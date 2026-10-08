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
    @ObservedObject var group: TabGroup
    let tabs: [Tab]
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
    let actions: TabBarActions
    let groupActions: TabGroupActions

    private var tint: Color { group.color.color }
    private var holdsSelection: Bool { tabs.contains { $0.id == store.selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            GroupChip(
                group: group, tabs: tabs, store: store, theme: theme,
                actions: groupActions, holdsSelection: holdsSelection)
            if !group.isCollapsed {
                ForEach(tabs) { tab in
                    TabItemView(tab: tab, store: store, theme: theme, actions: actions)
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(holdsSelection ? 0.16 : 0.10))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35), lineWidth: 1))
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
    let theme: ChromeTheme
    let actions: TabGroupActions
    let holdsSelection: Bool
    @State private var hovering = false
    @FocusState private var editing: Bool

    private var isRenaming: Bool { store.renamingGroupID == group.id }
    private var needing: Int { tabs.filter(\.activity.needsAttention).count }
    private var working: Int { tabs.filter(\.activity.isWorking).count }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(group.color.color).frame(width: 7, height: 7)
            if isRenaming {
                GroupNameField(group: group, store: store)
            } else {
                Text(verbatim: group.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
            if group.isCollapsed {
                Text(verbatim: "\(tabs.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.dimText)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(theme.dimText.opacity(0.18)))
                if needing > 0 {
                    WaitingDot(size: 6).help("\(needing) tab\(needing == 1 ? "" : "s") in \(group.name) need you")
                } else if working > 0 {
                    WorkingGlyph(symbol: "terminal", size: 9).help("\(working) working in \(group.name)")
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? group.color.color.opacity(0.22) : .clear)
        )
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
