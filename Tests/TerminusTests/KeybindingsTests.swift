import XCTest

@testable import Terminus

/// The keys the menu owns and Ghostty does not.
///
/// Ghostty consumes its own bindings in `performKeyEquivalent`, before the
/// menu ever sees the key — so a menu command on a key Ghostty binds does
/// nothing at all, silently. The only thing that stops that is an unbind
/// line in the config Terminus writes.
@MainActor
final class KeybindingsTests: XCTestCase {
    /// ⌘K is Ghostty's `clear_screen` on macOS. The palette takes it, so
    /// clearing moves to ⇧⌘K, and the menu's own key is unbound in
    /// Ghostty whatever happens (`ghosttyLines`).
    func testClearMovesOffTheKeyThePaletteTakes() {
        let clear = KeyCommands.byID["terminal.clear"]
        XCTAssertEqual(clear?.defaultKey, "shift+cmd+k")
        XCTAssertEqual(KeyCommands.byID["palette.show"]?.defaultKey, "cmd+k")
    }

    /// A menu command's key must not also be a Ghostty action's, or
    /// whichever Ghostty binds wins and the menu item is dead.
    func testNoMenuCommandSharesAKeyWithATerminalCommand() {
        // The editor's keys are their own scope: they act only while it has
        // the keyboard, before the menu (CodeTextView.performKeyEquivalent).
        var byKey: [String: String] = [:]
        for command in KeyCommands.all {
            guard let key = command.defaultKey else { continue }
            let scoped = (command.editor ? "editor " : "") + key
            if let other = byKey[scoped] {
                XCTFail("\(command.id) and \(other) are both on \(key)")
            }
            byKey[scoped] = command.id
        }
    }

    /// Every id is unique — `byID` is a dictionary, so a duplicate would
    /// silently lose one of them.
    func testEveryCommandHasItsOwnID() {
        XCTAssertEqual(KeyCommands.all.count, Set(KeyCommands.all.map(\.id)).count)
    }

    /// Each command is in a group the Settings page knows how to show.
    func testEveryCommandIsInAListedGroup() {
        for command in KeyCommands.all {
            XCTAssertTrue(KeyCommands.groups.contains(command.group), "\(command.id) is in \(command.group)")
        }
    }

    /// ⌘F is the editor's find and the terminal's search at once, which
    /// is deliberate — so it must not be unbound for the menu's sake.
    func testTheTerminalKeepsTheKeysItSharesWithTheMenu() {
        let find = KeyCommands.byID["edit.find"]
        let search = KeyCommands.byID["search.terminal"]
        XCTAssertEqual(find?.defaultKey, "cmd+f")
        XCTAssertTrue(find?.menu == true)
        XCTAssertNil(search?.defaultKey, "the terminal's search takes Ghostty's own key")
        XCTAssertEqual(search?.ghostty, "start_search")
        XCTAssertFalse(search?.menu == true)
    }

    /// Every key parses — one that does not would silently never bind.
    func testEveryDefaultKeyParses() {
        for command in KeyCommands.all {
            guard let key = command.defaultKey else { continue }
            XCTAssertNotNil(KeyCombo(key), "\(command.id): \(key)")
        }
    }
}
