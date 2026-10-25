import AppKit
import Combine

/// Notes: the sidebar's panel over the vault (NotesModel, the app's one),
/// its notes opened in the editor.
extension TerminalWindowController {
    var notes: NotesModel { NotesModel.shared }

    func wireNotes() {
        sidebarPanel.$panel
            // @Published fires before the value lands.
            .sink { [weak self] panel in
                DispatchQueue.main.async { self?.updateNotesVisibility(panel: panel) }
            }
            .store(in: &cancellables)
        let changed = editor?.onActiveChanged
        editor?.onActiveChanged = { [weak self] url in
            changed?(url)
            self?.editorShows(url)
        }
        updateNotesVisibility()
    }

    /// The panel reads the vault only while some window shows it (CLAUDE.md).
    func updateNotesVisibility(panel: SidebarPanel? = nil) {
        let shown = sidebarItem?.isCollapsed == false && window?.isVisible != false
        notes.setVisible(shown && (panel ?? sidebarPanel.panel) == .notes && Settings.shared.notesEnabled, for: self)
    }

    /// The note in the editor, highlighted in the tree — said only when it
    /// changes: the editor reports on every edit.
    private func editorShows(_ url: URL?) {
        let note = url.flatMap { notes.vault.contains($0) ? $0 : nil }
        guard notes.current?.standardizedFileURL != note?.standardizedFileURL else { return }
        notes.current = note
    }

    /// View ▸ Notes: the sidebar, on the notes.
    @objc func showNotes(_ sender: Any?) {
        guard Settings.shared.notesEnabled else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .notes
        updateNotesVisibility(panel: .notes)
    }

    /// Today's note in the editor — made from the daily template the first time.
    @objc func openDailyNote(_ sender: Any?) {
        guard Settings.shared.notesEnabled else { return }
        do {
            openNote(try notes.dailyNote())
        } catch {
            reportNotesError(error)
        }
    }

    @objc func newNote(_ sender: Any?) {
        newNote(in: nil)
    }

    func newNote(in folder: URL?) {
        guard Settings.shared.notesEnabled else { return }
        do {
            openNote(try notes.newNote(in: folder, beside: notes.current))
        } catch {
            reportNotesError(error)
        }
    }

    func newNotesFolder(in folder: URL?) {
        do {
            let url = try notes.newFolder(in: folder)
            renameItem(url)
        } catch {
            reportNotesError(error)
        }
    }

    func openNote(_ url: URL) {
        notes.expandFolders(of: url)
        openInEditor(url)
    }

    /// Another folder as the vault, picked in Finder's panel.
    func chooseNotesVault() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open as Vault"
        panel.message = "A folder of Markdown notes — an Obsidian vault, or a folder in iCloud Drive."
        panel.directoryURL = notes.vault.root.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.notes.switchVault(to: url)
        }
    }

    func notesSettingsChanged() {
        if !Settings.shared.notesEnabled, sidebarPanel.panel == .notes { sidebarPanel.panel = .files }
        // The rail lists its icons from the setting: drawn again.
        sidebarPanel.objectWillChange.send()
        notes.settingsChanged()
        updateNotesVisibility()
    }

    var notesActions: NotesActions {
        NotesActions(
            open: { [weak self] in self?.openNote($0) },
            newNote: { [weak self] in self?.newNote(in: $0) },
            newFolder: { [weak self] in self?.newNotesFolder(in: $0) },
            dailyNote: { [weak self] in self?.openDailyNote(nil) },
            rename: { [weak self] in self?.renameItem($0) },
            trash: { [weak self] in self?.trashItem($0) },
            insertPath: { [weak self] in self?.insertPath($0) },
            chooseVault: { [weak self] in self?.chooseNotesVault() }
        )
    }

    func reportNotesError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
