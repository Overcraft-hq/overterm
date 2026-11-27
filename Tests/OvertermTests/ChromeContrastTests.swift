import AppKit
import XCTest

@testable import Overterm
@testable import OvertermCore

/// A11Y-U1: the chrome's secondary and tertiary text read on the window
/// and the cards — 4.5:1 and 3:1 — whatever theme the terminal has.
@MainActor
final class ChromeContrastTests: XCTestCase {
    func testTheRatioIsWCAGs() {
        XCTAssertEqual(ChromeContrast.ratio(.white, .black), 21, accuracy: 0.01)
        XCTAssertEqual(ChromeContrast.ratio(.white, .white), 1, accuracy: 0.001)
        XCTAssertEqual(ChromeContrast.ratio(ChromeContrast.RGB(0.4627, 0.4627, 0.4627), .white), 4.54, accuracy: 0.02)
    }

    func testTextThatReadsIsLeftAlone() {
        let dark = ChromeContrast.RGB(0.1, 0.1, 0.1)
        let kept = ChromeContrast.floored(.white, alpha: 0.62, on: [dark], floor: 4.5, dark: true)
        XCTAssertEqual(kept.alpha, 0.62)
        XCTAssertEqual(kept.color, .white)
    }

    func testAPaleThemeIsRaisedThenMixed() {
        // A grey on a grey: no alpha is enough, so it is mixed toward white.
        let ground = ChromeContrast.RGB(0.35, 0.35, 0.35)
        let fg = ChromeContrast.RGB(0.55, 0.55, 0.55)
        let floored = ChromeContrast.floored(fg, alpha: 0.62, on: [ground], floor: 4.5, dark: true)
        XCTAssertEqual(floored.alpha, 1)
        XCTAssertGreaterThan(floored.color.red, fg.red)
        XCTAssertGreaterThanOrEqual(ChromeContrast.ratio(floored.color, ground), 4.5)
    }

    /// Every theme the app ships — Ghostty's and Overterm's own.
    func testEveryBundledThemeMeetsTheFloor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = [root.appendingPathComponent("Frameworks/GhosttyResources/ghostty/themes"), root.appendingPathComponent("Resources/themes")]
        var checked = 0
        var failures: [String] = []
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                    let theme = TerminalTheme.parse(text, name: file.lastPathComponent)
                else { continue }
                func ns(_ c: ThemeColor) -> NSColor { NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1) }
                let chrome = ChromeTheme(background: ns(theme.background), foreground: ns(theme.foreground))
                func rgb(_ color: NSColor) -> (ChromeContrast.RGB, Double) {
                    let c = color.usingColorSpace(.sRGB) ?? color
                    return (ChromeContrast.RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)), Double(c.alphaComponent))
                }
                let grounds = [chrome.winNS, chrome.cardNS].map { rgb($0).0 }
                for (name, text, wanted) in [("secondary", chrome.text2NS, ChromeContrast.secondary), ("tertiary", chrome.text3NS, ChromeContrast.tertiary)] {
                    let (color, alpha) = rgb(text)
                    // Where no colour reaches the floor on these grounds, the best one does.
                    let floor = min(wanted, ChromeContrast.reachable(on: grounds))
                    for g in grounds {
                        let ratio = ChromeContrast.ratio(color.over(g, alpha: alpha), g)
                        if ratio < floor - 0.01 { failures.append(String(format: "%@ %@ %.2f", theme.name, name, ratio)) }
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 400, "the themes were found")
        XCTAssertEqual(failures, [], "\(failures.count) of \(checked) themes under the floor")
    }
}
