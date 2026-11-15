import Combine
import XCTest

@testable import Overterm

/// Attention marks (docs/design/kubernetes/analysis.md, 3.13): what marks
/// a bound checkout's tab and what clears it (`KubeAttention`, pure), the
/// budget (`KubeAttentionBudget`), a tab's cluster mark (`TabActivity`),
/// the Deployments' conditions carried by their rows, and the background
/// watches themselves (`KubeAttentionWatches`) against `FakeKubeAPI` on a
/// socket of the test's own — two watches a bound namespace, the
/// binding's selector the server's, only GETs, no Secret.
@MainActor
final class KubeAttentionTests: XCTestCase {
    // MARK: The marks (pure)

    private static let podColumns = [
        KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Ready"), KubeColumn(name: "Status"), KubeColumn(name: "Restarts", type: "integer"),
    ]

    private func pods(_ rows: [(String, String)]) -> KubeRows {
        KubeRows(
            KubeTable(
                columns: Self.podColumns,
                rows: rows.map { KubeRow(id: KubeRowID(namespace: "shop", name: $0.0), cells: [.text($0.0), .text("0/1"), .text($0.1), .integer(1)]) }))
    }

    private func deployments(_ rows: [(String, Bool)]) -> KubeRows {
        let columns = [KubeColumn(name: "Name", format: "name"), KubeColumn(name: "Ready")]
        return KubeRows(
            KubeTable(
                columns: columns,
                rows: rows.map { name, stuck in
                    KubeRow(
                        id: KubeRowID(namespace: "shop", name: name), cells: [.text(name), .text("0/1")],
                        conditions: [
                            KubeRowCondition(type: "Available", status: "False", reason: "MinimumReplicasUnavailable"),
                            KubeRowCondition(
                                type: "Progressing", status: stuck ? "False" : "True", reason: stuck ? "ProgressDeadlineExceeded" : "ReplicaSetUpdated"),
                        ])
                }))
    }

    func testAPodMarksOnceWhenItStartsFailingAndClearsWhenItGoes() {
        var attention = KubeAttention(context: "fake-dev", namespace: "shop")
        // Where things stand when the watch began is no news.
        XCTAssertTrue(attention.observePods(pods([("old-1", "CrashLoopBackOff"), ("web-1", "Running")])).isEmpty)
        XCTAssertTrue(attention.observePods(pods([("old-1", "CrashLoopBackOff"), ("web-1", "Running")])).isEmpty)
        // web-1 goes into a crash loop: marked once.
        let crashed = attention.observePods(pods([("old-1", "CrashLoopBackOff"), ("web-1", "CrashLoopBackOff")]))
        XCTAssertEqual(crashed.raised.map(\.ref.name), ["web-1"])
        XCTAssertEqual(crashed.raised.first?.reason, "CrashLoopBackOff")
        XCTAssertEqual(crashed.raised.first?.note, "pod/web-1 CrashLoopBackOff — fake-dev · shop")
        XCTAssertEqual(crashed.raised.first?.ref.kind.fullName, "pods")
        // Its restarts — Running, Error, CrashLoopBackOff again, OOMKilled — mark nothing more.
        for status in ["Running", "Error", "CrashLoopBackOff", "OOMKilled"] {
            XCTAssertTrue(attention.observePods(pods([("old-1", "CrashLoopBackOff"), ("web-1", status)])).isEmpty, status)
        }
        XCTAssertEqual(attention.standing.map(\.ref.name), ["web-1"])
        // A new rollout's pod failing is news of its own; an image that won't pull too.
        let rollout = attention.observePods(pods([("web-1", "Running"), ("web-2", "ImagePullBackOff"), ("init-1", "Init:CrashLoopBackOff")]))
        XCTAssertEqual(rollout.raised.map(\.ref.name), ["init-1", "web-2"])
        XCTAssertEqual(rollout.raised.map(\.reason), ["CrashLoopBackOff", "ImagePullBackOff"], "an init container's too")
        XCTAssertTrue(rollout.cleared.isEmpty, "old-1 never marked: nothing to clear")
        // Gone: cleared.
        let replaced = attention.observePods(pods([("web-3", "Running")]))
        XCTAssertEqual(Set(replaced.cleared.map(\.ref.name)), ["web-1", "web-2", "init-1"])
        XCTAssertTrue(attention.standing.isEmpty)
        // A name used again (a StatefulSet's pod) after it went: news again.
        XCTAssertEqual(attention.observePods(pods([("web-3", "Running"), ("web-1", "OOMKilled")])).raised.map(\.reason), ["OOMKilled"])
        // Error and Pending aren't marks: Ask Why on the page covers them.
        XCTAssertTrue(attention.observePods(pods([("web-1", "OOMKilled"), ("web-3", "Error"), ("x", "Pending")])).isEmpty)
    }

