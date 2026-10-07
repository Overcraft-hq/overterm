import AppKit
import Carbon.HIToolbox
import GhosttyKit
import XCTest

@testable import Terminus

@MainActor
final class KeybindingsTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-keys-\(UUID().uuidString)")
    private var url: URL { dir.appendingPathComponent("keybindings.json") }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Ghostty's defaults for its actions, as the base config would answer.
    private func keybindings() -> Keybindings {
        Keybindings(
            url: url,
            ghosttyDefault: { ["clear_screen": KeyCombo("cmd+k"), "goto_split:left": KeyCombo("alt+cmd+left")][$0] ?? nil }, watch: false)
    }

    private func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    // MARK: KeyCombo

    func testKeysReadAndWriteAsVSCodeDoes() {
        let combo = KeyCombo("cmd+shift+d")
        XCTAssertEqual(combo, KeyCombo(shift: true, command: true, key: "d"))
        XCTAssertEqual(KeyCombo("Shift+CMD+D"), combo, "any order, any case")
        XCTAssertEqual(combo?.text, "shift+cmd+d")
        XCTAssertEqual(combo?.display, "⇧⌘D")
        XCTAssertEqual(combo?.ghostty, "shift+super+d")
        XCTAssertEqual(KeyCombo("ctrl+cmd+=")?.ghostty, "ctrl+super+=", "Ghostty reads a = key (==action)")
        XCTAssertEqual(KeyCombo("cmd++")?.key, "+")
        XCTAssertEqual(KeyCombo("alt+up")?.ghostty, "alt+arrow_up")
        XCTAssertEqual(KeyCombo("alt+up")?.display, "⌥↑")
        XCTAssertEqual(KeyCombo("shift+cmd+enter")?.display, "⇧⌘↩")
        XCTAssertNil(KeyCombo("cmd+shift"), "no key")
        XCTAssertNil(KeyCombo("hyper+d"), "no such modifier")
        XCTAssertNil(KeyCombo("cmd+banana"), "no such key")
    }

    func testMenuKeys() {
        let enter = KeyCombo("shift+cmd+enter")!.menuKey
        XCTAssertEqual(enter.key, "\r")
        XCTAssertEqual(enter.modifiers, [.shift, .command])
        XCTAssertEqual(KeyCombo("cmd+up")!.menuKey.key, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        XCTAssertEqual(KeyCombo("f5")!.menuKey.key, String(UnicodeScalar(NSF5FunctionKey)!))
    }

    /// Recorded by where the key is: ⌘, is "cmd+," whatever the layout calls it.
    func testRecordedKeysByPosition() throws {
        func event(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)))
        }
        XCTAssertEqual(KeyCombo(event: try event(kVK_ANSI_Comma, .command, "ö")), KeyCombo("cmd+,"), "Turkish Q's ⌘Ö")
        XCTAssertEqual(KeyCombo(event: try event(kVK_ANSI_D, [.command, .shift], "D")), KeyCombo("shift+cmd+d"))
        XCTAssertEqual(KeyCombo(event: try event(kVK_F5, [], "")), KeyCombo("f5"), "a function key alone is a shortcut")
        XCTAssertNil(KeyCombo(event: try event(kVK_ANSI_D, [], "d")), "a plain letter isn't one")
    }

    func testGhosttyTriggers() {
        var d = ghostty_input_trigger_s()
        d.tag = GHOSTTY_TRIGGER_PHYSICAL
        d.key.physical = GHOSTTY_KEY_D
        d.mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(KeyCombo(trigger: d), KeyCombo("shift+cmd+d"))
        var bracket = ghostty_input_trigger_s()
        bracket.tag = GHOSTTY_TRIGGER_UNICODE
        bracket.key.unicode = UInt32(("[" as UnicodeScalar).value)
        bracket.mods = GHOSTTY_MODS_SUPER
        XCTAssertEqual(KeyCombo(trigger: bracket), KeyCombo("cmd+["))
        var unbound = ghostty_input_trigger_s()
        unbound.tag = GHOSTTY_TRIGGER_PHYSICAL
        unbound.key.physical = GHOSTTY_KEY_UNIDENTIFIED
        XCTAssertNil(KeyCombo(trigger: unbound))
    }

    func testEveryCommandIsWellFormed() {
        XCTAssertEqual(Set(KeyCommands.all.map(\.id)).count, KeyCommands.all.count, "ids are unique")
        for command in KeyCommands.all {
            XCTAssertTrue(KeyCommands.groups.contains(command.group), command.id)
            if let key = command.defaultKey { XCTAssertNotNil(KeyCombo(key), command.id) }
            XCTAssertTrue(command.menu || command.ghostty != nil, "\(command.id): a menu item or a Ghostty action")
        }
    }

    // MARK: Resolution

    func testTheLastEntryWinsAndMinusRemoves() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        // mine
        [
          { "key": "cmd+y", "command": "tabs.new" },
          { "key": "cmd+u", "command": "tabs.new" },
          { "key": "cmd+d", "command": "-splits.right" },
          { "key": "cmd+x", "command": "-splits.down" },
        ]
        """.write(to: url, atomically: true, encoding: .utf8)
        let keys = keybindings()
        XCTAssertTrue(keys.problems.isEmpty, keys.problems.joined())
        XCTAssertEqual(keys.key(for: KeyCommands.byID["tabs.new"]!), KeyCombo("cmd+u"))
        XCTAssertNil(keys.key(for: KeyCommands.byID["splits.right"]!), "its default removed")
        XCTAssertEqual(keys.key(for: KeyCommands.byID["splits.down"]!), KeyCombo("shift+cmd+d"), "-command removes only that key")
        XCTAssertEqual(keys.key(for: KeyCommands.byID["terminal.clear"]!), KeyCombo("cmd+k"), "a Ghostty action's default is Ghostty's")
    }

    func testSettingWritesTheFile() {
        let keys = keybindings()
        let newTab = KeyCommands.byID["tabs.new"]!
        let split = KeyCommands.byID["splits.right"]!
        keys.set(newTab, to: KeyCombo("cmd+y"))
        keys.set(split, to: nil)
        XCTAssertTrue(text().contains("{ \"key\": \"cmd+y\", \"command\": \"tabs.new\" }"), text())
        XCTAssertTrue(text().contains("{ \"key\": \"cmd+d\", \"command\": \"-splits.right\" }"), text())
        keys.set(newTab, to: KeyCombo("cmd+u"))
        XCTAssertFalse(text().contains("cmd+y"), "one entry per command")
        keys.set(newTab, to: KeyCombo("cmd+t"))
        XCTAssertFalse(text().contains("tabs.new"), "back on its default, nothing to say")
        keys.reset(split)
        XCTAssertEqual(keys.key(for: split), KeyCombo("cmd+d"))
        XCTAssertTrue(keys.entries.isEmpty)
        let reopened = keybindings()
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    func testConflictsAreOnlyAboutChosenKeys() {
        let keys = keybindings()
        let find = KeyCommands.byID["edit.find"]!
        XCTAssertTrue(keys.conflicts(for: find).isEmpty, "⌘F is the editor's and the terminal's by design")
        keys.set(KeyCommands.byID["tabs.new"]!, to: KeyCombo("cmd+d"))
        XCTAssertEqual(keys.conflicts(for: KeyCommands.byID["splits.right"]!).map(\.id), ["tabs.new"])
        XCTAssertEqual(keys.conflicts(for: KeyCommands.byID["tabs.new"]!).map(\.id), ["splits.right"])
    }

    /// Ghostty: a menu command's keys are let go (the menu has them); a
    /// terminal command's new key is bound to its action.
    func testGhosttyLines() {
        let keys = keybindings()
        XCTAssertTrue(keys.ghosttyLines.isEmpty)
        keys.set(KeyCommands.byID["tabs.new"]!, to: KeyCombo("cmd+y"))
        keys.set(KeyCommands.byID["tabs.newClaude"]!, to: KeyCombo("cmd+j"))
        keys.set(KeyCommands.byID["terminal.clear"]!, to: KeyCombo("ctrl+alt+l"))
        keys.set(KeyCommands.byID["splits.right"]!, to: nil)
        XCTAssertEqual(
            keys.ghosttyLines,
            [
                "keybind = super+t=unbind", "keybind = super+y=unbind",  // tabs.new: Ghostty's new_tab
                "keybind = super+j=unbind",  // tabs.newClaude: no Ghostty action, its new key freed
                "keybind = super+d=unbind",  // splits.right removed
                "keybind = super+k=unbind", "keybind = ctrl+alt+l=clear_screen",  // terminal-only
            ], "\n" + keys.ghosttyLines.joined(separator: "\n"))
    }

    func testKeysGoOnTheMenuItems() {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "New Tab", action: nil, keyEquivalent: "t")
        item.identifier = NSUserInterfaceItemIdentifier("tabs.new")
        let other = menu.addItem(withTitle: "Split Right", action: nil, keyEquivalent: "d")
        other.identifier = NSUserInterfaceItemIdentifier("splits.right")
        let keys = keybindings()
        keys.set(KeyCommands.byID["tabs.new"]!, to: KeyCombo("alt+cmd+y"))
        keys.set(KeyCommands.byID["splits.right"]!, to: nil)
        keys.apply(to: menu)
        XCTAssertEqual(item.keyEquivalent, "y")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option, .command])
        XCTAssertEqual(other.keyEquivalent, "")
    }

    func testABrokenFileKeepsTheShortcuts() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "[ { \"key\": \"cmd+y\", \"command\": \"tabs.new\" }, ".write(to: url, atomically: true, encoding: .utf8)
        let keys = keybindings()
        XCTAssertNotNil(keys.key(for: KeyCommands.byID["tabs.new"]!))
        try "[ { \"key\": \"cmd+y\" , oops ]".write(to: url, atomically: true, encoding: .utf8)
        let broken = keybindings()
        XCTAssertTrue(broken.problems.first?.contains("doesn't parse") == true, broken.problems.joined())
        broken.set(KeyCommands.byID["tabs.new"]!, to: KeyCombo("cmd+u"))
        XCTAssertEqual(text(), "[ { \"key\": \"cmd+y\" , oops ]", "not written over")
        try "[ { \"key\": \"cmd+banana\", \"command\": \"tabs.new\" }, { \"key\": \"cmd+y\", \"command\": \"no.such\" } ]"
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(keybindings().problems.count, 2)
    }
}
