import Foundation
import XCTest

@testable import Overterm

/// The Kubernetes page: the app's model against `FakeKubeAPI` on a socket
/// of the test's own — contexts chosen, the pods followed while a page
/// shows and only then, a namespace or all of them — and the page's own
/// reading of them: the server's columns, a failing pod's reason, the
/// production band, the filter, the order, the keys. Ages as kubectl says
/// them. Nothing here reads ~/.kube: this Mac's current context is
/// production, and a unit test's model reads no kubeconfig at all.
@MainActor
final class KubernetesPageTests: XCTestCase {
    private var api: FakeKubeAPI!
    private var socket: String!

    override func setUpWithError() throws {
        socket = "/tmp/otkp-\(UInt32.random(in: 0...UInt32.max)).sock"
        api = FakeKubeAPI(socket: socket)
        try api.start()
        api.addNamespace("shop")
        api.addNamespace("payments")
        api.addPod("web-1", namespace: "shop")
        var crashing = FakeKubeAPI.Pod()
        crashing.status = "CrashLoopBackOff"
        crashing.ready = 0
        crashing.restarts = 7
        crashing.lastRestart = "2m"
        api.addPod("api-1", namespace: "shop", crashing)
        api.addPod("web-1", namespace: "payments")
    }

    override func tearDown() {
        if let api {
            XCTAssertEqual(api.writes, [], "only GETs")
            XCTAssertEqual(api.subresourceRequests, [], "no subresource")
            api.stop()
        }
    }

    private static func context(_ name: String, namespace: String? = nil, settings: KubeContextSettings = KubeContextSettings()) -> KubeContext {
        KubeContext(
            name: name, cluster: name, server: "http://127.0.0.1:1", namespace: namespace, user: "anonymous", auth: KubeAuth.none, file: nil,
            contextClass: KubeClassifier.classify(context: name, cluster: name, set: settings.contextClass), settings: settings)
    }

    /// A model over the fake: these contexts, no settings, no memory.
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

    private func until(_ timeout: TimeInterval = 5, _ what: String = "", _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: The model

    func testThePageFollowsTheContextsPodsWhileItShows() async throws {
        let model = model([Self.context("fake-dev", namespace: "shop"), Self.context("fake-prod")], current: "fake-dev")
        XCTAssertFalse(model.contextsRead, "nothing read before a page shows")
        model.show()
        try await until(5, "listed") { model.pods.count == 2 }
        XCTAssertEqual(model.selectedName, "fake-dev", "kubectl's current")
        XCTAssertEqual(model.scope, .namespace("shop"), "the context's own namespace")
        XCTAssertEqual(model.pods.sorted.map(\.id.description), ["shop/api-1", "shop/web-1"])
        XCTAssertEqual(model.podState, .live)
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["includeObject"] == "None" }, "rows only")
        try await until(5, "namespaces") { model.namespaces == ["payments", "shop"] }
        XCTAssertEqual(model.version?.minorNumber, 34)

        // The watch: one added, one failing, one gone — in batches.
        api.addPod("cache-0", namespace: "shop")
        api.updatePod("web-1", namespace: "shop") { $0.status = "Error" }
        try await until(5, "changes") { model.pods.count == 3 && model.pods[KubeRowID(namespace: "shop", name: "web-1")]?.cells[2] == .text("Error") }
        api.deletePod("cache-0", namespace: "shop")
        try await until(5, "deleted") { model.pods.count == 2 }
        XCTAssertNil(model.anchors[KubeRowID(namespace: "shop", name: "cache-0")], "its age forgotten with it")
        XCTAssertNotNil(model.anchors[KubeRowID(namespace: "shop", name: "web-1")]?.said, "rows only: the Age cell, counted on")

        // All namespaces: two web-1s, each with its creation time.
        model.setScope(.all)
        try await until(5, "all") { model.pods.count == 3 }
        XCTAssertEqual(model.pods.sorted.map(\.id.description), ["payments/web-1", "shop/api-1", "shop/web-1"])
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/pods" && $0.query["includeObject"] == "Metadata" })
        XCTAssertNotNil(model.anchors[KubeRowID(namespace: "payments", name: "web-1")]?.created)

        // Another context opens on its own namespace; the first keeps its pick.
        model.select("fake-prod")
        XCTAssertEqual(model.scope, .namespace("default"), "kubectl's default for a context with none")
        try await until(5, "fake-prod listed") { model.podState == .live }
        XCTAssertEqual(model.pods.count, 0)
        model.select("fake-dev")
        XCTAssertEqual(model.scope, .all)

