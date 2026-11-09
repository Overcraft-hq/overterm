import XCTest

@testable import Overterm

/// A context's settings in one sheet: read from `kubernetes.contexts` and
/// `kubernetes.agentWrites`, written back with the entry's other fields and
/// the other entries kept, checked by SettingsSchema; production's session
/// switch never a setting.
@MainActor
final class KubeContextSettingsDraftTests: XCTestCase {
    private let context = KubeWritesTests.context
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-ctxsettings-\(UUID().uuidString)")
    private var url: URL { dir.appendingPathComponent("settings.json") }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testItReadsTheEntryAndTheAgentsList() {
        let contexts = SettingValue.entries([
            "kind-fake": [
                "class": .string("remote"), "writable": .bool(true), "metrics": .string("prometheus"), "prometheus": .string("monitoring/prom:9090"),
                "nodeShell": .bool(true), "nodeShellImage": .string("acme/node-tools:1"), "defaultNamespace": .string("shop"),
            ]
        ])
        let draft = KubeContextSettingsDraft(context: context("kind-fake", KubeContextSettings(), false), contexts: contexts, agentWrites: ["kind-fake"])
        XCTAssertEqual(draft.contextClass, .remote)
        XCTAssertEqual(draft.classByName, .local, "what its name says, for unset")
        XCTAssertEqual(draft.writable, true)
        XCTAssertEqual(draft.metrics, .prometheus)
        XCTAssertEqual(draft.prometheus, "monitoring/prom:9090")
        XCTAssertTrue(draft.nodeShell)
        XCTAssertEqual(draft.nodeShellImage, "acme/node-tools:1")
        XCTAssertEqual(draft.defaultNamespace, "shop")
        XCTAssertTrue(draft.agentWrites)
        XCTAssertFalse(draft.applyOnProduction)
        let none = KubeContextSettingsDraft(context: context("fake-dev", KubeContextSettings(), false), contexts: nil, agentWrites: [])
        XCTAssertNil(none.contextClass)
        XCTAssertNil(none.writable)
        XCTAssertFalse(none.agentWrites)
        XCTAssertEqual(none.writableSaid, "Read-only (a remote context's default).")
    }

    func testItWritesOnlyItsOwnFieldsKeepingTheRest() throws {
        let contexts = SettingValue.entries([
            "kind-fake": ["displayName": .string("Kind"), "debugImage": .string("alpine:3.20"), "writable": .bool(false)],
            "fake-dev": ["class": .string("remote")],
        ])
        var draft = KubeContextSettingsDraft(context: context("kind-fake", KubeContextSettings(), false), contexts: contexts, agentWrites: ["fake-dev"])
        draft.writable = nil
        draft.metrics = KubeMetricsSource.none
        draft.prometheus = "  "
        draft.defaultNamespace = " shop "
        draft.agentWrites = true
        let (written, agents) = try draft.applied(contexts: contexts, agentWrites: ["fake-dev"]).get()
        XCTAssertEqual(
            written,
            .entries([
                "kind-fake": ["displayName": .string("Kind"), "debugImage": .string("alpine:3.20"), "metrics": .string("none"), "defaultNamespace": .string("shop")],
                "fake-dev": ["class": .string("remote")],
            ]), "unset fields out, blank text out, the other fields and entries as they were")
        XCTAssertEqual(agents, ["fake-dev", "kind-fake"])
        draft.agentWrites = false
        XCTAssertEqual(try draft.applied(contexts: contexts, agentWrites: ["fake-dev", "kind-fake"]).get().agentWrites, ["fake-dev"])

        // An entry left with nothing goes.
        var bare = KubeContextSettingsDraft(context: context("fake-dev", KubeContextSettings(), false), contexts: contexts, agentWrites: [])
        bare.contextClass = nil
        XCTAssertEqual(try bare.applied(contexts: contexts, agentWrites: []).get().contexts.entries?["fake-dev"], nil)
    }

    func testBadValuesAreRefusedBeforeAnythingIsWritten() {
        var draft = KubeContextSettingsDraft(context: context("kind-fake", KubeContextSettings(), false), contexts: nil, agentWrites: [])
        draft.prometheus = "prometheus"
        XCTAssertNotNil(draft.validation)
        guard case .failure = draft.applied(contexts: nil, agentWrites: []) else { return XCTFail("taken") }
        draft.prometheus = "monitoring/prometheus-server:80"
        draft.nodeShellImage = "node tools; id"
        XCTAssertEqual(draft.validation, "node tools; id isn't an image reference (name[:tag][@digest]).")
        draft.nodeShellImage = ""
        draft.defaultNamespace = "Shop"
        XCTAssertEqual(draft.validation, "Default namespace: Lowercase only: shop?")
        draft.defaultNamespace = "shop"
        XCTAssertNil(draft.validation)
    }

