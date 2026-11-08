import Foundation
import XCTest

@testable import Overterm

/// Stage M5's queue (docs/design/kubernetes/metrics.md, 6.3): 4 in
/// flight, identical queries joined, a query nobody waits for dropped or
/// cancelled, priority order, an agent's 2 places at most, `Retry-After`
/// pausing the context, a credential failure and a `services/proxy` 403
/// stopping it. Against a stand-in transport that answers when told.
final class KubePromQueueTests: XCTestCase {
    /// Answers each path when released; counts what is in flight.
    final class Gate: KubePrometheusTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var open: Set<String> = []
        private var all = false
        private(set) var asked: [String] = []
        private(set) var cancelled: [String] = []
        private var flying = 0
        private(set) var most = 0
        var status = 200
        var headers: [(String, String)] = []
        var body = Data(#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1,"1"]}]}}"#.utf8)
        var error: Error?
        /// A transport slow to notice it was cancelled (a connection's read in flight).
        var ignoresCancel = false

        func release(_ path: String) { lock.withLock { _ = open.insert(path) } }
        func releaseAll() { lock.withLock { all = true } }
        var askedPaths: [String] { lock.withLock { asked } }
        var cancelledPaths: [String] { lock.withLock { cancelled } }
        var highest: Int { lock.withLock { most } }

        func query(_ path: String) async throws -> HTTPResponse {
            lock.withLock {
                asked.append(path)
                flying += 1
                most = max(most, flying)
            }
            defer { lock.withLock { flying -= 1 } }
            while !lock.withLock({ all || open.contains(path) }) {
                do {
                    try await Task.sleep(for: .milliseconds(5))
                } catch {
                    lock.withLock { cancelled.append(path) }
                    if lock.withLock({ ignoresCancel }) {
                        while !lock.withLock({ all || open.contains(path) }) { usleep(5000) }
                        break
                    }
                    throw error
                }
            }
            if let error = lock.withLock({ self.error }) { throw error }
            return lock.withLock { HTTPResponse(status: status, headers: headers, body: body) }
        }
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testFourInFlightByPriorityIdenticalOnesJoined() async throws {
        let queue = KubePromQueue()
        let gate = Gate()
        var tasks: [Task<Double?, Error>] = []
        func ask(_ path: String, _ priority: KubePromQueue.Priority, order: Int = 0) {
            tasks.append(Task { KubePrometheusReader.value(try await queue.ask(path, via: gate, priority: priority, order: order).series) })
        }
        for index in 0..<4 { ask("/q\(index)", .visible, order: index) }
        await until("four going") { await queue.inFlight == 4 }
        ask("/sizing", .sizing)
        ask("/ranking", .ranking)
        ask("/top", .visible, order: 0)
        ask("/q0", .peak)
        await until("waiting") { await queue.queued == 3 }
        let fourth = await queue.inFlight
        XCTAssertEqual(fourth, 4, "the fifth waits")
        XCTAssertEqual(gate.askedPaths.count, 4)
        gate.releaseAll()
        for task in tasks { _ = try await task.value }
        let sent = await queue.sent
        XCTAssertEqual(sent, 7, "/q0 asked twice, sent once")
        XCTAssertLessThanOrEqual(gate.highest, KubePromQueue.maxInFlight)
        let order = await queue.sentPaths
        XCTAssertEqual(Array(order.suffix(3)), ["/top", "/ranking", "/sizing"], "a visible chart first, sizing last")
        let peak = await queue.peak
        XCTAssertEqual(peak, 4)
    }

    func testAQueryNobodyWaitsForIsDroppedOrCancelled() async throws {
        let queue = KubePromQueue()
        let gate = Gate()
        for index in 0..<4 { Task { _ = try? await queue.ask("/busy\(index)", via: gate) } }
        await until("four going") { await queue.inFlight == 4 }
        let waiting = Task { try await queue.ask("/waiting", via: gate) }
        await until("one waiting") { await queue.queued == 1 }
        waiting.cancel()
        await until("dropped") { await queue.queued == 0 }
        do {
            _ = try await waiting.value
            XCTFail("cancelled")
        } catch is CancellationError {}
        // One on its way, its only asker gone: cancelled.
        let going = Task { try await queue.ask("/busy0", via: gate) }
        try await Task.sleep(for: .milliseconds(50))
        going.cancel()
        _ = try? await going.value
        gate.releaseAll()
        await until("ended") { await queue.inFlight == 0 }
        XCTAssertFalse(gate.askedPaths.contains("/waiting"), "never sent")
    }

    /// Its only asker gone, a query on its way is cancelled — and a later
    /// identical ask, never cancelled itself, starts afresh rather than
    /// joining it and getting its cancellation (a chart scrolled off and back).
    func testACancelledQueryIsntJoinedByALaterAsk() async throws {
        let queue = KubePromQueue()
        let gate = Gate()
        gate.ignoresCancel = true
        let first = Task { try await queue.ask("/a", via: gate) }
        await until("going") { gate.askedPaths.count == 1 }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled")
        } catch is CancellationError {}
        let held = await queue.inFlight
        XCTAssertEqual(held, 1, "still holding its place until it ends")
        let again = Task { try await queue.ask("/a", via: gate) }
        await until("sent afresh") { gate.askedPaths.count == 2 }
        let both = await queue.inFlight
        XCTAssertEqual(both, 2, "the cancelled one counts against the four")
        gate.release("/a")
        let answer = try await again.value
        XCTAssertEqual(KubePrometheusReader.value(answer.series), 1, "its own answer, not the other's cancellation")
        await until("ended") { await queue.inFlight == 0 }
    }

