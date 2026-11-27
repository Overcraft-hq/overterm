import AppKit

/// One tab: its terminals (one, or several split panes) and what the tab
/// bar shows for it.
@MainActor
package final class Tab: ObservableObject, Identifiable {
    package let id = UUID()
    /// The pane with the keyboard — the tab's only terminal until it is
    /// split. Typing, search, the title and the directory follow it; what
    /// concerns the whole tab (closing, its processes) goes over `terminals`.
    @Published package private(set) var terminal: TerminalView
    /// The tab's panes.
    @Published package private(set) var splits: SplitTree<TerminalView>
    /// A pane shown alone, filling the tab (toggle_split_zoom).
    @Published package var zoomed: TerminalView?

    package var terminals: [TerminalView] { splits.leaves }
    package var isSplit: Bool { terminals.count > 1 }

    /// What the shell last set via OSC 0/2 (shell integration sets it to the
    /// running command or the cwd).
    @Published package var shellTitle: String

    /// The shell's current directory, as last reported.
    @Published package var workingDirectory: String?

    /// Where the tab's agent is working, when that differs
    /// from the shell — Claude Code chdirs into a worktree on EnterWorktree.
    /// The census's light tick reads it for every tab of a window on screen
    /// (`TerminalWindowController.takeLightTick`).
    @Published package var agentDirectory: String?

    /// A checkout the user attached to this tab: tree, diff and worktree
    /// highlight show it instead of following the shell or the agent.
    @Published package var attachedCheckout: URL?

    /// What the sidebar and diff show for this tab: an attached checkout,
    /// else where its agent works, else the shell's directory.
    package var checkoutSource: (root: URL, reason: CheckoutReason)? {
        Self.checkoutSource(workingDirectory: workingDirectory, agentDirectory: agentDirectory, attached: attachedCheckout, agent: agent)
    }

    /// The same, from given values — for subscribers: @Published emits
    /// before the property is set, so reading the tab back in a sink sees
    /// the old value.
    package static func checkoutSource(
        workingDirectory: String?, agentDirectory: String?, attached: URL?, agent: Agent?
    ) -> (root: URL, reason: CheckoutReason)? {
        if let attached { return (attached, .attached) }
        if let agentDirectory { return (FileTreeModel.treeRoot(for: agentDirectory), .agent(agent ?? .claude)) }
        return workingDirectory.map { (FileTreeModel.treeRoot(for: $0), .shell) }
    }

    /// A name the user gave the tab; overrides the shell title while set.
    @Published package var customTitle: String?

    @Published package var color: TabColor?
    /// Pinned tabs sit at the left of the strip and are not closed by ⌘W or
    /// the close-others/right actions — only by their process exiting.
    /// Set through TabStore.setPinned, which keeps pinned tabs first.
    @Published package var isPinned = false

    @Published package var activity = TabActivity()

    /// What its checkout deploys has failed (attention marks, 3.13): the
    /// newest first — Ask Why on the mark asks about the first.
    @Published package var kubeAlertsStorage: [AnyHashable] = []
    /// Why its checkout's failures won't mark it now ("not watched");
    /// nil while they will, or nothing is bound.
    @Published package var kubeNotWatched: String?
    /// One of its panes asks for a Terraform write (TerraformPrompt, 3.3):
    /// its tab's mark and the Inbox's card; never answered by Overterm.
    @Published package var terraformAskStorage: Any?
    /// What an agent that sent no signal asks on one of its panes' screens
    /// (`AgentScreenCheck`), as last read; nil when nothing.
    package var screenAsk: String?

    /// The island this tab belongs to, if any. The group is looked up in
    /// `TabStore.groups`; the store keeps a group's tabs contiguous.
    @Published package var groupID: TabGroup.ID?

    /// The agent this tab was opened for, if any.
    package let agent: Agent?

    package init(terminal: TerminalView, agent: Agent? = nil) {
        self.terminal = terminal
        self.splits = .leaf(terminal)
        self.agent = agent
        self.workingDirectory = terminal.workingDirectory
        self.shellTitle = terminal.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
    }

    /// What this tab's processes listen on, from the census's light tick
    /// (`TerminalWindowController.takeLightTick`, docs/design/activity/
    /// analysis.md 7.3): every tab of a window on screen, a tab never
    /// selected too, every 2 s; a hidden window's catch up as it shows.
    @Published package var ports: [ListeningPort] = []
    /// `ports` by the pane whose tree listens on each: a pane's header says
    /// its own, never its neighbour's server.
    @Published package var panePorts: [ObjectIdentifier: [ListeningPort]] = [:]

    package func ports(of pane: TerminalView) -> [ListeningPort] { panePorts[ObjectIdentifier(pane)] ?? [] }
    /// Each pane's agent and the conversation it would pick back up, as
    /// the light tick last read it (`notePaneAgents`): what the session
    /// saves, so every pane comes back with its own agent and Claude its
    /// own conversation — not the tab's first pane, `--continue`'s newest.
    @Published package var paneResumes: [ObjectIdentifier: AgentResume] = [:]
    /// The process each pane's record was read from, and when its session
    /// file was last read: read again only for a new one, or now and then.
    package var paneAgentReads: [ObjectIdentifier: (identity: ActivityProcessID, readAt: Date)] = [:]

    package func resume(of pane: TerminalView) -> AgentResume? { paneResumes[ObjectIdentifier(pane)] }
    /// The pane whose agent last asked for you — by its notification or
    /// bell, or a question the screen check read there: what the Inbox
    /// reads and answers into, whichever pane has the keyboard.
    package weak var askingPane: TerminalView?

    /// `askingPane` while it is still one of the tab's, else the focused one.
    package var askingTerminal: TerminalView {
        if let askingPane, terminals.contains(where: { $0 === askingPane }) { return askingPane }
        return terminal
    }
    /// What the compose projects of its checkout publish (DockerModel).
    /// Apart from `ports`: they don't make the tab a server.
    @Published package var containerPorts: [ListeningPort] = []
    /// The Kubernetes port-forwards started from this tab (`KubeForwards`):
    /// pills naming the pod each is pinned to. Apart from `ports` too.
    @Published package var forwardPorts: [ListeningPort] = []
    /// The ports a pane's pill freed, watched until they are
    /// (`TerminalWindowController.watchFreed`): the header says when.
    @Published package var portFreeing: [PortFreeing] = []

    package func portFreeing(of pane: TerminalView) -> [PortFreeing] { portFreeing.filter { $0.pane == ObjectIdentifier(pane) } }

    /// What this tab is, for the glyph in its icon tile.
    package var kind: TabKind {
        TabKind.of(
            agent: agent, title: shellTitle, hasPort: !ports.isEmpty, pinned: kubeBadge != nil, terraform: terminals.contains { $0.terraformRoot != nil })
    }

    /// What the strip says of the panes' contexts: one, `mixed`, or a lost
    /// pin (Kubernetes' `Tab.kubeBadgeHook`).
    package var kubeBadge: KubeTabBadge? { Tab.kubeBadgeOf?(self) }

    /// Kubernetes' reading of a tab's pins (`KubeTabBadge.of`).
    package static var kubeBadgeOf: (@MainActor (Tab) -> KubeTabBadge?)? {
        FeatureHooks.ensure()
        return kubeBadgeHook
    }
    package nonisolated(unsafe) static var kubeBadgeHook: (@MainActor (Tab) -> KubeTabBadge?)?

    /// What the strip shows: the name you gave it, else the shell's title
    /// shortened to the folder itself. Shells (and themes) set the title to
    /// the whole path, which fills a tab with `~/Documents/opensource/`
    /// and hides the part that tells them apart.
    package var title: String { customTitle ?? Self.shortened(shellTitle) }

    /// The last component of a title that is nothing but a path; anything
    /// else is left alone — `pnpm dev` and `nvim src/main.swift` say what
    /// they say, and cutting them would lose it.
    package static func shortened(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("/"), !trimmed.contains(" ") else { return title }
        // A path and nothing else: /src/app, ~/src/app, src/app, with any
        // number of trailing slashes.
        var path = trimmed
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? title : last
    }

    /// `pane` has the keyboard now; the tab shows its title and directory.
    package func focus(_ pane: TerminalView) {
        guard pane !== terminal, splits.contains(pane) else { return }
        terminal = pane
        if let title = pane.title { shellTitle = title }
        if let directory = pane.workingDirectory { workingDirectory = directory }
    }

    /// A new layout. The focused pane stays focused while it is still in
    /// it, else the first pane is; a zoomed pane that left unzooms.
    package func setSplits(_ splits: SplitTree<TerminalView>) {
        self.splits = splits
        if let zoomed, !splits.contains(zoomed) { self.zoomed = nil }
        if !splits.contains(terminal), let first = splits.leaves.first { focus(first) }
    }
}

/// Why a tab shows the checkout it shows.
package enum CheckoutReason: Equatable {
    case shell
    case agent(Agent)
    case attached
}
