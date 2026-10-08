import XCTest

@testable import Terminus

/// Groups on real Tabs. The Ghostty runtime is never initialized in the
/// unit-test process, so each TerminalView is surfaceless: no ptys.
@MainActor
final class TabGroupTests: XCTestCase {
    private var store = TabStore()

    override func setUp() {
        super.setUp()
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

    func testANewTabJoinsTheAnchorsIsland() {
        let a = tab("a")
        let group = store.addToNewGroup([a], name: "work")!
        let fresh = Tab(terminal: TerminalView())
        fresh.customTitle = "new"
        store.insert(fresh, after: a)
        XCTAssertEqual(fresh.groupID, group.id, "a tab opened from a grouped tab stays in the group")
        XCTAssertEqual(islands(store.strip), ["[work: a,new]"])
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
