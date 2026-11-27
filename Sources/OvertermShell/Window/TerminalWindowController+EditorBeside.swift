import AppKit
import Combine

/// The editor beside an agent (issue #31, patch 3): a file the agent
/// rewrites reloads while the window stays key (EDIT-G3), the tree says
/// what git says and follows the file showing (EDIT-G6, EDIT-U2), Go to
/// File (EDIT-G1) and ⌘L from the editor (EDIT-N1).
extension TerminalWindowController {
    package func wireEditorBeside() {
        guard let editor else { return }
        // The changes pane's watcher on the checkout — no second one: what
        // it saw change is reloaded if open and unedited, else the bar asks.
        diff.changes
            .sink { [weak self] _ in
                guard let self, let root = self.diff.root else { return }
                self.editor?.reloadIfChangedOnDisk(under: root)
            }
            .store(in: &cancellables)
        // The tree's marks from the changes already read. @Published emits
        // before the value lands: the emitted ones are used.
        diff.$files
            .combineLatest(diff.$root)
            .sink { [weak self] files, root in self?.tree.setChanges(files, root: root) }
            .store(in: &cancellables)
        // The tree follows the file showing — only while it is on screen.
        let changed = editor.onActiveChanged
        editor.onActiveChanged = { [weak self] url in
            changed?(url)
            self?.editorFileShown(url)
        }
        editor.onRevealInFiles = { [weak self] url in self?.revealInFiles(url) }
    }

    /// The Files panel is the one showing.
    package var filesPanelShowing: Bool {
        sidebarItem?.isCollapsed == false && sidebarPanel.panel == .files && store.showingOverlay == nil
    }

    private func editorFileShown(_ url: URL?) {
        guard url != lastRevealedInTree else { return }
        lastRevealedInTree = url
        guard let url, filesPanelShowing else { return }
        tree.reveal(url)
    }

    /// The editor header's Reveal in Files: the sidebar on Files, the
    /// file's folders open and its row picked.
    package func revealInFiles(_ url: URL) {
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        if sidebarPanel.panel != .files { sidebarPanel.panel = .files }
        if !tree.reveal(url) { NSSound.beep() }
    }

    /// Go to File from ⌘K: the editor's column opened for its picker.
    package func goToFile() {
        guard let editor, let editorItem else { return }
        if editorItem.isCollapsed { editorItem.isCollapsed = false }
        editor.goToFile()
    }

    /// ⌘L over the editor's selection: the Ask Agent sheet with the file's
    /// path and lines, to the checkout's agents first.
    package func askAboutEditor(_ asked: EditorAsk) {
        let agents = asked.folder.map { checkoutAgents(in: $0) } ?? []
        let targets = agents.isEmpty ? store.tabs.filter { $0.agent != nil && !terraformAsking($0) } : agents
        presentAskAgent(text: asked.text, command: nil, folder: asked.folder?.path, targets: targets, subject: asked.subject)
    }
}
