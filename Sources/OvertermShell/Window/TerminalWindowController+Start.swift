import AppKit

/// Ways into the window that need no shell knowledge (onboarding 7.4).
extension TerminalWindowController {
    /// File ▸ Open Folder… and its ⌘K row: a folder picked in Finder's
    /// panel, a tab opened there (`open(_:)`) — into a repository without
    /// `cd`. Overterm never runs `git init` in it.
    @objc package func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "A tab opens in the folder you pick."
        if let cwd = store.selected?.workingDirectory { panel.directoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.open([url]) }
        }
    }
}
