import XCTest

@testable import Terminus

final class TerminalThemeTests: XCTestCase {
    private let dracula = """
        palette = 0=#21222c
        palette = 1=#ff5555
        palette = 2=#50fa7b
        background = #282a36
        foreground = #f8f8f2
        cursor-color = #f8f8f2
        selection-background = #44475a
        """

    func testParsesAThemeFile() throws {
        let theme = try XCTUnwrap(TerminalTheme.parse(dracula, name: "Dracula"))
        XCTAssertEqual(theme.name, "Dracula")
        XCTAssertEqual(theme.background, ThemeColor("#282a36"))
        XCTAssertEqual(theme.foreground, ThemeColor("#f8f8f2"))
        XCTAssertEqual(theme.cursor, ThemeColor("#f8f8f2"))
        XCTAssertEqual(theme.selection, ThemeColor("#44475a"))
        XCTAssertEqual(theme.palette.count, 3)
        XCTAssertEqual(theme.ansi(1), ThemeColor("#ff5555"))
        // Past what the file holds: the foreground, not a crash.
        XCTAssertEqual(theme.ansi(9), theme.foreground)
    }

    /// The gallery's dark / light filter has to agree with the chrome, which
    /// reads HSB brightness off the background.
    func testDarkAndLight() throws {
        XCTAssertTrue(try XCTUnwrap(TerminalTheme.parse(dracula, name: "x")).isDark)
        let light = try XCTUnwrap(TerminalTheme.parse("background = #f7f7f7\nforeground = #000000", name: "y"))
        XCTAssertFalse(light.isDark)
    }

    func testAFileWithoutGroundsIsNoTheme() {
        XCTAssertNil(TerminalTheme.parse("palette = 1=#ff5555", name: "x"))
        XCTAssertNil(TerminalTheme.parse("background = #282a36", name: "x"))
        XCTAssertNil(TerminalTheme.parse("", name: "x"))
    }

    func testColourForms() {
        XCTAssertEqual(ThemeColor("#ffffff"), ThemeColor(red: 1, green: 1, blue: 1))
        XCTAssertEqual(ThemeColor("282a36"), ThemeColor("#282a36"))
        XCTAssertEqual(ThemeColor("#F0A"), ThemeColor("#ff00aa"))
        XCTAssertEqual(ThemeColor("rgb:ff/00/aa"), ThemeColor("#ff00aa"))
        XCTAssertEqual(ThemeColor("  #282A36 "), ThemeColor("#282a36"))
        // A colour name, a palette reference: that line is skipped, the
        // theme still loads.
        XCTAssertNil(ThemeColor("cornflowerblue"))
        XCTAssertNil(ThemeColor("#12345"))
        XCTAssertNil(ThemeColor(""))
    }

    /// Comments, blank lines and a key we don't read, as the files have them.
    func testIgnoresTheRest() throws {
        let theme = try XCTUnwrap(
            TerminalTheme.parse(
                """
                # Someone's theme

                background = #000000
                foreground = #ffffff
                cursor-text = #000000
                palette = 99=#ff0000
                nonsense
                """, name: "x"))
        XCTAssertTrue(theme.palette.isEmpty)
        XCTAssertNil(theme.cursor)
    }
}

final class ThemeCatalogTests: XCTestCase {
    private func entries(_ names: [(String, Bool, ThemeCatalog.Source)]) -> [ThemeCatalog.Entry] {
        names.map { name, dark, source in
            let text = dark ? "background = #101010\nforeground = #eeeeee" : "background = #fafafa\nforeground = #101010"
            return ThemeCatalog.Entry(theme: TerminalTheme.parse(text, name: name)!, source: source)
        }
    }

    func testFilterByNameAndLightness() {
        let all = entries([("Dracula", true, .builtIn), ("Alabaster", false, .builtIn), ("My Dark", true, .user)])
        XCTAssertEqual(ThemeCatalog.filter(all, search: "", appearance: .all).count, 3)
        XCTAssertEqual(ThemeCatalog.filter(all, search: "", appearance: .light).map(\.id), ["Alabaster"])
        XCTAssertEqual(ThemeCatalog.filter(all, search: "dark", appearance: .all).map(\.id), ["My Dark"])
        XCTAssertEqual(ThemeCatalog.filter(all, search: "  DRAC ", appearance: .dark).map(\.id), ["Dracula"])
        XCTAssertTrue(ThemeCatalog.filter(all, search: "dracula", appearance: .light).isEmpty)
    }

