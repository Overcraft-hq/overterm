import Foundation

/// A context's Prometheus queries, one queue for the page's charts and an
/// agent's alike (metrics.md, 6.3): at most 4 in flight; an identical
/// query already waiting or going is joined, not sent twice; one nobody
/// waits for any more is dropped, or cancelled on its way; the waiting
/// ones go by priority — visible charts top first, then a ranking, then a
/// peak or projection, then sizing — and an agent's below every page's,
/// holding at most 2 of the 4 places, so an agent in a loop can't starve
/// the page. A busy answer's `Retry-After` (a 429 or 503) pauses the whole
/// context, not that query; a credential failure or a `services/proxy`
/// 403 stops it — what waits is told why, nothing is retried in a loop,
/// and a new queue is made when the context's credentials change.
actor KubePromQueue {
    enum Priority: Int, Comparable, Sendable {
        case visible = 0, ranking, peak, sizing

        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    enum Asker: Sendable {
        case page, agent
    }

    /// The queue stopped: why, said to whoever asks.
    struct Stopped: Error, LocalizedError, Equatable {
        var reason: String
        var errorDescription: String? { reason }
    }

    static let maxInFlight = 4
    static let maxAgent = 2
    /// The longest pause a `Retry-After` gets.
    static let maxPause: TimeInterval = 300

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<KubePrometheusReader.Answer, Error>
    }

    private struct Entry {
        let path: String
        var priority: Priority
        var order: Int
        var agent: Bool
        let sequence: UInt64
        let transport: any KubePrometheusTransport
        let deadline: Duration
        var waiters: [Waiter]
        var task: Task<Void, Never>?
    }

    private var waiting: [String: Entry] = [:]
    private var running: [String: Entry] = [:]
    /// Cancelled on their way (nobody waits for them), by sequence: still
    /// holding a place until they end, but no longer joined — a later
    /// identical ask starts afresh rather than getting their cancellation.
    private var cancelling: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 0
    /// Asks cancelled before they were queued (the handler's task ran first).
    private var cancelledEarly: Set<UInt64> = []
    private var asked: Set<UInt64> = []
    private var wake: Task<Void, Never>?

    /// Paused until then (a `Retry-After`).
    private(set) var pausedUntil: Date?
    /// Stopped: why.
    private(set) var stopped: String?
    /// Queries sent, and the most in flight at once (the tests').
    private(set) var sent = 0
    private(set) var peak = 0
    private(set) var peakAgent = 0
    /// The last paths sent, in the order they went (the tests').
    private(set) var sentPaths: [String] = []
    /// The Service its 403 names.
    let service: KubePrometheusService?

    init(service: KubePrometheusService? = nil) {
        self.service = service
    }

    var inFlight: Int { running.count + cancelling.count }
    var queued: Int { waiting.count }

    /// One query's answer, when its turn comes: `order` places it among
    /// its priority (a chart's place on screen, top first).
    func ask(
        _ path: String, via transport: any KubePrometheusTransport, priority: Priority = .visible, order: Int = 0, asker: Asker = .page,
        deadline: Duration = KubePromQL.deadline
    ) async throws -> KubePrometheusReader.Answer {
        if let stopped { throw Stopped(reason: stopped) }
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        asked.insert(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(Waiter(id: id, continuation: continuation), path, transport, priority, order, asker == .agent, deadline)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Asked again from a clean slate (a test's; a new queue does the same).
    func resume() {
        stopped = nil
        pausedUntil = nil
        pump()
    }

    // MARK: Inside

    private func enqueue(
        _ waiter: Waiter, _ path: String, _ transport: any KubePrometheusTransport, _ priority: Priority, _ order: Int, _ agent: Bool, _ deadline: Duration
    ) {
        if cancelledEarly.remove(waiter.id) != nil {
            asked.remove(waiter.id)
            return waiter.continuation.resume(throwing: CancellationError())
        }
        if let stopped {
            asked.remove(waiter.id)
            return waiter.continuation.resume(throwing: Stopped(reason: stopped))
        }
        if var entry = running[path] {
            entry.waiters.append(waiter)
            entry.agent = entry.agent && agent
            running[path] = entry
            return
        }
        if var entry = waiting[path] {
            entry.waiters.append(waiter)
            entry.priority = min(entry.priority, priority)
            entry.order = min(entry.order, order)
            entry.agent = entry.agent && agent
            waiting[path] = entry
            return
        }
        waiting[path] = Entry(
            path: path, priority: priority, order: order, agent: agent, sequence: waiter.id, transport: transport, deadline: deadline, waiters: [waiter])
        pump()
    }

    private func cancel(_ id: UInt64) {
        for (path, var entry) in waiting {
            guard let index = entry.waiters.firstIndex(where: { $0.id == id }) else { continue }
            let waiter = entry.waiters.remove(at: index)
            waiting[path] = entry.waiters.isEmpty ? nil : entry
            asked.remove(id)
            return waiter.continuation.resume(throwing: CancellationError())
        }
        for (path, var entry) in running {
            guard let index = entry.waiters.firstIndex(where: { $0.id == id }) else { continue }
            let waiter = entry.waiters.remove(at: index)
            // Nobody waits for it any more: cancelled on its way, out of
            // `running` so nothing joins it; its place freed when it ends.
            if entry.waiters.isEmpty {
                entry.task?.cancel()
                running[path] = nil
                cancelling[entry.sequence] = entry
            } else {
                running[path] = entry
            }
            asked.remove(id)
            return waiter.continuation.resume(throwing: CancellationError())
        }
        // Not queued yet: it is turned away when it arrives. Answered already: nothing to do.
        if asked.contains(id) { cancelledEarly.insert(id) }
    }

    private func pump() {
        guard stopped == nil else { return }
        if let until = pausedUntil {
            let left = until.timeIntervalSinceNow
            if left > 0 {
                if wake == nil {
                    wake = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(left))
                        await self?.woke()
                    }
                }
                return
            }
            pausedUntil = nil
        }
        while inFlight < Self.maxInFlight {
            let agents = running.values.filter(\.agent).count + cancelling.values.filter(\.agent).count
            let next = waiting.values.filter { !$0.agent || agents < Self.maxAgent }.min { a, b in
                (a.agent ? 1 : 0, a.priority.rawValue, a.order, a.sequence) < (b.agent ? 1 : 0, b.priority.rawValue, b.order, b.sequence)
            }
            guard let next else { break }
            start(next)
        }
    }

    private func woke() {
        wake = nil
        pump()
    }

    private func start(_ entry: Entry) {
        var entry = entry
        waiting[entry.path] = nil
        sent += 1
        sentPaths.append(entry.path)
        if sentPaths.count > 64 { sentPaths.removeFirst(sentPaths.count - 64) }
        let path = entry.path
        let sequence = entry.sequence
        let transport = entry.transport
        let deadline = entry.deadline
        entry.task = Task { [weak self] in
            let result: Result<KubePrometheusReader.Answer, Error>
            do {
                result = .success(try await KubePrometheusMonitor.fetch(transport, path, deadline: deadline))
            } catch {
                result = .failure(error)
            }
            await self?.finish(path, sequence, result)
        }
        running[path] = entry
        peak = max(peak, inFlight)
        peakAgent = max(peakAgent, running.values.filter(\.agent).count + cancelling.values.filter(\.agent).count)
    }

    private func finish(_ path: String, _ sequence: UInt64, _ result: Result<KubePrometheusReader.Answer, Error>) {
        if cancelling.removeValue(forKey: sequence) != nil {
            // Nobody waited for it: its place freed, its answer (or failure) only acted on.
            if case .failure(let error) = result, !(error is CancellationError) { act(on: error) }
            return pump()
        }
        guard running[path]?.sequence == sequence, let entry = running.removeValue(forKey: path) else { return }
        if case .failure(let error) = result { act(on: error) }
        for waiter in entry.waiters {
            asked.remove(waiter.id)
            if let stopped, case .failure(let error) = result, error is CancellationError {
                waiter.continuation.resume(throwing: Stopped(reason: stopped))
            } else {
                waiter.continuation.resume(with: result)
            }
        }
        pump()
    }

    /// A failure that pauses or stops the context's queries.
    private func act(on error: Error) {
        if let problem = error as? KubeProxyProblem, problem.stopsRequests {
            stop(KubeChartEmpty.credential(problem.reason).sentence)
        } else if let failure = error as? KubePrometheusReader.Failure {
            if failure.kind == .serviceProxyForbidden {
                stop(service.map { KubeChartEmpty.serviceProxyForbidden($0).sentence } ?? failure.message)
            } else if failure.kind == .busy, let after = failure.retryAfter, after > 0 {
                let until = Date().addingTimeInterval(min(after, Self.maxPause))
                if pausedUntil.map({ $0 < until }) ?? true { pausedUntil = until }
            }
        }
    }

    /// Stopped: what waits is told why, what goes is cancelled.
    private func stop(_ reason: String) {
        guard stopped == nil else { return }
        stopped = reason
        let held = waiting.values.flatMap(\.waiters)
        waiting = [:]
        for waiter in held {
            asked.remove(waiter.id)
            waiter.continuation.resume(throwing: Stopped(reason: reason))
        }
        for entry in running.values { entry.task?.cancel() }
        for entry in cancelling.values { entry.task?.cancel() }
    }
}
