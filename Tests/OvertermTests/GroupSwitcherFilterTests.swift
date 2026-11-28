import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// ⌃⌘G typed into (GRP-U1): the islands that match by name or by a tab,
/// and the highlighted one's tabs.
@MainActor
final class GroupSwitcherFilterTests: XCTestCase {
    private var store = TabStore()

    private func tab(_ name: String) -> Tab {
        let tab = Tab(terminal: TerminalView())
        tab.customTitle = name
        store.insert(tab, after: store.tabs.last)
        return tab
    }

    func testIslandsAreFilteredByTheirNameOrATabsTitle() throws {
        let api = try XCTUnwrap(store.addToNewGroup([tab("server"), tab("tests")], name: "shop-api"))
        let web = try XCTUnwrap(store.addToNewGroup([tab("vite"), tab("billing page")], name: "web"))
        let all = GroupSwitcherFilter.order(store)
        XCTAssertEqual(all.map(\.name), ["shop-api", "web"])
        func shown(_ query: String) -> [String] { GroupSwitcherFilter.groups(all, tabs: { self.store.tabs(in: $0) }, query: query).map(\.name) }
        XCTAssertEqual(shown(""), ["shop-api", "web"])
        XCTAssertEqual(shown("shop"), ["shop-api"])
        XCTAssertEqual(shown("vite"), ["web"], "by a tab's title")
        XCTAssertEqual(shown("SAPI"), ["shop-api"], "the palette's fuzzy match, any case")
        XCTAssertEqual(shown("zzz"), [])
        // The tab column: all of an island matched by name, else its matching tabs.
        XCTAssertEqual(GroupSwitcherFilter.tabs(of: api, store.tabs(in: api), query: "shop").map(\.title), ["server", "tests"])
        XCTAssertEqual(GroupSwitcherFilter.tabs(of: web, store.tabs(in: web), query: "bill").map(\.title), ["billing page"])
    }

    func testTypingAndDeleting() {
        XCTAssertEqual(GroupSwitcherFilter.query("sh", typing: "o", delete: false, modifiers: false), "sho")
        XCTAssertEqual(GroupSwitcherFilter.query("sho", typing: nil, delete: true, modifiers: false), "sh")
        XCTAssertNil(GroupSwitcherFilter.query("", typing: nil, delete: true, modifiers: false), "⌫ on nothing types nothing")
        XCTAssertNil(GroupSwitcherFilter.query("sh", typing: "k", delete: false, modifiers: true), "a shortcut isn't typing")
        XCTAssertNil(GroupSwitcherFilter.query("sh", typing: "\u{F700}", delete: false, modifiers: false), "an arrow isn't typing")
        XCTAssertNil(GroupSwitcherFilter.query("sh", typing: "\r", delete: false, modifiers: false))
    }
}
