import AppKit

extension EditorBuffer {
    /// An Excalidraw drawing (`DrawingModel`): its canvas beside the text.
    package var drawing: DrawingModel? {
        get { drawingPart as? DrawingModel }
        set { drawingPart = newValue }
    }
}

extension EditorViewController {
    /// A note's reading view, made the first time one shows.
    package var noteReader: NoteReaderView? {
        get { noteReaderStorage as? NoteReaderView }
        set { noteReaderStorage = newValue }
    }

    /// The drawing's canvas on screen, if any.
    package var shownDrawing: DrawingView? {
        get { shownDrawingStorage as? DrawingView }
        set { shownDrawingStorage = newValue }
    }
}

/// The notes' part in the editor (`EditorNotes`): what the editor asks, said
/// by the extensions that did it when it was the editor's own.
@MainActor
package final class NotesEditor: EditorNotes {
    package nonisolated init() {}

    package func opensLater(_ url: URL, in editor: EditorViewController, then done: @escaping (Bool) -> Void) -> Bool {
        // Only iCloud's placeholder is here: fetched first, then opened.
        guard NoteFiles.isEvicted(url) else { return false }
        NoteFiles.whenDownloaded(url) { [weak editor] arrived in
            guard arrived, let editor else { return done(false) }
            editor.open(url, then: done)
        }
        return true
    }

    package func attach(_ buffer: EditorBuffer, in editor: EditorViewController) {
        editor.attachNote(buffer)
        editor.attachDrawing(buffer)
    }

    package func activated(_ buffer: EditorBuffer, in editor: EditorViewController) { editor.setLiveLayout(buffer.livePreview) }
    package func closing(_ buffer: EditorBuffer, in editor: EditorViewController) { editor.closeDrawing(buffer) }
    package func textChanged(_ buffer: EditorBuffer, in editor: EditorViewController) { editor.drawingTextChanged(buffer) }
    package func selectionChanged(in editor: EditorViewController) { editor.updateLivePreviewEditing() }

    package func themeChanged(dark: Bool, in editor: EditorViewController) {
        for buffer in editor.buffers { buffer.drawing?.view.setDark(dark) }
    }

    package func invalidateReader(in editor: EditorViewController) -> Bool {
        guard let reader = editor.noteReader else { return false }
        reader.invalidate()
        return true
    }

    package func hideReader(in editor: EditorViewController) { editor.noteReader?.isHidden = true }
    package func showDrawing(of buffer: EditorBuffer?, in editor: EditorViewController) { editor.showDrawing(buffer?.drawing) }
    package func showNote(_ buffer: EditorBuffer, in editor: EditorViewController) { editor.showNote(buffer) }

    package func styleLive(_ target: NSMutableAttributedString, at location: Int, in buffer: EditorBuffer, editor: EditorViewController) {
        editor.styleLive(target, at: location, in: buffer)
    }

    package func liveTypingAttributes(in editor: EditorViewController) -> [NSAttributedString.Key: Any] { editor.liveTypingAttributes }
    package func liveClick(at index: Int, in editor: EditorViewController) -> Bool { editor.liveClick(at: index) }
    package func paste(_ pasteboard: NSPasteboard, in editor: EditorViewController) -> Bool { editor.pasteIntoNote(from: pasteboard) }
    package func addTemplateItems(to menu: NSMenu, in editor: EditorViewController) { editor.addTemplateItems(to: menu) }
    package func updateCompletion(in editor: EditorViewController) -> Bool { editor.updateNoteCompletion() }

    package func acceptCompletion(_ candidate: CompletionState.Candidate, anchor: Int, in editor: EditorViewController) {
        editor.acceptNoteCompletion(candidate, anchor: anchor)
    }
}

/// The vault as ⌘F searches it.
package struct VaultSearch: SpotlightNotes {
    package let vault: NotesVault
    package let index: NotesIndex

    package init(vault: NotesVault, index: NotesIndex) {
        self.vault = vault
        self.index = index
    }

    package func names(matching query: String, limit: Int) -> [String] { index.notes(matching: query, limit: limit) }

    package func lines(_ query: String, limit: Int) async -> [ContentMatch] {
        let paths = index.notes(matching: "", limit: .max)
        let vault = vault
        return await Task.detached(priority: .userInitiated) { NotesSearch.lines(query, in: vault, paths: paths, limit: limit) }.value
    }
}

/// The notes' part in the shell under them, set once (`OvertermFeatures`).
package enum NotesFeature {
    package static func install() {
        EditorViewController.notesStorage = NotesEditor()
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0.hasPrefix("notes_") }, enabled: { $0.notesAgentAccess },
                unavailable: "The notes aren't available to agents — Settings ▸ Notes.",
                tools: { NotesMCP.tools },
                instructions: { settings in
                    "The user's notes (an Obsidian vault): notes_search finds notes by name, #tag or what they say, notes_read reads one with its links — for context the user keeps there. Read-only."
                        + (settings.notesAgentDrawings
                            ? " notes_draw makes a new Excalidraw drawing from boxes, arrows and text — a diagram the user asked for, opened beside the terminal."
                            : "")
                },
                call: { name, arguments, _ in try await NotesMCP.call(name, arguments, notes: NotesModel.shared) }))
    }
}
