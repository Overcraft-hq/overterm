import AppKit
import SwiftUI
import XCTest

@testable import Terminus

/// The chrome's colour vocabulary. Every token is derived from the
/// terminal's own background and foreground, so the only way to know a
/// dark theme and a light one both come out legible is to build both.
@MainActor
final class ChromeThemeTests: XCTestCase {
    private let dark = ChromeTheme(
        background: NSColor(srgbRed: 0.086, green: 0.090, blue: 0.102, alpha: 1),
        foreground: NSColor(srgbRed: 0.922, green: 0.922, blue: 0.941, alpha: 1))
    private let light = ChromeTheme(
        background: .white, foreground: NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1))

    private func brightness(_ color: NSColor) -> CGFloat {
        (color.usingColorSpace(.sRGB) ?? color).brightnessComponent
    }

    func testDarkAndLightAreTold() {
        XCTAssertTrue(dark.isDark)
        XCTAssertFalse(light.isDark)
    }

    /// The three grounds have to differ, or the cards vanish into the
    /// window and the gaps between them stop reading as gaps.
    func testTheThreeGroundsAreDistinct() {
        for theme in [dark, light] {
            XCTAssertNotEqual(theme.winNS, theme.cardNS)
            XCTAssertNotEqual(theme.cardNS, theme.termNS)
            XCTAssertNotEqual(theme.winNS, theme.termNS)
        }
    }

    /// The window is the darkest thing in either theme: the cards sit on
    /// it, so it has to recede.
    func testTheWindowRecedesBehindTheCards() {
        XCTAssertLessThan(brightness(dark.winNS), brightness(dark.termNS))
        XCTAssertLessThan(brightness(light.winNS), brightness(light.termNS))
    }

    /// A shadow under a card only works on a light ground; in the dark the
    /// hairline carries it alone.
    func testOnlyALightThemeDropsACardShadow() {
        XCTAssertEqual(dark.cardShadow, .clear)
        XCTAssertNotEqual(light.cardShadow, .clear)
    }

    /// Three weights of text presence, all from one foreground.
    func testTextFadesInThreeSteps() {
        for theme in [dark, light] {
            XCTAssertEqual(theme.text, Color(nsColor: theme.textNS))
            XCTAssertNotEqual(theme.text, theme.text2)
            XCTAssertNotEqual(theme.text2, theme.text3)
        }
    }

    /// The old names still answer, so a view that has not been redrawn yet
    /// keeps its colours.
    func testTheOldNamesStillAnswer() {
        XCTAssertEqual(dark.strip, dark.win)
        XCTAssertEqual(dark.stripNS, dark.winNS)
        XCTAssertEqual(dark.selected, dark.tabSel)
        XCTAssertEqual(dark.hover, dark.rowHover)
        XCTAssertEqual(dark.dimText, dark.text2)
    }
}
