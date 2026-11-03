import XCTest

@testable import Overterm

/// The strip's "N need you": it follows each tab's mark, not only the store.
@MainActor
final class AttentionWatchTests: XCTestCase {
    private func settle() async {
        // The watch reads the tabs a main-queue turn after a change.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    func testFollowsATabsMarkWithoutTheStore() async {
        let store = TabStore()
        let first = Tab(terminal: TerminalView())
        let second = Tab(terminal: TerminalView())
        store.insert(first, after: nil)
        store.insert(second, after: first)
        let watch = AttentionWatch(store: store)
        XCTAssertTrue(watch.waiting.isEmpty)

        first.activity.containerFailed("db exited", visible: false)
        await settle()
        XCTAssertEqual(watch.waiting.map(\.id), [first.id])

        // Seen: the tab's own activity changes, the store says nothing.
        first.activity.seen()
        await settle()
        XCTAssertTrue(watch.waiting.isEmpty, "a cleared mark still counted")
    }

    func testAClosedTabNoLongerCounts() async {
        let store = TabStore()
        let tab = Tab(terminal: TerminalView())
        store.insert(tab, after: nil)
        let watch = AttentionWatch(store: store)
        tab.activity.containerFailed("db exited", visible: false)
        await settle()
        XCTAssertEqual(watch.waiting.count, 1)
        store.remove(tab)
        await settle()
        XCTAssertTrue(watch.waiting.isEmpty)
    }
}
