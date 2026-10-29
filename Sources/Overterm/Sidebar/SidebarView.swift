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
    /// A new file or folder in this folder, asking for its name.
    var newFile: (URL) -> Void = { _ in }
    var newFolder: (URL) -> Void = { _ in }
    /// Asks for a new name.
    var rename: (URL) -> Void = { _ in }
    /// Moves it to the Trash, after asking.
    var trash: (URL) -> Void = { _ in }
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

/// What the sidebar can show, one at a time — the rail down its left
/// edge picks between them (`SidebarRail`).
enum SidebarPanel: String, CaseIterable, Identifiable {
    case files, git, sessions, snippets, api, notes, database, docker

    var id: String { rawValue }

    /// The rail's icons, in the user's order (`general.sidebarOrder`): each
    /// optional panel's only while Settings has it on.
    @MainActor static var shown: [SidebarPanel] { order.filter(\.isEnabled) }

    /// Every panel, in the order the rail draws them.
    @MainActor static var order: [SidebarPanel] { ordered(Settings.shared.value("general.sidebarOrder")?.list ?? []) }

    /// The panels in the order `names` gives: names it doesn't know (or
    /// gives twice) are passed over, and panels it leaves out keep their
    /// place at the end — a new panel turns up in an old order.
    static func ordered(_ names: [String]) -> [SidebarPanel] {
        var panels: [SidebarPanel] = []
        for name in names {
            guard let panel = SidebarPanel(rawValue: name), !panels.contains(panel) else { continue }
            panels.append(panel)
        }
        return panels + allCases.filter { !panels.contains($0) }
    }

    /// `order` with `panel` moved `offset` places among `visible` — past
    /// the next one you can see, not a hidden one between the two.
    static func moving(_ panel: SidebarPanel, by offset: Int, in order: [SidebarPanel], visible: [SidebarPanel]) -> [SidebarPanel] {
        guard let at = visible.firstIndex(of: panel), visible.indices.contains(at + offset),
            let from = order.firstIndex(of: panel), let to = order.firstIndex(of: visible[at + offset])
        else { return order }
        var moved = order
        moved.remove(at: from)
        moved.insert(panel, at: to)
        return moved
    }

    /// Moves the panel in the rail and writes the order to settings.json.
    @MainActor static func move(_ panel: SidebarPanel, by offset: Int) {
        let moved = moving(panel, by: offset, in: order, visible: shown)
        Settings.shared.set("general.sidebarOrder", .list(moved.map(\.rawValue)))
    }

    /// The toggle that shows the panel; nil for Files and Overgit, which
    /// are always there.
    var toggleKey: String? {
        switch self {
        case .api: "api.enabled"
        case .notes: "notes.enabled"
        case .database: "database.enabled"
        case .docker: "docker.enabled"
        case .sessions: "general.sessions"
        case .snippets: "general.snippets"
        case .files, .git: nil
        }
    }

    @MainActor var isEnabled: Bool { toggleKey.map { Settings.shared.bool($0) } ?? true }

    /// What the stored choice means. `worktrees` had an icon of its own
    /// until Overgit took it in; somebody who left the sidebar there finds
    /// their worktrees where they went, not an empty panel.
    init(stored: String?) {
        switch stored {
        case "worktrees": self = .git
        default: self = stored.flatMap(SidebarPanel.init(rawValue:)) ?? .files
        }
    }

