import XCTest

@testable import Overterm

/// Groups on real Tabs. The Ghostty runtime is never initialized in the
/// unit-test process, so each TerminalView is surfaceless: no ptys.
@MainActor
final class TabGroupTests: XCTestCase {
    private var store = TabStore()

    override func setUp() async throws {
        store = TabStore()
    }

    @discardableResult
    private func tab(_ name: String) -> Tab {
        let tab = Tab(terminal: TerminalView())
        tab.customTitle = name
        store.insert(tab, after: store.tabs.last)
        return tab
    }

    private var order: [String] { store.tabs.map(\.title) }

    private func islands(_ strip: [TabStrip]) -> [String] {
        strip.map {
            switch $0 {
            case .group(let g, let tabs): "[\(g.name): \(tabs.map(\.title).joined(separator: ","))]"
            case .loose(let t): t.title
            }
        }
    }

    // MARK: Restoring

    /// A session comes back island by island: every group is there before
    /// its tabs are. The first tab of the first island used to prune the
    /// others as empty, and their tabs came back loose.
    func testRestoringTwoIslandsBringsBothBack() {
        let work = TabGroup(name: "work", color: .blue)
        let play = TabGroup(name: "play", color: .green)
        store.groups = [work, play]
        store.restoring = true
        for (name, group) in [("a", work), ("b", work), ("c", play), ("d", play)] {
            let tab = Tab(terminal: TerminalView())
            tab.customTitle = name
            store.insert(tab, after: store.tabs.last, joining: group.id)
        }
        store.restoring = false
        store.normalize()
        XCTAssertEqual(islands(store.strip), ["[work: a,b]", "[play: c,d]"])
    }

    /// Whatever happens to its island, a tab stays in the strip.
    func testATabWhoseIslandIsGoneStaysLoose() {
        let a = tab("a"), b = tab("b")
        store.addToNewGroup([b], name: "gone")
        store.groups.removeAll()
        store.normalize()
        XCTAssertEqual(order, ["a", "b"])
        XCTAssertNil(b.groupID)
        XCTAssertNil(a.groupID)
    }

    // MARK: Making a group

    func testAGroupGathersItsTabsWhereTheFirstOneIs() {
        let a = tab("a"), b = tab("b"), c = tab("c"), d = tab("d")
        store.addToNewGroup([b, d], name: "work")
        XCTAssertEqual(order, ["a", "b", "d", "c"], "the island lands where its first tab was")
        XCTAssertEqual(b.groupID, d.groupID)
        XCTAssertNil(a.groupID)
        XCTAssertNil(c.groupID)
    }

