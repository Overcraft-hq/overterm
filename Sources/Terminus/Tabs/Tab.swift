import AppKit

/// One tab: a terminal and what the tab bar shows for it.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let terminal: TerminalView

    /// What the shell last set via OSC 0/2 (shell integration sets it to the
    /// running command or the cwd).
    @Published var shellTitle: String

    /// A name the user gave the tab; overrides the shell title while set.
    @Published var customTitle: String?

    @Published var color: TabColor?

    init(terminal: TerminalView) {
        self.terminal = terminal
        self.shellTitle = terminal.workingDirectory.map { ($0 as NSString).lastPathComponent } ?? "Terminal"
    }

    var title: String { customTitle ?? shellTitle }
}
