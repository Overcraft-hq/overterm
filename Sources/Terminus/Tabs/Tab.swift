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

    /// A name the user gave the tab; overrides the shell title while set.
    @Published var customTitle: String?

    @Published var color: TabColor?
    /// Pinned tabs sit at the left of the strip and are not closed by ⌘W or
    /// the close-others/right actions — only by their process exiting.
    /// Set through TabStore.setPinned, which keeps pinned tabs first.
    @Published var isPinned = false

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
