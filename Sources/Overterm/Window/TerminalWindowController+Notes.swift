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
        // A #tag clicked in a note: the Notes panel, on that tag's notes.
        editor?.onNoteTag = { [weak self] tag in
            guard let self else { return }
            self.showNotes(nil)
            self.notes.tagFilter = tag
            self.notes.detail = .tags
        }
        let changed = editor?.onActiveChanged
        editor?.onActiveChanged = { [weak self] url in
            changed?(url)
            self?.editorShows(url)
        }
        spotlight.notes = { [weak self] in
            guard let self, Settings.shared.notesEnabled else { return nil }
            // ⌘F asks for the index: read now if no panel has yet, and the
            // query run again when it is.
            if !self.notes.isLoaded {
                self.notes.whenLoaded { [weak self] in self?.spotlight.refresh() }
                return nil
            }
            self.notes.whenLoaded {}
            return (self.notes.vault, self.notes.index)
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

    func openNote(_ url: URL, line: Int? = nil) {
        notes.expandFolders(of: url)
        openInEditor(url, line: line.map { $0 + 1 })
    }

    /// Every open tab on a note, in every window: the vault is the app's, so
    /// an edit to a note is made where it is open, whichever window that is.
    func openNoteBuffers(_ url: URL) -> [(EditorViewController, EditorBuffer)] {
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        return NSApp.windows.compactMap { $0.windowController as? TerminalWindowController }.flatMap { controller in
            (controller.editor?.buffers ?? []).compactMap { buffer in
                buffer.url?.standardizedFileURL.resolvingSymlinksInPath() == key ? controller.editor.map { ($0, buffer) } : nil
            }
        }
    }

    /// A task ticked from the Tasks pane: in the note's buffer when it is
    /// open (an edit like any), else in the file. The line is the index's,
    /// which may be older than the text: the task is found by its words.
    func toggleNoteTask(_ url: URL, line: Int, text task: String? = nil) {
        if let (editor, buffer) = openNoteBuffers(url).first {
            let text = buffer.storage.string
            guard let edit = NoteEdits.toggleTask(in: text, line: line, text: task) else { return NSSound.beep() }
            editor.replaceText(of: buffer, with: (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
            if buffer === editor.active, buffer.showsPreview { editor.renderNote(buffer) }
            return
        }
        do {
            let text = try NoteFiles.read(url)
            guard let edit = NoteEdits.toggleTask(in: text, line: line, text: task) else { return NSSound.beep() }
            try NoteFiles.write((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), to: url)
            notes.reload()
        } catch {
            reportNotesError(error)
        }
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
        // Agents' notes tools come and go with the setting.
        BrowserBridge.shared.update()
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
            newTab: { [weak self] in self?.newTab(in: $0) },
            chooseVault: { [weak self] in self?.chooseNotesVault() },
            openAt: { [weak self] url, line in self?.openNote(url, line: line) },
            toggleTask: { [weak self] url, line, text in self?.toggleNoteTask(url, line: line, text: text) }
        )
    }

    /// The notes' graph in the right-hand pane (which takes the slot, as
    /// every pane there does).
    @objc func showNotesGraph(_ sender: Any?) {
        guard Settings.shared.notesEnabled else { return }
        rightPane.graphOpened = true
        rightPane.mode = .graph
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    // MARK: Agents and branches

    /// ⌘L for a note: the editor's selection in it, or all of it, to an agent.
    func askAgentAboutNote() {
        guard let editor, let buffer = editor.active, buffer.isNote, let url = buffer.url else { return }
        let selection = editor.textView.selectedRange()
        let text =
            selection.length > 0 ? (buffer.storage.string as NSString).substring(with: selection) : buffer.storage.string
        let header = "From my note “\(notes.path(of: url))”:\n\n"
        let selected = store.selected
        let agents = store.tabs.filter { $0.agent != nil }
        let ordered = agents.filter { $0.id == selected?.id } + agents.filter { $0.id != selected?.id }
        presentAskAgent(text: header + text, command: nil, folder: selected?.workingDirectory, targets: ordered)
    }

    /// The note for the selected tab's branch, made the first time.
    func openBranchNote() {
        guard Settings.shared.notesEnabled, let root = store.selected?.checkoutSource?.root else { return NSSound.beep() }
        Task { [weak self] in
            let branch = (try? await Git.run(["rev-parse", "--abbrev-ref", "HEAD"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let top = (try? await Git.run(["rev-parse", "--show-toplevel"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, let branch, !branch.isEmpty, branch != "HEAD" else { return NSSound.beep() }
            // The main checkout's name, not a worktree's folder.
            let common = (try? await Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let repo = common.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? root.lastPathComponent
            let url = self.notes.vault.root.appendingPathComponent(BranchNote.path(repo: repo, branch: branch))
            do {
                if !FileManager.default.fileExists(atPath: url.path), !NoteFiles.isEvicted(url) {
                    try NoteFiles.write(
                        BranchNote.text(repo: repo, branch: branch, checkout: top ?? root.path, date: Date()), to: url)
                    self.notes.reload()
                }
                self.openNote(url)
            } catch {
                self.reportNotesError(error)
            }
        }
    }

    // MARK: From the terminal

    /// Terminal text at the end of today's note — in its buffer when the
    /// note is open in any window (an edit like any), else in the file,
    /// fetched from iCloud first if it must be. The note isn't opened: the
    /// terminal keeps the keyboard.
    func appendToTodaysNote(_ text: String, command: String?, folder: String?) {
        guard Settings.shared.notesEnabled else { return }
        let url: URL
        do {
            url = try notes.dailyNote()
        } catch {
            return reportNotesError(error)
        }
        let entry = NoteAppend.entry(text, command: command, folder: folder, date: Date(), settings: notes.vault.settings)
        if let (editor, buffer) = openNoteBuffers(url).first {
            editor.replaceText(of: buffer, with: NoteAppend.append(entry, to: buffer.storage.string))
            return
        }
        NoteFiles.whenDownloaded(url) { [weak self] arrived in
            guard let self else { return }
            do {
                guard arrived else { throw NoteFiles.Problem.notDownloaded(url.deletingPathExtension().lastPathComponent) }
                try NoteFiles.write(NoteAppend.append(entry, to: try NoteFiles.read(url)), to: url)
                self.notes.reload()
            } catch {
                self.reportNotesError(error)
            }
        }
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
    /// link the move would break (NoteRename). The notes to rewrite are
    /// read, fetched from iCloud if they must be, and written off the main
    /// thread; a note open with unsaved edits — in any window — gets the
    /// change in its buffer, still unsaved, and tabs everywhere follow.
    func moveNote(_ url: URL, to target: URL) {
        let notes = self.notes
        notes.whenLoaded { [weak self] in
            guard let self else { return }
            let index = notes.index
            let root = notes.vault.root
            let settings = notes.vault.settings
            let old = notes.path(of: url)
            let new = notes.path(of: target)
            let moves = NoteRename.moves(of: old, to: new, files: index.resolver.files)
            var buffers: [String: (EditorViewController, EditorBuffer)] = [:]
            for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                for buffer in controller.editor?.buffers ?? [] where buffer.document.isDirty {
                    if let open = buffer.url, notes.vault.contains(open), let editor = controller.editor { buffers[notes.path(of: open)] = (editor, buffer) }
                }
            }
            let unsaved = buffers.mapValues { $0.1.storage.string }
            Task { [weak self] in
                let outcome = await Task.detached(priority: .userInitiated) {
                    Self.move(url, to: target, root: root, index: index, moves: moves, settings: settings, unsaved: unsaved)
                }.value
                guard let self else { return }
                if let error = outcome.moveError { return self.reportNotesError(error) }
                for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                    controller.editor?.filesMoved(from: url, to: target)
                }
                for (path, text) in outcome.rewrites {
                    if let (editor, buffer) = buffers[path] { editor.replaceText(of: buffer, with: text) }
                }
                for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                    controller.editor?.reloadIfChangedOnDisk()
                }
                if notes.current?.standardizedFileURL == url.standardizedFileURL { notes.current = target }
                notes.expandFolders(of: target)
                notes.reload()
                self.tree.reload()
                if let error = outcome.writeErrors.first { self.reportNotesError(error) }
            }
        }
    }

    private struct MoveOutcome: @unchecked Sendable {
        var rewrites: [String: String] = [:]
        var moveError: Error?
        var writeErrors: [Error] = []
    }

    /// The move and the files' rewrites — off the main thread: reading a
    /// note iCloud hasn't downloaded waits for it.
    private nonisolated static func move(
        _ url: URL, to target: URL, root: URL, index: NotesIndex, moves: [String: String], settings: ObsidianSettings,
        unsaved: [String: String]
    ) -> MoveOutcome {
        var outcome = MoveOutcome()
        outcome.rewrites = NoteRename.rewrites(index: index, moves: moves, settings: settings, unsaved: unsaved) { path in
            try? NoteFiles.read(root.appendingPathComponent(path))
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NoteFiles.move(url, to: target)
        } catch {
            outcome.moveError = error
            outcome.rewrites = [:]
            return outcome
        }
        for (path, text) in outcome.rewrites where unsaved[path] == nil {
            do {
                try NoteFiles.write(text, to: root.appendingPathComponent(moves[path] ?? path))
            } catch {
                outcome.writeErrors.append(error)
            }
        }
        return outcome
    }

    func reportNotesError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