    func testAnAgentHoldsTwoPlacesAndGoesAfterThePage() async throws {
        let queue = KubePromQueue()
        let gate = Gate()
        for index in 0..<6 { Task { _ = try? await queue.ask("/agent\(index)", via: gate, asker: .agent) } }
        await until("two going") { await queue.inFlight == 2 }
        try await Task.sleep(for: .milliseconds(100))
        let agents = await queue.inFlight
        XCTAssertEqual(agents, 2, "two of the four, however many it asks")
        let page = Task { try await queue.ask("/chart", via: gate) }
        await until("the page's chart goes at once") { gate.askedPaths.contains("/chart") }
        gate.release("/chart")
        _ = try await page.value
        gate.releaseAll()
        await until("all done") {
            let going = await queue.inFlight
            let held = await queue.queued
            return going == 0 && held == 0
        }
        let most = await queue.peakAgent
        XCTAssertEqual(most, KubePromQueue.maxAgent)
    }

    func testRetryAfterPausesTheContext() async throws {
        let queue = KubePromQueue()
        let gate = Gate()
        gate.status = 429
        gate.headers = [("Retry-After", "1")]
        gate.body = Data(#"{"kind":"Status","code":429,"message":"too many requests"}"#.utf8)
        gate.releaseAll()
        do {
            _ = try await queue.ask("/first", via: gate)
            XCTFail("busy")
        } catch let failure as KubePrometheusReader.Failure {
            XCTAssertEqual(failure.kind, .busy)
            XCTAssertEqual(failure.retryAfter, 1)
            XCTAssertEqual(failure.message, "Prometheus is busy (HTTP 429); asked again in 1 s.")
        }
        let paused = await queue.pausedUntil
        XCTAssertNotNil(paused, "the whole context paused")
        gate.status = 200
        gate.headers = []
        gate.body = Data(#"{"status":"success","data":{"resultType":"vector","result":[]}}"#.utf8)
        let started = Date()
        _ = try await queue.ask("/second", via: gate)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.8, "sent once the pause ended")
        XCTAssertEqual(gate.askedPaths, ["/first", "/second"], "nothing retried meanwhile")
    }

    func testA403OrACredentialFailureStopsIt() async throws {
        let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-operated", port: "9090")!
        let queue = KubePromQueue(service: service)
        let gate = Gate()
        gate.status = 403
        gate.body = Data(#"{"kind":"Status","code":403,"message":"services is forbidden"}"#.utf8)
        for index in 0..<4 { Task { _ = try? await queue.ask("/held\(index)", via: gate) } }
        await until("four going") { await queue.inFlight == 4 }
        let waiting = Task { try await queue.ask("/waits", via: gate) }
        await until("one waits") { await queue.queued == 1 }
        gate.release("/held0")
        do {
            _ = try await waiting.value
            XCTFail("stopped")
        } catch let stop as KubePromQueue.Stopped {
            XCTAssertEqual(stop.reason, "You can't reach monitoring/prometheus-operated here: `get services/proxy` is refused in monitoring.")
        }
        do {
            _ = try await queue.ask("/after", via: gate)
            XCTFail("still stopped")
        } catch is KubePromQueue.Stopped {}
        await until("the rest cancelled") { await queue.inFlight == 0 }
        XCTAssertFalse(gate.askedPaths.contains("/waits") || gate.askedPaths.contains("/after"))

        // A credential failure, the context's own sentence.
        let signIn = KubePromQueue()
        let failing = Gate()
        failing.error = KubeProxyProblem.credentials("aws: the SSO session has expired")
        failing.releaseAll()
        _ = try? await signIn.ask("/q", via: failing)
        let reason = await signIn.stopped
        XCTAssertEqual(reason, KubeProxyProblem.credentials("aws: the SSO session has expired").reason)
    }
}
