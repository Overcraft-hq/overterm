import XCTest

@testable import Overterm

@MainActor
final class SettingsTests: XCTestCase {
    /// A unit test's `Settings.shared` is a file of its own: a test that
    /// set `docker.enabled` once turned Docker off in the running app.
    func testTheSharedSettingsInAUnitTestAreNotTheUsers() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Overterm").appendingPathComponent("settings.json").standardizedFileURL.path
        XCTAssertNotEqual(Settings.sharedURL.standardizedFileURL.path, real)
        XCTAssertTrue(Settings.sharedURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-settings-\(UUID().uuidString)")
    private var url: URL { dir.appendingPathComponent("settings.json") }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDefaultsKeepTodaysBehaviour() {
        let settings = Settings(url: url, watch: false)
        XCTAssertTrue(settings.restoreTabs)
        XCTAssertTrue(settings.restoreScrollback)
        XCTAssertEqual(settings.scrollbackLines, 2000)
        XCTAssertEqual(settings.newTabDirectory, .current)
        XCTAssertEqual(settings.confirmClose, .always, "closing always asks unless changed")
        XCTAssertTrue(settings.notifications && settings.dockBadge && settings.checkForUpdates)
        XCTAssertEqual(settings.unfocusedPaneDim, 0.35)
        XCTAssertEqual(settings.editorFontSize, 13)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing written until something is set")
    }

    /// VS Code's way: only what differs from the default is in the file.
    func testOnlyWhatDiffersIsWritten() {
        let settings = Settings(url: url, watch: false)
        settings.set("general.confirmClose", .string("whenRunning"))
        settings.set("appearance.fontSize", .int(16))
        XCTAssertEqual(text(), "{\n  \"general.confirmClose\": \"whenRunning\",\n  \"appearance.fontSize\": 16\n}\n")
        let reopened = Settings(url: url, watch: false)
        XCTAssertEqual(reopened.confirmClose, .whenRunning)
        XCTAssertEqual(reopened.number("appearance.fontSize"), 16)
        settings.set("general.confirmClose", .string("always"))
        XCTAssertFalse(text().contains("confirmClose"), "set back to its default, it leaves the file")
        settings.set("appearance.fontSize", nil)
        XCTAssertEqual(text(), "{\n}\n")
    }

    /// A hand-written file keeps its comments, order and other lines.
    func testEditsInPlaceKeepComments() throws {
        try write(
            """
            {
              // my font
              "appearance.fontSize": 14, // big
              /* tabs */
              "general.newTabDirectory": "home"
            }

            """)
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.number("appearance.fontSize"), 14)
        settings.set("appearance.fontSize", .int(18))
        settings.set("general.confirmClose", .string("whenRunning"))
        XCTAssertEqual(
            text(),
            """
            {
              // my font
              "appearance.fontSize": 18, // big
              /* tabs */
              "general.newTabDirectory": "home",
              "general.confirmClose": "whenRunning"
            }

            """)
        settings.set("general.newTabDirectory", nil)
        XCTAssertFalse(text().contains("newTabDirectory"))
        XCTAssertTrue(text().contains("// my font"))
        XCTAssertEqual(Settings(url: url, watch: false).confirmClose, .whenRunning, "still parses (a trailing comma is fine)")
    }

    func testAOneLineFileIsRewrittenWhole() throws {
        try write("{\"appearance.fontSize\": 14}")
        let settings = Settings(url: url, watch: false)
        settings.set("general.confirmClose", .string("whenRunning"))
        XCTAssertEqual(Settings(url: url, watch: false).confirmClose, .whenRunning)
        XCTAssertEqual(Settings(url: url, watch: false).number("appearance.fontSize"), 14)
    }

