import AppKit
import XCTest

@testable import Overterm

/// A pod's log (stage 1c): the default container, the queries built, the
/// pure pieces (lines out of bytes, older lines, the file's name, what an
/// agent is given), and — against `FakeKubeAPI` on a socket of the test's
/// own — a follow resumed across a dropped stream without a line twice or
/// one lost, older lines asked for with a larger tail, Previous, and the
/// follow stopping on a pod gone or a container that ended. Only GETs
/// reach the fake; the one subresource is `log`. Nothing reads ~/.kube.
@MainActor
final class KubePodLogTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkl-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests.filter { !$0.isLog }, [], "no subresource but a pod's log")
            api.stop()
        }
    }

    private var client: KubeClient { KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")) }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A session on the pod, read as its detail reads it.
    private func session(_ pod: String) async throws -> KubePodLogSession {
        let session = KubePodLogSession(namespace: "shop", pod: pod, client: client)
        session.podRead(try await client.object(.pods, namespace: "shop", name: pod).json)
        return session
    }

    private var logRequests: [FakeKubeAPI.Request] { api.requests.filter(\.isLog) }

    // MARK: Pure

    func testTheDefaultContainerIsTheAnnotatedOneElseTheFirst() {
        func pod(_ annotation: String?) -> [String: Any] {
            let metadata: [String: Any] = annotation.map { ["annotations": [KubePodContainers.defaultAnnotation: $0]] } ?? [:]
            let spec: [String: Any] = [
                "initContainers": [["name": "migrate"]], "containers": [["name": "app"], ["name": "proxy"]], "ephemeralContainers": [["name": "debugger"]],
            ]
            let app: [String: Any] = [
                "name": "app", "restartCount": 2, "state": ["running": [String: Any]()], "lastState": ["terminated": ["reason": "OOMKilled", "exitCode": 137]],
            ]
            let proxy: [String: Any] = ["name": "proxy", "restartCount": 0, "state": ["waiting": ["reason": "CrashLoopBackOff"]]]
            let migrate: [String: Any] = ["name": "migrate", "restartCount": 0, "state": ["terminated": ["reason": "Completed", "exitCode": 0]]]
            let status: [String: Any] = ["containerStatuses": [app, proxy], "initContainerStatuses": [migrate]]
            return ["metadata": metadata, "spec": spec, "status": status]
        }
        XCTAssertEqual(KubePodContainers.defaultContainer(pod("proxy")), "proxy", "the annotation's")
        XCTAssertEqual(KubePodContainers.defaultContainer(pod(nil)), "app", "else the first container — not the init one")
        XCTAssertEqual(KubePodContainers.defaultContainer(pod("gone")), "app", "an annotation naming none: the first, as kubectl does")
        let containers = KubePodContainers.of(pod(nil))
        XCTAssertEqual(containers.map(\.name), ["app", "proxy", "migrate", "debugger"], "containers, then init, then ephemeral")
        XCTAssertEqual(containers.map(\.role), [.container, .container, .initContainer, .ephemeral])
        XCTAssertEqual(containers[0].state, .running)
        XCTAssertEqual(containers[0].lastTerminated, "OOMKilled (exit 137)")
        XCTAssertTrue(containers[0].hasPrevious, "restarted: Previous is offered")
        XCTAssertFalse(containers[1].hasPrevious, "never restarted: no Previous")
        XCTAssertEqual(containers[1].state, .waiting("CrashLoopBackOff"))
        XCTAssertEqual(containers[2].state, .terminated(reason: "Completed", exitCode: 0))
        XCTAssertEqual(containers[3].state, .unknown, "no status yet")
        XCTAssertNil(KubePodContainers.defaultContainer(["spec": [:]]), "a pod with no containers has none")
    }

    func testTheQueries() {
        let first = KubePodLogSource.query(container: "app", previous: false, since: .hour, tail: 500, after: nil)
        XCTAssertEqual(
            first.path(namespace: "shop", pod: "web-7d9"),
            "/api/v1/namespaces/shop/pods/web-7d9/log?container=app&follow=true&sinceSeconds=3600&tailLines=500&timestamps=true",
            "followed, its tail, since as sinceSeconds, always with timestamps")
        let resumed = KubePodLogSource.query(container: "app", previous: false, since: .hour, tail: 500, after: "2026-11-04T10:00:07.123456789Z")
        XCTAssertEqual(
            resumed.path(namespace: "shop", pod: "web-7d9"),
            "/api/v1/namespaces/shop/pods/web-7d9/log?container=app&follow=true&sinceTime=2026-11-04T10%3A00%3A07Z&tailLines=5000&timestamps=true",
            "resumed: from the last line's second, never sinceSeconds with it, at most what the feed keeps")
        let previous = KubePodLogSource.query(container: "app", previous: true, since: .all, tail: 500, after: "2026-11-04T10:00:07Z")
        XCTAssertEqual(
            previous.path(namespace: "shop", pod: "web-7d9"), "/api/v1/namespaces/shop/pods/web-7d9/log?container=app&previous=true&tailLines=500&timestamps=true",
            "previous: read whole, not followed")
        XCTAssertEqual(
            KubeLogQuery(container: "a/b", tailLines: 10).path(namespace: "x y", pod: "p"),
            "/api/v1/namespaces/x%20y/pods/p/log?container=a%2Fb&tailLines=10&timestamps=true", "escaped")
        XCTAssertEqual(KubeLogQuery.sinceTime(after: "2026-11-04T10:00:07Z"), "2026-11-04T10:00:07Z")
        XCTAssertEqual(KubeLogSince.allCases.map(\.seconds), [300, 3600, 21600, 86400, nil])
    }

    func testWhetherAnEndedFollowIsFollowedAgain() {
        func pod(_ state: [String: Any], phase: String = "Running", policy: String = "Always", deleting: Bool = false) -> [String: Any] {
            let metadata: [String: Any] = deleting ? ["deletionTimestamp": "2026-11-04T10:00:00Z"] : [:]
            let spec: [String: Any] = ["containers": [["name": "app"]], "restartPolicy": policy]
            let status: [String: Any] = ["name": "app", "restartCount": 1, "state": state]
            return ["metadata": metadata, "spec": spec, "status": ["phase": phase, "containerStatuses": [status]] as [String: Any]]
        }
        XCTAssertEqual(KubeLogResume.of(pod: pod(["running": [String: Any]()]), container: "app"), .follow)
        XCTAssertEqual(KubeLogResume.of(pod: nil, container: "app"), .stop(KubeLogResume.podGone))
        guard case .wait = KubeLogResume.of(pod: pod(["waiting": ["reason": "CrashLoopBackOff"]]), container: "app") else {
            return XCTFail("a back-off is waited out")
        }
        guard case .wait = KubeLogResume.of(pod: pod(["terminated": ["reason": "Error", "exitCode": 1]]), container: "app") else {
            return XCTFail("ended, but it will be started again")
        }
        XCTAssertEqual(
            KubeLogResume.of(pod: pod(["terminated": ["reason": "Completed", "exitCode": 0]], phase: "Succeeded"), container: "app"),
            .stop("The container ended: Completed (exit 0)."))
        XCTAssertEqual(
            KubeLogResume.of(pod: pod(["terminated": ["reason": "Completed", "exitCode": 0]], policy: "OnFailure"), container: "app"),
            .stop("The container ended: Completed (exit 0)."), "OnFailure doesn't restart a success")
        XCTAssertEqual(KubeLogResume.of(pod: pod(["waiting": [String: Any]()], deleting: true), container: "app"), .stop("The pod is being deleted."))
        XCTAssertEqual(KubeLogResume.of(pod: pod(["running": [String: Any]()]), container: "gone"), .stop("The pod has no container gone any more."))
        XCTAssertEqual(KubePodLogSource.after(nil), .follow, "a stream that just ended")
        XCTAssertEqual(KubePodLogSource.after(KubeAPIError(status: 404, reason: "NotFound", message: "pods \"x\" not found")), .stop(KubeLogResume.podGone))
        XCTAssertEqual(KubePodLogSource.after(KubeAPIError(status: 400, reason: nil, message: "container app is not valid for pod x")), .stop("container app is not valid for pod x"))
        guard case .wait = KubePodLogSource.after(KubeAPIError(status: 400, reason: nil, message: "container \"app\" in pod \"x\" is waiting to start: ContainerCreating"))
        else { return XCTFail("a container not started yet is waited for") }
        XCTAssertEqual(KubePodLogSource.after(KubeProxyProblem.awsSignIn(profile: nil)), .stop(KubeProxyProblem.awsSignIn(profile: nil).reason))
        XCTAssertEqual(KubePodLogSource.after(KubeProxyProblem.unreachable("dial tcp")), .follow, "a blip is asked again")
    }

    private func line(_ stamp: String, _ message: String) -> LogLine {
        LogLine(stream: .stdout, timestamp: stamp, level: nil, message: message, fields: [], source: nil)
    }

    func testOlderLinesAreWhatComesBeforeTheFirstShown() {
        let all = (1...8).map { line("2026-11-04T10:00:0\($0)Z", $0 == 4 || $0 == 6 ? "same" : "l\($0)") }
        XCTAssertEqual(KubeLogText.older(all, than: Array(all[5...])).map(\.message), ["l1", "l2", "l3", "same", "l5"], "up to where the shown ones start")
        XCTAssertEqual(KubeLogText.older(all, than: []).count, 8, "nothing shown: all of them")
        // The first shown line said twice before it: matched with what follows it.
        let repeated = [line("2026-11-04T10:00:01Z", "x"), line("2026-11-04T10:00:01Z", "x"), line("2026-11-04T10:00:02Z", "y")]
        XCTAssertEqual(KubeLogText.older(repeated, than: Array(repeated[1...])).count, 1)
        // The shown lines aren't in the answer (it grew past them): those older than the first.
        XCTAssertEqual(KubeLogText.older(Array(all[0..<3]), than: [line("2026-11-04T10:00:09Z", "new")]).count, 3)
    }

    func testBytesAsLines() {
        var splitter = KubeLogText.Splitter()
        XCTAssertEqual(splitter.feed(Data("2026-11-04T10:00:01.5Z one\n2026-11-04T10:00:02Z tw".utf8)).map(\.message), ["one"])
        XCTAssertEqual(splitter.feed(Data("o\r\n2026-11-04T10:00:03Z {\"level\":\"error\",\"msg\":\"three\"}\n".utf8)).map(\.message), ["two", "three"])
        XCTAssertEqual(splitter.feed(Data("2026-11-04T10:00:04Z last".utf8)), [])
        let last = splitter.finish()
        XCTAssertEqual(last.map(\.message), ["last"], "a last line without its newline, at the end")
        XCTAssertEqual(last.first?.timestamp, "2026-11-04T10:00:04Z")
        XCTAssertEqual(KubeLogText.lines(Data("2026-11-04T10:00:03Z {\"level\":\"error\",\"msg\":\"three\"}\n".utf8)).first?.level, .error)
    }

    /// A bare `\r` (progress output), a form feed, U+2028 inside a kubelet
    /// line are its text: one line, one time — never a fragment whose first
    /// word ("Timeout") is taken for a time and resumed from.
    func testALineIsSplitAtNewlinesOnly() {
        var splitter = KubeLogText.Splitter()
        let bytes = Data("2026-11-04T10:00:01Z 10%\rTimeout reached\r\n2026-11-04T10:00:02Z page\u{0C}two\u{2028}Then more\n".utf8)
        let lines = splitter.feed(bytes)
        XCTAssertEqual(lines.count, 2, "\(lines.map(\.message))")
        XCTAssertEqual(lines.map(\.timestamp), ["2026-11-04T10:00:01Z", "2026-11-04T10:00:02Z"])
        XCTAssertEqual(lines.first?.message, "10%\rTimeout reached", "its trailing \\r dropped, the inner one kept")
        XCTAssertEqual(splitter.finish(), [])
        // A line's first word with a T in it is no time.
        XCTAssertNil(LogLine.parse("Timeout reached", stream: .stdout, timestamps: true).timestamp)
        XCTAssertEqual(LogLine.parse("Timeout reached", stream: .stdout, timestamps: true).message, "Timeout reached")
        XCTAssertNil(LogLine.parse("TLS handshake", stream: .stdout, timestamps: true).timestamp)
        XCTAssertEqual(LogLine.parse("2026-11-04T10:00:01.5Z up", stream: .stdout, timestamps: true).timestamp, "2026-11-04T10:00:01.5Z")
    }

    func testTheSavedFilesName() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        XCTAssertEqual(KubeLogText.fileName(pod: "web-7d9", container: "app", previous: false, at: date), "web-7d9-app-\(stamp).log")
        XCTAssertEqual(KubeLogText.fileName(pod: "web-7d9", container: "app", previous: true, at: date), "web-7d9-app-previous-\(stamp).log")
    }

    func testWhatAnAgentIsGivenIsScrubbed() {
        let env = KubeLogScrub.env(of: [
            "spec": ["containers": [["name": "app", "env": [["name": "DB_PASSWORD", "value": "hunter2-fake"], ["name": "MODE", "value": "prod"]]]]]
        ])
        let text = """
            connecting with hunter2-fake as web, mode prod
            GET /api Authorization: Bearer abc.def-ghi
            jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
            aws AKIAIOSFODNN7EXAMPLE secret aws_secret_access_key=wJalrXUtnFEMIfakeKEY
            token: abc123fake
            client-key-data: LS0tLS1CRUdJTiBQUklWQVRF
            password=s3cr3t-fake&user=web
            db postgres://web:pw-fake@db:5432/shop
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEAfake
            -----END RSA PRIVATE KEY-----
            """
        let scrubbed = KubeLogScrub.scrub(text, env: env)
        for secret in [
            "hunter2-fake", "abc.def-ghi", "eyJhbGciOiJIUzI1NiJ9", "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMIfakeKEY", "abc123fake", "LS0tLS1CRUdJTiBQUklWQVRF", "s3cr3t-fake", "pw-fake",
            "MIIEowIBAAKCAQEAfake",
        ] {
            XCTAssertFalse(scrubbed.contains(secret), "\(secret) taken out of:\n\(scrubbed)")
        }
        for kept in ["connecting with", "mode prod", "GET /api", "user=web", "postgres://web:", "@db:5432/shop", "-----BEGIN RSA PRIVATE KEY-----"] {
            XCTAssertTrue(scrubbed.contains(kept), "\(kept) kept in:\n\(scrubbed)")
        }
        XCTAssertEqual(env.map(\.key), ["DB_PASSWORD", "MODE"], "plain values only")
    }

    /// The search: plain text (case aside), a regular expression, or
    /// marking what matches with every line kept.
    func testTheSearchIsTextARegularExpressionOrAHighlight() {
        let lines = ["GET /health 200", "GET /cart 500", "POST /cart 201", "worker ready"].map { line("2026-11-04T10:00:01Z", $0) }
        func shown(_ filter: LogFilter) -> [String] {
            let matcher = filter.matcher()
            return lines.filter(matcher.matches).map(\.message)
        }
        XCTAssertEqual(shown(LogFilter(text: "cart")), ["GET /cart 500", "POST /cart 201"])
        XCTAssertEqual(shown(LogFilter(text: "^(get|post) /cart [25]0\\d$", regex: true)), ["GET /cart 500", "POST /cart 201"], "a regular expression, case aside")
        XCTAssertEqual(shown(LogFilter(text: "/cart [25]0", regex: false)), [], "plain text: its brackets are text")
        let bad = LogFilter(text: "(unclosed", regex: true)
        XCTAssertEqual(bad.problem, "Not a regular expression")
        XCTAssertEqual(shown(bad).count, 4, "one that isn't picks nothing out")
        let marking = LogFilter(text: "cart", highlight: true)
        XCTAssertTrue(marking.isEmpty, "marking, the text picks nothing out")
        XCTAssertEqual(shown(marking).count, 4)
        let drawn = LogStyle.line(lines[1], text: .white, dim: .gray, timestamps: false, highlight: marking.expression)
        var marked: [String] = []
        drawn.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: drawn.length)) { value, range, _ in
            if value != nil { marked.append((drawn.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(marked, ["cart"], "its match marked")
        XCTAssertEqual(LogFilter(text: "a.c", regex: false).expression?.pattern, NSRegularExpression.escapedPattern(for: "a.c"))
    }

    func testNewestFirstDrawsTheLinesReversed() {
        let lines = ["one", "two", "three"].map { NSAttributedString(string: $0) }
        XCTAssertEqual(LogTextView.joined(lines).string, "one\ntwo\nthree")
        XCTAssertEqual(LogTextView.joined(lines, reversed: true).string, "three\ntwo\none")
    }

    func testCopyAsKubectlForALog() {
        XCTAssertEqual(
            KubectlLine.logs(context: "fake-dev", namespace: "shop", pod: "web-7d9", container: "app", previous: true, since: .hour, timestamps: true),
            "kubectl --context fake-dev -n shop logs web-7d9 -c app --previous --since=1h --timestamps")
        XCTAssertEqual(
            KubectlLine.logs(context: "fake-dev", namespace: "shop", pod: "web-7d9", container: nil, previous: false, since: .all, timestamps: false),
            "kubectl --context fake-dev -n shop logs web-7d9")
    }

    // MARK: Against the fake

    /// "Logs from Here" on a pod that logged more than the feed keeps
    /// since the spike: the lines from that time come — the head, read
    /// once, not the newest since — and the note says ours was the limit.
    func testLogsFromHereKeepsTheHeadOfALogLongerThanTheFeed() async throws {
        api.addPod("web-7d9", namespace: "shop")
        let end = Date().addingTimeInterval(-5)
        api.setLog("web-7d9", namespace: "shop", (0..<6000).map { "line \($0)" }, until: end)
        let session = try await session("web-7d9")
        session.show(since: .all)
        // From the 100th line's second.
        let from = end.addingTimeInterval(Double(100 - 5999))
        session.read(from: from, container: "app")
        let read = await eventually(10) { session.feed.lines.count == LogFeed.keep && session.fromCut }
        XCTAssertTrue(read, "\(session.feed.lines.count) lines, cut \(session.fromCut), \(session.reading)")
        XCTAssertEqual(session.feed.lines.first?.message, "line 100", "the lines from that time, not the newest since")
        XCTAssertEqual(session.feed.lines.last?.message, "line 5099")
        let ended = await eventually { session.reading == .ended(nil) }
        XCTAssertTrue(ended, "read once, not followed: \(session.reading)")
        let asked = try XCTUnwrap(logRequests.last)
        XCTAssertNil(asked.query["tailLines"], "\(asked.query)")
        XCTAssertNil(asked.query["follow"], "\(asked.query)")
        XCTAssertEqual(asked.query["limitBytes"], String(KubePodLogSource.fromReadBytes))
        XCTAssertEqual(api.openLogStreams, 0, "nothing left open")
        session.clearFrom()
        XCTAssertFalse(session.fromCut, "the whole log again: nothing cut")
        session.cancel()
    }

    /// The stream dropped (the connection closed with no end): resumed
    /// from the last line's second, the lines that second said again
    /// dropped — but one of the same time and other text, written while it
    /// was down, kept — and nothing written meanwhile lost.
    func testAFollowResumesAcrossADroppedStreamWithoutDuplicatesOrGaps() async throws {
        api.addPod("web-7d9", namespace: "shop")
        let base = Date().addingTimeInterval(-30).timeIntervalSince1970.rounded(.down)
        for index in 1...3 { api.appendLog("web-7d9", namespace: "shop", "line \(index)", at: Date(timeIntervalSince1970: base + Double(index) + 0.25)) }
        let session = try await session("web-7d9")
        XCTAssertEqual(session.container, "app")
        session.show(since: .all)
        session.source?.retryDelay = .milliseconds(20)
        let first = await eventually { session.feed.lines.count == 3 && session.feed.following }
        XCTAssertTrue(first, "\(session.feed.lines.map(\.message))")
        let same = Date(timeIntervalSince1970: base + 4.5)
        api.appendLog("web-7d9", namespace: "shop", "line 4", at: same)
        let followed = await eventually { session.feed.lines.count == 4 }
        XCTAssertTrue(followed, "a line appended comes by the follow")
        XCTAssertEqual(api.dropLogStreams(), 1)
        // Written while it was down: one at the very time of the last shown, others after.
        api.appendLog("web-7d9", namespace: "shop", "line 4b", at: same)
        api.appendLog("web-7d9", namespace: "shop", "line 5", at: Date(timeIntervalSince1970: base + 4.75))
        api.appendLog("web-7d9", namespace: "shop", "line 6", at: Date(timeIntervalSince1970: base + 6))
        let resumed = await eventually { session.feed.lines.count >= 7 && session.source?.resumes == 1 }
        XCTAssertTrue(resumed, "\(session.feed.lines.map(\.message)) \(session.reading)")
        XCTAssertEqual(session.feed.lines.map(\.message), ["line 1", "line 2", "line 3", "line 4", "line 4b", "line 5", "line 6"], "each once, in order")
        let followAgain = await eventually { self.api.openLogStreams == 1 }
        XCTAssertTrue(followAgain)
        api.appendLog("web-7d9", namespace: "shop", "line 7", at: Date(timeIntervalSince1970: base + 7))
        let more = await eventually { session.feed.lines.last?.message == "line 7" }
        XCTAssertTrue(more, "followed on")
        let asked = logRequests
        XCTAssertEqual(asked.count, 2, "\(asked.map(\.query))")
        XCTAssertEqual(asked.first?.query["tailLines"], "500")
        XCTAssertEqual(asked.last?.query["sinceTime"], KubeLogQuery.sinceTime(after: FakeKubeAPI.nanoStamp(same)), "from the last line's second")
        XCTAssertEqual(asked.last?.query["tailLines"], "\(LogFeed.keep)", "capped at what the feed keeps")
        XCTAssertNil(asked.last?.query["sinceSeconds"])
        XCTAssertTrue(asked.allSatisfy { $0.query["timestamps"] == "true" && $0.query["container"] == "app" && $0.query["follow"] == "true" })
        XCTAssertEqual(session.feed.lines.count, Set(session.feed.lines.map { "\($0.timestamp ?? "") \($0.message)" }).count, "nothing twice")
        session.hide()
        let closed = await eventually { self.api.openLogStreams == 0 }
        XCTAssertTrue(closed, "hidden, its stream closes")
        XCTAssertFalse(session.feed.following)
    }

    /// Scrolled to the top: asked again with twice the tail, the older
    /// lines put in front, until the log's start.
    func testOlderLinesOnScrollUp() async throws {
        api.addPod("web-7d9", namespace: "shop")
        let base = Date().addingTimeInterval(-3600).timeIntervalSince1970.rounded(.down)
        for index in 1...1200 { api.appendLog("web-7d9", namespace: "shop", "line \(index)", at: Date(timeIntervalSince1970: base + Double(index))) }
        let session = try await session("web-7d9")
        session.show(since: .all)
        let first = await eventually { session.feed.lines.count == 500 }
        XCTAssertTrue(first, "\(session.feed.lines.count)")
        XCTAssertEqual(session.feed.lines.first?.message, "line 701")
        let prepended = session.feed.prepended
        session.loadOlder()
        let more = await eventually { session.feed.lines.count == 1000 && !session.loadingOlder }
        XCTAssertTrue(more, "\(session.feed.lines.count)")
        XCTAssertEqual(session.feed.lines.first?.message, "line 201")
        XCTAssertEqual(session.feed.prepended, prepended + 1, "the view keeps its place")
        XCTAssertFalse(session.reachedStart)
        session.loadOlder()
        let all = await eventually { session.feed.lines.count == 1200 && !session.loadingOlder }
        XCTAssertTrue(all, "\(session.feed.lines.count)")
        XCTAssertTrue(session.reachedStart, "fewer than asked: the start")
        XCTAssertEqual(session.feed.lines.map(\.message), (1...1200).map { "line \($0)" }, "every line once, in order")
        let tails = logRequests.filter { $0.query["follow"] == nil }.map { $0.query["tailLines"] }
        XCTAssertEqual(tails, ["1000", "2000"])
        session.loadOlder()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(logRequests.filter { $0.query["follow"] == nil }.count, 2, "nothing more is asked for")
        session.cancel()
    }

    /// Deleted: its stream ends, the pod is asked for once, and the log
    /// says it's gone — no follow again.
    func testAFollowStopsOnAGonePod() async throws {
        api.addPod("web-7d9", namespace: "shop")
        api.setLog("web-7d9", namespace: "shop", ["one", "two"])
        let session = try await session("web-7d9")
        session.show(since: .all)
        session.source?.retryDelay = .milliseconds(20)
        let following = await eventually { session.feed.lines.count == 2 && self.api.openLogStreams == 1 }
        XCTAssertTrue(following)
        api.deletePod("web-7d9", namespace: "shop")
        let ended = await eventually { session.reading == .ended(KubeLogResume.podGone) }
        XCTAssertTrue(ended, "\(session.reading)")
        XCTAssertFalse(session.feed.following)
        XCTAssertEqual(session.feed.lines.map(\.message), ["one", "two"], "what it showed stays")
        let count = api.requests.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(api.requests.count, count, "nothing more is asked")
        XCTAssertEqual(logRequests.count, 1)
    }

    /// A container that ended for good (the pod Succeeded): not followed again.
    func testAFollowStopsWhenTheContainerEnded() async throws {
        api.addPod("job-1", namespace: "shop")
        api.setLog("job-1", namespace: "shop", ["working", "done"])
        let session = try await session("job-1")
        session.show(since: .fiveMinutes)
        session.source?.retryDelay = .milliseconds(20)
        let following = await eventually { session.feed.lines.count == 2 && self.api.openLogStreams == 1 }
        XCTAssertTrue(following)
        XCTAssertEqual(logRequests.first?.query["sinceSeconds"], "300", "since as sinceSeconds")
        api.updatePod("job-1", namespace: "shop") {
            $0.terminatedReason = "Completed"
            $0.phase = "Succeeded"
        }
        api.endLogStreams()
        let ended = await eventually { session.reading == .ended("The container ended: Completed (exit 0).") }
        XCTAssertTrue(ended, "\(session.reading)")
        XCTAssertEqual(logRequests.count, 1, "not followed again")
    }

    /// Previous: the crashed instance's whole log, not followed; a
    /// container picked: its own log, from the start.
    func testPreviousAndAnotherContainer() async throws {
        var pod = FakeKubeAPI.Pod(status: "CrashLoopBackOff", ready: 0, containers: 2, restarts: 3)
        pod.initContainers = ["migrate"]
        api.addPod("worker-5c", namespace: "shop", pod, annotations: [KubePodContainers.defaultAnnotation: "sidecar-1"])
        api.setLog("worker-5c", namespace: "shop", container: "app", ["booting", "panic: out of cheese"], previous: true)
        api.setLog("worker-5c", namespace: "shop", container: "app", ["booting again"])
        api.setLog("worker-5c", namespace: "shop", container: "sidecar-1", ["proxy up"])
        api.setLog("worker-5c", namespace: "shop", container: "migrate", ["migrated"])
        let session = try await session("worker-5c")
        XCTAssertEqual(session.container, "sidecar-1", "the annotated container first")
        XCTAssertEqual(session.containers.map(\.name), ["app", "sidecar-1", "migrate"])
        session.show(since: .all)
        let sidecar = await eventually { session.feed.lines.map(\.message) == ["proxy up"] }
        XCTAssertTrue(sidecar, "\(session.feed.lines.map(\.message))")
        session.pick(previous: true)
        XCTAssertFalse(session.previous, "the sidecar never restarted: no Previous")
        session.pick(container: "app")
        let app = await eventually { session.feed.lines.map(\.message) == ["booting again"] }
        XCTAssertTrue(app, "\(session.feed.lines.map(\.message))")
        session.pick(previous: true)
        XCTAssertTrue(session.previous)
        let crashed = await eventually { session.feed.lines.map(\.message) == ["booting", "panic: out of cheese"] && session.reading == .ended(nil) }
        XCTAssertTrue(crashed, "\(session.feed.lines.map(\.message)) \(session.reading)")
        let previous = logRequests.last
        XCTAssertEqual(previous?.query["previous"], "true")
        XCTAssertNil(previous?.query["follow"], "the crashed one's log isn't followed")
        session.pick(container: "migrate")
        XCTAssertFalse(session.previous, "another container: its current log")
        let migrate = await eventually { session.feed.lines.map(\.message) == ["migrated"] }
        XCTAssertTrue(migrate)
        session.cancel()
        // Without a container, a pod with two is refused, as the server refuses it.
        do {
            _ = try await client.logLines(namespace: "shop", pod: "worker-5c", query: KubeLogQuery())
            XCTFail("a container is needed")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.message.hasPrefix("a container name must be specified"), error.message)
        }
    }

    /// A server (or proxy) that closes every follow as it opens, while the
    /// pod reads Running: followed again, waiting longer each time — a few
    /// requests, not one every retry delay — and back to the short wait
    /// once a stream stays open.
    func testFollowsThatEndAtOnceBackOff() async throws {
        api.addPod("web-7d9", namespace: "shop")
        api.setLog("web-7d9", namespace: "shop", ["one"])
        api.endFollowsAtOnce = true
        let session = try await session("web-7d9")
        session.show(since: .all)
        let source = try XCTUnwrap(session.source)
        source.retryDelay = .milliseconds(20)
        source.maxRetryDelay = .milliseconds(400)
        source.steadyAfter = .milliseconds(300)
        let shown = await eventually { session.feed.lines.map(\.message) == ["one"] }
        XCTAssertTrue(shown)
        try await Task.sleep(for: .milliseconds(1500))
        // 20, 40, 80, 160, 320, then 400 ms: about 8 in 1.5 s — 75 without the backoff.
        let asked = logRequests.count
        XCTAssertGreaterThan(asked, 2, "followed again")
        XCTAssertLessThanOrEqual(asked, 12, "\(asked) follows in 1.5 s: the waits grow")
        XCTAssertLessThanOrEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods/web-7d9" }.count, 12)
        XCTAssertEqual(session.feed.lines.map(\.message), ["one"], "nothing twice")
        // It stays open now: the stream after a steady one is asked for at once again.
        api.endFollowsAtOnce = false
        let open = await eventually(3) { self.api.openLogStreams == 1 }
        XCTAssertTrue(open)
        try await Task.sleep(for: .milliseconds(400))
        let before = logRequests.count
        api.dropLogStreams()
        let again = await eventually(1) { self.logRequests.count > before && self.api.openLogStreams == 1 }
        XCTAssertTrue(again, "after a steady stream, the short wait")
        session.cancel()
    }

    /// A container that crashes and restarts while its log is followed:
    /// the pod read to resume it updates the tab's containers — Previous
    /// is offered, its restarts said — the container picked kept.
    func testAPodReadOnResumeUpdatesTheContainers() async throws {
        api.addPod("web-7d9", namespace: "shop", FakeKubeAPI.Pod(ready: 2, containers: 2))
        api.setLog("web-7d9", namespace: "shop", container: "sidecar-1", ["proxy up"])
        let session = try await session("web-7d9")
        session.pick(container: "sidecar-1")
        session.show(since: .all)
        session.source?.retryDelay = .milliseconds(20)
        let following = await eventually { session.feed.lines.count == 1 && self.api.openLogStreams == 1 }
        XCTAssertTrue(following)
        XCTAssertEqual(session.containers.first?.hasPrevious, false)
        api.updatePod("web-7d9", namespace: "shop") { $0.restarts = 1 }
        api.endLogStreams(of: "web-7d9", namespace: "shop")
        let updated = await eventually { session.containers.first?.restarts == 1 && self.api.openLogStreams == 1 }
        XCTAssertTrue(updated, "\(session.containers)")
        XCTAssertEqual(session.containers.first?.hasPrevious, true, "Previous offered once it restarted")
        XCTAssertEqual(session.containers.first?.lastTerminated, "Error (exit 1)")
        XCTAssertEqual(session.container, "sidecar-1", "the container picked kept")
        session.cancel()
    }
}
