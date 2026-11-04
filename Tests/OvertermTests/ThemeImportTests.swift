import XCTest

@testable import Overterm

/// Another app's colours as a Ghostty theme file, read back by the gallery.
final class ThemeImportTests: XCTestCase {
    private func entry(_ red: Double, _ green: Double, _ blue: Double, space: String = "sRGB") -> [String: Any] {
        ["Red Component": red, "Green Component": green, "Blue Component": blue, "Alpha Component": 1, "Color Space": space]
    }

    func testITermColours() throws {
        var plist: [String: Any] = [
            "Background Color": entry(0.1, 0.1, 0.1), "Foreground Color": entry(0.9, 0.9, 0.9),
            "Cursor Color": entry(1, 0.5, 0), "Selection Color": entry(0.2, 0.3, 0.4),
        ]
        for index in 0...15 { plist["Ansi \(index) Color"] = entry(Double(index) / 15, 0, 0) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let file = try ThemeImport.iterm(data).file(source: "Test.itermcolors")
        XCTAssertTrue(file.contains("background = #1a1a1a\n"), file)
        XCTAssertTrue(file.contains("cursor-color = #ff8000\n"), file)
        XCTAssertTrue(file.contains("palette = 15=#ff0000\n"), file)
        XCTAssertTrue(file.contains("selection-background = #334d66\n"), file)
        let theme = try XCTUnwrap(TerminalTheme.parse(file, name: "Test"))
        XCTAssertEqual(theme.palette.count, 16, "the gallery reads all sixteen")
    }

    /// Old files are in "Calibrated" (generic) RGB: converted, not copied.
    func testCalibratedIsConvertedToSRGB() throws {
        let plist: [String: Any] = ["Background Color": entry(0.5, 0.5, 0.5, space: "Calibrated"), "Foreground Color": entry(1, 1, 1)]
        let colours = try ThemeImport.iterm(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        XCTAssertNotEqual(colours.background.map(ThemeImport.hex), "#808080", "generic RGB isn't sRGB")
    }

    func testVSCodeThemeWithComments() throws {
        let json = """
            // A theme, as VS Code writes them: comments, trailing commas.
            {
              "name": "Night Owl",
              "colors": {
                "editor.background": "#011627",
                "editor.foreground": "#d6deeb",
                "terminal.ansiRed": "#ef5350",
                "terminal.ansiBrightWhite": "#ffffffcc",
                "terminalCursor.foreground": "#80a4c2",
              },
            }
            """
        let (name, colours) = try ThemeImport.vscode(json)
        XCTAssertEqual(name, "Night Owl")
        let file = try colours.file(source: "night-owl.json")
        for line in ["background = #011627", "foreground = #d6deeb", "palette = 1=#ef5350", "palette = 15=#ffffff", "cursor-color = #80a4c2"] {
            XCTAssertTrue(file.contains(line + "\n"), "\(line) in\n\(file)")
        }
        XCTAssertNotNil(TerminalTheme.parse(file, name: "Night Owl"))
    }

    func testNothingToDrawIsRefused() {
        XCTAssertThrowsError(try ThemeImport.vscode(##"{"colors": {"button.background": "#fff"}}"##)) {
            XCTAssertEqual($0 as? ThemeImport.Failure, .noColours)
        }
        XCTAssertThrowsError(try ThemeImport.iterm(Data("not a plist".utf8)))
    }

    func testSavingNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try ThemeImport.save("background = #000000\n", named: "Night/Owl", in: dir), "Night-Owl")
        XCTAssertEqual(try ThemeImport.save("background = #111111\n", named: "Night/Owl", in: dir), "Night-Owl 2")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Night-Owl"), encoding: .utf8), "background = #000000\n")
    }
}

/// The theme editor writes only the lines it changes.
final class ThemeFileTests: XCTestCase {
    func testOnlyTheChangedLinesAreWritten() {
        let original = """
            # Dracula, from Ghostty
            palette = 0=#21222c
            palette = 1=#ff5555
            background = #282a36
            foreground = #f8f8f2
            cursor-text = #282a36
            """
        let edited = ThemeFile.set(
            [
                "background": ThemeColor(red: 0, green: 0, blue: 0), "palette 1": ThemeColor(red: 1, green: 0, blue: 0),
                "selection-background": ThemeColor(red: 1, green: 1, blue: 1), "palette 2": ThemeColor(red: 0, green: 1, blue: 0),
            ],
            in: original)
        XCTAssertEqual(
            edited,
            """
            # Dracula, from Ghostty
            palette = 0=#21222c
            palette = 1=#ff0000
            background = #000000
            foreground = #f8f8f2
            cursor-text = #282a36
            selection-background = #ffffff
            palette = 2=#00ff00

            """, "the comment and cursor-text kept; new keys at the end")
        XCTAssertNotNil(TerminalTheme.parse(edited, name: "Mine"))
    }

    func testFromNothing() {
        let text = ThemeFile.set(["foreground": ThemeColor(red: 1, green: 1, blue: 1), "background": ThemeColor(red: 0, green: 0, blue: 0)], in: "")
        XCTAssertEqual(text, "background = #000000\nforeground = #ffffff\n")
    }
}
