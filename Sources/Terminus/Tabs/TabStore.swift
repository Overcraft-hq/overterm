import Foundation

/// The ordered tabs of one window and which one is selected. Pure state; the
/// window controller turns changes into view changes.
@MainActor
final class TabStore: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedID: Tab.ID?

    var selected: Tab? { tabs.first { $0.id == selectedID } }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    func index(of tab: Tab) -> Int? { tabs.firstIndex { $0.id == tab.id } }

    /// Chrome's rule: a new tab goes right after the current one.
    func insert(_ tab: Tab, after anchor: Tab?) {
        if let anchor, let i = index(of: anchor) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        selectedID = tab.id
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

    /// Moves a tab by `offset` places, clamped to the ends.
    func move(_ tab: Tab, by offset: Int) {
        guard let from = index(of: tab) else { return }
        let to = max(0, min(tabs.count - 1, from + offset))
        guard to != from else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
}
