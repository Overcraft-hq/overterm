import Foundation
import XCTest

@testable import Overterm

/// Sizing on a pod's Metrics tab (docs/design/kubernetes/metrics.md 2.10;
/// stage M10), the page over `FakeKubeAPI` and its fake Prometheus (the
/// prometheus chart's profile: no rules, a minute's scrape), never a
/// cluster of the user's: nothing asked before the press; on it, R1's
/// instant queries over the week, through the Service's `query` with 20 s,
/// once — never refreshed; the card against the pod's spec; left before
/// it answers, dropped and not asked again until pressed. GETs only.
@MainActor
final class KubeSizingPageTests: XCTestCase {
    private var api: FakeKubeAPI!
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

    /// The queries Sizing asks: R1's measures (none of the tab's charts reads a week).
    private var sizing: [FakeKubeAPI.Request] { api.requests.filter { $0.isPrometheusQuery && $0.query["query"]?.contains("168h") == true } }

    private func pageOverFake(prometheus: String? = "monitoring/prometheus-server:80") throws -> (KubernetesModel, KubernetesPageModel) {
        let socket = "/tmp/otksz-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.metricsServer = true
        api.addNamespace("shop")
        api.addNamespace("monitoring")
        api.addPod(
            "web-1", namespace: "shop",
            FakeKubeAPI.Pod(ready: 1, containers: 1, resources: ["app": ["requests": ["cpu": "1", "memory": "256Mi"], "limits": ["memory": "512Mi"]]]))
        api.setPodMetrics("web-1", namespace: "shop", [("app", "120m", "100Mi")])
        api.servePrometheus(namespace: "monitoring", service: "prometheus-server", port: "80")
        api.setPrometheusProfile(.prometheusChart)
        let labels = ["namespace": "shop", "pod": "web-1", "container": "app", "image": "nginx:1.27", "metrics_path": "/metrics/cadvisor"]
        api.setPrometheusSeries("container_cpu_usage_seconds_total", labels: labels, value: 0.25)
        api.setPrometheusSeries("container_memory_working_set_bytes", labels: labels, value: 64 * 1_048_576)
        api.setPrometheusMatrix("container_cpu_cfs_throttled_periods_total{", [])
        api.setPrometheusMatrix("container_network_receive_bytes_total{", [])
        api.setPrometheusMatrix("sum(clamp_min(", [])
        api.setPrometheusMatrix("kube_pod_container_status_last_terminated_reason{", [])
        api.setPrometheusMatrix("container_fs_usage_bytes{", [])
        let mi = 1_048_576.0
        let app = ["container": "app"]
        api.setPrometheusMatrix("quantile_over_time(0.5, (sum", [FakePromFixture.Line(app) { _ in 0.11 }])
        api.setPrometheusMatrix("quantile_over_time(0.95, (sum", [FakePromFixture.Line(app) { _ in 0.21 }])
        api.setPrometheusMatrix("max_over_time((sum", [FakePromFixture.Line(app) { _ in 0.48 }])
        api.setPrometheusMatrix("quantile_over_time(0.95, (max", [FakePromFixture.Line(app) { _ in 498 * mi }])
        api.setPrometheusMatrix("max_over_time(container_memory_working_set_bytes{", [FakePromFixture.Line(app) { _ in 509 * mi }])
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
        model.prometheus.interval = .milliseconds(100)
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        model.prometheusOverride = { context, service in
            KubePrometheusDirect(connection: KubeSocketConnection(socket: socket, context: context.name), service: service)
        }
        return (model, KubernetesPageModel(model: model))
    }

    private func openPod(_ model: KubernetesModel, _ page: KubernetesPageModel, prometheus: Bool = true) async throws {
        model.show()
        page.visible = true
        try await until(5, "listed") { model.rows.count == 1 && model.discovery != nil }
        page.selection = ["shop/web-1"]
        XCTAssertTrue(page.press("m"))
        try await until(5, "its object read") { page.detail?.object != nil }
        if prometheus { try await until(5, "Prometheus found") { model.prometheus.service == service } }
    }

    func testSizingAsksAWeekOnceOnThePressAndSuggests() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openPod(model, page)
        let ref = try XCTUnwrap(page.detail?.ref)
        XCTAssertTrue(page.offersSizing(ref))
        XCTAssertNil(page.sizingDisabled)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(sizing.isEmpty, "nothing before the press: \(sizing.map(\.query))")

