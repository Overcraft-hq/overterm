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

    func testSamplesTakenWhileShownMakeTheSparklines() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        try await until(5, "three samples") { model.metrics.ring.points(.pod(namespace: "shop", name: "web-1")).count >= 3 }
        let web = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1")
        XCTAssertGreaterThanOrEqual(page.usageHistory(of: web).count, 3)
        XCTAssertEqual(page.usageHistory(of: web).last?.usage.cpu, 0.25)
        XCTAssertGreaterThan(model.metrics.merges, 0)
        XCTAssertEqual(model.metrics.mergesOnMain, 0, "merged off the main thread")
        page.showSection(.overview)
        try await until(5, "the cluster's") { page.clusterHistory.count >= 2 }
        XCTAssertEqual(page.clusterHistory.last?.usage.cpu, 1)
        page.visible = false
        try await until(5, "hidden, gone") { model.metrics.reading(.nodes) == nil && !model.metrics.isPolling }
        XCTAssertEqual(page.clusterHistory, [], "nothing kept once hidden")
    }

    // MARK: A detail's own reads (metrics.md 4.1)

    func testAPodsDetailReadsItsOwnSampleAndKeepsItAnHour() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        let own = "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods/web-1"
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1")
        page.open(ref, from: .list)
        try await until(5, "the pod's own reads") { self.metricsRequests.filter { $0.path == own }.count >= 3 }
        XCTAssertEqual(model.metrics.details, [.pod(namespace: "shop", name: "web-1")])
        try await until(5, "its samples, both tiers") { model.metrics.ring.points(.pod(namespace: "shop", name: "web-1")).count >= 2 }
        XCTAssertTrue(model.metrics.ring.holds(.pod(namespace: "shop", name: "web-1"), .detail))
        XCTAssertEqual(model.metrics.ring.folded(.pod(namespace: "shop", name: "web-1")).isEmpty, false)
        XCTAssertTrue(model.metrics.ring.holds(.container(namespace: "shop", pod: "web-1", container: "app"), .detail), "each container's too")
        XCTAssertEqual(page.podSample(of: ref)?.total.cpu, 0.25)

        // The list on another kind: the detail's own sample still says it.
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps")))
        page.open(ref, from: .list)
        try await until(5, "only the pod's own read") { model.metrics.reading(.pods) == nil && page.podSample(of: ref) != nil }

        // Closed: no more reads, but its samples stay their hour.
        page.closeDetail()
        try await until(5, "stopped") { !model.metrics.isPolling }
        let asked = metricsRequests.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(metricsRequests.count, asked, "nothing read once the detail closes")
        XCTAssertTrue(model.metrics.ring.holds(.pod(namespace: "shop", name: "web-1"), .detail), "kept an hour after (decision 1)")
        XCTAssertEqual(model.metrics.ring.points(.pod(namespace: "shop", name: "web-1"), now: Date().addingTimeInterval(3_700)), [], "not past it")

        // Another context: every sample of this one dropped.
        model.metrics.update(
            KubeMetricsMonitor.Situation(context: "fake-other", scope: .namespace("shop"), labels: nil, availability: .served), client: { nil })
        XCTAssertTrue(model.metrics.ring.isEmpty)
    }

    func testLeavingThePageKeepsADetailsSamplesUntilAnotherContext() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        let key = KubeUsageKey.pod(namespace: "shop", name: "web-1")
        let ref = KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1")
        // Its detail open over another kind: only its own reads.
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps")))
        page.open(ref, from: .list)
        try await until(5, "both tiers") { model.metrics.ring.holds(key, .detail) && !model.metrics.ring.folded(key).isEmpty }
        let points = model.metrics.ring.points(key)
        page.closeDetail()
        try await until(5, "stopped") { !model.metrics.isPolling }
        let asked = metricsRequests.count

        // The page left (the model's last viewer gone) and come back to.
        model.hide()
        XCTAssertFalse(model.isShown)
        XCTAssertTrue(model.metrics.ring.holds(key, .detail), "kept while the page is hidden (decision 1)")
        model.show()
        try await until(5, "listed again") { model.listState == .live && model.metrics.availability == .served }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.metrics.ring.holds(key, .detail), "kept once it shows again")
        XCTAssertFalse(model.metrics.ring.folded(key).isEmpty, "its folded tier too")
        XCTAssertEqual(model.metrics.ring.points(key), points, "what was sampled before")
        XCTAssertEqual(metricsRequests.count, asked, "and nothing asked for it")

        // The monitor alone: nowhere, then the same context — the same cluster and user —, keeps them…
        let dev = try XCTUnwrap(model.contexts.context(named: "fake-dev"))
        let here = KubeMetricsMonitor.Situation(
            context: "fake-dev", scope: .namespace("shop"), labels: nil, availability: .served, cluster: KubePrometheusMonitor.cluster(of: dev))
        model.metrics.update(nil) { nil }
        model.metrics.update(here) { nil }
        XCTAssertTrue(model.metrics.ring.holds(key, .detail))
        // …the same name pointed at another cluster drops them, as another context, even after nowhere, does.
        var moved = here
        moved.cluster = "http://127.0.0.1:2\nfake-dev\nanonymous"
        model.metrics.update(moved) { nil }
        XCTAssertTrue(model.metrics.ring.isEmpty, "another cluster's samples are never this one's")
        model.metrics.update(nil) { nil }
        model.metrics.update(KubeMetricsMonitor.Situation(context: "fake-other", scope: .namespace("shop"), labels: nil, availability: .served)) { nil }
        XCTAssertTrue(model.metrics.ring.isEmpty)
    }

    func testANamespaceRefusedLeavesTheOthersUsage() async throws {
        // `view` bound in shop, not in locked.
        api.addNamespace("locked")
        api.addPod("vault-1", namespace: "locked")
        api.setPodMetrics("vault-1", namespace: "locked", [("app", "5m", "8Mi")])
        api.forbidden = ["pods.metrics.k8s.io@locked"]
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 3 && model.listState == .live }
        model.setScope(.of(["shop", "locked"]))
        try await until(5, "both namespaces' pods") { model.rows.count == 4 && model.listState == .live && model.discovery != nil }
        try await until(5, "shop's usage") { model.metrics.reading(.pods)?.sample?.pods.isEmpty == false }
        let sentence = "metrics-server answered 403: you can't list pods.metrics.k8s.io in locked."
        let reading = try XCTUnwrap(model.metrics.reading(.pods))
        XCTAssertNil(reading.refused, "the target isn't refused: shop answered")
        XCTAssertEqual(reading.sample?.refusal, sentence, "only the refused namespace named")
        XCTAssertEqual(page.metricsNote, sentence)
        XCTAssertTrue(page.metricsNoteIsRefusal)
        let web = try XCTUnwrap(page.rows.first { $0.row.id.name == "web-1" })
        let vault = try XCTUnwrap(page.rows.first { $0.row.id.name == "vault-1" })
        XCTAssertEqual(page.usage(.cpu, of: web).text, "250m", "shop's usage stands")
        XCTAssertEqual(page.usage(.cpu, of: vault), .dash(sentence))
        let shop = "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods"
        let locked = "/apis/metrics.k8s.io/v1beta1/namespaces/locked/pods"
        try await until(5, "polled again") { self.metricsRequests.filter { $0.path == shop }.count >= 3 }
        XCTAssertEqual(metricsRequests.filter { $0.path == locked }.count, 1, "the refused namespace isn't asked again")

        // The sentences: past the cap the read refused is the cluster's.
        let many = KubeScope.of((0...KubeScope.watchCap).map { "acme-\($0)" })
        XCTAssertEqual(
            KubeMetricsTarget.pods(many, labels: nil).refusal, "metrics-server answered 403: you can't list pods.metrics.k8s.io across the cluster.")
        XCTAssertEqual(KubeMetricsTarget.podsRefusal(["shop", "locked"]), "metrics-server answered 403: you can't list pods.metrics.k8s.io in locked, shop.")

        // Granted since (no new credentials): Try Again asks again.
        api.forbidden = []
        model.retry()
        try await until(5, "locked's usage") { model.metrics.reading(.pods)?.sample?.pods[KubeRowID(namespace: "locked", name: "vault-1")] != nil }
        XCTAssertNil(model.metrics.reading(.pods)?.sample?.refusal)
        XCTAssertEqual(page.usage(.cpu, of: vault).text, "5m")
    }

    func testEveryNamespaceRefusedRefusesTheTarget() async throws {
        api.addNamespace("locked")
        api.forbidden = ["pods.metrics.k8s.io@locked", "pods.metrics.k8s.io@shop"]
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 3 && model.listState == .live }
        model.setScope(.of(["shop", "locked"]))
        let both = "metrics-server answered 403: you can't list pods.metrics.k8s.io in locked, shop."
        try await until(5, "refused") { model.metrics.reading(.pods)?.refused == both }
        XCTAssertFalse(model.metrics.isPolling)
    }

    func testANodesAndAnHPAsOwnReads() async throws {
        api.add(
            "horizontalpodautoscalers.autoscaling", "web", namespace: "shop",
            fields: [
                "spec": [
                    "minReplicas": 2, "maxReplicas": 6,
                    "metrics": [["type": "Resource", "resource": ["name": "cpu", "target": ["type": "Utilization", "averageUtilization": 70]]]],
                ],
                "status": [
                    "currentReplicas": 3, "desiredReplicas": 4,
                    "currentMetrics": [["type": "Resource", "resource": ["name": "cpu", "current": ["averageUtilization": 91, "averageValue": "455m"]]]],
                    "conditions": [["type": "ScalingLimited", "status": "False"]],
                ],
            ])
        let model = model()
        let owner = NSObject()
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil && model.metrics.availability == .served }
        model.metrics.wantDetail([.node("fake-node-1"), .hpa(namespace: "shop", name: "web")], for: owner)
        try await until(5, "the node's") { model.metrics.reading(.node("fake-node-1"))?.sample?.nodes["fake-node-1"] != nil }
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/metrics.k8s.io/v1beta1/nodes/fake-node-1" })
        XCTAssertEqual(model.metrics.ring.points(.node("fake-node-1")).last?.usage.cpu, 1)
        XCTAssertTrue(model.metrics.ring.holds(.node("fake-node-1"), .detail))
        try await until(5, "the HPA's") { model.metrics.reading(.hpa(namespace: "shop", name: "web"))?.sample?.hpa != nil }
        let hpa = try XCTUnwrap(model.metrics.reading(.hpa(namespace: "shop", name: "web"))?.sample?.hpa)
        XCTAssertEqual(
            hpa, KubeHPAStatus(name: "web", current: 3, desired: 4, min: 2, max: 6, scalingLimited: false, metrics: [.init(name: "cpu", current: "91%", target: "70%")]))
        XCTAssertTrue(api.requests.contains { $0.path == "/apis/autoscaling/v2/namespaces/shop/horizontalpodautoscalers/web" })
        model.metrics.wantDetail([], for: owner)
        try await until(5, "stopped") { !model.metrics.isPolling }
        XCTAssertNil(model.metrics.reading(.node("fake-node-1")), "the reading goes with the want")
        XCTAssertTrue(model.metrics.ring.holds(.node("fake-node-1"), .detail), "its samples stay their hour")
    }

    func testADetailsTargetsAreCappedAtThreeAContext() async throws {
        let model = model()
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil && model.metrics.availability == .served }
        let owners = (0..<4).map { _ in NSObject() }
        let pods = ["web-1", "worker-1", "pending-1", "web-2"]
        api.addPod("web-2", namespace: "shop")
        api.setPodMetrics("web-2", namespace: "shop", [("app", "5m", "8Mi")])
        for (owner, pod) in zip(owners, pods) { model.metrics.wantDetail([.pod(namespace: "shop", name: pod)], for: owner) }
        XCTAssertEqual(model.metrics.details.map(\.target), pods.dropFirst().map { .pod(namespace: "shop", name: $0) }, "a fourth replaces the oldest")
        XCTAssertEqual(model.metrics.targets.count, KubeMetricsMonitor.maxDetailTargets)
        try await until(5, "the three read") {
            Set(self.metricsRequests.map(\.path)).isSuperset(of: pods.dropFirst().map { "/apis/metrics.k8s.io/v1beta1/namespaces/shop/pods/\($0)" })
        }
        XCTAssertFalse(metricsRequests.contains { $0.path.hasSuffix("/pods/web-1") }, "the oldest isn't read")
        model.metrics.wantDetail([], for: owners[3])
        XCTAssertEqual(model.metrics.details.map(\.target).first, .pod(namespace: "shop", name: "web-1"), "one gone, the oldest read again")
        for owner in owners { model.metrics.wantDetail([], for: owner) }
        XCTAssertEqual(model.metrics.targets, [])
    }

    func testARefusedMetricsReadIsSaidOnceAndNotAskedAgain() async throws {
        api.forbidden = ["pods.metrics.k8s.io"]
        let model = model()
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "pods") { model.rows.count == 3 && model.discovery != nil }
        page.visible = true
        let sentence = "metrics-server answered 403: you can't list pods.metrics.k8s.io in shop."
        try await until(5, "refused") { model.metrics.reading(.pods)?.refused != nil }
        XCTAssertEqual(model.metrics.reading(.pods)?.refused, sentence)
        XCTAssertEqual(page.metricsNote, sentence, "said in its own words")
        XCTAssertEqual(page.usage(.cpu, of: try XCTUnwrap(page.rows.first)), .dash(sentence))
        XCTAssertEqual(model.listState, .live, "the list is fine")
        XCTAssertFalse(model.metrics.isPolling)
        let asked = metricsRequests.count
        XCTAssertEqual(asked, 1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(metricsRequests.count, asked, "not asked every interval")
        page.visible = false
        page.visible = true
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(metricsRequests.count, asked, "nor by showing the page again")
        XCTAssertEqual(model.metrics.reading(.pods)?.refused, sentence, "still said")
        XCTAssertTrue(page.metricsNoteIsRefusal, "Try Again beside it")
        // Leaving the page (its last viewer gone: another page, the window
        // occluded) and coming back: still refused, not asked again.
        model.hide()
        XCTAssertFalse(model.isShown)
        model.show()
        try await until(5, "listed again") { model.listState == .live && model.metrics.availability == .served }
        try await until(5, "said again") { model.metrics.reading(.pods)?.refused == sentence }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(metricsRequests.count, asked, "nor by leaving the page and coming back")

        // A pod's own read: its own sentence.
        page.open(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1"), from: .list)
        try await until(5, "the pod's refused") { model.metrics.reading(.pod(namespace: "shop", name: "web-1"))?.refused != nil }
        XCTAssertEqual(
            page.podUsageProblem(of: KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1")),
            "metrics-server answered 403: you can't get pods.metrics.k8s.io in shop.")
        XCTAssertEqual(
            KubeMetricsTarget.pods(.all, labels: nil).refusal, "metrics-server answered 403: you can't list pods.metrics.k8s.io across the cluster.")
        XCTAssertEqual(KubeMetricsTarget.node("n").refusal, "metrics-server answered 403: you can't get nodes.metrics.k8s.io.")

        // The credentials change (a sign-in, `retry`): asked again.
        api.forbidden = []
        model.retry()
        try await until(5, "read after the retry") { model.metrics.reading(.pods)?.sample != nil && model.metrics.reading(.pods)?.refused == nil }
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
        XCTAssertTrue(model.metrics.ring.isEmpty, "every sample of the context dropped")

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