    /// A file that doesn't parse: nothing in it applies, nothing writes over it.
    func testABrokenFileIsNeverWrittenOver() throws {
        let broken = "{\n  \"appearance.fontSize\": 14,\n  oops\n"
        try write(broken)
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.problems.count, 1)
        XCTAssertTrue(settings.problems[0].contains("doesn't parse"), settings.problems[0])
        XCTAssertNil(settings.number("appearance.fontSize"))
        settings.set("general.confirmClose", .string("whenRunning"))
        XCTAssertEqual(text(), broken)
        settings.save(text: "{\n  \"general.confirmClose\": \"whenRunning\"\n}\n")
        XCTAssertTrue(settings.problems.isEmpty)
        XCTAssertEqual(settings.confirmClose, .whenRunning)
    }

    /// Valid settings apply; the rest are listed, and their defaults hold.
    func testBadValuesAreListedNotApplied() throws {
        try write(
            """
            {
              "general.confirmClose": "sometimes",
              "appearance.fontSize": 99,
              "appearance.unfocusedPaneDim": 0.5,
              "editor.fontSize": 15,
              "general.restoreTabs": "yes",
              "something.else": true
            }
            """)
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.confirmClose, .always)
        XCTAssertNil(settings.number("appearance.fontSize"))
        XCTAssertEqual(settings.unfocusedPaneDim, 0.5)
        XCTAssertEqual(settings.editorFontSize, 15)
        XCTAssertTrue(settings.restoreTabs)
        XCTAssertEqual(settings.problems.count, 4, settings.problems.joined(separator: "\n"))
        XCTAssertTrue(settings.problems.contains { $0.contains("something.else") })
    }

    /// A list (the rail's order) is written on one line, read back as a
    /// list, and changed in place like any other value — comments kept.
    func testAListIsWrittenAndEditedInPlace() throws {
        try write(
            """
            {
              // mine
              "general.sidebarOrder": ["database", "files"], // db first
              "general.restoreTabs": false
            }

            """)
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.value("general.sidebarOrder")?.list, ["database", "files"])
        settings.set("general.sidebarOrder", .list(["git", "files"]))
        XCTAssertEqual(
            text(),
            """
            {
              // mine
              "general.sidebarOrder": ["git", "files"], // db first
              "general.restoreTabs": false
            }

            """)
        XCTAssertEqual(Settings(url: url, watch: false).value("general.sidebarOrder")?.list, ["git", "files"])
        settings.set("general.sidebarOrder", .list(SidebarPanel.allCases.map(\.rawValue)))
        XCTAssertFalse(text().contains("sidebarOrder"), "the default order leaves the file")
    }

    /// A list where a name or a flag belongs, or anything but names in a
    /// list, is a problem like any other bad value.
    func testAListIsCheckedLikeAnyValue() throws {
        try write(
            """
            {
              "general.sidebarOrder": [1, 2],
              "general.restoreTabs": ["yes"],
              "general.sidebarRail": "tiny"
            }
            """)
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.problems.count, 3, settings.problems.joined(separator: "\n"))
        XCTAssertEqual(settings.value("general.sidebarOrder")?.list, SidebarPanel.allCases.map(\.rawValue))
        XCTAssertTrue(settings.restoreTabs)
        XCTAssertEqual(SettingValue.list(["a\"b", "c"]).json, #"["a\"b", "c"]"#)
    }

    /// Kubernetes' settings: on by default, nothing else set; a free list
    /// (kubeconfigs, pinned contexts) read and written like the rail's.
    func testKubernetesDefaultsAndLists() throws {
        let settings = Settings(url: url, watch: false)
        XCTAssertTrue(settings.kubernetesEnabled)
        XCTAssertEqual(settings.kubernetesKubeconfigs, [])
        XCTAssertEqual(settings.kubernetesPinnedContexts, [])
        XCTAssertEqual(settings.kubernetesContexts, [:])
        XCTAssertEqual(settings.kubernetesMaxProxies, 4)
        XCTAssertEqual(settings.kubernetesProxyIdleMinutes, 10)
        XCTAssertEqual(settings.kubernetesKubectlPath, "", "found, not set")
        XCTAssertEqual(
            settings.kubernetesProxyConfiguration, KubeProxies.Configuration(maxProxies: 4, idleTime: 600, kubectlPath: "", extraKubeconfigs: []))
        settings.set("kubernetes.kubectlPath", .string(" /opt/homebrew/bin/kubectl "))
        settings.set("kubernetes.proxyIdleMinutes", .int(30))
        XCTAssertEqual(Settings(url: url, watch: false).kubernetesProxyConfiguration.kubectlPath, "/opt/homebrew/bin/kubectl")
        XCTAssertEqual(Settings(url: url, watch: false).kubernetesProxyConfiguration.idleTime, 1800)
        settings.set("kubernetes.kubeconfigs", .list(["~/.kube/acme-extra.kubeconfig"]))
        settings.set("kubernetes.pinnedContexts", .list(["globex-eu-west-1-dev"]))
        XCTAssertEqual(Settings(url: url, watch: false).kubernetesKubeconfigs, ["~/.kube/acme-extra.kubeconfig"])
        XCTAssertEqual(Settings(url: url, watch: false).kubernetesPinnedContexts, ["globex-eu-west-1-dev"])
        settings.set("kubernetes.kubeconfigs", .list([]))
        XCTAssertFalse(text().contains("kubeconfigs"), "an empty list is the default")
        try write("{\n  \"kubernetes.pinnedContexts\": \"one\",\n  \"kubernetes.maxProxies\": 0\n}\n")
        let bad = Settings(url: url, watch: false)
        XCTAssertEqual(bad.problems.count, 2, bad.problems.joined(separator: "\n"))
        XCTAssertEqual(bad.kubernetesMaxProxies, 4)
    }

    /// `kubernetes.contexts`: an object of contexts, each with fields of
    /// its own. A field that doesn't fit is reported and left out — the
    /// rest of the entry still applies, so a typo never drops a hand-set
    /// production class.
    func testContextsAreEntriesCheckedFieldByField() throws {
        try write(
            """
            {
              // mine
              "kubernetes.contexts": {
                "acme-dev": { "class": "production", "writable": "yes", "colur": "red" },
                "kind-x": { "writable": false, "favouriteNamespaces": ["a", "b"], "class": "prod" }
              },
              "general.restoreTabs": false
            }
            """)
        let settings = Settings(url: url, watch: false)
        let contexts = settings.kubernetesContexts
        XCTAssertEqual(contexts["acme-dev"]?.contextClass, .production)
        XCTAssertNil(contexts["acme-dev"]?.writable)
        XCTAssertEqual(contexts["kind-x"], KubeContextSettings(writable: false, favouriteNamespaces: ["a", "b"]))
        XCTAssertEqual(settings.problems.count, 3, settings.problems.joined(separator: "\n"))
        XCTAssertTrue(settings.problems.contains { $0.contains("\"acme-dev\": \"colur\" isn't a field") })
        XCTAssertTrue(settings.problems.contains { $0.contains("\"kind-x\": \"class\" must be one of") })
        XCTAssertFalse(settings.restoreTabs)

        // Not an object of objects: the whole setting is a problem.
        try write("{\n  \"kubernetes.contexts\": { \"a\": true }\n}\n")
        let wrong = Settings(url: url, watch: false)
        XCTAssertEqual(wrong.kubernetesContexts, [:])
        XCTAssertEqual(wrong.problems.count, 1, wrong.problems.joined(separator: "\n"))
    }

    /// Entries are written on one line, sorted, and changed in place there.
    func testEntriesAreWrittenAndEditedInPlace() throws {
        try write("{\n  // mine\n  \"general.restoreTabs\": false\n}\n")
        let settings = Settings(url: url, watch: false)
        let value = SettingValue.entries(["b": ["writable": .bool(true)], "a\"q": ["class": .string("local"), "favouriteNamespaces": .list(["x"])]])
        XCTAssertEqual(value.json, #"{"a\"q": {"class": "local", "favouriteNamespaces": ["x"]}, "b": {"writable": true}}"#)
        settings.set("kubernetes.contexts", value)
        XCTAssertTrue(text().contains("// mine"), text())
        XCTAssertEqual(Settings(url: url, watch: false).value("kubernetes.contexts"), value)
        settings.set("kubernetes.contexts", .entries(["b": ["class": .string("production")]]))
        XCTAssertTrue(text().contains(#"  "kubernetes.contexts": {"b": {"class": "production"}}"#), text())
        XCTAssertTrue(text().contains("// mine"), "edited on its line: \(text())")
        XCTAssertEqual(Settings(url: url, watch: false).kubernetesContexts["b"]?.contextClass, .production)
        settings.set("kubernetes.contexts", nil)
        XCTAssertFalse(text().contains("kubernetes.contexts"))
    }

    /// An object written over several lines by hand is replaced where it
    /// stands, over several lines again: the file's other lines and the
    /// comments of the entries still there stay; an entry gone takes its own.
    func testAnObjectOverSeveralLinesIsEditedWhereItStands() throws {
        try write(
            "{\n  // mine\n  \"kubernetes.contexts\": { // all\n    // prod's\n    \"acme-prod\": { \"class\": \"production\" }, /* } */\n"
                + "    \"b\": {\n      // never make this writable\n      \"writable\": true\n    }\n    // the end\n  }, // after\n  \"general.restoreTabs\": false\n}\n"
        )
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.kubernetesContexts["acme-prod"]?.contextClass, .production)
        settings.set("kubernetes.contexts", .entries(["acme-prod": ["class": .string("production")], "b": ["writable": .bool(false)], "c": [:]]))
        XCTAssertEqual(
            text(),
            "{\n  // mine\n  \"kubernetes.contexts\": { // all\n    // prod's\n    \"acme-prod\": {\"class\": \"production\"}, /* } */\n"
                + "    // never make this writable\n    \"b\": {\"writable\": false},\n    \"c\": {}\n    // the end\n  }, // after\n"
                + "  \"general.restoreTabs\": false\n}\n")
        XCTAssertEqual(Settings(url: url, watch: false).kubernetesContexts["b"]?.writable, false)
        settings.set("kubernetes.contexts", .entries(["b": ["writable": .bool(true)]]))
        XCTAssertEqual(
            text(),
            "{\n  // mine\n  \"kubernetes.contexts\": { // all\n    // never make this writable\n    \"b\": {\"writable\": true}\n    // the end\n  }, // after\n"
                + "  \"general.restoreTabs\": false\n}\n", "acme-prod's comments went with it")
        XCTAssertEqual(Settings(url: url, watch: false).value("general.restoreTabs"), .bool(false))
        settings.set("kubernetes.contexts", nil)
        XCTAssertEqual(text(), "{\n  // mine\n  \"general.restoreTabs\": false\n}\n")
        XCTAssertNil(SettingsJSON.setting("{\n  \"a\": {\n", key: "a", json: "1"), "never closed: rewritten whole by the caller")
    }

    /// A list over several lines: an item a line, its comments with it.
    func testAListOverSeveralLinesKeepsItsItemsComments() throws {
        let text = "{\n  \"kubernetes.agentWrites\": [\n    \"kind-fake\", // mine\n    // dev's\n    \"fake-dev\"\n  ]\n}\n"
        let members = SettingValue.list(["fake-dev", "kind-fake", "acme-dev"]).members
        XCTAssertEqual(
            SettingsJSON.setting(text, key: "kubernetes.agentWrites", json: "[]", members: members),
            "{\n  \"kubernetes.agentWrites\": [\n    // dev's\n    \"fake-dev\",\n    \"kind-fake\", // mine\n    \"acme-dev\"\n  ]\n}\n")
    }

    func testChangesNameTheKeys() throws {
        let settings = Settings(url: url, watch: false)
        var seen: [Set<String>] = []
        let subscription = settings.changes.sink { seen.append($0) }
        settings.set("appearance.theme", .string("Dracula"))
        settings.set("appearance.theme", .string("Dracula"))
        settings.save(text: "{\n  \"appearance.theme\": \"Nord\",\n  \"editor.fontSize\": 14\n}\n")
        XCTAssertEqual(seen, [["appearance.theme"], ["appearance.theme", "editor.fontSize"]], "an unchanged value says nothing")
        subscription.cancel()
    }

    /// The watcher: a change made by hand applies without anyone asking.
    func testAnEditByHandApplies() async throws {
        try write("{\n}\n")
        let settings = Settings(url: url)
        try write("{\n  \"general.confirmClose\": \"whenRunning\"\n}\n")
        let deadline = Date().addingTimeInterval(5)
        while settings.confirmClose != .whenRunning, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(settings.confirmClose, .whenRunning)
    }

    /// Before settings.json, settings were UserDefaults: carried over once.
    func testUserDefaultsCarryOverOnce() throws {
        let suite = "overterm-settings-migrate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("whenRunning", forKey: "settings.confirmClose")
        defaults.set(15.0, forKey: "settings.fontSize")
        defaults.set(true, forKey: "settings.restoreTabs")  // the default: not written
        defaults.set(0.5, forKey: "settings.unfocusedPaneDim")
        let settings = Settings(url: url, legacy: defaults, watch: false)
        XCTAssertEqual(settings.confirmClose, .whenRunning)
        XCTAssertEqual(settings.number("appearance.fontSize"), 15)
        XCTAssertEqual(settings.unfocusedPaneDim, 0.5)
        XCTAssertFalse(text().contains("restoreTabs"))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(Settings(url: url, legacy: defaults, watch: false).confirmClose, .always, "deleted, it stays deleted")
    }

    func testGhosttyOverridesOnlyWhatIsSet() {
        XCTAssertEqual(Settings.ghosttyOverrides(values: [:]).split(separator: "\n").count, 1, "a comment only")
        let text = Settings.ghosttyOverrides(
            values: [
                "appearance.fontFamily": .string("JetBrains Mono"), "appearance.fontSize": .int(14), "appearance.windowPadding": .int(6),
                "appearance.cursorStyle": .string("bar"), "terminal.optionAsAlt": .string("left"), "terminal.copyOnSelect": .string("clipboard"),
                "terminal.scrollbackMegabytes": .int(20), "appearance.cursorBlink": .bool(false), "general.confirmClose": .string("whenRunning"),
            ], keybindings: ["keybind = super+t=unbind"])
        for line in [
            "font-family = \"JetBrains Mono\"", "font-size = 14", "window-padding-x = 6", "window-padding-y = 6", "cursor-style = bar",
            "macos-option-as-alt = left", "copy-on-select = clipboard", "scrollback-limit = 20000000", "cursor-style-blink = false",
            "keybind = super+t=unbind",
        ] {
            XCTAssertTrue(text.contains(line + "\n"), "\(line) in:\n\(text)")
        }
        XCTAssertFalse(text.contains("confirm"), "not a Ghostty setting")
    }

    /// The look tuned in Settings ▸ Appearance, as Ghostty reads it.
    func testTheTerminalsLookInGhosttysWords() {
        let text = Settings.ghosttyOverrides(values: [
            "appearance.ligatures": .bool(false), "appearance.lineHeight": .int(20), "appearance.letterSpacing": .int(-5),
            "appearance.minimumContrast": .double(4.5), "appearance.boldIsBright": .bool(true),
            "appearance.cursorColor": .string("#ff8800"), "appearance.selectionBackground": .string("#334455"),
        ])
        for line in [
            "font-feature = -calt", "font-feature = -liga", "font-feature = -dlig", "adjust-cell-height = 20%", "adjust-cell-width = -5%",
            "minimum-contrast = 4.5", "bold-color = bright", "cursor-color = #ff8800", "selection-background = #334455",
        ] {
            XCTAssertTrue(text.contains(line + "\n"), "\(line) in:\n\(text)")
        }
        // On is the font's own; off for bold is Ghostty's default.
        let on = Settings.ghosttyOverrides(values: ["appearance.ligatures": .bool(true), "appearance.boldIsBright": .bool(false)])
        XCTAssertFalse(on.contains("font-feature") || on.contains("bold-color"), on)
    }

    /// Translucent, the surfaces draw at the opacity and blur what shows through.
    func testTranslucencyAndTheBackgroundImage() {
        XCTAssertEqual(Settings.windowLines(values: [:]), [])
        XCTAssertEqual(Settings.windowLines(values: ["appearance.backgroundOpacity": .double(1)]), [], "opaque writes nothing")
        XCTAssertEqual(
            Settings.windowLines(values: ["appearance.backgroundOpacity": .double(0.8)]), ["background-opacity = 0.8", "background-blur = true"])
        XCTAssertEqual(
            Settings.windowLines(values: ["appearance.backgroundOpacity": .double(0.8), "appearance.backgroundBlur": .bool(false)]),
            ["background-opacity = 0.8", "background-blur = false"])
        XCTAssertEqual(
            Settings.windowLines(values: ["appearance.backgroundImage": .string("/Users/a/My Pictures/sky.png"), "appearance.backgroundImageFit": .string("contain")]),
            ["background-image = \"/Users/a/My Pictures/sky.png\"", "background-image-opacity = 0.25", "background-image-fit = contain"])
        // Each written once, by windowLines, not again one setting at a time.
        let text = Settings.ghosttyOverrides(values: ["appearance.backgroundOpacity": .double(0.7), "appearance.backgroundBlur": .bool(true)])
        XCTAssertEqual(text.components(separatedBy: "background-opacity").count, 2, text)
        XCTAssertEqual(text.components(separatedBy: "background-blur").count, 2, text)
    }

    func testColoursAreHex() {
        let spec = SettingsSchema.byKey["appearance.cursorColor"]!
        XCTAssertNil(spec.problem(with: .string("#1e90ff")))
        XCTAssertNotNil(spec.problem(with: .string("blue")))
        XCTAssertNotNil(spec.problem(with: .string("#1e90f")))
        XCTAssertEqual(SettingsColor.format(red: 1, green: 0.5, blue: 0), "#ff8000")
        XCTAssertEqual(SettingsColor.parse("#ff8000")?.green ?? 0, 128.0 / 255, accuracy: 0.001)
    }

    func testEverySettingHasAValidDefault() {
        for spec in SettingsSchema.all {
            if let value = spec.defaultValue { XCTAssertNil(spec.problem(with: value), spec.key) }
            // A key says which page shows it — except on Themes, which was
            // carved out of Appearance and shows the `appearance.` keys that
            // named the theme before it had a page of its own. Renaming them
            // would empty the settings.json of everyone who has one.
            let prefix =
                switch spec.section {
                case .about: "updates."
                case .themes: "appearance."
                default: spec.section.rawValue + "."
                }
            XCTAssertTrue(spec.key.hasPrefix(prefix), spec.key)
        }
        XCTAssertEqual(Set(SettingsSchema.all.map(\.key)).count, SettingsSchema.all.count, "keys are unique")
        for key in SettingsSchema.legacyKeys.values { XCTAssertNotNil(SettingsSchema.byKey[key], key) }
    }

    func testSearchFindsASectionBySetting() {
        XCTAssertTrue(SettingsSection.appearance.matches("cursor"))
        XCTAssertTrue(SettingsSection.terminal.matches("option"))
        XCTAssertTrue(SettingsSection.shortcuts.matches("split"))
        XCTAssertTrue(SettingsSection.general.matches("general.confirmClose"), "by its key, as the JSON has it")
        XCTAssertFalse(SettingsSection.agents.matches("cursor"))
        XCTAssertTrue(SettingsSection.themes.matches("theme"), "the gallery's own page")
        XCTAssertFalse(SettingsSection.appearance.matches("theme"), "which Appearance no longer holds")
        XCTAssertTrue(SettingsSection.kubernetes.matches("kubeconfig"))
        XCTAssertTrue(SettingsSection.kubernetes.matches("kubernetes.pinnedContexts"))
    }
}
