import AppKit
import XCTest

@testable import Overterm
@testable import OvertermShell

/// The sidebar's keys, read off an event.
@MainActor
final class SidebarKeyTests: XCTestCase {
    private func key(_ code: UInt16, _ characters: String = "") -> SidebarKey? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ).flatMap(SidebarKey.init)
    }

    func testArrowsVimKeysReturnAndEscape() {
        XCTAssertEqual(key(125), .down)
        XCTAssertEqual(key(126), .up)
        XCTAssertEqual(key(123), .left)
        XCTAssertEqual(key(124), .right)
        XCTAssertEqual(key(36, "\r"), .open)
        XCTAssertEqual(key(53, "\u{1b}"), .escape)
        XCTAssertEqual(key(38, "j"), .down)
        XCTAssertEqual(key(40, "k"), .up)
        XCTAssertNil(key(0, "a"), "any other key is the panel's own, or nothing")
    }
}
