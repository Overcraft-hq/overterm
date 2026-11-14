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

    private func proxies(max: Int = 4, idle: TimeInterval = 600, plans: Recorder<Int?>? = nil, planning: Answers? = nil) -> KubeProxies {
        let opened = self.opened!
        let closed = self.closed!
        let answers = self.answers!
        let openings = self.openings!
        let closings = self.closings!
        let clock = self.clock!
        return KubeProxies(
            configuration: KubeProxies.Configuration(maxProxies: max, idleTime: idle), now: { clock.now }, sweepEvery: .seconds(3600),
            plan: { context, _, minor in
                if let planning { _ = await planning.answer(context.name) }
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
        let dev = Self.context("fake-dev", writable: false)
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

    /// Production is writable unless its setting says no (the owner's
    /// decision): no switch — its proxy opens without the method filter.
    /// Set `writable: false`, the proxies close it at once, the next one
    /// has the filter, and a write is refused before any socket, whichever
    /// copy of the context it carries — the second lock, not the only one.
    func testProductionIsWritableUntilItsSettingSaysNo() async throws {
        let proxies = proxies()
        let prod = Self.context("fake-prod")
        _ = try await proxies.send(prod, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.map(\.readOnly), [false], "no method filter: writable by default")
        _ = try await proxies.sendWrite(prod, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
        XCTAssertEqual(answers.count("fake-prod"), 2, "the write reached its socket")

        let readOnly = Self.context("fake-prod", writable: false)
        await proxies.update(contexts: KubeContextList(contexts: [readOnly]))
        XCTAssertEqual(closed.values, ["fake-prod"], "closed at once: the next request opens it with the filter")
        do {
            _ = try await proxies.sendWrite(prod, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
            XCTFail("the copy says writable; the proxies know better")
        } catch {
            XCTAssertEqual(error as? KubeWriteRefused, KubeWriteRefused(reason: KubeWriteCheck.readOnly(prod)))
        }
        XCTAssertEqual(answers.count("fake-prod"), 2, "the write never reached the socket")
        _ = try await proxies.send(prod, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.map(\.readOnly), [false, true], "the method filter on")
        let refused = await proxies.isWritable(prod)
        XCTAssertFalse(refused)

        // Its entry taken out: writable again, the filter off.
        await proxies.update(contexts: KubeContextList(contexts: [prod]))
        _ = try await proxies.sendWrite(prod, .PATCH, "/apis/apps/v1/namespaces/shop/deployments/web/scale", body: Data("{}".utf8))
        XCTAssertEqual(opened.values.map(\.readOnly), [false, true, false])
        let writable = await proxies.isWritable(prod)
        XCTAssertTrue(writable)
        // The kubeconfig read again points the name at another server: that
        // copy is refused at once, before anyone tells the proxies.
        let moved = KubeContext(
            name: prod.name, cluster: prod.cluster, server: "http://127.0.0.1:2", namespace: nil, user: prod.user, auth: prod.auth, file: nil,
            contextClass: prod.contextClass, settings: prod.settings)
        let movedWritable = await proxies.isWritable(moved)
        XCTAssertFalse(movedWritable, "a write reviewed on another reading is refused")

        // Remote and local alike: writable by default, read-only by the setting.
        let dev = Self.context("fake-dev")
        let kind = Self.context("kind-fake", writable: false)
        await proxies.update(contexts: KubeContextList(contexts: [prod, dev, kind]))
        _ = try await proxies.sendWrite(dev, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
        XCTAssertEqual(opened.values.last?.readOnly, false, "a remote context is writable unless it says no")
        _ = try await proxies.send(kind, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.last?.readOnly, true, "a local one set read-only has the filter")
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
        let watching = Self.context("watch")
        let watch = Task {
            for try await _ in proxies.stream(watching, role: .background, .GET, "/api/v1/pods?watch=1") {}
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
        let next = Self.context("next")
        let busy = Task { try await proxies.send(next, .GET, "/") }
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

    /// Every slot busy, the page takes a background proxy's (the attention
    /// watches', 3.13) before another context's that is busy — and says which.
    func testThePageTakesABackgroundSlotFirst() async throws {
        let proxies = proxies(max: 2)
        answers.hold("a")
        let a = Self.context("a")
        let page = Task { try await proxies.send(a, .GET, "/") }
        try await until { self.answers.isHeld("a") }
        answers.hold("watch")
        let watching = Self.context("watch")
        let watch = Task {
            for try await _ in proxies.stream(watching, role: .background, .GET, "/api/v1/pods?watch=1") {}
        }
        try await until { self.answers.isHeld("watch") }
        clock.advance(1)
        // a was used before the watch began, but it isn't the background's.
        _ = try await proxies.send(Self.context("b"), .GET, "/")
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["a", "b"])
        XCTAssertEqual(closed.values, ["watch"])
        let evicted = await proxies.closedForPage
        XCTAssertEqual(evicted, ["watch"])
        // The background can't have one back while both are busy.
        do {
            _ = try await proxies.send(Self.context("watch"), role: .background, .GET, "/")
            XCTFail("no background slot while the page's and a busy one hold both")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .noSlot(max: 2))
        }
        answers.release("a")
        _ = try await page.value
        answers.release("watch")
        watch.cancel()
        _ = await watch.result
        // a idle now: the background's request closes it and opens its own.
        _ = try await proxies.send(Self.context("watch"), role: .background, .GET, "/")
        let after = await proxies.connected
        XCTAssertEqual(after, ["b", "watch"])
    }

    /// Attention watches on `maxProxies − 1` contexts hold every background
    /// slot busy; a request someone made (an agent's, the rail's) still gets
    /// one — the least recently used proxy only watches hold is given up —,
    /// while another watch doesn't.
    func testARequestSomeoneMadeTakesAProxyOnlyWatchesHold() async throws {
        let proxies = proxies(max: 4)
        _ = try await proxies.send(Self.context("page"), .GET, "/")
        var watches: [Task<Void, Error>] = []
        for name in ["w1", "w2", "w3"] {
            clock.advance(1)
            answers.hold(name)
            let context = Self.context(name)
            watches.append(
                Task { for try await _ in proxies.stream(context, role: .watch, .GET, "/api/v1/pods?watch=1") {} })
            try await until { self.answers.isHeld(name) }
        }
        do {
            _ = try await proxies.send(Self.context("w4"), role: .watch, .GET, "/")
            XCTFail("a watch never takes another watch's slot")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .noSlot(max: 4))
        }
        clock.advance(1)
        let answer = try await proxies.send(Self.context("agent"), role: .background, .GET, "/api/v1/namespaces/shop/pods")
        XCTAssertEqual(answer.status, 200)
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["agent", "page", "w2", "w3"], "the oldest watch's proxy given up")
        XCTAssertEqual(closed.values, ["w1"])
        let closedForPage = await proxies.closedForPage
        XCTAssertEqual(closedForPage, [], "not the page's doing")
        for name in ["w1", "w2", "w3"] { answers.release(name) }
        for watch in watches {
            watch.cancel()
            _ = await watch.result
        }
    }

    /// A watch never opens a browser sign-in: an oidc context is reached
    /// only once a request someone made has signed in.
    func testAWatchNeverSignsIn() async throws {
        let proxies = proxies()
        let oidc = Self.context("globex-eu-west-1-dev", auth: Self.oidc)
        do {
            _ = try await proxies.send(oidc, role: .watch, .GET, "/api/v1/pods")
            XCTFail("not signed in")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .needsPageSignIn)
            XCTAssertTrue(KubeProxyProblem.needsPageSignIn.reason.hasPrefix("Sign in on the page first"))
        }
        XCTAssertTrue(opened.values.isEmpty, "nothing started")
        XCTAssertEqual(answers.count(oidc.name), 0)
        let status = await proxies.status(of: oidc.name)
        XCTAssertEqual(status, .closed, "and it holds no sign-in turn")
        // The page signs in; then the watch rides on it.
        _ = try await proxies.send(oidc, .GET, "/api/v1/pods")
        let watched = try await proxies.send(oidc, role: .watch, .GET, "/api/v1/pods")
        XCTAssertEqual(watched.status, 200)
        // A context that signs in some other way is watched at once.
        let plain = try await proxies.send(Self.context("fake-dev"), role: .watch, .GET, "/")
        XCTAssertEqual(plain.status, 200)
    }

    /// Decision 26: when the page needs a slot, an idle background proxy
    /// goes before an idle one of another context the page used — and is
    /// noted as closed for the page.
    func testThePageClosesAnIdleBackgroundProxyBeforeAnIdleForegroundOne() async throws {
        let proxies = proxies(max: 3)
        _ = try await proxies.send(Self.context("a"), .GET, "/")
        clock.advance(1)
        _ = try await proxies.send(Self.context("bg"), role: .background, .GET, "/")
        clock.advance(1)
        _ = try await proxies.send(Self.context("b"), .GET, "/")
        clock.advance(1)
        // a was used longest ago, but it isn't the background's.
        _ = try await proxies.send(Self.context("c"), .GET, "/")
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["a", "b", "c"])
        XCTAssertEqual(closed.values, ["bg"])
        let evicted = await proxies.closedForPage
        XCTAssertEqual(evicted, ["bg"], "an idle background proxy closed for the page is noted too")
    }

    func testAnIdleProxyCloses() async throws {
        let proxies = proxies(idle: 600)
        _ = try await proxies.send(Self.context("a"), .GET, "/")
        answers.hold("b")
        let b = Self.context("b")
        let held = Task { try await proxies.send(b, .GET, "/") }
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

    /// An expired session's plugin waits minutes for a browser nobody saw
    /// (the spoke's `oidc-login`, gitops.md 14.12): a stand-in plugin that
    /// never answers, and after a short wait the page says what to run —
    /// never "unreachable", never a wait for minutes.
    func testASignInThatWaitsSaysToSignInAtATerminal() async throws {
        let proxies = proxies()
        let spoke = Self.context("globex-eu-west-1-prod", auth: Self.oidc)
        answers.hold(spoke.name)
        let waiting = Task { try await proxies.send(spoke, .GET, "/api") }
        try await until { self.answers.isHeld(spoke.name) }
        var status = await proxies.status(of: spoke.name)
        XCTAssertEqual(status, .signingIn, "at first, the browser's")
        clock.advance(KubeProxies.signInPatience - 1)
        status = await proxies.status(of: spoke.name)
        XCTAssertEqual(status, .signingIn)
        clock.advance(1)
        status = await proxies.status(of: spoke.name)
        XCTAssertEqual(status, .signInNeeded(context: spoke.name))
        XCTAssertEqual(status.reason, "Sign-in needed — run `kubectl --context globex-eu-west-1-prod get ns` once in a terminal")
        // Signed in at last: the page's next look is open.
        answers.release(spoke.name)
        _ = try await waiting.value
        status = await proxies.status(of: spoke.name)
        XCTAssertEqual(status, .open)
        XCTAssertEqual(KubeProxies.signInCommand("acme prod"), "kubectl --context 'acme prod' get ns", "quoted for zsh")
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
        _ = try await proxies.send(Self.context("fake-dev", writable: false), .GET, "/")
        _ = try await proxies.send(Self.context("fake-dev"), .GET, "/")
        _ = try await proxies.send(Self.context("fake-dev", writable: false), .GET, "/")
        XCTAssertEqual(opened.values.map(\.readOnly), [true, false, true])
        XCTAssertEqual(closed.values, ["fake-dev", "fake-dev"])
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["fake-dev"])
    }

    /// The proxies decide, not the copy (rule 1, "the guarantee is the
    /// socket's"): once told the context is read-only now, a session's
    /// stale writable copy — an attention watch reconnecting — gets the
    /// method filter, and its writes are refused.
    func testAStaleWritableCopyAfterTheListSaysReadOnlyKeepsTheMethodFilter() async throws {
        let proxies = proxies()
        let writable = Self.context("acme-dev", writable: true)
        await proxies.update(contexts: KubeContextList(contexts: [writable]))
        _ = try await proxies.send(writable, role: .watch, .GET, "/api/v1/pods?watch=1")
        XCTAssertEqual(opened.values.map(\.readOnly), [false])

        // Set `writable: false`: the writable proxy is closed as the list comes.
        let readOnly = Self.context("acme-dev", writable: false)
        await proxies.update(contexts: KubeContextList(contexts: [readOnly]))
        XCTAssertEqual(closed.values, ["acme-dev"], "a writable socket isn't kept for a read-only context")
        _ = try await proxies.send(readOnly, .GET, "/api/v1/pods")
        // The watch resumes with the copy it started with.
        _ = try await proxies.send(writable, role: .watch, .GET, "/api/v1/pods?watch=1")
        XCTAssertEqual(opened.values.map(\.readOnly), [false, true], "the stale copy neither reopens it writable nor flaps it")
        XCTAssertEqual(closed.values, ["acme-dev"])
        let isWritable = await proxies.isWritable(writable)
        XCTAssertFalse(isWritable)
        do {
            _ = try await proxies.sendWrite(writable, .DELETE, "/api/v1/namespaces/shop/pods/web", body: nil)
            XCTFail("a stale writable copy takes no write")
        } catch {
            XCTAssertTrue(error is KubeWriteRefused)
        }

        // Marked production by hand and set read-only: the same.
        let prod = KubeContext(
            name: "acme-dev", cluster: readOnly.cluster, server: readOnly.server, namespace: nil, user: readOnly.user, auth: readOnly.auth,
            file: nil, contextClass: .production, settings: KubeContextSettings(contextClass: .production, writable: false))
        await proxies.update(contexts: KubeContextList(contexts: [prod]))
        _ = try await proxies.send(writable, role: .watch, .GET, "/api/v1/pods?watch=1")
        XCTAssertEqual(opened.values.last?.readOnly, true)

        // A name the list no longer has: its proxy closed, a copy of it read-only.
        await proxies.update(contexts: KubeContextList(contexts: []))
        let connected = await proxies.connected
        XCTAssertEqual(connected, [])
        _ = try await proxies.send(writable, .GET, "/")
        XCTAssertEqual(opened.values.last?.readOnly, true)
    }

    /// A kubeconfig that points a name at another cluster with the same
    /// class: the running kubectl read the old one when it started, so the
    /// next request plans a new proxy — when the list is told, and when a
    /// copy alone says so.
    func testANameRepointedAtAnotherClusterGetsANewProxy() async throws {
        let proxies = proxies()
        let dev = Self.context("acme-dev", writable: true)
        let moved = KubeContext(
            name: dev.name, cluster: "globex-eks", server: "https://globex.example:443", namespace: nil, user: dev.user, auth: dev.auth,
            file: nil, contextClass: dev.contextClass, settings: dev.settings)
        // No list told: the copy says it.
        _ = try await proxies.send(dev, .GET, "/")
        _ = try await proxies.send(moved, .GET, "/")
        XCTAssertEqual(opened.values.count, 2, "a new proxy for the other cluster")
        XCTAssertEqual(closed.values, ["acme-dev"])

        // Told: closed as the list comes, metrics proxy included.
        await proxies.update(contexts: KubeContextList(contexts: [moved]))
        let service = KubePrometheusService(namespace: "monitoring", name: "prometheus", port: "9090")!
        _ = try await proxies.sendPrometheus(moved, service, service.queryPath + "?query=up")
        await proxies.update(contexts: KubeContextList(contexts: [dev]))
        XCTAssertEqual(closed.values, ["acme-dev", "acme-dev", "acme-dev"], "the proxy and the metrics proxy")
        _ = try await proxies.send(moved, .GET, "/")
        XCTAssertEqual(opened.values.count, 4, "planned again — for the context as the list has it")
        let isWritable = await proxies.isWritable(moved)
        XCTAssertFalse(isWritable, "a write reviewed on the other cluster is refused")
        let current = await proxies.isWritable(dev)
        XCTAssertTrue(current)
    }

    /// The list says read-only while a writable proxy is still being
    /// planned (actor reentrancy: `plan` is an await): the request that
    /// planned it ends, and no socket without the method filter is opened
    /// for a context the list now says is read-only.
    func testAListToldWhileAWritableProxyIsPlannedClosesIt() async throws {
        let planning = Answers()
        let proxies = proxies(planning: planning)
        let writable = Self.context("acme-dev", writable: true)
        await proxies.update(contexts: KubeContextList(contexts: [writable]))
        planning.hold("acme-dev")
        let request = Task { try await proxies.send(writable, role: .background, .GET, "/api/v1/pods") }
        try await until { planning.isHeld("acme-dev") }
        await proxies.update(contexts: KubeContextList(contexts: [Self.context("acme-dev", writable: false)]))
        planning.release("acme-dev")
        do {
            _ = try await request.value
            XCTFail("planned for a writable context the list no longer has")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .closedWhileOpening)
        }
        XCTAssertEqual(opened.values.map(\.readOnly), [], "no writable socket opened")
        let connected = await proxies.connected
        XCTAssertEqual(connected, [])
        _ = try await proxies.send(writable, role: .background, .GET, "/api/v1/pods")
        XCTAssertEqual(opened.values.map(\.readOnly), [true], "the next one has the method filter")
    }

    /// A name repointed at another cluster: the old server's version isn't
    /// the new one's kubectl's, nor is a credential failure the old user's.
    func testANameRepointedForgetsTheOldServersVersionAndStop() async throws {
        let plans = Recorder<Int?>()
        let proxies = proxies(plans: plans)
        let dev = Self.context("fake-dev")
        await proxies.update(contexts: KubeContextList(contexts: [dev]))
        answers.set("fake-dev", HTTPResponse(status: 200, headers: [], body: Data(#"{"major":"1","minor":"30+"}"#.utf8)))
        _ = try await proxies.send(dev, .GET, "/version")
        let moved = KubeContext(
            name: dev.name, cluster: "globex-eks", server: "https://globex.example:443", namespace: nil, user: dev.user, auth: dev.auth,
            file: nil, contextClass: dev.contextClass, settings: dev.settings)
        await proxies.update(contexts: KubeContextList(contexts: [moved]))
        _ = try await proxies.send(moved, .GET, "/version")
        XCTAssertEqual(plans.values, [nil, nil], "planned without the old server's minor")
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
        let c = Self.context("c")
        let one = Task { try await proxies.send(c, .GET, "/one") }
        try await until { self.closings.isWaiting("a") }
        let two = Task { try await proxies.send(c, .GET, "/two") }
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

    /// A person flips a context's Writes while its read-only proxy is
    /// still starting: the list closes that entry, the next request opens
    /// a writable one, then the read-only kubectl finishes and is ended.
    /// kubectl takes over whatever is at its path when it binds, and a
    /// closed proxy's socket is removed: on one path the writable proxy
    /// was left running with no socket, and every request to the context
    /// failed ("isn't answering") until it was closed as idle — the
    /// `kubernetes` scenario's Apply on fake-prod, after its Writes were
    /// set off and on again.
    func testWritesFlippedWhileAReadOnlyProxyStartsLeaveTheNewOneItsSocket() async throws {
        let folder = KubeSocketFolder(base: URL(fileURLWithPath: "/tmp/otkps-\(getpid())", isDirectory: true))
        let sockets = Sockets()
        let readOnlyOpening = Answers()
        readOnlyOpening.hold("ro")
        let proxies = KubeProxies(
            sweepEvery: .seconds(3600),
            plan: { context, _, _ in
                KubeProxySpec(
                    context: context.name, readOnly: !context.isWritable, kubectl: URL(fileURLWithPath: "/stand-in/kubectl"),
                    socket: try folder.socket(for: context.name, readOnly: !context.isWritable), environment: [:], cacheDirectory: nil,
                    signIn: KubeSignIn(context.auth))
            },
            open: { spec in
                if spec.readOnly { _ = await readOnlyOpening.answer("ro") }
                // As kubectl binds: whatever was at the path is replaced.
                let id = sockets.bind(spec.socket)
                let open = Flag(true)
                return KubeProxy(
                    context: spec.context, readOnly: spec.readOnly, signIn: spec.signIn, transport: SocketTransport(path: spec.socket, id: id, sockets: sockets),
                    isRunning: { open.value },
                    close: {
                        open.value = false
                        // As `ManagedProcess.close`: what is at its path is removed.
                        sockets.unlink(spec.socket)
                    })
            })
        let readOnly = Self.context("acme-prod", writable: false)
        let writable = Self.context("acme-prod")
        await proxies.update(contexts: KubeContextList(contexts: [readOnly]))
        let starting = Task { try await proxies.send(readOnly, .GET, "/api/v1/pods") }
        try await until { readOnlyOpening.isHeld("ro") }

        // Writes on again: the read-only entry is closed while it opens.
        await proxies.update(contexts: KubeContextList(contexts: [writable]))
        let first = try await proxies.send(writable, .GET, "/api/v1/pods")
        XCTAssertEqual(first.status, 200)
        readOnlyOpening.release("ro")
        do {
            _ = try await starting.value
            XCTFail("closed while it opened")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .closedWhileOpening)
        }

        let after = try await proxies.send(writable, .GET, "/api/v1/pods")
        XCTAssertEqual(after.status, 200, "the writable proxy still has its socket")
        XCTAssertNotEqual(
            try folder.socket(for: "acme-prod", readOnly: true), try folder.socket(for: "acme-prod"), "a read-only proxy's socket is never a writable one's")
    }

    /// The same race with the flags unchanged: a context's metrics proxy
    /// for one Prometheus Service still starting when a chart asks another
    /// Service's. Both are read-only; the second must not share the first's
    /// path, or the late one takes its socket and removes it when ended —
    /// each planned proxy has a number of its own (`proxySocket`), as the
    /// app's planner gives it.
    func testAnotherPrometheusWhileTheMetricsProxyStartsLeavesTheNewOneItsSocket() async throws {
        let folder = KubeSocketFolder(base: URL(fileURLWithPath: "/tmp/otkps-\(getpid())", isDirectory: true))
        let sockets = Sockets()
        let opening = Answers()
        opening.hold("old")
        let proxies = KubeProxies(
            sweepEvery: .seconds(3600),
            plan: { context, _, _ in
                KubeProxySpec(
                    context: context.name, readOnly: !context.isWritable, kubectl: URL(fileURLWithPath: "/stand-in/kubectl"),
                    socket: try folder.proxySocket(for: context.name, readOnly: !context.isWritable), environment: [:], cacheDirectory: nil,
                    signIn: KubeSignIn(context.auth))
            },
            open: { spec in
                if spec.prometheus?.name == "old" { _ = await opening.answer("old") }
                let id = sockets.bind(spec.socket)
                let open = Flag(true)
                return KubeProxy(
                    context: spec.context, readOnly: spec.readOnly, signIn: spec.signIn, transport: SocketTransport(path: spec.socket, id: id, sockets: sockets),
                    isRunning: { open.value },
                    close: {
                        open.value = false
                        sockets.unlink(spec.socket)
                    })
            })
        let context = Self.context("acme-dev")
        let old = try XCTUnwrap(KubePrometheusService(namespace: "monitoring", name: "old", port: "9090"))
        let new = try XCTUnwrap(KubePrometheusService(namespace: "monitoring", name: "new", port: "9090"))
        let starting = Task { try await proxies.sendPrometheus(context, old, old.queryPath) }
        try await until { opening.isHeld("old") }

        let first = try await proxies.sendPrometheus(context, new, new.queryPath)
        XCTAssertEqual(first.status, 200)
        opening.release("old")
        do {
            _ = try await starting.value
            XCTFail("closed while it opened")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .closedWhileOpening)
        }
        let after = try await proxies.sendPrometheus(context, new, new.queryPath)
        XCTAssertEqual(after.status, 200, "the new metrics proxy still has its socket")
    }

    /// Every proxy's path is its own: the number goes before `.sock`, and
    /// the metrics socket stays beside it.
    func testEachProxyHasAPathOfItsOwn() throws {
        let folder = KubeSocketFolder(base: URL(fileURLWithPath: "/tmp", isDirectory: true), uid: 501, pid: 7)
        let base = try folder.socket(for: "fake-dev", readOnly: true)
        let one = try KubeSocketFolder.socket(base, proxy: 1)
        let two = try KubeSocketFolder.socket(base, proxy: 2)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(one, String(base.dropLast(".sock".count)) + "-1.sock")
        XCTAssertEqual(try KubePrometheusFlags.socket(beside: one), String(base.dropLast(".sock".count)) + "-1-metrics.sock")
        let deep = String(repeating: "d", count: KubeSocketFolder.maxPathBytes - 6) + ".sock"
        XCTAssertThrowsError(try KubeSocketFolder.socket(deep, proxy: 123))
        XCTAssertNotEqual(
            try folder.proxySocket(for: "fake-dev", readOnly: false), try folder.proxySocket(for: "fake-dev", readOnly: false),
            "each planned proxy gets a number of its own")
    }

    /// A proxy closed while its first request waited for it to open ends
    /// that request with a reason to try again, leaves no entry behind that
    /// nothing could close, and ends the kubectl that finished opening.
    func testAProxyClosedWhileItOpenedEndsTheRequest() async throws {
        let proxies = proxies()
        openings.hold("x")
        let x = Self.context("x")
        let request = Task { try await proxies.send(x, role: .background, .GET, "/") }
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

    /// The Overview's pinned cards read in spare slots only: with
    /// `maxProxies` 2 and three pinned contexts, the one the background's
    /// slot can't hold is said not read — no proxy is closed for a card,
    /// cycle after cycle, so no kubectl (and no credential plugin) is
    /// started again and again.
    @MainActor
    func testPinnedCardsNeverCloseAProxy() async throws {
        let proxies = proxies(max: 2)
        _ = try await proxies.send(Self.context("page"), .GET, "/")
        let list = KubeContextList(contexts: ["p1", "p2", "page"].map { Self.context($0) }, current: "page")
        let session = KubePinnedHealthSession()
        session.interval = .milliseconds(30)
        session.show(
            pinned: ["p1", "p2", "page"], contexts: list, discovery: { _ in nil },
            target: { context in (KubeClient(KubeProxyConnection(proxies: proxies, context: context, role: .spare)), .namespace("shop")) })
        let deadline = Date().addingTimeInterval(5)
        while session.cards.contains(where: { $0.state == .waiting }) || answers.count("p1") < 3, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(answers.count("p1"), 3, "several cycles")
        XCTAssertEqual(session.cards.first { $0.context == "p2" }?.state, .notRead(KubePinnedHealthSession.noSlot))
        XCTAssertEqual(closed.values, [], "no proxy closed for a card")
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["p1", "page"])
        XCTAssertEqual(opened.values.map(\.context), ["page", "p1"], "each opened once")
        XCTAssertEqual(answers.count("p2"), 0, "nothing sent to the one with no slot")
        session.hide()
        // A request someone made still gets its slot: the spare one's is given up.
        clock.advance(1)
        _ = try await proxies.send(Self.context("agent"), role: .background, .GET, "/")
        XCTAssertEqual(closed.values, ["p1"])
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

/// Unix sockets' paths as kubectl and `ManagedProcess` treat them: a
/// bind replaces what was at the path, a close removes what is there.
private final class Sockets: @unchecked Sendable {
    private let lock = NSLock()
    private var bound: [String: Int] = [:]
    private var last = 0

    func bind(_ path: String) -> Int {
        lock.withLock {
            last += 1
            bound[path] = last
            return last
        }
    }

    func unlink(_ path: String) { lock.withLock { _ = bound.removeValue(forKey: path) } }
    func isBound(_ path: String, by id: Int) -> Bool { lock.withLock { bound[path] == id } }
}

/// A proxy's transport that reaches it only while its socket is at its path.
private struct SocketTransport: HTTPTransport {
    let path: String
    let id: Int
    let sockets: Sockets

    private func answer() throws -> HTTPResponse {
        guard sockets.isBound(path, by: id) else { throw HTTPError.unreachable("kubectl proxy isn't answering (No such file or directory).") }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
    }

    func send(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) async throws -> HTTPResponse { try answer() }

    func send(
        _ method: HTTPMethod, _ path: String, length: Int, body: @escaping @Sendable () async throws -> Data?, headers: [(String, String)],
        sent: @escaping @Sendable (Int) -> Void
    ) async throws -> HTTPResponse { try answer() }

    func receive(_ method: HTTPMethod, _ path: String, headers: [(String, String)], consume: (Data) async throws -> Void) async throws {
        try await consume(try answer().body)
    }

    func ready() async throws -> HTTPResponse { try answer() }

    func stream(_ method: HTTPMethod, _ path: String, body: Data?, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> {
        let answered = Result { try answer() }
        return AsyncThrowingStream { continuation in
            switch answered {
            case .success(let response): continuation.yield(response.body)
            case .failure(let error): continuation.finish(throwing: error)
            }
            continuation.finish()
        }
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
