import AppKit
import XCTest

@testable import Overterm

/// Settings ▸ Editor ▸ Colours ▸ The terminal theme's: the syntax in the
/// terminal's own sixteen.
final class EditorThemeTerminalTests: XCTestCase {
    private let ansi = (0...15).map { NSColor(srgbRed: CGFloat($0) / 15, green: 0.5, blue: 0.5, alpha: 1) }

    func testSyntaxTakesTheTerminalsColours() throws {
        let theme = EditorTheme(background: .black, terminal: .init(foreground: .white, ansi: ansi))
        XCTAssertEqual(theme.style(for: "keyword.control.return")?.color, ansi[5], "keywords magenta")
        XCTAssertEqual(theme.style(for: "string")?.color, ansi[2], "strings green")
        XCTAssertEqual(theme.style(for: "function.method")?.color, ansi[4], "functions blue")
        XCTAssertEqual(theme.style(for: "comment")?.color, ansi[8], "comments bright black")
        XCTAssertEqual(theme.text, .white)
        XCTAssertTrue(theme.isDark)
    }

    func testWithoutSixteenItIsOneDark() {
        let partial = EditorTheme(background: .black, terminal: .init(foreground: .white, ansi: Array(ansi.prefix(8))))
        let one = EditorTheme(background: .black, terminal: nil)
        XCTAssertEqual(partial.style(for: "keyword")?.color, one.style(for: "keyword")?.color)
    }
}
