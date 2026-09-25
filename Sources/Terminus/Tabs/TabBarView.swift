import AppKit
import SwiftUI

/// What the strip asks its window to do. Closures rather than a reference to
/// the controller, so the hosting view does not retain it.
struct TabBarActions {
    var select: (Tab) -> Void
    var close: (Tab) -> Void
    var newTab: () -> Void
    var newAgentTab: (Agent) -> Void
    var newTask: () -> Void
    /// The ± badge: open the changes pane on the scope the badge counts,
    /// or hide it.
    var toggleDiff: () -> Void
    /// The PR chip: the right pane on the checkout's pull request.
    var showPullRequest: () -> Void
    /// Every tab as a card (⇧⌘A).
    var showOverview: () -> Void
    /// Editing a name ended (committed or cancelled): give the keyboard back
    /// to the terminal.
    var renameEnded: () -> Void
    var setPinned: (Tab, Bool) -> Void
}

/// Chrome-style tab strip, living in the window's title bar.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    @ObservedObject var diff: DiffModel
    /// For the checkout's pull request, next to the ± badge.
    @ObservedObject var worktrees: WorktreeModel
    let theme: ChromeTheme
    /// Room for the traffic lights on the left.
    let leadingInset: CGFloat
    let actions: TabBarActions

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            ForEach(store.tabs) { tab in
                TabItemView(
                    tab: tab,
                    store: store,
                    theme: theme,
                    actions: actions
                )
            }
            // Click: a plain tab. The arrow: an agent tab.
            Menu {
                Button("New Tab") { actions.newTab() }
                Divider()
                ForEach(Agent.allCases) { agent in
                    Button {
                        actions.newAgentTab(agent)
                    } label: {
                        Label("New \(agent.name) Tab", systemImage: agent.symbol)
                    }
                }
                Divider()
                Button("New Task…") { actions.newTask() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
            } primaryAction: {
                actions.newTab()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .foregroundStyle(theme.dimText)
            .help("New Tab (⌘T) — arrow for Claude / Codex")
            .padding(.leading, 6)
            Spacer(minLength: 0)
            Button(action: actions.showOverview) {
                Image(systemName: "square.grid.2x2").font(.system(size: 12)).frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Agent Overview (⇧⌘A)")
            .padding(.trailing, 4)
            if let pr = diff.branch.flatMap({ worktrees.pullRequests[$0] }) {
                PullRequestChip(pr: pr, theme: theme, action: actions.showPullRequest)
                    .padding(.trailing, 6)
            }
            if let badge = diff.badge {
                DiffBadge(badge: badge, theme: theme, action: actions.toggleDiff)
            }
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(WindowDragArea())
        .coordinateSpace(name: TabFramesKey.space)
        .onPreferenceChange(TabFramesKey.self) { frames in
            MainActor.assumeIsolated { store.tabFrames = frames }
        }
    }
}

/// Each tab's frame in the strip, top-left origin.
struct TabFramesKey: PreferenceKey {
    static let space = "tabStrip"
    static let defaultValue: [Tab.ID: CGRect] = [:]

    static func reduce(value: inout [Tab.ID: CGRect], nextValue: () -> [Tab.ID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TabItemView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
    let actions: TabBarActions
    @State private var hovering = false

    private var isSelected: Bool { tab.id == store.selectedID }
    private var isRenaming: Bool { tab.id == store.renamingID }

    private var symbol: String { tab.agent?.symbol ?? "terminal" }

    /// Done / failed / waiting — the mark in front of the name.
    @ViewBuilder private var mark: some View {
        switch tab.activity.mark {
        case .waiting: WaitingDot().help(tab.activity.note ?? "Waiting for you")
        case .failed: ResultMark(failed: true).help(tab.activity.note ?? "Failed")
        case .done: ResultMark(failed: false).help(tab.activity.note ?? "Finished")
        case .none: EmptyView()
        }
    }

    /// A pinned tab is just its icon — the agent's, or a terminal — in the
    /// tab's colour (breathing yellow while it works); the name is in the
    /// tooltip; a mark sits in the corner.
    private var pinnedContent: some View {
        Group {
            if tab.activity.isWorking {
                WorkingGlyph(symbol: symbol, size: 12)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tab.color?.color ?? (isSelected ? theme.text : theme.dimText))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Group {
                switch tab.activity.mark {
                case .waiting: WaitingDot(size: 5)
                case .failed: ResultMark(failed: true, size: 7)
                case .done: ResultMark(failed: false, size: 7)
                case .none: EmptyView()
                }
            }
            .padding(2)
        }
    }

    private var fullContent: some View {
        HStack(spacing: 6) {
            if let color = tab.color {
                Circle().fill(color.color).frame(width: 8, height: 8)
            }
            mark
            if tab.activity.isWorking {
                WorkingGlyph(symbol: tab.agent?.symbol ?? "circle.fill", size: tab.agent == nil ? 6 : 10)
            } else if let agent = tab.agent {
                Image(systemName: agent.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? theme.text : theme.dimText)
                    .help(agent.name)
            }
            if isRenaming {
                TabRenameField(tab: tab, store: store, theme: theme, onEnd: actions.renameEnded)
            } else {
                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? theme.text : theme.dimText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: { actions.close(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .opacity(isSelected || hovering ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.horizontal, 10)
    }

    var body: some View {
        Group {
            if tab.isPinned { pinnedContent } else { fullContent }
        }
        // Pinned: a fixed icon-sized square, as in Chrome. The rest share the
        // remaining width.
        .frame(
            minWidth: tab.isPinned ? 38 : 60, idealWidth: tab.isPinned ? 38 : 200, maxWidth: tab.isPinned ? 38 : 220,
            minHeight: 28, maxHeight: 28
        )
        .fixedSize(horizontal: tab.isPinned, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? theme.selected : (hovering ? theme.hover : .clear))
        )
        .background(
            // A coloured tab carries a faint wash of its colour, so it is
            // findable in a full strip even when not selected.
            RoundedRectangle(cornerRadius: 7)
                .fill(tab.color?.color.opacity(isSelected ? 0.0 : 0.14) ?? .clear)
        )
        .overlay(alignment: .bottom) {
            if tab.activity.isWorking {
                WorkingBar().padding(.horizontal, 6).padding(.bottom, 1)
            } else if isSelected, let color = tab.color {
                Capsule().fill(color.color).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        // Single and double tap together, not exclusively: an exclusive double
        // tap would delay every plain click by the double-click interval.
        .onTapGesture { actions.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !tab.isPinned { store.renamingID = tab.id } })
        .onHover { hovering = $0 }
        // Reordering is done by the window (installTabMouseHandling): drags
        // in the title bar never reach SwiftUI's onDrag.
        .opacity(store.draggingID == tab.id ? 0.75 : 1)
        // Where this tab is, for the window's right-click and drag handling:
        // the title bar swallows both before they reach SwiftUI.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named(TabFramesKey.space))])
            }
        )
        .help(tab.title)
        .padding(.horizontal, 2)
    }
}

/// In-place name editor. Return commits, Escape cancels, an empty name goes
/// back to following the shell title.
private struct TabRenameField: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: TabStore
    let theme: ChromeTheme
    let onEnd: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(theme.text)
            .focused($focused)
            .onAppear {
                draft = tab.title
                focused = true
            }
            .onSubmit(commit)
            .onExitCommand(perform: finish)
            .onChange(of: focused) { isFocused in
                // Clicking elsewhere commits, as in Chrome.
                if !isFocused, store.renamingID == tab.id { commit() }
            }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        tab.customTitle = name.isEmpty || name == tab.shellTitle ? nil : name
        finish()
    }

    private func finish() {
        guard store.renamingID == tab.id else { return }
        store.renamingID = nil
        onEnd()
    }
}

/// Empty strip space drags the window, as a title bar should.
private struct WindowDragArea: NSViewRepresentable {
    typealias DragView = WindowDragView

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Warp's "± +N −M": the selected tab's uncommitted change totals — or,
/// with nothing uncommitted, its branch's; in a repository with neither, a
/// plain ±. A click opens the changes pane on the scope it counts.
private struct DiffBadge: View {
    let badge: DiffModel.Badge
    let theme: ChromeTheme
    let action: () -> Void
    @State private var hovering = false

    /// None for the plain ±.
    private var totals: (added: Int, removed: Int)? {
        switch badge {
        case .uncommitted(let added, let removed), .branch(let added, let removed): (added, removed)
        case .plain: nil
        }
    }

    private var help: String {
        switch badge {
        case .uncommitted: "Uncommitted changes (⌥⌘D)"
        case .branch: "Changes on this branch, all committed (⌥⌘D)"
        case .plain: "Changes (⌥⌘D)"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plusminus").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text)
                if let totals {
                    Text(verbatim: "+\(totals.added)").foregroundStyle(DiffColors.added)
                    Text(verbatim: "−\(totals.removed)").foregroundStyle(DiffColors.removed)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.selected : theme.hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The checkout's pull request in the title bar: number in its state's
/// colour, CI at a glance.
private struct PullRequestChip: View {
    let pr: PullRequestSummary
    let theme: ChromeTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .medium)).foregroundStyle(StatePill.color(pr.state))
                Text(verbatim: "#\(pr.number)").foregroundStyle(theme.text)
                CIGlyph(overall: pr.checks.overall).font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.selected : theme.hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("#\(pr.number) \(pr.title)")
    }
}

/// The strip's host. Its clicks must never start a window drag — the empty
/// part of the strip does that itself (WindowDragArea) — or dragging a tab
/// would move the window instead of the tab.
final class TabStripHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    /// The strip IS the title bar. With the title bar's inset (which
    /// `.ignoresSafeArea()` doesn't undo here) SwiftUI laid it out in the top
    /// 28 pt of its 38, leaving an empty band under the tabs.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

/// Behind the tab strip: pressing empty strip space drags (or, double-clicked,
/// zooms) the window.
final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
