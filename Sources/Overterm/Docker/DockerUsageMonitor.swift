import Combine
import Foundation

/// What the running containers use, for the page's CPU and memory columns:
/// read only while a page's Containers section shows (`want`), stopped
/// when the last one goes. Each running or paused container is read once
/// a round (`oneShotStats`), `limit` at a time, its CPU set against its
/// read before (`DockerUsageReadings`). One for the app
/// (`DockerModel.usage`): two windows showing it read once.
///
/// `docker stats --no-stream` would do the same calls without one-shot —
/// all at once, each waiting for two of the engine's samples — in a
/// process every round, and print for people what is read back here as
/// numbers.
@MainActor
final class DockerUsageMonitor: ObservableObject {
    /// By container id, from its second read.
    @Published private(set) var byContainer: [String: DockerUsage] = [:]
    /// Between rounds, counted after one ends: a slow engine (a remote
    /// one's ssh) stretches the cadence rather than piling reads up.
    var interval: Duration = .seconds(3)
    /// After a round that read a container for the first time: its
    /// columns fill a second after it shows, not a round later.
    var first: Duration = .seconds(1)
    /// How long a read may take: one that hangs (a container whose shim
    /// stopped answering) fails, and the round still ends — else nothing
    /// is read again, and every cell keeps its last number as if current.
    var timeout: Duration = .seconds(5)
    /// Reads at once.
    nonisolated static let limit = 4
    /// Failed rounds a container's last value outlives: one hiccup, not
    /// a number read minutes ago.
    nonisolated static let keptThrough = 1

    private weak var docker: DockerModel?
    private var wanted = 0
    private var polling: Task<Void, Never>?
    private var readings = DockerUsageReadings()
    /// Failed reads in a row, by container id.
    private var misses: [String: Int] = [:]
    /// The engine the readings are of: another one's counters mean nothing
    /// here.
    private weak var readEngine: DockerEngine?

    init(docker: DockerModel) {
        self.docker = docker
    }

    var isPolling: Bool { polling != nil }

    /// A page's Containers section shows.
    func want() {
        wanted += 1
        guard polling == nil else { return }
        polling = Task { [weak self] in await self?.poll() }
    }

    /// It went: at the last one, the reads stop — those on their way
    /// cancelled with the task — and the values go.
    func unwant() {
        wanted = max(0, wanted - 1)
        guard wanted == 0 else { return }
        polling?.cancel()
        polling = nil
        reset()
    }

    /// Nothing known: the engine went, or another took its place.
    func reset() {
        readings = DockerUsageReadings()
        misses = [:]
        readEngine = nil
        if !byContainer.isEmpty { byContainer = [:] }
    }

    private func poll() async {
        while !Task.isCancelled {
            let waiting = await round()
            try? await Task.sleep(for: waiting ? first : interval)
        }
    }

    /// Every running or paused container read once; whether one read for
    /// the first time waits for its second. The poll calls it, and the
    /// tests, a round at a time.
    func round() async -> Bool {
        guard let docker, let engine = docker.engine else {
            reset()
            return false
        }
        if readEngine !== engine {
            reset()
            readEngine = engine
        }
        let ids = docker.containers.filter { $0.state.hasStats }.map(\.Id)
        let samples = await Self.read(ids, limit: Self.limit, timeout: timeout, Self.reader(engine, of: docker))
        guard !Task.isCancelled, docker.engine === engine else { return false }
        let running = Set(ids)
        readings.keep(running)
        misses = misses.filter { running.contains($0.key) }
        var next: [String: DockerUsage] = [:]
        var waiting = false
        for id in ids {
            guard let sample = samples[id] else {
                // Failed, or too slow: what it showed stays a round, then
                // a dash. Not read again sooner for it: a read that fails
                // once a second is no better than once a round.
                let missed = (misses[id] ?? 0) + 1
                misses[id] = missed
                if missed <= Self.keptThrough, let kept = byContainer[id] { next[id] = kept }
                continue
            }
            misses[id] = nil
            if let usage = readings.add(sample, for: id) {
                next[id] = usage
            } else if readings.has(id) {
                // Its first read, or its first since a restart: the next
                // one says. An empty one (it stopped) is forgotten, and so
                // is what it showed.
                if let kept = byContainer[id] { next[id] = kept } else { waiting = true }
            }
        }
        if next != byContainer { byContainer = next }
        return waiting
    }

    /// `read` for each of `ids`, at most `limit` at a time, none for longer
    /// than `timeout`; what came back.
    nonisolated static func read<Value: Sendable>(
        _ ids: [String], limit: Int, timeout: Duration, _ read: @escaping @Sendable (String) async -> Value?
    ) async -> [String: Value] {
        await withTaskGroup(of: (String, Value?).self) { group in
            var pending = ids.makeIterator()
            for _ in 0..<max(1, limit) {
                guard let id = pending.next() else { break }
                group.addTask { (id, await within(timeout) { await read(id) }) }
            }
            var found: [String: Value] = [:]
            // `next()`, not `for await`: a read is added as one ends.
            while let done = await group.next() {
                if let value = done.1 { found[done.0] = value }
                if !Task.isCancelled, let id = pending.next() { group.addTask { (id, await within(timeout) { await read(id) }) } }
            }
            return found
        }
    }

    /// What `work` gives within `timeout`, else nil, and `work` cancelled:
    /// a read's connection closes then (`NIODockerTransport.send`), so the
    /// group isn't kept waiting for it.
    nonisolated static func within<Value: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async -> Value?) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// A container's one-shot stats, unless the engine has changed since:
    /// a switched-away engine isn't asked again (its ssh is closing). Made
    /// here, not in a closure of the main actor's: that one would be
    /// isolated to it (CLAUDE.md, a block for a queue).
    nonisolated static func reader(_ engine: DockerEngine, of docker: DockerModel) -> @Sendable (String) async -> ContainerStatsSample? {
        // Held for one round, as `round` holds it.
        { id in
            guard !Task.isCancelled, await docker.engine === engine else { return nil }
            return try? await engine.oneShotStats(id)
        }
    }
}
