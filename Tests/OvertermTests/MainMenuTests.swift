import AppKit
import XCTest

@testable import Overterm

/// The menu bar as it is built. A command whose key never reaches its item
/// is a shortcut that does nothing, and that is invisible from the model
/// alone — these walk the real menu.
@MainActor
final class MainMenuTests: XCTestCase {
    override func setUp() async throws {
        // MainMenu.build() sets NSApp.windowsMenu; without an application
        // object that is a nil force-unwrap. Making it does not run a loop.
        _ = NSApplication.shared
    }

    private func items(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items(of:)) ?? []) }
    }

    func testEveryMenuCommandCarriesItsKey() {
        let built = items(of: MainMenu.build())
        let byID = Dictionary(uniqueKeysWithValues: built.compactMap { item in item.identifier.map { ($0.rawValue, item) } })
        for command in KeyCommands.all where command.menu {
            guard let item = byID[command.id] else {
                XCTFail("\(command.id) has no menu item")
                continue
            }
            guard let key = command.defaultKey.flatMap(KeyCombo.init) else {
                XCTAssertEqual(item.keyEquivalent, "", "\(command.id) has no default key but its item carries one")
                continue
            }
            let (equivalent, modifiers) = key.menuKey
            XCTAssertEqual(item.keyEquivalent, equivalent, "\(command.id)")
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, "\(command.id)")
        }
    }

    /// Two items on one key: AppKit fires the first it finds and the other
    /// silently never works.
    func testNoTwoMenuItemsAnswerTheSameKey() {
        var seen: [String: String] = [:]
        for item in items(of: MainMenu.build()) where !item.keyEquivalent.isEmpty {
            let key = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
            if let other = seen[key] { XCTFail("\(item.title) and \(other) share \(key)") }
            seen[key] = item.title
        }
    }

    /// Every id we set ourselves is a command, or Keybindings can neither
    /// show it in Settings nor rebind it. AppKit gives the items we don't
    /// identify an id of its own (the selector, `showAbout:`); ours are the
    /// dotted ones.
    func testEveryIdentifierWeSetIsAKnownCommand() {
        for item in items(of: MainMenu.build()) {
            guard let id = item.identifier?.rawValue, id.contains("."), !id.hasSuffix(":") else { continue }
            XCTAssertNotNil(KeyCommands.byID[id], "\(item.title) claims \(id), which is not a command")
        }
    }
}
