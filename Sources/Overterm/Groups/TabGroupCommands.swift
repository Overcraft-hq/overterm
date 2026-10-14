import AppKit
import SwiftUI
import GhosttyKit

/// What the window does with an island: the chip's menu, the Group menu and
/// the shortcuts all land here. The ordering lives in `TabStore+Groups`;
/// this is the part that touches terminals, sheets and the keyboard.
extension TerminalWindowController {
    // MARK: Making one

    /// ⌃⌘G: the selected tabs — or just the selected one — become an island.
    @objc func groupSelectedTabs(_ sender: Any?) {
        let members = store.multiSelection.isEmpty ? [store.selected].compactMap { $0 } : store.selectedTabs
        guard !members.isEmpty, let group = store.addToNewGroup(members) else { return }
        store.clearMultiSelection()
        // The name is editable in the chip straight away, prefilled from the
        // git root, as the design has it, with the rest of the group's
        // settings under it while they are still worth deciding.
        store.renamingGroupID = group.id
        showGroupPopover(for: group)
    }

    /// The new island's settings, under its chip. Also Group ▸ Edit Group…
    /// and a ⌥-click on a chip, because the three decisions it holds are
    /// the ones you revisit.
    func showGroupPopover(for group: TabGroup, waiting: Int = 20) {
        if waiting == 20 { groupPopover?.close() }
        guard let theme else { return }
        guard let chip = chip(of: group) else {
            // A brand-new island has no chip yet — SwiftUI lays the strip out
            // a turn later, and a popover needs something to point at. Wait
            // for it rather than not appearing at all, but not forever.
            guard waiting > 0 else { return }
            DispatchQueue.main.async { [weak self] in self?.showGroupPopover(for: group, waiting: waiting - 1) }
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        popover.contentViewController = NSHostingController(
            rootView: GroupPopover(
                group: group, theme: theme,
                folder: store.tabs(in: group).first.flatMap { $0.attachedCheckout?.path ?? $0.workingDirectory },
                done: { [weak self] in
                    self?.groupPopover?.close()
                    self?.store.renamingGroupID = nil
                    self?.focusSelectedTerminal()
                }))
        popover.show(relativeTo: chip.rect, of: chip.strip, preferredEdge: chip.strip.isFlipped ? .maxY : .minY)
        groupPopover = popover
    }

    /// An island's chip, as something a popover can point at. The strip
    /// publishes frames top-left; the host is flipped, so that is its space.
    func chip(of group: TabGroup) -> (strip: NSView, rect: CGRect)? {
        guard let strip = tabBarView, let frame = store.groupChipFrames[group.id] else { return nil }
        var rect = frame
        if !strip.isFlipped { rect.origin.y = strip.bounds.height - frame.maxY }
        return (strip, rect)
    }

    /// The island holds every tab there is, so nothing in the strip says
    /// whether this new tab is one of its own (`NewTabGroup.ask`). The tab
    /// is already open, outside it; this only offers to move it in, and
    /// records the answer so the question is asked once.
    func askNewTabGroup(for tab: Tab, in group: TabGroup, waiting: Int = 20) {
        guard let theme else { return }
        guard let chip = chip(of: group) else {
            guard waiting > 0 else { return }
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let tab else { return }
                self?.askNewTabGroup(for: tab, in: group, waiting: waiting - 1)
            }
            return
        }
        newTabPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        popover.contentViewController = NSHostingController(
            rootView: NewTabPrompt(
                group: group, theme: theme,
                keepOut: { [weak self] in
                    group.takesNewTabs = false
                    self?.newTabPopover?.close()
                    self?.focusSelectedTerminal()
                },
                join: { [weak self, weak tab] in
                    group.takesNewTabs = true
                    if let tab { self?.store.add([tab], to: group) }
                    self?.newTabPopover?.close()
                    self?.focusSelectedTerminal()
                }))
        popover.show(relativeTo: chip.rect, of: chip.strip, preferredEdge: chip.strip.isFlipped ? .maxY : .minY)
        newTabPopover = popover
    }

