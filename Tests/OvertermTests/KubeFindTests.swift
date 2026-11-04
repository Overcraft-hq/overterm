import Foundation
import XCTest

@testable import Overterm

/// Finding and copying on the Kubernetes page: `field:` and `label:` sent
/// to the server, Copy as kubectl and its quoting, the list as CSV, the
/// Deployments Status read off their cells. Against `FakeKubeAPI` on a
/// socket of the test's own; nothing reads ~/.kube.
@MainActor
final class KubeFindTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private var copied: [String] = []
    private var saved: [(String, String)] = []

    override func setUpWithError() throws {
        socket = "/tmp/otkf-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addPod("web-1", namespace: "shop", labels: ["app": "web"])
        var done = FakeKubeAPI.Pod()
        done.status = "Completed"
        done.phase = "Succeeded"
        done.ready = 0
        api.addPod("migrate-1", namespace: "shop", done, labels: ["app": "web"])
        api.addPod("db-0", namespace: "shop", labels: ["app": "db"])
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
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
        let socket = self.socket!
        model.connectOverride = { context in KubeSocketConnection(socket: socket, context: context.name) }
        model.statusOverride = { _ in .open }
        return model
    }

    private func page(_ model: KubernetesModel) -> KubernetesPageModel {
        let page = KubernetesPageModel(model: model)
        page.selectorDelay = .milliseconds(20)
        page.actions = KubernetesActions(
            run: { _ in }, settings: {}, copy: { [weak self] in self?.copied.append($0) }, copySecret: { _ in },
            save: { [weak self] in self?.saved.append(($0, $1)) })
        return page
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Selectors

    func testFieldSelectorWords() {
        func read(_ text: String) -> String? { KubeFieldSelector.read(text).selector }
        XCTAssertNil(read("web status:running"))
        XCTAssertEqual(read("field:status.phase=Running"), "status.phase=Running")
        XCTAssertEqual(read("f:spec.nodeName==fake-node-1"), "spec.nodeName=fake-node-1")
        XCTAssertEqual(read("field:status.phase!=Running"), "status.phase!=Running")
        XCTAssertEqual(read("-field:status.phase=Running"), "status.phase!=Running")
        XCTAssertEqual(read("-field:status.phase!=Running"), "status.phase=Running")
        XCTAssertEqual(read("field:status.phase=Running,spec.nodeName=n1 field:metadata.name=web-1"), "status.phase=Running,spec.nodeName=n1,metadata.name=web-1")
        XCTAssertEqual(read("field:Status.Phase=Running"), "Status.Phase=Running", "as typed: the server's names are case-sensitive")
        XCTAssertEqual(read("field:status.podIP=10.0.0.10"), "status.podIP=10.0.0.10")
        XCTAssertEqual(read("field:spec.nodeName="), "spec.nodeName=", "an empty value is one")
        for refused in ["field:spec", "field:=x", "field:a=b=c", "field:a..b=c", "field:a=b,", "-field:a=1,b=2", "field:a=b!c", "field:a=b\\,c"] {
            XCTAssertEqual(KubeFieldSelector.read(refused), KubeLabelSelector.Reading(selector: nil, refused: [refused]), refused)
        }
    }

    func testBothSelectorsReadFromOneFilter() {
        let reading = KubeListSelectors.read("web label:app=web field:status.phase=Running label:=x status:running")
        XCTAssertEqual(reading.selectors, KubeListSelectors(label: "app=web", field: "status.phase=Running"))
        XCTAssertEqual(reading.refused, ["label:=x"])
        XCTAssertEqual(reading.selectors.said, "label app=web, field status.phase=Running")
        XCTAssertEqual(reading.selectors.options, KubeListOptions(labelSelector: "app=web", fieldSelector: "status.phase=Running"))
        XCTAssertNil(KubeListSelectors.read("web").selectors.said)
        XCTAssertTrue(KubeFilterKey.field.isServers && KubeFilterKey.label.isServers && !KubeFilterKey.status.isServers)
    }

    func testTheSelectorsInTheURL() {
        XCTAssertEqual(
            KubePath.query("/api/v1/namespaces/shop/pods", [("labelSelector", "app=web"), ("fieldSelector", "status.phase!=Running,spec.nodeName=n1")]),
            "/api/v1/namespaces/shop/pods?labelSelector=app%3Dweb&fieldSelector=status.phase%21%3DRunning%2Cspec.nodeName%3Dn1")
    }

    /// `field:` narrows the list on the server — the list and the watch
    /// after it — with `label:` beside it and the text on what came.
    func testFieldWordsGoToTheServer() async throws {
        let model = model()
        let page = page(model)
        model.show()
        page.visible = true
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 3 }

        page.filter = "field:status.phase=Running"
        try await until(5, "running") { model.rows.sorted.map(\.id.name) == ["db-0", "web-1"] }
        XCTAssertEqual(model.fieldSelector, "status.phase=Running")
        XCTAssertNil(model.labelSelector)
        XCTAssertTrue(
            api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && !$0.isWatch && $0.query["fieldSelector"] == "status.phase=Running" },
            "\(api.requests)")
        XCTAssertTrue(api.requests.contains { $0.isWatch && $0.query["fieldSelector"] == "status.phase=Running" }, "the watch is asked with it too")
        XCTAssertEqual(page.rows.map(\.id), ["shop/db-0", "shop/web-1"], "not filtered again on the rows")

        // The watch keeps to it: a pod that doesn't match never comes.
        var pending = FakeKubeAPI.Pod()
        pending.phase = "Pending"
        pending.status = "Pending"
        api.addPod("cache-0", namespace: "shop", pending)
        api.addPod("cache-1", namespace: "shop")
        try await until(5, "the running one by the watch") { model.rows.sorted.map(\.id.name) == ["cache-1", "db-0", "web-1"] }

        // Both, and text on what came.
        page.filter = "label:app=web field:status.phase=Running web"
        try await until(5, "both") { model.rows.sorted.map(\.id.name) == ["web-1"] }
        XCTAssertEqual(model.selectors, KubeListSelectors(label: "app=web", field: "status.phase=Running"))
        XCTAssertTrue(page.listIsOurs)
        XCTAssertEqual(page.rows.map(\.id), ["shop/web-1"])

        // Refused: nothing asked with it, and said.
        page.filter = "field:spec"
        XCTAssertEqual(page.selectorReading.refused, ["field:spec"])
        try await until(5, "every pod") { model.rows.count == 5 }
        XCTAssertTrue(model.selectors.isEmpty)

        // Hidden, the page gives the list back.
        page.filter = "field:status.phase=Running"
        page.applySelector()
        XCTAssertEqual(model.fieldSelector, "status.phase=Running")
        page.visible = false
        XCTAssertTrue(model.selectors.isEmpty)
    }

    // MARK: Copy as kubectl

    private static func kind(_ group: String, _ resource: String, _ kind: String, namespaced: Bool = true, short: [String] = []) -> KubeResourceKind {
        KubeResourceKind(
            group: group, version: "v1", resource: resource, kind: kind, singular: kind.lowercased(), namespaced: namespaced,
            verbs: ["get", "list", "watch"], shortNames: short)
    }

    private static let deployments = kind("apps", "deployments", "Deployment", short: ["deploy"])
    private static let coreEvents = kind("", "events", "Event", short: ["ev"])
    private static let newEvents = kind("events.k8s.io", "events", "Event", short: ["ev"])
    private static let widgets = kind("example.com", "widgets", "Widget", short: ["wd"])
    private static let cronjobs = kind("batch", "cronjobs", "CronJob", short: ["cj"])
    private static let jobs = kind("batch", "jobs", "Job")
    private static let nodes = kind("", "nodes", "Node", namespaced: false, short: ["no"])
    private static let secrets = kind("", "secrets", "Secret")
    private static let discovery = KubeDiscovery(kinds: [.pods, deployments, coreEvents, newEvents, widgets, cronjobs, jobs, nodes, secrets])

    func testTheKindAsKubectlIsToldIt() {
        let d = Self.discovery
        XCTAssertEqual(KubectlLine.resource(.pods, in: d), "po")
        XCTAssertEqual(KubectlLine.resource(Self.deployments, in: d), "deploy")
        XCTAssertEqual(KubectlLine.resource(Self.jobs, in: d), "jobs")
        XCTAssertEqual(KubectlLine.resource(Self.cronjobs, in: d), "cj")
        XCTAssertEqual(KubectlLine.resource(Self.coreEvents, in: d), "ev", "the core group wins kubectl's lookup")
        XCTAssertEqual(KubectlLine.resource(Self.newEvents, in: d), "events.events.k8s.io", "its names are the core's too")
        XCTAssertEqual(KubectlLine.resource(Self.widgets, in: d), "widgets.example.com", "a CRD by its full name")
        XCTAssertEqual(KubectlLine.resource(Self.secrets, in: nil), "secrets")
    }

    func testListCommands() {
        XCTAssertEqual(
            KubectlLine.list(context: "fake-dev", kind: Self.deployments, scope: .namespace("shop"), discovery: Self.discovery),
            "kubectl --context fake-dev get deploy -n shop")
        XCTAssertEqual(
            KubectlLine.list(
                context: "fake-dev", kind: .pods, scope: .all, selectors: KubeListSelectors(label: "app=web,tier!=db", field: "status.phase=Running"),
                wide: true, discovery: Self.discovery),
            "kubectl --context fake-dev get po -A -l 'app=web,tier!=db' --field-selector status.phase=Running -o wide")
        XCTAssertEqual(
            KubectlLine.list(context: "fake-dev", kind: Self.nodes, scope: .namespace("shop"), discovery: Self.discovery),
            "kubectl --context fake-dev get no", "a cluster-wide kind has no namespace")
        XCTAssertEqual(
            KubectlLine.list(context: "fake-dev", kind: .pods, scope: .namespace("shop"), selectors: KubeListSelectors(label: "!app")),
            "kubectl --context fake-dev get po -n shop -l '!app'", "! is history in zsh: quoted")
    }

    func testObjectAndEventCommands() {
        let web = KubeObjectRef(context: "fake-dev", kind: Self.deployments, namespace: "shop", name: "web")
        XCTAssertEqual(KubectlLine.object(web, discovery: Self.discovery), "kubectl --context fake-dev -n shop get deploy web -o yaml")
        XCTAssertEqual(KubectlLine.events(for: web, discovery: Self.discovery), "kubectl --context fake-dev -n shop events --for deploy/web")
        let node = KubeObjectRef(context: "fake-dev", kind: Self.nodes, namespace: "shop", name: "fake-node-1")
        XCTAssertEqual(KubectlLine.object(node), "kubectl --context fake-dev get no fake-node-1 -o yaml")
        XCTAssertEqual(KubectlLine.events(for: node), "kubectl --context fake-dev events -A --for no/fake-node-1", "-A is events' own flag: after it")
        let widget = KubeObjectRef(context: "kind-fake", kind: Self.widgets, namespace: "shop", name: "blue-1")
        XCTAssertEqual(KubectlLine.object(widget), "kubectl --context kind-fake -n shop get widgets.example.com blue-1 -o yaml")
        // A Secret: described — its keys' sizes — never -o yaml, which would print every value.
        let secret = KubeObjectRef(context: "fake-prod", kind: Self.secrets, namespace: "payments", name: "web-db")
        XCTAssertEqual(KubectlLine.object(secret), "kubectl --context fake-prod -n payments describe secrets web-db")
        XCTAssertFalse(KubectlLine.object(secret).contains("yaml") || KubectlLine.object(secret).contains("json"))
    }

    func testQuotingForZsh() {
        let q = KubectlLine.quoted
        for bare in ["fake-dev", "shop", "app=web", "app.kubernetes.io/name=api", "arn:aws:eks:eu-west-1:123456789012:cluster/acme-prod", "a@b", "a+b,c"] {
            XCTAssertEqual(q(bare), bare, bare)
        }
        XCTAssertEqual(q(""), "''")
        XCTAssertEqual(q("app!=web"), "'app!=web'")
        XCTAssertEqual(q("=cmd"), "'=cmd'", "a leading = is zsh's path expansion")
        XCTAssertEqual(q("~acme"), "'~acme'")
        XCTAssertEqual(q("a b"), "'a b'")
        XCTAssertEqual(q("*"), "'*'")
        XCTAssertEqual(q("$HOME"), "'$HOME'")
        XCTAssertEqual(q("a;rm -rf x"), "'a;rm -rf x'")
        XCTAssertEqual(q("it's"), "'it'\\''s'")
        XCTAssertEqual(q("`id`"), "'`id`'")
        XCTAssertEqual(q("{a,b}"), "'{a,b}'")
        XCTAssertEqual(q("a#b"), "'a#b'")
        XCTAssertEqual(q("-n"), "'-n'")
    }

    /// `k` on the page: the selected rows' commands, else the list's with
    /// its namespace and selectors; the detail's on its Events tab.
    func testCopyAsKubectlOnThePage() async throws {
        let model = model()
        let page = page(model)
        model.show()
        page.visible = true
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 3 }

        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(copied.last, "kubectl --context fake-dev get po -n shop")
        page.filter = "label:app=web field:status.phase=Running web"
        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(
            copied.last, "kubectl --context fake-dev get po -n shop -l app=web --field-selector status.phase=Running", "the text word has no kubectl twin")
        page.filter = ""
        page.selection = ["shop/web-1", "shop/db-0"]
        XCTAssertTrue(page.press("k"))
        XCTAssertEqual(
            copied.last, "kubectl --context fake-dev -n shop get po db-0 -o yaml\nkubectl --context fake-dev -n shop get po web-1 -o yaml", "in the list's order")
        let verbs = page.verbs(for: ["shop/web-1"])
        XCTAssertEqual(
            verbs.map(\.title),
            [
                "Copy Name", "Copy Namespace/Name", "Copy as kubectl", "Copy List as kubectl", "Copy Row as TSV", "Copy Row as CSV", "Export List as CSV…",
                "Terminal in This Context", "Shell in a Tab", "Attach in a Tab", "Follow Logs in a Tab",
            ])
        verbs.first { $0.title == "Copy as kubectl" }?.perform()
        XCTAssertEqual(copied.last, "kubectl --context fake-dev -n shop get po web-1 -o yaml")

        page.open(KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1"), from: .list)
        page.copyDetailKubectl()
        XCTAssertEqual(copied.last, "kubectl --context fake-dev -n shop get po web-1 -o yaml")
        page.showTab(.events)
        page.copyDetailKubectl()
        XCTAssertEqual(copied.last, "kubectl --context fake-dev -n shop events --for po/web-1")
        page.closeDetail()
    }

    // MARK: CSV

    func testCSVEscaping() {
        let csv = KubeListExport.csv(
            columns: ["Name", "Message"],
            rows: [
                ["web", "plain"], ["a,b", "say \"hi\""], ["multi", "one\ntwo"], ["=HYPERLINK(\"x\")", "+1"], ["@cmd", "-2"], ["-", "-rf"], ["tab", "\tx"],
            ])
        XCTAssertEqual(
            csv,
            """
            Name,Message
            web,plain
            "a,b","say ""hi\"\""
            multi,"one
            two"
            "'=HYPERLINK(""x"")",'+1
            '@cmd,-2
            -,'-rf
            tab,'\tx

            """)
        XCTAssertEqual(KubeListExport.inert("-1.5"), "-1.5", "a negative number stays one")
        XCTAssertEqual(KubeListExport.inert(""), "")
    }

    func testCSVFileNames() {
        XCTAssertEqual(KubeListExport.fileName(context: "fake-dev", kind: Self.deployments, scope: .namespace("shop")), "fake-dev-shop-deployments.csv")
        XCTAssertEqual(KubeListExport.fileName(context: "fake-dev", kind: .pods, scope: .all), "fake-dev-all-pods.csv")
        XCTAssertEqual(KubeListExport.fileName(context: "fake-dev", kind: Self.nodes, scope: .namespace("shop")), "fake-dev-nodes.csv")
        XCTAssertEqual(
            KubeListExport.fileName(context: "arn:aws:eks:eu-west-1:1:cluster/acme", kind: .pods, scope: .namespace("shop")),
            "arn_aws_eks_eu-west-1_1_cluster_acme-shop-pods.csv")
    }

    /// The list as the page shows it: its columns (the wide ones only when
    /// wide), the rows its filter lets through, a failing pod's reason.
    func testTheListAsCSV() async throws {
        var crashing = FakeKubeAPI.Pod()
        crashing.status = "CrashLoopBackOff"
        crashing.ready = 0
        api.addPod("api-1", namespace: "shop", crashing)
        let model = model()
        let page = page(model)
        model.show()
        page.visible = true
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 4 }
        page.filter = "-db"
        let lines = page.csv().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Name,Ready,Status,Restarts,Age")
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: ",").first.map(String.init) ?? "" }, ["api-1", "migrate-1", "web-1"])
        XCTAssertTrue(lines.contains { $0.hasPrefix("api-1,0/1,CrashLoopBackOff,") }, "\(lines)")
        page.wide = true
        XCTAssertTrue(page.csv().hasPrefix("Name,Ready,Status,Restarts,Age,IP,Node"), page.csv())
        XCTAssertEqual(page.csvFileName, "fake-dev-shop-pods.csv")
        XCTAssertTrue(page.canExport)
        page.exportCSV()
        XCTAssertEqual(saved.map(\.0), ["fake-dev-shop-pods.csv"])
        XCTAssertEqual(saved.first?.1, page.csv())
    }

    /// Copy Rows as TSV or CSV: the right-clicked rows, else the selected
    /// ones, else every row the filter shows — the shown columns first.
    func testCopyRowsAsTSVAndCSV() async throws {
        let model = model()
        let page = page(model)
        model.show()
        page.visible = true
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 3 }
        page.filter = "-db"
        let visible = try XCTUnwrap(page.copyRows(.tsv)).split(separator: "\n").map(String.init)
        XCTAssertEqual(visible.first, "Name\tReady\tStatus\tRestarts\tAge")
        XCTAssertEqual(visible.dropFirst().map { String($0.prefix { $0 != "\t" }) }, ["migrate-1", "web-1"], "the visible rows, no selection")
        XCTAssertEqual(copied.last, visible.joined(separator: "\n"))
        page.selection = ["shop/web-1"]
        let selected = try XCTUnwrap(page.copyRows(.csv)).split(separator: "\n").map(String.init)
        XCTAssertEqual(selected.first, "Name,Ready,Status,Restarts,Age")
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected[1].hasPrefix("web-1,"), "\(selected)")
        page.selection = ["shop/db-0"]
        XCTAssertEqual(page.copyRows(.csv)?.split(separator: "\n").count, 3, "a selection the filter hides: the visible rows")
        page.verbs(for: ["shop/migrate-1"]).first { $0.title == "Copy Row as TSV" }?.perform()
        XCTAssertEqual(copied.last?.split(separator: "\n").last.map { String($0.prefix { $0 != "\t" }) }, "migrate-1", "the right-clicked row")
        XCTAssertEqual(KubeListExport.text(.tsv, columns: ["Name"], rows: [["=cmd"], ["a\tb"]]), "Name\n'=cmd\na b")
    }

    // MARK: Deployments' Status

    func testADeploymentsStatusOffItsCells() {
        let columns = ["Name", "Ready", "Up-to-date", "Available", "Age"].map { KubeColumn(name: $0) }
        func hint(_ ready: String, _ updated: Int, _ available: Int) -> KubeDeploymentHint? {
            KubeDeploymentHint(
                row: KubeRow(id: KubeRowID(namespace: "shop", name: "web"), cells: [.text("web"), .text(ready), .integer(updated), .integer(available), .text("1d")]),
                columns: columns)
        }
        XCTAssertEqual(hint("3/3", 3, 3), .available)
        XCTAssertEqual(hint("0/0", 0, 0), .scaledToZero)
        XCTAssertEqual(hint("2/3", 1, 2), .rollingOut(updated: 1, desired: 3))
        XCTAssertEqual(hint("0/1", 1, 0), .unavailable(available: 0, desired: 1))
        XCTAssertEqual(hint("2/3", 3, 3), .notReady(ready: 2, desired: 3))
        XCTAssertEqual(hint("0/1", 1, 0)?.text, "Unavailable 0/1")
        XCTAssertTrue(hint("0/1", 1, 0)?.isBad == true)
        XCTAssertNil(hint("three", 3, 3))
        XCTAssertTrue(KubeDeploymentHint.applies(to: Self.deployments, columns: columns))
        XCTAssertFalse(KubeDeploymentHint.applies(to: Self.deployments, columns: columns + [KubeColumn(name: "Status")]), "the server's own wins")
        XCTAssertFalse(KubeDeploymentHint.applies(to: .pods, columns: columns))
    }

    func testTheDeploymentsListHasAStatusColumn() async throws {
        api.add("deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1])
        api.add("deployments.apps", "worker", namespace: "shop", values: ["Ready": "0/1", "Up-to-date": 1, "Available": 0])
        let model = model()
        let page = page(model)
        model.show()
        page.visible = true
        defer { model.hide() }
        try await until(5, "discovery") { model.catalog.kind(fullName: "deployments.apps") != nil }
        page.showKind(try XCTUnwrap(model.catalog.kind(fullName: "deployments.apps")))
        try await until(5, "listed") { model.rows.count == 2 && !model.rows.columns.isEmpty }
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Up-to-date", "Available", "Status", "Age"])
        XCTAssertEqual(page.rows.map { $0.hint?.text }, ["Available", "Unavailable 0/1"])
        page.filter = "status:unavailable"
        XCTAssertEqual(page.rows.map(\.id), ["shop/worker"])
        page.filter = ""
        page.sort = ResourceSort(column: KubeDeploymentHint.column, ascending: false)
        XCTAssertEqual(page.rows.map(\.id), ["shop/worker", "shop/web"])
        page.sort = nil
        XCTAssertTrue(page.csv().hasPrefix("Name,Ready,Up-to-date,Available,Status,Age\nweb,1/1,1,1,Available,"), page.csv())
        page.selection = ["shop/web"]
        XCTAssertEqual(page.copyKubectl(), "kubectl --context fake-dev -n shop get deploy web -o yaml")
    }
}
