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
            renameNote(url)
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
            rename: { [weak self] in self?.renameNote($0) },
            trash: { [weak self] in self?.trashItem($0) },
            insertPath: { [weak self] in self?.insertPath($0) },
            chooseVault: { [weak self] in self?.chooseNotesVault() }
        )
    }

    // MARK: Renaming, links and all

    /// Asks for a new name — a note's without `.md` — and renames it, the
    /// links to it written again (`moveNote`).
    func renameNote(_ url: URL) {
        let isNote = url.pathExtension.lowercased() == "md"
        let shown = isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        askForName(title: "Rename", detail: shown, initial: shown, action: "Rename") { [weak self] name in
            guard let self, name != shown else { return nil }
            let file = isNote && !name.lowercased().hasSuffix(".md") ? name + ".md" : name
            let target = url.deletingLastPathComponent().appendingPathComponent(file)
            // A change of case only is the same file to a case-insensitive disk.
            if file.lowercased() != url.lastPathComponent.lowercased(), let problem = Self.nameProblem(file, at: target) { return problem }
            guard self.notes.vault.contains(target) else { return "The name can't leave the vault." }
            self.moveNote(url, to: target)
            return nil
        }
    }

    /// Moves a note, file or folder of the vault, and writes again every
    /// link the move would break (NoteRename). A note open with unsaved
    /// edits gets the change in its buffer, still unsaved; the others are
    /// written, coordinated, and the editor's tabs follow.
    func moveNote(_ url: URL, to target: URL) {
        let notes = self.notes
        notes.whenLoaded { [weak self] in
            guard let self else { return }
            let index = notes.index
            let old = notes.path(of: url)
            let new = notes.path(of: target)
            let moves = NoteRename.moves(of: old, to: new, files: index.resolver.files)
            var unsaved: [String: EditorBuffer] = [:]
            for buffer in self.editor?.buffers ?? [] where buffer.document.isDirty {
                if let open = buffer.url, notes.vault.contains(open) { unsaved[notes.path(of: open)] = buffer }
            }
            let rewrites = NoteRename.rewrites(index: index, moves: moves, settings: notes.vault.settings) { path in
                unsaved[path]?.storage.string ?? (try? NoteFiles.read(notes.url(of: path)))
            }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try NoteFiles.move(url, to: target)
            } catch {
                self.reportNotesError(error)
                return
            }
            self.editor?.filesMoved(from: url, to: target)
            var failed: [Error] = []
            for (path, text) in rewrites {
                if let buffer = unsaved[path] {
                    self.editor?.replaceText(of: buffer, with: text)
                    continue
                }
                do {
                    try NoteFiles.write(text, to: notes.url(of: moves[path] ?? path))
                } catch {
                    failed.append(error)
                }
            }
            self.editor?.reloadIfChangedOnDisk()
            if notes.current?.standardizedFileURL == url.standardizedFileURL { notes.current = target }
            notes.expandFolders(of: target)
            notes.reload()
            self.tree.reload()
            if let error = failed.first { self.reportNotesError(error) }
        }
    }

    func reportNotesError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
