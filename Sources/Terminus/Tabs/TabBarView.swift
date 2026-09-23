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
    /// The ± badge: show or hide the changes pane.
    var toggleDiff: () -> Void
    /// Editing a name ended (committed or cancelled): give the keyboard back
    /// to the terminal.
    var renameEnded: () -> Void
    var setPinned: (Tab, Bool) -> Void
}

/// Chrome-style tab strip, living in the window's title bar.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    @ObservedObject var diff: DiffModel
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
            if diff.error == nil, !diff.files.isEmpty {
                DiffBadge(added: diff.totals.added, removed: diff.totals.removed, theme: theme, action: actions.toggleDiff)
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

    /// Signal yellow: the brand's "look here".
    private static let attention = Color(red: 1.0, green: 0.882, blue: 0.29)

    private var symbol: String { tab.agent?.symbol ?? "terminal" }

    /// A pinned tab is just its icon — the agent's, or a terminal — in the
    /// tab's colour; the name is in the tooltip. Attention and work show as
    /// a corner mark.
    private var pinnedContent: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tab.color?.color ?? (isSelected ? theme.text : theme.dimText))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if tab.activity.needsAttention {
                    Circle().fill(Self.attention).frame(width: 6, height: 6).padding(5)
                } else if tab.activity.isWorking {
                    ProgressView().controlSize(.mini).scaleEffect(0.5).frame(width: 8, height: 8).padding(3)
                }
            }
    }

    private var fullContent: some View {
        HStack(spacing: 6) {
            if let color = tab.color {
                Circle().fill(color.color).frame(width: 8, height: 8)
            }
            if tab.activity.needsAttention {
                Circle()
                    .fill(Self.attention)
                    .frame(width: 7, height: 7)
                    .help(tab.activity.note ?? "Needs your attention")
            } else if tab.activity.isWorking {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            }
            if let agent = tab.agent {
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
            if isSelected, let color = tab.color {
                Capsule().fill(color.color).frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        // Single and double tap together, not exclusively: an exclusive double
        // tap would delay every plain click by the double-click interval.
        .onTapGesture { actions.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !tab.isPinned { store.renamingID = tab.id } })
        .onHover { hovering = $0 }
        .onDrag {
            store.draggingID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, store: store))
        // Where this tab is, for the window's right-click handling: a
        // SwiftUI .contextMenu never fires here — the title bar swallows
        // right-clicks before they reach the strip.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TabFramesKey.self, value: [tab.id: proxy.frame(in: .named(TabFramesKey.space))])
            }
        )
        .help(tab.title)
        .padding(.horizontal, 2)
    }
}

/// Reorders live: as a dragged tab passes over another in its group, they
/// swap places, like Chrome.
private struct TabDropDelegate: DropDelegate {
    let target: Tab
    let store: TabStore

    func dropEntered(info: DropInfo) {
        guard let id = store.draggingID, let dragged = store.tabs.first(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.12)) { store.move(dragged, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.draggingID = nil
        return true
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
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Warp's "± +N −M": the selected tab's uncommitted change totals; a click
/// opens the changes pane.
private struct DiffBadge: View {
    let added: Int
    let removed: Int
    let theme: ChromeTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plusminus").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text)
                Text("+\(added)").foregroundStyle(DiffColors.added)
                Text("−\(removed)").foregroundStyle(DiffColors.removed)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.selected : theme.hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Uncommitted changes (⌥⌘D)")
    }
}
