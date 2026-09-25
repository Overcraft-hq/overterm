import AppKit
import SwiftUI

/// What the file tree asks the window to do with an entry.
struct FileTreeActions {
    /// Type the entry's path into the selected terminal.
    var insertPath: (URL) -> Void
    /// Show a file in the editor pane.
    var openInEditor: (URL) -> Void
    /// Open a file in the app picked for files (ExternalOpener), asking
    /// which the first time.
    var openExternally: (URL) -> Void
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
    /// Remove the merged (and vanished) linked worktrees, after confirming.
    var cleanUp: () -> Void
    /// The right pane on the current checkout's pull request.
    var showPullRequest: () -> Void
}

/// What the snippet list asks the window to do.
struct SnippetActions {
    /// Use it: type it in (run: and press Return), asking for placeholder
    /// values first if it has any.
    var use: (Snippet, _ run: Bool) -> Void
    /// Open the editor; nil for a new snippet.
    var edit: (Snippet?) -> Void
}

/// What the Sessions panel asks the window to do.
struct SessionActions {
    /// Go to the tab it runs in, else resume it in a new tab there.
    var resume: (ClaudeSession) -> Void
    /// Always a new tab, even when it runs somewhere.
    var resumeInNewTab: (ClaudeSession) -> Void
    var refresh: () -> Void
}

/// What the sidebar can show, one at a time — Warp-style icon tabs.
enum SidebarPanel: String, CaseIterable, Identifiable {
    case files, worktrees, sessions, snippets

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .worktrees: "arrow.triangle.branch"
        case .sessions: "bubble.left.and.text.bubble.right"
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
    @ObservedObject var sessions: SessionsModel
    let opener: ExternalOpener
    let theme: ChromeTheme
    let actions: FileTreeActions
    let worktreeActions: WorktreeActions
    let snippetActions: SnippetActions
    let sessionActions: SessionActions
    let onClose: () -> Void
    @AppStorage("sidebarPanel", store: AppEnvironment.defaults) private var panel: SidebarPanel = .files

