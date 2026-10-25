import AppKit
import Combine

/// A note of the vault in the editor: its preview (⇧⌘V, the eye) is the
/// reading view, Obsidian's — links followed, tasks ticked in the text,
/// embeds and diagrams drawn.
extension EditorViewController {
    var notes: NotesModel { NotesModel.shared }

    /// A Markdown file inside the vault is a note.
    func attachNote(_ buffer: EditorBuffer) {
        guard Settings.shared.notesEnabled, let url = buffer.url, url.pathExtension.lowercased() == "md",
            buffer.document.unavailable == nil, notes.vault.contains(url)
        else { return }
        buffer.isNote = true
    }

    /// Shows the reading view over the text, or the text, as the buffer asks.
    func showNote(_ buffer: EditorBuffer) {
        guard buffer.showsPreview else {
            noteReader?.isHidden = true
            scrollView.isHidden = false
            return
        }
        let reader = makeNoteReader()
        reader.isHidden = false
        scrollView.isHidden = true
        renderNote(buffer)
    }

    private func makeNoteReader() -> NoteReaderView {
        if let noteReader { return noteReader }
        let reader = NoteReaderView()
        reader.translatesAutoresizingMaskIntoConstraints = false
        scrollView.superview?.addSubview(reader, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            reader.topAnchor.constraint(equalTo: scrollView.topAnchor),
            reader.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            reader.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            reader.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        reader.onOpenLink = { [weak self] target, anchor, markdown, _ in self?.followNoteLink(target, anchor: anchor, markdown: markdown) }
        reader.onOpenURL = { NSWorkspace.shared.open($0) }
        reader.onToggleTask = { [weak self] line in self?.toggleNoteTask(line: line) }
        reader.onTag = { [weak self] tag in self?.onNoteTag?(tag) }
        // A note written or renamed elsewhere: links in this one may
        // resolve now.
        noteObserver = notes.$index
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let buffer = self.active, buffer.isNote, buffer.showsPreview else { return }
                self.renderNote(buffer)
            }
        noteReader = reader
        return reader
    }

    /// Draws the note — once the index can say what its links mean.
    func renderNote(_ buffer: EditorBuffer, scrollTo anchor: String? = nil) {
        guard let url = buffer.url, let reader = noteReader else { return }
        let notes = self.notes
        notes.whenLoaded { [weak self, weak buffer] in
            guard let self, let buffer, buffer === self.active, buffer.showsPreview else { return }
            let path = notes.path(of: url)
            let open = Dictionary(
                self.buffers.compactMap { other in other.url.map { (notes.path(of: $0), other.storage.string) } },
                uniquingKeysWith: { first, _ in first })
            let payload = NoteRenderPayload.make(path: path, text: buffer.storage.string, index: notes.index) { embedded in
                // An open note's text as it is now, edits and all.
                open[embedded] ?? (try? NoteFiles.read(notes.url(of: embedded)))
            }
            reader.vaultRoot = notes.vault.root
            reader.show(payload, settings: notes.vault.settings, theme: self.theme, scrollTo: anchor)
        }
    }

