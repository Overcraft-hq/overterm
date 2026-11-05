import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// The proxies a context each (`KubeProxies`), over stand-in proxies whose
/// answers the test writes: opened once and kept, `maxProxies` with the
/// page's slot, idle ones closed, a credential failure that stops the
/// context's requests, oidc sign-ins one at a time, read-only that follows
/// the context. Nothing here starts kubectl.
final class KubeProxiesTests: XCTestCase {
    private var clock: Clock!
    private var opened: Recorder<KubeProxySpec>!
    private var closed: Recorder<String>!
    private var answers: Answers!
    /// Opens the test holds (`hold`), and closes that block until let go.
    private var openings: Answers!
    private var closings: CloseGates!

    override func setUp() {
        clock = Clock()
        opened = Recorder()
        closed = Recorder()
        answers = Answers()
        openings = Answers()
        closings = CloseGates()
    }

    private func proxies(max: Int = 4, idle: TimeInterval = 600, plans: Recorder<Int?>? = nil) -> KubeProxies {
        let opened = self.opened!
        let closed = self.closed!
        let answers = self.answers!
        let openings = self.openings!
        let closings = self.closings!
        let clock = self.clock!
        return KubeProxies(
            configuration: KubeProxies.Configuration(maxProxies: max, idleTime: idle), now: { clock.now }, sweepEvery: .seconds(3600),
            plan: { context, _, minor in
                plans?.add(minor)
                return KubeProxySpec(
                    context: context.name, readOnly: !context.isWritable, kubectl: URL(fileURLWithPath: "/stand-in/kubectl"),
                    socket: "/tmp/\(KubeSocketFolder.name(for: context.name))", environment: [:], cacheDirectory: nil, signIn: KubeSignIn(context.auth))
            },
            open: { spec in
                _ = await openings.answer(spec.context)
                opened.add(spec)
                let open = Flag(true)
                return KubeProxy(
                    context: spec.context, readOnly: spec.readOnly, signIn: spec.signIn, transport: StubTransport(context: spec.context, answers: answers),
                    isRunning: { open.value },
                    close: {
                        closings.pass(spec.context)
                        open.value = false
                        closed.add(spec.context)
                    })
            })
    }

