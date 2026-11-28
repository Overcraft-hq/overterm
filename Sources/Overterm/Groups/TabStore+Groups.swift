import Foundation

/// Tab groups on top of the one ordered list of tabs.
///
/// The store keeps two invariants, and every operation here restores them:
///
/// 1. **Pinned tabs come first** (as before), and a pinned tab is never in a
///    group — grouping one unpins it. Pinned tabs are the strip's left edge;
///    an island that could slide in front of them would fight that.
/// 2. **A group's tabs are one run.** Everything that walks `tabs` — the
///    session, closing, tab peek, the agent overview — stays unaware of
///    groups, and the strip can read islands straight off the order.
extension TabStore {
    // MARK: Reading

    /// The strip in order: islands and the loose tabs between them. Stashed
    /// groups are not here — their tabs are out of the strip.
    package var strip: [TabStrip] {
        var result: [TabStrip] = []
        var index = 0
        while index < tabs.count {
            let tab = tabs[index]
            guard let id = tab.groupID, let group = group(id) else {
                result.append(.loose(tab))
                index += 1
                continue
            }
            var run: [Tab] = []
            while index < tabs.count, tabs[index].groupID == id {
                run.append(tabs[index])
                index += 1
            }
            if !group.isStashed { result.append(.group(group, run)) }
        }
        return result
    }