    func testAStuckRolloutMarksAndClearsWhenItProgresses() {
        var attention = KubeAttention(context: "fake-dev", namespace: "shop")
        XCTAssertTrue(attention.observeDeployments(deployments([("old", true), ("web", false)])).isEmpty, "stuck already: no news")
        let stuck = attention.observeDeployments(deployments([("old", true), ("web", true)]))
        XCTAssertEqual(stuck.raised.map(\.ref.name), ["web"])
        XCTAssertEqual(stuck.raised.first?.reason, "ProgressDeadlineExceeded")
        XCTAssertEqual(stuck.raised.first?.note, "deploy/web rollout stuck (ProgressDeadlineExceeded) — fake-dev · shop")
        XCTAssertTrue(attention.observeDeployments(deployments([("old", true), ("web", true)])).isEmpty, "once")
        // web progresses again: cleared; old moves on too, and may mark next time.
        let moving = attention.observeDeployments(deployments([("old", false), ("web", false)]))
        XCTAssertEqual(moving.cleared.map(\.ref.name), ["web"])
        XCTAssertTrue(moving.raised.isEmpty)
        let again = attention.observeDeployments(deployments([("old", true), ("web", true)]))
        XCTAssertEqual(again.raised.map(\.ref.name), ["old", "web"], "stuck again: marked again")
        // Deleted: cleared.
        XCTAssertEqual(attention.observeDeployments(deployments([("old", true)])).cleared.map(\.ref.name), ["web"])
        // Only the binding's own.
        var only = KubeAttention(context: "fake-dev", namespace: "shop")
        _ = only.observeDeployments(deployments([("web", false), ("other", false)]), includes: { $0 == "web" })
        XCTAssertEqual(only.observeDeployments(deployments([("web", true), ("other", true)]), includes: { $0 == "web" }).raised.map(\.ref.name), ["web"])
    }

