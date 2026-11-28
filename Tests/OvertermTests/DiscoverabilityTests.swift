import AppKit
import XCTest

@testable import Overterm
@testable import OvertermActivity
@testable import OvertermCore
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermShell

/// Finding things (issue-tracker#57): keys read as they are bound now, the
/// key sheets, the panels' commands.
@MainActor
final class DiscoverabilityTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func keys(_ json: String = "[]") throws -> Keybindings {
        let file = dir.appendingPathComponent("keybindings.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return Keybindings(url: file, ghosttyDefault: { _ in nil }, watch: false)
    }

    /// DISC-U4, DISC-N3: a tooltip or a hint says the key bound now.
    func testHintsFollowARebinding() throws {
        let plain = try keys()
        XCTAssertEqual(KeyHints.help("Overgit", command: "overgit.show", keys: plain), "Overgit (⌥⌘G)")
        XCTAssertEqual(KeyHints.help("Files", command: "files.show", keys: plain), "Files", "unbound: the title alone")
        XCTAssertNil(KeyHints.text("%@ jumps", command: "files.show", keys: plain), "no hint with a gap in it")
        let rebound = try keys(#"[{ "key": "ctrl+alt+cmd+i", "command": "inbox.show" }]"#)
        XCTAssertEqual(KeyHints.text("J / K to move · %@ to close", command: "inbox.show", keys: rebound), "J / K to move · ⌃⌥⌘I to close")
        XCTAssertEqual(SidebarRailAction.settings.help(keys: rebound), "Settings (⌘,)")
    }

    /// DISC-U4: every panel with a command of its own names it; Docker's
    /// and Kubernetes' open their page instead.
    func testEveryPanelsCommandIsACommand() {
        for panel in SidebarPanel.allCases {
            guard let id = panel.commandID else {
                XCTAssertTrue([.docker, .kubernetes].contains(panel))
                continue
            }
            XCTAssertNotNil(KeyCommands.byID[id], "\(panel) → \(id)")
        }
    }

    /// DISC-U8: Files, Sessions, Snippets and the simulator are in the menu.
    func testThePanelsAndTheSimulatorAreInTheMenu() {
        let ids = Self.identifiers(in: MainMenu.build())
        for id in ["files.show", "sessions.show", "snippets.show", "simulator.toggle", "help.keysHere"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    /// DISC-U6: a page's sheet groups its keys, each once, and adds the
    /// window's commands that are the page's.
    func testThePagesSheetsAreGrouped() {
        let docker = KeySheet.groups(of: DockerKey.self)
        XCTAssertEqual(docker.map(\.title), ["Navigation", "The selection", "Compose", "The page", "Sections"])
        XCTAssertEqual(docker.flatMap(\.rows).count, DockerKey.allCases.count)
        let activity = KeySheet.groups(of: ActivityKey.self)
        XCTAssertEqual(activity.flatMap(\.rows).count, ActivityKey.allCases.count)
        XCTAssertTrue(activity.contains { $0.title == "Verbs — each asked first" })
        let window = KeySheet.commands(KeySheet.commands(prefixed: ["docker."]), title: KeySheet.windowGroup) { _ in nil }
        XCTAssertEqual(window?.rows.first?.key, KeySheet.unbound)
        XCTAssertTrue(window?.rows.contains { $0.title == "Docker Switcher" } == true)
    }

    /// DISC-U7: the filter's tooltip is `/`'s line in `?`.
    func testTheFilterTooltipIsTheKeysLine() {
        XCTAssertEqual(DockerKey.filterHelp, "status:running project:api port:5432 is:test — ? lists the keys")
        XCTAssertTrue(ResourceKeys.filterHelp(KubernetesKey.filter.title).hasPrefix("web status:crashloopbackoff"))
    }

    /// DISC-U5: Review's keys, `?` among them.
    func testReviewsKeys() {
        XCTAssertEqual(ReviewKey.of("j"), .nextFile)
        XCTAssertEqual(ReviewKey.of("V"), .viewed)
        XCTAssertEqual(ReviewKey.of("?"), .help)
        XCTAssertNil(ReviewKey.of("x"))
        let rows = ReviewKey.groups { _ in nil }.flatMap(\.rows).map(\.key)
        XCTAssertEqual(Array(rows.prefix(6)), ["j", "k", "n", "p", "v", "?"])
    }

    /// DISC-N1: each surface's sheet, from the commands and the bindings now.
    func testKeysHere() throws {
        let rebound = try keys(#"[{ "key": "ctrl+cmd+t", "command": "tabs.new" }]"#)
        let terminal = KeySheet.Surface.terminal.groups { rebound.key(for: $0)?.display }
        XCTAssertEqual(terminal.map(\.title), ["Terminal", "Tabs", "Panes", "Groups", KeySheet.windowGroup])
        XCTAssertTrue(terminal.flatMap(\.rows).contains(KeySheetRow(key: "⌃⌘T", title: "New Tab")))
        XCTAssertEqual(KeySheet.Surface.editor.groups { _ in nil }.first?.title, "Editor")
        XCTAssertTrue(KeySheet.Surface.browser.groups { _ in nil }.first?.rows.contains { $0.key == "⌘L" } == true)
    }

    private static func identifiers(in menu: NSMenu) -> Set<String> {
        var ids = Set<String>()
        for item in menu.items {
            if let id = item.identifier?.rawValue { ids.insert(id) }
            if let sub = item.submenu { ids.formUnion(identifiers(in: sub)) }
        }
        return ids
    }
}
