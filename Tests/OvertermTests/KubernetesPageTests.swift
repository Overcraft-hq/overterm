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

        XCTAssertEqual(KubernetesModel.defaultScope(Self.context("x", namespace: "team")), .namespace("team"))
        XCTAssertEqual(
            KubernetesModel.defaultScope(Self.context("x", namespace: "team", settings: KubeContextSettings(defaultNamespace: "mine"))), .namespace("mine"))
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
        XCTAssertEqual(KubernetesKey.of("n"), .namespace)
        XCTAssertEqual(KubernetesKey.of("c"), .context)
        XCTAssertNil(KubernetesKey.of("N"), "case matters")
        XCTAssertNil(KubernetesKey.of("e"), "no shell yet — and no key that writes")
    }

    // MARK: Navigating

    func testNAndCPickANamespaceAndAContext() async throws {
        let model = model([Self.context("fake-dev", namespace: "shop"), Self.context("fake-prod", namespace: "payments")], current: "fake-dev")
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "namespaces") { model.namespaces == ["payments", "shop"] }

        // n: all of them first, the context's own, the server's; the one showing highlighted.
        let focus = page.focusList
        XCTAssertTrue(page.press("n"))
        var picker = try XCTUnwrap(page.picker)
        XCTAssertEqual(picker.kind, .namespace)
        XCTAssertEqual(picker.results.map(\.title), ["All namespaces", "shop", "payments"])
        XCTAssertEqual(picker.selected?.title, "shop")
        page.picker?.query = "pay"
        picker = try XCTUnwrap(page.picker)
        XCTAssertEqual(picker.results.map(\.title), ["payments", "pay"], "what is typed, after what it finds")
        XCTAssertTrue(picker.results[1].typed)
        page.choosePicked()
        XCTAssertNil(page.picker)
        XCTAssertEqual(model.scope, .namespace("payments"))
        XCTAssertGreaterThan(page.focusList, focus, "the list has the keyboard again")
        try await until(5, "payments' pods") { model.pods.sorted.map(\.id.description) == ["payments/web-1"] }

        // A name nobody listed, typed.
        page.openPicker(.namespace)
        page.picker?.query = "Staging-2"
        XCTAssertEqual(page.picker?.results.map(\.title), ["staging-2"])
        page.choosePicked()
        XCTAssertEqual(model.scope, .namespace("staging-2"))
        try await until(5, "listed") { model.podState == .live }
        XCTAssertEqual(model.pods.count, 0)
        page.openPicker(.namespace)
        XCTAssertEqual(page.picker?.selected?.title, "staging-2", "the one showing is in the list, typed")
        page.picker?.query = "not a name"
        XCTAssertEqual(page.picker?.results.map(\.title), [], "spaces: no namespace is called that")
        page.choosePicked()
        XCTAssertNotNil(page.picker, "nothing to pick: it stays")
        page.closePicker()
        XCTAssertNil(page.picker)

        // c: every context, the one showing highlighted.
        XCTAssertTrue(page.press("c"))
        XCTAssertEqual(page.picker?.results.map(\.title), ["fake-dev", "fake-prod"])
        XCTAssertEqual(page.picker?.selected?.title, "fake-dev")
        XCTAssertEqual(page.picker?.results.last?.detail, "Production · read-only")
        XCTAssertTrue(page.picker?.results.last?.production == true)
        page.picker?.move(1)
        XCTAssertEqual(page.picker?.selected?.title, "fake-prod")
        page.picker?.move(1)
        XCTAssertEqual(page.picker?.selected?.title, "fake-dev", "round again")
        page.picker?.query = "prod"
        page.choosePicked()
        XCTAssertEqual(model.selectedName, "fake-prod")
        XCTAssertEqual(model.scope, .namespace("payments"))
        XCTAssertNotNil(page.band)
        page.openPicker(.context)
        page.picker?.query = "staging"
        XCTAssertEqual(page.picker?.results, [], "a context isn't typed")
        page.closePicker()
    }

    /// A user held to a namespace can't list them (a context that carries
    /// one often is): the picker says so, offers the context's own,
    /// and takes a name typed first.
    func testARefusedNamespaceListIsTyped() async throws {
        api.forbidden = ["namespaces"]
        let model = model([Self.context("team-dev", namespace: "shop")])
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        try await until(5, "refused") { model.namespacesRefused != nil }
        XCTAssertEqual(model.namespaces, [])
        XCTAssertEqual(model.pods.count, 2, "its own namespace's pods are read all the same")
        XCTAssertTrue(page.press("n"))
        let picker = try XCTUnwrap(page.picker)
        XCTAssertEqual(picker.note, "Listing namespaces isn't allowed here: type one.")
        XCTAssertEqual(picker.results.map(\.title), ["All namespaces", "shop"])
        XCTAssertEqual(picker.results.last?.detail, "the context's")
        page.picker?.query = "s"
        XCTAssertEqual(page.picker?.selected?.title, "s", "refused, what is typed comes first")
        page.picker?.query = "payments"
        page.choosePicked()
        XCTAssertEqual(model.scope, .namespace("payments"))
        try await until(5, "payments' pods") { model.pods.sorted.map(\.id.description) == ["payments/web-1"] }
    }

    /// The picker follows the namespaces that come in after it opened.
    func testAnOpenPickerFollowsTheNamespacesListed() async throws {
        api.forbidden = ["namespaces"]
        let model = model([Self.context("fake-dev", namespace: "shop")])
        let page = KubernetesPageModel(model: model)
        model.show()
        defer { model.hide() }
        page.openPicker(.context)
        XCTAssertNil(page.picker, "no context read yet")
        try await until(5, "refused") { model.namespacesRefused != nil }
        page.openPicker(.namespace)
        XCTAssertNotNil(page.picker?.note)
        page.picker?.query = "pa"
        XCTAssertEqual(page.picker?.selected?.title, "pa", "typed, first")
        api.forbidden = []
        model.retry()
        try await until(5, "listed") { page.picker?.items.map(\.title).contains("payments") == true }
        XCTAssertNil(page.picker?.note, "allowed now")
        XCTAssertEqual(page.picker?.query, "pa", "what is typed kept")
        XCTAssertEqual(page.picker?.results.first?.title, "payments", "what it finds first")
        XCTAssertEqual(page.picker?.results.last?.typed, true, "what is typed after")
    }

    func testLabelWordsGoToTheServer() async throws {
        api.addPod("web-2", namespace: "shop", labels: ["app": "web", "tier": "fe"])
        api.addPod("db-0", namespace: "shop", labels: ["app": "db"])
        let model = model([Self.context("fake-dev", namespace: "shop")])
        let page = KubernetesPageModel(model: model)
        page.selectorDelay = .milliseconds(20)
        model.show()
        page.visible = true
        defer { model.hide() }
        try await until(5, "listed") { model.pods.count == 4 }

        page.filter = "label:app=web"
        try await until(5, "selected") { model.pods.sorted.map(\.id.name) == ["web-2"] }
        XCTAssertEqual(model.labelSelector, "app=web")
        XCTAssertTrue(api.requests.contains { $0.path == "/api/v1/namespaces/shop/pods" && $0.query["labelSelector"] == "app=web" }, "\(api.requests)")
        XCTAssertEqual(page.rows.map(\.id), ["shop/web-2"], "the rows aren't filtered by it again")

        page.filter = "-label:app=web label:app"
        try await until(5, "not web") { model.pods.sorted.map(\.id.name) == ["db-0"] }
        XCTAssertEqual(model.labelSelector, "app!=web,app")

        // Text and a label: the server's pods, then the text on them.
        api.addPod("web-3", namespace: "shop", labels: ["app": "web"])
        page.filter = "label:app=web 3"
        try await until(5, "both") { model.pods.count == 2 }
        XCTAssertEqual(page.rows.map(\.id), ["shop/web-3"])

        // Typing on: only once it stops is the server asked.
        api.forgetRequests()
        page.selectorDelay = .milliseconds(300)
        page.filter = "label:t"
        page.filter = "label:ti"
        page.filter = "label:tier=fe"
        try await until(5, "fe") { model.pods.sorted.map(\.id.name) == ["web-2"] }
        XCTAssertEqual(Set(api.requests.compactMap { $0.query["labelSelector"] }), ["tier=fe"], "\(api.requests)")

        // What isn't a selector asks nothing, and says so.
        page.selectorDelay = .milliseconds(20)
        page.filter = "label:=x"
        XCTAssertEqual(page.labelReading.refused, ["label:=x"])
        try await until(5, "every pod") { model.pods.count == 5 }
        XCTAssertNil(model.labelSelector)
        page.filter = ""
        page.applySelector()
        XCTAssertNil(model.labelSelector)
    }

    /// Two windows' pages share the app's one list: the one that asked
    /// last has it, the other says so; a page that hides gives it back, so
    /// the ⌃⌘J switcher after it lists every pod.
    func testALabelSelectorBelongsToThePageShowingIt() async throws {
        api.addPod("web-2", namespace: "shop", labels: ["app": "web"])
        let model = model([Self.context("fake-dev", namespace: "shop")])
        let a = KubernetesPageModel(model: model)
        let b = KubernetesPageModel(model: model)
        a.selectorDelay = .milliseconds(20)
        b.selectorDelay = .milliseconds(20)
        model.show()
        defer { model.hide() }
        a.visible = true
        b.visible = true
        try await until(5, "listed") { model.pods.count == 3 }

        a.filter = "label:app=web"
        try await until(5, "a's") { model.pods.sorted.map(\.id.name) == ["web-2"] }
        XCTAssertTrue(a.listIsOurs)
        XCTAssertFalse(b.listIsOurs, "b's empty filter isn't what the list was asked with")

        // b typing (or its window becoming key) takes the list; a says so.
        b.filter = "x"
        try await until(5, "b's") { model.pods.count == 3 }
        XCTAssertNil(model.labelSelector)
        XCTAssertTrue(b.listIsOurs)
        XCTAssertFalse(a.listIsOurs, "a's field still says label:app=web")

        a.applySelector()
        try await until(5, "a's again") { model.pods.count == 1 }
        // b hiding leaves a's alone.
        b.visible = false
        XCTAssertEqual(model.labelSelector, "app=web")
        XCTAssertTrue(a.listIsOurs)
        // A hidden page's typing asks for nothing.
        b.filter = "label:app=db"
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.labelSelector, "app=web")

        // a hides: what holds the model on (the switcher) gets every pod.
        model.show()
        a.visible = false
        XCTAssertNil(model.labelSelector)
        try await until(5, "every pod") { model.pods.count == 3 }
        model.hide()

        // Shown again, a's filter asks again.
        a.visible = true
        try await until(5, "a's once more") { model.pods.count == 1 }
        XCTAssertTrue(a.listIsOurs)
    }

    /// The last viewer gone, no selector is left for whoever looks next.
    func testTheLastHideDropsTheSelector() async throws {
        let model = model([Self.context("fake-dev", namespace: "shop")])
        let page = KubernetesPageModel(model: model)
        model.show()
        page.visible = true
        page.filter = "label:app=web"
        page.applySelector()
        XCTAssertEqual(model.labelSelector, "app=web")
        model.hide()
        XCTAssertNil(model.labelSelector)
        XCTAssertNil(model.selectorOwner)
    }

    // MARK: Pure parts

    func testLabelSelectorWords() {
        func read(_ text: String) -> KubeLabelSelector.Reading { KubeLabelSelector.read(text) }
        XCTAssertEqual(read("web").selector, nil)
        XCTAssertEqual(read("label:app=web").selector, "app=web")
        XCTAssertEqual(read("l:app==web").selector, "app=web")
        XCTAssertEqual(read("label:app!=web").selector, "app!=web")
        XCTAssertEqual(read("-label:app=web").selector, "app!=web")
        XCTAssertEqual(read("-label:app!=web").selector, "app=web")
        XCTAssertEqual(read("label:app").selector, "app")
        XCTAssertEqual(read("-label:app").selector, "!app")
        XCTAssertEqual(read("label:!app").selector, "!app")
        XCTAssertEqual(read("-label:!app").selector, "app")
        XCTAssertEqual(read("label:App=Web").selector, "App=Web", "as typed: labels are case-sensitive")
        XCTAssertEqual(read("label:app=web,tier=fe label:release").selector, "app=web,tier=fe,release")
        XCTAssertEqual(read("label:app.kubernetes.io/name=api").selector, "app.kubernetes.io/name=api")
        XCTAssertEqual(read("label:app=").selector, "app=", "an empty value is one")
        XCTAssertEqual(read("label:").selector, nil, "no value: nothing (ResourceFilter)")
        for refused in ["label:=x", "label:a=b=c", "label:a,", "-label:a=1,b=2", "label:-a", "label:Upper.Case/x=1", "label:a=" + String(repeating: "v", count: 64)] {
            XCTAssertEqual(read(refused), KubeLabelSelector.Reading(selector: nil, refused: [refused]), refused)
        }
        XCTAssertEqual(read("label:app=web label:=x"), KubeLabelSelector.Reading(selector: "app=web", refused: ["label:=x"]))
    }

    func testThePickersLists() {
        let namespaces = KubePicker.namespaces(
            listed: ["kube-system", "payments", "shop"], favourites: ["shop"], own: "team", current: .namespace("payments"), refused: nil)
        XCTAssertEqual(namespaces.items.map(\.title), ["All namespaces", "shop", "team", "payments", "kube-system"])
        XCTAssertEqual(namespaces.items.map(\.detail), ["0", "favourite", "the context's", nil, nil])
        XCTAssertEqual(namespaces.selected?.title, "payments")
        var all = KubePicker.namespaces(listed: [], favourites: [], own: nil, current: .all, refused: nil)
        XCTAssertEqual(all.selected?.choice, .scope(.all))
        all.query = "default"
        XCTAssertEqual(all.results.map(\.choice), [.scope(.namespace("default"))])
        XCTAssertEqual(all.chosen, .scope(.namespace("default")))
        all.query = "-x"
        XCTAssertEqual(all.results, [], "not a namespace's name")
        all.move(1)
        XCTAssertNil(all.chosen)

        XCTAssertEqual(KubePicker.typedNamespace(" Shop "), "shop")
        XCTAssertEqual(KubePicker.typedNamespace("a-1"), "a-1")
        for bad in ["", "a_b", "a.b", "-a", "a-", "a b", "ş", String(repeating: "a", count: 64)] {
            XCTAssertNil(KubePicker.typedNamespace(bad), bad)
        }

        let contexts = KubePicker.contexts(
            KubeContextList(
                contexts: [
                    Self.context("kind-fake"), Self.context("arn:aws:eks:eu-west-1:1:cluster/acme-prod", settings: KubeContextSettings(displayName: "acme")),
                ], current: "kind-fake"), selected: nil)
        XCTAssertEqual(contexts.items.map(\.title), ["kind-fake", "acme"])
        XCTAssertEqual(contexts.items.map(\.detail), ["Local · writable · current", "Production · read-only · arn:aws:eks:eu-west-1:1:cluster/acme-prod"])
        XCTAssertEqual(contexts.index, 0)
        XCTAssertEqual(contexts.items.map(\.production), [false, true])
    }

    /// ⌃⌘J is a menu shortcut of its own, and none of Ghostty v1.3.1's
    /// defaults (⌘J, ⇧⌘J, ⌥⇧⌘J and ⌃⇧⌘J are; ⇧⌥⌘J, Docker's pattern, is taken).
    func testTheSwitchersShortcutIsFree() throws {
        XCTAssertEqual(KeyCommands.byID["kubernetes.switch"]?.defaultKey, "ctrl+cmd+j")
        XCTAssertEqual(KeyCommands.all.filter { $0.defaultKey == "ctrl+cmd+j" }.map(\.id), ["kubernetes.switch"])
        let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("vendor/ghostty/src/config/Config.zig")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { throw XCTSkip("Ghostty's sources aren't here") }
        let lines = text.components(separatedBy: "\n").filter { $0.contains(".unicode = 'j'") }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let mods = line.components(separatedBy: ".mods = ").last ?? ""
            let ctrlAndSuper = (mods.contains(".ctrl = true") && mods.contains(".super = true")) || mods.contains("ctrlOrSuper(.{ .ctrl")
            XCTAssertFalse(ctrlAndSuper && !mods.contains(".shift") && !mods.contains(".alt"), line)
        }
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
