import AppKit
import SwiftUI

/// What the file tree asks the window to do with an entry.
package struct FileTreeActions {
    /// Type the entry's path into the selected terminal.
    package var insertPath: (URL) -> Void
    /// Show a file in the editor pane.
    package var openInEditor: (URL) -> Void
    /// Open a file in the app picked for files (ExternalOpener), asking
    /// which the first time.
    package var openExternally: (URL) -> Void
    /// Open a new tab whose shell starts in this folder.
    package var newTab: (URL) -> Void
    /// The path as the selected tab's shell would write it (relative to its
    /// cwd when inside it).
    package var relativePath: (URL) -> String
    /// A new file or folder in this folder, asking for its name.
    package var newFile: (URL) -> Void = { _ in }
    package var newFolder: (URL) -> Void = { _ in }
    /// Asks for a new name.
    package var rename: (URL) -> Void = { _ in }
    /// Moves it to the Trash, after asking.
    package var trash: (URL) -> Void = { _ in }

    package init(
        insertPath: @escaping (URL) -> Void, openInEditor: @escaping (URL) -> Void, openExternally: @escaping (URL) -> Void, newTab: @escaping (URL) -> Void, relativePath: @escaping (URL) -> String,
        newFile: @escaping (URL) -> Void = { _ in }, newFolder: @escaping (URL) -> Void = { _ in }, rename: @escaping (URL) -> Void = { _ in }, trash: @escaping (URL) -> Void = { _ in }
    ) {
        self.insertPath = insertPath
        self.openInEditor = openInEditor
        self.openExternally = openExternally
        self.newTab = newTab
        self.relativePath = relativePath
        self.newFile = newFile
        self.newFolder = newFolder
        self.rename = rename
        self.trash = trash
    }
}

/// What the worktree list asks the window to do.
package struct WorktreeActions {
    /// Go to a tab in this worktree, or open one.
    package var open: (Worktree) -> Void
    package var newTab: (Worktree) -> Void
    package var newAgentTab: (Worktree, Agent) -> Void
    package var remove: (Worktree) -> Void
    /// Pin the selected tab's sidebar and diff to this worktree.
    package var attach: (Worktree) -> Void
    /// Back to following the agent / shell.
    package var detach: () -> Void
    package var newTask: () -> Void
    /// Remove the merged (and vanished) linked worktrees, after confirming.
    package var cleanUp: () -> Void
    /// The right pane on the current checkout's pull request.
    package var showPullRequest: () -> Void

    package init(
        open: @escaping (Worktree) -> Void, newTab: @escaping (Worktree) -> Void, newAgentTab: @escaping (Worktree, Agent) -> Void, remove: @escaping (Worktree) -> Void,
        attach: @escaping (Worktree) -> Void, detach: @escaping () -> Void, newTask: @escaping () -> Void, cleanUp: @escaping () -> Void, showPullRequest: @escaping () -> Void
    ) {
        self.open = open
        self.newTab = newTab
        self.newAgentTab = newAgentTab
        self.remove = remove
        self.attach = attach
        self.detach = detach
        self.newTask = newTask
        self.cleanUp = cleanUp
        self.showPullRequest = showPullRequest
    }
}

/// What the snippet list asks the window to do.
package struct SnippetActions {
    /// Use it: type it in (run: and press Return), asking for placeholder
    /// values first if it has any.
    package var use: (Snippet, _ run: Bool) -> Void
    /// Open the editor; nil for a new snippet.
    package var edit: (Snippet?) -> Void

    package init(use: @escaping (Snippet, _ run: Bool) -> Void, edit: @escaping (Snippet?) -> Void) {
        self.use = use
        self.edit = edit
    }
}

/// What the Sessions panel asks the window to do.
package struct SessionActions {
    /// Go to the tab it runs in, else resume it in a new tab there.
    package var resume: (AgentSession) -> Void
    /// Always a new tab, even when it runs somewhere.
    package var resumeInNewTab: (AgentSession) -> Void
    package var refresh: () -> Void

    package init(resume: @escaping (AgentSession) -> Void, resumeInNewTab: @escaping (AgentSession) -> Void, refresh: @escaping () -> Void) {
        self.resume = resume
        self.resumeInNewTab = resumeInNewTab
        self.refresh = refresh
    }
}

