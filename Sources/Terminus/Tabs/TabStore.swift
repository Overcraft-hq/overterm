import Foundation

/// The ordered tabs of one window and which one is selected. Pure state; the
/// window controller turns changes into view changes.
@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID: Tab.ID?
    /// The tab whose name is being edited in the strip, if any.
    @Published var renamingID: Tab.ID?

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0.id == tab.id } }

    /// Invariant: pinned tabs come first. Index of the first unpinned tab.
    private var pinnedCount: Int { tabs.prefix { $0.isPinned }.count }

    /// Chrome's rule: a new tab goes right after the current one — or, from a
    /// pinned tab, first among the unpinned ones.
    func insert(_ tab: Tab, after anchor: Tab?) {
        if let anchor, let i = index(of: anchor) {
            tabs.insert(tab, at: max(i + 1, pinnedCount))
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
    }

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
    }

    func select(_ tab: Tab) {
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

    func tab(at point: CGPoint) -> Tab? {
        tabs.first { tabFrames[$0.id]?.contains(point) == true }
    }

    /// The tab being dragged in the strip, if any. Not published: only the
    /// drop delegate reads it.
    var draggingID: Tab.ID?

    /// Moves `tab` to where `target` is, if both are in the same group. Used
    /// live while dragging, so the strip reorders under the pointer.
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