        // Hidden, it reads nothing.
        try await until(5, "watching") { self.api.openWatches == 1 }
        model.hide()
        try await until(5, "watch closed") { self.api.openWatches == 0 }
        XCTAssertEqual(model.podState, .idle)
        api.forgetRequests()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(api.requests, [], "nothing asked while nobody looks")
    }

    func testAFailedListSaysWhyAndStops() async throws {
        let model = model([Self.context("fake-dev", namespace: "shop")])
        api.failCredentials()
        model.show()
        defer { model.hide() }
        try await until(5, "failed") {
            if case .failed = model.podState { return true }
            return false
        }
        guard case .failed(let reason, let problem) = model.podState else { return }
        XCTAssertEqual(problem, .credentials("getting credentials: exec: executable aws failed with exit code 255"))
        XCTAssertTrue(reason.contains("couldn't get credentials"), reason)
    }

    /// A unit test's model reads no kubeconfig of the user's, whatever the
    /// settings name: AppEnvironment's guard, through the model's own loader.
    func testAUnitTestsModelReadsNoKubeconfig() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OVERTERM_KUBECONFIG"] != nil, "a run of its own fake clusters")
        XCTAssertTrue(AppEnvironment.guardsKubeconfig)
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(AppEnvironment.kubeconfigs(extra: ["~/.kube/config", home.appendingPathComponent(".kube").path]), [])
        let proxies = KubeProxies()
        defer { proxies.closeAll() }
        let model = KubernetesModel(proxies: proxies)
        model.readConfiguration = { KubernetesModel.Configuration(extraKubeconfigs: ["~/.kube/config"]) }
        model.watchesSettings = false
        model.remembersSelection = false
        model.show()
        defer { model.hide() }
        try await until(5, "read") { model.contextsRead }
        XCTAssertEqual(model.contexts.contexts, [])
        XCTAssertEqual(model.contexts.files, [], "no file read")
        XCTAssertNil(model.selectedName)
        let connected = await proxies.connected
        XCTAssertEqual(connected, [], "no proxy started")
        // And told the user's file outright, the loader refuses it.
        let refused = KubeContextList.load(files: [home.appendingPathComponent(".kube/config")], settings: [:], guarded: true, home: home)
        XCTAssertEqual(refused.files, [])
        XCTAssertEqual(refused.contexts, [])
    }

    func testWhichContextThePageOpensOn() {
        let list = KubeContextList(contexts: [Self.context("a"), Self.context("b"), Self.context("c")], current: "c")
        XCTAssertEqual(KubernetesModel.choose(in: list, kept: "a", remembered: "b", pinned: []), "a")
        XCTAssertEqual(KubernetesModel.choose(in: list, kept: "gone", remembered: "b", pinned: ["a"]), "b")
        XCTAssertEqual(KubernetesModel.choose(in: list, kept: nil, remembered: "gone", pinned: ["x", "a"]), "a")
        XCTAssertEqual(KubernetesModel.choose(in: list, kept: nil, remembered: nil, pinned: []), "c")
        XCTAssertEqual(KubernetesModel.choose(in: KubeContextList(contexts: [Self.context("a")]), kept: nil, remembered: nil, pinned: []), "a")
        XCTAssertNil(KubernetesModel.choose(in: KubeContextList(), kept: "a", remembered: "a", pinned: ["a"]))

        XCTAssertEqual(KubernetesModel.defaultScope(Self.context("x", namespace: "globex")), .namespace("globex"))
        XCTAssertEqual(
            KubernetesModel.defaultScope(Self.context("x", namespace: "globex", settings: KubeContextSettings(defaultNamespace: "mine"))), .namespace("mine"))
        XCTAssertEqual(KubernetesModel.defaultScope(Self.context("x")), .namespace("default"))
    }

    // MARK: The page

    func testThePageReadsTheServersRows() async throws {
        let model = model([Self.context("fake-dev", namespace: "shop"), Self.context("fake-prod", namespace: "shop")])
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "listed") { model.pods.count == 2 }

        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Status", "Restarts", "Age"], "the server's, priority 0")
        page.wide = true
        XCTAssertEqual(page.columns.map(\.title), ["Name", "Ready", "Status", "Restarts", "Age", "IP", "Node", "Nominated Node", "Readiness Gates"])
        page.wide = false

        XCTAssertEqual(page.failing.map(\.id.name), ["api-1"])
        XCTAssertEqual(page.failing.first?.exitReason, "CrashLoopBackOff")
        XCTAssertNil(page.band, "fake-dev isn't production")
        XCTAssertEqual(page.classLabel, "Remote · read-only")

        // The filter: text, a status, a namespace, negated.
        page.filter = "web"
        XCTAssertEqual(page.rows.map(\.id), ["shop/web-1"])
        page.filter = "status:crashloop"
        XCTAssertEqual(page.rows.map(\.id), ["shop/api-1"])
        page.filter = "-status:running ns:shop"
        XCTAssertEqual(page.rows.map(\.id), ["shop/api-1"])
        page.filter = ""

        // The order: by a column's values, numbers as numbers.
        let restarts = try XCTUnwrap(page.columns.first { $0.title == "Restarts" })
        page.sort = ResourceSort(column: restarts.id, ascending: false)
        XCTAssertEqual(page.rows.map(\.id), ["shop/api-1", "shop/web-1"])
        page.sort = ResourceSort(column: restarts.id, ascending: true)
        XCTAssertEqual(page.rows.map(\.id), ["shop/web-1", "shop/api-1"])
        page.sort = nil
        XCTAssertEqual(page.rows.map(\.id), ["shop/api-1", "shop/web-1"], "by namespace, then name")

        // Only reads in the menu.
        let verbs = page.verbs(for: ["shop/api-1"]).map(\.title)
        XCTAssertEqual(verbs, ["Copy Name", "Copy Namespace/Name"])

        // Keys.
        XCTAssertTrue(page.press("w"))
        XCTAssertTrue(page.wide)
        XCTAssertTrue(page.press("0"))
        XCTAssertEqual(model.scope, .all)
        try await until(5, "all") { model.pods.count == 3 }
        XCTAssertEqual(page.columns.first?.title, "Namespace", "kubectl get -A's")
        XCTAssertTrue(page.press("?"))
        XCTAssertTrue(page.cheatSheet)
        XCTAssertTrue(page.press("q"), "an open sheet takes any key")
        XCTAssertFalse(page.cheatSheet)
        XCTAssertFalse(page.press("q"), "not a key of the list's")
        XCTAssertTrue(page.press("1"))
        XCTAssertEqual(page.section, .pods)

        // Production: the band.
        model.select("fake-prod")
        XCTAssertEqual(page.band, "PRODUCTION · fake-prod · read-only: Overterm changes nothing here")
        XCTAssertEqual(page.classLabel, "Production · read-only")
    }

    func testTheKeysAreWellFormed() {
        XCTAssertTrue(KubernetesKey.isWellFormed)
        XCTAssertEqual(KubernetesKey.of("1")?.section, .pods)
        XCTAssertNil(KubernetesKey.of("e"), "no shell yet — and no key that writes")
    }

    // MARK: Ages

    func testAgesAsKubectlSaysThem() {
        let cases: [(TimeInterval, String)] = [
            (0, "0s"), (59, "59s"), (119, "119s"), (120, "2m"), (125, "2m5s"), (600, "10m"), (179 * 60, "179m"), (3 * 3600, "3h"),
            (3 * 3600 + 12 * 60, "3h12m"), (8 * 3600, "8h"), (47 * 3600, "47h"), (48 * 3600, "2d"), (51 * 3600, "2d3h"), (8 * 86400, "8d"),
            (400 * 86400, "400d"), (730 * 86400, "2y"), (742 * 86400, "2y12d"), (3000 * 86400, "8y"),
        ]
        for (seconds, said) in cases { XCTAssertEqual(KubeAge.format(seconds), said, "\(seconds)") }
        XCTAssertEqual(KubeAge.format(-5), "<invalid>")
        XCTAssertEqual(KubeAge.seconds("2d3h"), 51 * 3600)
        XCTAssertEqual(KubeAge.seconds("5m30s"), 330)
        XCTAssertEqual(KubeAge.seconds("3y12d"), (3 * 365 + 12) * 86400)
        XCTAssertNil(KubeAge.seconds("<unknown>"))
        XCTAssertNil(KubeAge.seconds("5"))
        XCTAssertNil(KubeAge.seconds(""))

        let received = Date(timeIntervalSince1970: 1_000_000)
        let said = KubeAge.Anchor(created: nil, said: 300, received: received)
        XCTAssertEqual(said.age(at: received.addingTimeInterval(60)), 360, "what it said, and since")
        let created = KubeAge.Anchor(created: received.addingTimeInterval(-90), said: 300, received: received)
        XCTAssertEqual(created.age(at: received.addingTimeInterval(10)), 100, "the creation time wins")
        XCTAssertNil(KubeAge.Anchor(created: nil, said: nil, received: received).age(at: received))
    }

    func testARowCarriesItsCreationTimeWhenItHasMetadata() throws {
        let table = try KubeTableReader.read(
            [
                "kind": "Table",
                "columnDefinitions": [["name": "Name", "type": "string", "format": "name"], ["name": "Age", "type": "string"]],
                "rows": [
                    ["cells": ["a", "5m"], "object": ["metadata": ["name": "a", "namespace": "shop", "creationTimestamp": "2026-11-03T10:00:00Z"]]],
                    ["cells": ["b", "2d"]],
                ],
            ], namespace: nil)
        XCTAssertEqual(table.rows[0].created, try Date("2026-11-03T10:00:00Z", strategy: .iso8601))
        XCTAssertNil(table.rows[1].created)
        XCTAssertEqual(KubeAge.anchor(table.rows[1], columns: table.columns, received: Date()).said, 2 * 86400)
    }
}