/// What the sidebar can show, one at a time — the rail down its left
/// edge picks between them (`SidebarRail`).
package enum SidebarPanel: String, CaseIterable, Identifiable {
    case files, git, sessions, snippets, api, notes, database, docker, kubernetes, terraform

    package var id: String { rawValue }

    /// The rail's icons, in the user's order (`general.sidebarOrder`): each
    /// optional panel's only while Settings has it on.
    @MainActor package static var shown: [SidebarPanel] { order.filter(\.isEnabled) }

    /// Every panel, in the order the rail draws them.
    @MainActor package static var order: [SidebarPanel] { ordered(Settings.shared.value("general.sidebarOrder")?.list ?? []) }

    /// The panels in the order `names` gives: names it doesn't know (or
    /// gives twice) are passed over, and panels it leaves out keep their
    /// place at the end — a new panel turns up in an old order.
    package static func ordered(_ names: [String]) -> [SidebarPanel] {
        var panels: [SidebarPanel] = []
        for name in names {
            guard let panel = SidebarPanel(rawValue: name), !panels.contains(panel) else { continue }
            panels.append(panel)
        }
        return panels + allCases.filter { !panels.contains($0) }
    }

    /// `order` with `panel` moved `offset` places among `visible` — past
    /// the next one you can see, not a hidden one between the two.
    package static func moving(_ panel: SidebarPanel, by offset: Int, in order: [SidebarPanel], visible: [SidebarPanel]) -> [SidebarPanel] {
        guard let at = visible.firstIndex(of: panel), visible.indices.contains(at + offset),
            let from = order.firstIndex(of: panel), let to = order.firstIndex(of: visible[at + offset])
        else { return order }
        var moved = order
        moved.remove(at: from)
        moved.insert(panel, at: to)
        return moved
    }

    /// Moves the panel in the rail and writes the order to settings.json.
    @MainActor package static func move(_ panel: SidebarPanel, by offset: Int) {
        let moved = moving(panel, by: offset, in: order, visible: shown)
        Settings.shared.set("general.sidebarOrder", .list(moved.map(\.rawValue)))
    }

    /// The toggle that shows the panel; nil for Files and Overgit, which
    /// are always there.
    package var toggleKey: String? {
        switch self {
        case .api: "api.enabled"
        case .notes: "notes.enabled"
        case .database: "database.enabled"
        case .docker: "docker.enabled"
        case .kubernetes: "kubernetes.enabled"
        case .terraform: "terraform.enabled"
        case .sessions: "general.sessions"
        case .snippets: "general.snippets"
        case .files, .git: nil
        }
    }

    @MainActor package var isEnabled: Bool { toggleKey.map { Settings.shared.bool($0) } ?? true }

    /// What the stored choice means. `worktrees` had an icon of its own
    /// until Overgit took it in; somebody who left the sidebar there finds
    /// their worktrees where they went, not an empty panel.
    package init(stored: String?) {
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
    package var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .git: "arrow.triangle.branch"
        case .sessions: "bubble.left.and.bubble.right"
        case .snippets: "curlybraces"
        case .api: "arrow.left.arrow.right"
        case .notes: "note.text"
        case .database: "cylinder.split.1x2"
        case .docker: "shippingbox"
        case .kubernetes: "helm"
        case .terraform: "square.stack.3d.up"
        }
    }

    /// The glyph as the rail draws it: the open panel's is a shade heavier,
    /// which is all the weight the selection needs beside its bar.
    @ViewBuilder package func icon(selected: Bool, compact: Bool = false) -> some View {
        switch self {
        // Wider than the symbols beside it: a drawn mark with this much
        // air in it reads a size smaller than Apple's do.
        case .git: OvergitMark().frame(width: compact ? 16 : 19, height: compact ? 16 : 19)
        default: Image(systemName: symbol).font(.system(size: compact ? 13 : 15, weight: selected ? .semibold : .regular))
        }
    }

    /// The command that shows the panel, for the rail's tooltip (DISC-U4).
    /// Docker's and Kubernetes' open their page, not the panel: none.
    package var commandID: String? {
        switch self {
        case .files: "files.show"
        case .git: "overgit.show"
        case .sessions: "sessions.show"
        case .snippets: "snippets.show"
        case .api: "api.show"
        case .notes: "notes.show"
        case .database: "database.show"
        case .terraform: "terraform.show"
        case .docker, .kubernetes: nil
        }
    }

    package var title: String {
        switch self {
        case .git: "Overgit"
        case .api: "API"
        default: rawValue.capitalized
        }
    }
}

