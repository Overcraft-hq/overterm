import AppKit
import XCTest

@testable import Overterm

/// A resource's verbs as an AppKit menu (`ResourceVerbMenuItem.items`):
/// the order and dividers its SwiftUI menu has, the reason a verb is
/// unavailable, submenus, and what a press runs.
@MainActor
final class ResourceVerbTests: XCTestCase {
    private func titles(_ items: [NSMenuItem]) -> [String] { items.map { $0.isSeparatorItem ? "—" : $0.title } }

    func testTheMenuIsTheButtonsThenMoreThenRemovalApart() {
        let verbs = [
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc"),
            ResourceVerb(title: "Remove…", symbol: "trash", place: .remove),
            ResourceVerb(title: "Stop", symbol: "stop.fill", place: .button),
            ResourceVerb(title: "Restart", symbol: "arrow.clockwise", place: .button),
        ]
        XCTAssertEqual(titles(ResourceVerbMenuItem.items(verbs)), ["Stop", "Restart", "—", "Copy Name", "—", "Remove…"])
        XCTAssertEqual(titles(ResourceVerbMenuItem.items(verbs.filter { $0.place == .more })), ["Copy Name"], "no divider before the first")
        XCTAssertTrue(ResourceVerbMenuItem.items([]).isEmpty)
    }

    func testADividerWhereTheGroupChanges() {
        let verbs = [
            ResourceVerb(title: "Pause", symbol: "pause"),
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 2),
            ResourceVerb(title: "Copy ID", symbol: "number", group: 2),
            ResourceVerb(title: "Rename…", symbol: "pencil", group: 3),
        ]
        XCTAssertEqual(titles(ResourceVerbMenuItem.items(verbs)), ["Pause", "—", "Copy Name", "Copy ID", "—", "Rename…"])
    }

    func testAnUnavailableVerbIsDisabledWithItsReason() {
        let shell = ResourceVerb(title: "Open a Shell in a Tab", symbol: "terminal", key: "e", unavailable: "It isn't running.")
        let item = ResourceVerbMenuItem.items([shell])[0]
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.toolTip, "It isn't running.")
        XCTAssertEqual(shell.help, "Open a Shell in a Tab (e) — It isn't running.")
        let stop = ResourceVerb(title: "Stop", symbol: "stop.fill")
        XCTAssertTrue(ResourceVerbMenuItem.items([stop])[0].isEnabled)
        XCTAssertNil(ResourceVerbMenuItem.items([stop])[0].toolTip)
        XCTAssertEqual(stop.help, "Stop")
    }

    func testAPressRunsTheVerbAndChildrenAreASubmenu() throws {
        var ran: [String] = []
        let verbs = [
            ResourceVerb(title: "Restart", symbol: "arrow.clockwise") { ran.append("restart") },
            ResourceVerb(
                title: "Connect a Container", symbol: "link",
                children: [
                    ResourceVerb(title: "web", symbol: "shippingbox") { ran.append("web") },
                    ResourceVerb(title: "db", symbol: "shippingbox", group: 1) { ran.append("db") },
                ]),
        ]
        let items = ResourceVerbMenuItem.items(verbs)
        XCTAssertEqual(titles(items), ["Restart", "Connect a Container"])
        let restart = items[0]
        _ = try XCTUnwrap(restart.target as? NSObject).perform(try XCTUnwrap(restart.action), with: restart)
        XCTAssertEqual(ran, ["restart"])

        let parent = items[1]
        XCTAssertTrue(parent.hasSubmenu, "its children a submenu")
        let submenu = try XCTUnwrap(parent.submenu)
        XCTAssertEqual(titles(submenu.items), ["web", "—", "db"])
        let db = submenu.items[2]
        _ = try XCTUnwrap(db.target as? NSObject).perform(try XCTUnwrap(db.action), with: db)
        XCTAssertEqual(ran, ["restart", "db"])
    }

    func testAVerbIsKnownByItsTitle() {
        XCTAssertEqual(ResourceVerb(title: "Copy ID", symbol: "number").id, "Copy ID")
        XCTAssertEqual(ResourceVerb(title: "Copy ID", label: "ID", symbol: "number").id, "Copy ID", "not its label")
    }
}
