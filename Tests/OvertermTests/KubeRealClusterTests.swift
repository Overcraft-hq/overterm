import Darwin
import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// Overterm's own proxies and client against a real cluster: the kind
/// cluster `Scripts/kube-test-cluster.sh` makes (cluster "fake", context
/// `kind-fake`), through that script's kubeconfig and nothing else — what
/// docs/design/kubernetes/analysis.md, Section 12 left open about
/// `kubectl proxy`, answered by the server rather than by the fake.
///
/// Opt-in, as the Docker and database suites are:
///
///     Scripts/kube-test-cluster.sh create
///     OVERTERM_KUBE_TESTS=1 OVERTERM_KUBE_TEST_KUBECONFIG="$(Scripts/kube-test-cluster.sh kubeconfig)" \
///       swift test --filter KubeRealClusterTests
///     Scripts/kube-test-cluster.sh delete
///
/// Skipped otherwise. It refuses any kubeconfig under `~/.kube` or one
/// whose one context isn't `kind-fake` on 127.0.0.1, and every kubectl it
/// starts gets that file as `KUBECONFIG`, `--context` and a HOME of its
/// own. Its objects are in a namespace of its own (`overterm-test-…`,
/// labelled `overterm.test`), deleted after. The tokens it makes (two
/// ServiceAccounts', ten minutes) are kept in memory and handed to a
/// credential plugin through its environment — never written down.
final class KubeRealClusterTests: XCTestCase {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: Fixture?
    nonisolated(unsafe) private static var failure: String?

    private var fixture: Fixture!
    private var proxies: KubeProxies!
    private var planner: KubeProxyPlanner!
    private var configuration: KubeProxies.Configuration!
    private var base: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_KUBE_TESTS"] == "1", "OVERTERM_KUBE_TESTS=1 with Scripts/kube-test-cluster.sh runs it")
        fixture = try Self.lock.withLock { () throws -> Fixture in
            if let shared = Self.shared { return shared }
            if let failure = Self.failure { throw XCTSkip(failure) }
            do {
                let made = try Fixture.make()
                Self.shared = made
                return made
            } catch {
                Self.failure = "the cluster's fixture: \(error)"
                throw error
            }
        }
        base = URL(fileURLWithPath: "/tmp").appendingPathComponent("otkr-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var planner = KubeProxyPlanner(folder: KubeSocketFolder(base: base))
        planner.guarded = true
        planner.home = fixture.home
        let files = [fixture.kindKubeconfig, fixture.extraKubeconfig]
        planner.kubeconfigs = { _ in files }
        let environment = fixture.pluginEnvironment
        planner.baseEnvironment = { environment }
        self.planner = planner
        let real = planner
        configuration = KubeProxies.Configuration(maxProxies: 8, kubectlPath: fixture.kubectl.path)
        proxies = KubeProxies(configuration: configuration, plan: { try await real.plan($0, configuration: $1, serverMinor: $2) })
    }

