import XCTest

@testable import Overterm
@testable import OvertermCore

/// Tab Peek typed into (PEEK-U1) and what it shows (PEEK-U2).
@MainActor
final class TabPeekFilterTests: XCTestCase {
    func testACardIsFoundByItsTitleCheckoutOrAgent() {
        let entry = TabPeekModel.Entry(title: "billing page", color: nil, activity: TabActivity(), agent: .claude, panes: 1, checkout: "fix-coupons")
        XCTAssertTrue(entry.matches(""))
        XCTAssertTrue(entry.matches("bill"))
        XCTAssertTrue(entry.matches("coupons"), "its checkout")
        XCTAssertTrue(entry.matches("claude"), "its agent")
        XCTAssertFalse(entry.matches("vite"))
    }

    func testTheFilterDimsWithoutMovingAnyCard() {
        let model = TabPeekModel()
        let ids = [UUID(), UUID(), UUID()]
        model.cards = ids.enumerated().map { index, id in
            TabPeek.Card(id: id, frame: CGRect(x: index * 100, y: 0, width: 90, height: 60), content: CGRect(x: index * 100, y: 22, width: 90, height: 38), isSelected: false)
        }
        for (id, title) in zip(ids, ["server", "vite", "vitest"]) {
            model.entries[id] = TabPeekModel.Entry(title: title, color: nil, activity: TabActivity(), agent: nil, panes: 1)
        }
        model.query = "vit"
        XCTAssertEqual(model.cards.map(\.id), ids, "every card stays where it was")
        XCTAssertEqual(model.shownCards.map(\.id), Array(ids[1...]))
        XCTAssertFalse(model.matches(ids[0]))
        model.query = ""
        XCTAssertEqual(model.shownCards.count, 3)
    }

    func testPeekShowsWhatTheStripOffers() throws {
        let store = TabStore()
        func tab(_ name: String) -> Tab {
            let tab = Tab(terminal: TerminalView())
            tab.customTitle = name
            store.insert(tab, after: store.tabs.last)
            return tab
        }
        let loose = tab("loose")
        let api = try XCTUnwrap(store.addToNewGroup([tab("server"), tab("tests")], name: "shop-api"))
        let web = try XCTUnwrap(store.addToNewGroup([tab("vite")], name: "web"))
        XCTAssertEqual(store.stripTabs.map(\.title), ["loose", "server", "tests", "vite"])
        store.stash(web)
        XCTAssertEqual(store.stripTabs.map(\.title), ["loose", "server", "tests"], "a stashed island's tabs aren't offered")
        store.setFocused(api)
        XCTAssertEqual(store.stripTabs.map(\.title), ["server", "tests"], "focusing, only that island's")
        store.setFocused(nil)
        XCTAssertTrue(store.stripTabs.contains { $0 === loose })
    }
}
