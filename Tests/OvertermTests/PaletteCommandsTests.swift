import AppKit
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// ⌘K finds every menu command with the key bound now, and every setting
/// (issue-tracker#22).
@MainActor
final class PaletteCommandsTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    func testAKeyWrittenInASubtitleGivesWayToTheOneBoundNow() {
        XCTAssertEqual(PaletteCommands.strippingKey("Worktree + branch + agent  ⇧⌘N"), "Worktree + branch + agent")
        XCTAssertEqual(PaletteCommands.strippingKey("⌘T"), "")
        XCTAssertEqual(PaletteCommands.strippingKey("The keyboard to the next open column  F6"), "The keyboard to the next open column")
        XCTAssertEqual(PaletteCommands.strippingKey("A file by name  ⌘P in the editor"), "A file by name  ⌘P in the editor", "only a key at the end")
        XCTAssertEqual(PaletteCommands.subtitle("Every tab at a glance  ⇧⌘A", key: "⌃⌘A"), "Every tab at a glance  ⌃⌘A")
        XCTAssertNil(PaletteCommands.subtitle("⌘T", key: nil), "unbound: no key said")
        XCTAssertEqual(PaletteCommands.subtitle(nil, key: "⌘T"), "⌘T")
    }

    func testRebindingAKeyChangesTheRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("keybindings.json")
        try #"[{ "key": "ctrl+cmd+t", "command": "tabs.new" }]"#.write(to: file, atomically: true, encoding: .utf8)
        let keys = Keybindings(url: file, ghosttyDefault: { _ in nil }, watch: false)
        let row = PaletteItem(id: "a.newTab", group: .action, title: "New Tab", subtitle: "⌘T", symbol: "plus") { _, _ in }
        let live = PaletteCommands.withLiveKeys([row], keys: keys)
        XCTAssertEqual(live.first?.subtitle, keys.key(for: KeyCommands.byID["tabs.new"]!)?.display)
        XCTAssertNotEqual(live.first?.subtitle, "⌘T", "the key in keybindings.json, not the one written in the row")
    }

    func testEveryMenuCommandHasARow() {
        let menu = NSMenu()
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "View")
        sub.addItem(withTitle: "Inbox", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
        let docker = NSMenuItem(title: "Docker", action: nil, keyEquivalent: "")
        docker.submenu = NSMenu(title: "Docker")
        docker.submenu?.addItem(withTitle: "Compose Down…", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
        sub.addItem(docker)
        sub.addItem(.separator())
        sub.addItem(withTitle: "New Tab", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
        view.submenu = sub
        menu.addItem(view)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(edit)
        let found = PaletteCommands.commands(in: menu, skipping: [PaletteCommands.normalized("New Tab")])
        XCTAssertEqual(found.map(\.item.title), ["Inbox", "Compose Down…"], "a row already there and Copy left out")
        XCTAssertEqual(found.last?.path, ["View", "Docker"])
    }

    /// The real menu: the commands the issue names are all found by ⌘K.
    func testTheMenusCommandsTheIssueNamesAreOffered() {
        let found = PaletteCommands.commands(in: MainMenu.build(), skipping: []).map { PaletteCommands.normalized($0.item.title) }
        for title in ["Inbox", "Tab Info", "Usage", "Presentation Mode", "Keyboard Shortcuts", "Copy the Last Command's Output"] {
            XCTAssertTrue(found.contains(PaletteCommands.normalized(title)), "\(title) in \(found.prefix(40))")
        }
        XCTAssertFalse(found.contains("copy"))
        XCTAssertFalse(found.contains("quit overterm"))
    }

    /// A setting whose title fits the query better still comes after the
    /// action of that name: "changes" is the Changes pane.
    func testAnActionOutranksASetting() {
        let palette = PaletteModel()
        palette.reset(with: [
            PaletteItem(id: "setting.gutter", group: .setting, title: "Mark lines changed since the last commit", subtitle: nil, symbol: "gearshape") { _, _ in },
            PaletteItem(id: "a.diff", group: .action, title: "Changes", subtitle: nil, symbol: "plus") { _, _ in },
        ])
        palette.query = "changes"
        XCTAssertEqual(palette.results.map(\.id), ["a.diff", "setting.gutter"])
    }

    /// An item that is no command shows its own key equivalent.
    func testAnItemsOwnKey() {
        let item = NSMenuItem(title: "Something of AppKit's", action: nil, keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.command, .option]
        XCTAssertEqual(PaletteCommands.key(of: item), "⌥⌘J")
        XCTAssertEqual(PaletteCommands.equivalent(of: NSMenuItem(title: "x", action: nil, keyEquivalent: "")), nil)
    }

    func testASettingsRowSaysItsValue() {
        XCTAssertEqual(PaletteCommands.describe(.bool(true)), "On")
        XCTAssertEqual(PaletteCommands.describe(.double(13)), "13")
        XCTAssertEqual(PaletteCommands.describe(.list(["a", "b", "c", "d"])), "a, b, c +1")
        XCTAssertEqual(PaletteCommands.describe(nil), "—")
        XCTAssertTrue(SettingsSchema.all.contains { $0.title.localizedCaseInsensitiveContains("font size") }, "⌘K's \"font size\" finds a setting")
    }
}
