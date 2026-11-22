import AppKit
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

final class StripClickTests: XCTestCase {
    private func kind(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) -> StripClick? {
        StripClick.kind(type: type, modifiers: modifiers)
    }

    func testRightClickIsAContextClick() {
        XCTAssertEqual(kind(.rightMouseDown), .context)
        XCTAssertEqual(kind(.rightMouseDown, [.command]), .context)
    }

    /// The bug this exists for: ⌃-click is a context click on macOS and
    /// arrives as a left press, so watching .rightMouseDown alone misses it.
    func testControlClickIsAContextClickToo() {
        XCTAssertEqual(kind(.leftMouseDown, [.control]), .context)
    }

    func testControlBeatsCommand() {
        XCTAssertEqual(kind(.leftMouseDown, [.control, .command]), .context)
    }

    func testCommandClickMarks() {
        XCTAssertEqual(kind(.leftMouseDown, [.command]), .mark)
    }

    func testAPlainPressIsAPress() {
        XCTAssertEqual(kind(.leftMouseDown), .press)
        XCTAssertEqual(kind(.leftMouseDown, [.shift]), .press)
        XCTAssertEqual(kind(.leftMouseDown, [.option]), .press)
    }

    func testNothingElseIsAClick() {
        XCTAssertNil(kind(.leftMouseUp))
        XCTAssertNil(kind(.leftMouseDragged))
        XCTAssertNil(kind(.otherMouseDown))
    }
}