    private static func context(_ name: String, auth: KubeAuth? = KubeAuth.none, writable: Bool? = nil) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: nil, user: name, auth: auth, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings(writable: writable))
    }

    private static let oidc = KubeAuth.exec(KubeExec(command: "kubectl", arguments: ["oidc-login", "get-token"]))
    private static let aws = KubeAuth.exec(KubeExec(command: "aws", arguments: ["eks", "get-token", "--profile", "acme"]))

    func testAContextsProxyIsOpenedOnceAndKept() async throws {
        let proxies = proxies()
        let dev = Self.context("fake-dev")
        async let one = proxies.send(dev, .GET, "/api/v1/pods")
        async let two = proxies.send(dev, .GET, "/api/v1/pods")
        let answers = try await [one, two]
        XCTAssertEqual(answers.map(\.status), [200, 200])
        _ = try await proxies.send(dev, .GET, "/api/v1/namespaces")
        XCTAssertEqual(opened.values.map(\.context), ["fake-dev"])
        XCTAssertTrue(opened.values[0].readOnly)
        let status = await proxies.status(of: "fake-dev")
        XCTAssertEqual(status, .open)
        let other = await proxies.status(of: "fake-prod")
        XCTAssertEqual(other, .closed)
    }

    /// Production's switch for the session (rule 2): off, its proxy has the
    /// method filter and a write is refused before any socket; on, the
    /// proxy is started again without the filter — whichever copy of the
    /// context a request carries — and off again, with it.
    func testProductionsSessionWritesRestartItsProxyWithoutTheMethodFilter() async throws {
        let proxies = proxies()
        let prod = Self.context("fake-prod")
        _ = try await proxies.send(prod, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.map(\.readOnly), [true])
        do {
            _ = try await proxies.sendWrite(prod, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
            XCTFail("production without its switch takes no write")
        } catch {
            XCTAssertEqual(error as? KubeWriteRefused, KubeWriteRefused(reason: KubeWriteCheck.readOnly(prod)))
        }
        XCTAssertEqual(answers.count("fake-prod"), 1, "the write never reached the socket")

        await proxies.allowSessionWrites(prod)
        XCTAssertEqual(closed.values, ["fake-prod"], "closed at once: the next request opens it with the other flags")
        // The copy the request carries still says read-only: the proxies know better.
        _ = try await proxies.sendWrite(prod, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
        _ = try await proxies.send(prod, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.map(\.readOnly), [true, false], "one proxy without the method filter, kept")
        let writable = await proxies.isWritable(prod)
        XCTAssertTrue(writable)
        // The kubeconfig read again points the name at another server: that
        // copy is read-only here at once, before anyone tells the proxies.
        let moved = KubeContext(
            name: prod.name, cluster: prod.cluster, server: "http://127.0.0.1:2", namespace: nil, user: prod.user, auth: prod.auth, file: nil,
            contextClass: prod.contextClass, settings: prod.settings)
        let movedWritable = await proxies.isWritable(moved)
        XCTAssertFalse(movedWritable, "the switch was for the cluster it was turned on for")
        do {
            _ = try await proxies.sendWrite(moved, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
            XCTFail("another cluster under the same name takes no write")
        } catch {
            XCTAssertTrue(error is KubeWriteRefused)
        }

        await proxies.endSessionWrites("fake-prod")
        _ = try await proxies.send(prod, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.map(\.readOnly), [true, false, true], "the filter back")
        do {
            _ = try await proxies.sendWrite(prod, .PATCH, "/apis/apps/v1/namespaces/shop/deployments/web/scale", body: Data("{}".utf8))
            XCTFail("off again")
        } catch {
            XCTAssertTrue(error is KubeWriteRefused)
        }

        // Another class has no switch: a remote context stays as its setting says.
        let dev = Self.context("fake-dev")
        await proxies.allowSessionWrites(dev)
        _ = try await proxies.send(dev, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.last?.readOnly, true, "only production has a session switch")
        let kind = Self.context("kind-fake")
        _ = try await proxies.sendWrite(kind, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
        XCTAssertEqual(opened.values.last?.readOnly, false, "a local context is writable by its class")
    }

    func testTheLeastRecentlyUsedIdleOneClosesPastMaxProxies() async throws {
        let proxies = proxies(max: 2)
        _ = try await proxies.send(Self.context("a"), .GET, "/")
        clock.advance(1)
        _ = try await proxies.send(Self.context("b"), .GET, "/")
        clock.advance(1)
        // The page moves to c: a, used longest ago, closes.
        _ = try await proxies.send(Self.context("c"), .GET, "/")
        var connected = await proxies.connected
        XCTAssertEqual(connected, ["b", "c"])
        XCTAssertEqual(closed.values, ["a"])
        // The page's context is never closed for the background's.
        clock.advance(1)
        _ = try await proxies.send(Self.context("d"), role: .background, .GET, "/")
        connected = await proxies.connected
        XCTAssertEqual(connected, ["c", "d"])
        XCTAssertEqual(closed.values, ["a", "b"])
    }

    /// One slot is the page's: the background uses `maxProxies − 1` at most,
    /// and a busy background proxy is closed when the page needs its slot.
    func testOneSlotIsKeptForThePage() async throws {
        let proxies = proxies(max: 2)
        _ = try await proxies.send(Self.context("page"), .GET, "/")
        // A watch in the background, held open.
        answers.hold("watch")
        let watch = Task {
            for try await _ in proxies.stream(Self.context("watch"), role: .background, .GET, "/api/v1/pods?watch=1") {}
        }
        try await until { self.answers.isHeld("watch") }
        do {
            _ = try await proxies.send(Self.context("other"), role: .background, .GET, "/")
            XCTFail("the background has one slot, and it is busy")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .noSlot(max: 2))
        }
        var connected = await proxies.connected
        XCTAssertEqual(connected, ["page", "watch"])
        // The page moves to another context: the page's own former context
        // is idle, so it closes before the busy watch.
        clock.advance(1)
        _ = try await proxies.send(Self.context("next"), .GET, "/")
        connected = await proxies.connected
        XCTAssertEqual(connected, ["next", "watch"])
        // Both busy now: the page takes the least recently used one's slot.
        answers.hold("next")
        let busy = Task { try await proxies.send(Self.context("next"), .GET, "/") }
        try await until { self.answers.isHeld("next") }
        clock.advance(1)
        _ = try await proxies.send(Self.context("last"), .GET, "/")
        connected = await proxies.connected
        XCTAssertEqual(connected, ["last", "next"])
        XCTAssertEqual(closed.values, ["page", "watch"])
        answers.release("next")
        _ = try await busy.value
        answers.release("watch")
        watch.cancel()
        _ = await watch.result
    }

    func testAnIdleProxyCloses() async throws {
        let proxies = proxies(idle: 600)
        _ = try await proxies.send(Self.context("a"), .GET, "/")
        answers.hold("b")
        let held = Task { try await proxies.send(Self.context("b"), .GET, "/") }
        try await until { self.answers.isHeld("b") }
        clock.advance(599)
        var idle = await proxies.closeIdle()
        XCTAssertEqual(idle, [])
        clock.advance(2)
        idle = await proxies.closeIdle()
        XCTAssertEqual(idle, ["a"], "b has a request in flight")
        answers.release("b")
        _ = try await held.value
        clock.advance(601)
        idle = await proxies.closeIdle()
        XCTAssertEqual(idle, ["b"])
        XCTAssertEqual(closed.values, ["a", "b"])
        // The next request opens it again.
        _ = try await proxies.send(Self.context("a"), .GET, "/")
        XCTAssertEqual(opened.values.map(\.context), ["a", "b", "a"])
    }

    /// The spike: an expired SSO session made every request a 500 that ran
    /// `aws` again. The first stops the context until it is retried.
    func testACredentialFailureStopsTheContextsRequests() async throws {
        let proxies = proxies()
        let dev = Self.context("acme-dev", auth: Self.aws)
        answers.set(
            "acme-dev",
            HTTPResponse(
                status: 500, headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: Data("getting credentials: exec: executable aws failed with exit code 255\n".utf8)))
        do {
            _ = try await proxies.send(dev, .GET, "/api/v1/pods")
            XCTFail("a credential failure throws")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .awsSignIn(profile: "acme"))
            XCTAssertEqual((error as? KubeProxyProblem)?.reason, "Sign in again: aws sso login --profile acme")
        }
        for _ in 0..<3 {
            do {
                _ = try await proxies.send(dev, .GET, "/api/v1/pods")
                XCTFail("stopped")
            } catch {
                XCTAssertEqual(error as? KubeProxyProblem, .awsSignIn(profile: "acme"))
            }
        }
        do {
            for try await _ in proxies.stream(dev, .GET, "/api/v1/pods?watch=1") { XCTFail("no stream either") }
            XCTFail("stopped")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .awsSignIn(profile: "acme"))
        }
        XCTAssertEqual(answers.count("acme-dev"), 1, "no retries: one request reached the proxy")
        let status = await proxies.status(of: "acme-dev")
        XCTAssertEqual(status, .stopped(.awsSignIn(profile: "acme")))
        XCTAssertEqual(status.reason, "Sign in again: aws sso login --profile acme")

        // Signed in again: retried on a new proxy.
        answers.set("acme-dev", nil)
        await proxies.retry("acme-dev")
        let answer = try await proxies.send(dev, .GET, "/api/v1/pods")
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(opened.values.count, 2)
    }

    func testAnUnreachableClusterDoesntStopTheContext() async throws {
        let proxies = proxies()
        let dev = Self.context("fake-dev")
        answers.set("fake-dev", HTTPResponse(status: 500, headers: [("Content-Type", "text/plain")], body: Data("dial tcp 10.0.0.1:443: i/o timeout".utf8)))
        do {
            _ = try await proxies.send(dev, .GET, "/")
            XCTFail("unreachable")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .unreachable("dial tcp 10.0.0.1:443: i/o timeout"))
        }
        answers.set("fake-dev", nil)
        let answer = try await proxies.send(dev, .GET, "/")
        XCTAssertEqual(answer.status, 200, "the VPN came back")
        // The server's own errors are answers.
        answers.set("fake-dev", HTTPResponse(status: 403, headers: [("Content-Type", "application/json")], body: Data(#"{"kind":"Status"}"#.utf8)))
        let forbidden = try await proxies.send(dev, .GET, "/api/v1/secrets")
        XCTAssertEqual(forbidden.status, 403)
    }

    /// kubelogin listens on 127.0.0.1:8000: a second context's first
    /// request waits until the first context's browser sign-in is done.
    func testOIDCSignInsRunOneAtATime() async throws {
        let proxies = proxies()
        let first = Self.context("globex-eu-west-1-dev", auth: Self.oidc)
        let second = Self.context("globex-eu-central-1-dev", auth: Self.oidc)
        answers.hold(first.name)
        let one = Task { try await proxies.send(first, .GET, "/api/v1/pods") }
        try await until { self.answers.isHeld(first.name) }
        var status = await proxies.status(of: first.name)
        XCTAssertEqual(status, .signingIn)
        XCTAssertEqual(status.reason, "Waiting for the browser sign-in")
        let two = Task { try await proxies.send(second, role: .background, .GET, "/api/v1/pods") }
        try await until {
            let waiting = await proxies.status(of: second.name)
            return waiting == .waitingForSignIn(behind: first.name)
        }
        // A context that signs in some other way doesn't wait.
        let plain = try await proxies.send(Self.context("fake-dev"), .GET, "/")
        XCTAssertEqual(plain.status, 200)
        XCTAssertEqual(answers.count(second.name), 0, "not asked while the first sign-in runs")
        answers.release(first.name)
        _ = try await one.value
        _ = try await two.value
        XCTAssertEqual(answers.count(second.name), 1)
        status = await proxies.status(of: first.name)
        XCTAssertEqual(status, .open)
        // Signed in: its requests no longer wait for anyone's sign-in.
        answers.hold(second.name)
        let three = Task { try await proxies.send(second, .GET, "/again") }
        try await until { self.answers.isHeld(second.name) }
        let again = try await proxies.send(first, .GET, "/")
        XCTAssertEqual(again.status, 200)
        answers.release(second.name)
        _ = try await three.value
    }

    func testANobodyFinishedSignInSaysSoAndStops() async throws {
        let proxies = proxies()
        let first = Self.context("globex-eu-west-1-dev", auth: Self.oidc)
        answers.set(
            first.name,
            HTTPResponse(
                status: 500, headers: [("Content-Type", "text/plain")],
                body: Data("getting credentials: exec: executable kubectl failed with exit code 1: context deadline exceeded".utf8)))
        do {
            _ = try await proxies.send(first, .GET, "/")
            XCTFail("timed out")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .signInTimedOut)
        }
        // The next context's sign-in may go.
        let second = Self.context("globex-eu-central-1-dev", auth: Self.oidc)
        let answer = try await proxies.send(second, .GET, "/")
        XCTAssertEqual(answer.status, 200)
    }

    /// A context that becomes writable gets a proxy without the method
    /// filter, and one that stops being writable gets it back.
    func testReadOnlyFollowsTheContext() async throws {
        let proxies = proxies()
        _ = try await proxies.send(Self.context("fake-dev"), .GET, "/")
        _ = try await proxies.send(Self.context("fake-dev", writable: true), .GET, "/")
        _ = try await proxies.send(Self.context("fake-dev"), .GET, "/")
        XCTAssertEqual(opened.values.map(\.readOnly), [true, false, true])
        XCTAssertEqual(closed.values, ["fake-dev", "fake-dev"])
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["fake-dev"])
    }

    func testTheServersVersionIsNotedForTheNextKubectl() async throws {
        let plans = Recorder<Int?>()
        let proxies = proxies(plans: plans)
        let dev = Self.context("fake-dev")
        answers.set("fake-dev", HTTPResponse(status: 200, headers: [], body: Data(#"{"major":"1","minor":"30+"}"#.utf8)))
        _ = try await proxies.send(dev, .GET, "/version")
        await proxies.close("fake-dev")
        _ = try await proxies.send(dev, .GET, "/version")
        XCTAssertEqual(plans.values, [nil, 30])
    }

    func testAStreamHoldsItsProxyUntilItEnds() async throws {
        let proxies = proxies(idle: 10)
        answers.set("fake-dev", HTTPResponse(status: 200, headers: [], body: Data("one\ntwo\n".utf8)))
        var pieces: [String] = []
        for try await piece in proxies.stream(Self.context("fake-dev"), .GET, "/api/v1/pods?watch=1") {
            pieces.append(String(decoding: piece, as: UTF8.self))
        }
        XCTAssertEqual(pieces.joined(), "one\ntwo\n")
        clock.advance(11)
        let idle = await proxies.closeIdle()
        XCTAssertEqual(idle, ["fake-dev"], "ended: idle")
    }

    /// Two first requests for a context that needs a slot: the first
    /// closes another context's proxy for it, and while that close runs
    /// the second comes in. Both are counted — a proxy one request still
    /// uses is never closed as idle.
    func testTwoFirstRequestsThatWaitForASlotAreBothCounted() async throws {
        let proxies = proxies(max: 2, idle: 10)
        _ = try await proxies.send(Self.context("a"), .GET, "/")
        clock.advance(1)
        _ = try await proxies.send(Self.context("b"), .GET, "/")
        clock.advance(1)
        closings.block("a")
        answers.hold("c")
        let one = Task { try await proxies.send(Self.context("c"), .GET, "/one") }
        try await until { self.closings.isWaiting("a") }
        let two = Task { try await proxies.send(Self.context("c"), .GET, "/two") }
        try await until { await proxies.connected.contains("c") }
        closings.open("a")
        try await until { self.answers.waitingCount("c") == 2 }
        XCTAssertEqual(opened.values.map(\.context), ["a", "b", "c"], "one proxy for both")

        answers.releaseOne("c")
        try await until { self.answers.waitingCount("c") == 1 }
        clock.advance(11)
        var idle = await proxies.closeIdle()
        XCTAssertFalse(idle.contains("c"), "the other request still uses it")
        XCTAssertFalse(closed.values.contains("c"))

        answers.release("c")
        let statuses = try await [one.value, two.value].map(\.status)
        XCTAssertEqual(statuses, [200, 200])
        clock.advance(11)
        idle = await proxies.closeIdle()
        XCTAssertTrue(idle.contains("c"), "both done: idle")
    }

    /// A proxy closed while its first request waited for it to open ends
    /// that request with a reason to try again, leaves no entry behind that
    /// nothing could close, and ends the kubectl that finished opening.
    func testAProxyClosedWhileItOpenedEndsTheRequest() async throws {
        let proxies = proxies()
        openings.hold("x")
        let request = Task { try await proxies.send(Self.context("x"), role: .background, .GET, "/") }
        try await until { self.openings.isHeld("x") }
        await proxies.close("x")
        openings.release("x")
        do {
            _ = try await request.value
            XCTFail("closed")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .closedWhileOpening)
            XCTAssertFalse((error as? KubeProxyProblem)?.stopsRequests ?? true, "a retry may go")
        }
        let connected = await proxies.connected
        XCTAssertEqual(connected, [], "no entry left that nothing could close")
        XCTAssertEqual(closed.values, ["x"], "the kubectl that finished opening is ended")
        let again = try await proxies.send(Self.context("x"), .GET, "/")
        XCTAssertEqual(again.status, 200)
    }

    private func until(_ ok: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while await !ok(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let done = await ok()
        XCTAssertTrue(done, "waited 5 s")
    }
}

// MARK: Stand-ins

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [T] = []
    func add(_ value: T) { lock.withLock { all.append(value) } }
    var values: [T] { lock.withLock { all } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Bool
    init(_ value: Bool) { current = value }
    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// What each context's stand-in proxy answers (200 and an empty body
/// unless set), how many requests reached it, and the ones held until the
/// test releases them.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: HTTPResponse] = [:]
    private var counts: [String: Int] = [:]
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func set(_ context: String, _ response: HTTPResponse?) { lock.withLock { responses[context] = response } }
    func count(_ context: String) -> Int { lock.withLock { counts[context] ?? 0 } }
    func hold(_ context: String) { lock.withLock { _ = held.insert(context) } }
    func isHeld(_ context: String) -> Bool { lock.withLock { !(waiting[context] ?? []).isEmpty } }
    func waitingCount(_ context: String) -> Int { lock.withLock { waiting[context]?.count ?? 0 } }

    /// Lets the first held request answer; the others stay held.
    func releaseOne(_ context: String) {
        let first: CheckedContinuation<Void, Never>? = lock.withLock {
            guard var list = waiting[context], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            waiting[context] = list
            return first
        }
        first?.resume()
    }

    func release(_ context: String) {
        let resumed = lock.withLock {
            held.remove(context)
            defer { waiting[context] = nil }
            return waiting[context] ?? []
        }
        resumed.forEach { $0.resume() }
    }

    func answer(_ context: String) async -> HTTPResponse {
        let wait = lock.withLock {
            counts[context, default: 0] += 1
            return held.contains(context)
        }
        if wait {
            await withCheckedContinuation { continuation in
                let still = lock.withLock {
                    guard held.contains(context) else { return false }
                    waiting[context, default: []].append(continuation)
                    return true
                }
                if !still { continuation.resume() }
            }
        }
        return lock.withLock { responses[context] } ?? HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
    }
}

/// Closes that block (a stand-in's `close` is synchronous, as ending a
/// process is) until the test lets them go — so a close can be caught
/// half-way, with the actor free for other requests.
private final class CloseGates: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: DispatchSemaphore] = [:]
    private var waiting: Set<String> = []

    func block(_ context: String) { lock.withLock { gates[context] = DispatchSemaphore(value: 0) } }
    func isWaiting(_ context: String) -> Bool { lock.withLock { waiting.contains(context) } }
    func open(_ context: String) { lock.withLock { gates.removeValue(forKey: context) }?.signal() }

    func pass(_ context: String) {
        guard
            let gate = lock.withLock({ () -> DispatchSemaphore? in
                guard let gate = gates[context] else { return nil }
                waiting.insert(context)
                return gate
            })
        else { return }
        _ = gate.wait(timeout: .now() + 5)
        lock.withLock { _ = waiting.remove(context) }
    }
}

private struct StubTransport: HTTPTransport {
    let context: String
    let answers: Answers

    func send(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse {
        await answers.answer(context)
    }

    func send(
        _ method: HTTPMethod, _ path: String, length: Int, body: @escaping @Sendable () async throws -> Data?, headers: [(String, String)],
        sent: @escaping @Sendable (Int) -> Void
    ) async throws -> HTTPResponse {
        await answers.answer(context)
    }

    func stream(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        let answers = self.answers
        let context = self.context
        return AsyncThrowingStream { continuation in
            Task {
                let response = await answers.answer(context)
                if response.status >= 400 {
                    continuation.finish(throwing: HTTPError(status: response.status, message: response.errorMessage))
                    return
                }
                for line in String(decoding: response.body, as: UTF8.self).split(separator: "\n") { continuation.yield(Data((line + "\n").utf8)) }
                continuation.finish()
            }
        }
    }

    func receive(_ method: HTTPMethod, _ path: String, headers: [(String, String)], consume: (Data) async throws -> Void) async throws {
        try await consume(await answers.answer(context).body)
    }

    func ready() async throws -> HTTPResponse { await answers.answer(context) }
}
