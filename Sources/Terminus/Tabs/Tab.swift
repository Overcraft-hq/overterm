import AppKit

/// One tab: a terminal and what the tab bar shows for it.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let terminal: TerminalView

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

    /// The agent this tab was opened for, if any.
    let agent: Agent?

    init(terminal: TerminalView, agent: Agent? = nil) {
        self.terminal = terminal
        self.agent = agent
        self.workingDirectory = terminal.workingDirectory
        self.shellTitle = terminal.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
    }

    var title: String { customTitle ?? shellTitle }
}

/// Why a tab shows the checkout it shows.
enum CheckoutReason: Equatable {
    case shell
    case agent(Agent)
    case attached
}
