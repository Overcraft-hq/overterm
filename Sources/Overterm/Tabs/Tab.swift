import AppKit

/// One tab: its terminals (one, or several split panes) and what the tab
/// bar shows for it.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    /// The pane with the keyboard — the tab's only terminal until it is
    /// split. Typing, search, the title and the directory follow it; what
    /// concerns the whole tab (closing, its processes) goes over `terminals`.
    @Published private(set) var terminal: TerminalView
    /// The tab's panes.
    @Published private(set) var splits: SplitTree<TerminalView>
    /// A pane shown alone, filling the tab (toggle_split_zoom).
    @Published var zoomed: TerminalView?

    var terminals: [TerminalView] { splits.leaves }
    var isSplit: Bool { terminals.count > 1 }

    /// What the shell last set via OSC 0/2 (shell integration sets it to the
    /// running command or the cwd).
    @Published var shellTitle: String

    /// The shell's current directory, as last reported.
    @Published var workingDirectory: String?

    /// Where the tab's agent (claude, codex) is working, when that differs
    /// from the shell — Claude Code chdirs into a worktree on EnterWorktree.
    /// Polled by the window for the selected tab.
    @Published var agentDirectory: String?

    /// A checkout the user attached to this tab: tree, diff and worktree
    /// highlight show it instead of following the shell or the agent.
    @Published var attachedCheckout: URL?

    /// What the sidebar and diff show for this tab: an attached checkout,
    /// else where its agent works, else the shell's directory.
    var checkoutSource: (root: URL, reason: CheckoutReason)? {
        Self.checkoutSource(workingDirectory: workingDirectory, agentDirectory: agentDirectory, attached: attachedCheckout, agent: agent)
    }

    /// The same, from given values — for subscribers: @Published emits
    /// before the property is set, so reading the tab back in a sink sees
    /// the old value.
    static func checkoutSource(
        workingDirectory: String?, agentDirectory: String?, attached: URL?, agent: Agent?
    ) -> (root: URL, reason: CheckoutReason)? {
        if let attached { return (attached, .attached) }
        if let agentDirectory { return (FileTreeModel.treeRoot(for: agentDirectory), .agent(agent ?? .claude)) }
        return workingDirectory.map { (FileTreeModel.treeRoot(for: $0), .shell) }
    }

    /// A name the user gave the tab; overrides the shell title while set.
    @Published var customTitle: String?

    @Published var color: TabColor?
    /// Pinned tabs sit at the left of the strip and are not closed by ⌘W or
    /// the close-others/right actions — only by their process exiting.
    /// Set through TabStore.setPinned, which keeps pinned tabs first.
    @Published var isPinned = false

    @Published var activity = TabActivity()

    /// The island this tab belongs to, if any. The group is looked up in
    /// `TabStore.groups`; the store keeps a group's tabs contiguous.
    @Published var groupID: TabGroup.ID?

    /// The agent this tab was opened for, if any.
    let agent: Agent?

    init(terminal: TerminalView, agent: Agent? = nil) {
        self.terminal = terminal
        self.splits = .leaf(terminal)
        self.agent = agent
        self.workingDirectory = terminal.workingDirectory
        self.shellTitle = terminal.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
    }

    /// What the strip shows: the name you gave it, else the shell's title
    /// shortened to the folder itself. Shells (and themes) set the title to
    /// the whole path, which fills a tab with `~/Documents/opensource/`
    /// and hides the part that tells them apart.
    /// What this tab's processes listen on, filled by the window's poll
    /// (`pollAgentDirectory`, for the selected tab). A tab is only scanned
    /// once you have been in it — so a server you have never opened shows
    /// as a shell until you do, which is the cheap half of the trade: the
    /// scan is an `lsof`.
    @Published var ports: [ListeningPort] = []

    /// What this tab is, for the glyph in its icon tile.
    var kind: TabKind { TabKind.of(agent: agent, title: shellTitle, hasPort: !ports.isEmpty) }

    var title: String { customTitle ?? Self.shortened(shellTitle) }

    /// The last component of a title that is nothing but a path; anything
    /// else is left alone — `pnpm dev` and `nvim src/main.swift` say what
    /// they say, and cutting them would lose it.
    static func shortened(_ title: String) -> String {
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
    func focus(_ pane: TerminalView) {
        guard pane !== terminal, splits.contains(pane) else { return }
        terminal = pane
        if let title = pane.title { shellTitle = title }
        if let directory = pane.workingDirectory { workingDirectory = directory }
    }

    /// A new layout. The focused pane stays focused while it is still in
    /// it, else the first pane is; a zoomed pane that left unzooms.
    func setSplits(_ splits: SplitTree<TerminalView>) {
        self.splits = splits
        if let zoomed, !splits.contains(zoomed) { self.zoomed = nil }
        if !splits.contains(terminal), let first = splits.leaves.first { focus(first) }
    }
}

/// Why a tab shows the checkout it shows.
enum CheckoutReason: Equatable {
    case shell
    case agent(Agent)
    case attached
}
