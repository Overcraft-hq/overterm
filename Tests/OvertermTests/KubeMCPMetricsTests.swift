import Foundation
import XCTest

@testable import Overterm

/// `k8s_metrics` (docs/design/kubernetes/metrics.md 7; stage M11) against
/// `FakeKubeAPI` and its fake Prometheus and metrics-server, never a
/// cluster of the user's: a pod's usage from the tab's own queries, asked
/// as an agent with the page not showing the context — only the Service's
/// `query` and `query_range`, each with 20 s, nothing kept as the page's —,
/// its share of its limit, its OOMKill marked; a Prometheus note scrubbed
/// and quoted; the answer bounded; without Prometheus, what was sampled
/// while shown, else metrics-server now; sizing on request; what can't be
/// asked refused before anything is read; Ask Why's Usage part. GETs only.
@MainActor
final class KubeMCPMetricsTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-server", port: "80")!
    private let mi = 1_048_576.0
    private static let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.c2lnbmF0dXJlLWZha2U"

    override func setUpWithError() throws {
        socket = "/tmp/otkmm-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.metricsServer = true
        api.addNamespace("shop")
        api.addNamespace("monitoring")
        api.addPod(
            "api-1", namespace: "shop",
            FakeKubeAPI.Pod(
                ready: 1, containers: 1, restarts: 1,
                resources: ["app": ["requests": ["cpu": "1", "memory": "256Mi"], "limits": ["memory": "512Mi"]]], lastReason: "OOMKilled", lastExitCode: 137,
                lastFinished: Date().addingTimeInterval(-600)))
        api.setPodMetrics("api-1", namespace: "shop", [("app", "120m", "100Mi")])
        MainActor.assumeIsolated { KubeMCP.forgetDiscoveries() }
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.isPrometheusQuery && !service.allows($0.path) }, "only the Service's two query paths")
            XCTAssertTrue(api.requests.filter(\.isPrometheusQuery).allSatisfy { $0.query["timeout"] == "20s" }, "each with 20 s")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") || $0.path.contains("/nodes/") && $0.path.contains("/proxy") })
            api.stop()
        }
    }

    /// fake-dev, its Prometheus opted in (or not), on the fake's socket; nothing read from ~/.kube.
    private func model(prometheus: String? = "monitoring/prometheus-server:80") -> KubernetesModel {
        let socket = self.socket!
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings(prometheus: prometheus))
        model.load = { _ in KubeContextList(contexts: [context], current: "fake-dev") }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.metrics.interval = .milliseconds(100)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.prometheusOverride = { context, service in
            KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: context.name), service: service)
        }
        return model
    }

    /// The prometheus chart's profile: the pod's working set 415Mi of its 512Mi limit, its CPU 250m.
    private func servePrometheus() {
        api.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        api.setPrometheusProfile(.prometheusChart)
        let labels = ["namespace": "shop", "pod": "api-1", "container": "app", "image": "nginx:1.27", "metrics_path": "/metrics/cadvisor"]
        api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: labels, value: 0.25)
        api.setPrometheusSeries("container_memory_working_set_bytes", labels: labels, value: 415 * mi)
        api.setPrometheusMatrix("sum(clamp_min(", [FakePromFixture.Line { _ in 0 }])
        api.setPrometheusMatrix("kube_pod_container_status_last_terminated_reason{", [])
    }

    private func call(_ model: KubernetesModel, _ arguments: [String: Any]) async throws -> String {
        var arguments = arguments
        arguments["context"] = arguments["context"] ?? "fake-dev"
        arguments["namespace"] = arguments["namespace"] ?? "shop"
        let result = try await KubeMCP.call("k8s_metrics", arguments, kubernetes: model)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertNotEqual(result["isError"] as? Bool, true, text)
        return text
    }

    private func refused(_ model: KubernetesModel, _ arguments: [String: Any]) async -> String? {
        var arguments = arguments
        arguments["context"] = "fake-dev"
        arguments["namespace"] = arguments["namespace"] ?? "shop"
        do {
            let result = try await KubeMCP.call("k8s_metrics", arguments, kubernetes: model)
            return result["isError"] as? Bool == true ? (result["content"] as? [[String: Any]])?.first?["text"] as? String : nil
        } catch let error as BrowserMCP.ToolError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAPodsUsageFromPrometheusAskedAsAnAgent() async throws {
        servePrometheus()
        api.setPrometheusMatrix("container_memory_working_set_bytes{", nil, warnings: ["partial response: store down, Authorization: Bearer \(Self.jwt)"])
        let model = model()
        XCTAssertFalse(model.prometheus.isPolling, "the page shows nothing")
        let text = try await call(model, ["kind": "pod", "name": "api-1", "measures": ["cpu", "memory"]])
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("Context fake-dev") && lines[0].contains("namespace shop"), text)
        XCTAssertTrue(lines[1].hasPrefix("pod shop/api-1, 1h: Prometheus monitoring/prometheus-server:80"), text)
        XCTAssertTrue(lines[2].hasPrefix("last 1h at 1m ("), "a minute's scrape: a minute's step\n\(text)")
        XCTAssertTrue(text.contains("app · Memory: last 415Mi at "), text)
        XCTAssertTrue(text.contains("(81% of limit 512Mi)") || text.contains("162% of request 256Mi, 81% of limit 512Mi"), text)
        XCTAssertTrue(text.contains("app · CPU: last 250m at ") && text.contains("25% of request 1000m"), text)
        XCTAssertTrue(text.contains("OOMKilled (exit 137) at"), "its lastState's OOMKill marked:\n\(text)")
        XCTAssertTrue(text.contains("Note: “") && text.contains("partial response: store down"), "Prometheus' note, quoted as data:\n\(text)")
        XCTAssertFalse(text.contains(Self.jwt), "scrubbed:\n\(text)")
        XCTAssertLessThanOrEqual(text.count, KubeMetricsText.budget + 200, "bounded")

        let asked = api.requests.filter(\.isPrometheusQuery)
        XCTAssertFalse(asked.isEmpty)
        XCTAssertTrue(asked.contains { $0.path == service.rangePath && $0.query["step"] == "1m" }, "the tab's range queries: \(asked.map(\.query))")
        XCTAssertGreaterThan(model.prometheus.agentRequests, 0, "asked as an agent, through the context's queue")
        XCTAssertTrue(model.prometheus.tabs.isEmpty, "nothing kept as the page's")
        XCTAssertEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods/api-1" }.count, 1, "the pod's object read once")
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/apis/metrics.k8s.io") }, "Prometheus answered: metrics-server not asked")
    }

    func testWithoutPrometheusMetricsServerNowAndItsShares() async throws {
        let model = model(prometheus: nil)
        let text = try await call(model, ["kind": "container", "name": "api-1", "container": "app"])
        XCTAssertTrue(text.contains("container app of pod shop/api-1, now only: no history without Prometheus"), text)
        XCTAssertTrue(text.contains("app: CPU 120m (12% of request 1000m), memory 100Mi (39% of request 256Mi, 20% of limit 512Mi)"), text)
        XCTAssertTrue(text.contains("Sampled by metrics-server"), text)
        XCTAssertFalse(api.requests.contains(where: \.isPrometheusQuery), "no Prometheus where it isn't opted in")
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods/api-1" })

        // A claim has nothing from metrics-server: said, nothing asked of it.
        api.forgetRequests()
        let claim = try await call(model, ["kind": "pvc", "name": "data-db-0"])
        XCTAssertTrue(claim.contains("only Prometheus has"), claim)
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/apis/metrics.k8s.io") }, "\(api.requests)")
        // Sizing needs Prometheus.
        let sized = try await call(model, ["kind": "container", "name": "api-1", "container": "app", "sizing": true])
        XCTAssertTrue(sized.contains("Sizing needs Prometheus"), sized)
    }

    func testWhatWasSampledWhileShownWhenThereIsNoPrometheus() async throws {
        let model = model(prometheus: nil)
        let page = KubernetesPageModel(model: model)
        model.show()
        page.visible = true
        try await until(5, "listed") { model.rows.count == 1 && model.discovery != nil }
        page.selection = ["shop/api-1"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "sampled twice") { model.metrics.ring.points(.pod(namespace: "shop", name: "api-1")).count >= 2 }
        page.closeDetail()
        model.hide()
        api.forgetRequests()
        let text = try await call(model, ["kind": "pod", "name": "api-1", "range": "15m"])
        XCTAssertTrue(text.contains("pod shop/api-1, 15m: Sampled from metrics-server while shown since"), text)
        XCTAssertTrue(text.contains("app · Memory: last 100Mi at"), text)
        XCTAssertFalse(api.requests.contains { $0.path.hasPrefix("/apis/metrics.k8s.io") }, "nothing read now: \(api.requests.map(\.path))")
    }

    func testSizingOnRequest() async throws {
        servePrometheus()
        let app = ["container": "app"]
        let mi = self.mi
        api.setPrometheusMatrix("quantile_over_time(0.5, (sum", [FakePromFixture.Line(app) { _ in 0.11 }])
        api.setPrometheusMatrix("quantile_over_time(0.95, (sum", [FakePromFixture.Line(app) { _ in 0.21 }])
        api.setPrometheusMatrix("max_over_time((sum", [FakePromFixture.Line(app) { _ in 0.48 }])
        api.setPrometheusMatrix("quantile_over_time(0.95, (max", [FakePromFixture.Line(app) { _ in 498 * mi }])
        api.setPrometheusMatrix("max_over_time(container_memory_working_set_bytes{", [FakePromFixture.Line(app) { _ in 509 * mi }])
        let model = model()
        let text = try await call(model, ["kind": "container", "name": "api-1", "container": "app", "measures": "memory", "sizing": true])
        XCTAssertTrue(text.contains("Sizing · 7 days · per pod"), text)
        XCTAssertTrue(text.contains("suggested request ≈ p95 × 1.15 = 245m"), text)
        XCTAssertTrue(text.contains("suggested request and limit ≈ max × 1.15 = 586Mi"), text)
        XCTAssertTrue(text.contains("OOMKilled at"), "its OOMKill in the window, said:\n\(text)")
        XCTAssertTrue(model.prometheus.sizings.isEmpty, "nothing kept as the page's")
    }

    func testWhatCantBeAskedIsRefusedBeforeAnythingIsRead() async throws {
        let model = model()
        api.forgetRequests()
        let kind = await refused(model, ["kind": "secret", "name": "x"])
        XCTAssertTrue(kind?.contains("“kind” is pod, container") == true, kind ?? "answered")
        let range = await refused(model, ["name": "api-1", "range": "3h"])
        XCTAssertEqual(range, "“range” is 15m, 1h, 6h, 24h or 7d.")
        let measure = await refused(model, ["name": "api-1", "measures": ["cpu", "latency"]])
        XCTAssertTrue(measure?.hasPrefix("“latency” isn't a measure") == true, measure ?? "answered")
        let sizing = await refused(model, ["kind": "node", "name": "fake-node-1", "sizing": true])
        XCTAssertEqual(sizing, "“sizing” is a container's or a workload's.")
        let container = await refused(model, ["kind": "container", "name": "api-1"])
        XCTAssertTrue(container?.contains("needs “container”") == true, container ?? "answered")
        let path = await refused(model, ["name": "../secrets/x"])
        XCTAssertTrue(path?.contains("isn't an object's name") == true, path ?? "answered")
        XCTAssertTrue(api.requests.isEmpty, "nothing read: \(api.requests.map(\.path))")
        let missing = await refused(model, ["kind": "container", "name": "api-1", "container": "sidecar"])
        XCTAssertEqual(missing, "Pod api-1 has no container “sidecar”: it has app.")
    }

    func testAskWhyGetsTheFailingPodsUsage() async throws {
        servePrometheus()
        let model = model()
        let context = await model.contextsForAgents()?.context(named: "fake-dev")
        XCTAssertNotNil(context)
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "api-1")
        let part = await KubeMCP.usagePart(for: ref, context: context, kubernetes: model)
        XCTAssertEqual(part?.title, "usage")
        XCTAssertTrue(part?.text.contains("app · Memory: last 415Mi") == true && part?.text.contains("81% of limit 512Mi") == true, part?.text ?? "none")
        XCTAssertTrue(part?.text.contains("OOMKilled") == true, part?.text ?? "none")
        // A Deployment's only where it is cheap: no recording rules here, nothing sampled.
        let deployment = KubeObjectRef(context: "fake-dev", kind: .deployments, namespace: "shop", name: "api")
        let none = await KubeMCP.usagePart(for: deployment, context: context, kubernetes: model)
        XCTAssertNil(none)
    }

    /// worker-1 crash-looping, out of memory, beside a sidecar: Prometheus
    /// has both containers' usage.
    private func crashingWorker() {
        api.addPod(
            "worker-1", namespace: "shop",
            FakeKubeAPI.Pod(
                status: "CrashLoopBackOff", ready: 0, containers: 2, restarts: 3,
                resources: ["app": ["requests": ["cpu": "1", "memory": "256Mi"], "limits": ["memory": "512Mi"]]], lastReason: "OOMKilled", lastExitCode: 137,
                lastFinished: Date().addingTimeInterval(-600)))
        api.addEvent(about: "pods", "worker-1", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container app")
        for (container, memory) in [("app", 415 * mi), ("sidecar-1", 30 * mi)] {
            let labels = ["namespace": "shop", "pod": "worker-1", "container": container, "image": "nginx:1.27", "metrics_path": "/metrics/cadvisor"]
            api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: labels, value: 0.25)
            api.setPrometheusSeries("container_memory_working_set_bytes", labels: labels, value: memory)
        }
    }

    private func why(_ model: KubernetesModel, _ name: String) async throws -> String {
        let result = try await KubeMCP.call("k8s_why", ["context": "fake-dev", "namespace": "shop", "name": name], kubernetes: model)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertNotEqual(result["isError"] as? Bool, true, text)
        return text
    }

    func testWhyCarriesTheFailingContainersUsageFromWhatTheBriefRead() async throws {
        servePrometheus()
        crashingWorker()
        let model = model()
        api.forgetRequests()
        let text = try await why(model, "worker-1")
        let usage = try XCTUnwrap(text.range(of: "usage").map { String(text[$0.lowerBound...]) }, text)
        XCTAssertTrue(usage.contains("container app of pod shop/worker-1, 1h:"), "the failing container's, not the pod's:\n\(usage)")
        XCTAssertTrue(usage.contains("app · Memory: last 415Mi") && usage.contains("81% of limit 512Mi"), usage)
        XCTAssertFalse(usage.contains("sidecar-1 ·") || usage.contains("pod · Memory"), "a sidecar's lines never crowd it out:\n\(usage)")
        XCTAssertTrue(usage.contains("OOMKilled"), usage)
        // What the brief read isn't read again for its usage.
        XCTAssertEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/pods/worker-1" }.count, 1, "the pod read once")
        XCTAssertEqual(api.requests.filter { $0.path == "/api/v1/namespaces/shop/events" }.count, 1, "its events listed once")
        XCTAssertGreaterThan(model.prometheus.agentRequests, 0)
    }

    func testWhyAnswersWithoutUsageWhenPrometheusStalls() async throws {
        servePrometheus()
        crashingWorker()
        api.answerSlowly(service.queryPath, milliseconds: 20_000)
        api.answerSlowly(service.rangePath, milliseconds: 20_000)
        let limit = KubeMCP.usageLimit
        KubeMCP.usageLimit = .milliseconds(500)
        defer { KubeMCP.usageLimit = limit }
        let model = model()
        let started = Date()
        let text = try await why(model, "worker-1")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the brief never waits on a stalled Prometheus")
        XCTAssertTrue(text.contains("CrashLoopBackOff") && text.contains("BackOff"), "the brief itself:\n\(text)")
        XCTAssertFalse(text.contains("container app of pod shop/worker-1, 1h"), "no usage part:\n\(text)")
        api.answerSlowly(service.queryPath, milliseconds: nil)
        api.answerSlowly(service.rangePath, milliseconds: nil)
    }

    func testANodesTopPodsOnlyWhenAskedAndTheClustersMeasuresAsAsked() async throws {
        servePrometheus()
        api.add("nodes", "fake-node-1", values: ["Status": "Ready"], fields: ["status": ["allocatable": ["cpu": "4", "memory": "8Gi"]]])
        api.setNodeMetrics("fake-node-1", cpu: "500m", memory: "1Gi")
        let model = model()
        let topPods = "sum by (namespace,pod)("
        _ = try await call(model, ["kind": "node", "name": "fake-node-1"])
        XCTAssertFalse(
            api.requests.contains { $0.isPrometheusQuery && $0.query["query"]?.hasPrefix(topPods) == true },
            "a node's pods, a series each, never asked by default: \(api.requests.compactMap { $0.query["query"] })")
        api.forgetRequests()
        _ = try await call(model, ["kind": "node", "name": "fake-node-1", "top_pods": true])
        XCTAssertTrue(api.requests.contains { $0.isPrometheusQuery && $0.query["query"]?.hasPrefix(topPods) == true }, "asked on top_pods")
        let refused = await refused(model, ["kind": "pod", "name": "api-1", "top_pods": true])
        XCTAssertEqual(refused, "“top_pods” is a node's.")

        // The cluster's lines, as the fake can't add node-exporter's up: each armed as the union arms it.
        api.setPrometheusMatrix(#""overterm_s","cpu","""#, [FakePromFixture.Line(["overterm_s": "cpu"]) { _ in 1.5 }])
        api.setPrometheusMatrix(#""overterm_s","memory","""#, [FakePromFixture.Line(["overterm_s": "memory"]) { _ in 2e9 }])
        let cluster = try await call(model, ["kind": "cluster", "measures": ["cpu"]])
        XCTAssertTrue(cluster.contains("CPU:"), cluster)
        XCTAssertFalse(cluster.contains("Memory:"), "only the measures asked:\n\(cluster)")
    }

    func testTheClustersRefusedLinesTotalsAskedAsAnAgent() async throws {
        servePrometheus()
        api.setPrometheusProfile(.noNodeExporter)
        let model = model()
        // A week raw across the cluster: its lines refused, its totals one instant union.
        let text = try await call(model, ["kind": "cluster", "range": "7d"])
        XCTAssertTrue(text.contains("the cluster"), text)
        XCTAssertTrue(
            api.requests.contains { $0.path == service.queryPath && $0.query["query"]?.contains(#""overterm_s","cpuAllocatable""#) == true },
            "the totals' union asked")
        XCTAssertGreaterThan(model.prometheus.agentRequests, 0)
        XCTAssertEqual(model.prometheus.agentRequests, model.prometheus.requests, "every query an agent's: below the page, at most two places")
    }

    func testPrometheusThatFailedIsSaidOnTheNowOnlyLine() async throws {
        servePrometheus()
        api.failPrometheus(500, "boom")
        let model = model()
        let text = try await call(model, ["kind": "pod", "name": "api-1"])
        XCTAssertTrue(text.contains("pod shop/api-1, now only: Prometheus gave no history (see the note)"), text)
        XCTAssertFalse(text.contains("no history without Prometheus"), text)
        XCTAssertTrue(text.contains("Prometheus couldn't be"), text)
    }

    func testTheRingIsAContextsOnlyWhileItPointsAtTheSameCluster() async throws {
        let model = model(prometheus: nil)
        let list = await model.contextsForAgents()
        let dev = try XCTUnwrap(list?.context(named: "fake-dev"))
        model.metrics.update(
            KubeMetricsMonitor.Situation(
                context: "fake-dev", scope: .namespace("shop"), labels: nil, availability: .served, cluster: KubePrometheusMonitor.cluster(of: dev))
        ) { nil }
        XCTAssertTrue(model.metrics.ringHolds(dev))
        let elsewhere = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:2", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        XCTAssertFalse(model.metrics.ringHolds(elsewhere), "the same name pointed at another cluster: not its samples")
        model.metrics.update(nil) { nil }
    }
}
