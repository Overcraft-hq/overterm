import Foundation

/// Which island a new tab joins — the one rule, pure, so every way of
/// opening a tab answers it the same way.
///
/// Chrome's rule is "a new tab inherits the island of the one it opens
/// from", and that is wrong here. A Terminus group is usually a checkout,
/// so it ends up holding every tab you have; from then on ⌘T, the strip's
/// +, the palette and the sidebar all dropped their tab into the group
/// without being asked, and there was no way back out but a drag.
///
/// So a tab joins a group only where the intent is unmistakable: the
/// island's own + (or its menu), the folder someone bound to it, an island
/// the strip is focused on, or a group that was asked and said yes.
enum NewTabGroup {
    enum Placement: Equatable {
        /// Outside every island. Inserted after the anchor, which the
        /// store's contiguous-run invariant then lands after its island.
        case loose
        case join(UUID)
        /// Nothing says it belongs in the island and nothing says it
        /// doesn't: the island holds the whole strip, so there is no
        /// "outside" to read the intent from. The tab opens loose and the
        /// window offers to move it — once; the answer is the group's.
        case ask(UUID)
    }

    /// - Parameters:
    ///   - anchor: the island of the tab the new one opens from.
    ///   - focused: the island the strip is narrowed to (⌃⌘F), if any.
    ///   - bound: an island whose folder the new tab's directory is under,
    ///     and only when that binding was ticked (`TabGroup.folder`).
    ///   - takesNewTabs: what `anchor`'s island answered, if it was asked.
    ///   - hasTabOutside: some tab in the strip is not in `anchor`'s island.
    static func placement(
        anchor: UUID?, focused: UUID?, bound: UUID?, takesNewTabs: Bool?, hasTabOutside: Bool
    ) -> Placement {
        // Focus shows one island and nothing else, so a loose tab would
        // open out of sight. Not a guess: the only honest answer.
        if let focused { return .join(focused) }
        // A folder someone ticked is the most specific thing anyone has
        // said about where a tab belongs — unless that same island has
        // since been told not to take new tabs.
        if let bound, !(bound == anchor && takesNewTabs == false) { return .join(bound) }
        guard let anchor else { return .loose }
        if let takesNewTabs { return takesNewTabs ? .join(anchor) : .loose }
        return hasTabOutside ? .loose : .ask(anchor)
    }
}