/// A file tree row, dragged: its file URL.
package enum FileTreeDrag {
    package static func item(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// The file URLs a drop holds, handed over on the main thread once
    /// every one is read: a bucket's upload, a container's copy.
    package static func urls(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
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

/// One worktree, in Overgit's Worktrees section: the branch, what is
/// happening in it, and everything you can do to it.
package struct WorktreeRowView: View {
    package let worktree: Worktree
    package let isCurrent: Bool
    /// The tabs working in this checkout, so the row says what is going on
    /// in it rather than only that it exists.
    package let tabs: [Tab]
    /// Why the selected tab shows this worktree, when it does.
    package let reason: CheckoutReason?
    package let merged: MergedWorktrees.Reason?
    package let pullRequest: PullRequestSummary?
    @ObservedObject package var theme: ChromeTheme
    package let actions: WorktreeActions
    @State private var hovering = false

    package init(
        worktree: Worktree, isCurrent: Bool, tabs: [Tab], reason: CheckoutReason?, merged: MergedWorktrees.Reason?, pullRequest: PullRequestSummary?, theme: ChromeTheme, actions: WorktreeActions
    ) {
        self.worktree = worktree
        self.isCurrent = isCurrent
        self.tabs = tabs
        self.reason = reason
        self.merged = merged
        self.pullRequest = pullRequest
        self._theme = ObservedObject(wrappedValue: theme)
        self.actions = actions
    }

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
                .font(.system(size: ChromeMetrics.text(10)))
                .frame(width: 14)
            Text(worktree.displayName)
                .font(.system(size: ChromeMetrics.text(12), weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            switch reason {
            case .attached:
                Image(systemName: "pin.fill").font(.system(size: ChromeMetrics.text(9))).help("Attached to this tab")
            case .agent(let agent):
                Image(systemName: agent.symbol).font(.system(size: ChromeMetrics.text(9))).foregroundStyle(TabStatusStyle.signal)
                    .help("\(agent.name) is working here")
            default:
                EmptyView()
            }
            if let pullRequest, !worktree.isMain {
                HStack(spacing: 2) {
                    CIGlyph(overall: pullRequest.checks.overall).font(.system(size: ChromeMetrics.text(8), weight: .bold))
                    Text(verbatim: "#\(pullRequest.number)").font(.system(size: ChromeMetrics.text(10), design: .monospaced))
                        .foregroundStyle(StatePill.color(pullRequest.state))
                }
                .fixedSize()
                .help("#\(pullRequest.number) \(pullRequest.title)")
            }
            if merged != nil {
                Image(systemName: "arrow.triangle.merge").font(.system(size: ChromeMetrics.text(9))).foregroundStyle(TabStatusStyle.merged)
                    .help(mergedHelp)
            } else if worktree.isPrunable {
                Image(systemName: "questionmark.folder").font(.system(size: ChromeMetrics.text(9))).help("Its folder is gone")
            }
            if worktree.isLocked {
                Image(systemName: "lock.fill").font(.system(size: ChromeMetrics.text(9))).help("Locked")
            }
        }
        .foregroundStyle(isCurrent ? theme.text : theme.text2)
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            top
            if let subtitle {
                Text(subtitle.text)
                    .font(.system(size: ChromeMetrics.text(11)))
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
