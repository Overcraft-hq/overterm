import Combine
import XCTest

@testable import Overterm

/// A workload's merged logs (stage 2e, stern's way): the plan — the cap,
/// streams kept in place, a pod joining, the include and exclude
/// expressions — the merge on timestamps across sources, and against
/// `FakeKubeAPI` on a socket of the test's own: two pods merged by time,
/// a new pod joining from the watch, a pod gone with its stream closed,
/// the cap, the expressions, nothing read while hidden and a resume
/// without a line twice. Only GETs reach the fake; the one subresource is
/// `log`. Nothing reads ~/.kube.
@MainActor
final class KubeMergedLogTests: XCTestCase {
    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkm-\(UInt32.random(in: 0...UInt32.max)).sock"
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

    private func line(_ stamp: String, _ message: String, source: String? = nil) -> LogLine {
        LogLine(stream: .stdout, timestamp: stamp, level: nil, message: message, fields: [], source: source)
    }

    private func session(cap: Int = 10, capChanged: AnyPublisher<Void, Never>? = nil) -> (KubeMergedLogSession, Box) {
        let box = Box(cap)
        let session = KubeMergedLogSession(
            context: "fake-dev", namespace: "shop", selector: "app=api", title: "deployment/api", client: client, cap: { box.value },
            capChanged: capChanged)
        session.retryDelay = .milliseconds(20)
        return (session, box)
    }

    private final class Box {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    // MARK: Pure

    /// Two sources' batches, each in time order, merged among each other —
    /// a later batch with older lines put where they go, not at the end;
    /// equal times keep the order they came in.
    func testTheMergeIsOnTimestampsAcrossSources() {
        let feed = LogFeed()
        feed.merge([line("2026-11-06T10:00:01Z", "a1", source: "api-1/app"), line("2026-11-06T10:00:03Z", "a3", source: "api-1/app")])
        feed.merge([line("2026-11-06T10:00:02.5Z", "b2", source: "api-2/app"), line("2026-11-06T10:00:04Z", "b4", source: "api-2/app")])
        XCTAssertEqual(feed.lines.map(\.message), ["a1", "b2", "a3", "b4"])
        // A fraction's trailing zeros trimmed (Go's RFC 3339 nano) still sorts by time.
        feed.merge([line("2026-11-06T10:00:02.12Z", "c", source: "api-3/app")])
        XCTAssertEqual(feed.lines.map(\.message), ["a1", "c", "b2", "a3", "b4"])
        feed.merge([line("2026-11-06T10:00:04Z", "a4", source: "api-1/app")])
        XCTAssertEqual(feed.lines.last?.message, "a4", "the same time: after the one in already")
        XCTAssertEqual(feed.lines.map { $0.source ?? "" }, ["api-1/app", "api-3/app", "api-2/app", "api-1/app", "api-2/app", "api-1/app"])
    }