    func testMembersKeepTheStripsOrderNotTheArgumentsOrder() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        store.addToNewGroup([c, a], name: "work")
        XCTAssertEqual(order, ["a", "c", "b"])
    }

    func testTheStripReadsIslandsAndLooseTabs() {
        let a = tab("a"), b = tab("b"), c = tab("c"), d = tab("d")
        store.addToNewGroup([b, c], name: "work")
        _ = a
        _ = d
        XCTAssertEqual(islands(store.strip), ["a", "[work: b,c]", "d"])
    }

    func testAnEmptyGroupIsNotAGroup() {
        let a = tab("a"), b = tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        XCTAssertEqual(store.groups.count, 1)
        store.remove(a)
        XCTAssertTrue(store.groups.isEmpty, "closing the last tab takes its island with it")
        XCTAssertNil(store.group(group.id))
        XCTAssertEqual(order, ["b"])
        _ = b
    }

    func testUngroupLeavesTheTabsWhereTheyAre() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        let group = store.addToNewGroup([a, b], name: "work")!
        store.ungroup(group)
        XCTAssertEqual(order, ["a", "b", "c"])
        XCTAssertTrue(store.tabs.allSatisfy { $0.groupID == nil })
        XCTAssertTrue(store.groups.isEmpty)
        _ = c
    }

    func testATabCanLeaveItsIslandAlone() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        store.addToNewGroup([a, b, c], name: "work")
        store.removeFromGroup([b])
        XCTAssertNil(b.groupID)
        // a and c stay one run, so b is pushed out of the middle rather
        // than splitting the island in two.
        XCTAssertEqual(order, ["a", "c", "b"])
        XCTAssertEqual(islands(store.strip), ["[work: a,c]", "b"])
    }

    // MARK: New tabs

    func testANewTabDoesNotJoinTheAnchorsIsland() {
        let a = tab("a"), b = tab("b")
        store.addToNewGroup([a], name: "work")
        let fresh = Tab(terminal: TerminalView())
        fresh.customTitle = "new"
        store.insert(fresh, after: a)
        XCTAssertNil(fresh.groupID, "an island is joined on purpose, never by inheritance (NewTabGroup)")
        XCTAssertEqual(islands(store.strip), ["[work: a]", "new", "b"], "and it lands after the island's run")
        XCTAssertEqual(order, ["a", "new", "b"])
    }

    func testANewTabJoinsTheIslandItIsOpenedIn() {
        let a = tab("a")
        let group = store.addToNewGroup([a], name: "work")!
        let fresh = Tab(terminal: TerminalView())
        fresh.customTitle = "new"
        store.insert(fresh, after: a, joining: group.id)
        XCTAssertEqual(fresh.groupID, group.id)
        XCTAssertEqual(islands(store.strip), ["[work: a,new]"])
    }

    func testThePlacementOfANewTabReadsTheStrip() {
        let a = tab("a"), b = tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        XCTAssertEqual(store.placementForNewTab(.here, after: a, in: nil), .loose, "b is outside the island")
        store.add([b], to: group)
        XCTAssertEqual(
            store.placementForNewTab(.here, after: a, in: nil), .ask(group.id),
            "with the island holding every tab, there is nothing to read the intent from")
        group.takesNewTabs = true
        XCTAssertEqual(store.placementForNewTab(.here, after: a, in: nil), .join(group.id))
    }

    func testABoundFolderTakesATabOpenedUnderIt() {
        let a = tab("a")
        tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        group.folder = "/tmp/repo"
        XCTAssertEqual(store.placementForNewTab(.folder, after: nil, in: "/tmp/repo/src"), .join(group.id))
        XCTAssertEqual(
            store.placementForNewTab(.folder, after: nil, in: "/tmp/repository"), .loose, "a prefix is not a parent")
        XCTAssertEqual(store.placementForNewTab(.folder, after: nil, in: nil), .loose)
        XCTAssertEqual(
            store.placementForNewTab(.here, after: a, in: "/tmp/repo"), .loose,
            "⌘T in the island's own folder is not someone opening that folder")
    }

    func testANewGroupDoesNotBindItsFolder() {
        let a = tab("a")
        let group = store.addToNewGroup([a], name: nil)!
        XCTAssertNil(group.folder, "binding every tab opened in the folder is a decision, not a default")
    }

    func testATabOpenedFromALooseTabStaysLoose() {
        let a = tab("a")
        let fresh = Tab(terminal: TerminalView())
        fresh.customTitle = "new"
        store.insert(fresh, after: a)
        XCTAssertNil(fresh.groupID)
    }

    // MARK: Pinning

    func testGroupingAPinnedTabUnpinsIt() {
        let a = tab("a"), b = tab("b")
        store.setPinned(a, true)
        store.addToNewGroup([a, b], name: "work")
        XCTAssertFalse(a.isPinned, "pinned tabs are the strip's left edge; an island can't sit in front of them")
        XCTAssertEqual(islands(store.strip), ["[work: a,b]"])
    }

    func testPinnedTabsStayInFrontOfEveryIsland() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        store.addToNewGroup([a, b], name: "work")
        store.setPinned(c, true)
        store.normalize()
        XCTAssertEqual(order, ["c", "a", "b"])
    }

    // MARK: The invariant holds

    func testNormalizeIsIdempotent() {
        let a = tab("a"), b = tab("b"), c = tab("c"), d = tab("d")
        store.addToNewGroup([a, c], name: "one")
        store.addToNewGroup([b, d], name: "two")
        let once = order
        store.normalize()
        store.normalize()
        XCTAssertEqual(order, once, "the strip reports frames a moment late; a drag must not oscillate")
    }

    func testEveryGroupsTabsAreOneRun() {
        let tabs = (0..<6).map { tab("t\($0)") }
        store.addToNewGroup([tabs[0], tabs[3], tabs[5]], name: "one")
        store.addToNewGroup([tabs[1], tabs[4]], name: "two")
        for group in store.groups {
            let positions = store.tabs.enumerated().filter { $0.element.groupID == group.id }.map(\.offset)
            XCTAssertEqual(positions, Array(positions.first!...positions.last!), "\(group.name) is not contiguous")
        }
    }

    func testMovingAnIslandMovesAllOfIt() {
        let a = tab("a"), b = tab("b"), c = tab("c"), d = tab("d")
        let one = store.addToNewGroup([a, b], name: "one")!
        let two = store.addToNewGroup([c, d], name: "two")!
        store.move(two, before: one)
        XCTAssertEqual(islands(store.strip), ["[two: c,d]", "[one: a,b]"])
    }

    // MARK: Collapsing, stashing, focusing

    func testCollapsingMovesTheSelectionOut() {
        let a = tab("a"), b = tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        store.select(a)
        store.setCollapsed(group, true)
        XCTAssertEqual(store.selectedID, b.id, "the selected tab must not be invisible")
    }

    func testStashingTakesTheIslandOutOfTheStripButKeepsItsTabs() {
        let a = tab("a"), b = tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        store.select(a)
        store.stash(group)
        XCTAssertEqual(islands(store.strip), ["b"])
        XCTAssertEqual(store.selectedID, b.id)
        XCTAssertTrue(store.tabs.contains { $0 === a }, "stashing closes nothing — the processes keep running")
        XCTAssertEqual(store.visibleTabs.map(\.title), ["b"])
        XCTAssertEqual(store.stashedGroups.map(\.name), ["work"])
        XCTAssertNotNil(group.stashedAt)
    }

    func testRestoringBringsItBackAndSelectsIt() {
        let a = tab("a")
        _ = tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        store.stash(group)
        store.restore(group)
        XCTAssertEqual(islands(store.strip), ["[work: a]", "b"])
        XCTAssertEqual(store.selectedID, a.id)
        XCTAssertNil(group.stashedAt)
    }

    func testAStashedGroupIsNotPrunedWhileItHasNoVisibleTabs() {
        let a = tab("a")
        _ = tab("b")
        let group = store.addToNewGroup([a], name: "work")!
        store.stash(group)
        store.pruneEmptyGroups()
        XCTAssertEqual(store.stashedGroups.count, 1, "a stashed group outlives the strip")
    }

    func testFocusNarrowsTheStripToOneIsland() {
        let a = tab("a"), b = tab("b"), c = tab("c")
        let one = store.addToNewGroup([a], name: "one")!
        store.addToNewGroup([b], name: "two")
        store.select(c)
        store.setFocused(one)
        XCTAssertEqual(islands(store.focusedStrip), ["[one: a]"])
        XCTAssertEqual(store.selectedID, a.id, "focusing moves the selection into the group")
        store.setFocused(nil)
        XCTAssertEqual(islands(store.focusedStrip), ["[one: a]", "[two: b]", "c"])
    }

    // MARK: Folders

    func testTheMostSpecificFolderBindingWins() {
        let a = tab("a"), b = tab("b")
        store.addToNewGroup([a], name: "repo", folder: "/src/repo")
        let inner = store.addToNewGroup([b], name: "worktree", folder: "/src/repo/wt")!
        XCTAssertEqual(store.group(forDirectory: "/src/repo/wt/apps")?.id, inner.id)
        XCTAssertEqual(store.group(forDirectory: "/src/repo/apps")?.name, "repo")
        XCTAssertNil(store.group(forDirectory: "/elsewhere"))
        XCTAssertNil(store.group(forDirectory: nil))
    }

    func testAFolderPrefixMustBeAWholePathComponent() {
        let a = tab("a")
        store.addToNewGroup([a], name: "repo", folder: "/src/repo")
        XCTAssertNil(store.group(forDirectory: "/src/repo-other"), "repo-other is not inside repo")
    }

    func testAStashedGroupTakesNoNewTabs() {
        let a = tab("a")
        let group = store.addToNewGroup([a], name: "repo", folder: "/src/repo")!
        store.stash(group)
        XCTAssertNil(store.group(forDirectory: "/src/repo"))
    }

    // MARK: Naming and colour

    func testANewGroupIsNamedAfterItsFolder() {
        XCTAssertEqual(TabGroup.name(for: "/src/klaim-monorepo"), "klaim-monorepo")
        XCTAssertEqual(TabGroup.name(for: nil), "Group")
        XCTAssertEqual(TabGroup.name(for: ""), "Group")
        XCTAssertEqual(TabGroup.name(for: "/"), "Group")
    }

    func testNeighbouringIslandsNeverShareAColour() {
        var used: [TabColor] = []
        for _ in 0..<5 {
            let next = TabGroup.color(after: used)
            XCTAssertFalse(used.contains(next))
            used.append(next)
        }
        XCTAssertFalse(used.contains(.gray), "grey is the no-colour tab, not a group colour")
    }

    // MARK: What the strip shows

    func testAPathOnlyTitleIsCutToItsFolder() {
        XCTAssertEqual(Tab.shortened("/Users/me/Documents/m1"), "m1")
        XCTAssertEqual(Tab.shortened("~/Documents/opensource/terminus"), "terminus")
        XCTAssertEqual(Tab.shortened("src/app/"), "app")
        XCTAssertEqual(Tab.shortened("/Users/me/Documents/m1//"), "m1")
    }

    func testAnythingThatIsNotJustAPathIsLeftAlone() {
        // The title is the only thing a tab says; cutting these loses it.
        XCTAssertEqual(Tab.shortened("pnpm dev"), "pnpm dev")
        XCTAssertEqual(Tab.shortened("nvim src/main.swift"), "nvim src/main.swift")
        XCTAssertEqual(Tab.shortened("claude"), "claude")
        XCTAssertEqual(Tab.shortened("~"), "~")
        XCTAssertEqual(Tab.shortened(""), "")
        XCTAssertEqual(Tab.shortened("/"), "/")
    }

    func testACustomNameStillWins() {
        let tab = Tab(terminal: TerminalView())
        tab.shellTitle = "/Users/me/Documents/m1"
        XCTAssertEqual(tab.title, "m1")
        tab.customTitle = "api"
        XCTAssertEqual(tab.title, "api", "a name you gave it is never shortened")
    }

    func testStashedAgoReadsCoarsely() {
        let now = Date()
        XCTAssertEqual(TabGroup.stashedAgo(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(TabGroup.stashedAgo(now.addingTimeInterval(-12 * 60), now: now), "12 m ago")
        XCTAssertEqual(TabGroup.stashedAgo(now.addingTimeInterval(-2 * 3600), now: now), "2 h ago")
        XCTAssertEqual(TabGroup.stashedAgo(now.addingTimeInterval(-30 * 3600), now: now), "yesterday")
        XCTAssertEqual(TabGroup.stashedAgo(now.addingTimeInterval(-4 * 86_400), now: now), "4 days ago")
    }
}

/// Dragging a tab into and out of an island. The rule is geometry, and the
/// geometry is the part that can be wrong without anyone noticing until a
/// tab silently joins the wrong group.
@MainActor
final class IslandDropTests: XCTestCase {
    private func rect(_ x: CGFloat, _ width: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: width, height: 30)
    }

    /// An island is its chip and its tabs together — a drop on the chip is
    /// a drop on the island.
    func testASpanCoversTheChipAndEveryTab() {
        let span = TabStore.span(chip: rect(10, 50), members: [rect(64, 100), rect(168, 100)])
        XCTAssertEqual(span, 10...268)
    }

    func testAnIslandWithNothingDrawnYetHasNoSpan() {
        XCTAssertNil(TabStore.span(chip: nil, members: []))
    }

    /// A collapsed island is its chip alone, and still takes a drop.
    func testACollapsedIslandIsItsChip() {
        XCTAssertEqual(TabStore.span(chip: rect(10, 50), members: []), 10...60)
    }

    func testTheIslandUnderThePointerIsTheOneContainingIt() {
        let a = UUID(), b = UUID()
        let spans = [(id: a, span: CGFloat(0)...CGFloat(100)), (id: b, span: CGFloat(140)...CGFloat(240))]
        XCTAssertEqual(TabStore.island(at: 50, spans: spans), a)
        XCTAssertEqual(TabStore.island(at: 200, spans: spans), b)
        // Between them is where a tab leaves its island.
        XCTAssertNil(TabStore.island(at: 120, spans: spans))
        XCTAssertNil(TabStore.island(at: 400, spans: spans))
    }

    /// The edges belong to the island: a drop right on a chip's left edge
    /// is a drop on it, not a miss.
    func testTheEdgesBelongToTheIsland() {
        let a = UUID()
        let spans = [(id: a, span: CGFloat(10)...CGFloat(60))]
        XCTAssertEqual(TabStore.island(at: 10, spans: spans), a)
        XCTAssertEqual(TabStore.island(at: 60, spans: spans), a)
        XCTAssertNil(TabStore.island(at: 9.9, spans: spans))
    }
}
