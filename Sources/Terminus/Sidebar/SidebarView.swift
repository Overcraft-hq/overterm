import AppKit
import SwiftUI

/// What the file tree asks the window to do with an entry.
struct FileTreeActions {
    /// Type the entry's path into the selected terminal.
    var insertPath: (URL) -> Void
    /// Show a file in the editor pane.
    var openInEditor: (URL) -> Void
    /// Open a new tab whose shell starts in this folder.
    var newTab: (URL) -> Void
    /// The path as the selected tab's shell would write it (relative to its
    /// cwd when inside it).
    var relativePath: (URL) -> String
}

/// What the worktree list asks the window to do.
struct WorktreeActions {
    /// Go to a tab in this worktree, or open one.
    var open: (Worktree) -> Void
    var newTab: (Worktree) -> Void
    var newAgentTab: (Worktree, Agent) -> Void
    var remove: (Worktree) -> Void
    /// Pin the selected tab's sidebar and diff to this worktree.
    var attach: (Worktree) -> Void
    /// Back to following the agent / shell.
    var detach: () -> Void
    var newTask: () -> Void
}

/// What the snippet list asks the window to do.
struct SnippetActions {
    /// Use it: type it in (run: and press Return), asking for placeholder
    /// values first if it has any.
    var use: (Snippet, _ run: Bool) -> Void
    /// Open the editor; nil for a new snippet.
    var edit: (Snippet?) -> Void
}

/// What the sidebar can show, one at a time — Warp-style icon tabs.
enum SidebarPanel: String, CaseIterable, Identifiable {
    case files, worktrees, snippets

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .worktrees: "arrow.triangle.branch"
        case .snippets: "text.alignleft"
        }
    }

    var title: String { rawValue.capitalized }
}

/// The left panel: an icon bar choosing Files, Worktrees or Snippets, and
/// the chosen one at full height.
struct SidebarView: View {
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var worktrees: WorktreeModel
    @ObservedObject var snippets: SnippetStore
    let theme: ChromeTheme
    let actions: FileTreeActions
    let worktreeActions: WorktreeActions
    let snippetActions: SnippetActions
    let onClose: () -> Void
    @AppStorage("sidebarPanel", store: AppEnvironment.defaults) private var panel: SidebarPanel = .files

    var body: some View {
        VStack(spacing: 0) {
            panelBar
            Divider().opacity(0.4)
            switch panel {
            case .files: files
            case .worktrees: WorktreeListView(model: worktrees, currentRoot: tree.root, theme: theme, actions: worktreeActions)
            case .snippets: SnippetListView(store: snippets, theme: theme, actions: snippetActions)
            }
        }
        .background(theme.strip)
    }

    private var panelBar: some View {
        HStack(spacing: 4) {
            ForEach(SidebarPanel.allCases) { item in
                Button(action: { panel = item }) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(panel == item ? theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(panel == item ? theme.text : theme.dimText)
                .help(item.title)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Hide Sidebar (⌘B)")
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    @ViewBuilder private var files: some View {
        header
        if tree.root == nil {
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.rows) { row in
                        FileRowView(row: row, tree: tree, theme: theme, actions: actions)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(tree.root?.lastPathComponent ?? "")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(theme.dimText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(tree.root?.path ?? "")
            Spacer(minLength: 0)
            headerButton("arrow.clockwise", help: "Reload") { tree.reload() }
            headerButton("rectangle.compress.vertical", help: "Collapse All") { tree.collapseAll() }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.dimText)
        .help(help)
    }
}

private struct FileRowView: View {
    let row: FileRow
    @ObservedObject var tree: FileTreeModel
    let theme: ChromeTheme
    let actions: FileTreeActions
    @State private var hovering = false

    private var isSelected: Bool { tree.selection == row.id }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .frame(width: 10)
                .opacity(row.entry.isDirectory ? 1 : 0)
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 11))
                .frame(width: 14)
            Text(row.entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? theme.text : theme.dimText)
        .opacity(row.isIgnored && !isSelected ? 0.45 : 1)
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? theme.selected : (hovering ? theme.hover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            tree.selection = row.id
            if row.entry.isDirectory {
                tree.toggle(row)
            } else {
                actions.openInEditor(row.entry.url)
            }
        }
        // Simultaneous, so a plain click isn't held back for the double-click
        // interval. A folder already toggled on the single clicks; a file
        // already opened in the editor, and double-click hands it to its app.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !row.entry.isDirectory { NSWorkspace.shared.open(row.entry.url) }
            }
        )
        .contextMenu { menu }
        .help(row.entry.url.path)
    }

