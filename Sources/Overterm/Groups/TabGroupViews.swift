import SwiftUI

/// What an island asks its window to do. Closures, as `TabBarActions` is,
/// so the hosting view never retains the controller.
struct TabGroupActions {
    var select: (TabGroup) -> Void
    var toggleCollapsed: (TabGroup) -> Void
    var rename: (TabGroup) -> Void
    var setColor: (TabGroup, TabColor) -> Void
    var newTab: (TabGroup) -> Void
    var broadcast: (TabGroup) -> Void
    var closeIdle: (TabGroup) -> Void
    var focus: (TabGroup) -> Void
    var stash: (TabGroup) -> Void
    var restore: (TabGroup) -> Void
    var ungroup: (TabGroup) -> Void
    var close: (TabGroup) -> Void
    var setRestoresOnLaunch: (TabGroup, Bool) -> Void
    /// Hovering a collapsed chip peeks into it; nil ends the peek.
    var peek: (TabGroup?) -> Void
}

/// One island: a chip with the group's name, then its tabs, all on a tint
/// of the group's colour so the run reads as one thing.
struct GroupIslandView: View {
    /// The selected tab's branch, shown only on it (`TabItemView.branch`).
    var branch: String?
    @ObservedObject var group: TabGroup
    let tabs: [Tab]
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let actions: TabBarActions
    let groupActions: TabGroupActions

    private var tint: Color { group.color.color }
    private var holdsSelection: Bool { tabs.contains { $0.id == store.selectedID } }
    /// The tab being dragged would land here: say so before it is dropped.
    private var isDropTarget: Bool { store.draggingID != nil && store.dropGroupID == group.id }

    var body: some View {
        HStack(spacing: 0) {
            GroupChip(
                group: group, tabs: tabs, store: store, theme: theme,
                actions: groupActions, holdsSelection: holdsSelection)
            if !group.isCollapsed {
                ForEach(tabs) { tab in
                    TabItemView(
                        branch: branch, tab: tab, store: store, theme: theme, actions: actions, nested: true)
                }
                // The island's own +. The strip's + opens a loose tab now
                // (NewTabGroup), so "another one in here" needs a button of
                // its own — and this is the one place that says it outright.
                Button {
                    groupActions.newTab(group)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .help("New Tab in \(group.name)")
            }
        }
        .padding(TabCard.inset)
        .background(
            // The island you are in is the brighter one, and the only one
            // ringed: with four islands in the strip, "which am I in" has to
            // be answerable without reading a single name.
            RoundedRectangle(cornerRadius: TabCard.radius)
                .fill(tint.opacity(isDropTarget ? 0.26 : (holdsSelection ? 0.16 : 0.09)))
                .overlay(
                    RoundedRectangle(cornerRadius: TabCard.radius)
                        .strokeBorder(
                            isDropTarget ? tint : (holdsSelection ? tint.opacity(0.5) : .clear),
                            lineWidth: isDropTarget ? 2 : 1))
        )
        .padding(.horizontal, 3)
    }
}

/// The island's handle: colour, name, and — collapsed — how many tabs it
/// holds and whether any of them needs you.
private struct GroupChip: View {
    @ObservedObject var group: TabGroup
    let tabs: [Tab]
    @ObservedObject var store: TabStore
    @ObservedObject var theme: ChromeTheme
    let actions: TabGroupActions
    let holdsSelection: Bool
    @State private var hovering = false
    @FocusState private var editing: Bool

    private var isRenaming: Bool { store.renamingGroupID == group.id }
    private var needing: Int { tabs.filter(\.activity.needsAttention).count }
    private var working: Int { tabs.filter(\.activity.isWorking).count }

    /// Filled with the group's colour while you are in it, a wash of it
    /// otherwise — the chip is the island's handle and its label at once.
    private var chipBackground: Color {
        holdsSelection ? group.color.color : group.color.color.opacity(hovering ? 0.30 : 0.20)
    }

    private var chipForeground: Color {
        // The palette is bright by construction, so an active chip takes
        // dark text; an inactive one is the colour itself on the window.
        holdsSelection ? Color(white: 0.08) : group.color.color
    }

    /// One segment per tab along the chip's foot, in its state's colour: a
    /// collapsed island still says what is going on inside it.
    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Capsule().fill(TabStatusStyle.color(for: tab.activity, idle: theme.segIdle)).frame(height: 3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 3)
    }

    /// Up to three of the tabs inside, overlapping, as a stack of cards —
    /// how many, and of what sort, before you expand it.
    private var stack: some View {
        HStack(spacing: -5) {
            ForEach(tabs.prefix(3)) { tab in
                Image(systemName: tab.agent?.symbol ?? tab.kind.symbol)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.text2)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.stackBg).overlay(Circle().strokeBorder(theme.win, lineWidth: 1.5)))
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                GroupNameField(group: group, store: store)
            } else {
                Text(verbatim: group.name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(chipForeground)
                    .lineLimit(1)
            }
            if group.isCollapsed {
                stack
                if needing > 0 {
                    WaitingDot(size: 6).help("\(needing) tab\(needing == 1 ? "" : "s") in \(group.name) need you")
                } else if working > 0 {
                    WorkingSpinner(size: 11).help("\(working) working in \(group.name)")
                }
            }
        }
        .padding(.horizontal, 10)
        // The chip is a card inside the island, like the tabs beside it.
        .frame(height: TabCard.nested)
        .background(RoundedRectangle(cornerRadius: TabCard.nestedRadius).fill(chipBackground))
        .overlay(alignment: .bottom) { if group.isCollapsed { segments } }
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { actions.toggleCollapsed(group) } }
        .onHover { inside in
            hovering = inside
            // Only a collapsed island peeks: an open one is already there.
            actions.peek(inside && group.isCollapsed ? group : nil)
        }
        .help(group.isCollapsed ? "Expand \(group.name) — hover to peek inside" : "Collapse \(group.name)")
        // No .contextMenu: the strip is in the title bar, which takes
        // right-clicks before SwiftUI sees them. The window's monitor finds
        // the chip by this frame instead (TerminalWindowController).
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: GroupChipFramesKey.self,
                    value: [group.id: proxy.frame(in: .named(TabFramesKey.space))])
            }
        }
    }
}

/// Renaming inside the chip, as a tab's own rename works: ↩ confirms,
/// Esc cancels, and the keyboard goes back to the terminal either way.
private struct GroupNameField: View {
    @ObservedObject var group: TabGroup
    @ObservedObject var store: TabStore
    @State private var draft: String = ""

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: max(60, CGFloat(draft.count) * 7 + 12))
            .onSubmit {
                let trimmed = draft.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { group.name = trimmed }
                store.renamingGroupID = nil
            }
            .onExitCommand { store.renamingGroupID = nil }
            .onAppear { draft = group.name }
    }
}