    var body: some View {
        VStack(spacing: 0) {
            panelBar
            Divider().opacity(0.4)
            switch panel {
            case .files: files
            case .worktrees: WorktreeListView(model: worktrees, currentRoot: tree.root, theme: theme, actions: worktreeActions)
            case .sessions: SessionListView(model: sessions, worktrees: worktrees, theme: theme, actions: sessionActions)
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
                        FileRowView(row: row, tree: tree, opener: opener, theme: theme, actions: actions)
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

/// A file tree row, dragged: its file URL.
enum FileTreeDrag {
    static func item(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

private struct FileRowView: View {
    let row: FileRow
    @ObservedObject var tree: FileTreeModel
    /// Observed for "Open in <the app picked>".
    @ObservedObject var opener: ExternalOpener
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
        // already opened in the editor, and double-click hands it to the app
        // picked for files.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !row.entry.isDirectory { actions.openExternally(row.entry.url) }
            }
        )
        // A drag carries the file, as Finder's does: onto a terminal (its
        // path), Finder, another app.
        .onDrag { FileTreeDrag.item(for: row.entry.url) }
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
            Button(OpenWith.openTitle(opener.current)) { actions.openExternally(url) }
            Menu(OpenWith.submenuTitle) { OpenWithItems(file: url, opener: opener) }
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

/// A file's Open With submenu — the editor ↗'s right-click menu in SwiftUI
/// (ExternalOpener.menu): the apps, the one in use ticked, then Other….
/// Its own view, so LaunchServices is asked when the menu is built, not on
/// every redraw of the row.
private struct OpenWithItems: View {
    let file: URL
    @ObservedObject var opener: ExternalOpener

    var body: some View {
        ForEach(Array(opener.entries(for: file).enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .app(let app, let title, let isCurrent):
                Toggle(isOn: Binding(get: { isCurrent }, set: { _ in opener.open(file, with: app) })) {
                    Label {
                        Text(verbatim: title)
                    } icon: {
                        Image(nsImage: opener.icon(for: app))
                    }
                    .labelStyle(.titleAndIcon)
                }
            case .divider:
                Divider()
            case .other:
                Button(OpenWith.otherTitle) { opener.chooseApp(for: file) }
            }
        }
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
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                if !model.cleanable.isEmpty {
                    Button(action: actions.cleanUp) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.merge").font(.system(size: 9))
                            Text(verbatim: "\(model.cleanable.count)").font(.system(size: 10, weight: .medium))
                        }
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(Capsule().fill(TabStatusStyle.merged.opacity(0.18)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TabStatusStyle.merged)
                    .help("Clean Up Merged Worktrees…")
                }
                Button(action: actions.newTask) {
                    Image(systemName: "plus").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("New Task… (⇧⌘N)")
                Button(action: { Task { await model.refresh(fetch: true) } }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Fetch and reload")
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
                                merged: worktree.branch.flatMap { model.merged[$0] },
                                pullRequest: worktree.branch.flatMap { model.pullRequests[$0] },
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
    let merged: MergedWorktrees.Reason?
    let pullRequest: PullRequestSummary?
    let theme: ChromeTheme
    let actions: WorktreeActions
    @State private var hovering = false

    private var mergedHelp: String {
        switch merged {
        case .upstreamGone: "Merged — its branch was deleted on the remote"
        case .mergedInto(let base): "Merged into \(base)"
        case .pullRequestMerged(let number): "Pull request #\(number) merged"
        case nil: ""
        }
    }

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
            if let pullRequest, !worktree.isMain {
                HStack(spacing: 2) {
                    CIGlyph(overall: pullRequest.checks.overall).font(.system(size: 8, weight: .bold))
                    Text(verbatim: "#\(pullRequest.number)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(StatePill.color(pullRequest.state))
                }
                .fixedSize()
                .help("#\(pullRequest.number) \(pullRequest.title)")
            }
            if merged != nil {
                Image(systemName: "arrow.triangle.merge").font(.system(size: 9)).foregroundStyle(TabStatusStyle.merged)
                    .help(mergedHelp)
            } else if worktree.isPrunable {
                Image(systemName: "questionmark.folder").font(.system(size: 9)).help("Its folder is gone")
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
            if let pullRequest {
                Divider()
                if isCurrent { Button("Show Pull Request #\(pullRequest.number)") { actions.showPullRequest() } }
                if let url = pullRequest.url { Button("Open #\(pullRequest.number) on GitHub") { NSWorkspace.shared.open(url) } }
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
                if merged != nil || worktree.isPrunable {
                    Button("Clean Up Merged Worktrees…") { actions.cleanUp() }
                }
            }
        }
        .help(worktree.path.path)
    }
}

/// Claude Code conversations in this repository's worktrees, newest first.
/// A click goes to the tab it runs in, or resumes it in a new tab.
private struct SessionListView: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var worktrees: WorktreeModel
    let theme: ChromeTheme
    let actions: SessionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.dimText)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 4)
                if model.loading { ProgressView().controlSize(.mini) }
                Button(action: actions.refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimText)
                .help("Reload")
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            if model.sessions.isEmpty {
                Text(model.loading ? "" : "No Claude sessions here yet")
                    .font(.system(size: 12)).foregroundStyle(theme.dimText).padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sessions) { session in
                            SessionRowView(
                                session: session, running: model.running[session.id] != nil,
                                worktree: Worktree.containing(session.directory, in: worktrees.worktrees),
                                theme: theme, actions: actions)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .onAppear(perform: actions.refresh)
        .onChange(of: worktrees.worktrees) { _ in actions.refresh() }
    }
}

private struct SessionRowView: View {
    let session: ClaudeSession
    let running: Bool
    let worktree: Worktree?
    let theme: ChromeTheme
    let actions: SessionActions
    @State private var hovering = false

    private var title: String {
        let text = session.activity.title ?? session.activity.lastPrompt ?? session.id
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if running {
                    Circle().fill(TabStatusStyle.done).frame(width: 6, height: 6).help("Running in a tab")
                }
                Text(verbatim: title).font(.system(size: 12)).foregroundStyle(theme.text).lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(verbatim: worktree?.displayName ?? (session.directory as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("·")
                Text(session.updated, format: .relative(presentation: .named)).lineLimit(1)
            }
            .font(.system(size: 10))
            .foregroundStyle(theme.dimText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.resume(session) }
        .help(session.activity.lastPrompt.map { "You: \($0)" } ?? session.directory)
        .contextMenu {
            Button(running ? "Go to Its Tab" : "Resume") { actions.resume(session) }
            Button("Resume in a New Tab") { actions.resumeInNewTab(session) }
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
            Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.file]) }
        }
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