    func testProductionsSwitchIsShownNeverWritten() throws {
        let prod = context("fake-prod", KubeContextSettings(), true)
        var draft = KubeContextSettingsDraft(context: prod, contexts: nil, agentWrites: [])
        XCTAssertTrue(draft.isProduction)
        XCTAssertTrue(draft.sessionWrites)
        XCTAssertTrue(draft.writableSaid.contains("never by a setting"), draft.writableSaid)
        draft.writable = true
        draft.applyOnProduction = true
        let written = try draft.applied(contexts: nil, agentWrites: []).get().contexts
        XCTAssertEqual(written, .entries(["fake-prod": ["applyOnProduction": .bool(true)]]), "writable is no switch on production; the session's never a field")
        let fields = written.entries?["fake-prod"] ?? [:]
        XCTAssertNil(fields["writable"])
        XCTAssertFalse(fields.keys.contains { $0.lowercased().contains("session") })
    }

    func testSavedThroughSettingsInPlaceCommentsKept() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\n  // mine\n  \"kubernetes.contexts\": {\"fake-dev\": {\"class\": \"remote\"}}, // why\n  \"general.restoreTabs\": false\n}\n".write(
            to: url, atomically: true, encoding: .utf8)
        let settings = Settings(url: url, watch: false)
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: [context("fake-dev", KubeContextSettings(), false), context("kind-fake", KubeContextSettings(), false)], current: "kind-fake")
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let page = KubernetesPageModel(model: model)
        page.settingsStore = settings
        page.openContextSettings(list.contexts[1])
        XCTAssertEqual(page.contextSettingsDraft?.context, "kind-fake")
        XCTAssertTrue(page.press("x") == false && page.contextSettingsDraft != nil, "the sheet's fields have the keys")
        page.contextSettingsDraft?.writable = false
        page.contextSettingsDraft?.agentWrites = true
        page.contextSettingsDraft?.prometheus = "bad"
        page.saveContextSettings()
        XCTAssertNotNil(page.contextSettingsDraft?.problem, "refused, the sheet stays")
        XCTAssertFalse(text().contains("kind-fake"), "nothing written")
        page.contextSettingsDraft?.prometheus = ""
        page.saveContextSettings()
        XCTAssertNil(page.contextSettingsDraft, "saved, closed")
        XCTAssertTrue(text().contains("// mine") && text().contains("// why"), text())
        XCTAssertTrue(text().contains(#""kind-fake": {"writable": false}"#) && text().contains(#""fake-dev": {"class": "remote"}"#), text())
        XCTAssertEqual(settings.value("kubernetes.agentWrites"), .list(["kind-fake"]))
        XCTAssertEqual(settings.kubernetesContexts["kind-fake"]?.writable, false)
        page.openContextSettings(list.contexts[1])
        XCTAssertTrue(page.press("\u{1B}"))
        XCTAssertNil(page.contextSettingsDraft, "Esc closes it")
    }

    private func page(_ settings: Settings, _ contexts: [KubeContext]) -> KubernetesPageModel {
        let model = KubernetesModel(proxies: KubeProxies())
        let list = KubeContextList(contexts: contexts, current: contexts[0].name)
        model.load = { _ in list }
        model.readConfiguration = { KubernetesModel.Configuration() }
        model.watchesSettings = false
        model.remembersSelection = false
        let page = KubernetesPageModel(model: model)
        page.settingsStore = settings
        return page
    }

    /// The file's own values are the base: a field this build doesn't know,
    /// or can't use, in another entry — or in this one — is written back.
    func testFieldsThisBuildCantReadAreKept() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {
          "kubernetes.contexts": {
            // prod's: never writable
            "acme-prod": {"clas": "production", "futureField": "x"},
            "fake-dev": {"class": "remote", "writable": "yes"}
          }
        }

        """.write(to: url, atomically: true, encoding: .utf8)
        let settings = Settings(url: url, watch: false)
        XCTAssertNil(settings.value("kubernetes.contexts")?.entries?["acme-prod"]?["clas"], "fitted: the typo isn't applied")
        let dev = context("fake-dev", KubeContextSettings(), false)
        let page = page(settings, [dev])
        page.openContextSettings(dev)
        page.contextSettingsDraft?.defaultNamespace = "shop"
        page.saveContextSettings()
        XCTAssertNil(page.contextSettingsDraft, "saved: \(page.contextSettingsDraft?.problem ?? "")")
        let entries = try XCTUnwrap(settings.fileValue("kubernetes.contexts")?.entries)
        XCTAssertEqual(entries["acme-prod"], ["clas": .string("production"), "futureField": .string("x")], "another entry's unknown fields kept")
        XCTAssertEqual(entries["fake-dev"]?["writable"], .string("yes"), "this entry's bad value isn't the sheet's to drop")
        XCTAssertEqual(entries["fake-dev"]?["defaultNamespace"], .string("shop"))
        XCTAssertTrue(text().contains("// prod's: never writable"), text())
    }

    /// A context's saved queries (`charts`, a list of objects) aren't the
    /// sheet's: a Save writes them back as the file has them.
    func testSavedQueriesAreKeptByASave() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"""
        {
          "kubernetes.contexts": {
            "fake-dev": {"metrics": "prometheus", "charts": [{"title": "Requests", "query": "sum(rate(a{namespace=\"$ns\",pod=~\"$pod\"}[$w]))", "unit": "perSecond"}]}
          }
        }

        """#.write(to: url, atomically: true, encoding: .utf8)
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.kubernetesContexts["fake-dev"]?.charts.map(\.title), ["Requests"])
        let dev = context("fake-dev", KubeContextSettings(), false)
        let page = page(settings, [dev])
        page.openContextSettings(dev)
        page.contextSettingsDraft?.defaultNamespace = "shop"
        page.saveContextSettings()
        XCTAssertNil(page.contextSettingsDraft, "saved: \(page.contextSettingsDraft?.problem ?? "")")
        XCTAssertEqual(settings.kubernetesContexts["fake-dev"]?.defaultNamespace, "shop")
        XCTAssertEqual(
            settings.kubernetesContexts["fake-dev"]?.charts,
            [KubeSavedChart(title: "Requests", query: #"sum(rate(a{namespace="$ns",pod=~"$pod"}[$w]))"#, unit: .perSecond)], text())
    }

    /// Production made remote or local: asked in red, the name typed, and
    /// only then written.
    func testMakingProductionLessStrictNeedsItsNameTyped() throws {
        let prod = context("acme-prod", KubeContextSettings(), false)
        var draft = KubeContextSettingsDraft(context: prod, contexts: nil, agentWrites: [])
        XCTAssertEqual(draft.classByName, .production)
        XCTAssertFalse(draft.lessStrict(entry: nil), "unchanged")
        draft.contextClass = .local
        draft.agentWrites = true
        XCTAssertTrue(draft.lessStrict(entry: nil))
        XCTAssertTrue(draft.lessStrictSaid.contains("writable — by this setting"), draft.lessStrictSaid)
        XCTAssertTrue(draft.lessStrictSaid.contains("agents may change it"), draft.lessStrictSaid)
        XCTAssertTrue(draft.lessStrictSaid.hasSuffix("Type acme-prod to confirm."), draft.lessStrictSaid)
        guard case .failure(let refused) = draft.applied(contexts: nil, agentWrites: []) else { return XCTFail("written without the name") }
        XCTAssertTrue(refused.reason.contains("needs its name typed"), refused.reason)
        draft.typedName = "acme-pro"
        guard case .failure = draft.applied(contexts: nil, agentWrites: []) else { return XCTFail("a wrong name taken") }
        draft.typedName = " acme-prod "
        XCTAssertEqual(try draft.applied(contexts: nil, agentWrites: []).get().contexts, .entries(["acme-prod": ["class": .string("local")]]))

        // Production by its entry, not its name: the same.
        let dev = context("fake-dev", KubeContextSettings(), false)
        let saved = SettingValue.entries(["fake-dev": ["class": .string("production")]])
        var byEntry = KubeContextSettingsDraft(context: dev, contexts: saved, agentWrites: [])
        byEntry.contextClass = nil
        XCTAssertEqual(byEntry.resolvedClass, .remote)
        XCTAssertTrue(byEntry.lessStrict(entry: nil))
        XCTAssertTrue(byEntry.lessStrictSaid.contains("stays read-only"), byEntry.lessStrictSaid)
        guard case .failure = byEntry.applied(contexts: saved, agentWrites: []) else { return XCTFail("written without the name") }
        // Made production: nothing to ask.
        var stricter = KubeContextSettingsDraft(context: dev, contexts: nil, agentWrites: [])
        stricter.contextClass = .production
        XCTAssertFalse(stricter.lessStrict(entry: nil))
    }

    func testThePageAsksBeforeMakingProductionLessStrict() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\n}\n".write(to: url, atomically: true, encoding: .utf8)
        let settings = Settings(url: url, watch: false)
        let prod = context("acme-prod", KubeContextSettings(), false)
        let page = page(settings, [prod])
        page.openContextSettings(prod)
        page.contextSettingsDraft?.contextClass = .local
        page.saveContextSettings()
        XCTAssertEqual(page.contextSettingsDraft?.confirmingLessStrict, true, "asked first")
        XCTAssertNil(settings.fileValue("kubernetes.contexts")?.entries?["acme-prod"], "nothing written")
        page.saveContextSettings()
        XCTAssertNotNil(page.contextSettingsDraft?.problem, "no name typed: refused")
        XCTAssertNil(settings.fileValue("kubernetes.contexts")?.entries?["acme-prod"])
        page.contextSettingsDraft?.typedName = "acme-prod"
        page.saveContextSettings()
        XCTAssertNil(page.contextSettingsDraft, "saved, closed")
        XCTAssertEqual(settings.fileValue("kubernetes.contexts")?.entries?["acme-prod"], ["class": .string("local")])
    }
}
