import XCTest

@testable import Terminus

@MainActor
final class SettingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "terminus-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsKeepTodaysBehaviour() {
        let settings = Settings(defaults: defaults)
        XCTAssertTrue(settings.restoreTabs)
        XCTAssertTrue(settings.restoreScrollback)
        XCTAssertEqual(settings.newTabDirectory, .current)
        XCTAssertEqual(settings.confirmClose, .always, "closing always asked — asked for; it stays the default")
        XCTAssertTrue(settings.notifications)
        XCTAssertTrue(settings.dockBadge)
        XCTAssertNil(settings.fontSize, "nothing overrides the user's Ghostty config until they choose")
        XCTAssertEqual(settings.unfocusedPaneDim, 0.35)
    }

    func testChoicesPersist() {
        let settings = Settings(defaults: defaults)
        settings.confirmClose = .whenRunning
        settings.newTabDirectory = .home
        settings.fontSize = 15
        settings.theme = "Dracula"
        settings.restoreScrollback = false
        let again = Settings(defaults: defaults)
        XCTAssertEqual(again.confirmClose, .whenRunning)
        XCTAssertEqual(again.newTabDirectory, .home)
        XCTAssertEqual(again.fontSize, 15)
        XCTAssertEqual(again.theme, "Dracula")
        XCTAssertFalse(again.restoreScrollback)
        again.fontSize = nil
        XCTAssertNil(Settings(defaults: defaults).fontSize, "reset goes back to the Ghostty config")
    }

    func testGhosttyOverridesOnlyWhatIsSet() {
        let none = Settings.ghosttyOverrides(fontFamily: nil, fontSize: nil, theme: nil, windowPadding: nil, cursorStyle: nil)
        XCTAssertEqual(none.split(separator: "\n").count, 1, "just the header comment")
        let some = Settings.ghosttyOverrides(fontFamily: "JetBrains Mono", fontSize: 14.5, theme: "Dracula", windowPadding: 8, cursorStyle: .bar)
        XCTAssertTrue(some.contains("font-family = \"JetBrains Mono\"\n"))
        XCTAssertTrue(some.contains("font-size = 14.5\n"))
        XCTAssertTrue(some.contains("theme = \"Dracula\"\n"))
        XCTAssertTrue(some.contains("window-padding-x = 8\nwindow-padding-y = 8\n"))
        XCTAssertTrue(some.contains("cursor-style = bar\n"))
    }

    func testSearchFindsASectionBySetting() {
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("font") }, [.appearance])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("scrollback") }, [.general])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("") }, SettingsSection.allCases)
    }
}
