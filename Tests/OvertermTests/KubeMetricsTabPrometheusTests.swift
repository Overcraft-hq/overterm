import Foundation
import XCTest

@testable import Overterm

/// A Metrics tab over Prometheus (docs/design/kubernetes/metrics.md, 3.3–3.5,
/// 6.1, 6.2; stage M6), the page over `FakeKubeAPI` and its fake Prometheus
/// (named in the context's entry), never a cluster of the user's: the
/// ranges it can pick, Live's mixed source, 1h's every chart, an
/// incremental refresh asking only the tail, a zoom asked once at its own
/// step and popped by Reset, Custom checked, Live's pause, nothing read
/// once hidden. GETs only.
@MainActor
final class KubeMetricsTabPrometheusTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private let service = KubePrometheusService(namespace: "monitoring", name: "prometheus-server", port: "80")!

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.isPrometheusQuery && !service.allows($0.path) }, "only the Service's two query paths")
            api.stop()
        }
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var asked: [FakeKubeAPI.Request] { api.requests.filter(\.isPrometheusQuery) }

    private func pageOverFake(metricsServer: Bool = true) throws -> (KubernetesModel, KubernetesPageModel) {
        let socket = "/tmp/otkmp-\(UInt32.random(in: 0...UInt32.max)).sock"
        self.socket = socket
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.metricsServer = metricsServer
        api.addNamespace("shop")
        api.addNamespace("monitoring")
        api.addPod(
            "web-1", namespace: "shop",
            FakeKubeAPI.Pod(ready: 1, containers: 1, resources: ["app": ["requests": ["cpu": "250m"], "limits": ["cpu": "1", "memory": "128Mi"]]]))
        api.setPodMetrics("web-1", namespace: "shop", [("app", "120m", "100Mi")])
        api.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        api.setPrometheusProfile(.prometheusChart)
        let labels = ["namespace": "shop", "pod": "web-1", "container": "app", "image": "nginx:1.27", "metrics_path": "/metrics/cadvisor"]
        api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: labels, value: 0.25)
        api.setPrometheusSeries("container_memory_working_set_bytes", labels: labels, value: 64 * 1_048_576)
        api.setPrometheusMatrix("container_cpu_cfs_throttled_periods_total{", [FakePromFixture.Line(["container": "app"]) { _ in 0.1 }])
        api.setPrometheusMatrix("container_network_receive_bytes_total{", [FakePromFixture.Line(["overterm_s": "rx"]) { _ in 1000 }])
        api.setPrometheusMatrix("sum(clamp_min(", [FakePromFixture.Line { _ in 0 }])
        api.setPrometheusMatrix(E2ERunner.peakFragment, [FakePromFixture.Line(["container": "app"]) { _ in 0.4 }])
        api.setPrometheusMatrix("container_memory_rss{", [])
        api.setPrometheusMatrix("kube_pod_container_status_last_terminated_reason{", [])
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings(prometheus: "monitoring/prometheus-server:80"))
        model.load = { _ in KubeContextList(contexts: [context], current: "fake-dev") }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.metrics.interval = .milliseconds(100)
        model.prometheus.interval = .milliseconds(100)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.prometheusOverride = { context, service in
            KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: context.name), service: service)
        }
        return (model, KubernetesPageModel(model: model))
    }

    private func openPod(_ model: KubernetesModel, _ page: KubernetesPageModel) async throws {
        model.show()
        page.visible = true
        try await until(5, "listed") { model.rows.count == 1 && model.discovery != nil }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.object != nil }
    }

    private func range(_ request: FakeKubeAPI.Request) -> (start: Double, end: Double, step: String)? {
        guard let start = Double(request.query["start"] ?? ""), let end = Double(request.query["end"] ?? "") else { return nil }
        return (start, end, request.query["step"] ?? "")
    }

    func testLiveIsSampledAndAsksPrometheusOnlyWhatHasNoSampledForm() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openPod(model, page)
        try await until(5, "Prometheus found as the entry names it") { model.prometheus.service == service }
        XCTAssertEqual(page.metricsRanges, KubeMetricsRange.allCases, "every range, Prometheus found")
        XCTAssertEqual(page.metricsSource(of: try XCTUnwrap(page.detail?.ref)), .mixed)
        try await until(5, "Live's Prometheus answers") { model.prometheus.tabs.values.contains { $0.read != nil } }
        let reading = try XCTUnwrap(model.prometheus.tabs.values.first)
        XCTAssertEqual(reading.request.families, KubePromTabCharts.families(.pod, source: .mixed))
        XCTAssertEqual(reading.request.families, [.throttling, .network, .restarts, .oom, .fs])
        XCTAssertEqual(reading.span?.step, 60, "a minute's scrape: Live at a minute")
        XCTAssertNil(reading.results["cpu"], "CPU is sampled")
        XCTAssertEqual(page.metricsDetailsOnScreen, [.pod(namespace: "shop", name: "web-1")], "and metrics-server polled for it")
        try await until(5, "drawn") { page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) }?.sections.first?.charts.count == 3 }
        let charts = try XCTUnwrap(page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) })
        XCTAssertEqual(charts.sections[0].charts.map(\.data.source), ["metrics-server", "metrics-server", "Prometheus"], "throttling from Prometheus")
        XCTAssertEqual(charts.pod.map(\.data.id).suffix(2), ["pod.shop.web-1.network", "pod.shop.web-1.restarts"])
        let throttled = try XCTUnwrap(asked.first { $0.query["query"]?.contains("container_cpu_cfs_throttled_periods_total{") == true })
        XCTAssertEqual(range(throttled).map { $0.end - $0.start }, 900, "15 minutes")
        XCTAssertNil(page.metricsTabProblem(of: try XCTUnwrap(page.detail?.ref)), "nothing says it needs Prometheus")
        // Hidden: nothing read.
        page.visible = false
        try await until(5, "stopped") { !model.prometheus.isPolling && model.prometheus.tabs.isEmpty }
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(asked.isEmpty, "\(asked.map(\.query))")
    }

    func testAnHourAsksEveryChartThenOnlyTheTailAndAZoomOnce() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openPod(model, page)
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        XCTAssertTrue(page.press("."))
        XCTAssertEqual(page.shownMetricsRange, .hour)
        XCTAssertEqual(page.metricsSource(of: try XCTUnwrap(page.detail?.ref)), .prometheus)
        try await until(5, "its charts") { model.prometheus.tabs.values.contains { $0.results["cpu"] != nil } }
        try await until(5, "no metrics-server polled for it") { page.metricsDetailsOnScreen.isEmpty }
        let cpu = try XCTUnwrap(asked.first { $0.query["query"]?.hasPrefix("sum by (container)(rate(container_cpu_usage_seconds_total") == true })
        let first = try XCTUnwrap(range(cpu))
        XCTAssertEqual(first.end - first.start, 3600)
        XCTAssertEqual(first.step, "1m")
        XCTAssertEqual(cpu.query["timeout"], "20s")
        // A refresh two steps on asks the tail alone: never the whole hour again.
        model.prometheus.clock = { Date().addingTimeInterval(120) }
        try await until(5, "asked again, two minutes on") { self.asked.filter { $0.query["query"] == cpu.query["query"] }.count > 1 }
        let again = asked.filter { $0.query["query"] == cpu.query["query"] }.dropFirst()
        XCTAssertFalse(again.isEmpty)
        XCTAssertTrue(again.allSatisfy { (range($0)?.start ?? 0) >= first.end - 180 && (range($0)?.end ?? 0) > first.end }, "\(again.compactMap(range))")
        model.prometheus.clock = { Date() }
        try await until(5, "built") { page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) }?.pod.first?.data.source == "Prometheus" }
        let charts = try XCTUnwrap(page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) })
        XCTAssertEqual(charts.sections.first?.charts.map { $0.data.id.split(separator: ".").last.map(String.init) ?? "" }, ["cpu", "memory", "throttling"])
        XCTAssertTrue(charts.caption.hasPrefix("Prometheus monitoring/prometheus-server:80 · the last 1h at 1m · raw cAdvisor · scrape 1m"), charts.caption)

        // A zoom: asked once over its window at its own step; Reset gives the hour back.
        let shown = try XCTUnwrap(charts.pod.first?.data)
        api.forgetRequests()
        let from = shown.end.addingTimeInterval(-1800)
        page.zoomMetrics(from: from, to: shown.end, of: shown)
        XCTAssertEqual(page.metricsWindow?.kind, .zoom)
        try await until(5, "asked over the window") { self.asked.contains { $0.query["start"] == KubePromQL.stamp(from) && $0.query["step"] == "1m" } }
        try await until(5, "read") { model.prometheus.tabs.values.contains { if case .window = $0.request.span { $0.read != nil } else { false } } }
        try await Task.sleep(for: .milliseconds(200))
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(asked.isEmpty, "a zoomed window isn't refreshed: \(asked.map(\.query))")
        page.zoomMetrics(from: from, to: from.addingTimeInterval(600), of: shown)
        XCTAssertEqual(page.metricsZoom.count, 2, "a zoom of a zoom")
        XCTAssertTrue(page.press("\u{1B}"), "Esc pops one")
        XCTAssertEqual(page.metricsZoom.count, 1)
        XCTAssertTrue(page.resetMetricsWindow())
        XCTAssertNil(page.metricsWindow)
        XCTAssertNotNil(page.detail, "Esc popped the zoom, not the detail")
        try await until(5, "the hour again") { model.prometheus.tabs.keys.contains { $0.span == .range(.hour) } }
    }

    func testCustomAndTheSevenDaysEdge() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openPod(model, page)
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        page.pickMetricsRange(.week)
        XCTAssertTrue(page.press("."), ". past 7d")
        XCTAssertTrue(page.customRangeShown, "opens Custom")
        let now = Date()
        XCTAssertEqual(page.applyCustomRange(start: now, end: now.addingTimeInterval(-60), now: now), "The start must be before the end.")
        XCTAssertNil(page.metricsWindow)
        XCTAssertNil(page.applyCustomRange(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600), now: now))
        XCTAssertEqual(page.metricsWindow?.kind, .custom)
        XCTAssertFalse(page.customRangeShown)
        try await until(5, "asked over it") { self.asked.contains { $0.query["start"] == KubePromQL.stamp(now.addingTimeInterval(-7200)) } }
        XCTAssertTrue(page.press(","), ", from a window: its range, stepped")
        XCTAssertNil(page.metricsWindow)
        XCTAssertEqual(page.shownMetricsRange, .day)
    }

    func testWithoutMetricsServerTheTabOpensOnAnHourOfPrometheus() async throws {
        let (model, page) = try pageOverFake(metricsServer: false)
        defer { model.hide() }
        try await openPod(model, page)
        try await until(5, "metrics-server absent, Prometheus found") { model.metrics.availability == .absent && model.prometheus.service == service }
        XCTAssertEqual(page.shownMetricsRange, .hour, "decision 7: 1h where only Prometheus answers")
        XCTAssertEqual(page.metricsSource(of: try XCTUnwrap(page.detail?.ref)), .prometheus)
        try await until(5, "charted") { page.detail.flatMap { page.podCharts(of: $0.ref, object: $0.object) }?.hasSamples == true }
        page.pickMetricsRange(.live)
        XCTAssertEqual(page.metricsSource(of: try XCTUnwrap(page.detail?.ref)), .prometheus, "Live: every chart from Prometheus")
        try await until(5, "Live's 15 minutes") {
            self.asked.contains { $0.query["query"]?.contains("container_cpu_usage_seconds_total") == true && self.range($0).map { $0.end - $0.start } == 900 }
        }
        XCTAssertEqual(page.metricsDetailsOnScreen, [])
    }

    /// Live opened again after a while hidden counts its idle time from
    /// then: the tab never opens paused (metrics.md 3.5).
    func testLiveShownAgainAfterItsIdleTimeIsntPaused() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        page.metricsIdleLimit = 0.6
        try await openPod(model, page)
        try await until(5, "Live reads") { !page.metricsDetailsOnScreen.isEmpty }
        XCTAssertTrue(page.metricsLiveRuns)
        page.visible = false
        XCTAssertFalse(page.metricsLiveRuns)
        try await Task.sleep(for: .milliseconds(900))
        page.visible = true
        XCTAssertTrue(page.metricsLiveRuns)
        XCTAssertFalse(page.metricsLivePaused, "shown again: running, not paused")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(page.metricsLivePaused, "its idle time from the show, not from before it hid")
        try await until(5, "paused once idle that long") { page.metricsLivePaused }
    }

    /// Until discovery says, the tab opens on Live: never an hour asked
    /// for a moment, then dropped for Live (decision 7).
    func testTheDefaultRangeWaitsForDiscovery() throws {
        let (model, page) = try pageOverFake()
        XCTAssertEqual(model.metrics.availability, .unknown)
        XCTAssertEqual(page.shownMetricsRange(for: .pod), .live)
        XCTAssertEqual(page.shownMetricsRange(for: .workload("Deployment")), .live)
        _ = model
    }

    /// A node's top pods (K3, a series a pod on the node) are asked only
    /// while their group is on screen; the request changing keeps what was
    /// read until the new one answers (metrics.md 6.2).
    func testANodesTopPodsAreReadOnlyWhileShown() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        api.add("nodes", "fake-node-1", fields: ["status": ["allocatable": ["cpu": "4", "memory": "16Gi", "pods": "58"]]])
        api.setNodeMetrics("fake-node-1", cpu: "900m", memory: "6Gi")
        model.show()
        page.visible = true
        try await until(5, "discovery read") { model.discovery != nil }
        let nodes = try XCTUnwrap(model.discovery?.kind("nodes"))
        page.showKind(nodes)
        try await until(5, "nodes listed") { model.kind.fullName == "nodes" && model.rows.count >= 1 }
        page.selection = ["fake-node-1"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.object != nil }
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        page.pickMetricsRange(.hour)
        XCTAssertEqual(page.shownMetricsRange, .hour)
        let session = try XCTUnwrap(page.detail)
        try await until(5, "its charts read") { page.tabReading(of: session)?.read != nil }
        func top() -> [FakeKubeAPI.Request] { asked.filter { $0.query["query"]?.hasPrefix("sum by (namespace,pod)(") == true } }
        XCTAssertEqual(top().count, 0, "top pods off screen: not asked")
        XCTAssertEqual(page.tabRequest(of: session)?.families.contains(.topCPU), false)
        let charts = try XCTUnwrap(page.objectCharts(of: session))
        let group = try XCTUnwrap(charts.groups.first { $0.title == KubePromTabCharts.topPodsTitle })
        XCTAssertTrue(group.readsWhenShown && group.pending, "there to be scrolled to")
        page.metricsGroupShown(KubePromTabCharts.topPodsTitle, true)
        XCTAssertEqual(page.tabRequest(of: session)?.families.isSuperset(of: KubePromTabCharts.readWhenShown[KubePromTabCharts.topPodsTitle] ?? []), true)
        XCTAssertNotNil(page.tabReading(of: session)?.read, "the last answers stand while the new request is read")
        try await until(5, "top pods asked") { top().count == 2 }
        try await until(5, "read") { page.tabReading(of: session)?.results["topCPU"] != nil }
        page.metricsGroupShown(KubePromTabCharts.topPodsTitle, false)
        XCTAssertNotNil(page.tabReading(of: session)?.read, "scrolled off: what was read stands")
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(top().isEmpty, "scrolled off: not asked again \(top().map(\.query))")
    }

    /// A node's disks and network (K6, K7, M8b) are node-exporter's over
    /// the metrics proxy, asked only while their group is on screen — in
    /// Live too, where the node's other charts are sampled.
    func testANodesDisksAndNetworkAreReadOnlyWhileShown() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        api.add("nodes", "fake-node-1", fields: ["status": ["allocatable": ["cpu": "4", "memory": "16Gi", "pods": "58"]]])
        api.setNodeMetrics("fake-node-1", cpu: "900m", memory: "6Gi")
        let gib = 1_073_741_824.0
        api.setPrometheusMatrix(
            "node_filesystem_size_bytes{",
            [
                FakePromFixture.Line(["overterm_s": "used", "mountpoint": "/"]) { _ in 3 * gib },
                FakePromFixture.Line(["overterm_s": "size", "mountpoint": "/"]) { _ in 4 * gib },
            ])
        api.setPrometheusMatrix(
            "node_network_receive_bytes_total{",
            [FakePromFixture.Line(["overterm_s": "rx"]) { _ in 1_200_000 }, FakePromFixture.Line(["overterm_s": "tx"]) { _ in 340_000 }])
        model.show()
        page.visible = true
        try await until(5, "discovery read") { model.discovery != nil }
        let nodes = try XCTUnwrap(model.discovery?.kind("nodes"))
        page.showKind(nodes)
        try await until(5, "nodes listed") { model.kind.fullName == "nodes" && model.rows.count >= 1 }
        page.selection = ["fake-node-1"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.object != nil }
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        let session = try XCTUnwrap(page.detail)
        func exporter() -> [FakeKubeAPI.Request] {
            asked.filter {
                let query = $0.query["query"] ?? ""
                return !query.hasPrefix("count by (__name__)") && (query.contains("node_filesystem_") || query.contains("node_network_"))
            }
        }
        // Live, sampled: nothing of Prometheus' until the group shows.
        XCTAssertEqual(page.metricsSource(of: session.ref), .mixed)
        XCTAssertNil(page.tabRequest(of: session), "off screen: nothing asked")
        let pending = try XCTUnwrap(page.objectCharts(of: session)?.groups.last)
        XCTAssertEqual(pending.title, KubePromTabCharts.nodeExporterTitle)
        XCTAssertTrue(pending.readsWhenShown && pending.pending, "there to be scrolled to")
        page.metricsGroupShown(KubePromTabCharts.nodeExporterTitle, true)
        XCTAssertEqual(page.tabRequest(of: session)?.families, [.disks, .nodeNetwork])
        try await until(5, "asked in Live") { exporter().count == 2 }
        XCTAssertTrue(exporter().allSatisfy { $0.path == service.rangePath && $0.query["timeout"] == "20s" }, "\(exporter().map(\.path))")
        XCTAssertTrue(exporter().allSatisfy { ($0.query["query"] ?? "").contains(#"node_uname_info{nodename="fake-node-1"}"#) }, "mapped by uname")
        try await until(5, "drawn") { page.objectCharts(of: session)?.groups.last?.charts.count == 2 }
        let group = try XCTUnwrap(page.objectCharts(of: session)?.groups.last)
        XCTAssertEqual(group.charts.map(\.data.id), ["node.fake-node-1.disk.root", "node.fake-node-1.network"])
        XCTAssertEqual(group.charts.first?.chips, [KubeChartChip(text: "75% used", alert: false)])
        XCTAssertEqual(page.objectCharts(of: session)?.groups.first?.title, "Node", "the sampled charts kept")
        // Over the hour: asked with the rest once shown; scrolled off, not again.
        page.pickMetricsRange(.hour)
        try await until(5, "an hour's reading") { page.tabReading(of: session)?.results["disks"] != nil }
        page.metricsGroupShown(KubePromTabCharts.nodeExporterTitle, false)
        XCTAssertEqual(page.tabRequest(of: session)?.families.contains(.disks), false)
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(exporter().isEmpty, "scrolled off: not asked again \(exporter().map(\.query))")
        XCTAssertFalse(api.requests.contains { $0.path.contains("nodes/proxy") || $0.path.contains("/proxy/metrics") }, "never the kubelet")
    }

    func testLivePausesWithoutInputAndResumes() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        page.metricsIdleLimit = 0.4
        try await openPod(model, page)
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        try await until(5, "Live reads") { !model.prometheus.tabs.isEmpty && !page.metricsDetailsOnScreen.isEmpty }
        try await until(5, "paused") { page.metricsLivePaused }
        try await until(5, "nothing read while paused") { model.prometheus.tabs.isEmpty && page.metricsDetailsOnScreen.isEmpty }
        XCTAssertTrue(page.metricsTabWant == nil)
        page.resumeMetrics()
        XCTAssertFalse(page.metricsLivePaused)
        try await until(5, "read again") { !model.prometheus.tabs.isEmpty }
        // Another range ends the pause: only Live pauses.
        try await until(5, "paused again") { page.metricsLivePaused }
        page.pickMetricsRange(.hour)
        try await until(5, "an hour reads") { !page.metricsPaused && model.prometheus.tabs.keys.contains { $0.span == .range(.hour) } }
    }

    /// A Deployment `web` of two pods by two ReplicaSets, kube-state-metrics'
    /// owners, its detail opened on an hour of Prometheus.
    private func openWeb(_ model: KubernetesModel, _ page: KubernetesPageModel) async throws {
        let pods = [("web-7f9c6d-aaaaa", "web-7f9c6d", 0.3), ("web-55d4f-bbbbb", "web-55d4f", 0.1)]
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "2/2"],
            fields: [
                "spec": [
                    "replicas": 2, "selector": ["matchLabels": ["app": "web"]],
                    "template": ["spec": ["containers": [["name": "app", "resources": ["requests": ["cpu": "100m"]]]]]],
                ],
                "status": ["replicas": 2],
            ])
        for (pod, replicaSet, cpu) in pods {
            api.addPod(pod, namespace: "shop", FakeKubeAPI.Pod(ready: 1, containers: 1), labels: ["app": "web"])
            let labels = ["namespace": "shop", "pod": pod, "container": "app", "image": "nginx:1.27"]
            api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: labels, value: cpu)
            api.setPrometheusSeries("container_memory_working_set_bytes", labels: labels, value: 64 * 1_048_576)
            api.setPrometheusSeries("kube_pod_owner", labels: ["namespace": "shop", "pod": pod, "owner_kind": "ReplicaSet", "owner_name": replicaSet], value: 1)
            api.setPrometheusSeries(
                "kube_replicaset_owner", labels: ["namespace": "shop", "replicaset": replicaSet, "owner_kind": "Deployment", "owner_name": "web"], value: 1)
        }
        api.setPrometheusMatrix("topk(5,", pods.map { pod in FakePromFixture.Line(["pod": pod.0]) { _ in pod.2 } })
        api.setPrometheusMatrix("sum((clamp_min(", [FakePromFixture.Line { _ in 0 }])
        model.show()
        page.visible = true
        try await until(5, "discovery read") { model.discovery?.kind("deployments") != nil }
        page.showKind(try XCTUnwrap(model.discovery?.kind("deployments")))
        try await until(5, "listed") { model.rows[KubeRowID(namespace: "shop", name: "web")] != nil }
        page.selection = ["shop/web"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.object != nil }
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        page.pickMetricsRange(.hour)
    }

    /// A workload's top five (M7): ranked once by an instant `topk` a
    /// measure at the span's end, then asked by name alongside the owner
    /// join's total and its ReplicaSets; ranked again only on the tenth
    /// refresh. A namespace's raw series counted once, its workloads by
    /// owner. GETs only, through the Service's two paths.
    func testAWorkloadsTopFiveAreRankedOnceThenAskedByName() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openWeb(model, page)
        let session = try XCTUnwrap(page.detail)
        func ranks() -> [FakeKubeAPI.Request] { asked.filter { $0.path == service.queryPath && $0.query["query"]?.hasPrefix("topk(5,") == true } }
        try await until(5, "its top five read") { page.tabReading(of: session)?.results["cpuTop"] != nil && page.tabReading(of: session)?.results["revisions"] != nil }
        XCTAssertEqual(ranks().count, 2, "one ranking a measure")
        let span = try XCTUnwrap(page.tabReading(of: session)?.span)
        XCTAssertTrue(ranks().allSatisfy { $0.query["time"] == KubePromQL.stamp(span.end) && $0.query["timeout"] == "20s" }, "at the span's end")
        XCTAssertEqual(page.tabReading(of: session)?.ranking?.names["cpu"], ["web-7f9c6d-aaaaa", "web-55d4f-bbbbb"])
        let byName = asked.filter { $0.path == service.rangePath && $0.query["query"]?.hasPrefix("sum by (pod)(") == true }
        XCTAssertTrue(byName.contains { $0.query["query"]?.contains(#"pod=~"web-7f9c6d-aaaaa|web-55d4f-bbbbb""#) == true }, "\(byName.map(\.query))")
        try await until(5, "built") { page.objectCharts(of: session)?.charts.first { $0.data.id.hasSuffix(".revisions") } != nil }
        let charts = try XCTUnwrap(page.objectCharts(of: session))
        XCTAssertEqual(charts.view, .perPod, "two replicas: Per pod")
        XCTAssertEqual(charts.charts.first?.data.usage.map(\.id), ["web-7f9c6d-aaaaa", "web-55d4f-bbbbb"])
        XCTAssertEqual(charts.charts.first?.data.tier, "raw cAdvisor · by owner")
        let revisions = try XCTUnwrap(charts.charts.first { $0.data.id.hasSuffix(".revisions") })
        XCTAssertEqual(Set(revisions.data.usage.map(\.id)), ["rev:7f9c6d", "rev:55d4f"], "by ReplicaSet, from kube-state-metrics' owners")
        // Refreshed: the ranking kept until its tenth refresh, then asked again.
        try await until(5, "refreshed with the ranking kept") { (page.tabReading(of: session)?.ranking?.refreshes ?? 0) >= 3 }
        XCTAssertEqual(ranks().count, 2, "not ranked again meanwhile")
        try await until(10, "ranked again") { ranks().count == 4 }
        try await until(5, "the new ranking used") { (page.tabReading(of: session)?.ranking?.refreshes ?? 99) < KubeTabRanking.kept - 1 }

        // A namespace's tab: its raw series counted once, its workloads by owner.
        api.setPrometheusMatrix("topk(8,", [FakePromFixture.Line(["workload_type": "deployment", "workload": "web"]) { _ in 0.4 }])
        api.setPrometheusMatrix("avg_over_time((", [FakePromFixture.Line(["overterm_s": "cpu"]) { _ in 0.05 }])
        api.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "web-1", "phase": "Running"], value: 1)
        page.showKind(.namespaces)
        try await until(5, "namespaces listed") { model.kind.fullName == "namespaces" && model.rows[KubeRowID(namespace: nil, name: "shop")] != nil }
        api.forgetRequests()
        page.selection = ["shop"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.ref.name == "shop" && page.detail?.object != nil }
        XCTAssertEqual(page.metricsRanges, KubeMetricsRange.allCases, "a namespace's ranges over Prometheus too")
        page.pickMetricsRange(.hour)
        let namespace = try XCTUnwrap(page.detail)
        try await until(5, "its workloads read") { page.tabReading(of: namespace)?.results["cpuTop"]?.isEmpty == false }
        try await until(5, "built") { page.objectCharts(of: namespace)?.charts.first?.data.source == "Prometheus" }
        let built = try XCTUnwrap(page.objectCharts(of: namespace))
        let cpu = try XCTUnwrap(built.charts.first { $0.data.id == "namespace.shop.cpu" })
        XCTAssertEqual(cpu.data.usage.map(\.id), ["Deployment/web", "other"], "web's pods, and web-1, which nothing owns")
        XCTAssertTrue(cpu.chips.contains { $0.text.hasPrefix("requested but idle:") }, "\(cpu.chips)")
        XCTAssertEqual(built.charts.first { $0.data.id == "namespace.shop.phases" }?.data.usage.map(\.name), ["Running"])
        try await until(5, "refreshed") { (page.tabReading(of: namespace)?.ranking?.refreshes ?? 0) >= 2 }
        let counts = asked.filter { $0.query["query"]?.hasPrefix("count(container_cpu_usage_seconds_total{") == true }
        XCTAssertEqual(counts.count, 1, "counted once, kept with the profile")
        XCTAssertEqual(model.prometheus.profile?.namespaceSeries["shop"], 3)
        XCTAssertFalse(
            asked.contains { $0.query["query"]?.contains("[1h:") == true && $0.query["query"]?.hasPrefix("topk(8,") == false && $0.path == service.rangePath }, "no subquery in a range query")
    }

    /// The ranking never holds the visible charts back (metrics.md 4.5,
    /// 6.3): ranked again on another span, its count and its `topk`s slow,
    /// the total's range query goes out at once — the top five once ranked.
    func testTheVisibleChartsAreAskedWhileTheRankingIsRead() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openWeb(model, page)
        let session = try XCTUnwrap(page.detail)
        try await until(5, "ranked over the hour") { page.tabReading(of: session)?.results["cpuTop"] != nil }
        func totals() -> [FakeKubeAPI.Request] {
            asked.filter {
                $0.path == service.rangePath && $0.query["query"]?.hasPrefix("sum((sum by (namespace,pod,container)(rate(container_cpu_usage_seconds_total{") == true
                    && (range($0).map { $0.end - $0.start } ?? 0) > 3 * 3600
            }
        }
        func ranks() -> [FakeKubeAPI.Request] { asked.filter { $0.path == service.queryPath && $0.query["query"]?.hasPrefix("topk(5,") == true } }
        let ranked = ranks().count
        // Every instant query slow from here: the count, then the two rankings.
        api.answerSlowly(service.queryPath, milliseconds: 1500)
        let asking = Date()
        page.pickMetricsRange(.sixHours)
        try await until(1.2, "the total asked before the ranking answers") { !totals().isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(asking), 1.4, "not after the count's and the ranking's answers")
        XCTAssertEqual(ranks().count, ranked, "the ranking still waits for its count")
        XCTAssertTrue(asked.contains { $0.query["query"]?.hasPrefix("count by (pod)(container_cpu_usage_seconds_total{") == true }, "its pods counted first")
        try await until(8, "ranked over six hours, its top five asked") {
            ranks().count == ranked + 2 && page.tabReading(of: session)?.span.map { $0.end.timeIntervalSince($0.start) > 3 * 3600 } == true
                && page.tabReading(of: session)?.results["cpuTop"] != nil
        }
        api.answerSlowly(service.queryPath, milliseconds: nil)
    }

    /// A namespace whose count fails: nothing read raw across it (the count
    /// is what bounds that), the failure said, counted again at the next refresh.
    func testANamespaceWhoseCountFailsIsntReadRaw() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        api.setPrometheusMatrix(#"count(container_cpu_usage_seconds_total{namespace="shop""#, failure: FakePromFixture.Failure(status: 503, errorType: "unavailable", error: "busy"))
        api.setPrometheusSeries("kube_pod_status_phase", labels: ["namespace": "shop", "pod": "web-1", "phase": "Running"], value: 1)
        model.show()
        page.visible = true
        try await until(5, "discovery read") { model.discovery != nil }
        page.showKind(.namespaces)
        try await until(5, "namespaces listed") { model.kind.fullName == "namespaces" && model.rows[KubeRowID(namespace: nil, name: "shop")] != nil }
        page.selection = ["shop"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.ref.name == "shop" && page.detail?.object != nil }
        try await until(5, "Prometheus found") { model.prometheus.service == service }
        page.pickMetricsRange(.hour)
        let session = try XCTUnwrap(page.detail)
        func counts() -> Int { asked.filter { $0.query["query"]?.hasPrefix(#"count(container_cpu_usage_seconds_total{namespace="shop""#) == true }.count }
        try await until(5, "read without its count") { page.tabReading(of: session)?.results["phases"] != nil }
        let reading = try XCTUnwrap(page.tabReading(of: session))
        XCTAssertTrue(reading.refused[.cpu]?.contains("couldn't be counted") == true, "\(reading.refused)")
        XCTAssertNotNil(reading.refused[.idle])
        XCTAssertNotNil(reading.problem, "the failure said")
        XCTAssertNil(model.prometheus.profile?.namespaceSeries["shop"])
        XCTAssertTrue(model.prometheus.profile?.uncounted.isEmpty ?? true, "never kept with the profile")
        let raw = asked.filter {
            ($0.query["query"]?.contains("container_cpu_usage_seconds_total{") == true || $0.query["query"]?.contains("container_memory_working_set_bytes{") == true)
                && $0.query["query"]?.hasPrefix("count(") == false && $0.query["query"]?.hasPrefix("label_replace(count") == false
        }
        XCTAssertEqual(raw.map { $0.query["query"] ?? "" }, [], "nothing raw across the namespace")
        try await until(5, "counted again at the next refresh") { counts() >= 2 }
    }
}
