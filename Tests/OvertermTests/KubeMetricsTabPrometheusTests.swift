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
        XCTAssertEqual(reading.request.families, KubeTabFamily.prometheusOnly)
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
        page.metricsGroupShown(true)
        XCTAssertEqual(page.tabRequest(of: session)?.families.isSuperset(of: KubePromTabCharts.readWhenShown), true)
        XCTAssertNotNil(page.tabReading(of: session)?.read, "the last answers stand while the new request is read")
        try await until(5, "top pods asked") { top().count == 2 }
        try await until(5, "read") { page.tabReading(of: session)?.results["topCPU"] != nil }
        page.metricsGroupShown(false)
        XCTAssertNotNil(page.tabReading(of: session)?.read, "scrolled off: what was read stands")
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(top().isEmpty, "scrolled off: not asked again \(top().map(\.query))")
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
}
