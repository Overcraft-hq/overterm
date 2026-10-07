import XCTest

@testable import Terminus

@MainActor
final class SettingsTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-settings-\(UUID().uuidString)")
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
        let suite = "terminus-settings-migrate-\(UUID().uuidString)"
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

    func testEverySettingHasAValidDefault() {
        for spec in SettingsSchema.all {
            if let value = spec.defaultValue { XCTAssertNil(spec.problem(with: value), spec.key) }
            XCTAssertTrue(spec.key.hasPrefix(spec.section == .about ? "updates." : spec.section.rawValue + "."), spec.key)
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
    }
}