    /// The glyph in the rail. Overgit draws its own mark instead (`icon`),
    /// but keeps a symbol for anywhere a plain one is wanted.
    ///
    /// One symbol each, no `.fill` twin: three of the four have none, and a
    /// set that changes shape for the open panel reads as four different
    /// icons rather than one of them being on.
    var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .git: "arrow.triangle.branch"
        case .sessions: "bubble.left.and.bubble.right"
        case .snippets: "curlybraces"
        case .api: "arrow.left.arrow.right"
        case .notes: "note.text"
        case .database: "cylinder.split.1x2"
        case .docker: "shippingbox"
        }
    }

    /// The glyph as the rail draws it: the open panel's is a shade heavier,
    /// which is all the weight the selection needs beside its bar.
    @ViewBuilder func icon(selected: Bool, compact: Bool = false) -> some View {
        switch self {
        // Wider than the symbols beside it: a drawn mark with this much
        // air in it reads a size smaller than Apple's do.
        case .git: OvergitMark().frame(width: compact ? 16 : 19, height: compact ? 16 : 19)
        default: Image(systemName: symbol).font(.system(size: compact ? 13 : 15, weight: selected ? .semibold : .regular))
        }
    }

    var title: String {
        switch self {
        case .git: "Overgit"
        case .api: "API"
        default: rawValue.capitalized
        }
    }
}

/// The left column: a rail down its edge choosing Files, Overgit, Sessions
/// or Snippets, and the chosen one filling the rest.
struct SidebarView: View {
    @ObservedObject var sidebar: SidebarModel
    @ObservedObject var tree: FileTreeModel
    @ObservedObject var worktrees: WorktreeModel
    @ObservedObject var overgit: OvergitModel
    /// The working tree's numbers, which Overgit's overview reads rather
    /// than asking git for them a second time.
    @ObservedObject var diff: DiffModel
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var sessions: SessionsModel
    @ObservedObject var api: APIWorkspace
    @ObservedObject var notes: NotesModel
    @ObservedObject var database: DatabaseModel
    @ObservedObject var dockerPanel: DockerPanelModel
    /// The tabs, for the island the panels are scoped to.
    @ObservedObject var store: TabStore
    let opener: ExternalOpener
    @ObservedObject var theme: ChromeTheme
    let actions: FileTreeActions
    let worktreeActions: WorktreeActions
    let overgitActions: OvergitActions
    let snippetActions: SnippetActions
    let sessionActions: SessionActions
    let apiActions: APIActions
    let notesActions: NotesActions
    let databaseActions: DatabaseActions
    let dockerActions: DockerActions
    /// The gear at the foot of the rail.
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(sidebar: sidebar, theme: theme, onSettings: onSettings, onClose: onClose)
            VStack(spacing: 0) {
                switch sidebar.panel {
                case .files: files
                case .git:
                    OvergitView(
                        model: overgit, diff: diff, worktrees: worktrees, store: store, currentRoot: tree.root, group: group,
                        theme: theme, actions: overgitActions, worktreeActions: worktreeActions)
                case .sessions:
                    SessionListView(
                        model: sessions, worktrees: worktrees, group: group, theme: theme, actions: sessionActions)
                case .snippets: SnippetListView(store: snippets, group: group, theme: theme, actions: snippetActions)
                case .api: APIPanelView(workspace: api, group: group, theme: theme, actions: apiActions)
                case .notes: NotesPanelView(model: notes, theme: theme, actions: notesActions)
                case .database: DatabasePanelView(model: database, store: database.store, theme: theme, actions: databaseActions)
                case .docker:
                    DockerPanelView(
                        panel: dockerPanel, docker: .shared, checkoutCompose: dockerPanel.checkoutCompose, settings: .shared, theme: theme, group: group,
                        actions: dockerActions,
                        openPage: dockerActions.openPage, show: dockerActions.showContainer)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(theme.card)
    }

    /// The island the selected tab is in: what every panel here is about.
    private var group: TabGroup? { store.selected.flatMap { store.group(of: $0) } }

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
        PanelHeader(title: tree.root?.lastPathComponent ?? "Files", group: group, theme: theme, help: tree.root?.path) {
            PanelHeaderButton(symbol: "arrow.clockwise", help: "Reload", action: { tree.reload() }, theme: theme)
            PanelHeaderButton(
                symbol: "rectangle.compress.vertical", help: "Collapse All", action: { tree.collapseAll() }, theme: theme)
        }
    }
}

/// A file tree row, dragged: its file URL.
enum FileTreeDrag {
    static func item(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// The file URLs a drop holds, handed over on the main thread once
    /// every one is read: a bucket's upload, a container's copy.
    static func urls(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let lock = NSLock()
        nonisolated(unsafe) var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(lock.withLock { urls }) } }
    }
}

