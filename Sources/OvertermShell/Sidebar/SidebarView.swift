import AppKit
import SwiftUI

/// The left column: a rail down its edge choosing Files, Overgit, Sessions
/// or Snippets, and the chosen one filling the rest.
package struct SidebarView: View {
    @ObservedObject package var sidebar: SidebarModel
    @ObservedObject package var tree: FileTreeModel
    @ObservedObject package var worktrees: WorktreeModel
    @ObservedObject package var overgit: OvergitModel
    /// The working tree's numbers, which Overgit's overview reads rather
    /// than asking git for them a second time.
    @ObservedObject package var diff: DiffModel
    @ObservedObject package var snippets: SnippetStore
    @ObservedObject package var sessions: SessionsModel
    @ObservedObject package var api: APIWorkspace
    @ObservedObject package var notes: NotesModel
    @ObservedObject package var database: DatabaseModel
    @ObservedObject package var dockerPanel: DockerPanelModel
    @ObservedObject package var kubernetesPanel: KubernetesPanelModel
    @ObservedObject package var terraformPanel: TerraformPanelModel
    /// The tabs, for the island the panels are scoped to.
    @ObservedObject package var store: TabStore
    package let opener: ExternalOpener
    @ObservedObject package var theme: ChromeTheme
    package let actions: FileTreeActions
    package let worktreeActions: WorktreeActions
    package let overgitActions: OvergitActions
    package let snippetActions: SnippetActions
    package let sessionActions: SessionActions
    package let apiActions: APIActions
    package let notesActions: NotesActions
    package let databaseActions: DatabaseActions
    package let dockerActions: DockerActions
    package let terraformActions: TerraformPanelActions
    /// The Kubernetes page, from the panel's header.
    package let openKubernetesPage: () -> Void
    /// The buttons at the foot of the rail: Activity, the gear, Hide.
    package let railAction: (SidebarRailAction) -> Void
    /// The panel's keys while the sidebar has the keyboard (A11Y-U2), and
    /// the view that takes it — handed to the window, which alone gives it.
    package var onKey: (NSEvent) -> Bool = { _ in false }
    package var keyView: (NSView) -> Void = { _ in }

    package var body: some View {
        HStack(spacing: 0) {
            SidebarRail(sidebar: sidebar, theme: theme, perform: railAction)
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
                        panel: dockerPanel, docker: .shared, checkoutCompose: dockerPanel.checkoutCompose, updates: .shared, settings: .shared,
                        theme: theme, group: group,
                        actions: dockerActions,
                        openPage: dockerActions.openPage, show: dockerActions.showContainer)
                case .kubernetes:
                    KubernetesPanelView(
                        panel: kubernetesPanel, kubernetes: .shared, forwards: .shared, settings: .shared, theme: theme, group: group,
                        openPage: openKubernetesPage)
                case .terraform:
                    TerraformPanelView(panel: terraformPanel, settings: .shared, theme: theme, group: group, actions: terraformActions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(theme.card)
        .background(SidebarKeyCatcher(onKey: onKey, made: keyView))
    }

    /// The island the selected tab is in: what every panel here is about.
    private var group: TabGroup? { store.selected.flatMap { store.group(of: $0) } }

    @ViewBuilder private var files: some View {
        header
        if tree.root == nil {
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tree.rows) { row in
                            FileRowView(row: row, tree: tree, opener: opener, theme: theme, actions: actions)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // The row the keyboard picks is brought into view.
                .onChange(of: tree.selection) { picked in
                    guard let picked else { return }
                    proxy.scrollTo(picked)
                }
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
                .font(.system(size: ChromeMetrics.text(8), weight: .semibold))
                .frame(width: 10)
                .opacity(row.entry.isDirectory ? 1 : 0)
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.system(size: ChromeMetrics.text(11)))
                .frame(width: 14)
            Text(row.entry.name)
                .font(.system(size: ChromeMetrics.text(12)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? theme.text : theme.text2)
        .opacity(row.isIgnored && !isSelected ? 0.45 : 1)
        .padding(.leading, 8 + CGFloat(row.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: ChromeMetrics.row(26))
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
                    .font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3).padding(12)
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
    let session: AgentSession
    let running: Bool
    let worktree: Worktree?
    @ObservedObject var theme: ChromeTheme
    let actions: SessionActions
    @State private var hovering = false

    private var title: String {
        let text = session.title ?? session.lastPrompt ?? session.id
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if running {
                    Circle().fill(TabStatusStyle.done).frame(width: 6, height: 6).help("Running in a tab")
                }
                if session.agent != .claude {
                    // Which agent's, where it isn't Claude Code's.
                    Image(systemName: session.agent.symbol).font(.system(size: ChromeMetrics.text(9))).foregroundStyle(theme.dimText)
                        .help(session.agent.name)
                }
                Text(verbatim: title).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(verbatim: worktree?.displayName ?? (session.directory as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("·")
                Text(session.updated, format: .relative(presentation: .named)).lineLimit(1)
            }
            .font(.system(size: ChromeMetrics.text(10)))
            .foregroundStyle(theme.dimText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? theme.hover : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { actions.resume(session) }
        .help(session.lastPrompt.map { "You: \($0)" } ?? session.directory)
        .contextMenu {
            Button(running ? "Go to Its Tab" : "Resume") { actions.resume(session) }
            Button("Resume in a New Tab") { actions.resumeInNewTab(session) }
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
            if let file = session.file {
                Button("Show Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
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
                    Text("No snippets yet").font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2)
                    Text("A command you keep running, saved by name. \u{007B}\u{007B}value\u{007D}\u{007D} in one is asked for when you use it.")
                        .font(.system(size: ChromeMetrics.text(11)))
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
            Text(snippet.name).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(1)
            Text(snippet.command)
                .font(.system(size: ChromeMetrics.text(10), design: .monospaced))
                .foregroundStyle(theme.dimText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: ChromeMetrics.row(34))
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

/// The sidebar's keyboard (A11Y-U2): a view behind the panel that takes
/// keys only when the window gives it the keyboard (Focus the Sidebar,
/// F6) — never on its own, never as the panel appears or changes.
private struct SidebarKeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool
    let made: (NSView) -> Void

    func makeNSView(context: Context) -> SidebarKeyView {
        let view = SidebarKeyView()
        view.onKey = onKey
        made(view)
        return view
    }

    func updateNSView(_ view: SidebarKeyView, context: Context) { view.onKey = onKey }
}

package final class SidebarKeyView: NSView {
    var onKey: (NSEvent) -> Bool = { _ in false }

    package override var acceptsFirstResponder: Bool { true }
    // Clicks go to the panel's rows, not here.
    package override func hitTest(_ point: NSPoint) -> NSView? { nil }

    package override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    package override func accessibilityIdentifier() -> String { "sidebar.keyboard" }
}
