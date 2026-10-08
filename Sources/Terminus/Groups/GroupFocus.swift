import Foundation

/// Focus on one group (⌃⌘F): only that island is in the strip, and the
/// other groups' tabs stop interrupting — their notices are held until you
/// leave focus.
///
/// One thing always breaks through: an agent that is **blocked on you**. A
/// held permission prompt is the one interruption that costs you more by
/// waiting than by arriving, so `.waiting` is never queued.
@MainActor
final class GroupFocus: ObservableObject {
    struct Held: Identifiable, Equatable {
        let id: Tab.ID
        let title: String
        let note: String
        let groupName: String
    }

    @Published private(set) var groupID: TabGroup.ID?
    /// What was kept back while focusing, newest last.
    @Published private(set) var held: [Held] = []

    var isFocusing: Bool { groupID != nil }

    func begin(_ groupID: TabGroup.ID) {
        self.groupID = groupID
        held = []
    }

    /// Leaves focus and hands back what was kept, for one summary.
    @discardableResult
    func end() -> [Held] {
        groupID = nil
        let kept = held
        held = []
        return kept
    }

    /// Whether `tab`'s notice goes out now. Pure given its arguments, so
    /// the rule can be tested without notifications.
    nonisolated static func breaksThrough(tabGroup: TabGroup.ID?, focused: TabGroup.ID?, mark: TabActivity.Mark) -> Bool {
        guard let focused else { return true }
        if tabGroup == focused { return true }
        // A blocked agent always breaks through.
        return mark == .waiting
    }

    /// Call for every notice while focusing. Returns whether to post it;
    /// a held one is queued for the summary instead.
    func shouldNotify(tab: Tab, groupName: String) -> Bool {
        guard let groupID else { return true }
        if Self.breaksThrough(tabGroup: tab.groupID, focused: groupID, mark: tab.activity.mark) { return true }
        let entry = Held(
            id: tab.id, title: tab.title, note: tab.activity.note ?? Self.describe(tab.activity.mark),
            groupName: groupName)
        // One line per tab: a chatty tab must not bury the others.
        held.removeAll { $0.id == tab.id }
        held.append(entry)
        return false
    }

    /// Dropped when its tab closes, so the summary never names a dead tab.
    func forget(_ id: Tab.ID) { held.removeAll { $0.id == id } }

    nonisolated static func describe(_ mark: TabActivity.Mark) -> String {
        switch mark {
        case .waiting: "needs you"
        case .failed: "failed"
        case .done: "finished"
        case .none: "updated"
        }
    }
}
