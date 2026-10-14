import CoreGraphics
import Foundation

/// The ordered tabs of one window and which one is selected. Pure state; the
/// window controller turns changes into view changes.
@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID: Tab.ID?
    /// The tab whose name is being edited in the strip, if any.
    @Published var renamingID: Tab.ID?

    /// The islands (TabStore+Groups). Their order in the strip comes from
    /// the tabs, not from this list.
    @Published var groups: [TabGroup] = []
    /// Focus on one group: only its island is in the strip. Set it through
    /// `setFocused`, which moves the selection with it.
    @Published var focusedGroupID: TabGroup.ID?
    /// The group whose name is being edited in its chip, if any.
    @Published var renamingGroupID: TabGroup.ID?
    /// Where the arrows are in the group switcher (⌃⌘G).
    @Published var switcherHighlight: TabGroup.ID?

    /// ⌘-clicked tabs, for "Add 2 Tabs to New Group". The selected tab is
    /// not in here: `selectedTabs` adds it.
    @Published private(set) var multiSelection: Set<Tab.ID> = []

    /// What a group command acts on: the ⌘-clicked tabs in strip order,
    /// with the selected one, or just the selected one.
    var selectedTabs: [Tab] {
        let marked = tabs.filter { multiSelection.contains($0.id) || $0.id == selectedID }
        return marked.isEmpty ? [selected].compactMap { $0 } : marked
    }

    /// ⌘-click: add or remove a tab from the marked set. The selected tab
    /// can't be unmarked — it is always part of the command.
    func toggleMultiSelection(_ tab: Tab) {
        guard tab.id != selectedID else { return }
        if multiSelection.contains(tab.id) { multiSelection.remove(tab.id) } else { multiSelection.insert(tab.id) }
    }

    func clearMultiSelection() {
        guard !multiSelection.isEmpty else { return }
        multiSelection = []
    }

    func isMarked(_ tab: Tab) -> Bool { multiSelection.contains(tab.id) }
    /// The Settings tab: a page, not a terminal, after the terminal tabs
    /// while open (Warp's). Selecting it covers the window's body; the
    /// selected terminal tab stays selected underneath.
    @Published var settingsOpen = false
    @Published var settingsShowing = false

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0.id == tab.id } }

    /// Invariant: pinned tabs come first. Index of the first unpinned tab.
    private var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// Chrome's rule for the position: a new tab goes right after the current
    /// one — or, from a pinned tab, first among the unpinned ones.
    ///
    /// Which island it joins is `joining`, decided by `NewTabGroup` and
    /// never inherited from the anchor: once an island held every tab, an
    /// inherited group swallowed every new tab silently. A tab that joins
    /// nothing is inserted after the anchor all the same and `normalize`
    /// then slides it past the anchor's island, which keeps its run whole.
    func insert(_ tab: Tab, after anchor: Tab?, joining group: TabGroup.ID? = nil) {
        if let group { tab.groupID = group }
        if let anchor, let i = index(of: anchor) {
            tabs.insert(tab, at: max(i + 1, pinnedCount))
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
        normalize()
    }

    /// Reorders the whole list. Only the group layer (TabStore+Groups) uses
    /// it, and only to restore the invariants it documents.
    func replaceTabs(_ newTabs: [Tab]) { tabs = newTabs }

    func setPinned(_ tab: Tab, _ pinned: Bool) {
        guard tab.isPinned != pinned, let i = index(of: tab) else { return }
        tabs.remove(at: i)
        tab.isPinned = pinned
        // Pinning appends to the pinned group; unpinning puts it first after.
        tabs.insert(tab, at: pinnedCount)
    }

    /// Removes the tab. If it was selected, selection moves to its right
    /// neighbour, else the left one (Chrome's rule).
    func remove(_ tab: Tab) {
        guard let i = index(of: tab) else { return }
        tabs.remove(at: i)
        if selectedID == tab.id {
            selectedID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
        pruneEmptyGroups()
    }

    func select(_ tab: Tab) {
        // A plain click starts a new command: the ⌘-clicked set goes.
        clearMultiSelection()
        // Re-selecting would still publish, and the window answers a
        // selection by focusing the terminal — which ended an in-place
        // rename the moment it began (menu and double-click select first).
        guard selectedID != tab.id else { return }
        selectedID = tab.id
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    /// Next/previous with wrap-around.
    func selectAdjacent(_ offset: Int) {
        guard let i = selectedIndex, !tabs.isEmpty else { return }
        let n = tabs.count
        select(index: ((i + offset) % n + n) % n)
    }

    /// Where each tab is drawn in the strip (top-left origin), so the window
    /// can tell which tab a right-click landed on.
    var tabFrames: [Tab.ID: CGRect] = [:]

    /// The same for the islands' chips.
    var groupChipFrames: [TabGroup.ID: CGRect] = [:]

    /// The island a dragged tab would land in, while it is being dragged —
    /// so the strip can say which one will take it before you let go.
    @Published var dropGroupID: TabGroup.ID?

    func group(at point: CGPoint) -> TabGroup? {
        groups.first { groupChipFrames[$0.id]?.contains(point) == true }
    }

    func tab(at point: CGPoint) -> Tab? {
        tabs.first { tabFrames[$0.id]?.contains(point) == true }
    }

    /// The tab being dragged in the strip, if any (drawn slightly faded).
    @Published var draggingID: Tab.ID?

    /// Where a dragged tab belongs for a pointer at `x`: after every other tab
    /// of its group whose middle is left of the pointer.
    ///
    /// Idempotent under stale geometry, which is the point: the strip reports
    /// frames a moment after a move, and a swap-with-the-tab-under-the-pointer
    /// rule then saw the tab it had just swapped with still "under" the
    /// pointer and swapped back — 30 flip-flops in one drag.
    func dragMove(_ tab: Tab, toPointerX x: CGFloat) {
        let others = tabs.filter { $0.isPinned == tab.isPinned && $0.id != tab.id }
        let position = others.filter { (tabFrames[$0.id]?.midX ?? .infinity) < x }.count
        let groupStart = tab.isPinned ? 0 : pinnedCount
        guard let from = index(of: tab) else { return }
        let to = groupStart + position
        guard to != from else { return }
        var reordered = tabs
        reordered.remove(at: from)
        reordered.insert(tab, at: to)
        tabs = reordered
    }

    /// Moves `tab` to where `target` is, if both are in the same group.
    func move(_ tab: Tab, to target: Tab) {
        guard tab.id != target.id, tab.isPinned == target.isPinned,
            let from = index(of: tab), let to = index(of: target)
        else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Moves a tab by `offset` places, clamped to its group (pinned or not).
    func move(_ tab: Tab, by offset: Int) {
        guard let from = index(of: tab) else { return }
        let group = tab.isPinned ? 0..<pinnedCount : pinnedCount..<tabs.count
        let to = max(group.lowerBound, min(group.upperBound - 1, from + offset))
        guard to != from else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}
