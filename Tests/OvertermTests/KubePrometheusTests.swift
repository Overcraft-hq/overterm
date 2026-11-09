import Foundation
import NIOHTTP1
import XCTest

@testable import Overterm

/// Prometheus per context (stage 4; docs/design/kubernetes/analysis.md,
/// 2.11, Section 4): the metrics proxy's `--accept-paths` (one Service's two
/// query paths; other Services, other paths, encoded traversal refused),
/// finding the Service as Freelens does, the queries and their range, the
/// answers read, the proxy counted in `maxProxies` and closed when no chart
/// shows, and the monitor reading only what is wanted. Against `FakeKubeAPI`
/// (its fake Prometheus behind the Service's proxy path) on a socket of the
/// test's own; the real kubectl, when installed, through a kubeconfig of
/// the test's own pointing at it on 127.0.0.1. Nothing reads ~/.kube.
@MainActor
final class KubePrometheusTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private var base: URL!
    private var dir: URL!
    private let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-server", port: "80")!

    override func setUp() async throws {
        socket = "/tmp/otkpm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addNamespace("monitoring")
        api.addPod("web-1", namespace: "shop")
        api.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        let container = ["container": "app", "image": "nginx:1.27"]
        api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: container.merging(["namespace": "shop", "pod": "web-1"]) { $1 }, value: 0.25)
        api.setPrometheusSeries(
            "container_memory_working_set_bytes", labels: container.merging(["namespace": "shop", "pod": "web-1"]) { $1 }, value: 64 * 1_048_576)
        api.setPrometheusSeries("kubelet_volume_stats_used_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 2 * 1_073_741_824)
        api.setPrometheusSeries(
            "kubelet_volume_stats_capacity_bytes", labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], value: 10 * 1_073_741_824)
        api.setPrometheusSeries(
            "kube_pod_container_resource_requests", labels: ["resource": "cpu", "namespace": "shop", "pod": "web-1", "container": "app"], value: 1.5)
        api.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "web-1", "phase": "Running"], value: 1)
        // A finished Job's pod, which kube-state-metrics keeps until it is deleted: not counted.
        api.setPrometheusSeries(
            "kube_pod_container_resource_requests", labels: ["resource": "cpu", "namespace": "shop", "pod": "migrate-x7", "container": "job"], value: 2)
        api.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "migrate-x7", "phase": "Succeeded"], value: 1)
        api.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "migrate-x7", "phase": "Running"], value: 0)
        api.setPrometheusSeries("kube_node_status_allocatable", labels: ["resource": "cpu", "node": "fake-node-1"], value: 4)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-kubeprom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: "/tmp").appendingPathComponent("otpm-\(UInt32.random(in: 0...UInt32.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests.filter { !$0.isPrometheusQuery }, [], "no subresource but Prometheus's query paths")
            api.stop()
        }
        ManagedProcess.closeAll()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: base)
    }

    private static func context(_ name: String, settings: KubeContextSettings = KubeContextSettings()) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: settings)
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var client: KubeClient { KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")) }
    private var prometheusRequests: [FakeKubeAPI.Request] { api.requests.filter(\.isPrometheusQuery) }

    // MARK: The metrics proxy's paths

    func testTheMetricsProxyAcceptsOnlyItsServicesQueryPaths() throws {
        let accepted = KubePrometheusFlags.acceptedPaths(service)
        XCTAssertEqual(accepted, #"^/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/(query|query_range)$"#)
        XCTAssertFalse(accepted.contains(","), "kubectl splits its flags on commas")
        let pattern = try NSRegularExpression(pattern: accepted)
        func passes(_ path: String) -> Bool { pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }
        XCTAssertTrue(passes(service.queryPath))
        XCTAssertTrue(passes(service.rangePath))
        let refused = [
            // Other Services, namespaces, ports.
            "/api/v1/namespaces/monitoring/services/grafana:80/proxy/api/v1/query",
            "/api/v1/namespaces/shop/services/prometheus-server:80/proxy/api/v1/query",
            "/api/v1/namespaces/monitoring/services/prometheus-server:9090/proxy/api/v1/query",
            "/api/v1/namespaces/monitoring/services/prometheus-server/proxy/api/v1/query",
            "/api/v1/namespaces/monitoring/services/https:prometheus-server:80/proxy/api/v1/query",
            // Other paths of this one's.
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/label/__name__/values",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/admin/tsdb/delete_series",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query/",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query_rangeX",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/",
            // Traversal, as kubectl decodes it before matching (`%2F` is `/`).
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query/../../../../../../pods",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query/../admin/tsdb/snapshot",
            "/api/v1/namespaces/monitoring/services/grafana:80/proxy/../../prometheus-server:80/proxy/api/v1/query/x",
            "/api/v1/namespaces/default/pods",
            "/api/v1/namespaces/monitoring/pods/prometheus-0/exec",
            "//api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query",
        ]
        for path in refused { XCTAssertFalse(passes(path), path) }
        XCTAssertFalse(passes(("/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query%2F..%2Fadmin".removingPercentEncoding)!))

        // A name's metacharacters are escaped: `.` matches only a dot.
        XCTAssertEqual(KubePrometheusFlags.escaped("a.b+c(d)|e$"), #"a\.b\+c\(d\)\|e\$"#)
        let dotted = try NSRegularExpression(pattern: "^" + KubePrometheusFlags.escaped("/a.b") + "$")
        XCTAssertNil(dotted.firstMatch(in: "/aXb", range: NSRange(location: 0, length: 4)))

        // The flags: GETs only, kubectl's own refusals kept, the pods' and nodes' proxies too.
        let arguments = KubePrometheusFlags.arguments(context: "fake-dev", socket: "/tmp/x-metrics.sock", service: service, cacheDirectory: "/tmp/c")
        XCTAssertEqual(arguments.prefix(3), ["--context=fake-dev", "--cache-dir=/tmp/c", "proxy"])
        XCTAssertTrue(arguments.contains("--accept-paths=\(accepted)"))
        XCTAssertTrue(arguments.contains("--reject-methods=\(KubeProxyFlags.rejectedMethods)"), "every method but GET")
        XCTAssertTrue(arguments.contains("--disable-filter=false"))
        XCTAssertTrue(arguments.contains("--accept-hosts=^localhost$"))
        let rejected = try XCTUnwrap(arguments.first { $0.hasPrefix("--reject-paths=") })
        XCTAssertTrue(rejected.contains("exec|attach") && rejected.contains("nodes/.*/proxy"))
        XCTAssertFalse(rejected.contains("services"), "a Service's proxy is what this one is for — narrowed by --accept-paths")

        // What Overterm sends it is checked before any socket too.
        XCTAssertTrue(service.allows(service.rangePath + "?query=up&start=1&end=2&step=30s"))
        XCTAssertFalse(service.allows(service.proxyBase + "/api/v1/series?match[]=up"))
        XCTAssertFalse(service.allows("/api/v1/namespaces/shop/pods"))
        XCTAssertEqual(try KubePrometheusFlags.socket(beside: "/tmp/ot-kube-501-1/abcdef012345.sock"), "/tmp/ot-kube-501-1/abcdef012345-metrics.sock")
        XCTAssertThrowsError(try KubePrometheusFlags.socket(beside: "/tmp/" + String(repeating: "a", count: 90) + ".sock"))
    }

    func testTheServiceIsANamespaceServiceAndPortKubernetesAllows() {
        XCTAssertEqual(KubePrometheusService(setting: "monitoring/prometheus-server:9090")?.description, "monitoring/prometheus-server:9090")
        XCTAssertEqual(KubePrometheusService(setting: " monitoring/prometheus ")?.port, "80", "the port left out is 80")
        XCTAssertEqual(KubePrometheusService(setting: "monitoring/prometheus-operated:web")?.port, "web", "a named port")
        for bad in [
            "prometheus", "monitoring/", "/prometheus", "a/b/c", "monitoring/prom:80:1", "Monitoring/prometheus", "monitoring/prom.etheus",
            "monitoring/../pods", "monitoring/prom%2F", "monitoring/prom:0", "monitoring/prom:70000", "monitoring/prom:-web", "monitoring/prom:1234567890123456",
            "monitoring/-prom", "monitoring/prom:web/x", String(repeating: "a", count: 64) + "/p",
        ] {
            XCTAssertNil(KubePrometheusService(setting: bad), bad)
        }
        // Opt-in: unset, nothing is looked for.
        XCTAssertEqual(KubePrometheusUse.of(KubeContextSettings()), .off)
        XCTAssertEqual(KubePrometheusUse.of(KubeContextSettings(metrics: .prometheus)), .detect)
        XCTAssertEqual(KubePrometheusUse.of(KubeContextSettings(metrics: .auto)), .detect, "auto, set in the entry")
        XCTAssertEqual(KubePrometheusUse.of(KubeContextSettings(metrics: .metricsServer, prometheus: "monitoring/p:80")), .off)
        XCTAssertEqual(KubePrometheusUse.of(KubeContextSettings(metrics: KubeMetricsSource.none, prometheus: "monitoring/p:80")), .off)
        XCTAssertEqual(KubePrometheusUse.of(KubeContextSettings(prometheus: "monitoring/p:80")), .configured(KubePrometheusService(setting: "monitoring/p:80")!))
        guard case .invalid = KubePrometheusUse.of(KubeContextSettings(metrics: .prometheus, prometheus: "nope")) else { return XCTFail("invalid") }
        // The entry's fields, as settings.json writes them.
        let read = KubeContextSettings(fields: ["metrics": .string("prometheus"), "prometheus": .string(" monitoring/prometheus-server:80 ")])
        XCTAssertEqual(read.metrics, .prometheus)
        XCTAssertEqual(read.prometheus, "monitoring/prometheus-server:80")
        XCTAssertTrue(KubeContextSettings.fields.contains { $0.name == "prometheus" })
    }

    // MARK: Finding it

    func testTheServiceIsFoundAsFreelensFindsIt() async throws {
        let lens = Data(#"{"kind":"Service","metadata":{"name":"prometheus","namespace":"lens-metrics"},"spec":{"ports":[{"port":80}]}}"#.utf8)
        XCTAssertEqual(KubePrometheusProvider.lens.service(in: lens)?.description, "lens-metrics/prometheus:80")
        let list = Data(
            #"{"kind":"ServiceList","items":[{"metadata":{"name":"prometheus-operated","namespace":"z"},"spec":{"ports":[{"name":"grpc","port":10901},{"name":"web","port":9090}]}},{"metadata":{"name":"prometheus-operated","namespace":"monitoring"},"spec":{"ports":[{"name":"grpc","port":10901},{"name":"web","port":9090}]}}]}"#
                .utf8)
        XCTAssertEqual(KubePrometheusProvider.operatorManaged.service(in: list)?.description, "monitoring/prometheus-operated:9090", "the first by namespace, its web port")
        XCTAssertEqual(KubePrometheusProvider.helm.service(in: list)?.port, "10901", "the chart's first port")
        XCTAssertNil(KubePrometheusProvider.helm.service(in: Data(#"{"kind":"ServiceList","items":[]}"#.utf8)))
        // The chart's labels since v15, and before.
        XCTAssertTrue(
            KubePrometheusProvider.helm.path.contains(
                "labelSelector=app.kubernetes.io%2Fname%3Dprometheus%2Capp.kubernetes.io%2Fcomponent%3Dserver%2Capp.kubernetes.io%2Fmanaged-by%3DHelm"),
            KubePrometheusProvider.helm.path)
        XCTAssertTrue(KubePrometheusProvider.helm14.path.contains("labelSelector=app%3Dprometheus%2Ccomponent%3Dserver%2Cheritage%3DHelm"))
        XCTAssertEqual(KubePrometheusProvider.allCases, [.lens, .operatorManaged, .helm, .helm14], "Lens, the operator, the chart, the old chart")
        XCTAssertEqual(KubePrometheusProvider.helm14.title, KubePrometheusProvider.helm.title)

        // Against the fake: nothing labelled, not found — each provider asked once.
        let none = await KubePrometheusMonitor.find(client)
        XCTAssertEqual(none, .unavailable(KubePrometheusState.notFound))
        XCTAssertEqual(
            api.requests.map(\.path), ["/api/v1/namespaces/lens-metrics/services/prometheus", "/api/v1/services", "/api/v1/services", "/api/v1/services"])
        XCTAssertEqual(
            api.requests.compactMap { $0.query["labelSelector"] },
            [KubePrometheusProvider.operatorSelector, KubePrometheusProvider.helmSelector, KubePrometheusProvider.helm14Selector])
        XCTAssertTrue(KubePrometheusState.notFound.contains(KubePrometheusProvider.helmSelector))
        // The old chart's Service, labelled as before v15.
        api.add(
            "services", "prometheus-server", namespace: "monitoring", labels: ["app": "prometheus", "component": "server", "heritage": "Helm"],
            fields: ["spec": ["ports": [["name": "http", "port": 80]]]])
        let old = await KubePrometheusMonitor.find(client)
        XCTAssertEqual(old, .found(service, .helm14))
        XCTAssertEqual(old.said, "Prometheus monitoring/prometheus-server:80, found as the prometheus Helm chart")
        // The current chart's: found by its app.kubernetes.io labels.
        api.delete("services", "prometheus-server", namespace: "monitoring")
        api.add(
            "services", "prometheus-server", namespace: "monitoring",
            labels: ["app.kubernetes.io/name": "prometheus", "app.kubernetes.io/component": "server", "app.kubernetes.io/managed-by": "Helm"],
            fields: ["spec": ["ports": [["name": "http", "port": 80]]]])
        let found = await KubePrometheusMonitor.find(client)
        XCTAssertEqual(found, .found(service, .helm))
        // Services refused across namespaces: said, with what to set.
        api.forbidden = ["services"]
        guard case .unavailable(let why) = await KubePrometheusMonitor.find(client) else { return XCTFail("refused") }
        XCTAssertTrue(why.contains("refused listing") && why.contains("prometheus setting"), why)
        XCTAssertEqual(prometheusRequests, [], "looking for it queries nothing")
    }

    // MARK: Queries and answers

    func testQueriesAndTheirRange() throws {
        XCTAssertEqual(
            KubeTabTesting.query("cpu", .hour),
            #"sum by (container)(rate(container_cpu_usage_seconds_total{container!="",image!="",container!="POD",namespace="shop",pod="web-1"}[4m]))"#)
        XCTAssertEqual(
            KubeTabTesting.query("memory", .hour),
            #"max by (container)(container_memory_working_set_bytes{container!="",image!="",container!="POD",namespace="shop",pod="web-1"})"#)
        XCTAssertEqual(KubePromQL.literal(#"a"b\c"#), #"a\"b\\c"#, "a label value can't end its string")
        XCTAssertEqual(
            KubePromQL.volumes(KubePromQL.volumeUsed, namespaces: ["shop"]),
            #"sum by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace="shop"})"#)
        XCTAssertEqual(
            KubePromQL.volumes(KubePromQL.volumeUsed, namespaces: ["acme-api", "acme.web"]),
            #"sum by (namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{namespace=~"acme-api|acme\\.web"})"#, "several: the set, as a regex")
        XCTAssertEqual(
            KubePromQL.volumes(KubePromQL.volumeCapacity, namespaces: nil), "sum by (namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes)")
        XCTAssertEqual(
            KubePromQL.requests("cpu"),
            #"sum(max by (namespace,pod,container,node)(kube_pod_container_resource_requests{resource="cpu"}) * on(namespace,pod) group_left() max by (namespace,pod)(kube_pod_status_phase{phase=~"Pending|Running"} == 1))"#
        )
        XCTAssertEqual(KubePromQL.allocatable("memory"), #"sum(max by (node)(kube_node_status_allocatable{resource="memory"}))"#)

        XCTAssertEqual(KubeChartRange.allCases.map(\.title), ["1h", "6h", "24h", "7d"])
        XCTAssertEqual(KubeChartRange.allCases.map { Int($0.seconds / $0.step) }, [120, 120, 120, 168])
        XCTAssertEqual(KubeChartRange.allCases.map(\.rateWindow), ["4m", "4m", "13m", "61m"], "four scrapes of a minute at least, a step and a scrape")
        let now = Date(timeIntervalSince1970: 1_800_000_017)
        let (start, end) = KubeChartRange.hour.window(now: now)
        XCTAssertEqual(end.timeIntervalSince1970, 1_800_000_000, "rounded down to a step")
        XCTAssertEqual(end.timeIntervalSince(start), 3600)
        let path = KubePromQL.rangePath(service, KubePromQL.clusterMemory, .sixHours, now: now)
        let components = try XCTUnwrap(URLComponents(string: "http://localhost" + path))
        XCTAssertEqual(components.path, service.rangePath)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["query"], KubePromQL.clusterMemory)
        XCTAssertEqual(items["step"], "3m")
        XCTAssertEqual(items["timeout"], "20s", "Prometheus gives up at 20 s, not the HTTP timeout")
        XCTAssertEqual(Int(items["end"] ?? ""), 1_800_000_000)
        XCTAssertEqual(Int(items["start"] ?? "").map { 1_800_000_000 - $0 }, 6 * 3600)
        XCTAssertTrue(service.allows(path))
        XCTAssertTrue(service.allows(KubePromQL.instantPath(service, "up")))
        // What each chart asks.
        XCTAssertEqual(KubeChart.cluster.queries(range: .hour).totals.map(\.0).count, 6, "requests, limits and allocatable, cpu and memory")
        XCTAssertEqual(KubeChart.volume(namespace: "shop", claim: "data").queries(range: .hour).series.map(\.0), [.volumeUsed, .volumeCapacity])
    }

    func testAnswersAreReadBounded() throws {
        let matrix = Data(
            #"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{"pod":"web-1"},"values":[[1800000000,"0.25"],[1800000030.5,"NaN"],[1800000060,"+Inf"],[1800000090,"0.5"]]}]}}"#
                .utf8)
        let series = try KubePrometheusReader.read(matrix)
        XCTAssertEqual(series.first?.labels, ["pod": "web-1"])
        XCTAssertEqual(series.first?.points.map(\.value), [0.25, 0.5], "values that aren't numbers left out")
        XCTAssertEqual(series.first?.points.last?.time, Date(timeIntervalSince1970: 1_800_000_090))
        let vector = Data(#"{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1800000000.1,"1.5"]}]}}"#.utf8)
        XCTAssertEqual(KubePrometheusReader.value(try KubePrometheusReader.read(vector)), 1.5)
        XCTAssertNil(KubePrometheusReader.value(try KubePrometheusReader.read(Data(#"{"status":"success","data":{"resultType":"vector","result":[]}}"#.utf8))))
        XCTAssertThrowsError(try KubePrometheusReader.read(Data(#"{"status":"error","errorType":"bad_data","error":"parse error"}"#.utf8), status: 400)) {
            XCTAssertEqual(($0 as? KubePrometheusReader.Failure)?.message, "Prometheus refused the query: parse error.")
        }
        XCTAssertThrowsError(try KubePrometheusReader.read(Data("Forbidden".utf8), status: 403)) {
            XCTAssertEqual(($0 as? KubePrometheusReader.Failure)?.message, "Overterm's metrics proxy refused this path.", "the metrics proxy's own filter")
        }
        XCTAssertThrowsError(
            try KubePrometheusReader.read(Data(#"{"kind":"Status","message":"no endpoints available for service \"prometheus-server\""}"#.utf8), status: 503)
        ) { XCTAssertTrue(($0 as? KubePrometheusReader.Failure)?.message.contains("no endpoints") == true) }
        // Bounded: a runaway query's thousands of series and points.
        let many = (0..<2500).map { #"{"metric":{"i":"\#($0)"},"value":[1,"1"]}"# }.joined(separator: ",")
        XCTAssertEqual(try KubePrometheusReader.read(Data(#"{"status":"success","data":{"result":[\#(many)]}}"#.utf8)).count, KubePrometheusReader.maxSeries)

        // A claim's usage, by namespace and claim.
        let used = [KubeSeries(labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], points: [KubeSeriesPoint(time: Date(), value: 2_147_483_648)])]
        let capacity = [KubeSeries(labels: ["namespace": "shop", "persistentvolumeclaim": "data-db-0"], points: [KubeSeriesPoint(time: Date(), value: 10_737_418_240)])]
        let usage = KubeVolumeUsage.by(used: used, capacity: capacity)[KubeRowID(namespace: "shop", name: "data-db-0")]
        XCTAssertEqual(usage?.text, "2.0Gi of 10Gi (20%)")
        XCTAssertEqual(KubeVolumeFormat.bytes(512), "512B")
        XCTAssertEqual(KubeVolumeFormat.bytes(1_572_864), "1.5Mi")
    }

    func testTheFakesPrometheusAnswersOnlyItsQueryPaths() async throws {
        let direct = KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: service)
        let now = Date()
        let range = try await direct.query(KubePromQL.rangePath(service, try XCTUnwrap(KubeTabTesting.query("cpu", .hour)), .hour, now: now))
        XCTAssertEqual(range.status, 200)
        let points = KubePrometheusReader.points(try KubePrometheusReader.read(range.body))
        XCTAssertEqual(points.count, 121)
        XCTAssertEqual(points.last?.value, 0.25)
        let volumes = try await direct.query(KubePromQL.instantPath(service, KubePromQL.volumes(KubePromQL.volumeUsed, namespaces: ["shop"])))
        XCTAssertEqual(try KubePrometheusReader.read(volumes.body).first?.labels, ["namespace": "shop", "persistentvolumeclaim": "data-db-0"])
        // Directly too, only the two paths: refused before the socket.
        do {
            _ = try await direct.query(service.proxyBase + "/api/v1/series")
            XCTFail("refused")
        } catch let refused as KubePrometheusRefused {
            XCTAssertTrue(refused.path.hasSuffix("/series"))
        }
        // And the fake refuses another Service's proxy, as the flags would.
        let other = try await KubeSocketConnection(socket: socket, context: "fake-dev").get(
            "/api/v1/namespaces/monitoring/services/grafana:80/proxy/api/v1/query", headers: [])
        XCTAssertEqual(other.status, 403)
        XCTAssertEqual(prometheusRequests.count, 3)
    }

    // MARK: The budget

    func testTheMetricsProxyCountsTowardsMaxProxiesAndClosesWhenNoChartShows() async throws {
        let opened = Box<[KubeProxySpec]>([])
        let closed = Box<[String]>([])
        let socket = self.socket!
        let proxies = KubeProxies(
            configuration: KubeProxies.Configuration(maxProxies: 2), sweepEvery: .seconds(3600),
            plan: { context, _, _ in
                KubeProxySpec(
                    context: context.name, readOnly: !context.isWritable, kubectl: URL(fileURLWithPath: "/stand-in/kubectl"),
                    socket: "/tmp/\(KubeSocketFolder.name(for: context.name))", environment: [:], cacheDirectory: nil, signIn: .none)
            },
            open: { spec in
                opened.update { $0.append(spec) }
                let label = spec.prometheus == nil ? spec.context : spec.context + " (prometheus)"
                return KubeProxy(
                    context: spec.context, readOnly: spec.readOnly, signIn: .none, transport: UnixHTTPTransport.kubernetes(socket: socket, context: spec.context),
                    isRunning: { true }, close: { closed.update { $0.append(label) } })
            })
        let dev = Self.context("fake-dev", settings: KubeContextSettings(metrics: .prometheus))
        let kind = Self.context("kind-fake")
        _ = try await proxies.send(dev, .GET, "/api/v1/namespaces/shop/pods")
        let answered = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        XCTAssertEqual(answered.status, 200)
        var connected = await proxies.proxyLabels
        XCTAssertEqual(connected, ["fake-dev", "fake-dev (prometheus)"], "a second proxy of the context's own")
        let metrics = try XCTUnwrap(opened.value.last)
        XCTAssertEqual(metrics.prometheus, service)
        XCTAssertTrue(metrics.readOnly)
        XCTAssertTrue(metrics.socket.hasSuffix("-metrics.sock"))
        XCTAssertTrue(metrics.arguments.contains("--accept-paths=\(KubePrometheusFlags.acceptedPaths(service))"))
        XCTAssertFalse(metrics.arguments.contains { $0.hasPrefix("--reject-paths=") && $0.contains("services") })
        XCTAssertEqual(opened.value.first?.prometheus, nil, "the context's own proxy has its own flags")
        let reused = try await proxies.sendPrometheus(dev, service, KubePromQL.rangePath(service, KubePromQL.clusterMemory, .hour, now: Date()))
        XCTAssertEqual(reused.status, 200)
        XCTAssertEqual(opened.value.count, 2, "kept while charts ask")

        // Anything but its two paths is refused before the socket.
        let before = api.requests.count
        do {
            _ = try await proxies.sendPrometheus(dev, service, "/api/v1/namespaces/shop/secrets")
            XCTFail("refused")
        } catch is KubePrometheusRefused {}
        XCTAssertEqual(api.requests.count, before)

        // A slot like any: with two, another context's request takes the idle metrics proxy's.
        _ = try await proxies.send(kind, role: .background, .GET, "/api/v1/namespaces/shop/pods")
        connected = await proxies.proxyLabels
        XCTAssertEqual(connected, ["fake-dev", "kind-fake"], "the page's own kept, the metrics proxy given up")
        XCTAssertEqual(closed.value, ["fake-dev (prometheus)"])

        // Opened again for a chart, and closed when none shows.
        _ = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        connected = await proxies.proxyLabels
        XCTAssertTrue(connected.contains("fake-dev (prometheus)"))
        XCTAssertEqual(connected.count, 2, "never more than maxProxies")
        await proxies.closePrometheus("fake-dev")
        connected = await proxies.proxyLabels
        XCTAssertFalse(connected.contains("fake-dev (prometheus)"))
        XCTAssertTrue(connected.contains("fake-dev"), "the context's own proxy stays")
        XCTAssertEqual(closed.value.filter { $0 == "fake-dev (prometheus)" }.count, 2)
    }

    /// Proxies whose kubectl is a stand-in: each "proxy" a connection to
    /// the fake's socket, its opens and closes recorded.
    private func standIn(maxProxies: Int = 4) -> (KubeProxies, opened: Box<[KubeProxySpec]>, closed: Box<[String]>) {
        let opened = Box<[KubeProxySpec]>([])
        let closed = Box<[String]>([])
        let socket = self.socket!
        let proxies = KubeProxies(
            configuration: KubeProxies.Configuration(maxProxies: maxProxies), sweepEvery: .seconds(3600),
            plan: { context, _, _ in
                KubeProxySpec(
                    context: context.name, readOnly: !context.isWritable, kubectl: URL(fileURLWithPath: "/stand-in/kubectl"),
                    socket: "/tmp/\(KubeSocketFolder.name(for: context.name))", environment: [:], cacheDirectory: nil, signIn: .none)
            },
            open: { spec in
                opened.update { $0.append(spec) }
                let label = spec.prometheus == nil ? spec.context : spec.context + " (prometheus)"
                return KubeProxy(
                    context: spec.context, readOnly: spec.readOnly, signIn: .none, transport: UnixHTTPTransport.kubernetes(socket: socket, context: spec.context),
                    isRunning: { true }, close: { closed.update { $0.append(label) } })
            })
        return (proxies, opened, closed)
    }

    /// The page context's metrics proxy is the page's while its charts
    /// show: attention watches and spare reads never close it (closed for
    /// one, the next chart poll would close a watch, every refresh), and it
    /// isn't counted in the background's slots.
    func testWatchesNeverTakeThePageChartsProxy() async throws {
        let (proxies, opened, closed) = standIn(maxProxies: 4)
        let dev = Self.context("fake-dev", settings: KubeContextSettings(metrics: .prometheus))
        _ = try await proxies.send(dev, .GET, "/api/v1/namespaces/shop/pods")
        _ = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        for name in ["acme-a", "acme-b", "acme-c"] {
            _ = try await proxies.send(Self.context(name), role: .watch, .GET, "/api/v1/namespaces/shop/pods")
        }
        let labels = await proxies.proxyLabels
        XCTAssertEqual(labels, ["acme-b", "acme-c", "fake-dev", "fake-dev (prometheus)"], "a watch closed another watch's, not the charts'")
        XCTAssertEqual(closed.value, ["acme-a"])
        // A spare read: no slot free as it stands, nothing closed for it.
        do {
            _ = try await proxies.send(Self.context("acme-d"), role: .spare, .GET, "/api/v1/namespaces/shop/pods")
            XCTFail("no slot")
        } catch let problem as KubeProxyProblem {
            XCTAssertEqual(problem, .noSlot(max: 4))
        }
        // The next chart read opens nothing again, and closes nothing for the page.
        let before = opened.value.count
        _ = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        XCTAssertEqual(opened.value.count, before)
        let forPage = await proxies.closedForPage
        XCTAssertEqual(forPage, [])
        XCTAssertEqual(closed.value, ["acme-a"])
        // `connected` names contexts — what `close` takes, the charts' proxy with its context's.
        let connected = await proxies.connected
        XCTAssertEqual(connected, ["acme-b", "acme-c", "fake-dev"])
        await proxies.close("fake-dev")
        let has = await proxies.hasPrometheusProxy("fake-dev")
        XCTAssertFalse(has)
    }

    /// A Service's answer is a process in the cluster talking: a plain 500
    /// saying "getting credentials" is the chart's problem, never a stop of
    /// the context's requests. kubectl's own stderr saying so is.
    func testAPrometheusAnswerNeverStopsTheContext() async throws {
        let (proxies, _, _) = standIn()
        let dev = Self.context("fake-dev", settings: KubeContextSettings(metrics: .prometheus))
        api.failPrometheus(500, "getting credentials: exec: executable aws failed with exit code 255")
        let answer = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        XCTAssertEqual(answer.status, 500)
        XCTAssertThrowsError(try KubePrometheusReader.read(answer.body, status: answer.status)) {
            XCTAssertTrue(($0 as? KubePrometheusReader.Failure)?.message.hasPrefix("Prometheus answered 500") == true, "\($0)")
        }
        let status = await proxies.status(of: "fake-dev")
        if case .stopped = status { XCTFail("stopped by a Service's answer") }
        let pods = try await proxies.send(dev, .GET, "/api/v1/namespaces/shop/pods")
        XCTAssertEqual(pods.status, 200, "the context's own proxy still answers")
        let again = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        XCTAssertEqual(again.status, 500, "and the charts keep asking")
        // kubectl's own failure, as it logs it, does stop it.
        let logged = "E1106 10:00:00.000000 proxy_server.go:147] Error while proxying request: getting credentials: exec: executable aws failed with exit code 255"
        XCTAssertEqual(KubeProxies.metricsProblem(status: 500, stderr: "I1106 started\n" + logged, signIn: .none)?.stopsRequests, true)
        XCTAssertNil(KubeProxies.metricsProblem(status: 500, stderr: "I1106 Starting to serve on /tmp/x-metrics.sock", signIn: .none))
        XCTAssertNil(KubeProxies.metricsProblem(status: 200, stderr: logged, signIn: .none))
        // Too large an answer isn't parsed.
        XCTAssertThrowsError(try KubePrometheusReader.read(Data(count: KubePrometheusReader.maxBytes + 1))) {
            XCTAssertTrue(($0 as? KubePrometheusReader.Failure)?.message.contains("too large") == true)
        }
    }

    // MARK: The monitor

    /// Where Prometheus is is found once: the page hiding (the model's
    /// `update(nil)`) and showing again looks for nothing; another cluster
    /// under the name, or another use, looks again. No transport for a
    /// moment (Kubernetes off, the kubeconfig read again): tried again.
    func testWhereItIsIsKeptWhileThePageHides() async throws {
        let monitor = KubePrometheusMonitor()
        monitor.interval = .milliseconds(80)
        let socket = self.socket!
        let reachable = Box(false)
        let owner = NSObject()
        api.add(
            "services", "prometheus-server", namespace: "monitoring",
            labels: ["app.kubernetes.io/name": "prometheus", "app.kubernetes.io/component": "server", "app.kubernetes.io/managed-by": "Helm"],
            fields: ["spec": ["ports": [["port": 80]]]])
        func update(_ situation: KubePrometheusMonitor.Situation?) {
            monitor.update(
                situation, client: { KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")) },
                transport: { reachable.value ? KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: $0) : nil },
                close: { _ in })
        }
        let dev = KubePrometheusMonitor.Situation(context: "fake-dev", use: .detect, scope: .namespace("shop"), cluster: "a")
        monitor.want([.chart(.cluster)], for: owner)
        update(dev)
        try await until(5, "found") { monitor.state == .found(service, .helm) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(monitor.isPolling, "no transport yet: not given up")
        XCTAssertNil(monitor.charts[.cluster])
        reachable.update { $0 = true }
        try await until(5, "charted once it can be") { monitor.charts[.cluster]?.read != nil }

        // Hidden as the model hides it, shown again: no second lookup.
        update(nil)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(monitor.state, .off)
        api.forgetRequests()
        update(dev)
        XCTAssertEqual(monitor.state, .found(service, .helm), "known at once")
        try await until(5, "charted again") { monitor.charts[.cluster]?.read != nil }
        XCTAssertEqual(monitor.detections, 1)
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/services" || $0.path.hasPrefix("/api/v1/namespaces/lens-metrics") }, "\(api.requests.map(\.path))")

        // Another cluster under the name: looked for again.
        var moved = dev
        moved.cluster = "b"
        update(moved)
        try await until(5, "found again") { monitor.detections == 2 && monitor.state == .found(service, .helm) }
        // Another use, and back: forgotten, looked for again.
        update(KubePrometheusMonitor.Situation(context: "fake-dev", use: .configured(service), scope: .namespace("shop"), cluster: "b"))
        XCTAssertEqual(monitor.state, .found(service, nil))
        update(moved)
        try await until(5, "looked for after the use changed") { monitor.detections == 3 && monitor.state == .found(service, .helm) }
        monitor.want([], for: owner)
    }

    /// A chart hidden while its reading is on its way (a query answering
    /// slowly): no query after, and the metrics proxy closed once the
    /// reading stopped — never opened again by a query already going.
    func testAChartHiddenMidReadLeavesNoMetricsProxy() async throws {
        let (proxies, _, _) = standIn()
        let monitor = KubePrometheusMonitor()
        monitor.interval = .milliseconds(80)
        let owner = NSObject()
        let dev = Self.context("fake-dev", settings: KubeContextSettings(metrics: .prometheus))
        api.answerSlowly(service.rangePath, milliseconds: 400)
        monitor.update(
            KubePrometheusMonitor.Situation(context: "fake-dev", use: .configured(service), scope: .namespace("shop")), client: { nil },
            transport: { KubePrometheusProxyConnection(proxies: proxies, context: dev, service: $0) },
            close: { name in Task { await proxies.closePrometheus(name) } })
        monitor.want([.chart(.cluster)], for: owner)
        // The probe answers at once; the chart's range query is the slow one.
        func ranges() -> Int { self.prometheusRequests.filter { $0.path == self.service.rangePath }.count }
        try await until(5, "a query on its way") { ranges() >= 1 }
        monitor.want([], for: owner)
        XCTAssertFalse(monitor.isPolling)
        let deadline = Date().addingTimeInterval(5)
        while await proxies.hasPrometheusProxy("fake-dev"), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(800))
        let left = await proxies.hasPrometheusProxy("fake-dev")
        XCTAssertFalse(left, "the metrics proxy closed, and not opened again")
        XCTAssertEqual(ranges(), 1, "no query after the chart hid")
        XCTAssertEqual(monitor.closing, 0)
    }

    func testTheMonitorReadsOnlyWhatShowsAndClosesTheProxyAfter() async throws {
        let monitor = KubePrometheusMonitor()
        monitor.interval = .milliseconds(80)
        let closed = Box<[String]>([])
        let socket = self.socket!
        let service = self.service
        let owner = NSObject()
        func update(_ use: KubePrometheusUse, scope: KubeScope = .namespace("shop")) {
            monitor.update(
                KubePrometheusMonitor.Situation(context: "fake-dev", use: use, scope: scope),
                client: { KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev")) },
                transport: { KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: $0) },
                close: { name in closed.update { $0.append(name) } })
        }
        // Opted out: nothing looked for, whatever shows.
        update(.off)
        monitor.want([.chart(.cluster), .volumes], for: owner)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(monitor.state, .off)
        XCTAssertEqual(api.requests, [], "a context without Prometheus is asked nothing")

        // Opted in, nothing shown: nothing asked, not even where it is.
        monitor.want([], for: owner)
        update(.detect)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(api.requests, [])
        XCTAssertEqual(monitor.detections, 0)

        // A chart shows: found, then queried over the range.
        api.add(
            "services", "prometheus-server", namespace: "monitoring",
            labels: ["app.kubernetes.io/name": "prometheus", "app.kubernetes.io/component": "server", "app.kubernetes.io/managed-by": "Helm"],
            fields: ["spec": ["ports": [["port": 80]]]])
        let hour = KubeTabTesting.request(.hour)
        monitor.want([.tab(hour), .volumes], for: owner)
        try await until(5, "found") { monitor.state == .found(service, .helm) }
        // Nothing probed (the fake can't say): a minute's scrape assumed, an hour at a minute's step.
        try await until(5, "charted") { monitor.tabs[hour]?.results["cpu"]?.first?.points.count == 61 }
        let reading = try XCTUnwrap(monitor.tabs[hour])
        XCTAssertEqual(reading.results["memory"]?.first?.points.last?.value, 64 * 1_048_576)
        XCTAssertEqual(reading.span?.step, 60)
        try await until(5, "volumes") { monitor.volumes?.read != nil }
        XCTAssertEqual(monitor.volumeCell(KubeRowID(namespace: "shop", name: "data-db-0")).text, "2.0Gi of 10Gi (20%)")
        guard case .dash(let why) = monitor.volumeCell(KubeRowID(namespace: "shop", name: "unbound")) else { return XCTFail("a dash") }
        XCTAssertTrue(why.contains("kubelet_volume_stats"))
        let ranges = prometheusRequests.filter { $0.path.hasSuffix("query_range") }
        XCTAssertEqual(ranges.first?.query["step"], "1m")
        // Asked again every refresh: within a step nothing new (the cache's), past it only the tail.
        try await Task.sleep(for: .milliseconds(400))
        let again = prometheusRequests.filter { $0.path.hasSuffix("query_range") }.dropFirst(2)
        XCTAssertTrue(
            again.allSatisfy { Double($0.query["start"] ?? "") ?? 0 > Double(ranges.first?.query["start"] ?? "") ?? 0 }, "\(again.map(\.query))")

        // Another range: asked with its step.
        let week = KubeTabTesting.request(.week)
        monitor.range = .week
        monitor.want([.tab(week), .volumes], for: owner)
        try await until(5, "a week") { monitor.tabs[week]?.read != nil }
        XCTAssertNil(monitor.tabs[hour], "the hour's reading gone with its want")
        XCTAssertTrue(prometheusRequests.contains { $0.query["step"] == "30m" })

        // Hidden: reading ends, what was read goes, the metrics proxy is closed.
        monitor.want([], for: owner)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertTrue(monitor.charts.isEmpty && monitor.volumes == nil)
        try await until(5, "closed once the readings stopped") { closed.value == ["fake-dev"] }
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(api.requests, [], "nothing read while hidden")

        // Shown again: where it is is known; no second lookup.
        monitor.want([.chart(.cluster)], for: owner)
        try await until(5, "cluster") { monitor.charts[.cluster]?.read != nil }
        let cluster = try XCTUnwrap(monitor.charts[.cluster])
        XCTAssertEqual(cluster.share(.cpuRequests, of: .cpuAllocatable)?.percent, 38, "1.5 of 4 cores requested; the finished Job's 2 not counted")
        XCTAssertNil(cluster.totals[.memoryLimits], "kube-state-metrics has none: none said")
        XCTAssertEqual(monitor.detections, 1)
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/api/v1/services") })
        // Still a week: the cluster's raw lines aren't asked, and it says why; its totals are.
        XCTAssertEqual(cluster.range, .week)
        XCTAssertEqual(cluster.refused, KubeChart.rawRefusal(.week))
        XCTAssertTrue(cluster.series.isEmpty)
        XCTAssertFalse(prometheusRequests.contains { $0.path.hasSuffix("query_range") }, "\(prometheusRequests.map(\.query))")
        XCTAssertTrue(prometheusRequests.allSatisfy { $0.query["timeout"] == "20s" })
        // 6h: drawn, at a rate window of four scrapes.
        monitor.range = .sixHours
        try await until(5, "6h") { monitor.charts[.cluster]?.range == .sixHours && monitor.charts[.cluster]?.read != nil }
        XCTAssertNil(monitor.charts[.cluster]?.refused)
        XCTAssertEqual(monitor.charts[.cluster]?.series[.cpu]?.count, 121)
        XCTAssertTrue(prometheusRequests.contains { $0.path.hasSuffix("query_range") && $0.query["query"]?.contains("[4m]") == true })
        monitor.want([], for: owner)
    }

    /// A monitor reading `fake-dev`'s configured Service straight off the
    /// fake's socket, in `scope`.
    private func configuredMonitor(scope: KubeScope) -> KubePrometheusMonitor {
        let monitor = KubePrometheusMonitor()
        monitor.interval = .milliseconds(80)
        let socket = self.socket!
        monitor.update(
            KubePrometheusMonitor.Situation(context: "fake-dev", use: .configured(service), scope: scope), client: { nil },
            transport: { KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: $0) },
            close: { _ in })
        return monitor
    }

    /// The PVC list's Used column with several namespaces picked: asked
    /// for those namespaces (a regex of them, escaped), never the cluster's
    /// — a claim of the same name in a namespace not picked isn't read.
    func testThePVCColumnAsksOnlyTheNamespacesPicked() async throws {
        let claim = ["persistentvolumeclaim": "data-db-0"]
        for (namespace, used) in [("acme.web", 3.0), ("acmexweb", 7.0), ("billing", 9.0)] {
            let labels = claim.merging(["namespace": namespace]) { $1 }
            api.setPrometheusSeries("kubelet_volume_stats_used_bytes", labels: labels, value: used * 1_073_741_824)
            api.setPrometheusSeries("kubelet_volume_stats_capacity_bytes", labels: labels, value: 10 * 1_073_741_824)
        }
        let monitor = configuredMonitor(scope: KubeScope.of(["shop", "acme.web"]))
        let owner = NSObject()
        monitor.want([.volumes], for: owner)
        try await until(5, "volumes") { monitor.volumes?.read != nil }
        let queries = prometheusRequests.compactMap { $0.query["query"] }
        XCTAssertEqual(queries.count, 2, "\(queries)")
        XCTAssertTrue(queries.allSatisfy { $0.contains(#"namespace=~"acme\\.web|shop""#) }, "\(queries)")
        let usage = try XCTUnwrap(monitor.volumes?.usage)
        XCTAssertEqual(
            Set(usage.keys), [KubeRowID(namespace: "shop", name: "data-db-0"), KubeRowID(namespace: "acme.web", name: "data-db-0")],
            "billing isn't picked, and the dot is no wildcard")
        XCTAssertEqual(monitor.volumeCell(KubeRowID(namespace: "acme.web", name: "data-db-0")).text, "3.0Gi of 10Gi (30%)")
        XCTAssertNil(usage[KubeRowID(namespace: "billing", name: "data-db-0")])
        monitor.want([], for: owner)
    }

    /// The Pods list's shares (metrics.md 2.1, M5b): one instant query of
    /// kube-state-metrics a namespace picked — none across every namespace,
    /// which is said instead — read into each pod's requests and limits;
    /// gone with the want.
    func testThePodsSharesAskKubeStateMetricsOnceANamespace() async throws {
        // kube-state-metrics' raw series, evaluated by the fake: the query's own semantics, not a fixture's answer.
        for namespace in ["shop", "billing"] {
            let pod = ["namespace": namespace, "pod": "web-1", "container": "app"]
            api.setPrometheusSeries("kube_pod_container_info", labels: pod, value: 1)
            api.setPrometheusSeries("kube_pod_container_resource_requests", labels: pod.merging(["resource": "cpu"]) { $1 }, value: 0.5)
            api.setPrometheusSeries("kube_pod_container_resource_limits", labels: pod.merging(["resource": "memory"]) { $1 }, value: 128 * 1_048_576)
        }
        let monitor = configuredMonitor(scope: KubeScope.of(["shop", "billing"]))
        let owner = NSObject()
        monitor.want([.shares], for: owner)
        try await until(5, "shares") { monitor.shares?.read != nil }
        let asked = prometheusRequests.filter { $0.query["query"]?.contains("kube_pod_container_info") == true }
        XCTAssertEqual(asked.count, 2, "one a namespace: \(asked.map(\.query))")
        XCTAssertTrue(asked.allSatisfy { $0.path == service.queryPath && $0.query["timeout"] == "20s" }, "instant, with its timeout")
        XCTAssertEqual(Set(asked.compactMap { $0.query["query"]?.contains(#"namespace="shop""#) }), [true, false])
        let used = KubeUsage(cpu: 0.25, memory: 96 * 1_048_576)
        XCTAssertEqual(monitor.shareCell(.cpuRequest, KubeRowID(namespace: "billing", name: "web-1"), used: used).text, "50%")
        XCTAssertEqual(monitor.shareCell(.memoryLimit, KubeRowID(namespace: "shop", name: "web-1"), used: used).text, "75%")
        XCTAssertEqual(
            monitor.shareCell(.cpuLimit, KubeRowID(namespace: "shop", name: "web-1"), used: used).help,
            "Not every container of this pod has a CPU limit: the pod has none as a whole.")
        monitor.want([], for: owner)
        XCTAssertNil(monitor.shares)

        // Every namespace: none asked, why said.
        api.forgetRequests()
        let across = configuredMonitor(scope: .all)
        across.want([.shares], for: owner)
        try await until(5, "said") { across.shares?.unavailable != nil }
        XCTAssertEqual(across.shareCell(.cpuRequest, KubeRowID(namespace: "shop", name: "web-1"), used: used).help, KubeChartEmpty.sharesNeedNamespaces.sentence)
        XCTAssertFalse(prometheusRequests.contains { $0.query["query"]?.contains("kube_pod_container_info") == true }, "\(prometheusRequests)")
        across.want([], for: owner)
    }

    /// Every query of a chart may come back partial (Thanos, federation),
    /// each with its own warning: the chart keeps three notes in all, not
    /// three a query, and a read that fails doesn't leave the last good
    /// read's notes beside its problem.
    func testAChartKeepsThreeNotesAndNoneBesideAProblem() async throws {
        api.setPrometheusMatrix("container_cpu_usage_seconds_total", warnings: ["store eu-1 timed out", "store eu-2 timed out"])
        api.setPrometheusMatrix("container_memory_working_set_bytes", warnings: ["store eu-2 timed out", "store us-1 timed out", "store us-2 timed out"])
        let monitor = configuredMonitor(scope: .namespace("shop"))
        let owner = NSObject()
        let pod = KubeTabTesting.request(.hour, families: [.cpu, .memory])
        monitor.want([.tab(pod)], for: owner)
        try await until(5, "charted") { monitor.tabs[pod]?.read != nil }
        let reading = try XCTUnwrap(monitor.tabs[pod])
        XCTAssertEqual(reading.results["cpu"]?.first?.points.last?.value, 0.25, "the evaluated answer, the warnings beside it")
        XCTAssertEqual(
            reading.notes, ["Partial answer: store eu-1 timed out", "Partial answer: store eu-2 timed out", "Partial answer: store us-1 timed out"],
            "de-duplicated, then three for the chart")
        XCTAssertNil(reading.problem)

        api.failPrometheus(503, "upstream connect error")
        // Within a step a refresh asks nothing new: the kept answers forgotten, it asks again.
        monitor.forgetCaches()
        try await until(5, "the problem") { monitor.tabs[pod]?.problem != nil }
        XCTAssertEqual(monitor.tabs[pod]?.notes, [], "the last read's notes gone with it")
        XCTAssertEqual(monitor.tabs[pod]?.results["cpu"]?.first?.points.last?.value, 0.25, "a failed query keeps its last answer")
        monitor.want([], for: owner)
    }

    /// A fixture matched by a fragment the query contains (whitespace
    /// aside), never by parsing it: a query `FakePromQL` can't read is
    /// answered by its lines, functions of t with gaps; its failure is the
    /// answer when it has one; a query neither reads is `bad_data`.
    func testTheFakesFixturesAreMatchedByAFragment() async throws {
        let direct = KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: "fake-dev"), service: service)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let peak = #"max_over_time(sum(container_memory_working_set_bytes{namespace="shop"})[1h:1m])"#
        let unread = try await direct.query(KubePromQL.rangePath(service, peak, .hour, now: now))
        XCTAssertEqual(unread.status, 400, "FakePromQL doesn't read subqueries")
        XCTAssertThrowsError(try KubePrometheusReader.read(unread.body, status: unread.status)) {
            XCTAssertTrue(($0 as? KubePrometheusReader.Failure)?.message.hasPrefix("Prometheus refused the query:") == true)
        }

        // Every other step missing: a gap where the line has none.
        api.setPrometheusMatrix(
            "max_over_time( sum(container_memory_working_set_bytes",
            [FakePromFixture.Line(["pod": "web-1"]) { time in Int(time / 30) % 2 == 0 ? time - 1_799_996_400 : nil }])
        let answered = try await direct.query(KubePromQL.rangePath(service, peak, .hour, now: now))
        let series = try KubePrometheusReader.read(answered.body)
        XCTAssertEqual(series.first?.labels, ["pod": "web-1"])
        XCTAssertEqual(series.first?.points.count, 61)
        XCTAssertEqual(series.first?.points.last?.value, 3600, "a function of t, not FakePromQL's ramp")
        let instant = try await direct.query(KubePromQL.instantPath(service, peak))
        XCTAssertEqual(instant.status, 200, "an instant query is answered by the same fixture")

        api.setPrometheusMatrix("max_over_time(", failure: FakePromFixture.Failure(status: 503, errorType: "timeout", error: "query timed out"))
        let failed = try await direct.query(KubePromQL.rangePath(service, peak, .hour, now: now))
        XCTAssertThrowsError(try KubePrometheusReader.read(failed.body, status: failed.status)) {
            XCTAssertEqual(($0 as? KubePrometheusReader.Failure)?.message, KubePrometheusReader.tookTooLong)
        }
        XCTAssertTrue(FakePromFixture(fragment: "rate(x[5m])").matches("sum( rate( x[5m] ) )"))
        XCTAssertFalse(FakePromFixture(fragment: "rate(x[5m])").matches("rate(x[1m])"))
    }

    // MARK: The real kubectl

    /// The real `kubectl proxy`, started as the metrics proxy, in front of
    /// the fake on 127.0.0.1 through a kubeconfig of the test's own: one
    /// Service's queries pass; another Service, another path, a write,
    /// encoded traversal and the API itself get 403. Skipped without kubectl.
    func testTheRealKubectlMetricsProxyAcceptsOnlyTheQueries() async throws {
        // Wherever it is installed (Intel's /usr/local/bin, Apple silicon's /opt/homebrew/bin…).
        guard let kubectl = KubectlLocator.candidates(configured: "", guarded: false, loginPath: nil, home: FileManager.default.homeDirectoryForCurrentUser).first
        else { throw XCTSkip("no kubectl") }
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
        var planner = KubeProxyPlanner(folder: KubeSocketFolder(base: base))
        planner.guarded = true
        planner.home = dir.appendingPathComponent("home", isDirectory: true)
        planner.kubeconfigs = { _ in [kubeconfig] }
        planner.baseEnvironment = { ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()] }
        let real = planner
        let proxies = KubeProxies(
            configuration: KubeProxies.Configuration(kubectlPath: kubectl.path), plan: { try await real.plan($0, configuration: $1, serverMinor: $2) })
        defer { proxies.closeAll() }
        let dev = KubeContext(
            name: "fake-dev", cluster: "fake", server: "http://127.0.0.1:\(port)", namespace: nil, user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings(metrics: .prometheus))

        let query = try await proxies.sendPrometheus(dev, service, KubePromQL.instantPath(service, KubePromQL.requests("cpu")))
        XCTAssertEqual(query.status, 200)
        XCTAssertEqual(KubePrometheusReader.value(try KubePrometheusReader.read(query.body)), 1.5)
        let range = try await proxies.sendPrometheus(dev, service, KubePromQL.rangePath(service, KubePromQL.clusterMemory, .hour, now: Date()))
        XCTAssertEqual(range.status, 200)

        let socket = try KubePrometheusFlags.socket(beside: try planner.folder.socket(for: "fake-dev"))
        let raw = UnixHTTPTransport(address: .unix(socket), host: "localhost", readinessPath: "/version", service: "test")
        let refused = [
            "/api/v1/namespaces/monitoring/services/grafana:80/proxy/api/v1/query",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/label/__name__/values",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/admin/tsdb/snapshot",
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query%2Fx",
            // RE2's `$` is the text's end, not before a newline (NSRegularExpression's is).
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query%0A",
            "/api/v1/namespaces/shop/pods", "/api/v1/namespaces/shop/secrets", "/version",
            "/api/v1/namespaces/shop/pods/web-1/exec", "/api/v1/nodes/fake-node-1/proxy/stats/summary",
        ]
        for path in refused {
            let answer = try await raw.send(.GET, path, body: nil, headers: [])
            XCTAssertEqual(answer.status, 403, path)
        }
        for path in [
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query/../../../../../../namespaces/shop/pods",
            "//api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query",
            // Encoded traversal: decoded before the filter, and refused or redirected — never proxied.
            "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query%2F..%2F..%2F..%2F..%2F..%2F..%2Fpods",
            "/api/v1/namespaces/monitoring/services/grafana:80%2Fproxy%2F..%2F..%2Fprometheus-server:80/proxy/api/v1/query",
        ] {
            let variant = try await raw.send(.GET, path, body: nil, headers: [])
            XCTAssertFalse((200..<300).contains(variant.status), "\(path): \(variant.status)")
        }
        for method in [HTTPMethod.POST, .PUT, .DELETE] {
            let write = try await raw.send(method, service.queryPath, body: Data("query=up".utf8), headers: [])
            XCTAssertEqual(write.status, 403, "\(method)")
        }
        let other = UnixHTTPTransport(address: .unix(socket), host: "example.com", readinessPath: "/version", service: "test")
        let host = try await other.send(.GET, service.queryPath + "?query=up", body: nil, headers: [])
        XCTAssertEqual(host.status, 403, "any Host but localhost")
        XCTAssertEqual(
            api.requests.map(\.path), [service.queryPath, service.rangePath], "only the two queries reached the server, and nothing through the metrics proxy else")
        let connected = await proxies.proxyLabels
        XCTAssertEqual(connected, ["fake-dev (prometheus)"])
    }
}

/// A value behind a lock, for the closures the proxies call off the main actor.
private final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: T
    init(_ value: T) { current = value }
    var value: T { lock.withLock { current } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&current) } }
}
