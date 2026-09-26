import AppKit
import GhosttyKit
import XCTest

@testable import Terminus

@MainActor
final class ShortcutsTests: XCTestCase {
    func testKeyEquivalentsReadAsMenusShowThem() {
        XCTAssertEqual(Shortcuts.format(keyEquivalent: "d", modifiers: [.command, .shift]), "⇧⌘D")
        XCTAssertEqual(Shortcuts.format(keyEquivalent: "D", modifiers: [.command]), "⇧⌘D", "an upper-case key carries its Shift")
        XCTAssertEqual(Shortcuts.format(keyEquivalent: "\r", modifiers: [.command, .shift]), "⇧⌘↩")
        XCTAssertEqual(Shortcuts.format(keyEquivalent: "=", modifiers: [.command, .control]), "⌃⌘=")
        XCTAssertEqual(Shortcuts.format(keyEquivalent: ",", modifiers: [.command]), "⌘,")
    }

    func testMenusBecomeTitledRows() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        appMenu.addItem(withTitle: "About", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let split = viewMenu.addItem(withTitle: "Split Down", action: nil, keyEquivalent: "d")
        split.keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let rows = Shortcuts.menu(main)
        XCTAssertEqual(rows.map(\.title), ["Settings…", "View ▸ Split Down"], "no shortcut, no row")
        XCTAssertEqual(rows.map(\.keys), ["⌘,", "⇧⌘D"])
    }

    func testGhosttyTriggersBecomeLabels() {
        var d = ghostty_input_trigger_s()
        d.tag = GHOSTTY_TRIGGER_PHYSICAL
        d.key.physical = GHOSTTY_KEY_D
        d.mods = ghostty_input_mods_e(rawValue: GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
        XCTAssertEqual(Shortcuts.format(trigger: d), "⇧⌘D")
        var bracket = ghostty_input_trigger_s()
        bracket.tag = GHOSTTY_TRIGGER_UNICODE
        bracket.key.unicode = UInt32(("[" as UnicodeScalar).value)
        bracket.mods = GHOSTTY_MODS_SUPER
        XCTAssertEqual(Shortcuts.format(trigger: bracket), "⌘[")
        var unbound = ghostty_input_trigger_s()
        unbound.tag = GHOSTTY_TRIGGER_PHYSICAL
        unbound.key.physical = GHOSTTY_KEY_UNIDENTIFIED
        XCTAssertNil(Shortcuts.format(trigger: unbound), "nothing bound, no row")
        let rows = Shortcuts.terminal { $0 == "new_split:right" ? d : unbound }
        XCTAssertEqual(rows.map(\.title), ["Split right"])
    }

    func testFilter() {
        let row = Shortcut(group: .app, title: "View ▸ Split Down", keys: "⇧⌘D")
        XCTAssertTrue(row.matches("split"))
        XCTAssertTrue(row.matches("⌘D"))
        XCTAssertFalse(row.matches("search"))
    }
}