    /// Group ▸ Add Tab to Group ▸ <name>.
    func addSelectedTabs(to group: TabGroup) {
        let members = store.multiSelection.isEmpty ? [store.selected].compactMap { $0 } : store.selectedTabs
        store.add(members, to: group)
        store.clearMultiSelection()
    }

    /// Where the tab is, since the strip now shows only the folder's name:
    /// the whole path, readable, and one click to copy it.
    func addWorkingDirectoryItems(to menu: NSMenu, for tab: Tab) {
        guard let directory = tab.workingDirectory else { return }
        menu.addItem(.separator())
        let shown = (directory as NSString).abbreviatingWithTildeInPath
        let path = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
        path.isEnabled = false
        path.toolTip = directory
        menu.addItem(path)
        menu.addItem(
            ClosureMenuItem("Copy Working Directory") {
                guard let board = GhosttyRuntime.pasteboard(GHOSTTY_CLIPBOARD_STANDARD) else { return }
                board.clearContents()
                board.setString(directory, forType: .string)
            })
        menu.addItem(
            ClosureMenuItem("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
            })
    }

    /// The tab menu's group entries. With tabs ⌘-clicked the wording is
    /// about all of them, as the design has it ("Add 2 Tabs to New Group").
    func addGroupItems(to menu: NSMenu, for tab: Tab) {
        let members = store.multiSelection.isEmpty ? [tab] : store.selectedTabs
        let n = members.count
        let what = n == 1 ? "Tab" : "\(n) Tabs"
        menu.addItem(
            ClosureMenuItem("Add \(what) to New Group") { [weak self] in
                guard let self else { return }
                if self.store.multiSelection.isEmpty { self.store.select(tab) }
                self.groupSelectedTabs(nil)
            })
        let others = switcherGroups.filter { $0.id != tab.groupID && !$0.isStashed }
        if !others.isEmpty {
            let item = NSMenuItem(title: "Add \(what) to Group", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for group in others {
                submenu.addItem(
                    ClosureMenuItem(group.name) { [weak self] in
                        guard let self else { return }
                        if self.store.multiSelection.isEmpty { self.store.select(tab) }
                        self.addSelectedTabs(to: group)
                    })
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        if let group = store.group(of: tab) {
            menu.addItem(ClosureMenuItem("Remove from \(group.name)") { [weak self] in self?.store.removeFromGroup(members) })
        }
    }

    /// An island's menu. AppKit, not SwiftUI's `.contextMenu`: the strip
    /// lives in the title bar, which takes right-clicks first.
    func menu(for group: TabGroup) -> NSMenu {
        let tabs = store.tabs(in: group)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename Group…") { [weak self] in self?.store.renamingGroupID = group.id })
        menu.addItem(ClosureMenuItem("Group Settings…") { [weak self] in self?.showGroupPopover(for: group) })
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        for color in TabColor.allCases {
            let item = ClosureMenuItem(color.name) { group.color = color }
            item.state = group.color == color ? .on : .off
            colors.addItem(item)
        }
        colorItem.submenu = colors
        menu.addItem(colorItem)
        let restore = ClosureMenuItem("Restore on Launch") { group.restoresOnLaunch.toggle() }
        restore.state = group.restoresOnLaunch ? .on : .off
        menu.addItem(restore)
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(group.isCollapsed ? "Expand Group" : "Collapse Group") { [weak self] in
                self?.toggleGroupCollapsed(group)
            })
        menu.addItem(ClosureMenuItem("New Tab in Group") { [weak self] in self?.newTab(in: group) })
        menu.addItem(ClosureMenuItem("Broadcast Input to Group…") { [weak self] in self?.beginBroadcast(to: group) })
        let idle = tabs.filter { !$0.activity.isWorking && !$0.isPinned }.count
        if idle > 0 {
            menu.addItem(ClosureMenuItem("Close Idle Tabs (\(idle))") { [weak self] in self?.closeIdleTabs(in: group) })
        }
        menu.addItem(.separator())
        menu.addItem(
            ClosureMenuItem(store.focusedGroupID == group.id ? "Leave Focus" : "Focus on This Group") { [weak self] in
                self?.toggleFocus(on: group)
            })
        menu.addItem(
            ClosureMenuItem(group.isStashed ? "Restore Group" : "Stash Group") { [weak self] in
                group.isStashed == true ? self?.restoreGroup(group) : self?.stashGroup(group)
            })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Ungroup") { [weak self] in self?.store.ungroup(group) })
        menu.addItem(ClosureMenuItem("Close Group (\(tabs.count) tab\(tabs.count == 1 ? "" : "s"))") { [weak self] in self?.closeGroup(group) })
        return menu
    }

    /// ⌃⌘1…9: the nth island in the strip, counting the ones you can see —
    /// a stashed group is not in the strip, so it is not nth.
    @objc func showGroup(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag, n >= 1 else { return }
        let islands = store.groups.filter { !$0.isStashed }
        guard islands.count >= n else { return }
        let group = islands[n - 1]
        if group.isCollapsed { store.setCollapsed(group, false) }
        selectGroup(group)
    }

    func selectGroup(_ group: TabGroup) {
        guard let first = store.tabs(in: group).first else { return }
        store.select(first)
        focusSelectedTerminal()
    }

    func toggleGroupCollapsed(_ group: TabGroup) {
        store.setCollapsed(group, !group.isCollapsed)
        if group.isCollapsed { peekGroup(nil) }
    }

    /// A new tab inside the island, after its last one — the island's own
    /// + and its menu. The one way to say "in this group" outright, so it
    /// is the one place that doesn't ask (`NewTabGroup`).
    func newTab(in group: TabGroup) {
        guard let last = store.tabs(in: group).last else { return }
        newTab(from: last.terminal, joining: group.id)
    }

    // MARK: Closing

    func closeGroup(_ group: TabGroup) {
        closeTabs(store.tabs(in: group))
    }

    /// Everything in the island that isn't working — the design's
    /// "Close Idle Tabs (1)".
    func closeIdleTabs(in group: TabGroup) {
        closeTabs(store.tabs(in: group).filter { !$0.activity.isWorking && !$0.isPinned })
    }

    // MARK: Stash

    /// ⌃⌘S: the island leaves the strip, its processes untouched.
    @objc func stashSelectedGroup(_ sender: Any?) {
        guard let group = store.selected.flatMap({ store.group(of: $0) }) else { return }
        stashGroup(group)
    }

    func stashGroup(_ group: TabGroup) {
        // Its panes stop rendering while it is away; the ptys carry on, so an
        // agent in there keeps working and still raises its flags.
        store.tabs(in: group).flatMap(\.terminals).forEach { $0.setVisible(false) }
        store.stash(group)
        applyTabVisibility()
        focusSelectedTerminal()
    }

    func restoreGroup(_ group: TabGroup) {
        store.restore(group)
        applyTabVisibility()
        focusSelectedTerminal()
    }

    // MARK: Focus

    /// ⌃⌘F: only this island is in the strip. Again, or Esc, leaves it.
    @objc func toggleFocusedGroup(_ sender: Any?) {
        guard let group = store.focusedGroup ?? store.selected.flatMap({ store.group(of: $0) }) else { return }
        toggleFocus(on: group)
    }

    func toggleFocus(on group: TabGroup) {
        let leaving = store.focusedGroupID == group.id
        store.setFocused(leaving ? nil : group)
        if leaving { summarizeHeldNotices() } else { focus.begin(group.id) }
        updateGroupBars()
        applyTabVisibility()
        focusSelectedTerminal()
    }

    // MARK: Broadcast

    /// ⌥⌘I: one line typed into every tab of the island at once.
    @objc func broadcastToGroup(_ sender: Any?) {
        guard let group = store.selected.flatMap({ store.group(of: $0) }) else { return }
        beginBroadcast(to: group)
    }

    func beginBroadcast(to group: TabGroup) {
        broadcast.begin(group: group, tabs: store.tabs(in: group))
        updateGroupBars()
        focusBroadcastField()
    }

    /// The bars take room only while one of them is on.
    func updateGroupBars() {
        groupBars?.isHidden = !(broadcast.isOpen || focus.isFocusing)
    }

    func stopBroadcast() {
        broadcast.stop()
        updateGroupBars()
        focusSelectedTerminal()
    }

    /// The bar's field, once SwiftUI has laid it out — as the palette's is.
    func focusBroadcastField() {
        DispatchQueue.main.async { [weak self] in
            guard let bars = self?.groupBars, let field = TerminalWindowController.firstTextField(in: bars) else { return }
            self?.window?.makeFirstResponder(field)
        }
    }

    // MARK: Notices while focusing

    /// Every attention notice goes through here: while focusing on one
    /// island, another group's tab waits — unless its agent is blocked.
    func notifyUnlessHeld(_ tab: Tab) {
        let name = store.group(of: tab)?.name ?? "Ungrouped"
        guard focus.shouldNotify(tab: tab, groupName: name) else { return }
        AttentionNotifier.notify(tab: tab)
    }

    func leaveFocus() {
        guard let group = store.focusedGroup else { return }
        toggleFocus(on: group)
    }

    /// Leaving focus: one line for everything that waited.
    func summarizeHeldNotices() {
        let held = focus.end()
        guard !held.isEmpty else { return }
        AttentionNotifier.summarize(held)
    }

    // MARK: The switcher

    /// ⌃⌘G: the islands and their tabs; again, or Esc, closes it.
    @objc func showGroupSwitcher(_ sender: Any?) {
        guard let switcherView else { return }
        if !switcherView.isHidden { return hideGroupSwitcher() }
        guard !store.groups.isEmpty else { return }
        store.switcherHighlight = store.selected.flatMap { $0.groupID } ?? store.groups.first?.id
        switcherView.isHidden = false
        switcherView.superview?.addSubview(switcherView, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(switcherView)
    }

    func hideGroupSwitcher() {
        guard switcherView?.isHidden == false else { return }
        switcherView?.isHidden = true
        focusSelectedTerminal()
    }

    /// The switcher's own keys: the arrows walk the list, ⌥↩ moves the
    /// current tab into the highlighted group.
    func handleSwitcher(key event: NSEvent) -> Bool {
        let order = switcherGroups
        guard !order.isEmpty else { return false }
        let current = order.firstIndex { $0.id == store.switcherHighlight } ?? 0
        switch Int(event.keyCode) {
        case 125:  // down
            store.switcherHighlight = order[min(current + 1, order.count - 1)].id
            return true
        case 126:  // up
            store.switcherHighlight = order[max(current - 1, 0)].id
            return true
        case 36:  // return
            guard let group = store.group(store.switcherHighlight) else { return false }
            if event.modifierFlags.contains(.option) {
                moveSelectedTab(to: group)
            } else {
                chooseGroup(group)
            }
            return true
        default:
            return false
        }
    }

    var switcherGroups: [TabGroup] {
        var seen: [TabGroup] = []
        for case .group(let g, _) in store.strip where !seen.contains(where: { $0.id == g.id }) { seen.append(g) }
        return seen + store.stashedGroups
    }

    func chooseGroup(_ group: TabGroup) {
        hideGroupSwitcher()
        if group.isStashed { restoreGroup(group) } else { selectGroup(group) }
    }

    func chooseGroupTab(_ tab: Tab) {
        hideGroupSwitcher()
        store.select(tab)
        focusSelectedTerminal()
    }

    /// ⌥↩ in the switcher: the tab you were on joins that island.
    func moveSelectedTab(to group: TabGroup) {
        guard let tab = store.selected else { return }
        store.add([tab], to: group)
        hideGroupSwitcher()
        focusSelectedTerminal()
    }

    // MARK: Peeking into a collapsed island

    /// Hovering a collapsed chip: its terminals as a live row (TabPeek).
    func peekGroup(_ group: TabGroup?) {
        guard let group, group.isCollapsed else { return peek.peekGroup(nil) }
        peek.peekGroup(store.tabs(in: group))
    }
}