    /// A link in the reading view: the note it names, opened at its
    /// heading or block — or, for a note not written yet, written (as
    /// Obsidian does on a click) where new notes go.
    func followNoteLink(_ target: String, anchor: String?, markdown: Bool) {
        guard let current = active?.url else { return }
        let notes = self.notes
        let source = notes.path(of: current)
        var resolved: String?
        if markdown {
            let folder = (source as NSString).deletingLastPathComponent
            if let path = LinkResolver.standardized(folder.isEmpty ? target : folder + "/" + target) {
                resolved = notes.index.resolver.resolve(path, from: "") ?? notes.index.resolver.resolve(target, from: source)
            }
        } else {
            resolved = notes.index.resolver.resolve(target, from: source)
        }
        var url: URL
        if let resolved {
            url = notes.url(of: resolved)
        } else {
            guard !target.isEmpty else { return }
            let name = target.hasSuffix(".md") ? target : target + ".md"
            url =
                name.contains("/")
                ? notes.vault.root.appendingPathComponent(name) : notes.vault.folderForNewNote(beside: current).appendingPathComponent(name)
            guard notes.vault.contains(url) else { return }
            do {
                try NoteFiles.write("", to: url)
            } catch {
                return
            }
            notes.reload()
        }
        guard url.pathExtension.lowercased() == "md" else {
            // An image, a PDF: Finder's app for it.
            NSWorkspace.shared.open(url)
            return
        }
        if url.standardizedFileURL == current.standardizedFileURL {
            if let anchor { noteReader?.scrollTo(anchor: anchor) }
            return
        }
        open(url) { [weak self] opened in
            guard opened, let self, let buffer = self.active else { return }
            // Read as the link was: a note followed from the reading view reads.
            if buffer.isNote, !buffer.showsPreview {
                buffer.showsPreview = true
                self.updatePreview()
            }
            if let anchor { self.renderNote(buffer, scrollTo: anchor) }
        }
    }

    /// A checkbox clicked in the reading view: the task's `[ ]` in the
    /// text ticked — an ordinary edit, saved and undone like one.
    func toggleNoteTask(line: Int) {
        guard let buffer = active, buffer.isNote else { return }
        let text = buffer.storage.string
        guard let edit = NoteEdits.toggleTask(in: text, line: line) else { return }
        replaceText(of: buffer, with: (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        renderNote(buffer)
    }
}

// MARK: Completing links and tags

extension EditorViewController {
    /// `[[` lists the vault's notes, `[[Note#` its headings, `#` the tags —
    /// shown, or the list kept up to date. False when the caret is in none.
    func updateNoteCompletion() -> Bool {
        guard let buffer = active, buffer.isNote, let url = buffer.url, textView.selectedRanges.count == 1,
            textView.selectedRange().length == 0, let window = view.window
        else { return false }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard let context = NoteCompletion.context(before: before) else { return false }
        let start: Int
        switch context {
        case .link(_, let at), .heading(_, _, let at), .tag(_, let at): start = lineStart + at
        }
        let found = NoteCompletion.candidates(context, index: notes.index, source: notes.path(of: url), settings: notes.vault.settings)
        guard !found.isEmpty else {
            completionPopup.hide()
            completion = nil
            return true
        }
        let badge: String
        switch context {
        case .link: badge = "[["
        case .heading: badge = "#"
        case .tag: badge = "tag"
        }
        let candidates = found.map {
            CompletionState.Candidate(
                label: $0.label, filterText: $0.label, insertText: $0.insert, isSnippet: false, badge: badge, badgeColor: theme.info,
                detail: $0.detail, edit: nil, additionalEdits: [], sortText: $0.label, fromServer: false)
        }
        completionRequests += 1
        var state = CompletionState(anchor: start, requestedAt: caret, buffer: buffer, candidates: candidates, generation: completionRequests)
        state.isNote = true
        state.shown = Array(candidates.indices)
        completion = state
        let items = candidates.map {
            EditorListItem(title: $0.label, detail: $0.detail, badge: $0.badge, badgeColor: $0.badgeColor, matched: [])
        }
        completionPopup.show(items, details: candidates.map(\.detail), at: textView.screenRect(forCharacterAt: start), in: window)
        return true
    }

    /// The name (or heading, or tag) in place of what was typed — a link
    /// closed with `]]`, past the pair the editor already typed if it did.
    func acceptNoteCompletion(_ candidate: CompletionState.Candidate, anchor: Int) {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard anchor <= caret else { return }
        var end = caret
        var insert = candidate.insertText
        if candidate.badge == "[[" || candidate.badge == "#" {
            if caret + 2 <= text.length, text.substring(with: NSRange(location: caret, length: 2)) == "]]" { end += 2 }
            insert += "]]"
        }
        textView.apply(
            [(range: NSRange(location: anchor, length: end - anchor), text: insert)],
            selecting: [NSRange(location: anchor + (insert as NSString).length, length: 0)])
    }
}