    /// A stream's lines tagged with whose they are, the line parts applied.
    func testAStreamsLinesAreTaggedAndFiltered() async throws {
        var filter = KubeMergedLogFilter()
        filter.lines = "error|warn"
        filter.excludeLines = "healthz"
        let (stream, continuation) = AsyncThrowingStream<[LogLine], any Error>.makeStream()
        continuation.yield([line("2026-11-06T10:00:01Z", "ERROR boom"), line("2026-11-06T10:00:02Z", "ok"), line("2026-11-06T10:00:03Z", "warn healthz")])
        continuation.yield([LogLine.parse(#"2026-11-06T10:00:04Z {"msg":"slow","reason":"timeout warning"}"#, stream: .stdout, timestamps: true)])
        continuation.finish()
        var out: [LogLine] = []
        for try await lines in KubeMergedLogSource.tagged(stream, source: "api-1/app", filter: filter) { out += lines }
        XCTAssertEqual(out.map(\.message), ["ERROR boom", "slow"], "a JSON line's fields are matched too")
        XCTAssertTrue(out.allSatisfy { $0.source == "api-1/app" })
    }

    func testTheFiltersExpressions() {
        var filter = KubeMergedLogFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertTrue(filter.picks(pod: "anything"))
        filter.pods = "^api-"
        filter.excludePods = "canary"
        XCTAssertTrue(filter.picks(pod: "API-7d9-x"), "case aside")
        XCTAssertFalse(filter.picks(pod: "web-1"))
        XCTAssertFalse(filter.picks(pod: "api-canary-1"))
        filter.containers = "^app$"
        XCTAssertTrue(filter.picks(container: "app"))
        XCTAssertFalse(filter.picks(container: "sidecar-1"))
        XCTAssertEqual(filter.count, 3)
        XCTAssertNil(filter.problem)
        filter.lines = "(unclosed"
        XCTAssertEqual(filter.problem, "Lines: not a regular expression")
    }

    /// The cap, streams open keeping their place, a pod joining, pods not
    /// read yet read while there is room, the filter's pods and containers.
    func testThePlan() {
        typealias Key = KubeLogStreamKey
        let two: [(name: String, containers: [String]?)] = [("api-b", ["app"]), ("api-a", ["app", "sidecar-1"])]
        var plan = KubeMergedLogPlan.plan(pods: two, following: [], cap: 10, filter: KubeMergedLogFilter())
        XCTAssertEqual(plan.streams, [Key(pod: "api-a", container: "app"), Key(pod: "api-a", container: "sidecar-1"), Key(pod: "api-b", container: "app")])
        XCTAssertEqual(plan.total, 3)
        XCTAssertEqual(plan.capped, 0)
        // Capped: by the pods' order, the rest said.
        plan = KubeMergedLogPlan.plan(pods: two, following: [], cap: 2, filter: KubeMergedLogFilter())
        XCTAssertEqual(plan.streams, [Key(pod: "api-a", container: "app"), Key(pod: "api-a", container: "sidecar-1")])
        XCTAssertEqual(plan.capped, 1)
        // A pod joins, one that sorts first: it takes no stream open now.
        let open: Set<Key> = [Key(pod: "api-b", container: "app"), Key(pod: "api-c", container: "app")]
        let three: [(name: String, containers: [String]?)] = [("api-c", ["app"]), ("api-b", ["app"]), ("api-0", ["app"])]
        plan = KubeMergedLogPlan.plan(pods: three, following: open, cap: 2, filter: KubeMergedLogFilter())
        XCTAssertEqual(plan.streams, [Key(pod: "api-b", container: "app"), Key(pod: "api-c", container: "app")])
        XCTAssertEqual(plan.capped, 1)
        // One goes: the one left out takes its place.
        plan = KubeMergedLogPlan.plan(pods: Array(three.dropFirst()), following: open, cap: 2, filter: KubeMergedLogFilter())
        XCTAssertEqual(plan.streams, [Key(pod: "api-0", container: "app"), Key(pod: "api-b", container: "app")])
        // Not read yet: read while there is room, counted as one.
        let unread: [(name: String, containers: [String]?)] = [("api-a", ["app"]), ("api-b", nil), ("api-c", nil), ("api-d", nil)]
        plan = KubeMergedLogPlan.plan(pods: unread, following: [], cap: 3, filter: KubeMergedLogFilter())
        XCTAssertEqual(plan.streams, [Key(pod: "api-a", container: "app")])
        XCTAssertEqual(plan.fetch, ["api-b", "api-c"])
        XCTAssertEqual(plan.total, 4)
        XCTAssertEqual(plan.capped, 1)
        // The filter: a pod left out, a container left out — none takes a stream.
        var filter = KubeMergedLogFilter()
        filter.excludePods = "api-b"
        filter.containers = "^app$"
        plan = KubeMergedLogPlan.plan(pods: two, following: [], cap: 10, filter: filter)
        XCTAssertEqual(plan.streams, [Key(pod: "api-a", container: "app")])
        XCTAssertEqual(plan.total, 1)
        // A cap under one is one.
        XCTAssertEqual(KubeMergedLogPlan.plan(pods: two, following: [], cap: 0, filter: KubeMergedLogFilter()).streams.count, 1)
    }

    func testCopyAsKubectlForAMergedLog() {
        XCTAssertEqual(
            KubectlLine.mergedLogs(context: "fake-dev", namespace: "shop", selector: "app=api,tier in (web)", streams: 10, since: .hour, timestamps: true),
            "kubectl --context fake-dev -n shop logs -l 'app=api,tier in (web)' --all-containers --prefix --max-log-requests=10 --since=1h --timestamps")
    }

    /// A workload, a Job and a Service have a Logs tab; a ConfigMap hasn't.
    func testWhichDetailsHaveMergedLogs() {
        func ref(_ group: String, _ resource: String) -> KubeObjectRef {
            KubeObjectRef(
                context: "fake-dev", kind: KubeResourceKind(group: group, version: "v1", resource: resource, kind: "", singular: "", namespaced: true, verbs: []),
                namespace: "shop", name: "x")
        }
        for (group, resource) in [("apps", "deployments"), ("apps", "statefulsets"), ("apps", "daemonsets"), ("apps", "replicasets"), ("batch", "jobs"), ("", "services")] {
            XCTAssertTrue(ref(group, resource).selectsPods, resource)
            XCTAssertEqual(KubeDetailTab.tabs(for: ref(group, resource)), [.overview, .logs, .yaml, .events], resource)
        }
        XCTAssertFalse(ref("", "configmaps").hasLogs)
        XCTAssertFalse(ref("batch", "cronjobs").hasLogs)
        XCTAssertFalse(ref("", "pods").selectsPods)
        XCTAssertTrue(ref("", "pods").hasLogs)
    }

    // MARK: Against the fake

    /// Two pods merged on their timestamps, each line tagged; a pod that
    /// joins gets a stream from the watch; one deleted has its stream
    /// closed; only the selector's pods, their containers each.
    func testTwoPodsMergedOnTimestampsAndPodsJoiningAndGoing() async throws {
        api.addPod("api-1", namespace: "shop", labels: ["app": "api"])
        api.addPod("api-2", namespace: "shop", FakeKubeAPI.Pod(containers: 2), labels: ["app": "api"])
        api.addPod("web-1", namespace: "shop", labels: ["app": "web"])
        let base = Date().addingTimeInterval(-60).timeIntervalSince1970.rounded(.down)
        func at(_ offset: Double) -> Date { Date(timeIntervalSince1970: base + offset) }
        api.appendLog("api-1", namespace: "shop", "one", at: at(1))
        api.appendLog("api-2", namespace: "shop", "two", at: at(2))
        api.appendLog("api-1", namespace: "shop", "three", at: at(3))
        api.appendLog("api-2", namespace: "shop", container: "sidecar-1", "four", at: at(4))
        api.appendLog("api-2", namespace: "shop", "five", at: at(5))
        api.appendLog("web-1", namespace: "shop", "not the selector's", at: at(2.5))
        let (session, _) = session()
        session.show(since: .all)
        let merged = await eventually { session.feed.lines.count == 5 }
        XCTAssertTrue(merged, "\(session.feed.lines.map(\.message)) \(session.problem ?? "")")
        XCTAssertEqual(session.feed.lines.map(\.message), ["one", "two", "three", "four", "five"], "merged by time")
        XCTAssertEqual(session.feed.lines.map { $0.source ?? "" }, ["api-1/app", "api-2/app", "api-1/app", "api-2/sidecar-1", "api-2/app"])
        XCTAssertEqual(session.sources, ["api-1/app", "api-2/app", "api-2/sidecar-1"])
        let open = await eventually { self.api.openLogStreams == 3 && session.feed.following }
        XCTAssertTrue(open)
        XCTAssertEqual(api.openLogFollows, ["shop/api-1/app", "shop/api-2/app", "shop/api-2/sidecar-1"])
        XCTAssertTrue(api.requests.contains { $0.isWatch && $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=api" })
        XCTAssertEqual(session.summary, "3 containers of 2 pods followed · at most 10 at once (kubernetes.logStreams)")

        // Followed: a line comes where it goes.
        api.appendLog("api-1", namespace: "shop", "six", at: at(6))
        let followed = await eventually { session.feed.lines.last?.message == "six" }
        XCTAssertTrue(followed)

        // A new pod joins: its stream opens, its lines merged in.
        api.addPod("api-3", namespace: "shop", labels: ["app": "api"])
        api.appendLog("api-3", namespace: "shop", "from the new one", at: at(5.5))
        let joined = await eventually { self.api.openLogStreams == 4 && session.feed.lines.contains { $0.message == "from the new one" } }
        XCTAssertTrue(joined, "\(api.openLogFollows) \(session.feed.lines.map(\.message))")
        XCTAssertEqual(session.feed.lines.map(\.message), ["one", "two", "three", "four", "five", "from the new one", "six"])
        XCTAssertEqual(session.pods, ["api-1", "api-2", "api-3"])

        // One goes: its streams close, what it said stays; the pane's pick
        // of one of them goes back to all.
        session.picked = "api-2/sidecar-1"
        api.deletePod("api-2", namespace: "shop")
        let gone = await eventually { session.pods == ["api-1", "api-3"] && session.sources == ["api-1/app", "api-3/app"] }
        XCTAssertTrue(gone, "\(session.pods) \(session.sources)")
        XCTAssertNil(session.picked, "a stream no longer followed isn't picked")
        let closed = await eventually { self.api.openLogFollows == ["shop/api-1/app", "shop/api-3/app"] }
        XCTAssertTrue(closed, "\(api.openLogFollows)")
        XCTAssertTrue(session.feed.lines.contains { $0.message == "four" })
        XCTAssertFalse(api.requests.contains { $0.isLog && $0.path.contains("web-1") }, "not the selector's pod")
        session.cancel()
        let ended = await eventually { self.api.openLogStreams == 0 && self.api.openWatches == 0 }
        XCTAssertTrue(ended)
    }

    /// At most the cap's streams, the rest said; one followed going makes
    /// room for one left out.
    func testTheCap() async throws {
        for index in 1...3 {
            api.addPod("api-\(index)", namespace: "shop", labels: ["app": "api"])
            api.appendLog("api-\(index)", namespace: "shop", "hello from \(index)")
        }
        let (session, _) = session(cap: 2)
        session.show(since: .all)
        let capped = await eventually { self.api.openLogStreams == 2 && session.capped == 1 }
        XCTAssertTrue(capped, "\(api.openLogFollows) \(session.capped)")
        XCTAssertEqual(api.openLogFollows, ["shop/api-1/app", "shop/api-2/app"])
        XCTAssertEqual(session.summary, "2 containers of 3 pods followed · 1 more left out · at most 2 at once (kubernetes.logStreams)")
        XCTAssertFalse(api.requests.contains { $0.isLog && $0.path.contains("api-3") }, "no stream past the cap")
        api.deletePod("api-1", namespace: "shop")
        let moved = await eventually { self.api.openLogFollows == ["shop/api-2/app", "shop/api-3/app"] && session.capped == 0 }
        XCTAssertTrue(moved, "\(api.openLogFollows)")
        session.cancel()
    }

    /// The expressions: a pod left out has its stream closed, a line left
    /// out never comes; every stream read again from its start; one that
    /// isn't a regular expression changes nothing.
    func testIncludeAndExcludeExpressions() async throws {
        api.addPod("api-1", namespace: "shop", labels: ["app": "api"])
        api.addPod("api-canary", namespace: "shop", labels: ["app": "api"])
        api.setLog("api-1", namespace: "shop", ["GET /healthz 200", "ERROR db down", "GET /cart 200"])
        api.setLog("api-canary", namespace: "shop", ["ERROR canary"])
        let (session, _) = session()
        session.show(since: .all)
        let all = await eventually { session.feed.lines.count == 4 && self.api.openLogStreams == 2 }
        XCTAssertTrue(all, "\(session.feed.lines.map(\.message))")
        var filter = KubeMergedLogFilter()
        filter.excludePods = "canary"
        filter.excludeLines = "healthz"
        session.picked = "api-canary/app"
        XCTAssertTrue(session.setFilter(filter))
        XCTAssertNil(session.picked, "the filter left the picked stream out: all of them shown")
        let narrowed = await eventually { self.api.openLogFollows == ["shop/api-1/app"] && session.feed.lines.count == 2 }
        XCTAssertTrue(narrowed, "\(api.openLogFollows) \(session.feed.lines.map(\.message))")
        XCTAssertEqual(session.feed.lines.map(\.message), ["ERROR db down", "GET /cart 200"])
        filter.lines = "error"
        XCTAssertTrue(session.setFilter(filter))
        let errors = await eventually { session.feed.lines.map(\.message) == ["ERROR db down"] }
        XCTAssertTrue(errors, "\(session.feed.lines.map(\.message))")
        api.appendLog("api-1", namespace: "shop", "GET /healthz 200")
        api.appendLog("api-1", namespace: "shop", "ERROR again")
        let more = await eventually { session.feed.lines.last?.message == "ERROR again" }
        XCTAssertTrue(more)
        XCTAssertEqual(session.feed.lines.map(\.message), ["ERROR db down", "ERROR again"], "followed lines go through it too")
        var broken = filter
        broken.pods = "("
        XCTAssertFalse(session.setFilter(broken))
        XCTAssertEqual(session.filter, filter, "kept")
        session.cancel()
    }

    /// Hidden, nothing is read — the watch and every stream close; shown
    /// again, each stream resumes from its last line's time, nothing twice.
    /// ⌘L's lines are scrubbed of each pod's own secret-looking env.
    func testReadOnlyWhileShownAndResumedWithoutDuplicates() async throws {
        api.addPod("api-1", namespace: "shop", FakeKubeAPI.Pod(env: ["API_TOKEN": "tok-merged-123"]), labels: ["app": "api"])
        api.addPod("api-2", namespace: "shop", labels: ["app": "api"])
        api.setLog("api-1", namespace: "shop", ["a"])
        api.setLog("api-2", namespace: "shop", ["b"])
        let (session, _) = session()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(api.requests.isEmpty, "made, it reads nothing")
        session.show(since: .all)
        let shown = await eventually { session.feed.lines.count == 2 && self.api.openLogStreams == 2 }
        XCTAssertTrue(shown)
        session.hide()
        let hidden = await eventually { self.api.openLogStreams == 0 && self.api.openWatches == 0 }
        XCTAssertTrue(hidden, "\(api.openLogStreams) \(api.openWatches)")
        XCTAssertFalse(session.feed.following)
        api.forgetRequests()
        api.appendLog("api-1", namespace: "shop", "while away")
        api.addPod("api-3", namespace: "shop", labels: ["app": "api"])
        api.deletePod("api-2", namespace: "shop")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(api.requests.isEmpty, "nothing asked while hidden: \(api.requests)")
        session.show(since: .all)
        let resumed = await eventually {
            self.api.openLogFollows == ["shop/api-1/app", "shop/api-3/app"] && session.feed.lines.contains { $0.message == "while away" }
        }
        XCTAssertTrue(resumed, "\(api.openLogFollows) \(session.feed.lines.map(\.message))")
        XCTAssertEqual(session.feed.lines.filter { $0.message == "a" }.count, 1, "nothing twice")
        XCTAssertEqual(session.feed.lines.filter { $0.message == "b" }.count, 1, "what the gone pod said stays")
        let resumes = api.requests.filter { $0.isLog && !$0.path.contains("api-3") }
        XCTAssertEqual(resumes.map(\.path), ["/api/v1/namespaces/shop/pods/api-1/log"], "the pod deleted while hidden isn't read: the watch listed first")
        XCTAssertFalse(api.requests.contains { $0.path.hasSuffix("/pods/api-2") }, "nor asked for")
        XCTAssertTrue(resumes.allSatisfy { $0.query["sinceTime"] != nil }, "from the last line, not the tail again: \(resumes.map(\.query))")
        XCTAssertEqual(session.scrubbed("using tok-merged-123 now").contains("tok-merged-123"), false)
        session.cancel()
    }
    /// A gone pod's lines stay, and so does its env for scrubbing them:
    /// ⌘L on what a deleted pod wrote never hands its token to an agent.
    func testAGonePodsLinesAreStillScrubbedOfItsEnv() async throws {
        api.addPod("api-1", namespace: "shop", FakeKubeAPI.Pod(env: ["API_TOKEN": "tok-gone-456"]), labels: ["app": "api"])
        api.addPod("api-2", namespace: "shop", labels: ["app": "api"])
        api.setLog("api-1", namespace: "shop", ["calling with tok-gone-456"])
        api.setLog("api-2", namespace: "shop", ["b"])
        let (session, _) = session()
        session.show(since: .all)
        let shown = await eventually { session.feed.lines.count == 2 && self.api.openLogStreams == 2 }
        XCTAssertTrue(shown)
        api.deletePod("api-1", namespace: "shop")
        let gone = await eventually { session.pods == ["api-2"] && session.sources == ["api-2/app"] }
        XCTAssertTrue(gone, "\(session.pods) \(session.sources)")
        let line = try XCTUnwrap(session.feed.lines.first { $0.source == "api-1/app" }?.message, "its lines stay")
        XCTAssertFalse(session.scrubbed(line).contains("tok-gone-456"), session.scrubbed(line))
        // Another event, its lines still there: still scrubbed.
        api.updatePod("api-2", namespace: "shop") { $0.restarts = 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(session.scrubbed(line).contains("tok-gone-456"))
        session.cancel()
    }

    /// A stream that ended for good while its pod stays (a Job's Completed
    /// pod) is closed: its slot goes to one left out, its lines stay and
    /// it is still in the picker; shown again, it isn't read again.
    func testAnEndedStreamGivesItsSlotToARunningOne() async throws {
        var done = FakeKubeAPI.Pod(status: "Completed", phase: "Succeeded", ready: 0)
        done.terminatedReason = "Completed"
        api.addPod("api-a-done", namespace: "shop", done, labels: ["app": "api"])
        api.addPod("api-b", namespace: "shop", labels: ["app": "api"])
        api.setLog("api-a-done", namespace: "shop", ["job finished"])
        api.setLog("api-b", namespace: "shop", ["serving"])
        let (session, _) = session(cap: 1)
        session.show(since: .all)
        let moved = await eventually {
            self.api.openLogFollows == ["shop/api-b/app"] && session.feed.lines.count == 2 && session.ended == [KubeLogStreamKey(pod: "api-a-done", container: "app")]
        }
        XCTAssertTrue(moved, "\(api.openLogFollows) \(session.feed.lines.map(\.message)) \(session.ended)")
        XCTAssertEqual(session.streams.map(\.id), ["api-b/app"])
        XCTAssertEqual(session.sources, ["api-a-done/app", "api-b/app"], "the ended one still picked out")
        XCTAssertEqual(session.capped, 0)
        XCTAssertEqual(session.summary, "1 container of 2 pods followed · 1 ended · at most 1 at once (kubernetes.logStreams)")
        session.hide()
        api.forgetRequests()
        session.show(since: .all)
        let back = await eventually { self.api.openLogFollows == ["shop/api-b/app"] }
        XCTAssertTrue(back)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(api.requests.contains { $0.path.contains("api-a-done") }, "an ended stream isn't read again: \(api.requests.map(\.path))")
        session.cancel()
    }

    /// A pod that can't be read is said beside the summary, never in its
    /// place, and no longer once it is read.
    func testAPodsProblemIsSaidBesideTheSummaryAndCleared() async throws {
        api.addPod("api-1", namespace: "shop", labels: ["app": "api"])
        let (session, _) = session()
        session.show(since: .all)
        let shown = await eventually { self.api.openLogStreams == 1 }
        XCTAssertTrue(shown)
        api.failingResources = ["pods"]
        api.addPod("api-2", namespace: "shop", labels: ["app": "api"])
        let failed = await eventually { session.podProblems["api-2"] != nil }
        XCTAssertTrue(failed, "\(session.podProblems)")
        XCTAssertEqual(session.problems.count, 1)
        XCTAssertTrue(session.problems[0].hasPrefix("api-2: "), session.problems[0])
        XCTAssertNil(session.problem, "the watch is fine")
        XCTAssertTrue(session.summary.hasSuffix("at most 10 at once (kubernetes.logStreams)"), "the summary still says the cap")
        api.failingResources = []
        api.updatePod("api-2", namespace: "shop") { $0.restarts = 1 }
        let read = await eventually { session.podProblems.isEmpty && self.api.openLogStreams == 2 }
        XCTAssertTrue(read, "\(session.podProblems) \(api.openLogFollows)")
        session.cancel()
    }

    /// `kubernetes.logStreams` changed while the tab shows: planned again at
    /// once, the new cap said.
    func testTheCapFollowsTheSetting() async throws {
        for index in 1...3 { api.addPod("api-\(index)", namespace: "shop", labels: ["app": "api"]) }
        let changed = PassthroughSubject<Void, Never>()
        let (session, box) = session(cap: 1, capChanged: changed.eraseToAnyPublisher())
        session.show(since: .all)
        let one = await eventually { self.api.openLogStreams == 1 && session.capped == 2 }
        XCTAssertTrue(one)
        box.value = 3
        changed.send()
        let three = await eventually { self.api.openLogStreams == 3 && session.capped == 0 }
        XCTAssertTrue(three, "\(api.openLogFollows)")
        XCTAssertTrue(session.summary.hasSuffix("at most 3 at once (kubernetes.logStreams)"), session.summary)
        session.cancel()
    }
}