    package func group(_ id: TabGroup.ID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    package func group(of tab: Tab) -> TabGroup? { group(tab.groupID) }

    package func tabs(in group: TabGroup) -> [Tab] { tabs.filter { $0.groupID == group.id } }

    /// The group a new tab opened in `directory` should join: the one bound
    /// to that folder, or to a folder it sits under. Only a group whose
    /// binding was ticked is here — `TabGroup.folder` is nil otherwise.
    package func group(forDirectory directory: String?) -> TabGroup? {
        guard let directory else { return nil }
        return
            groups
            .filter { !$0.isStashed }
            .filter { folder in
                guard let bound = folder.folder else { return false }
                return directory == bound || directory.hasPrefix(bound.hasSuffix("/") ? bound : bound + "/")
            }
            // The most specific binding wins: a group on the worktree beats
            // one on the repository above it.
            .max { ($0.folder?.count ?? 0) < ($1.folder?.count ?? 0) }
    }

    /// Tabs the strip shows: everything but a stashed group's.
    package var visibleTabs: [Tab] { tabs.filter { group(of: $0)?.isStashed != true } }

    /// The tabs the strip offers, which Tab Peek shows (PEEK-U2): none of a
    /// stashed island's, and while focusing, the focused island's alone.
    package var stripTabs: [Tab] {
        let visible = visibleTabs
        guard let focused = focusedGroupID, group(focused) != nil else { return visible }
        return visible.filter { $0.groupID == focused }
    }

    /// Where a new tab opened from `anchor`, in `directory`, belongs
    /// (`NewTabGroup` holds the rule; this reads the strip for it).
    package func placementForNewTab(
        _ opening: NewTabGroup.Opening, after anchor: Tab?, in directory: String?
    ) -> NewTabGroup.Placement {
        let anchorGroup = anchor?.groupID
        return NewTabGroup.placement(
            opening: opening,
            anchor: anchorGroup,
            focused: focusedGroupID,
            bound: group(forDirectory: directory)?.id,
            takesNewTabs: group(anchorGroup)?.takesNewTabs,
            // A pinned tab counts: it is never in a group, it is always in
            // the strip, and it is somewhere for a loose tab to belong.
            hasTabOutside: visibleTabs.contains { $0.groupID != anchorGroup })
    }

    // MARK: Making and unmaking

    /// Puts `members` in a new island, in the order they are in the strip,
    /// where the first of them sits now.
    @discardableResult
    package func addToNewGroup(_ members: [Tab], name: String? = nil, color: TabColor? = nil, folder: String? = nil) -> TabGroup? {
        let members = ordered(members)
        guard !members.isEmpty else { return nil }
        // The checkout they share names the island, but it does not bind
        // it: "every tab opened in this folder joins" is a decision, and
        // taken for you it is the one that swallowed every new tab. The
        // popover offers it, unticked (GroupPopover).
        let common = commonFolder(of: members)
        let group = TabGroup(
            name: name ?? TabGroup.name(for: folder ?? common),
            color: color ?? TabGroup.color(after: groups.map(\.color)),
            folder: folder)
        groups.append(group)
        add(members, to: group)
        return group
    }

    /// Moves `members` into `group`, at its end.
    package func add(_ members: [Tab], to group: TabGroup) {
        let members = ordered(members).filter { $0.groupID != group.id }
        guard !members.isEmpty else { return }
        for tab in members where tab.isPinned { setPinned(tab, false) }
        var rest = tabs
        rest.removeAll { tab in members.contains { $0 === tab } }
        members.forEach { $0.groupID = group.id }
        // After the group's last tab if it has one, else where its first new
        // member was — a brand-new island appears in place.
        let at: Int
        if let last = rest.lastIndex(where: { $0.groupID == group.id }) {
            at = last + 1
        } else {
            at = rest.firstIndex { $0 === members[0] } ?? min(index(of: members[0]) ?? rest.count, rest.count)
        }
        rest.insert(contentsOf: members, at: min(at, rest.count))
        replaceTabs(rest)
        normalize()
    }

    /// Out of its island, staying where it is in the strip.
    package func removeFromGroup(_ members: [Tab]) {
        let touched = members.filter { $0.groupID != nil }
        guard !touched.isEmpty else { return }
        touched.forEach { $0.groupID = nil }
        normalize()
    }

    /// The island goes, its tabs stay where they are.
    package func ungroup(_ group: TabGroup) {
        tabs(in: group).forEach { $0.groupID = nil }
        groups.removeAll { $0.id == group.id }
        normalize()
    }

    /// A group with no tabs left is not a group. Called after any removal —
    /// but not while a session is coming back (`restoring`): its islands are
    /// all there before their tabs, and the first tab of the first one
    /// pruned the rest.
    package func pruneEmptyGroups() {
        guard !restoring else { return }
        let alive = Set(tabs.compactMap(\.groupID))
        groups.removeAll { !alive.contains($0.id) && !$0.isStashed }
    }

    // MARK: Moving

    /// Moves a whole island so it sits where `target`'s island is.
    package func move(_ group: TabGroup, before target: TabGroup) {
        guard group.id != target.id else { return }
        let moving = tabs(in: group)
        guard !moving.isEmpty, let anchor = tabs.firstIndex(where: { $0.groupID == target.id }) else { return }
        var rest = tabs
        let before = rest.prefix(anchor).filter { tab in moving.contains { $0 === tab } }.count
        rest.removeAll { tab in moving.contains { $0 === tab } }
        rest.insert(contentsOf: moving, at: max(anchor - before, 0))
        replaceTabs(rest)
        normalize()
    }

    // MARK: Collapsing, stashing, focusing

    package func setCollapsed(_ group: TabGroup, _ collapsed: Bool) {
        guard group.isCollapsed != collapsed else { return }
        group.isCollapsed = collapsed
        // A collapsed island must not keep the selection: the selected tab
        // would be invisible. Move to the first tab outside it.
        if collapsed, let selected, selected.groupID == group.id {
            selectFirstOutside(group)
        }
        objectWillChange.send()
    }

    /// Out of the strip; the processes carry on. The selection moves out
    /// first, so nothing invisible stays selected.
    package func stash(_ group: TabGroup) {
        guard !group.isStashed else { return }
        if let selected, selected.groupID == group.id { selectFirstOutside(group) }
        group.isStashed = true
        group.stashedAt = Date()
        objectWillChange.send()
    }

    package func restore(_ group: TabGroup) {
        guard group.isStashed else { return }
        group.isStashed = false
        group.stashedAt = nil
        if let first = tabs(in: group).first { select(first) }
        objectWillChange.send()
    }

    package var stashedGroups: [TabGroup] { groups.filter(\.isStashed) }

    /// Only this group's tabs are in the strip; the rest are out of the way
    /// without being stashed. Nil shows everything again.
    package func setFocused(_ group: TabGroup?) {
        guard focusedGroupID != group?.id else { return }
        focusedGroupID = group?.id
        if let group, let selected, selected.groupID != group.id, let first = tabs(in: group).first {
            select(first)
        }
    }

    package var focusedGroup: TabGroup? { group(focusedGroupID) }

    /// What the strip draws: focus narrows it to one island.
    package var focusedStrip: [TabStrip] {
        guard let id = focusedGroupID else { return strip }
        return strip.filter { if case .group(let g, _) = $0 { return g.id == id } else { return false } }
    }

    // MARK: What the strip draws

    /// The tabs the strip draws, in order: none of a stashed island's, none
    /// of a collapsed one's, and while an island is focused only its own.
    /// What moves between tabs or acts on "the other tabs" goes by these:
    /// the keyboard never lands on a tab nobody can see, and a bulk verb
    /// never reaches one silently.
    package var drawnTabs: [Tab] {
        focusedStrip.flatMap { piece -> [Tab] in
            switch piece {
            case .loose(let tab): [tab]
            case .group(let group, let run): group.isCollapsed ? [] : run
            }
        }
    }

    package func isDrawn(_ tab: Tab) -> Bool { drawnTabs.contains { $0 === tab } }

    /// The `index`th drawn tab (⌘1–9), the last for one past them.
    package func select(drawnIndex index: Int) {
        let drawn = drawnTabs
        guard !drawn.isEmpty else { return }
        select(drawn[min(max(index, 0), drawn.count - 1)])
    }

    /// Next/previous among the drawn tabs, wrapping. From a tab the strip
    /// doesn't draw (it shouldn't be selected), the first or the last.
    package func selectAdjacent(_ offset: Int) {
        let drawn = drawnTabs
        guard !drawn.isEmpty else { return }
        guard let selected, let i = drawn.firstIndex(where: { $0 === selected }) else {
            return select(offset >= 0 ? drawn[0] : drawn[drawn.count - 1])
        }
        let n = drawn.count
        select(drawn[((i + offset) % n + n) % n])
    }

    /// Brings `tab` into the strip, then selects it — a notification's tab,
    /// the next one wanting you: its island back from the shelf, expanded,
    /// and focus left when it is elsewhere.
    package func reveal(_ tab: Tab) {
        if let group = group(of: tab) {
            if group.isStashed {
                group.isStashed = false
                group.stashedAt = nil
                objectWillChange.send()
            }
            if group.isCollapsed { setCollapsed(group, false) }
        }
        if let focused = focusedGroupID, tab.groupID != focused { setFocused(nil) }
        select(tab)
    }

    /// Why each of `tabs` isn't in the strip, by island — what a question
    /// about them says: `“shop-api” (stashed)`, `“web” (collapsed)`,
    /// `“docs” and 2 loose tabs (outside the focused “api”)`. Empty when
    /// all of them are drawn.
    package func hiddenSummary(_ tabs: [Tab]) -> [String] {
        let hidden = tabs.filter { !isDrawn($0) }
        guard !hidden.isEmpty else { return [] }
        var said: [String] = []
        var outside: [String] = []
        var loose = 0
        var seen = Set<TabGroup.ID>()
        for tab in hidden {
            guard let group = group(of: tab) else {
                loose += 1
                continue
            }
            guard seen.insert(group.id).inserted else { continue }
            if group.isStashed {
                said.append("“\(group.name)” (stashed)")
            } else if let focused = focusedGroupID, group.id != focused {
                outside.append("“\(group.name)”")
            } else {
                said.append("“\(group.name)” (collapsed)")
            }
        }
        if loose > 0 { outside.append(loose == 1 ? "a loose tab" : "\(loose) loose tabs") }
        if !outside.isEmpty, let focused = focusedGroup {
            said.append(outside.joined(separator: ", ") + " (outside the focused “\(focused.name)”)")
        }
        return said
    }

    // MARK: Invariants

    /// Puts the tabs back in order: pinned first, then each group's tabs in
    /// one run where its first tab is. Idempotent — the strip reports frames
    /// a moment late, and a drag must not oscillate.
    // MARK: Dragging into and out of an island

    /// The horizontal span an island occupies in the strip: its chip and
    /// its tabs together. Pure — the drop rule is geometry and should be
    /// readable without a strip to run it against.
    package nonisolated static func span(chip: CGRect?, members: [CGRect]) -> ClosedRange<CGFloat>? {
        let rects = ([chip].compactMap { $0 }) + members
        guard let first = rects.first else { return nil }
        let low = rects.reduce(first.minX) { Swift.min($0, $1.minX) }
        let high = rects.reduce(first.maxX) { Swift.max($0, $1.maxX) }
        return low...Swift.max(low, high)
    }

    /// Which island a pointer at `x` is over, if any. The innermost match
    /// would be ambiguous between neighbours, so spans never overlap: the
    /// first containing one wins and the strip lays them out in order.
    package nonisolated static func island(at x: CGFloat, spans: [(id: TabGroup.ID, span: ClosedRange<CGFloat>)]) -> TabGroup.ID? {
        spans.first { $0.span.contains(x) }?.id
    }

    /// Where each island is right now, in strip coordinates.
    package var islandSpans: [(id: TabGroup.ID, span: ClosedRange<CGFloat>)] {
        groups.compactMap { group in
            let members = tabs(in: group).compactMap { tabFrames[$0.id] }
            guard let span = Self.span(chip: groupChipFrames[group.id], members: members) else { return nil }
            return (group.id, span)
        }
    }

    /// A tab dragged to `x`: it joins the island it is dropped inside, and
    /// leaves the one it was in when it is dropped between them. Ordering
    /// happens first and `normalize` then pulls the island's run back
    /// together around it, so the tab keeps the place the pointer gave it.
    package func drop(_ tab: Tab, atPointerX x: CGFloat) {
        let target = Self.island(at: x, spans: islandSpans)
        if tab.groupID != target { tab.groupID = target }
        dragMove(tab, toPointerX: x)
        normalize()
    }

    /// A whole island dragged by its chip, left or right, past loose tabs
    /// and other islands alike.
    package func dragMove(_ group: TabGroup, toPointerX x: CGFloat) {
        let moving = tabs(in: group)
        guard !moving.isEmpty else { return }
        // The strip as pieces — each other island whole, each loose tab —
        // and the island after every piece whose middle the pointer has
        // passed. Moving its first tab alone left the island where the rest
        // of it was: it could go left, never right.
        var pieces: [[Tab]] = []
        for tab in tabs where !tab.isPinned && tab.groupID != group.id {
            if let id = tab.groupID, let last = pieces.last?.first, last.groupID == id {
                pieces[pieces.count - 1].append(tab)
            } else {
                pieces.append([tab])
            }
        }
        let spans = Dictionary(islandSpans.map { ($0.id, $0.span) }, uniquingKeysWith: { first, _ in first })
        func middle(_ piece: [Tab]) -> CGFloat {
            if let id = piece.first?.groupID, let span = spans[id] { return (span.lowerBound + span.upperBound) / 2 }
            return piece.first.flatMap { tabFrames[$0.id]?.midX } ?? .infinity
        }
        let position = pieces.filter { middle($0) < x }.count
        var rebuilt = tabs.filter(\.isPinned)
        for (index, piece) in pieces.enumerated() {
            if index == position { rebuilt += moving }
            rebuilt += piece
        }
        if position >= pieces.count { rebuilt += moving }
        guard rebuilt.map(ObjectIdentifier.init) != tabs.map(ObjectIdentifier.init) else { return }
        replaceTabs(rebuilt)
        normalize()
    }

    package func normalize() {
        var seen: [TabGroup.ID] = []
        var runs: [TabGroup.ID: [Tab]] = [:]
        var order: [Tab] = []
        for tab in tabs where !tab.isPinned {
            // A tab whose island has gone is loose — never dropped: a tab
            // left out of this list vanished from the strip, its shell still
            // running with nothing to show it.
            if let id = tab.groupID, group(id) == nil { tab.groupID = nil }
            guard let id = tab.groupID else {
                order.append(tab)
                continue
            }
            if runs[id] == nil {
                seen.append(id)
                // A placeholder keeps the island where its first tab was.
                order.append(tab)
                runs[id] = [tab]
            } else {
                runs[id]?.append(tab)
            }
        }
        var rebuilt: [Tab] = tabs.filter(\.isPinned)
        for tab in order {
            if let id = tab.groupID, let run = runs[id], run.first === tab {
                rebuilt.append(contentsOf: run)
            } else if tab.groupID == nil {
                rebuilt.append(tab)
            }
        }
        if rebuilt.map(ObjectIdentifier.init) != tabs.map(ObjectIdentifier.init) { replaceTabs(rebuilt) }
        pruneEmptyGroups()
    }

    /// Members in the order the strip has them, duplicates dropped.
    private func ordered(_ members: [Tab]) -> [Tab] {
        var seen = Set<Tab.ID>()
        return tabs.filter { tab in members.contains { $0 === tab } && seen.insert(tab.id).inserted }
    }

    /// The checkout the members share, if they share one — what a new
    /// island binds itself to.
    private func commonFolder(of members: [Tab]) -> String? {
        let roots = members.compactMap { $0.checkoutSource?.root.path }
        guard let first = roots.first, roots.count == members.count, roots.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func selectFirstOutside(_ group: TabGroup) {
        guard let next = tabs.first(where: { $0.groupID != group.id }) else { return }
        select(next)
    }
}
