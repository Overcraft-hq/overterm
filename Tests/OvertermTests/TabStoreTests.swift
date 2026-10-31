import XCTest

@testable import Overterm

/// Tab logic on real Tabs. The Ghostty runtime is never initialized in the
/// unit-test process, so each TerminalView is surfaceless: no ptys.
@MainActor
final class TabStoreTests: XCTestCase {
    private func tab(_ name: String) -> Tab {
        let tab = Tab(terminal: TerminalView())
        tab.customTitle = name
        return tab
    }

    private func titles(_ store: TabStore) -> [String] { store.tabs.map(\.title) }

    func testSurfacelessWithoutTheRuntime() {
        XCTAssertNil(TerminalView().surface, "unit tests must not spawn shells")
    }

    func testNewTabGoesRightAfterTheAnchorAndIsSelected() {
        let store = TabStore()
        let a = tab("a"), b = tab("b"), c = tab("c")
        store.insert(a, after: nil)
        store.insert(b, after: a)
        store.insert(c, after: a)
        XCTAssertEqual(titles(store), ["a", "c", "b"])
        XCTAssertEqual(store.selected?.title, "c")
    }

    func testClosingTheSelectedTabSelectsItsRightNeighbourElseLeft() {
        let store = TabStore()
        let a = tab("a"), b = tab("b"), c = tab("c")
        [a, b, c].forEach { store.insert($0, after: store.tabs.last) }
        store.select(b)
        store.remove(b)
        XCTAssertEqual(store.selected?.title, "c")
        store.remove(c)
        XCTAssertEqual(store.selected?.title, "a")
        store.remove(a)
        XCTAssertNil(store.selected)
    }

    func testClosingAnotherTabKeepsTheSelection() {
        let store = TabStore()
        let a = tab("a"), b = tab("b")
        [a, b].forEach { store.insert($0, after: store.tabs.last) }
        store.select(a)
        store.remove(b)
        XCTAssertEqual(store.selected?.title, "a")
    }

    func testPinnedTabsStayFirst() {
        let store = TabStore()
        let a = tab("a"), b = tab("b"), c = tab("c")
        [a, b, c].forEach { store.insert($0, after: store.tabs.last) }
        store.setPinned(c, true)
        XCTAssertEqual(titles(store), ["c", "a", "b"])
        store.setPinned(b, true)
        XCTAssertEqual(titles(store), ["c", "b", "a"], "pinning appends to the pinned group")
        store.setPinned(c, false)
        XCTAssertEqual(titles(store), ["b", "c", "a"], "unpinning puts it first after the group")
    }

    func testNewTabFromAPinnedTabLandsAfterThePinnedGroup() {
        let store = TabStore()
        let a = tab("a"), b = tab("b"), n = tab("new")
        [a, b].forEach { store.insert($0, after: store.tabs.last) }
        store.setPinned(a, true)
        store.setPinned(b, true)
        store.insert(n, after: a)
        XCTAssertEqual(titles(store), ["a", "b", "new"])
    }

    func testMovesStayInsideTheirGroup() {
        let store = TabStore()
        let p = tab("p"), a = tab("a"), b = tab("b")
        [p, a, b].forEach { store.insert($0, after: store.tabs.last) }
        store.setPinned(p, true)
        store.move(a, by: -5)
        XCTAssertEqual(titles(store), ["p", "a", "b"], "an unpinned tab can't cross into the pinned group")
        store.move(a, by: 1)
        XCTAssertEqual(titles(store), ["p", "b", "a"])
        store.move(p, by: 3)
        XCTAssertEqual(titles(store), ["p", "b", "a"])
        store.move(a, to: p)
        XCTAssertEqual(titles(store), ["p", "b", "a"], "drag across groups is refused")
        store.move(a, to: b)
        XCTAssertEqual(titles(store), ["p", "a", "b"])
    }

    func testDragMoveSlotsAfterTheMiddlesPassed() {
        let store = TabStore()
        let a = tab("a"), b = tab("b"), c = tab("c")
        [a, b, c].forEach { store.insert($0, after: store.tabs.last) }
        store.tabFrames = [a.id: CGRect(x: 80, y: 0, width: 100, height: 28), b.id: CGRect(x: 180, y: 0, width: 100, height: 28), c.id: CGRect(x: 280, y: 0, width: 100, height: 28)]
        store.dragMove(c, toPointerX: 100)
        XCTAssertEqual(titles(store), ["c", "a", "b"], "left of a's middle: first")
        // Frames not yet updated (the strip lags): the same pointer changes nothing.
        store.dragMove(c, toPointerX: 100)
        store.dragMove(c, toPointerX: 110)
        XCTAssertEqual(titles(store), ["c", "a", "b"], "no flip-flop on stale frames")
        store.dragMove(c, toPointerX: 250)
        XCTAssertEqual(titles(store), ["a", "b", "c"], "past b's middle: last")
    }

    func testDragMoveStaysInItsGroup() {
        let store = TabStore()
        let p = tab("p"), a = tab("a")
        [p, a].forEach { store.insert($0, after: store.tabs.last) }
        store.setPinned(p, true)
        store.tabFrames = [p.id: CGRect(x: 80, y: 0, width: 38, height: 28), a.id: CGRect(x: 120, y: 0, width: 100, height: 28)]
        store.dragMove(a, toPointerX: 0)
        XCTAssertEqual(titles(store), ["p", "a"], "an unpinned tab stops after the pinned group")
    }

