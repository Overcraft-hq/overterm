import Foundation
import XCTest

@testable import Overterm

/// Usage from metrics.k8s.io (stage 2d; docs/design/kubernetes/analysis.md,
/// 2.11): quantities read as the API writes them, metrics-server's lists
/// read, said as `kubectl top` says them, a dash with why when there is
/// none — no metrics-server (discovery says so, nothing is asked), a read
/// refused, a sample too old — and the polling: only while a page shows
/// the column, stopped when it hides, never with `metrics: none`. Against
/// `FakeKubeAPI` on a socket of the test's own; nothing reads ~/.kube.
@MainActor
final class KubeMetricsTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otkmt-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop")
        api.addPod("worker-1", namespace: "shop", FakeKubeAPI.Pod(containers: 2))
        api.addPod("pending-1", namespace: "shop", FakeKubeAPI.Pod(status: "Pending", phase: "Pending", ready: 0))
        api.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "control-plane", "Version": "v1.34.1"], fields: ["status": ["allocatable": ["cpu": "4", "memory": "8Gi"]]])
        api.setPodMetrics("web-1", namespace: "shop", [("app", "250m", "64Mi")])
        api.setPodMetrics("worker-1", namespace: "shop", [("app", "1234567n", "100Mi"), ("sidecar-1", "1m", "512Ki")])
        api.setNodeMetrics("fake-node-1", cpu: "1", memory: "2Gi")
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no subresource")
            api.stop()
        }
    }

    private static func context(_ name: String, namespace: String? = nil, metrics: KubeMetricsSource? = nil) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: namespace, user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings(metrics: metrics))
    }

    private func model(metrics: KubeMetricsSource? = nil) -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: [Self.context("fake-dev", namespace: "shop", metrics: metrics)], current: "fake-dev")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        model.flushInterval = .milliseconds(20)
        model.statusInterval = .milliseconds(50)
        model.metrics.interval = .milliseconds(100)
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return model
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private var metricsRequests: [FakeKubeAPI.Request] { api.requests.filter { $0.path.hasPrefix("/apis/metrics.k8s.io") } }

    // MARK: Pure

    func testQuantitiesReadAsTheAPIWritesThem() throws {
        let cases: [(String, Double)] = [
            ("1234567n", 0.001234567), ("250u", 0.00025), ("500m", 0.5), ("2", 2), ("1.5", 1.5), ("128Ki", 131_072), ("64Mi", 67_108_864),
            ("2Gi", 2_147_483_648), ("1Ti", 1_099_511_627_776), ("1k", 1000), ("1M", 1e6), ("1G", 1e9), ("1e3", 1000), ("1.5E2", 150), ("12E", 12e18),
            (" 3 ", 3), ("0", 0),
        ]
        for (text, value) in cases {
            let read = try XCTUnwrap(KubeQuantity.value(text), text)
            XCTAssertEqual(read, value, accuracy: abs(value) * 1e-12 + 1e-15, text)
        }
        for text in ["", "lots", "nan", "inf", "0x10", "12Q", "Mi", "1.2.3Mi"] {
            XCTAssertNil(KubeQuantity.value(text), text)
        }
    }

    func testMetricsListsAreRead() throws {
        let pods = Data(
            """
            {"kind":"PodMetricsList","apiVersion":"metrics.k8s.io/v1beta1","metadata":{},"items":[
             {"metadata":{"name":"web-1","namespace":"shop"},"timestamp":"2026-11-05T10:00:00Z","window":"15.007s",
              "containers":[{"name":"app","usage":{"cpu":"250m","memory":"64Mi"}},{"name":"sidecar","usage":{"cpu":"5000000n","memory":"1024Ki"}}]},
             {"metadata":{"name":"bad"},"containers":"nope"}
            ]}
            """.utf8)
        let read = try KubeMetricsReader.pods(pods)
        XCTAssertEqual(read.map(\.id.description), ["shop/web-1", "bad"])
        XCTAssertEqual(read[0].containers["sidecar"], KubeUsage(cpu: 0.005, memory: 1_048_576))
        XCTAssertEqual(read[0].total.cpu, 0.255, accuracy: 1e-9)
        XCTAssertEqual(read[0].timestamp, try Date("2026-11-05T10:00:00Z", strategy: .iso8601))
        XCTAssertEqual(read[0].window, "15.007s")
        XCTAssertEqual(read[1].containers, [:])
        XCTAssertThrowsError(try KubeMetricsReader.pods(Data("{\"kind\":\"Status\"}".utf8)))

        let nodes = Data(#"{"items":[{"metadata":{"name":"n1"},"timestamp":"2026-11-05T10:00:00Z","usage":{"cpu":"1500m","memory":"3Gi"}}]}"#.utf8)
        XCTAssertEqual(try KubeMetricsReader.nodes(nodes).first?.usage, KubeUsage(cpu: 1.5, memory: 3_221_225_472))
        let list = Data(#"{"metadata":{"continue":"abc"},"items":[{"metadata":{"name":"n1"},"status":{"allocatable":{"cpu":"3920m","memory":"15Gi","pods":"110"}}}]}"#.utf8)
        let allocatable = try KubeMetricsReader.allocatable(list)
        XCTAssertEqual(allocatable.nodes["n1"]?.cpu, 3.92)
        XCTAssertEqual(allocatable.continueToken, "abc")
    }

    func testUsageIsSaidAsKubectlTopSaysIt() {
        XCTAssertEqual(KubeMetricsFormat.cpu(0.25), "250m")
        XCTAssertEqual(KubeMetricsFormat.cpu(0.001234567), "1m")
        XCTAssertEqual(KubeMetricsFormat.cpu(12.5), "12500m")
        XCTAssertEqual(KubeMetricsFormat.memory(67_108_864), "64Mi")
        XCTAssertEqual(KubeMetricsFormat.memory(524_288), "512Ki")
        XCTAssertEqual(KubeMetricsFormat.memory(0), "0Mi")
        XCTAssertEqual(KubeMetricsFormat.percent(1, of: 4), 25)
        XCTAssertNil(KubeMetricsFormat.percent(1, of: 0))
        XCTAssertNil(KubeMetricsFormat.percent(1, of: nil))
    }

    func testDiscoverySaysWhetherThereIsAMetricsServer() {
        let pods = KubeResourceKind(group: "metrics.k8s.io", version: "v1beta1", resource: "pods", kind: "PodMetrics", singular: "", namespaced: true, verbs: ["get", "list"])
        let served = KubeDiscovery(kinds: [.pods, pods])
        XCTAssertEqual(KubeMetricsAvailability.of(served, source: .auto), .served)
        XCTAssertEqual(KubeMetricsAvailability.of(served, source: .metricsServer), .served)
        XCTAssertEqual(KubeMetricsAvailability.of(served, source: .none), .off, "none skips the check entirely")
        XCTAssertEqual(KubeMetricsAvailability.of(nil, source: .auto), .unknown)
        XCTAssertEqual(KubeMetricsAvailability.of(KubeDiscovery(kinds: [.pods]), source: .auto), .absent)
        XCTAssertEqual(
            KubeMetricsAvailability.of(KubeDiscovery(kinds: [.pods], failedGroups: ["metrics.k8s.io/v1beta1": "Stale"]), source: .auto), .down("Stale"))
        XCTAssertTrue(KubeMetricsAvailability.absent.reason?.contains("No metrics-server") == true)
        XCTAssertNil(KubeMetricsAvailability.served.reason)
        XCTAssertEqual(KubeMetricsTarget.pods(.namespace("shop"), labels: "app=web").path, "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods?labelSelector=app%3Dweb")
        XCTAssertEqual(KubeMetricsTarget.pods(.all, labels: nil).path, "/apis/metrics.k8s.io/v1beta1/pods")
        XCTAssertEqual(KubeContextSettings(fields: ["metrics": .string("none")]).metrics, KubeMetricsSource.none)
        XCTAssertEqual(KubeContextSettings(fields: ["metrics": .string("prometheus")]).metrics, .prometheus, "stage 4's")
        XCTAssertEqual(KubeMetricsAvailability.of(KubeDiscovery(kinds: [.pods]), source: .prometheus), .absent, "metrics-server's columns as before")
    }

    func testACellIsANumberOrADashSayingWhy() {
        let now = Date()
        let id = KubeRowID(namespace: "shop", name: "web-1")
        let pod = KubePodMetrics(id: id, timestamp: now, window: "15s", containers: ["app": KubeUsage(cpu: 0.25, memory: 67_108_864)])
        let fresh = KubeMetricsReading(sample: KubeMetricsSample(pods: [pod], read: now))
        func cell(_ availability: KubeMetricsAvailability, _ reading: KubeMetricsReading?, at time: Date = now, row: KubeRowID = id) -> KubeUsageCell {
            KubeUsageCell.of(.cpu, row: row, isNode: false, availability: availability, reading: reading, now: time, staleAfter: 60)
        }
        XCTAssertEqual(cell(.served, fresh), .value("250m", sort: 0.25, percent: nil))
        XCTAssertEqual(cell(.served, fresh).text, "250m")
        XCTAssertEqual(cell(.absent, fresh).text, "—", "no metrics-server: a dash")
        XCTAssertTrue(cell(.absent, nil).help?.contains("No metrics-server") == true)
        XCTAssertEqual(cell(.unknown, nil), .waiting)
        XCTAssertEqual(cell(.served, nil), .waiting)
        XCTAssertEqual(cell(.served, KubeMetricsReading(sample: nil, problem: "Not allowed")).help, "Usage couldn't be read: Not allowed")
        let old = cell(.served, KubeMetricsReading(sample: fresh.sample, problem: "timeout"), at: now.addingTimeInterval(120))
        XCTAssertEqual(old.text, "—", "never a stale number shown as current")
        XCTAssertTrue(old.help?.contains("Not read for 2m: timeout") == true, old.help ?? "")
        XCTAssertTrue(cell(.served, fresh, row: KubeRowID(namespace: "shop", name: "pending-1")).help?.contains("no sample") == true)

        // A node: its share of allocatable.
        let node = KubeNodeMetrics(name: "n1", timestamp: now, window: nil, usage: KubeUsage(cpu: 1, memory: 2_147_483_648))
        let nodes = KubeMetricsReading(sample: KubeMetricsSample(nodes: [node], allocatable: ["n1": KubeUsage(cpu: 4, memory: 8_589_934_592)], read: now))
        let memory = KubeUsageCell.of(.memory, row: KubeRowID(namespace: nil, name: "n1"), isNode: true, availability: .served, reading: nodes, now: now, staleAfter: 60)
        XCTAssertEqual(memory.text, "2048Mi (25%)")
        XCTAssertEqual(nodes.sample?.clusterAllocatable?.cpu, 4)
    }

    func testAPodsContainersAgainstTheirRequestsAndLimits() {
        let pod: [String: Any] = [
            "spec": [
                "containers": [
                    ["name": "app", "resources": ["requests": ["cpu": "500m", "memory": "128Mi"], "limits": ["cpu": "1", "memory": "256Mi"]]],
                    ["name": "sidecar"],
                ]
            ]
        ]
        let metrics = KubePodMetrics(
            id: KubeRowID(namespace: "shop", name: "web-1"), timestamp: nil, window: nil,
            containers: ["app": KubeUsage(cpu: 0.25, memory: 240 * 1_048_576), "sidecar": KubeUsage(cpu: 0.001, memory: 1_048_576)])
        let lines = KubeContainerUsage.lines(pod, metrics)
        XCTAssertEqual(lines.map(\.container), ["app", "sidecar"])
        XCTAssertEqual(lines[0].cpu, "250m · 50% of 500m requested · 25% of its 1000m limit")
        XCTAssertEqual(lines[0].memory, "240Mi · 188% of 128Mi requested · 94% of its 256Mi limit")
        XCTAssertTrue(lines[0].nearLimit, "within a tenth of its memory limit")
        XCTAssertEqual(lines[1].cpu, "1m")
        XCTAssertFalse(lines[1].nearLimit)
    }

    // MARK: Polled while shown

    func testUsageIsPolledOnlyWhileTheColumnShows() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "pods and discovery") { model.rows.count == 3 && model.discovery != nil }
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Status", "Restarts", "CPU", "Memory", "Age"], "usage before Age")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(metricsRequests, [], "the page isn't on screen: nothing asked")

        page.visible = true
        try await until(5, "a sample") { model.metrics.reading(.pods)?.sample != nil }
        XCTAssertEqual(model.metrics.availability, .served)
        XCTAssertTrue(metricsRequests.allSatisfy { $0.path == "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods" }, "\(metricsRequests)")
        let rows = page.rows
        func text(_ name: String, _ column: String) -> String {
            guard let row = rows.first(where: { $0.row.id.name == name }), let column = page.columns.first(where: { $0.id == column }) else { return "?" }
            return page.cellText(row, column, now: Date())
        }
        XCTAssertEqual(text("web-1", KubernetesPageModel.cpuColumn), "250m")
        XCTAssertEqual(text("web-1", KubernetesPageModel.memoryColumn), "64Mi")
        XCTAssertEqual(text("worker-1", KubernetesPageModel.cpuColumn), "2m", "its containers summed")
        XCTAssertEqual(text("pending-1", KubernetesPageModel.cpuColumn), "—", "not sampled")
        page.sort = ResourceSort(column: KubernetesPageModel.cpuColumn, ascending: false)
        XCTAssertEqual(page.rows.map(\.row.id.name), ["web-1", "worker-1", "pending-1"], "by usage, the unsampled last")
        page.sort = nil
        try await until(5, "polled again") { self.metricsRequests.count >= 3 }

        // Another kind with no usage: nothing asked.
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps")))
        try await until(5, "stopped") { !model.metrics.isPolling }
        XCTAssertFalse(page.columns.contains { $0.title == "CPU" })
        var asked = metricsRequests.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(metricsRequests.count, asked, "not polled while no column shows")

        // The nodes: theirs, with allocatable.
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "nodes")))
        try await until(5, "node sample") { model.metrics.reading(.nodes)?.sample?.nodes.isEmpty == false }
        try await until(5, "node allocatable") { model.metrics.reading(.nodes)?.sample?.allocatable.isEmpty == false }
        let node = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(page.usage(.cpu, of: node).text, "1000m (25%)")
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/nodes" && $0.query["limit"] == "500" }, "allocatable from the NodeList")

        // Hidden: no more.
        page.visible = false
        try await until(5, "stopped hidden") { !model.metrics.isPolling }
        asked = metricsRequests.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(metricsRequests.count, asked, "hidden, nothing polled")
    }

    func testWithoutAMetricsServerTheColumnsAreDashesAndNothingIsAsked() async throws {
        api.metricsServer = false
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods and discovery") { model.rows.count == 3 && model.discovery != nil }
        try await until(5, "absent") { model.metrics.availability == .absent }
        XCTAssertTrue(page.columns.contains { $0.title == "CPU" }, "the columns, with dashes")
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(page.usage(.cpu, of: row).text, "—")
        XCTAssertTrue(page.metricsNote?.contains("No metrics-server") == true, page.metricsNote ?? "")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(metricsRequests, [], "discovery said so: no request, no error")
        XCTAssertEqual(model.listState, .live, "the list is fine")

        // metrics-server comes: read again, it is polled.
        api.metricsServer = true
        model.rediscover()
        try await until(5, "served") { model.metrics.availability == .served && model.metrics.reading(.pods)?.sample != nil }
        XCTAssertEqual(page.usage(.cpu, of: try XCTUnwrap(page.rows.first { $0.row.id.name == "web-1" })).text, "250m")
    }

    func testMetricsNoneSkipsTheCheckEntirely() async throws {
        let model = model(metrics: KubeMetricsSource.none)
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods and discovery") { model.rows.count == 3 && model.discovery != nil }
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Status", "Restarts", "Age"], "no usage column")
        XCTAssertEqual(model.metrics.availability, .off)
        page.showSection(.overview)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(metricsRequests, [], "nothing asked of metrics.k8s.io")
        XCTAssertNil(page.metricsNote)
    }

    func testARefusedReadIsADashAndTheListStands() async throws {
        // A server failing its pods' reads (metrics-server's `pods` too): a 500.
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        api.failingResources = ["pods"]
        page.visible = true
        try await until(5, "a problem") { model.metrics.reading(.pods)?.problem != nil }
        XCTAssertTrue(page.metricsNote?.hasPrefix("Usage couldn't be read") == true, page.metricsNote ?? "")
        XCTAssertEqual(page.usage(.cpu, of: try XCTUnwrap(page.rows.first)).text, "—")
        api.failingResources = []
        try await until(5, "read again") { model.metrics.reading(.pods)?.problem == nil && model.metrics.reading(.pods)?.sample != nil }
    }

    // MARK: History, and a credential failure

    func testHistoryKeepsTheLastSamplesWhileShownInMemory() {
        var history = KubeUsageHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        let web = KubeRowID(namespace: "shop", name: "web-1")
        let gone = KubeRowID(namespace: "shop", name: "gone-1")
        for index in 0..<(KubeUsageHistory.capacity + 5) {
            var pods = [KubePodMetrics(id: web, timestamp: nil, window: nil, containers: ["app": KubeUsage(cpu: Double(index), memory: 1)])]
            if index == 0 { pods.append(KubePodMetrics(id: gone, timestamp: nil, window: nil, containers: ["app": KubeUsage(cpu: 1, memory: 1)])) }
            history.record(KubeMetricsSample(pods: pods, read: start.addingTimeInterval(Double(index) * 15)))
        }
        XCTAssertEqual(history.points(web).count, KubeUsageHistory.capacity, "a ring: the last ones only")
        XCTAssertEqual(history.points(web).first?.usage.cpu, 5)
        XCTAssertEqual(history.points(web).last?.usage.cpu, Double(KubeUsageHistory.capacity + 4))
        XCTAssertEqual(history.points(gone), [], "a pod no longer sampled is forgotten")
        XCTAssertEqual(history.cluster, [], "pods add nothing to the cluster's")
        XCTAssertEqual(KubeUsageHistory.span(history.points(web)), "the last 9m45s, sampled while shown")
        XCTAssertNil(KubeUsageHistory.span(Array(history.points(web).prefix(1))), "one sample is no line")

        var nodes = KubeUsageHistory()
        nodes.record(
            KubeMetricsSample(
                nodes: [
                    KubeNodeMetrics(name: "fake-node-1", timestamp: nil, window: nil, usage: KubeUsage(cpu: 1, memory: 2)),
                    KubeNodeMetrics(name: "fake-node-2", timestamp: nil, window: nil, usage: KubeUsage(cpu: 0.5, memory: 1)),
                ], allocatable: [:], read: start))
        XCTAssertEqual(nodes.cluster.map(\.usage), [KubeUsage(cpu: 1.5, memory: 3)], "every node's, added up")
        XCTAssertEqual(nodes.points(KubeRowID(namespace: nil, name: "fake-node-2")).map(\.usage), [KubeUsage(cpu: 0.5, memory: 1)])
    }

    func testSamplesTakenWhileShownMakeTheSparklines() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        try await until(5, "three samples") { (model.metrics.reading(.pods)?.history.points(KubeRowID(namespace: "shop", name: "web-1")).count ?? 0) >= 3 }
        let web = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1")
        XCTAssertGreaterThanOrEqual(page.usageHistory(of: web).count, 3)
        XCTAssertEqual(page.usageHistory(of: web).last?.usage.cpu, 0.25)
        page.showSection(.overview)
        try await until(5, "the cluster's") { page.clusterHistory.count >= 2 }
        XCTAssertEqual(page.clusterHistory.last?.usage.cpu, 1)
        page.visible = false
        try await until(5, "hidden, gone") { model.metrics.reading(.nodes) == nil && !model.metrics.isPolling }
        XCTAssertEqual(page.clusterHistory, [], "nothing kept once hidden")
    }

    func testACredentialFailureDropsTheSampleAndOnlyARetryPollsAgain() async throws {
        let failing = FailSwitch()
        let model = model()
        let socket = self.socket!
        model.connectOverride = { context in
            FailingMetricsConnection(inner: KubeSocketConnection(socket: socket, context: context.name), failing: failing)
        }
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        try await until(5, "a sample") { model.metrics.reading(.pods)?.sample != nil }
        let row = try XCTUnwrap(page.rows.first { $0.row.id.name == "web-1" })
        XCTAssertEqual(page.usage(.cpu, of: row).text, "250m")

        failing.on = true
        try await until(5, "stopped at the credential failure") { !model.metrics.isPolling }
        // Nothing more will come: the sample is gone at once, not left standing.
        XCTAssertNil(model.metrics.reading(.pods)?.sample)
        XCTAssertEqual(page.usage(.cpu, of: row).text, "—", "no stale number")
        XCTAssertEqual(page.usage(.cpu, of: row, now: Date().addingTimeInterval(model.metrics.staleAfter + 1)).text, "—")
        XCTAssertTrue(page.metricsNote?.hasPrefix("Usage couldn't be read") == true, page.metricsNote ?? "")
        XCTAssertEqual(page.usageHistory(of: KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1")), [])

        // A page asking again doesn't run the sign-in again.
        failing.on = false
        page.visible = false
        page.visible = true
        let asked = failing.metricsAsked
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(model.metrics.isPolling)
        XCTAssertEqual(failing.metricsAsked, asked, "not asked again by showing the page again")

        // A retry, after a sign-in: polled again.
        model.retry()
        try await until(5, "polled after the retry") { model.metrics.reading(.pods)?.sample != nil && model.metrics.isPolling }
        XCTAssertEqual(page.usage(.cpu, of: row).text, "250m")
    }
}

/// Whether `FailingMetricsConnection` fails metrics.k8s.io's reads as a
/// credential failure (the exec plugin's), and how often it was asked.
private final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var _on = false
    private var _asked = 0
    var on: Bool {
        get { lock.withLock { _on } }
        set { lock.withLock { _on = newValue } }
    }
    var metricsAsked: Int { lock.withLock { _asked } }
    func ask() -> Bool {
        lock.withLock {
            _asked += 1; return _on
        }
    }
}

/// The test socket, with metrics.k8s.io failing as a sign-in does when asked to.
private struct FailingMetricsConnection: KubeConnection {
    let inner: KubeSocketConnection
    let failing: FailSwitch
    var signIn: KubeSignIn { inner.signIn }

    func get(_ path: String, headers: [(String, String)]) async throws -> HTTPResponse {
        if path.hasPrefix("/apis/metrics.k8s.io/"), failing.ask() { throw KubeProxyProblem.credentials("the token expired") }
        return try await inner.get(path, headers: headers)
    }

    func stream(_ path: String, headers: [(String, String)]) -> AsyncThrowingStream<Data, Error> { inner.stream(path, headers: headers) }
}