    override func tearDown() {
        proxies?.closeAll()
        ManagedProcess.closeAll()
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    override class func tearDown() {
        lock.withLock {
            shared?.remove()
            shared = nil
        }
        super.tearDown()
    }

    // MARK: The method filter

    /// A read-only context's socket answers every method but GET with
    /// kubectl's own 403 — `text/plain`, "Forbidden" — before the server
    /// hears of it; a lowercase or unknown method too (kubectl matches the
    /// method as sent; the apiserver would answer it 405). Nothing is made.
    func testTheMethodFilterRefusesEveryMethodButGET() async throws {
        let dev = try fixture.context("fake-dev")
        XCTAssertFalse(dev.isWritable)
        let body = Data(#"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"acme-sneak"}}"#.utf8)
        let path = "/api/v1/namespaces/\(fixture.namespace)/configmaps"
        let methods: [HTTPMethod] = [.POST, .PUT, .PATCH, .DELETE, .OPTIONS, .RAW(value: "post"), .RAW(value: "Delete"), .RAW(value: "PROPFIND")]
        for method in methods {
            let refused = try await proxies.send(dev, method, path, body: body, headers: [("Content-Type", "application/json")])
            XCTAssertEqual(refused.status, 403, "\(method)")
            XCTAssertEqual(refused.header("Content-Type"), "text/plain; charset=utf-8", "\(method): kubectl's own answer")
            XCTAssertEqual(String(decoding: refused.body, as: UTF8.self), "Forbidden\n", "\(method)")
        }
        let listed = try await proxies.send(dev, .GET, path)
        XCTAssertEqual(listed.status, 200)
        let sneak = try await proxies.send(dev, .GET, path + "/acme-sneak")
        XCTAssertEqual(sneak.status, 404, "nothing was made")
    }

    // MARK: Path variants

    /// No variant of a path reaches exec, attach, port-forward or a pod's,
    /// a Service's or a node's proxy, on either kind of socket: kubectl
    /// matches the decoded path, so `%2F` is a slash; its mux answers a
    /// path with `//`, `/./` or `..` with a 307 to the clean one, which is
    /// refused in turn; a changed case is a path the server doesn't
    /// serve; a trailing segment or a query is still the subresource.
    func testPathVariantsNeverReachWhatIsInsideTheCluster() async throws {
        let ns = fixture.namespace
        let pod = fixture.echoPod
        let node = fixture.node
        let variants = [
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec?command=sh&stdout=true",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/attach?stdout=true",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/portforward?ports=9376",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/proxy/",
            "/api/v1/namespaces/\(ns)/pods/\(pod):9376/proxy/",
            "/api/v1/namespaces/\(ns)/pods/http:\(pod):9376/proxy/",
            "/api/v1/namespaces/\(ns)/services/echo:80/proxy/",
            "/api/v1/namespaces/\(ns)/services/http:echo:80/proxy/",
            "/api/v1/namespaces/\(ns)/services/echo/proxy/",
            "/api/v1/nodes/\(node)/proxy/healthz",
            "/api/v1/nodes/\(node):10250/proxy/pods",
            "/api/v1/nodes/\(node)/proxy/run/\(ns)/\(pod)/x",
            // Encoded
            "/api/v1/namespaces/\(ns)/pods/\(pod)%2Fexec?command=sh",
            "/api/v1/namespaces/\(ns)/pods%2F\(pod)%2Fexec",
            "/api%2Fv1%2Fnamespaces%2F\(ns)%2Fservices%2Fecho:80%2Fproxy%2F",
            "/api/v1/namespaces/\(ns)/services/echo:80%2Fproxy/",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/%65xec",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec%3Fcommand=sh",
            // Not clean
            "//api/v1/namespaces/\(ns)/pods/\(pod)/exec",
            "/api//v1/namespaces/\(ns)/pods/\(pod)/exec",
            "/api/v1/namespaces/\(ns)/pods/\(pod)//exec",
            "/api/v1/./namespaces/\(ns)/pods/\(pod)/exec",
            "/./api/v1/namespaces/\(ns)/services/echo:80/proxy/",
            "/api/v1/namespaces/\(ns)/pods/x/../\(pod)/exec",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/./proxy/",
            // Case
            "/api/v1/namespaces/\(ns)/pods/\(pod)/EXEC",
            "/API/v1/namespaces/\(ns)/pods/\(pod)/exec",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/Proxy/",
            "/api/v1/namespaces/\(ns)/services/echo:80/PROXY/",
            "/api/v1/nodes/\(node)/Proxy/healthz",
            // Trailing segments
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec/",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec/extra",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec;x",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec.json",
            "/api/v1/namespaces/\(ns)/pods/\(pod)/exec?x=/../log",
        ]
        for name in ["kind-fake", "fake-dev"] {
            let context = try fixture.context(name)
            for path in variants {
                let response = try await proxies.send(context, .GET, path)
                let planned = await proxies.socket(name)
                let socket = try XCTUnwrap(planned)
                try await assertNeverReached(response, path: path, context: name, socket: socket)
            }
            // A WebSocket exec is a GET: the paths stop it, not the methods.
            let upgrade = try await proxies.send(
                context, .GET, "/api/v1/namespaces/\(ns)/pods/\(pod)/exec?command=sh&stdout=true",
                headers: [
                    ("Connection", "Upgrade"), ("Upgrade", "websocket"), ("Sec-WebSocket-Version", "13"), ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
                    ("Sec-WebSocket-Protocol", "v5.channel.k8s.io"),
                ])
            XCTAssertEqual(upgrade.status, 403, "\(name): a WebSocket exec")
            // What isn't inside the cluster still answers: a log, the pod.
            let log = try await proxies.send(context, .GET, "/api/v1/namespaces/\(ns)/pods/\(pod)/log?tailLines=1")
            XCTAssertEqual(log.status, 200, "\(name): a log is a read")
            let read = try await proxies.send(context, .GET, "/api/v1/namespaces/\(ns)/pods/\(pod)?/exec")
            XCTAssertEqual(read.status, 200, "\(name): a query is no path")
        }
    }

    /// The answer to a variant: never 2xx, never an upgrade, never the
    /// pod's own words (serve-hostname answers its name to any path); a
    /// 307 only to a path the socket refuses.
    private func assertNeverReached(_ response: HTTPResponse, path: String, context: String, socket: String) async throws {
        let said = String(decoding: response.body.prefix(512), as: UTF8.self)
        XCTAssertFalse((200..<300).contains(response.status) || response.status == 101, "\(context) \(path): \(response.status) \(said)")
        XCTAssertNotEqual(said.trimmingCharacters(in: .whitespacesAndNewlines), fixture.echoPod, "\(context) \(path) reached the pod")
        if response.status == 307 {
            let location = try XCTUnwrap(response.header("Location"), path)
            let clean = URLComponents(string: location).map { ($0.percentEncodedPath) + ($0.percentEncodedQuery.map { "?" + $0 } ?? "") } ?? location
            let transport = UnixHTTPTransport.kubernetes(socket: socket, context: context)
            let followed = try await transport.send(.GET, clean, body: nil, headers: [])
            XCTAssertEqual(followed.status, 403, "\(context) \(path) → \(clean)")
        } else if response.status != 403 {
            XCTAssertEqual(response.status, 404, "\(context) \(path): a path the server doesn't serve — \(said)")
        }
    }

    // MARK: Connect subresources

    /// Every subresource the server lists with `get` that isn't a read of
    /// the object's own (status, scale, log…) is a connect one — a process
    /// in the cluster at the other end — and every one is refused, on
    /// either socket. On kind's 1.37 they are exactly the six the list
    /// names, and no API is aggregated; an aggregated group with one of
    /// its own would fail here, naming it.
    func testEveryConnectSubresourceTheServerListsIsRefused() async throws {
        let dev = try fixture.context("fake-dev")
        let kind = try fixture.context("kind-fake")
        let accept = "application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList"
        var connect: [(group: String, version: String, resource: String, subresource: String, namespaced: Bool)] = []
        let reads: Set<String> = ["status", "scale", "log", "ephemeralcontainers", "resize", "approval"]
        for root in ["/api", "/apis"] {
            let answer = try await proxies.send(dev, .GET, root, headers: [("Accept", accept)])
            XCTAssertEqual(answer.status, 200, root)
            let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: answer.body) as? [String: Any], root)
            XCTAssertEqual(list["kind"] as? String, "APIGroupDiscoveryList", "aggregated discovery")
            for group in list["items"] as? [[String: Any]] ?? [] {
                let name = (group["metadata"] as? [String: Any])?["name"] as? String ?? ""
                for version in group["versions"] as? [[String: Any]] ?? [] {
                    for resource in version["resources"] as? [[String: Any]] ?? [] {
                        for sub in resource["subresources"] as? [[String: Any]] ?? [] {
                            let subresource = sub["subresource"] as? String ?? ""
                            guard (sub["verbs"] as? [String] ?? []).contains("get"), !reads.contains(subresource) else { continue }
                            connect.append(
                                (
                                    name, version["version"] as? String ?? "", resource["resource"] as? String ?? "", subresource,
                                    resource["scope"] as? String == "Namespaced"
                                ))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            Set(connect.map { "\($0.resource)/\($0.subresource)" }),
            ["pods/attach", "pods/exec", "pods/portforward", "pods/proxy", "nodes/proxy", "services/proxy"],
            "kind's 1.37: the six the reject list names")
        for item in connect {
            let prefix = item.group.isEmpty ? "/api/\(item.version)" : "/apis/\(item.group)/\(item.version)"
            let name = item.resource == "nodes" ? fixture.node : item.resource == "services" ? "echo" : fixture.echoPod
            let path = prefix + (item.namespaced ? "/namespaces/\(fixture.namespace)" : "") + "/\(item.resource)/\(name)/\(item.subresource)"
            for context in [dev, kind] {
                let refused = try await proxies.send(context, .GET, path)
                XCTAssertEqual(refused.status, 403, "\(context.name) \(path)")
            }
        }
        // Which APIs another server serves: none on kind.
        let services = try await proxies.send(dev, .GET, "/apis/apiregistration.k8s.io/v1/apiservices")
        let items = (try JSONSerialization.jsonObject(with: services.body) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        let aggregated = items.filter { (($0["spec"] as? [String: Any])?["service"] as? [String: Any]) != nil }
        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(aggregated.count, 0, "no aggregated API on kind: \(aggregated.map { ($0["metadata"] as? [String: Any])?["name"] ?? "" })")
    }

    // MARK: Exec plugins

    /// Whether a failed credential plugin's answer is kept: it isn't —
    /// kubectl runs it again for every request (and a token the server
    /// refuses is thrown away and asked for again). So Overterm stops the
    /// context at the first failure, a 401 on a plugin's context too, and
    /// runs the plugin again only once it is asked to (`retry`). A token
    /// the server takes is kept until its expiry: one call for many
    /// requests.
    func testACredentialPluginsFailuresAreNotCachedSoTheContextStops() async throws {
        let path = "/api/v1/namespaces/\(fixture.namespace)/pods"
        // A plugin that fails.
        let failing = try fixture.context("acme-fail")
        await assertStops(failing, path: path, calls: "fail")
        XCTAssertEqual(fixture.calls("fail"), 1, "stopped: the plugin isn't run again")
        await proxies.retry("acme-fail")
        await assertStops(failing, path: path, calls: "fail")
        XCTAssertEqual(fixture.calls("fail"), 2, "kubectl kept nothing: run again for the next request")
        // A token the server refuses: a 401, the plugin asked again by kubectl.
        let refused = try fixture.context("acme-bogus")
        await assertStops(refused, path: path, calls: "bogus")
        let asked = fixture.calls("bogus")
        XCTAssertGreaterThan(asked, 0)
        await assertStops(refused, path: path, calls: "bogus")
        XCTAssertEqual(fixture.calls("bogus"), asked, "a 401 on a plugin's context stops it: the plugin isn't run again")
        // A token it takes: kept.
        let good = try fixture.context("acme-token")
        for _ in 0..<4 {
            let answer = try await proxies.send(good, .GET, "/version")
            XCTAssertEqual(answer.status, 200)
        }
        let forbidden = try await proxies.send(good, .GET, path)
        XCTAssertEqual(forbidden.status, 403, "the default ServiceAccount lists nothing — the server's 403, a Status")
        XCTAssertEqual(fixture.calls("token"), 1, "a token taken is kept until it expires")
    }

    private func assertStops(_ context: KubeContext, path: String, calls: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let answer = try await proxies.send(context, .GET, path)
            XCTFail("\(context.name): \(answer.status) \(String(decoding: answer.body.prefix(200), as: UTF8.self))", file: file, line: line)
        } catch let problem as KubeProxyProblem {
            XCTAssertTrue(problem.stopsRequests, "\(problem)", file: file, line: line)
            let status = await proxies.status(of: context.name)
            XCTAssertEqual(status, .stopped(problem), file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    // MARK: Port-forwards

    /// Whether `kubectl port-forward pod/…` exits when its pod is deleted:
    /// not while nothing connects. It goes on listening — 10 seconds here,
    /// a minute by hand — and exits (1, "lost connection to pod") at the
    /// next connection, which fails. So kubectl exiting says the pod went
    /// only once someone used the forward; the forwards' pod check is
    /// what notices before (`KubeForwards`).
    func testAPortForwardOutlivesItsPodUntilAConnection() async throws {
        let kind = try fixture.context("kind-fake")
        let tool = try await planner.tool(kind, configuration: configuration, serverMinor: nil)
        let port = try Self.freePort()
        let arguments = KubePortForwardCommand.arguments(
            pod: "forward-me", localPort: port, remotePort: 9376, context: "kind-fake", namespace: fixture.namespace, address: "127.0.0.1",
            cacheDirectory: tool.cacheDirectory)
        let process = try await ManagedProcess.start(
            ManagedProcess.Launch(executable: tool.kubectl, arguments: arguments, environment: tool.environment, readiness: .line(KubePortForwardCommand.isReady)))
        defer { process.close() }
        let first = try await Self.get("http://127.0.0.1:\(port)/")
        XCTAssertEqual(first, "forward-me", "the pod answers through it")

        // Deleted at once, through the writable socket.
        let deleted = try await proxies.sendWrite(
            kind, .DELETE, "/api/v1/namespaces/\(fixture.namespace)/pods/forward-me", body: Data(#"{"gracePeriodSeconds":0}"#.utf8),
            headers: [("Content-Type", "application/json")])
        XCTAssertEqual(deleted.status, 200)
        let gone = try await eventually(30) {
            (try? await self.proxies.send(kind, .GET, "/api/v1/namespaces/\(self.fixture.namespace)/pods/forward-me"))?.status == 404
        }
        XCTAssertTrue(gone, "the pod is gone")
        try await Task.sleep(for: .seconds(10))
        XCTAssertTrue(process.isRunning, "kubectl still forwards to a pod that is gone")

        let began = ContinuousClock.now
        let second = try? await Self.get("http://127.0.0.1:\(port)/")
        XCTAssertNil(second, "the connection fails")
        let exited = try await eventually(10) { !process.isRunning }
        XCTAssertTrue(exited, "and kubectl exits")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(process.stderr.text.contains("lost connection to pod"), process.stderr.text)
    }

    // MARK: Streaming lists

    /// Streaming lists (`sendInitialEvents`) and Tables combine on kind's
    /// 1.37, and end with the bookmark marked `k8s.io/initial-events-end`
    /// — on the Table's one row's object, not its metadata. A follow takes
    /// it as the list, in well under the quiet that would give it up, and
    /// the context goes on streaming; an empty one's end carries the
    /// columns.
    func testStreamingListsCombineWithTablesAndEndAtTheirBookmark() async throws {
        let dev = try fixture.context("fake-dev")
        var client = KubeClient(KubeProxyConnection(proxies: proxies, context: dev))
        let version = try await client.version()
        XCTAssertEqual(version.minorNumber, 37, version.gitVersion)
        let lists = KubeStreamingLists()
        lists.learn("fake-dev", minor: version.minorNumber)
        XCTAssertEqual(lists.state(of: "fake-dev"), .served)
        client.streaming = (lists, "fake-dev")

        // The raw stream: every pod ADDED, then the end's bookmark.
        let raw = client.watch(.pods, in: .namespace(fixture.namespace), options: KubeListOptions(labelSelector: "app=echo"), from: nil, columns: [])
        let reading = Task { () -> (added: Int, ended: Bool) in
            var added = 0
            for try await event in raw {
                switch event {
                case .added: added += 1
                case .bookmark(_, let end) where end: return (added, true)
                default: break
                }
            }
            return (added, false)
        }
        let stopper = Task {
            try await Task.sleep(for: .seconds(10))
            reading.cancel()
        }
        let (added, sawEnd) = (try? await reading.value) ?? (0, false)
        stopper.cancel()
        XCTAssertTrue(sawEnd, "the end's bookmark came")
        XCTAssertEqual(added, 1)

        // A follow: the list in one stream, the context still streaming.
        let began = ContinuousClock.now
        let table = try await firstListed(client.follow(.pods, in: .namespace(fixture.namespace), options: KubeListOptions(labelSelector: "app=echo")))
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(4), "not the quiet's fallback")
        XCTAssertEqual(table.rows.map(\.id.name), [fixture.echoPod])
        XCTAssertGreaterThan(table.columns.count, 5)
        XCTAssertEqual(lists.state(of: "fake-dev"), .served, "never refused")
        let empty = try await firstListed(client.follow(.pods, in: .namespace(fixture.namespace), options: KubeListOptions(labelSelector: "app=nobody")))
        XCTAssertEqual(empty.rows.count, 0)
        XCTAssertEqual(empty.columns.map(\.name), table.columns.map(\.name), "an empty one's end carries the columns")
        XCTAssertEqual(lists.state(of: "fake-dev"), .served)
    }

    private func firstListed(_ stream: AsyncThrowingStream<KubeFollowUpdate, Error>) async throws -> KubeTable {
        let reading = Task { () -> KubeTable? in
            for try await update in stream { if case .listed(let table) = update { return table } }
            return nil
        }
        let stopper = Task {
            try await Task.sleep(for: .seconds(20))
            reading.cancel()
        }
        defer { stopper.cancel() }
        let table = try await reading.value
        return try XCTUnwrap(table, "listed")
    }

    // MARK: Prometheus

    /// The metrics proxy against a real Service proxy path: its query and
    /// query_range reach the Service (serve-hostname answers its pod's
    /// name), and nothing else does — another Service's, another path under
    /// this one's, `..`, `%2F`, a POST.
    func testTheMetricsProxyReachesOnlyItsServicesQueryPaths() async throws {
        let dev = try fixture.context("fake-dev")
        let service = try XCTUnwrap(KubePrometheusService(namespace: fixture.namespace, name: "echo", port: "80"))
        let query = try await proxies.sendPrometheus(dev, service, service.queryPath + "?query=up")
        XCTAssertEqual(query.status, 200)
        XCTAssertEqual(String(decoding: query.body, as: UTF8.self), fixture.echoPod, "the Service answered")
        let range = try await proxies.sendPrometheus(dev, service, service.rangePath + "?query=up&start=1&end=2&step=1")
        XCTAssertEqual(range.status, 200)

        let planned = await proxies.socket("fake-dev", prometheus: service)
        let socket = try XCTUnwrap(planned)
        let metrics = UnixHTTPTransport.kubernetes(socket: socket, context: "fake-dev")
        let ns = fixture.namespace
        let refused = [
            "/api/v1/namespaces/\(ns)/services/orphan:80/proxy/api/v1/query",
            "/api/v1/namespaces/\(ns)/services/echo:80/proxy/",
            service.proxyBase + "/api/v1/query/x",
            service.proxyBase + "/api/v1/admin/tsdb/snapshot",
            service.proxyBase + "/api/v1/query%2F..%2F..%2Fadmin",
            service.proxyBase + "/api/v1/QUERY",
            "/api/v1/namespaces/\(ns)/pods",
            "/api/v1/namespaces/\(ns)/pods/\(fixture.echoPod)/proxy/",
            "/version",
        ]
        for path in refused {
            let answer = try await metrics.send(.GET, path, body: nil, headers: [])
            XCTAssertEqual(answer.status, 403, path)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), "Forbidden\n", path)
        }
        for path in [service.proxyBase + "/api/v1/query/../../../admin", "//" + service.queryPath.dropFirst()] {
            let answer = try await metrics.send(.GET, String(path), body: nil, headers: [])
            XCTAssertNotEqual(answer.status, 200, path)
            XCTAssertFalse(String(decoding: answer.body, as: UTF8.self).contains(fixture.echoPod), "\(path) reached the Service")
        }
        let posted = try await metrics.send(.POST, service.queryPath, body: Data("query=up".utf8), headers: [("Content-Type", "application/x-www-form-urlencoded")])
        XCTAssertEqual(posted.status, 403, "GETs only")
    }

    // MARK: Writes

    /// A writable context's socket writes; a read-only one's doesn't, and
    /// Overterm refuses before it even tries.
    func testAWriteOnAWritableSocketAndNoneOnAReadOnlyOne() async throws {
        let kind = try fixture.context("kind-fake")
        let dev = try fixture.context("fake-dev")
        let path = "/api/v1/namespaces/\(fixture.namespace)/configmaps"
        let body = Data(#"{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"acme-written"},"data":{"a":"b"}}"#.utf8)
        let created = try await proxies.sendWrite(kind, .POST, path, body: body, headers: [("Content-Type", "application/json")])
        XCTAssertEqual(created.status, 201, String(decoding: created.body.prefix(300), as: UTF8.self))
        let read = try await proxies.send(dev, .GET, path + "/acme-written")
        XCTAssertEqual(read.status, 200)
        do {
            _ = try await proxies.sendWrite(dev, .DELETE, path + "/acme-written", body: nil)
            XCTFail("a read-only context's write")
        } catch is KubeWriteRefused {}
        let refused = try await proxies.send(dev, .DELETE, path + "/acme-written")
        XCTAssertEqual(refused.status, 403, "the socket refuses it too")
        let deleted = try await proxies.sendWrite(kind, .DELETE, path + "/acme-written", body: nil)
        XCTAssertEqual(deleted.status, 200)
        let after = try await proxies.send(dev, .GET, path + "/acme-written")
        XCTAssertEqual(after.status, 404)
    }

    // MARK: can-i

    /// `kubectl auth can-i` as Overterm runs it: the cluster's admin may,
    /// a ServiceAccount nobody gave a role may not — with the server's
    /// own "no".
    func testCanIAnswers() async throws {
        let kind = try fixture.context("kind-fake")
        let viewer = try fixture.context("fake-viewer")
        for access in [KubeAccess.exec, .attach, .portForward, .logs] {
            let yes = await KubeCanIRunner.run(kind, namespace: fixture.namespace, access, configuration: configuration, planner: planner, proxies: proxies)
            XCTAssertEqual(yes, .yes, "\(access)")
            let no = await KubeCanIRunner.run(viewer, namespace: fixture.namespace, access, configuration: configuration, planner: planner, proxies: proxies)
            guard case .no = no else { return XCTFail("\(access): \(no)") }
        }
        XCTAssertEqual(fixture.calls("viewer"), 4, "a short-lived kubectl keeps nothing: the plugin runs for each question")
    }

    // MARK: The tree and the health checks

    /// A Deployment's tree read from a real cluster: its ReplicaSet and
    /// pod, the ConfigMap and the claim it uses, the Service that selects
    /// it — nothing missing.
    @MainActor
    func testADeploymentsTreeOnRealObjects() async throws {
        let kind = try fixture.context("kind-fake")
        let client = KubeClient(KubeProxyConnection(proxies: proxies, context: kind))
        let discovery = try await client.discover()
        let deployments = try XCTUnwrap(discovery.kinds.first { $0.group == "apps" && $0.resource == "deployments" })
        let detail = KubeDetailSession(
            ref: KubeObjectRef(context: "kind-fake", kind: deployments, namespace: fixture.namespace, name: "echo"), client: client, discovery: discovery)
        detail.showTree()
        detail.load()
        let read = await eventuallyOnMain(20) { detail.tree?.state == .loaded }
        XCTAssertTrue(read, "\(String(describing: detail.tree?.state))")
        let tree = try XCTUnwrap(detail.tree?.tree)
        let nodes = tree.root.all
        let said = nodes.map { "\($0.kind)/\($0.name)" }
        for wanted in ["Deployment/echo", "ConfigMap/echo-config", "PersistentVolumeClaim/echo-data", "Service/echo", "Pod/\(fixture.echoPod)"] {
            XCTAssertTrue(said.contains(wanted), "\(wanted) in \(said)")
        }
        XCTAssertTrue(nodes.contains { $0.kind == "ReplicaSet" }, "\(said)")
        XCTAssertEqual(tree.problems.map { "\($0.kind)/\($0.name)" }, [], "nothing missing: \(tree.notes)")
        XCTAssertEqual(detail.tree?.findings.map(\.check), [], "its Service selects it")
        detail.cancel()
    }

    /// The Overview's checks on the namespace: the containers without
    /// probes or limits, the Service that selects nothing — and not the
    /// one that selects the Deployment's pod.
    @MainActor
    func testTheHealthChecksOnRealObjects() async throws {
        let kind = try fixture.context("kind-fake")
        let client = KubeClient(KubeProxyConnection(proxies: proxies, context: kind))
        let discovery = try await client.discover()
        let session = KubeHealthSession()
        session.show(context: "kind-fake", scope: .namespace(fixture.namespace), discovery: discovery, client: client)
        let read = await eventuallyOnMain(20) { session.state == .loaded }
        XCTAssertTrue(read)
        let found = Set(session.report.findings.map { "\($0.check.code) \($0.subject.said)" })
        for wanted in ["K101 deployment/echo", "K102 deployment/echo", "K104 deployment/echo", "K201 service/orphan"] {
            XCTAssertTrue(found.contains(wanted), "\(wanted) in \(found.sorted()) \(session.report.notes)")
        }
        XCTAssertFalse(found.contains("K201 service/echo"), "\(found.sorted())")
        session.hide()
    }

    // MARK: Argo CD's and Flux's CRDs (docs/design/kubernetes/gitops.md, 8.5)

    /// The pinned CRDs (`Scripts/fetch-gitops-crds.sh`) applied to
    /// kind-fake — only through the script's kubeconfig, `--context
    /// kind-fake` —, then the server's own printer columns read as a Table
    /// and compared with the fake's (`FakeKubeAPI.gitOpsColumns`): names,
    /// types and priorities. What it served before is left; what it added
    /// is deleted after.
    func testGitOpsCRDsPrinterColumnsAreTheFakes() async throws {
        let run = Kubectl(kubectl: fixture.kubectl, kubeconfig: fixture.kindKubeconfig, home: fixture.home)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/gitops-crds")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".yaml") }.sorted().map {
            folder.appendingPathComponent($0).path
        }
        XCTAssertEqual(files.count, 5)
        let before = Set(try run(["get", "crd", "-o", "jsonpath={.items[*].metadata.name}"]).split(separator: " ").map(String.init))
        // Every CRD the files hold (the source controller's six, ExternalArtifact
        // among them), not only the ones the fake serves: each one added is removed.
        let applied = try Set(files.flatMap { try Self.crdNames(inYAML: String(contentsOfFile: $0, encoding: .utf8)) })
        XCTAssertTrue(applied.isSuperset(of: FakeKubeAPI.gitOpsColumns.keys), "\(applied.sorted())")
        XCTAssertTrue(applied.contains("externalartifacts.source.toolkit.fluxcd.io"))
        let added = applied.subtracting(before)
        defer {
            for name in added { _ = try? run(["delete", "crd", name, "--wait=false"]) }
        }
        // Server-side: an ApplicationSet's CRD is too large for last-applied.
        for file in files { try run(["apply", "--server-side", "--force-conflicts", "--field-manager=overterm-test", "-f", file]) }
        for name in FakeKubeAPI.gitOpsColumns.keys { try run(["wait", "--for=condition=Established", "crd/\(name)", "--timeout=60s"]) }
        let kind = try fixture.context("kind-fake")
        let client = KubeClient(KubeProxyConnection(proxies: proxies, context: kind))
        let discovery = try await client.discover()
        for (fullName, columns) in FakeKubeAPI.gitOpsColumns {
            let served = try XCTUnwrap(discovery.kinds.first { $0.fullName == fullName }, fullName)
            let table = try await client.list(served, in: .namespace(fixture.namespace))
            // The server's: Name first, then the CRD's own (Age only where the CRD has none).
            let said = table.columns.filter { $0.name != "Name" && !(columns.allSatisfy { $0.name != "Age" } && $0.name == "Age") }
            XCTAssertEqual(said.map(\.name), columns.map(\.name), fullName)
            XCTAssertEqual(said.map(\.type), columns.map(\.type), fullName)
            XCTAssertEqual(said.map(\.priority), columns.map(\.priority), fullName)
        }
    }

    // MARK: Helpers

    /// Each CustomResourceDefinition's `metadata.name` in a file of several documents.
    static func crdNames(inYAML text: String) throws -> [String] {
        let documents = try XCTUnwrap(YAMLReader.documents(text))
        return documents.compactMap { document in
            guard let document = document as? [String: Any], document["kind"] as? String == "CustomResourceDefinition" else { return nil }
            return (document["metadata"] as? [String: Any])?["name"] as? String
        }
    }

    private func eventually(_ seconds: Double, _ condition: @escaping () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    @MainActor
    private func eventuallyOnMain(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// One GET, its body; throws when the connection fails.
    private static func get(_ url: String) async throws -> String {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let (data, _) = try await URLSession(configuration: configuration).data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    /// A port nothing listens on, on 127.0.0.1.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// The cluster's objects for the suite, made once with kubectl through
/// the script's kubeconfig: a namespace of the run's own and in it a
/// Deployment (serve-hostname, its ConfigMap as env, a claim mounted, no
/// probes or limits), its Service, a Service selecting nothing, a lone pod
/// to forward to, two ServiceAccounts' tokens in memory.
private struct Fixture {
    let dir: URL
    let home: URL
    let kindKubeconfig: URL
    /// The suite's own contexts over kind's cluster and user — `fake-dev`
    /// (remote: read-only), `fake-viewer` and the `acme-*` plugins'.
    /// No credential in it: a plugin's token is in its environment.
    let extraKubeconfig: URL
    let kubectl: URL
    let namespace: String
    let echoPod: String
    let node: String
    let pluginEnvironment: [String: String]
    private let contexts: KubeContextList

    func context(_ name: String) throws -> KubeContext {
        try XCTUnwrap(contexts.context(named: name), "no context \(name)")
    }

    /// How often the plugin ran for `mode`.
    func calls(_ mode: String) -> Int {
        ((try? String(contentsOf: dir.appendingPathComponent("calls-\(mode)"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    static func make() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["OVERTERM_KUBE_TEST_KUBECONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("overterm-kind/kubeconfig")
        let kindKubeconfig = URL(fileURLWithPath: path).standardizedFileURL
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        // Never the user's: not under ~/.kube, one context, kind-fake, on 127.0.0.1.
        guard !KubeconfigSources.isUsersOwn(kindKubeconfig, home: realHome) else { throw Refused("\(path) is under ~/.kube") }
        guard FileManager.default.fileExists(atPath: kindKubeconfig.path) else {
            throw Refused("no kubeconfig at \(path): Scripts/kube-test-cluster.sh create")
        }
        let own = KubeContextList.load(files: [kindKubeconfig], settings: [:], guarded: true, home: realHome)
        guard own.contexts.map(\.name) == ["kind-fake"], let server = own.contexts.first?.server, let host = URL(string: server)?.host,
            host == "127.0.0.1" || host == "::1", own.contexts.first?.contextClass == .local
        else { throw Refused("\(path) must hold kind-fake alone, on 127.0.0.1: \(own.contexts.map { "\($0.name) \($0.server ?? "")" })") }
        let kubectl = try XCTUnwrap(
            ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"].map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) },
            "no kubectl")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-kube-real-\(UUID().uuidString)", isDirectory: true)
        let home = dir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        let namespace = "overterm-test-\(UInt32.random(in: 0...UInt32.max) % 1_000_000)"
        let run = Kubectl(kubectl: kubectl, kubeconfig: kindKubeconfig, home: home)
        do {
            try run(["apply", "-f", "-"], input: manifest(namespace))
            try run(["-n", namespace, "rollout", "status", "deployment/echo", "--timeout=240s"])
            try run(["-n", namespace, "wait", "pod/forward-me", "--for=condition=Ready", "--timeout=240s"])
            let echoPod = try run(["-n", namespace, "get", "pods", "-l", "app=echo", "-o", "jsonpath={.items[0].metadata.name}"])
            let node = try run(["get", "nodes", "-o", "jsonpath={.items[0].metadata.name}"])
            let viewer = try run(["-n", namespace, "create", "token", "viewer", "--duration=10m"])
            let token = try run(["-n", namespace, "create", "token", "default", "--duration=10m"])

            // The plugin: one script, a mode an argument, each call counted.
            let plugin = dir.appendingPathComponent("acme-credentials")
            try """
            #!/bin/sh
            echo call >> "\(dir.path)/calls-$1"
            case "$1" in
              fail) echo "Token has expired" >&2; exit 1 ;;
              bogus) token="acme-not-a-token" ;;
              token) token="$OT_TEST_TOKEN" ;;
              viewer) token="$OT_VIEWER_TOKEN" ;;
            esac
            printf '{"apiVersion":"client.authentication.k8s.io/v1","kind":"ExecCredential","status":{"token":"%s","expirationTimestamp":"2099-01-01T00:00:00Z"}}' "$token"
            """.write(to: plugin, atomically: true, encoding: .utf8)
            chmod(plugin.path, 0o700)
            func user(_ name: String, _ mode: String) -> String {
                """
                - name: \(name)
                  user:
                    exec: {apiVersion: client.authentication.k8s.io/v1, command: "\(plugin.path)", args: [\(mode)], interactiveMode: Never}
                """
            }
            let extra = dir.appendingPathComponent("acme.kubeconfig")
            try """
            apiVersion: v1
            kind: Config
            users:
            \(user("acme-fail", "fail"))
            \(user("acme-bogus", "bogus"))
            \(user("acme-token", "token"))
            \(user("acme-viewer", "viewer"))
            contexts:
            - name: fake-dev
              context: {cluster: kind-fake, user: kind-fake}
            - name: fake-viewer
              context: {cluster: kind-fake, user: acme-viewer}
            - name: acme-fail
              context: {cluster: kind-fake, user: acme-fail}
            - name: acme-bogus
              context: {cluster: kind-fake, user: acme-bogus}
            - name: acme-token
              context: {cluster: kind-fake, user: acme-token}
            """.write(to: extra, atomically: true, encoding: .utf8)
            let contexts = KubeContextList.load(files: [kindKubeconfig, extra], settings: [:], guarded: true, home: realHome)
            return Fixture(
                dir: dir, home: home, kindKubeconfig: kindKubeconfig, extraKubeconfig: extra, kubectl: kubectl, namespace: namespace, echoPod: echoPod,
                node: node,
                pluginEnvironment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "OT_TEST_TOKEN": token, "OT_VIEWER_TOKEN": viewer],
                contexts: contexts)
        } catch {
            _ = try? run(["delete", "namespace", namespace, "--wait=false"])
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// The namespace goes, with everything in it; then the folder.
    func remove() {
        let run = Kubectl(kubectl: kubectl, kubeconfig: kindKubeconfig, home: home)
        _ = try? run(["delete", "namespace", namespace, "--wait=true", "--timeout=120s"])
        try? FileManager.default.removeItem(at: dir)
    }

    private static func manifest(_ namespace: String) -> String {
        let image = "registry.k8s.io/e2e-test-images/agnhost:2.53"
        return """
            apiVersion: v1
            kind: Namespace
            metadata: {name: \(namespace), labels: {overterm.test: "1"}}
            ---
            apiVersion: v1
            kind: ServiceAccount
            metadata: {name: viewer, namespace: \(namespace)}
            ---
            apiVersion: v1
            kind: ConfigMap
            metadata: {name: echo-config, namespace: \(namespace)}
            data: {GREETING: hello}
            ---
            apiVersion: v1
            kind: PersistentVolumeClaim
            metadata: {name: echo-data, namespace: \(namespace)}
            spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 10Mi}}}
            ---
            apiVersion: apps/v1
            kind: Deployment
            metadata: {name: echo, namespace: \(namespace), labels: {app: echo}}
            spec:
              replicas: 1
              selector: {matchLabels: {app: echo}}
              template:
                metadata: {labels: {app: echo}}
                spec:
                  terminationGracePeriodSeconds: 0
                  containers:
                  - name: echo
                    image: \(image)
                    imagePullPolicy: IfNotPresent
                    args: [serve-hostname]
                    ports: [{containerPort: 9376}]
                    envFrom: [{configMapRef: {name: echo-config}}]
                    volumeMounts: [{name: data, mountPath: /data}]
                  volumes:
                  - name: data
                    persistentVolumeClaim: {claimName: echo-data}
            ---
            apiVersion: v1
            kind: Service
            metadata: {name: echo, namespace: \(namespace)}
            spec: {selector: {app: echo}, ports: [{port: 80, targetPort: 9376}]}
            ---
            apiVersion: v1
            kind: Service
            metadata: {name: orphan, namespace: \(namespace)}
            spec: {selector: {app: nobody}, ports: [{port: 80, targetPort: 9376}]}
            ---
            apiVersion: v1
            kind: Pod
            metadata: {name: forward-me, namespace: \(namespace), labels: {app: forward-me}}
            spec:
              terminationGracePeriodSeconds: 0
              containers:
              - name: echo
                image: \(image)
                imagePullPolicy: IfNotPresent
                args: [serve-hostname]
                ports: [{containerPort: 9376}]
            """
    }
}

private struct Refused: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// kubectl for the fixture: the script's kubeconfig as `KUBECONFIG` and
/// `--kubeconfig`, `--context kind-fake`, kuberc off, a HOME of its own.
/// What it prints is returned, never logged (a token is among it).
private struct Kubectl {
    let kubectl: URL
    let kubeconfig: URL
    let home: URL

    @discardableResult
    func callAsFunction(_ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = kubectl
        process.arguments = ["--kubeconfig", kubeconfig.path, "--context", "kind-fake"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "KUBECONFIG": kubeconfig.path, "KUBERC": "off"]
        let out = Pipe()
        let err = Pipe()
        let stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Refused("kubectl \(arguments.prefix(3).joined(separator: " ")): \(String(decoding: error, as: UTF8.self).prefix(400))")
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
