import AppKit
import GhosttyKit
import XCTest

@testable import Terminus

final class GhosttyInputTests: XCTestCase {
    func testModsRoundTrip() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = GhosttyInput.mods(flags)
        for bit in [GHOSTTY_MODS_SHIFT, GHOSTTY_MODS_CTRL, GHOSTTY_MODS_ALT, GHOSTTY_MODS_SUPER] {
            XCTAssertNotEqual(mods.rawValue & bit.rawValue, 0)
        }
        XCTAssertEqual(GhosttyInput.modifierFlags(mods), flags)
        XCTAssertEqual(GhosttyInput.mods([]).rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testRightSideModifiersAreReported() {
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | UInt(NX_DEVICERALTKEYMASK))
        let mods = GhosttyInput.mods(rightOption)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT_RIGHT.rawValue, 0, "macos-option-as-alt = right needs this")
    }

    func testMouseButtons() {
        XCTAssertEqual(GhosttyInput.mouseButton(0), GHOSTTY_MOUSE_LEFT)
        XCTAssertEqual(GhosttyInput.mouseButton(1), GHOSTTY_MOUSE_RIGHT)
        XCTAssertEqual(GhosttyInput.mouseButton(2), GHOSTTY_MOUSE_MIDDLE)
        XCTAssertEqual(GhosttyInput.mouseButton(7), GHOSTTY_MOUSE_UNKNOWN)
    }

    private func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testKeyEventTranslation() {
        let ev = key("a", 0).ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(ev.keycode, 0)
        XCTAssertEqual(ev.action, GHOSTTY_ACTION_PRESS)
        XCTAssertNil(ev.text, "text is the caller's (C string lifetime)")
        let ctrl = key("\u{03}", 8, .control).ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(ctrl.consumed_mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0, "control never counts as consumed")
    }

    func testGhosttyCharacters() {
        XCTAssertEqual(key("a", 0).ghosttyCharacters, "a")
        XCTAssertNil(key("\u{F700}", 126).ghosttyCharacters, "function keys (private use area) send no text")
        XCTAssertNotEqual(key("\u{03}", 8, .control).ghosttyCharacters, "\u{03}", "control characters are left to libghostty")
    }
}

final class AgentTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(Agent.claude.command, "claude")
        XCTAssertEqual(Agent.claude.resumeCommand, "claude --continue")
        XCTAssertEqual(Agent.codex.command, "codex")
        XCTAssertEqual(Agent.codex.resumeCommand, "codex resume --last")
        XCTAssertEqual(Set(Agent.allCases.map(\.rawValue)), ["claude", "codex"], "the session file stores these")
    }
}
