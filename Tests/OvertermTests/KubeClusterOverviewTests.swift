import Foundation
import XCTest

@testable import Overterm

/// The Overview section (stage 2d): workload counts and pods by phase
/// (the server's phases, by field selector), what fails first, the
/// Applications grouping by the recommended labels, the last hour's
/// Warning events — read only while the section shows, every follow ended
/// when it hides. Against `FakeKubeAPI` on a socket of the test's own.
@MainActor
final class KubeClusterOverviewTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUp() async throws {
        socket = "/tmp/otkco-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop", labels: ["app": "web"])
        api.addPod("web-2", namespace: "shop", labels: ["app": "web"])
        api.addPod("worker-1", namespace: "shop", FakeKubeAPI.Pod(status: "CrashLoopBackOff", phase: "Running", ready: 0, restarts: 4))
        api.addPod("migrate-1", namespace: "shop", FakeKubeAPI.Pod(status: "Completed", phase: "Succeeded", ready: 0))
        api.addPod("pull-1", namespace: "shop", FakeKubeAPI.Pod(status: "ImagePullBackOff", phase: "Pending", ready: 0))
        let shopLabels = [KubeApplications.nameLabel: "web", KubeApplications.instanceLabel: "web-prod", KubeApplications.partOfLabel: "shop"]
        api.add("deployments.apps", "web", namespace: "shop", values: ["Ready": "2/2", "Up-to-date": 2, "Available": 2], labels: shopLabels)
        api.add(
            "deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0],
            labels: [KubeApplications.nameLabel: "worker", KubeApplications.partOfLabel: "shop", KubeApplications.componentLabel: "queue"])
        api.add("deployments.apps", "legacy", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1])
        api.add(
            "statefulsets.apps", "web-db", namespace: "shop", values: ["Ready": "1/1"],
            labels: [KubeApplications.nameLabel: "web", KubeApplications.instanceLabel: "web-prod", KubeApplications.partOfLabel: "shop", KubeApplications.componentLabel: "database"])
        api.add("daemonsets.apps", "agent", namespace: "shop", values: ["Desired": 3, "Current": 3, "Ready": 2, "Up-to-date": 3, "Available": 2])
        api.add("jobs.batch", "migrate", namespace: "shop", values: ["Status": "Complete", "Completions": "1/1"])
        api.add("jobs.batch", "report", namespace: "shop", values: ["Status": "Failed", "Completions": "0/1"])
        api.add("nodes", "fake-node-1", values: ["Status": "Ready", "Roles": "control-plane"])
        api.add("nodes", "fake-node-2", values: ["Status": "NotReady,SchedulingDisabled", "Roles": "<none>"])
        api.addEvent(about: "pods", "worker-1", namespace: "shop", type: "Warning", reason: "BackOff", message: "Back-off restarting failed container", count: 9)
        api.addEvent(about: "pods", "web-1", namespace: "shop", reason: "Scheduled", message: "Assigned shop/web-1")
        api.addEvent(about: "pods", "web-2", namespace: "shop", type: "Warning", reason: "Unhealthy", message: "old", last: Date().addingTimeInterval(-7200))
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no subresource")
            api.stop()
        }
    }

    private func model() -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let context = KubeContext(
            name: "fake-dev", cluster: "fake-dev", server: "http://127.0.0.1:1", namespace: "shop", user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: .remote, settings: KubeContextSettings())
        let list = KubeContextList(contexts: [context], current: "fake-dev")
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

    // MARK: Pure

    private static func row(_ name: String, namespace: String? = "shop", labels: [String: String] = [:], cells: [KubeCell] = []) -> KubeRow {
        KubeRow(id: KubeRowID(namespace: namespace, name: name), cells: [.text(name)] + cells, labels: labels)
    }

    func testApplicationsAreGroupedByTheRecommendedLabels() {
        let deploy = KubeResourceKind(group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "", namespaced: true, verbs: [])
        let sts = KubeResourceKind(group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", singular: "", namespaced: true, verbs: [])
        let n = KubeApplications.nameLabel
        let i = KubeApplications.instanceLabel
        let p = KubeApplications.partOfLabel
        let systems = KubeApplications.group([
            (deploy, Self.row("web", labels: [n: "web", i: "web-prod", p: "shop"]), true),
            (sts, Self.row("web-db", labels: [n: "web", i: "web-prod", p: "shop"]), false),
            (deploy, Self.row("web-canary", labels: [n: "web", i: "web-canary", p: "shop"]), true),
            (deploy, Self.row("worker", labels: [n: "worker", p: "shop"]), true),
            (deploy, Self.row("redis", labels: [n: "redis"]), true),
            (deploy, Self.row("redis", namespace: "other", labels: [n: "redis"]), true),
            (deploy, Self.row("legacy"), true),
        ])
        XCTAssertEqual(systems.map(\.partOf), ["shop", nil], "systems by part-of, those of none last")
        let shop = systems[0].applications
        XCTAssertEqual(shop.map(\.name), ["web", "web", "worker"])
        XCTAssertEqual(shop.map(\.instance), ["web-canary", "web-prod", nil], "two installs of web: two applications")
        XCTAssertEqual(shop[1].members.map(\.id.name), ["web", "web-db"], "an instance's workloads together, by kind")
        XCTAssertEqual(shop[1].notReady, 1)
        XCTAssertEqual(systems[1].applications.map { "\($0.namespace ?? "")/\($0.name)" }, ["other/redis", "shop/redis"], "one a namespace")
        XCTAssertFalse(systems.flatMap(\.applications).flatMap(\.members).contains { $0.id.name == "legacy" }, "no label: no application")
    }

    func testAWorkloadsRowSaysWhetherItIsReady() {
        let ready = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Ready")]
        XCTAssertEqual(KubeWorkloadState.ready(Self.row("a", cells: [.text("2/3")]), columns: ready, kind: "deployments"), false)
        XCTAssertEqual(KubeWorkloadState.ready(Self.row("a", cells: [.text("3/3")]), columns: ready, kind: "statefulsets"), true)
        XCTAssertEqual(KubeWorkloadState.ready(Self.row("a", cells: [.text("0/0")]), columns: ready, kind: "deployments"), true, "scaled to nothing")
        let daemons = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Desired"), KubeColumn(name: "Ready")]
        XCTAssertEqual(KubeWorkloadState.ready(Self.row("a", cells: [.integer(3), .integer(2)]), columns: daemons, kind: "daemonsets"), false)
        let jobs = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Status")]
        XCTAssertEqual(KubeWorkloadState.ready(Self.row("a", cells: [.text("Failed")]), columns: jobs, kind: "jobs"), false)
        XCTAssertEqual(KubeWorkloadState.ready(Self.row("a", cells: [.text("Running")]), columns: jobs, kind: "jobs"), true)
        XCTAssertNil(KubeWorkloadState.ready(Self.row("a"), columns: ready, kind: "services"))
    }

    // MARK: Read while shown

    func testTheOverviewCountsWhatFailsAndReadsOnlyWhileShown() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil && model.rows.count == 5 }
        let before = api.openWatches
        XCTAssertEqual(page.clusterOverview.state, .idle, "not shown: nothing read")

        XCTAssertTrue(page.press("1"))
        XCTAssertEqual(page.section, .overview)
        XCTAssertEqual(page.title, "Overview")
        let session = page.clusterOverview
        try await until(5, "live") { session.state == .live && session.overview.phases.count == 5 && session.overview.nodes == 2 }
        let overview = session.overview
        XCTAssertEqual(overview.phases, ["Running": 3, "Pending": 1, "Succeeded": 1, "Failed": 0, "Unknown": 0], "the server's phases")
        XCTAssertEqual(overview.failingPods.map(\.id.name), ["pull-1", "worker-1"])
        XCTAssertEqual(overview.workloads.map(\.title), ["Deployments", "StatefulSets", "DaemonSets", "Jobs"])
        XCTAssertEqual(overview.workloads.map(\.total), [3, 1, 1, 2])
        XCTAssertEqual(overview.workloads.flatMap(\.notReady).map(\.name), ["worker", "agent", "report"])
        XCTAssertEqual(overview.notReadyNodes, ["fake-node-2"])
        XCTAssertEqual(overview.warnings.map(\.reason), ["BackOff"], "Warnings only, the last hour's")
        XCTAssertEqual(overview.warnings.first?.object, "pod/worker-1")
        XCTAssertEqual(overview.problems, 6)
        XCTAssertEqual(overview.systems.map(\.partOf), ["shop"])
        XCTAssertEqual(overview.systems.first?.applications.map(\.name), ["web", "worker"])
        XCTAssertEqual(overview.systems.first?.applications.first?.members.map(\.id.name), ["web", "web-db"])
        XCTAssertEqual(overview.unlabelled, 4, "legacy, agent and the Jobs")
        for phase in KubeClusterOverview.phases {
            XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["fieldSelector"] == "status.phase=\(phase)" }, phase)
        }
        XCTAssertTrue(
            api.requests.contains { $0.path == "/apis/apps/v1/namespaces/shop/deployments" && $0.query["includeObject"] == "Metadata" }, "their labels")
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/events" && $0.query["fieldSelector"] == "type=Warning" })
        XCTAssertTrue(page.metricsOnScreen == .nodes, "the cluster's usage is the nodes'")
        try await until(5, "cluster usage") { model.metrics.reading(.nodes) != nil }

        // Kept live: a pod that starts failing, one that moves on.
        api.updatePod("pull-1", namespace: "shop") {
            $0.status = "Running"
            $0.phase = "Running"
            $0.ready = 1
        }
        try await until(5, "moved to Running") { session.overview.phases["Running"] == 4 && session.overview.phases["Pending"] == 0 }
        XCTAssertEqual(session.overview.failingPods.map(\.id.name), ["worker-1"])

        // The list's verbs are no keys here; the page's are.
        XCTAssertFalse(page.press("r"), "a verb on a kind not on screen")
        XCTAssertTrue(page.press("?"))
        _ = page.press("x")
        XCTAssertTrue(page.cheatSheet, "only Esc or ? closes the keys")
        XCTAssertTrue(page.press("\u{1B}"))

        // Another section: every follow ends, nothing kept.
        XCTAssertTrue(page.press("2"))
        try await until(5, "ended") { self.api.openWatches <= before }
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.overview, KubeClusterOverview())

        // Back, then the page hidden: ended again.
        XCTAssertTrue(page.press("1"))
        try await until(5, "live again") { session.state == .live }
        page.visible = false
        try await until(5, "hidden") { self.api.openWatches <= before && session.state == .idle }
    }

    func testAPartRefusedIsSaidAndTheRestStands() async throws {
        api.forbidden = ["events"]
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil }
        page.showSection(.overview)
        let session = page.clusterOverview
        try await until(5, "live") { session.state == .live && session.overview.nodes == 2 }
        XCTAssertTrue(session.problems[.warnings]?.hasPrefix("Not allowed") == true, "\(session.problems)")
        XCTAssertEqual(session.overview.pods, 5)
    }

    func testAnObjectTheOverviewNamesOpensItsDetail() async throws {
        let model = model()
        let page = KubernetesPageModel(model: model)
        page.visible = true
        model.show()
        defer { model.hide() }
        try await until(5, "discovery") { model.discovery != nil }
        page.showSection(.overview)
        page.openFromOverview(kind: "deployments.apps", KubeRowID(namespace: "shop", name: "worker"))
        XCTAssertEqual(page.section, .workloads)
        XCTAssertEqual(model.kind.fullName, "deployments.apps")
        XCTAssertEqual(page.detail?.ref.name, "worker")
        XCTAssertEqual(page.clusterOverview.state, .idle, "off the Overview: not read")
    }
}