    @ViewBuilder private var menu: some View {
        let url = row.entry.url
        Button("Insert Path in Terminal") { actions.insertPath(url) }
        if row.entry.isDirectory {
            Button("New Tab Here") { actions.newTab(url) }
        } else {
            Button("Open in Editor") { actions.openInEditor(url) }
            Button("Open in Default App") { NSWorkspace.shared.open(url) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button("Copy Path") { copy(url.path) }
        Button("Copy Relative Path") { copy(actions.relativePath(url)) }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct WorktreeListView: View {
    @ObservedObject var model: WorktreeModel
    /// The selected tab's checkout, i.e. the worktree it is in.
    let currentRoot: URL?
    let theme: ChromeTheme
    let actions: WorktreeActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Worktrees")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.dimText)
                Spacer()
                Button(action: actions.newTask) {
                    Image(systemName: "plus").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("New Task… (⇧⌘N)")
                Button(action: { Task { await model.refresh() } }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Reload")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            if model.worktrees.isEmpty {
                Text("Not in a git repository").font(.system(size: 12)).foregroundStyle(theme.dimText).padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.worktrees) { worktree in
                            WorktreeRowView(
                                worktree: worktree,
                                isCurrent: currentRoot?.standardizedFileURL == worktree.path.standardizedFileURL,
                                reason: model.showing.flatMap {
                                    $0.root.standardizedFileURL == worktree.path.standardizedFileURL ? $0.reason : nil
                                },
                                theme: theme, actions: actions)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

private struct WorktreeRowView: View {
    let worktree: Worktree
    let isCurrent: Bool
    /// Why the selected tab shows this worktree, when it does.
    let reason: CheckoutReason?
    let theme: ChromeTheme
    let actions: WorktreeActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
                .font(.system(size: 10))
                .frame(width: 14)
            Text(worktree.displayName)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            switch reason {
            case .attached:
                Image(systemName: "pin.fill").font(.system(size: 9)).help("Attached to this tab")
            case .agent(let agent):
                Image(systemName: agent.symbol).font(.system(size: 9)).foregroundStyle(TabStatusStyle.signal)
                    .help("\(agent.name) is working here")
            default:
                EmptyView()
            }
            if worktree.isLocked {
                Image(systemName: "lock.fill").font(.system(size: 9)).help("Locked")
            }
        }
        .foregroundStyle(isCurrent ? theme.text : theme.dimText)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isCurrent ? theme.selected : (hovering ? theme.hover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.open(worktree) }
        .contextMenu {
            if reason == .attached {
                Button("Detach from This Tab") { actions.detach() }
            } else {
                Button("Attach to This Tab") { actions.attach(worktree) }
            }
            Divider()
            Button("New Tab Here") { actions.newTab(worktree) }
            ForEach(Agent.allCases) { agent in
                Button("New \(agent.name) Tab Here") { actions.newAgentTab(worktree, agent) }
            }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.path]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path.path, forType: .string)
            }
            if !worktree.isMain {
                Divider()
                Button("Remove Worktree…") { actions.remove(worktree) }
            }
        }
        .help(worktree.path.path)
    }
}

private struct SnippetListView: View {
    @ObservedObject var store: SnippetStore
    let theme: ChromeTheme
    let actions: SnippetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Snippets")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                Spacer()
                Button(action: { actions.edit(nil) }) {
                    Image(systemName: "plus").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Snippet")
            }
            .foregroundStyle(theme.dimText)
            .padding(.horizontal, 12)
            .frame(height: 30)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.snippets) { snippet in
                        SnippetRowView(snippet: snippet, theme: theme, actions: actions, onDelete: { store.delete(snippet) })
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

private struct SnippetRowView: View {
    let snippet: Snippet
    let theme: ChromeTheme
    let actions: SnippetActions
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snippet.name).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
            Text(snippet.command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.dimText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : .clear).padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A click types it in without running: Return stays your call.
        .onTapGesture { actions.use(snippet, false) }
        .contextMenu {
            Button("Run") { actions.use(snippet, true) }
            Button("Insert") { actions.use(snippet, false) }
            Divider()
            Button("Edit…") { actions.edit(snippet) }
            Button("Delete") { onDelete() }
        }
        .help(snippet.command)
    }
}
