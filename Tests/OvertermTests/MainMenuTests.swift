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

    // MARK: Help and View's submenus (DISC-U1, DISC-U2)

    private func menu(_ title: String, in main: NSMenu) -> NSMenu? { main.items.first { $0.submenu?.title == title }?.submenu }

    func testTheHelpMenuIsTheAppsHelpMenu() throws {
        let main = MainMenu.build()
        let help = try XCTUnwrap(menu("Help", in: main))
        XCTAssertTrue(NSApp.helpMenu === help, "macOS's menu search goes in NSApp.helpMenu")
        XCTAssertEqual(main.items.last?.submenu, help, "Help is the last menu")
        let titles = help.items.map(\.title)
        XCTAssertTrue(titles.contains("Keyboard Shortcuts") && titles.contains("Overterm on GitHub") && titles.contains("View Latest Changelog"), "\(titles)")
        XCTAssertNil(help.items.first { $0.title == "View Latest Changelog" }?.identifier.map(\.rawValue).flatMap { KeyCommands.byID[$0] }, "the mirror carries no command id")
        XCTAssertEqual(AppDelegate.gitHubURL.absoluteString, "https://github.com/Overcraft-hq/overterm")
    }

    func testViewGroupsEachFeatureInASubmenu() throws {
        let view = try XCTUnwrap(menu("View", in: MainMenu.build()))
        let submenus = view.items.compactMap(\.submenu).map(\.title)
        XCTAssertEqual(submenus, ["Groups", "Panes", "Columns", "Docker", "Kubernetes", "Activity", "Terraform", "Notes"])
        let top = Set(view.items.filter { $0.submenu == nil && !$0.isSeparatorItem }.compactMap(\.identifier?.rawValue))
        for id in ["palette.show", "inbox.show", "agents.overview", "sidebar.toggle", "changes.toggle", "browser.toggle", "review.branch", "tabs.peek", "view.presentation"] {
            XCTAssertTrue(top.contains(id), "\(id) stays at View's top level")
        }
        XCTAssertLessThan(view.items.count, 35, "View is no longer one long list")
        let groups = try XCTUnwrap(view.items.first { $0.title == "Groups" }?.submenu)
        XCTAssertEqual(groups.items.filter { $0.identifier?.rawValue.hasPrefix("groups.goto") == true }.map(\.tag), Array(1...9))
    }

    /// A key put on a command in a submenu lands on its item, as at the top.
    func testRebindingReachesASubmenusItem() throws {
        let main = MainMenu.build()
        let item = try XCTUnwrap(items(of: main).first { $0.identifier?.rawValue == "splits.zoom" })
        item.keyEquivalent = ""
        Keybindings.shared.apply(to: main)
        let expected = Keybindings.shared.key(for: try XCTUnwrap(KeyCommands.byID["splits.zoom"]))?.menuKey.0 ?? ""
        XCTAssertEqual(item.keyEquivalent, expected)
        XCTAssertFalse(expected.isEmpty, "Zoom Pane has a key")
    }
}