    /// The user's own themes come after the bundled ones, and a name in both
    /// resolves the way Ghostty resolves it — the first directory wins.
    func testScanKeepsTheFirstOfAName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-themes-\(UUID().uuidString)")
        let bundled = root.appendingPathComponent("bundled")
        let mine = root.appendingPathComponent("mine")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [bundled, mine] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "background = #101010\nforeground = #eeeeee".write(to: bundled.appendingPathComponent("Shared"), atomically: true, encoding: .utf8)
        try "background = #fafafa\nforeground = #101010".write(to: mine.appendingPathComponent("Shared"), atomically: true, encoding: .utf8)
        try "background = #001122\nforeground = #eeeeee".write(to: mine.appendingPathComponent("Only Mine"), atomically: true, encoding: .utf8)
        // Not a theme, and the fetched directory's own two files.
        try "nothing".write(to: mine.appendingPathComponent("Not A Theme"), atomically: true, encoding: .utf8)
        try "MIT".write(to: mine.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)

        let found = ThemeCatalog.scan([(bundled, .builtIn), (mine, .user)])
        XCTAssertEqual(found.map(\.id), ["Only Mine", "Shared"])
        XCTAssertEqual(found.first { $0.id == "Shared" }?.source, .builtIn)
        XCTAssertEqual(found.first { $0.id == "Shared" }?.theme.isDark, true)
        XCTAssertEqual(found.first { $0.id == "Only Mine" }?.source, .user)
    }
}

final class ThemeSettingTests: XCTestCase {
    /// One theme: quoted, so a name with spaces survives.
    func testOneTheme() {
        XCTAssertEqual(
            Settings.themeLines(values: ["appearance.theme": .string("Catppuccin Mocha")]), ["theme = \"Catppuccin Mocha\""])
        XCTAssertEqual(Settings.themeLines(values: [:]), [])
        XCTAssertEqual(Settings.themeLines(values: ["appearance.theme": .string("")]), [])
    }

    /// Following macOS: Ghostty's own `light:…,dark:…`, which can't be quoted.
    func testThePairWhenItFollowsMacOS() {
        let both: [String: SettingValue] = [
            "appearance.followSystemAppearance": .bool(true),
            "appearance.theme": .string("Claude Dark"),
            "appearance.themeLight": .string("Claude Light"),
        ]
        XCTAssertEqual(Settings.themeLines(values: both), ["theme = light:Claude Light,dark:Claude Dark"])
        // Half a pair is the dark one on its own, not a broken line.
        var half = both
        half["appearance.themeLight"] = .string("")
        XCTAssertEqual(Settings.themeLines(values: half), ["theme = \"Claude Dark\""])
        // Off, with a light theme still in the file: it waits there.
        var off = both
        off["appearance.followSystemAppearance"] = .bool(false)
        XCTAssertEqual(Settings.themeLines(values: off), ["theme = \"Claude Dark\""])
    }

    /// The overrides file as a whole carries it once, not twice.
    func testTheOverridesFileHoldsItOnce() {
        let text = Settings.ghosttyOverrides(values: [
            "appearance.followSystemAppearance": .bool(true),
            "appearance.theme": .string("Noctis"),
            "appearance.themeLight": .string("Noctis Lux"),
            "appearance.fontSize": .int(14),
        ])
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("theme") }, ["theme = light:Noctis Lux,dark:Noctis"])
        XCTAssertTrue(text.contains("font-size = 14"))
    }

    /// Both halves are a theme the gallery can show — the names in
    /// Resources/themes are what Ghostty will be asked for.
    func testTheBundledExtrasAreThemes() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/themes")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !["LICENSE", "README.md"].contains($0) && !$0.hasPrefix(".") }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            XCTAssertNotNil(TerminalTheme.parse(text, name: name), name)
            // A comma or a colon in a name would break `light:…,dark:…`.
            XCTAssertFalse(name.contains(",") || name.contains(":"), name)
        }
    }
}