        page.sizeUsage()
        try await until(5, "read") { page.sizingReading(of: ref)?.done == true }
        let reading = try XCTUnwrap(page.sizingReading(of: ref))
        XCTAssertNil(reading.problem, reading.problem ?? "")
        XCTAssertEqual(reading.window, 7 * 86400, "Prometheus keeps 15 days: a week")
        XCTAssertEqual(reading.tier, .raw)
        XCTAssertEqual(reading.figures.map(\.container), ["app"])
        XCTAssertEqual(sizing.count, 5, "one instant query a measure over the week: \(sizing.map(\.query))")
        XCTAssertEqual(reading.queries.map(\.id), ["cpu50", "cpu95", "cpuMax", "memory95", "memoryMax", "oom"], "and the OOMKills kube-state-metrics says")
        XCTAssertTrue(sizing.allSatisfy { $0.path == service.queryPath && $0.query["timeout"] == "20s" && $0.query["start"] == nil }, "instant, with 20 s")
        XCTAssertTrue(sizing.allSatisfy { $0.query["query"]?.contains(#"namespace="shop",pod="web-1""#) == true }, "the pod alone")

        let session = try XCTUnwrap(page.detail)
        let card = try XCTUnwrap(page.sizingCard(of: session))
        XCTAssertEqual(card.title, "Sizing · 7 days · per pod · raw cAdvisor")
        let row = try XCTUnwrap(card.rows.first)
        XCTAssertEqual(row.cpu?.suggestion, "suggested request ≈ p95 × 1.15 = 245m")
        XCTAssertEqual(row.cpu?.now, "now: request 1000m · limit none", "against the pod's spec")
        XCTAssertEqual(row.memory?.suggestion, "suggested request and limit ≈ max × 1.15 = 586Mi")
        XCTAssertEqual(row.memory?.limit, 512 * 1_048_576)

        // Once: never refreshed, nor asked again on its way back to the tab.
        XCTAssertNil(page.sizingWant)
        let asked = sizing.count
        try await Task.sleep(for: .milliseconds(500))
        page.showTab(.overview)
        page.showTab(.metrics)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sizing.count, asked, "never refreshed")
        XCTAssertNotNil(page.sizingCard(of: session), "kept while its object shows")
        page.hideSizing()
        XCTAssertNil(page.sizingReading(of: ref))

        // Pressed again: asked again.
        page.sizeUsage()
        try await until(5, "read again") { page.sizingReading(of: ref)?.done == true }
        XCTAssertEqual(sizing.count, asked * 2)
        XCTAssertEqual(model.prometheus.sizings.count, 1, "the earlier press's answer gone")
    }

    func testSizingLeftBeforeItAnswersIsDroppedAndNotAskedAgain() async throws {
        let (model, page) = try pageOverFake()
        defer { model.hide() }
        try await openPod(model, page)
        let ref = try XCTUnwrap(page.detail?.ref)
        api.answerSlowly(service.queryPath, milliseconds: 800)
        page.sizeUsage()
        try await until(5, "asking") { page.sizingReading(of: ref)?.done == false }
        page.showTab(.overview)
        try await until(5, "left before it answered: dropped") { page.sizingAsked == nil }
        try await until(5, "its reading gone") { model.prometheus.sizings.isEmpty }
        api.answerSlowly(service.queryPath, milliseconds: nil)
        try await Task.sleep(for: .milliseconds(900))
        api.forgetRequests()
        page.showTab(.metrics)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(sizing.isEmpty, "not asked again without a press: \(sizing.map(\.query))")
        XCTAssertNil(page.sizingReading(of: ref))
    }

    func testSizingNeedsPrometheusOnForTheContext() async throws {
        let (model, page) = try pageOverFake(prometheus: nil)
        defer { model.hide() }
        try await openPod(model, page, prometheus: false)
        let ref = try XCTUnwrap(page.detail?.ref)
        XCTAssertNil(page.sizingSubject(of: KubeObjectRef(context: "fake-dev", kind: .namespaces, namespace: nil, name: "shop")), "a namespace isn't sized")
        XCTAssertEqual(page.sizingSubject(of: ref), .pod(namespace: "shop", name: "web-1"), "a pod would be")
        XCTAssertFalse(page.prometheusOn)
        XCTAssertFalse(page.offersSizing(ref), "not offered: Prometheus isn't on for the context")
        page.sizeUsage()
        XCTAssertNil(page.sizingAsked, "a press does nothing")
        // Even a press left over (the setting turned off since): nothing read.
        page.sizingAsked = KubeSizingRequest(context: "fake-dev", subject: .pod(namespace: "shop", name: "web-1"), asked: Date())
        XCTAssertNil(page.sizingWant, "not read with Prometheus off")
        page.sizingAsked = nil
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(api.requests.contains(where: \.isPrometheusQuery), "no Prometheus query: \(api.requests.filter(\.isPrometheusQuery).map(\.query))")
        XCTAssertTrue(model.prometheus.sizings.isEmpty)
    }
}