    func testTheBudgetWatchesTheMostRecentlyUsedBoundNamespaces() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func binding(_ checkout: String, _ namespace: String, selector: String? = nil) -> KubeBinding {
            KubeBinding(checkout: checkout, context: "fake-dev", namespace: namespace, selector: selector)
        }
        let bindings = [
            "/a": binding("/a", "shop"), "/b": binding("/b", "payments"), "/c": binding("/c", "shop"), "/d": binding("/d", "search", selector: "app=s"),
        ]
        let open: [String: Date] = ["/a": t0, "/b": t0.addingTimeInterval(30), "/c": t0.addingTimeInterval(10), "/d": t0.addingTimeInterval(20), "/e": t0]
        let plan = KubeAttentionBudget.plan(open: open, bindings: bindings, budget: 2)
        XCTAssertEqual(plan.watched.map(\.namespace), ["payments", "search"], "the most recently used first")
        XCTAssertEqual(plan.over.map(\.namespace), ["shop"], "two checkouts in shop are one scope; /e is bound to nothing")
        XCTAssertEqual(plan.watched.last?.selector, "app=s")
        XCTAssertEqual(KubeAttentionBudget.plan(open: open, bindings: bindings, budget: 4).watched.count, 3)
        XCTAssertEqual(KubeAttentionBudget.watchesPerScope * 4, 8, "at most 8 watches by default")
        XCTAssertTrue(KubeAttentionBudget.plan(open: [:], bindings: bindings, budget: 4).watched.isEmpty, "no tab open, nothing watched")
    }

    func testAClusterMarkOnATab() {
        var activity = TabActivity()
        XCTAssertFalse(activity.clusterFailed("pod/web-1 CrashLoopBackOff — fake-dev · shop", visible: true), "seen as it happened")
        XCTAssertTrue(activity.clusterFailed("pod/web-1 CrashLoopBackOff — fake-dev · shop", visible: false))
        XCTAssertEqual(activity.mark, .failed)
        XCTAssertTrue(activity.fromCluster)
        XCTAssertFalse(activity.clusterFailed("pod/web-1 CrashLoopBackOff — fake-dev · shop", visible: false), "the same again: no news")
        XCTAssertTrue(activity.clusterFailed("deploy/web rollout stuck (ProgressDeadlineExceeded) — fake-dev · shop", visible: false), "a newer one says itself")
        XCTAssertEqual(activity.note, "deploy/web rollout stuck (ProgressDeadlineExceeded) — fake-dev · shop")
        XCTAssertTrue(activity.clusterRecovered())
        XCTAssertEqual(activity.mark, .none)
        // Another mark since: a recovered cluster leaves it.
        XCTAssertTrue(activity.clusterFailed("pod/web-2 OOMKilled — fake-dev · shop", visible: false))
        XCTAssertTrue(activity.handle(.bell, visible: false))
        XCTAssertFalse(activity.fromCluster)
        XCTAssertFalse(activity.clusterRecovered())
        XCTAssertEqual(activity.mark, .waiting)
        // A container's mark isn't a cluster's.
        var docker = TabActivity()
        XCTAssertTrue(docker.containerFailed("db exited (1)", visible: false))
        XCTAssertFalse(docker.clusterRecovered())
        XCTAssertFalse(docker.clusterFailed("pod/x CrashLoopBackOff — c · n", visible: false), "a failure already marks it")
    }

    /// The bound checkout's agent waiting after a deploy: a crash keeps the
    /// waiting mark but is still news (told, `clusterNewsUnderOtherMark`),
    /// and the Inbox offers Ask Why on the tab's alerts whatever its mark.
    func testACrashUnderAWaitingMarkIsStillToldAndAsksWhy() {
        let crash = "pod/web-1 CrashLoopBackOff — fake-dev · shop"
        var waiting = TabActivity()
        XCTAssertTrue(waiting.handle(.bell, visible: false))
        XCTAssertFalse(waiting.clusterFailed(crash, visible: false), "the waiting mark is higher: kept")
        XCTAssertEqual(waiting.mark, .waiting)
        XCTAssertTrue(waiting.clusterNewsUnderOtherMark(visible: false), "but the crash is still told")
        XCTAssertFalse(waiting.clusterNewsUnderOtherMark(visible: true), "seen as it happened")
        // A failed command holds the mark: told too.
        var failed = TabActivity()
        XCTAssertTrue(failed.containerFailed("db exited (1)", visible: false))
        XCTAssertFalse(failed.clusterFailed(crash, visible: false))
        XCTAssertTrue(failed.clusterNewsUnderOtherMark(visible: false))
        // A cluster mark already: the same note again is no news, said by clusterFailed.
        var cluster = TabActivity()
        XCTAssertTrue(cluster.clusterFailed(crash, visible: false))
        XCTAssertFalse(cluster.clusterFailed(crash, visible: false))
        XCTAssertFalse(cluster.clusterNewsUnderOtherMark(visible: false))

        let tab = Tab(terminal: TerminalView())
        tab.activity = waiting
        tab.kubeAlerts = [
            KubeAttentionAlert(ref: KubeObjectRef(context: "fake-dev", kind: .pods, namespace: "shop", name: "web-1"), reason: "CrashLoopBackOff")
        ]
        let inbox = InboxModel()
        inbox.refresh(tabs: [tab], group: { _ in nil }, screen: { _ in nil })
        XCTAssertEqual(inbox.entries.first?.mark, .waiting)
        XCTAssertEqual(inbox.entries.first?.asksWhy, true, "Ask Why follows the tab's alerts, not who holds the mark")
        tab.kubeAlerts = []
        inbox.refresh(tabs: [tab], group: { _ in nil }, screen: { _ in nil })
        XCTAssertEqual(inbox.entries.first?.asksWhy, false)
    }

    func testADeploymentsRowCarriesItsConditionsOnlyWhenItsObjectCame() throws {
        let object: [String: Any] = [
            "kind": "Table", "apiVersion": "meta.k8s.io/v1",
            "columnDefinitions": [["name": "Name", "type": "string", "format": "name"]],
            "rows": [
                [
                    "cells": ["web"],
                    "object": [
                        "kind": "Deployment", "metadata": ["name": "web", "namespace": "shop"],
                        "spec": ["template": ["spec": ["containers": [["env": [["name": "DB_PASSWORD", "value": "acme-unit-pw"]]]]]]],
                        "status": ["conditions": [["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded", "message": "timed out"]]],
                    ],
                ],
                ["cells": ["api"], "object": ["kind": "PartialObjectMetadata", "metadata": ["name": "api", "namespace": "shop"]]],
            ],
        ]
        let table = try KubeTableReader.read(object, namespace: "shop")
        XCTAssertEqual(table.rows.first?.conditions, [KubeRowCondition(type: "Progressing", status: "False", reason: "ProgressDeadlineExceeded")])
        XCTAssertTrue(KubeAttention.isStuck(table.rows[0]))
        XCTAssertEqual(table.rows.last?.conditions, [], "metadata carries none")
        XCTAssertFalse("\(table.rows)".contains("acme-unit-pw"), "nothing else of the object is kept")
        XCTAssertEqual(KubeClient.includeObject(.deployments, .namespace("shop"), objects: true), "Object")
        XCTAssertEqual(KubeClient.includeObject(.pods, .namespace("shop")), "None")
    }

    // MARK: The watches, against the fake

    nonisolated(unsafe) private var api: FakeKubeAPI!
    nonisolated(unsafe) private var socket: String!
    private var folder: URL!

    override func tearDown() async throws {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertFalse(api.requests.contains { $0.path.contains("/secrets") }, "no Secret")
            XCTAssertFalse(api.requests.contains { $0.isLog }, "no log")
            api.stop()
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func startFake() throws {
        socket = "/tmp/otka-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kube-attention-\(UUID().uuidString)", isDirectory: true)
        api.addNamespace("shop")
        api.addNamespace("payments")
        let part = ["app.kubernetes.io/part-of": "shop"]
        api.addPod("web-1", namespace: "shop", labels: part)
        api.addPod("other-1", namespace: "shop")
        api.add(
            "deployments.apps", "web", namespace: "shop", values: ["Ready": "1/1", "Up-to-date": 1, "Available": 1], labels: part,
            fields: ["status": ["conditions": [["type": "Progressing", "status": "True", "reason": "NewReplicaSetAvailable"]]]])
        api.addPod("pay-1", namespace: "payments")
    }

    private func watches(budget: Int = 4, enabled: Bool = true) -> KubeAttentionWatches {
        let store = KubeBindingStore(file: folder.appendingPathComponent("support/bindings.json"))
        let watches = KubeAttentionWatches(store: store, kubernetes: KubernetesModel(proxies: KubeProxies()))
        let list = KubeMCPTests.listForPanel()
        watches.contexts = { list }
        watches.enabled = { enabled }
        watches.budget = { budget }
        watches.flushInterval = .milliseconds(10)
        watches.retryDelays = [.milliseconds(100)]
        let socket = self.socket!
        watches.clientFor = { context in KubeClient(KubeSocketConnection(socket: socket, context: context.name)) }
        return watches
    }

    private func until(_ seconds: Double, _ what: String, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testABoundCheckoutWithATabOpenIsWatchedAndMarked() async throws {
        try startFake()
        let watches = watches()
        let checkout = folder.appendingPathComponent("shop").path
        XCTAssertTrue(
            watches.store.set(KubeBinding(checkout: checkout, context: "fake-dev", namespace: "shop", selector: "app.kubernetes.io/part-of=shop")))
        var events: [KubeAttentionWatches.Event] = []
        let sink = watches.events.sink { events.append($0) }
        defer { sink.cancel() }
        let window = ObjectIdentifier(self)
        // No tab of it: nothing is followed.
        watches.refreshNow()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(api.requests.isEmpty, "\(api.requests)")
        let key = KubeBindingStore.key(URL(fileURLWithPath: checkout))
        watches.report(window, open: [key], selected: key)
        watches.refreshNow()
        try await until(5, "both watched") { watches.states[key] == .watching && self.api.openWatches == 2 }
        XCTAssertEqual(api.watched, ["deployments.apps", "pods"])
        let lists = api.requests.filter { !$0.isWatch }
        XCTAssertTrue(lists.allSatisfy { $0.query["labelSelector"] == "app.kubernetes.io/part-of=shop" }, "the binding's selector, the server's: \(lists)")
        XCTAssertEqual(api.requests.first { $0.path.hasSuffix("/deployments") }?.query["includeObject"], "Object", "its conditions")
        XCTAssertEqual(api.requests.first { $0.path.hasSuffix("/pods") }?.query["includeObject"], "None", "rows only")
        XCTAssertTrue(api.requests.allSatisfy { $0.path.contains("/namespaces/shop/") }, "the bound namespace only")

        // A crash marks it; a stuck rollout too.
        api.updatePod("web-1", namespace: "shop") { $0.status = "CrashLoopBackOff" }
        try await until(5, "the crash") { events.flatMap(\.change.raised).count == 1 }
        XCTAssertEqual(events.last?.checkouts, [key])
        XCTAssertEqual(events.last?.change.raised.first?.note, "pod/web-1 CrashLoopBackOff — fake-dev · shop")
        api.setFields(
            "deployments.apps", "web", namespace: "shop",
            ["status": ["conditions": [["type": "Progressing", "status": "False", "reason": "ProgressDeadlineExceeded"]]]])
        try await until(5, "the stuck rollout") { events.flatMap(\.change.raised).count == 2 }
        XCTAssertEqual(events.last?.change.raised.first?.object, "deploy/web")
        // The pod replaced: cleared.
        api.deletePod("web-1", namespace: "shop")
        try await until(5, "cleared") { events.flatMap(\.change.cleared).map(\.object) == ["pod/web-1"] }
        // A pod outside the selector marks nothing.
        api.updatePod("other-1", namespace: "shop") { $0.status = "CrashLoopBackOff" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(events.flatMap(\.change.raised).count, 2)

        // Its tab closed: every watch ends.
        watches.report(window, open: [], selected: nil)
        watches.refreshNow()
        try await until(5, "unwatched") { self.api.openWatches == 0 }
        XCTAssertTrue(watches.states.isEmpty)
        XCTAssertTrue(watches.watchedScopes.isEmpty)
    }

    func testPastTheBudgetACheckoutIsNotWatched() async throws {
        try startFake()
        let watches = watches(budget: 1)
        let shop = folder.appendingPathComponent("shop").path
        let pay = folder.appendingPathComponent("pay").path
        XCTAssertTrue(watches.store.set(KubeBinding(checkout: shop, context: "fake-dev", namespace: "shop")))
        XCTAssertTrue(watches.store.set(KubeBinding(checkout: pay, context: "fake-dev", namespace: "payments")))
        let (a, b) = (KubeBindingStore.key(URL(fileURLWithPath: shop)), KubeBindingStore.key(URL(fileURLWithPath: pay)))
        watches.report(ObjectIdentifier(self), open: [a, b], selected: a)
        watches.refreshNow()
        try await until(5, "shop watched") { watches.states[a] == .watching }
        XCTAssertNotNil(watches.states[b]?.notWatched, "over the budget")
        XCTAssertEqual(api.openWatches, 2, "one namespace's two")
        // payments used now: it takes the budget.
        watches.report(ObjectIdentifier(self), open: [a, b], selected: b)
        watches.refreshNow()
        try await until(5, "payments watched") { watches.states[b] == .watching && watches.states[a]?.notWatched != nil }
        try await until(5, "shop's watches ended") { self.api.watched == ["deployments.apps", "pods"] && self.api.openWatches == 2 }
        // Off: nothing.
        watches.enabled = { false }
        watches.refreshNow()
        try await until(5, "off") { self.api.openWatches == 0 && watches.states.isEmpty }
    }

    /// A watch dropped (over the budget here) takes its marks down: no
    /// later watch knows of them, so a pod deleted meanwhile would never
    /// clear its mark. Re-admitted, it starts from where things stand.
    func testAWatchDroppedByTheBudgetTakesItsMarksDown() async throws {
        try startFake()
        let watches = watches(budget: 1)
        let shop = folder.appendingPathComponent("shop").path
        let pay = folder.appendingPathComponent("pay").path
        XCTAssertTrue(watches.store.set(KubeBinding(checkout: shop, context: "fake-dev", namespace: "shop")))
        XCTAssertTrue(watches.store.set(KubeBinding(checkout: pay, context: "fake-dev", namespace: "payments")))
        let (a, b) = (KubeBindingStore.key(URL(fileURLWithPath: shop)), KubeBindingStore.key(URL(fileURLWithPath: pay)))
        // What the tabs hold, as the window applies the events.
        var marks: [String: Set<String>] = [:]
        let sink = watches.events.sink { event in
            for key in event.checkouts {
                marks[key, default: []].subtract(event.change.cleared.map(\.id))
                marks[key, default: []].formUnion(event.change.raised.map(\.id))
            }
        }
        defer { sink.cancel() }
        let window = ObjectIdentifier(self)
        watches.report(window, open: [a, b], selected: a)
        watches.refreshNow()
        try await until(5, "shop watched") { watches.states[a] == .watching }
        api.updatePod("web-1", namespace: "shop") { $0.status = "CrashLoopBackOff" }
        try await until(5, "marked") { marks[a]?.count == 1 }
        // payments used now: shop's watch is dropped, its mark taken down.
        watches.report(window, open: [a, b], selected: b)
        watches.refreshNow()
        try await until(5, "shop's mark down") { marks[a]?.isEmpty == true }
        XCTAssertNotNil(watches.states[a]?.notWatched, "and it says it isn't watched")
        // The pod goes while nobody watches; shop used again.
        api.deletePod("web-1", namespace: "shop")
        watches.report(window, open: [a, b], selected: a)
        watches.refreshNow()
        try await until(5, "shop watched again") { watches.states[a] == .watching }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(marks[a], [], "no mark about a pod that no longer exists")
        watches.stopAll()
        try await until(5, "stopped") { self.api.openWatches == 0 }
    }

    func testAWatchThatCantListSaysNotWatchedAndTriesAgain() async throws {
        try startFake()
        api.forbidden = ["pods"]
        let watches = watches()
        let shop = folder.appendingPathComponent("shop").path
        XCTAssertTrue(watches.store.set(KubeBinding(checkout: shop, context: "fake-dev", namespace: "shop")))
        let key = KubeBindingStore.key(URL(fileURLWithPath: shop))
        watches.report(ObjectIdentifier(self), open: [key], selected: key)
        watches.refreshNow()
        try await until(5, "not watched") { watches.states[key]?.notWatched?.contains("Not allowed") == true }
        api.forbidden = []
        try await until(5, "watched again") { watches.states[key] == .watching }
        watches.stopAll()
        try await until(5, "stopped") { self.api.openWatches == 0 }
    }

    func testAContextTheKubeconfigLacksIsSaid() async throws {
        try startFake()
        let watches = watches()
        let shop = folder.appendingPathComponent("shop").path
        XCTAssertTrue(watches.store.set(KubeBinding(checkout: shop, context: "acme-gone", namespace: "shop")))
        let key = KubeBindingStore.key(URL(fileURLWithPath: shop))
        watches.report(ObjectIdentifier(self), open: [key], selected: key)
        watches.refreshNow()
        try await until(5, "said") { watches.states[key]?.notWatched?.contains("acme-gone") == true }
        XCTAssertTrue(api.requests.isEmpty)
    }
}
