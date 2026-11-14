import Foundation
import XCTest

@testable import Overterm

/// Several namespaces at once: the scope's one spelling, the merge of a
/// follow each, the cap (one watch across the cluster, filtered — refused
/// where the cluster-wide list is), the picker's ticks, what is kept per
/// context, and the page over the fake: rows of both, the Namespace
/// column, the chip's words, `:ns a,b`. Against `FakeKubeAPI` on a socket
/// of the test's own; nothing here reads ~/.kube.
@MainActor
final class KubeNamespacesTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!
    private var suite: String?

    override func setUp() async throws {
        socket = "/tmp/otkn-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        for namespace in ["shop", "payments", "default"] { api.addNamespace(namespace) }
        api.addPod("web-1", namespace: "shop")
        api.addPod("api-1", namespace: "shop")
        api.addPod("web-1", namespace: "payments")
        api.addPod("other", namespace: "default")
    }

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            api.stop()
        }
        if let suite { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private static func context(_ name: String, namespace: String? = nil) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: namespace, user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: nil), settings: KubeContextSettings())
    }

    private func model(_ contexts: [KubeContext], current: String? = nil) -> KubernetesModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: contexts, current: current)
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

    private func client() -> KubeClient {
        var client = KubeClient(KubeSocketConnection(socket: socket, context: "fake-dev"))
        client.watchTimeout = { 600 }
        client.maxBackoff = .milliseconds(200)
        return client
    }

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func row(_ namespace: String, _ name: String) -> KubeRow {
        KubeRow(id: KubeRowID(namespace: namespace, name: name), cells: [.text(name)])
    }

    private static let columns = [KubeColumn(name: "Name", format: "name")]

    // MARK: The scope

    func testAScopeHasOneSpelling() {
        XCTAssertEqual(KubeScope.of([]), .all)
        XCTAssertEqual(KubeScope.of(["shop"]), .namespace("shop"), "one is the plain namespace")
        XCTAssertEqual(KubeScope.of(["shop", "shop", ""]), .namespace("shop"))
        XCTAssertEqual(KubeScope.of(["b", "a"]), .namespaces(["a", "b"]))
        XCTAssertEqual(KubeScope.of(["b", "a"]), KubeScope.of(["a", "b"]), "order doesn't make another")
        XCTAssertEqual(Set([KubeScope.of(["a", "b"]), .of(["b", "a"])]).count, 1)

        let several = KubeScope.of(["payments", "acme-api", "shop"])
        XCTAssertEqual(several.names, ["acme-api", "payments", "shop"])
        XCTAssertEqual(several.title, "acme-api +2")
        XCTAssertEqual(KubeScope.namespace("shop").title, "shop")
        XCTAssertEqual(KubeScope.all.title, "All namespaces")
        XCTAssertEqual(several.said, "namespaces acme-api, payments, shop")
        XCTAssertTrue(several.spansNamespaces)
        XCTAssertTrue(KubeScope.all.spansNamespaces)
        XCTAssertFalse(KubeScope.namespace("shop").spansNamespaces)
        XCTAssertNil(several.namespace(for: .pods), "no one namespace in a path")
        XCTAssertTrue(several.includes("shop"))
        XCTAssertFalse(several.includes("default"))
        XCTAssertTrue(several.includes(nil), "a cluster-scoped row")

        XCTAssertEqual(several.reads(for: .pods), ["acme-api", "payments", "shop"], "a list each")
        XCTAssertEqual(several.reads(for: .namespaces), [nil], "a cluster-scoped kind: one")
        XCTAssertEqual(KubeScope.all.reads(for: .pods), [nil])
        let eleven = KubeScope.of((1...11).map { "ns-\($0)" })
        XCTAssertEqual(eleven.reads(for: .pods), [nil], "past the cap: one across the cluster")
        XCTAssertTrue(eleven.isFilteredAcross(for: .pods))
        XCTAssertFalse(KubeScope.of((1...10).map { "ns-\($0)" }).isFilteredAcross(for: .pods), "ten is the cap")

        XCTAssertEqual(several.one(preferring: "shop"), "shop")
        XCTAssertEqual(several.one(preferring: "elsewhere"), "acme-api")
        XCTAssertNil(KubeScope.all.one())

        for scope in [KubeScope.all, .namespace("shop"), several] {
            XCTAssertEqual(KubeScope(persisted: scope.persisted), scope, "kept and read back")
        }
        XCTAssertEqual(KubeScope.all.persisted, [])
    }

    func testSeveralNamespacesMergeOnceEachHasListed() {
        var merge = KubeScopeMerge(namespaces: ["payments", "shop"])
        XCTAssertEqual(merge.take(.listed(KubeTable(columns: Self.columns, rows: [Self.row("shop", "web-1")], resourceVersion: "5")), from: "shop"), [])
        XCTAssertEqual(merge.take(.changed([.added(Self.row("shop", "api-1"))], resourceVersion: "6"), from: "shop"), [], "folded in until all have listed")
        XCTAssertEqual(merge.take(.bookmark("7"), from: "shop"), [])
        let listed = merge.take(.listed(KubeTable(columns: Self.columns, rows: [Self.row("payments", "web-1")], resourceVersion: "9")), from: "payments")
        guard listed.count == 1, case .listed(let table) = listed[0] else { return XCTFail("one list: \(listed)") }
        XCTAssertEqual(table.rows.map(\.id.description), ["payments/web-1", "shop/api-1", "shop/web-1"])
        XCTAssertEqual(table.columns, Self.columns)
        XCTAssertNil(table.resourceVersion, "no one version for several")

        XCTAssertEqual(
            merge.take(.changed([.deleted(KubeRowID(namespace: "shop", name: "api-1"))], resourceVersion: "8"), from: "shop"),
            [.changed([.deleted(KubeRowID(namespace: "shop", name: "api-1"))], resourceVersion: nil)])
        XCTAssertEqual(merge.take(.bookmark("10"), from: "payments"), [], "a namespace's bookmark is its own")

        // Listed again (a 410): what changed in that namespace alone.
        var changed = Self.row("payments", "web-1")
        changed.cells = [.text("web-1 again")]
        let relisted = merge.take(
            .listed(KubeTable(columns: Self.columns, rows: [changed, Self.row("payments", "db-0")], resourceVersion: "12")), from: "payments")
        XCTAssertEqual(relisted, [.changed([.added(Self.row("payments", "db-0")), .modified(changed)], resourceVersion: nil)])
        XCTAssertEqual(merge.take(.listed(KubeTable(columns: Self.columns, rows: [Self.row("shop", "web-1")])), from: "shop"), [], "nothing differs")
        XCTAssertEqual(merge.merged.rows.map(\.id.description), ["payments/db-0", "payments/web-1", "shop/web-1"])
    }

    /// One namespace waiting for the server keeps the list retrying —
    /// whatever the others' changes — until it lists again, even with
    /// nothing changed; one stuck before its first list hides no other.
    func testANamespaceRetryingKeepsTheListRetryingUntilItListsAgain() {
        let busy = KubeAPIError(status: 503, reason: nil, message: "the server is busy")
        let shop = KubeTable(columns: Self.columns, rows: [Self.row("shop", "web-1")], resourceVersion: "5")
        let payments = KubeTable(columns: Self.columns, rows: [Self.row("payments", "web-1")], resourceVersion: "6")
        var merge = KubeScopeMerge(namespaces: ["payments", "shop"])
        XCTAssertEqual(merge.take(.listed(shop), from: "shop"), [])
        XCTAssertEqual(merge.take(.listed(payments), from: "payments").count, 1)
        XCTAssertEqual(merge.take(.retrying(busy), from: "payments"), [.retrying(busy)])
        XCTAssertEqual(
            merge.take(.changed([.added(Self.row("shop", "api-1"))], resourceVersion: "7"), from: "shop"),
            [.changed([.added(Self.row("shop", "api-1"))], resourceVersion: nil), .retrying(busy)], "shop's change, the list still not all current")
        XCTAssertEqual(merge.take(.bookmark("8"), from: "shop"), [.retrying(busy)])
        XCTAssertEqual(merge.take(.listed(payments), from: "payments"), [.changed([], resourceVersion: nil)], "back, nothing changed: live again")
        XCTAssertEqual(merge.take(.bookmark("9"), from: "payments"), [])
        // Back from a watch's 429 without listing again: its next word says so.
        XCTAssertEqual(merge.take(.retrying(busy), from: "shop"), [.retrying(busy)])
        XCTAssertEqual(merge.take(.bookmark("10"), from: "shop"), [.changed([], resourceVersion: nil)])

        var stuck = KubeScopeMerge(namespaces: ["payments", "shop"])
        XCTAssertEqual(stuck.take(.retrying(busy), from: "payments"), [.retrying(busy)], "nothing listed yet: only that")
        XCTAssertEqual(
            stuck.take(.listed(shop), from: "shop"), [.listed(KubeTable(columns: Self.columns, rows: shop.rows)), .retrying(busy)],
            "shop shown, said retrying")
        XCTAssertEqual(stuck.take(.listed(payments), from: "payments"), [.changed([.added(Self.row("payments", "web-1"))], resourceVersion: nil)])
    }

    func testANamespaceThatRefusesIsLeftOut() {
        let forbidden = KubeAPIError(status: 403, reason: "Forbidden", message: "pods is forbidden")
        let shop = KubeTable(columns: Self.columns, rows: [Self.row("shop", "web-1")], resourceVersion: "5")
        var merge = KubeScopeMerge(namespaces: ["locked", "shop"])
        XCTAssertEqual(merge.take(.listed(shop), from: "shop"), [])
        XCTAssertEqual(
            merge.take(.unlisted("locked", forbidden), from: "locked"), [.unlisted("locked", forbidden), .listed(KubeTable(columns: Self.columns, rows: shop.rows))])
        XCTAssertFalse(merge.allRefused)

        var both = KubeScopeMerge(namespaces: ["locked", "shop"])
        XCTAssertEqual(both.take(.unlisted("locked", forbidden), from: "locked"), [.unlisted("locked", forbidden)])
        XCTAssertEqual(both.take(.unlisted("shop", forbidden), from: "shop"), [.unlisted("shop", forbidden)])
        XCTAssertTrue(both.allRefused)
    }

    func testPastTheCapTheClusterWideFollowIsKeptToThem() {
        let scope = KubeScope.of(["shop", "payments"])
        let table = KubeTable(columns: Self.columns, rows: [Self.row("shop", "a"), Self.row("default", "b"), Self.row("payments", "c")])
        XCTAssertEqual(KubeScopeMerge.filtered(.listed(table), to: scope), .listed(KubeTable(columns: Self.columns, rows: [Self.row("shop", "a"), Self.row("payments", "c")])))
        XCTAssertEqual(
            KubeScopeMerge.filtered(.changed([.added(Self.row("default", "x")), .added(Self.row("shop", "y"))], resourceVersion: "4"), to: scope),
            .changed([.added(Self.row("shop", "y"))], resourceVersion: "4"))
        XCTAssertEqual(KubeScopeMerge.filtered(.changed([.added(Self.row("default", "x"))], resourceVersion: "5"), to: scope), .bookmark("5"), "only how far it got")
    }

    // MARK: The client

    func testSeveralNamespacesAreAWatchEachMerged() async throws {
        let stream = client().follow(.pods, in: .of(["shop", "payments"]))
        let rows = Rows()
        let task = Task { for try await update in stream { rows.apply(update) } }
        defer { task.cancel() }
        try await until(5, "both listed") { rows.ids == ["payments/web-1", "shop/api-1", "shop/web-1"] }
        try await until(5, "a watch each") { self.api.openWatches == 2 }
        XCTAssertEqual(Set(api.requests.filter { $0.query["watch"] == "1" }.map(\.path)), ["/api/v1/namespaces/shop/pods", "/api/v1/namespaces/payments/pods"])
        XCTAssertFalse(api.requests.contains { $0.path == "/api/v1/pods" }, "nothing across the cluster")
        api.addPod("db-0", namespace: "payments")
        api.addPod("elsewhere", namespace: "default")
        api.deletePod("api-1", namespace: "shop")
        try await until(5, "changes in both") { rows.ids == ["payments/db-0", "payments/web-1", "shop/web-1"] }

        let listed = try await client().list(.pods, in: .of(["shop", "payments"]))
        XCTAssertEqual(Set(listed.rows.map(\.id.description)), ["payments/db-0", "payments/web-1", "shop/web-1"])
    }

    func testPastTheCapItIsOneWatchAcrossTheClusterOrRefused() async throws {
        let names = ["shop", "payments"] + (1...9).map { "ns-\($0)" }
        let stream = client().follow(.pods, in: .of(names))
        let rows = Rows()
        let task = Task { for try await update in stream { rows.apply(update) } }
        try await until(5, "listed") { rows.ids == ["payments/web-1", "shop/api-1", "shop/web-1"] }
        try await until(5, "one watch") { self.api.openWatches == 1 }
        XCTAssertEqual(api.requests.filter { $0.query["watch"] == "1" }.map(\.path), ["/api/v1/pods"])
        api.addPod("elsewhere", namespace: "default")
        api.addPod("db-0", namespace: "payments")
        try await until(5, "kept to them") { rows.ids == ["payments/db-0", "payments/web-1", "shop/api-1", "shop/web-1"] }
        task.cancel()
        try await until(5, "closed") { self.api.openWatches == 0 }

        // Where the list across the cluster is refused: said, with what to do.
        api.forbidden = ["pods@cluster"]
        do {
            for try await _ in client().follow(.pods, in: .of(names)) {}
            XCTFail("refused")
        } catch let refused as KubeScopeRefused {
            XCTAssertEqual(refused.count, 11)
            XCTAssertTrue(refused.localizedDescription.contains("Pick 10 or fewer"), refused.localizedDescription)
        }
        do {
            _ = try await client().list(.pods, in: .of(names))
            XCTFail("refused")
        } catch is KubeScopeRefused {}
        // Ten are a list each: allowed.
        let ten = try await client().list(.pods, in: .of(Array(names.prefix(10))))
        XCTAssertEqual(ten.rows.count, 4, "shop's two, payments' two")
    }

    func testANamespaceRefusedLeavesTheOthersListed() async throws {
        api.addNamespace("locked")
        api.addPod("secret-app", namespace: "locked")
        api.forbidden = ["pods@locked"]
        let updates = Updates()
        let task = Task { for try await update in self.client().follow(.pods, in: .of(["shop", "locked"])) { updates.append(update) } }
        defer { task.cancel() }
        try await until(5, "shop listed") { updates.rows.ids == ["shop/api-1", "shop/web-1"] }
        XCTAssertTrue(updates.all.contains { if case .unlisted("locked", let error) = $0 { error.isForbidden } else { false } }, "said")
        api.addPod("db-0", namespace: "shop")
        try await until(5, "shop still followed") { updates.rows.ids == ["shop/api-1", "shop/db-0", "shop/web-1"] }

        let listed = try await client().list(.pods, in: .of(["shop", "locked"]))
        XCTAssertEqual(Set(listed.rows.map(\.id.description)), ["shop/api-1", "shop/db-0", "shop/web-1"], "a list leaves it out too")

        // Every one refusing: refused.
        api.forbidden = ["pods@locked", "pods@shop"]
        do {
            for try await _ in client().follow(.pods, in: .of(["shop", "locked"])) {}
            XCTFail("refused")
        } catch let error as KubeAPIError {
            XCTAssertTrue(error.isForbidden)
        }
        do {
            _ = try await client().list(.pods, in: .of(["shop", "locked"]))
            XCTFail("refused")
        } catch let error as KubeAPIError {
            XCTAssertTrue(error.isForbidden)
        }
    }

    func testThePageSaysANamespaceItCantListAndIsLiveAfterARetry() async throws {
        api.addNamespace("locked")
        api.streamingLists = false
        let model = model([Self.context("fake-dev", namespace: "shop")], current: "fake-dev")
        model.show()
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 2 && model.listState == .live }
        api.forbidden = ["pods@locked"]
        model.setScope(.of(["shop", "locked", "payments"]))
        try await until(5, "the rest listed") { model.rows.sorted.map(\.id.description) == ["payments/web-1", "shop/api-1", "shop/web-1"] }
        XCTAssertEqual(model.listState, .live)
        XCTAssertEqual(Array(model.unlisted.keys), ["locked"])
        XCTAssertEqual(model.unlistedNote?.hasPrefix("Can't list pods in locked ("), true, model.unlistedNote ?? "")

        // payments waits for the server: retrying, whatever shop's changes say.
        api.failingResources = ["pods@payments"]
        api.expireWatches()
        try await until(5, "retrying") { if case .retrying = model.listState { true } else { false } }
        api.addPod("db-0", namespace: "shop")
        try await until(5, "shop's change") { model.rows[KubeRowID(namespace: "shop", name: "db-0")] != nil }
        try await Task.sleep(for: .milliseconds(100))
        if case .retrying = model.listState {} else { XCTFail("still retrying, not \(model.listState)") }
        // Back, nothing changed in it: live.
        api.failingResources = []
        try await until(5, "live again") { model.listState == .live }
        XCTAssertEqual(model.rows.count, 4)
    }

    // MARK: The picker

    func testThePickerTicksSeveral() {
        var picker = KubePicker.namespaces(
            listed: ["default", "payments", "shop"], favourites: ["shop"], own: nil, current: .of(["shop", "payments"]), refused: nil, listedAll: true)
        XCTAssertEqual(picker.items.map(\.title), ["All namespaces", "shop", "payments", "default"], "favourites first, then the ones showing")
        XCTAssertEqual(picker.items.filter(picker.isChecked).map(\.title), ["shop", "payments"])
        XCTAssertEqual(picker.selected?.title, "payments", "the first showing highlighted")
        XCTAssertEqual(picker.checkedScope, .of(["shop", "payments"]))

        // Untick payments: shop alone.
        XCTAssertEqual(picker.toggle(), .namespace("shop"))
        // Tick default and payments: every listed one is All — one watch.
        picker.move(1)
        XCTAssertEqual(picker.selected?.title, "default")
        XCTAssertEqual(picker.toggle(), .of(["shop", "default"]))
        picker.move(-1)
        XCTAssertEqual(picker.toggle(), .all)
        XCTAssertTrue(picker.isChecked(picker.items[0]), "All ticked")
        XCTAssertEqual(picker.collapsed, .of(["shop", "default", "payments"]), "what to show should All be refused")
        // A namespace ticked with All goes alone; All clears them.
        XCTAssertEqual(picker.toggle(), .namespace("payments"))
        picker.index = 0
        XCTAssertEqual(picker.toggle(), .all)

        // a,b typed is those.
        picker.query = "shop, payments"
        XCTAssertEqual(picker.results.first?.title, "shop, payments")
        XCTAssertEqual(picker.chosen, .scope(.of(["shop", "payments"])))
        picker.query = "shop,-x"
        XCTAssertNotEqual(picker.results.first?.typed, true, "not every one a name")
        XCTAssertEqual(KubePicker.typedNamespaces("A, b,,a"), ["a", "b"])
        XCTAssertNil(KubePicker.typedNamespaces("a,b c"))

        // Where the namespaces aren't the server's whole list — or listing
        // across the cluster was refused — every one ticked is still them.
        var accessible = KubePicker.namespaces(listed: ["a", "b"], favourites: [], own: nil, current: .namespace("a"), refused: nil)
        accessible.move(1)
        XCTAssertEqual(accessible.toggle(), .of(["a", "b"]))
        XCTAssertNil(accessible.collapsed)
    }

    /// Every listed namespace ticked is All — but where the pods may only
    /// be listed a namespace at a time, its refusal shows them again, and
    /// from then on ticking them all stays them.
    func testEveryNamespaceTickedWhereAllIsRefusedStaysThem() async throws {
        api.forbidden = ["pods@cluster"]
        let model = model([Self.context("fake-dev", namespace: "shop")], current: "fake-dev")
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 2 && model.namespaces == ["default", "payments", "shop"] }
        XCTAssertTrue(page.press("n"))
        page.picker?.query = "payments"
        page.togglePicked()
        page.picker?.query = "default"
        page.togglePicked()
        try await until(5, "them again") { model.clusterListRefused && model.scope == .of(["default", "payments", "shop"]) }
        try await until(5, "listed a namespace each") { model.rows.count == 4 && model.listState == .live }
        try await until(5, "the picker knows") { page.picker?.listedAll.isEmpty == true }
        page.picker?.query = "default"
        page.togglePicked()
        XCTAssertEqual(model.scope, .of(["payments", "shop"]))
        page.picker?.query = "default"
        page.togglePicked()
        XCTAssertEqual(model.scope, .of(["default", "payments", "shop"]), "not All: refused here")
        page.closePicker()
    }

    func testASavedFilterKeepsSeveralNamespacesAndAnOlderBuildReadsOne() throws {
        let saved = KubeSavedFilter(name: "web", context: "fake-dev", kind: .init(.pods), scope: .of(["shop", "payments"]), filter: "web")
        XCTAssertEqual(saved.namespace, "payments", "one name an older build can list")
        XCTAssertEqual(saved.namespaces, ["payments", "shop"])
        XCTAssertEqual(saved.scope, .of(["shop", "payments"]))
        XCTAssertEqual(saved.said, "Pod · payments +1 · fake-dev")
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(KubeSavedFilter.self, from: data), saved)
        struct Older: Decodable { var namespace: String? }
        XCTAssertEqual(try JSONDecoder().decode(Older.self, from: data).namespace, "payments")

        let one = KubeSavedFilter(name: "web", context: "fake-dev", kind: .init(.pods), scope: .namespace("shop"), filter: "web")
        XCTAssertEqual(one.namespace, "shop")
        XCTAssertNil(one.namespaces)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(one), as: UTF8.self).contains("namespaces"), "the file as an older build wrote it")
        // An older build's file: one namespace.
        let older = try JSONDecoder().decode(
            KubeSavedFilter.self,
            from: Data(
                #"{"id":"\#(UUID().uuidString)","name":"web","context":"fake-dev","kind":{"group":"","version":"v1","resource":"pods","kind":"Pod","namespaced":true},"namespace":"shop","filter":"web"}"#
                    .utf8))
        XCTAssertEqual(older.scope, .namespace("shop"))
        XCTAssertEqual(KubeSavedFilter(name: "n", context: "fake-dev", kind: .init(.namespaces), scope: .of(["a", "b"]), filter: "x").scope, .all)
    }

    func testTheOverviewSharesOneWatchBudget() {
        let parts = KubeClusterOverviewSession.parts(nil).map(\.1)
        XCTAssertEqual(KubeClusterOverviewSession.watchCap(parts), 2, "five phases: two namespaces each")
        let ten = parts + Array(repeating: KubeResourceKind.pods, count: 5)
        XCTAssertEqual(KubeClusterOverviewSession.watchCap(ten), 1, "ten parts: across the cluster for two or more")
        XCTAssertEqual(KubeClusterOverviewSession.watchCap([.namespaces]), KubeScope.watchCap, "a cluster-scoped kind takes none")
        XCTAssertEqual(KubeScopeRefused(count: 3, reason: "forbidden", cap: 1).localizedDescription.hasSuffix("Pick one namespace."), true)
    }

    // MARK: The page

    func testThePageShowsSeveralNamespacesAndKeepsThem() async throws {
        let name = "overterm-test-\(UUID().uuidString)"
        suite = name
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = model([Self.context("fake-dev", namespace: "shop")], current: "fake-dev")
        model.remembersSelection = true
        model.defaults = defaults
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "listed") { model.rows.count == 2 && model.namespaces == ["default", "payments", "shop"] }
        XCTAssertFalse(page.columns.contains { $0.id == KubernetesPageModel.namespaceColumn }, "one namespace: no Namespace column")
        XCTAssertEqual(page.scopeLabel, "shop")

        // n, payments ticked: both, merged, the Namespace column.
        XCTAssertTrue(page.press("n"))
        page.picker?.query = "payments"
        page.togglePicked()
        XCTAssertNotNil(page.picker, "ticking leaves it open")
        XCTAssertEqual(model.scope, .of(["shop", "payments"]))
        try await until(5, "both") { model.rows.sorted.map(\.id.description) == ["payments/web-1", "shop/api-1", "shop/web-1"] }
        XCTAssertEqual(page.columns.first?.id, KubernetesPageModel.namespaceColumn)
        XCTAssertEqual(page.scopeLabel, "payments +1")
        XCTAssertNil(page.scopeNote)
        XCTAssertEqual(
            page.listKubectl, "kubectl --context fake-dev get po -n payments\nkubectl --context fake-dev get po -n shop", "a command each, one -n each")
        XCTAssertNil(page.shownNamespace, "a tab carries one -n: the context's own")
        XCTAssertEqual(page.templateNamespace, "shop", "the context's own, one of them")
        XCTAssertEqual(defaults.dictionary(forKey: KubernetesModel.scopesKey) as? [String: [String]], ["fake-dev": ["payments", "shop"]])
        XCTAssertEqual(defaults.string(forKey: "kubernetes.selectedContext"), "fake-dev", "the context picked kept in the same defaults")
        page.closePicker()

        // :ns a,b.
        XCTAssertNil(page.run(try XCTUnwrap(KubeCommand.parse(":ns default,shop"))))
        XCTAssertEqual(model.scope, .of(["default", "shop"]))
        XCTAssertEqual(page.run(try XCTUnwrap(KubeCommand.parse(":ns shop,-x"))), "Not a namespace's name: shop,-x")
        try await until(5, "default and shop") { model.rows.sorted.map(\.id.description) == ["default/other", "shop/api-1", "shop/web-1"] }

        // Another model on the same defaults: the context opens on them.
        let again = self.model([Self.context("fake-dev", namespace: "shop")], current: "fake-dev")
        again.remembersSelection = true
        again.defaults = defaults
        again.show()
        defer { again.hide() }
        try await until(5, "remembered") { again.scope == .of(["default", "shop"]) }
        XCTAssertEqual(again.agentDefaultScope(for: Self.context("fake-dev", namespace: "shop")), .of(["default", "shop"]), "the agents' default follows")
    }
}

/// A follow's updates, as they come, and its rows.
private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [KubeFollowUpdate] = []
    let rows = Rows()

    func append(_ update: KubeFollowUpdate) {
        lock.withLock { updates.append(update) }
        rows.apply(update)
    }
    var all: [KubeFollowUpdate] { lock.withLock { updates } }
}

/// A follow's rows, applied as they come.
private final class Rows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = KubeRows()

    func apply(_ update: KubeFollowUpdate) { lock.withLock { rows.apply(update) } }
    var ids: [String] { lock.withLock { rows.sorted.map(\.id.description) } }
}
