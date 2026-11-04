import Darwin
import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// The Kubernetes client against `FakeKubeAPI` on a socket of the test's
/// own: the version, discovery (aggregated and the legacy walk), lists as
/// Table rows only, paging and an expired `continue`, one object, a watch
/// followed with bookmarks and resumed from where it got, a 410 (in the
/// stream and as the answer) listed again, the streaming list and its
/// fallback, a credential failure, 429s — and that only GETs were sent.
/// The real kubectl, when installed, runs in front of the fake through a
/// kubeconfig of the test's own. Nothing here reads ~/.kube: this Mac's
/// current context is production.
final class KubeClientTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private var dir: URL!

    override func setUpWithError() throws {
        // Short, under /tmp: a unix socket's path is 104 bytes at most.
        socket = "/tmp/otkc-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("default")
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        api.addPod("web-2", namespace: "shop")
        var crashing = FakeKubeAPI.Pod()
        crashing.status = "CrashLoopBackOff"
        crashing.ready = 0
        crashing.restarts = 7
        crashing.lastRestart = "2m"
        api.addPod("api-1", namespace: "shop", crashing)
        api.addPod("other", namespace: "default")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-kubeclient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Every request any test sent was a GET, and none reached a subresource.
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no subresource")
            api.stop()
        }
        ManagedProcess.closeAll()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func client(signIn: KubeSignIn = .none) -> KubeClient {
        var client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev", signIn: signIn))
        client.watchTimeout = { 600 }
        client.maxBackoff = .milliseconds(200)
        return client
    }

    // MARK: Reads

    func testTheServersVersion() async throws {
        let version = try await client().version()
        XCTAssertEqual(version.minorNumber, 34)
        XCTAssertEqual(version.gitVersion, "v1.34.1")
        XCTAssertEqual(api.requests.map(\.description), ["GET /version"])
    }

    func testAggregatedDiscoveryIsTwoRequests() async throws {
        let discovery = try await client().discover()
        XCTAssertTrue(discovery.aggregated)
        XCTAssertEqual(Set(api.requests.map(\.path)), ["/api", "/apis"])
        XCTAssertTrue(api.requests.allSatisfy { $0.accept.contains("as=APIGroupDiscoveryList") })
        let pods = try XCTUnwrap(discovery.kind("po"))
        XCTAssertEqual(pods, discovery.kind("pods"))
        XCTAssertTrue(pods.namespaced)
        XCTAssertTrue(pods.canList && pods.canWatch)
        XCTAssertTrue(pods.subresources.contains("log"))
        XCTAssertEqual(discovery.kind("ns")?.namespaced, false)
        XCTAssertEqual(discovery.kind("deploy")?.groupVersion, "apps/v1")
        XCTAssertEqual(discovery.kind("pods.metrics.k8s.io")?.verbs, ["get", "list"])
    }

    /// From 1.30 a modern cluster never walks: an aggregated API that is
    /// down is a `Stale` version in the aggregated list.
    func testAggregatedDiscoveryNotesAGroupThatIsDown() async throws {
        api.failingGroups = ["metrics.k8s.io/v1beta1"]
        let discovery = try await client().discover()
        XCTAssertTrue(discovery.aggregated)
        XCTAssertEqual(Set(api.requests.map(\.path)), ["/api", "/apis"])
        XCTAssertEqual(Array(discovery.failedGroups.keys), ["metrics.k8s.io/v1beta1"])
        XCTAssertNil(discovery.kind("pods.metrics.k8s.io"))
        XCTAssertNotNil(discovery.kind("deploy"))
    }

    func testTheLegacyWalkNotesAGroupThatIsDown() async throws {
        api.aggregatedDiscovery = false
        api.failingGroups = ["metrics.k8s.io/v1beta1"]
        let discovery = try await client().discover()
        XCTAssertFalse(discovery.aggregated)
        XCTAssertEqual(
            Set(api.requests.map(\.path)),
            [
                "/api", "/apis", "/api/v1", "/apis/apps/v1", "/apis/batch/v1", "/apis/events.k8s.io/v1", "/apis/apiextensions.k8s.io/v1",
                "/apis/rbac.authorization.k8s.io/v1", "/apis/networking.k8s.io/v1", "/apis/metrics.k8s.io/v1beta1",
            ])
        XCTAssertEqual(Array(discovery.failedGroups.keys), ["metrics.k8s.io/v1beta1"])
        XCTAssertNil(discovery.kind("pods.metrics.k8s.io"))
        XCTAssertEqual(discovery.kind("pods")?.subresources.contains("exec"), true)
        XCTAssertEqual(discovery.kind("cj")?.fullName, "cronjobs.batch")
        XCTAssertEqual(discovery.kind("events")?.group, "")
    }

    func testAListIsTableRowsOnly() async throws {
        let table = try await client().list(.pods, in: .namespace("shop"))
        let request = try XCTUnwrap(api.requests.last)
        XCTAssertEqual(request.path, "/api/v1/namespaces/shop/pods")
        XCTAssertEqual(request.query["includeObject"], "None", "rows only: 885 KB, not 35 MB")
        XCTAssertEqual(request.query["limit"], "500")
        XCTAssertTrue(request.accept.hasPrefix("application/json;as=Table;v=v1;g=meta.k8s.io"))
        XCTAssertEqual(table.rows.map(\.id.description), ["shop/api-1", "shop/web-1", "shop/web-2"])
        XCTAssertEqual(table.resourceVersion, String(api.resourceVersion))
        XCTAssertEqual(table.defaultColumns.map(\.name), ["Name", "Ready", "Status", "Restarts", "Age"])
        let crashing = try XCTUnwrap(KubePodSummary(row: table.rows[0], columns: table.columns))
        XCTAssertEqual(crashing.exitReason, "CrashLoopBackOff")
        XCTAssertEqual(crashing.restarts, 7)
        XCTAssertEqual(crashing.lastRestart, "2m ago")
        XCTAssertTrue(try XCTUnwrap(KubePodSummary(row: table.rows[1], columns: table.columns)).isReady)

        let namespaces = try await client().list(.namespaces, in: .namespace("ignored"))
        XCTAssertEqual(api.requests.last?.path, "/api/v1/namespaces", "a cluster kind's list has no namespace")
        XCTAssertEqual(namespaces.rows.map(\.id), [KubeRowID(namespace: nil, name: "default"), KubeRowID(namespace: nil, name: "shop")])

        let selected = try await client().list(.pods, options: KubeListOptions(labelSelector: "app=none"))
        XCTAssertEqual(api.requests.last?.query["labelSelector"], "app=none", "selectors go to the server")
        XCTAssertEqual(selected.rows, [])
    }

    /// No core kind's Table has a Namespace column (`kubectl get -A` adds
    /// it from the metadata): across all namespaces the rows carry their
    /// metadata, so two pods of one name in two namespaces are two rows,
    /// each fetched by its own namespace, and deleting one leaves the other.
    func testAcrossAllNamespacesARowsNamespaceIsItsMetadatas() async throws {
        api.addPod("web-1", namespace: "default")
        let client = client()
        let table = try await client.list(.pods, in: .all)
        XCTAssertEqual(api.requests.last?.path, "/api/v1/pods")
        XCTAssertEqual(api.requests.last?.query["includeObject"], "Metadata")
        XCTAssertEqual(
            table.rows.map(\.id.description), ["default/other", "default/web-1", "shop/api-1", "shop/web-1", "shop/web-2"])
        let row = try XCTUnwrap(table.rows.first { $0.id == KubeRowID(namespace: "default", name: "web-1") })
        let object = try await client.object(.pods, namespace: row.id.namespace, name: row.id.name)
        XCTAssertEqual(object.namespace, "default")
        _ = try await client.list(.namespaces, in: .all)
        XCTAssertEqual(api.requests.last?.query["includeObject"], "None", "a cluster kind's rows need no namespace")

        let follower = Follower(client.follow(.pods, in: .all))
        defer { follower.stop() }
        try await follower.until { $0.count == 5 }
        try await until { self.api.openWatches == 1 }
        XCTAssertEqual(api.requests.last?.query["includeObject"], "Metadata", "the watch's rows too")
        api.deletePod("web-1", namespace: "shop")
        try await follower.until { $0.count == 4 }
        XCTAssertNotNil(follower.rows[KubeRowID(namespace: "default", name: "web-1")], "the other namespace's web-1 stays")
        api.updatePod("web-1", namespace: "default") { $0.status = "OOMKilled" }
        try await follower.until { $0[KubeRowID(namespace: "default", name: "web-1")]?.cell("Status", in: $0.columns) == .text("OOMKilled") }
        XCTAssertEqual(follower.rows.count, 4)
    }

    func testAListIsPagedAndAnExpiredContinueListsAgain() async throws {
        for index in 0..<5 { api.addPod("p\(index)", namespace: "paged") }
        var client = client()
        client.pageSize = 2
        let table = try await client.list(.pods, in: .namespace("paged"))
        XCTAssertEqual(table.rows.map(\.id.name), ["p0", "p1", "p2", "p3", "p4"])
        XCTAssertNil(table.continueToken)
        let pages = api.requests.filter { $0.path == "/api/v1/namespaces/paged/pods" }
        XCTAssertEqual(pages.count, 3)
        XCTAssertNil(pages[0].query["continue"])
        XCTAssertNotNil(pages[1].query["continue"])

        // The token expires between the first page and the second: from the start.
        api.forgetRequests()
        let api = self.api!
        let once = Once()
        client = KubeClient(
            Hooked(base: KubeSocketConnection(socket: socket, context: "fake-dev")) { path in
                if path.contains("continue="), once.first() { api.expireContinueTokens() }
            })
        client.pageSize = 2
        let again = try await client.list(.pods, in: .namespace("paged"))
        XCTAssertEqual(again.rows.map(\.id.name), ["p0", "p1", "p2", "p3", "p4"], "no row twice, none missing")
        XCTAssertGreaterThan(api.requests.filter { $0.query["continue"] == nil }.count, 1, "listed again from the start")
    }

    func testOneObjectIsOneGetWhole() async throws {
        let object = try await client().object(.pods, namespace: "shop", name: "api-1")
        XCTAssertEqual(object.kind, "Pod")
        XCTAssertEqual(object.namespace, "shop")
        XCTAssertNotNil(object.resourceVersion)
        XCTAssertNotNil((object.json["metadata"] as? [String: Any])?["managedFields"], "the whole object")
        XCTAssertEqual(api.requests.last?.description, "GET /api/v1/namespaces/shop/pods/api-1")
        do {
            _ = try await client().object(.pods, namespace: "shop", name: "gone")
            XCTFail("not found")
        } catch let error as KubeAPIError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.message, #"pods "gone" not found"#)
        }
    }

    // MARK: Following a list

    func testAFollowedListGetsItsChangesAndBookmarks() async throws {
        let follower = Follower(client().follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        let listVersion = try XCTUnwrap(follower.rows.resourceVersion)
        try await until { self.api.openWatches == 1 }
        let watch = try XCTUnwrap(api.requests.last)
        XCTAssertEqual(watch.query["watch"], "1")
        XCTAssertEqual(watch.query["resourceVersion"], listVersion, "from the list's version")
        XCTAssertEqual(watch.query["allowWatchBookmarks"], "true")
        XCTAssertEqual(watch.query["includeObject"], "None")
        XCTAssertEqual(watch.query["timeoutSeconds"], "600")

        api.addPod("web-3", namespace: "shop")
        api.updatePod("web-1", namespace: "shop") {
            $0.status = "OOMKilled"
            $0.ready = 0
        }
        api.deletePod("web-2", namespace: "shop")
        api.addPod("elsewhere", namespace: "default")
        try await follower.until { $0.count == 3 && $0[KubeRowID(namespace: "shop", name: "web-3")] != nil }
        XCTAssertNil(follower.rows[KubeRowID(namespace: "shop", name: "web-2")])
        XCTAssertNil(follower.rows[KubeRowID(namespace: "default", name: "elsewhere")], "another namespace's isn't watched")
        let web1 = try XCTUnwrap(follower.rows[KubeRowID(namespace: "shop", name: "web-1")])
        XCTAssertEqual(KubePodSummary(row: web1, columns: follower.rows.columns)?.exitReason, "OOMKilled", "the list's headers read a watch's rows")

        api.bookmark()
        let now = String(api.resourceVersion)
        try await follower.until { $0.resourceVersion == now }
        XCTAssertTrue(follower.updates.contains(.bookmark(now)))
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == nil }.count, 1, "listed once")
    }

    func testAWatchTheServerEndsResumesFromWhereItGot() async throws {
        let follower = Follower(client().follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
        let seen = try XCTUnwrap(follower.rows.resourceVersion)
        api.endWatches()
        try await until { self.api.requests.filter { $0.query["watch"] == "1" }.count == 2 && self.api.openWatches == 1 }
        XCTAssertEqual(api.requests.last?.query["resourceVersion"], seen, "from the last event's version")
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == nil }.count, 1, "not listed again")
        api.deletePod("web-3", namespace: "shop")
        try await follower.until { $0.count == 3 }
    }

    func testAnInStream410ListsAgain() async throws {
        let follower = Follower(client().follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        api.compact()
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
        api.expireWatches()
        try await until { self.api.requests.filter { $0.query["watch"] == nil }.count == 2 && self.api.openWatches == 1 }
        XCTAssertEqual(follower.updates.filter { if case .listed = $0 { true } else { false } }.count, 2, "listed again")
        XCTAssertEqual(follower.rows.count, 4)
        api.addPod("web-4", namespace: "shop")
        try await follower.until { $0.count == 5 }
    }

    func testA410AsTheWatchsAnswerListsAgain() async throws {
        api.goneAsAnswer = true
        let follower = Follower(client().follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        // A change the watch doesn't see: its version is now behind.
        api.addPod("elsewhere", namespace: "default")
        api.compact()
        api.endWatches()
        // The watch from the old version is answered 410: a list, a watch from it.
        try await until { self.api.requests.filter { $0.query["watch"] == nil }.count == 2 && self.api.openWatches == 1 }
        let watches = api.requests.filter { $0.query["watch"] == "1" }
        XCTAssertEqual(watches.count, 3)
        XCTAssertEqual(watches[2].query["resourceVersion"], follower.rows.resourceVersion)
        api.deletePod("api-1", namespace: "shop")
        try await follower.until { $0.count == 2 }
    }

    func testAStreamingListReplacesTheFirstList() async throws {
        var client = client()
        client.streamingLists = true
        let follower = Follower(client.follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == nil }.count, 0, "no list")
        let watch = try XCTUnwrap(api.requests.last)
        XCTAssertEqual(watch.query["sendInitialEvents"], "true")
        XCTAssertEqual(watch.query["resourceVersionMatch"], "NotOlderThan")
        XCTAssertNil(watch.query["resourceVersion"])
        guard case .listed(let table) = follower.updates.first else { return XCTFail("\(follower.updates)") }
        XCTAssertEqual(table.resourceVersion, String(api.resourceVersion), "the bookmark's version")
        XCTAssertEqual(table.columns.count, 9)
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == "1" }.count, 1, "the same watch goes on")
    }

    /// Only the bookmark marked `k8s.io/initial-events-end` ends the
    /// initial events; one before it moves the version on and is no list.
    func testAStreamingListEndsAtItsEndsBookmarkOnly() async throws {
        api.interimBookmarks = true
        var client = client()
        client.streamingLists = true
        let follower = Follower(client.follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        let listed = follower.updates.compactMap { update -> KubeTable? in if case .listed(let table) = update { table } else { nil } }
        XCTAssertEqual(listed.map(\.rows.count), [3], "one list, whole")
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
    }

    func testAServerWithoutStreamingListsIsListedAndWatched() async throws {
        api.streamingLists = false
        var client = client()
        client.streamingLists = true
        let follower = Follower(client.follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == nil }.count, 1, "refused (422): listed instead")
        XCTAssertNotNil(api.requests.last?.query["resourceVersion"])
    }

    // MARK: Failures

    /// The spike: with an expired AWS session every answer was the proxy's
    /// 500 in plain text. Said as what to run; not retried — each request
    /// would run `aws` again.
    func testACredentialFailureIsSaidAndNotRetried() async throws {
        api.failCredentials()
        do {
            _ = try await client(signIn: .aws(profile: "acme")).list(.pods, in: .namespace("shop"))
            XCTFail("it failed")
        } catch let problem as KubeProxyProblem {
            XCTAssertEqual(problem, .awsSignIn(profile: "acme"))
            XCTAssertEqual(problem.command, "aws sso login --profile acme")
            XCTAssertTrue(problem.stopsRequests)
        }
        XCTAssertEqual(api.requests.count, 1)
        api.forgetRequests()
        var updates: [KubeFollowUpdate] = []
        do {
            for try await update in client().follow(.pods, in: .namespace("shop")) { updates.append(update) }
            XCTFail("it ended")
        } catch let problem as KubeProxyProblem {
            XCTAssertEqual(problem, .credentials("getting credentials: exec: executable aws failed with exit code 255"))
        }
        XCTAssertEqual(updates, [])
        XCTAssertEqual(api.requests.count, 1, "a follow stops at the first")
    }

    func testA429IsRetriedAfterItsRetryAfter() async throws {
        api.throttle(2, retryAfter: 0)
        let table = try await client().list(.namespaces)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(api.requests.count, 3)
        api.throttle(5, retryAfter: 0)
        do {
            _ = try await client().list(.namespaces)
            XCTFail("throttled")
        } catch let error as KubeAPIError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfter, 0)
        }
    }

    /// A 429 on a watch's answer waits its `Retry-After` and watches again
    /// from the same version, saying so; the rows stand meanwhile.
    func testA429OnAWatchWaitsAndWatchesAgain() async throws {
        api.failWatches(2, status: 429, retryAfter: 0)
        let follower = Follower(client().follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        let retries = follower.updates.compactMap { update -> KubeAPIError? in if case .retrying(let error) = update { error } else { nil } }
        XCTAssertEqual(retries.map(\.status), [429, 429])
        XCTAssertEqual(retries.first?.retryAfter, 0, "the Retry-After read from the stream's answer")
        let watches = api.requests.filter { $0.query["watch"] == "1" }
        XCTAssertEqual(watches.count, 3)
        XCTAssertEqual(Set(watches.map { $0.query["resourceVersion"] }).count, 1, "from the list's version each time")
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == nil }.count, 1, "not listed again")
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
    }

    /// The server's own 500 (a JSON Status) on a watch is the server
    /// failing for now: retried, backing off — not the proxy's plain-text
    /// 500, which ends a follow.
    func testTheServersJSON500OnAWatchIsRetried() async throws {
        api.failWatches(1, status: 500)
        let follower = Follower(client().follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        let retries = follower.updates.compactMap { update -> KubeAPIError? in if case .retrying(let error) = update { error } else { nil } }
        XCTAssertEqual(retries.map(\.status), [500])
        XCTAssertEqual(retries.first?.reason, "InternalError")

        let json = HTTPError(
            HTTPResponse(status: 500, headers: [("Content-Type", "application/json")], body: FakeKubeAPI.status(500, "InternalError", "etcdserver: request timed out")))
        XCTAssertEqual(KubeClient.mapped(json, signIn: .none) as? KubeAPIError, KubeAPIError(status: 500, reason: "InternalError", message: "etcdserver: request timed out"))
        let plain = HTTPError(HTTPResponse(status: 500, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data("dial tcp 10.0.0.1:443: i/o timeout".utf8)))
        XCTAssertEqual(KubeClient.mapped(plain, signIn: .none) as? KubeProxyProblem, .unreachable("dial tcp 10.0.0.1:443: i/o timeout"))
    }

    /// A list without a resourceVersion (metrics.k8s.io's) has nothing to
    /// watch from: listed again, never watched from "".
    func testAListWithoutAResourceVersionIsListedAgainNotWatched() async throws {
        api.unversionedLists = true
        var client = client()
        client.unversionedPoll = .milliseconds(50)
        let follower = Follower(client.follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
        XCTAssertGreaterThanOrEqual(api.requests.count, 2)
        XCTAssertEqual(api.requests.filter { $0.query["watch"] != nil }, [], "no watch")
    }

    /// The fake sees a Namespace's own subresource as one, so the check
    /// that none was reached can't miss it.
    func testTheFakeKnowsANamespacesSubresource() {
        XCTAssertEqual(FakeKubeAPI.route("/api/v1/namespaces/shop/finalize")?.subresource, "finalize")
        XCTAssertEqual(FakeKubeAPI.route("/api/v1/namespaces/shop/status")?.name, "shop")
        XCTAssertNil(FakeKubeAPI.route("/api/v1/namespaces/shop/pods")?.subresource)
        XCTAssertEqual(FakeKubeAPI.route("/api/v1/namespaces/shop/pods/p/exec")?.subresource, "exec")
        XCTAssertTrue(FakeKubeAPI.Request(method: "GET", path: "/api/v1/namespaces/shop/finalize", query: [:], accept: "").isSubresource)
    }

    /// The client over the app's own proxies, in a unit test without
    /// OVERTERM_KUBECONFIG: no kubeconfig is read — not ~/.kube/config, not
    /// KUBECONFIG — so no kubectl starts and no request leaves, even for
    /// this Mac's production context's name.
    func testTheAppsProxiesReachNoClusterFromAUnitTest() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"] != nil, "a run of its own fake clusters")
        XCTAssertTrue(AppEnvironment.guardsKubeconfig)
        let proxies = KubeProxies(configuration: KubeProxies.Configuration(kubectlPath: "/usr/local/bin/kubectl", extraKubeconfigs: ["~/.kube/config"]))
        defer { proxies.closeAll() }
        let production = KubeContext(
            name: "arn:aws:eks:eu-west-1:000000000000:cluster/acme-prod", cluster: "acme-prod", server: nil, namespace: nil, user: "u", auth: nil,
            file: nil, contextClass: .production, settings: KubeContextSettings())
        do {
            _ = try await KubeClient(KubeProxyConnection(proxies: proxies, context: production)).version()
            XCTFail("nothing to reach")
        } catch {
            XCTAssertEqual(error as? KubeProxyProblem, .noKubeconfig)
        }
        let connected = await proxies.connected
        XCTAssertEqual(connected, [], "no proxy started")
    }

    // MARK: The real kubectl

    /// The real `kubectl proxy` of a read-only context in front of the fake
    /// on 127.0.0.1, through a kubeconfig of the test's own and its
    /// `--context`: discovery, a list, a followed change and a 410 pass
    /// through it; nothing but GETs reached the fake. Skipped without kubectl.
    func testTheClientThroughTheRealKubectlProxy() async throws {
        let kubectl = URL(fileURLWithPath: "/usr/local/bin/kubectl")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: kubectl.path), "no kubectl")
        let port = try api.listenTCP()
        let kubeconfig = dir.appendingPathComponent("fake.kubeconfig")
        try """
        apiVersion: v1
        kind: Config
        clusters:
        - name: fake
          cluster: {server: "http://127.0.0.1:\(port)"}
        users:
        - name: anonymous
          user: {}
        contexts:
        - name: fake-dev
          context: {cluster: fake, user: anonymous}
        current-context: fake-dev
        """.write(to: kubeconfig, atomically: true, encoding: .utf8)
        let base = URL(fileURLWithPath: "/tmp").appendingPathComponent("otkc-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var planner = KubeProxyPlanner(folder: KubeSocketFolder(base: base))
        planner.guarded = true
        planner.home = dir.appendingPathComponent("home", isDirectory: true)
        planner.kubeconfigs = { _ in [kubeconfig] }
        planner.baseEnvironment = { ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()] }
        let real = planner
        let proxies = KubeProxies(
            configuration: KubeProxies.Configuration(kubectlPath: kubectl.path), plan: { try await real.plan($0, configuration: $1, serverMinor: $2) })
        defer { proxies.closeAll() }
        let context = KubeContext(
            name: "fake-dev", cluster: "fake", server: "http://127.0.0.1:\(port)", namespace: nil, user: "anonymous", auth: KubeAuth.none, file: kubeconfig,
            contextClass: KubeClassifier.classify(context: "fake-dev", cluster: "fake", set: nil), settings: KubeContextSettings())
        XCTAssertFalse(context.isWritable, "remote, so its proxy refuses every write")
        var client = KubeClient(KubeProxyConnection(proxies: proxies, context: context))
        client.watchTimeout = { 600 }

        let discovery = try await client.discover()
        XCTAssertEqual(discovery.kind("po"), discovery.kind("pods"))
        let table = try await client.list(.pods, in: .namespace("shop"))
        XCTAssertEqual(table.rows.count, 3)

        let follower = Follower(client.follow(.pods, in: .namespace("shop")))
        defer { follower.stop() }
        try await follower.until { $0.count == 3 }
        try await until { self.api.openWatches == 1 }
        api.addPod("web-3", namespace: "shop")
        try await follower.until { $0.count == 4 }
        api.compact()
        api.expireWatches()
        try await until { self.api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["watch"] == nil }.count == 3 }
        try await follower.until { $0.count == 4 }
        XCTAssertTrue(api.requests.allSatisfy { $0.method == "GET" })
    }

    // MARK: Helpers

    private func until(_ ok: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !ok() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A follow's updates, applied to its rows as they come.
private final class Follower: @unchecked Sendable {
    private let lock = NSLock()
    private var applied = KubeRows()
    private var seen: [KubeFollowUpdate] = []
    private var failure: Error?
    private var task: Task<Void, Never>?

    init(_ stream: AsyncThrowingStream<KubeFollowUpdate, Error>) {
        task = Task { [weak self] in
            do {
                for try await update in stream {
                    guard let self else { return }
                    self.lock.withLock {
                        self.applied.apply(update)
                        self.seen.append(update)
                    }
                }
            } catch {
                self?.lock.withLock { self?.failure = error }
            }
        }
    }

    var rows: KubeRows { lock.withLock { applied } }
    var updates: [KubeFollowUpdate] { lock.withLock { seen } }

    func until(_ ok: (KubeRows) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !ok(rows) {
            if let failure = lock.withLock({ failure }) { throw failure }
            guard Date() < deadline else {
                XCTFail("timed out: \(rows.sorted.map(\.id.description))")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() { task?.cancel() }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// A connection that runs `before` ahead of each GET it passes on.
private struct Hooked: KubeConnection {
    let base: KubeSocketConnection
    let before: @Sendable (String) -> Void

    var signIn: KubeSignIn { base.signIn }

    func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse {
        before(path)
        return try await base.get(path, headers: headers)
    }

    func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> { base.stream(path, headers: headers) }
}