    func testAdjacentWrapsAndIndexSelectionClamps() {
        let store = TabStore()
        let a = tab("a"), b = tab("b")
        [a, b].forEach { store.insert($0, after: store.tabs.last) }
        store.selectAdjacent(1)
        XCTAssertEqual(store.selected?.title, "a", "wraps past the end")
        store.selectAdjacent(-1)
        XCTAssertEqual(store.selected?.title, "b", "wraps past the start")
        store.select(index: 9)
        XCTAssertEqual(store.selected?.title, "b", "out of range is ignored")
    }

    func testReselectingDoesNotPublish() {
        // A publish makes the window focus the terminal, which ended an
        // in-place rename the moment it began.
        let store = TabStore()
        let a = tab("a")
        store.insert(a, after: nil)
        var publishes = 0
        let sub = store.$selectedID.dropFirst().sink { _ in publishes += 1 }
        store.select(a)
        XCTAssertEqual(publishes, 0)
        sub.cancel()
    }

    func testTitleFollowsTheShellUnlessRenamed() {
        let t = Tab(terminal: TerminalView(workingDirectory: "/tmp/project"))
        XCTAssertEqual(t.title, "project", "starts as the directory name")
        t.shellTitle = "vim main.go"
        XCTAssertEqual(t.title, "vim main.go")
        t.customTitle = "feat/x"
        XCTAssertEqual(t.title, "feat/x")
        t.customTitle = nil
        XCTAssertEqual(t.title, "vim main.go")
    }

    func testTabAtPointUsesReportedFrames() {
        let store = TabStore()
        let a = tab("a"), b = tab("b")
        [a, b].forEach { store.insert($0, after: store.tabs.last) }
        store.tabFrames = [a.id: CGRect(x: 80, y: 0, width: 200, height: 28), b.id: CGRect(x: 284, y: 0, width: 200, height: 28)]
        XCTAssertEqual(store.tab(at: CGPoint(x: 100, y: 10))?.title, "a")
        XCTAssertEqual(store.tab(at: CGPoint(x: 300, y: 10))?.title, "b")
        XCTAssertNil(store.tab(at: CGPoint(x: 20, y: 10)), "the traffic-light inset is no tab")
    }

    func testCloseWarning() {
        let idle = tab("idle")
        XCTAssertEqual(TerminalWindowController.closeWarning(for: [idle]), "Its shell is idle.")
        XCTAssertEqual(TerminalWindowController.closeWarning(for: [idle, tab("b")]), "Their shells are idle.")
    }

    func testAPageCoversTheSelectedTabWithoutTakingItsSelection() {
        let store = TabStore()
        let a = tab("a")
        store.insert(a, after: nil)
        store.showOverlay(.settings)
        store.showOverlay(.settings)
        XCTAssertEqual(store.openOverlays, [.settings], "shown twice, in the strip once")
        XCTAssertEqual(store.showingOverlay, .settings)
        XCTAssertEqual(store.selected?.title, "a", "the terminal tab stays selected underneath")

        store.hideOverlay()
        XCTAssertNil(store.showingOverlay)
        XCTAssertEqual(store.openOverlays, [.settings], "hidden, it stays in the strip")

        store.showOverlay(.settings)
        store.closeOverlay(.settings)
        XCTAssertNil(store.showingOverlay)
        XCTAssertTrue(store.openOverlays.isEmpty)
    }
}

@MainActor
final class CheckoutSourceTests: XCTestCase {
    func testAttachedBeatsAgentBeatsShell() {
        let tab = Tab(terminal: TerminalView(workingDirectory: "/tmp"), agent: .claude)
        XCTAssertEqual(tab.checkoutSource?.reason, .shell)
        tab.agentDirectory = "/var"
        XCTAssertEqual(tab.checkoutSource?.reason, .agent(.claude))
        XCTAssertEqual(tab.checkoutSource?.root.path, "/var")
        tab.attachedCheckout = URL(fileURLWithPath: "/usr")
        XCTAssertEqual(tab.checkoutSource?.reason, .attached)
        XCTAssertEqual(tab.checkoutSource?.root.path, "/usr")
        tab.attachedCheckout = nil
        XCTAssertEqual(tab.checkoutSource?.reason, .agent(.claude), "detach goes back to following the agent")
    }

    func testAgentProcessesAreRecognized() {
        func node(_ name: String, _ command: String) -> ProcessNode {
            ProcessNode(pid: 1, parent: 0, name: name, command: command, cpuPercent: 0, memory: 0, workingDirectory: nil)
        }
        XCTAssertTrue(TerminalWindowController.isAgent(node("claude", "claude --continue")))
        XCTAssertTrue(TerminalWindowController.isAgent(node("node", "/Users/b/.local/bin/codex resume --last")))
        XCTAssertFalse(TerminalWindowController.isAgent(node("zsh", "-zsh")))
        XCTAssertFalse(TerminalWindowController.isAgent(node("vim", "vim claude.md")))
    }

}