private struct FileRowView: View {
    let row: FileRow
    @ObservedObject var tree: FileTreeModel
    /// Observed for "Open in <the app picked>".
    @ObservedObject var opener: ExternalOpener
    @ObservedObject var theme: ChromeTheme
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
        .foregroundStyle(isSelected ? theme.text : theme.text2)
        .opacity(row.isIgnored && !isSelected ? 0.45 : 1)
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.rowSel : (hovering ? theme.rowHover : .clear))
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
        // Into a folder, or beside a file.
        let folder = row.entry.isDirectory ? url : url.deletingLastPathComponent()
        Button("New File…") { actions.newFile(folder) }
        Button("New Folder…") { actions.newFolder(folder) }
        Divider()
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
        // Through every symlink — /private/tmp for /tmp, a worktree's target.
        Button("Copy Real Path") { copy(url.resolvingSymlinksInPath().path) }
        Divider()
        Button("Rename…") { actions.rename(url) }
        Button("Move to Trash…") { actions.trash(url) }
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

/// One worktree, in Overgit's Worktrees section: the branch, what is
/// happening in it, and everything you can do to it.
struct WorktreeRowView: View {
    let worktree: Worktree
    let isCurrent: Bool
    /// The tabs working in this checkout, so the row says what is going on
    /// in it rather than only that it exists.
    let tabs: [Tab]
    /// Why the selected tab shows this worktree, when it does.
    let reason: CheckoutReason?
    let merged: MergedWorktrees.Reason?
    let pullRequest: PullRequestSummary?
    @ObservedObject var theme: ChromeTheme
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

    /// What its tabs are doing, in one line. A blocked agent is the thing
    /// worth crossing the sidebar for, so it is named and coloured.
    private var subtitle: (text: String, color: Color)? {
        guard !tabs.isEmpty else { return nil }
        if let blocked = tabs.first(where: { $0.activity.mark == .waiting }) {
            return ("Agent waiting · \(blocked.title)", theme.orangeText)
        }
        let names = tabs.map(\.title).joined(separator: ", ")
        return (names, tabs.contains(where: \.activity.isWorking) ? theme.text2 : theme.text3)
    }

    private var top: some View {
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
        .foregroundStyle(isCurrent ? theme.text : theme.text2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            top
            if let subtitle {
                Text(subtitle.text)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitle.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? theme.rowSel : (hovering ? theme.rowHover : .clear))
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
    let group: TabGroup?
    @ObservedObject var theme: ChromeTheme
    let actions: SessionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Sessions", group: group, theme: theme) {
                if model.loading { ProgressView().controlSize(.mini) }
                PanelHeaderButton(symbol: "arrow.clockwise", help: "Reload", action: actions.refresh, theme: theme)
            }
            if model.sessions.isEmpty {
                Text(model.loading ? "" : "No agent sessions in \(group?.name ?? "this folder") yet")
                    .font(.system(size: 12)).foregroundStyle(theme.text3).padding(12)
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
    @ObservedObject var theme: ChromeTheme
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
    let group: TabGroup?
    @ObservedObject var theme: ChromeTheme
    let actions: SnippetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Snippets", group: group, theme: theme) {
                PanelHeaderButton(symbol: "plus", help: "New Snippet", action: { actions.edit(nil) }, theme: theme)
            }

            if store.snippets.isEmpty {
                // The list is empty on a first run: say what a snippet is,
                // rather than leave the panel blank.
                VStack(alignment: .leading, spacing: 4) {
                    Text("No snippets yet").font(.system(size: 12)).foregroundStyle(theme.text2)
                    Text("A command you keep running, saved by name. \u{007B}\u{007B}value\u{007D}\u{007D} in one is asked for when you use it.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
            } else {
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
}

private struct SnippetRowView: View {
    let snippet: Snippet
    @ObservedObject var theme: ChromeTheme
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
