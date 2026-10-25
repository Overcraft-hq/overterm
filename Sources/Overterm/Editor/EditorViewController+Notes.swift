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
        buffer.livePreview = Settings.shared.notesLivePreview
        // Prose wraps.
        buffer.wrapOverride = true
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

// MARK: Pasting images

extension EditorViewController {
    /// An image on the pasteboard — a screenshot, or image files copied in
    /// Finder — saved where the vault keeps attachments and embedded at the
    /// caret. False for anything else, which pastes as text.
    func pasteIntoNote(from pasteboard: NSPasteboard) -> Bool {
        guard let buffer = active, let url = buffer.url else { return false }
        let notes = self.notes
        let folder = notes.vault.folderForAttachment(of: url)
        var saved: [URL] = []
        let images = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { NoteItem.Kind($0) == .image || NoteItem.Kind($0) == .pdf }
        do {
            if !images.isEmpty {
                for file in images {
                    let name = file.deletingPathExtension().lastPathComponent
                    let target = NotesVault.freeName(name, extension: file.pathExtension, in: folder)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: target)
                    saved.append(target)
                }
            } else if let data = pasteboard.data(forType: .png)
                ?? pasteboard.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
            {
                let name = (NoteAttachments.pastedName(at: Date()) as NSString).deletingPathExtension
                let target = NotesVault.freeName(name, extension: "png", in: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: target)
                saved.append(target)
            } else {
                return false
            }
        } catch {
            NSSound.beep()
            return true
        }
        // The index learns the files now, so the embeds name them shortest.
        var files = notes.index.resolver.files
        files += saved.map { notes.path(of: $0) }
        let resolver = LinkResolver(files: files)
        let source = notes.path(of: url)
        let embeds = saved.map { NoteAttachments.embed(notes.path(of: $0), from: source, resolver: resolver, settings: notes.vault.settings) }
        textView.insertText(embeds.joined(separator: "\n"), replacementRange: textView.selectedRange())
        notes.reload()
        return true
    }
}

// MARK: Templates

extension EditorViewController {
    /// Obsidian's Insert template: the template's text at the caret, its
    /// `{{title}}`, `{{date}}` and `{{time}}` filled for this note.
    func insertTemplate(_ template: URL) {
        guard let buffer = active, buffer.isNote, let url = buffer.url, let body = try? NoteFiles.read(template) else { return }
        let text = NoteTemplate.apply(
            body, title: url.deletingPathExtension().lastPathComponent, date: Date(), settings: notes.vault.settings)
        if buffer.showsPreview {
            buffer.showsPreview = false
            updatePreview()
        }
        textView.insertText(text, replacementRange: textView.selectedRange())
        focus()
    }

    /// The templates, in a note's right-click menu.
    func addTemplateItems(to menu: NSMenu) {
        guard active?.isNote == true else { return }
        let templates = notes.vault.templates
        guard !templates.isEmpty else { return }
        let submenu = NSMenu()
        for template in templates {
            let item = NSMenuItem(title: template.deletingPathExtension().lastPathComponent, action: #selector(insertTemplateItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Insert Template", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func insertTemplateItem(_ sender: NSMenuItem) {
        if let template = sender.representedObject as? URL { insertTemplate(template) }
    }
}

// MARK: Live Preview

extension EditorViewController {
    /// The layout as Live Preview needs it — lines as tall as their fonts,
    /// markup laid out as nothing — or the code editor's.
    func setLiveLayout(_ live: Bool) {
        // No line numbers in Live Preview, as Obsidian: lines of every
        // height, a heading's and a wrapped paragraph's, numbered as code.
        if scrollView.rulersVisible == live { scrollView.rulersVisible = !live }
        guard lineHeight.variable != live, let layout = textView.layoutManager else { return }
        lineHeight.variable = live
        let all = NSRange(location: 0, length: layout.textStorage?.length ?? 0)
        layout.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        textView.needsDisplay = true
    }

    private var liveStyle: NoteLivePreview {
        let size = max(13, (textView.font?.pointSize ?? 13) + 2)
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
        return NoteLivePreview(
            fonts: .init(body: body, mono: mono),
            colors: .init(
                text: theme.text, muted: theme.lineNumber, accent: theme.info, mark: theme.warning.withAlphaComponent(0.3),
                code: theme.style(for: "string")?.color ?? theme.text, heading: theme.text))
    }

    /// Styles the lines in `range` (attributes only — the text is the file's).
    func applyLivePreview(over range: NSRange, in buffer: EditorBuffer) {
        let storage = buffer.storage
        let text = storage.string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        let lines = text.lineRange(for: range)
        if buffer.liveBlocks?.version != buffer.version {
            buffer.liveBlocks = (buffer.version, NoteLivePreview.blocks(in: text))
        }
        let editing = buffer === active ? textView.selectedRanges.map(\.rangeValue) : buffer.selection
        buffer.liveEditing = editing.map { text.lineRange(for: $0) }
        let runs = liveStyle.runs(in: text, range: lines, editing: editing, blocks: buffer.liveBlocks?.blocks ?? [])
        storage.beginEditing()
        for key in [NSAttributedString.Key.noteHidden, .noteDecoration, .noteLink, .noteURL, .backgroundColor, .strikethroughStyle, .cursor] {
            storage.removeAttribute(key, range: lines)
        }
        for (index, run) in runs.enumerated() {
            let clipped = NSIntersectionRange(run.range, NSRange(location: 0, length: storage.length))
            guard clipped.length > 0 else { continue }
            if index == 0 { storage.setAttributes(run.attributes, range: clipped) } else { storage.addAttributes(run.attributes, range: clipped) }
        }
        storage.endEditing()
    }

    /// The caret moved to other lines: those it left hide their markup,
    /// the ones it is on show theirs.
    func updateLivePreviewEditing() {
        guard let buffer = active, buffer.livePreview, !textView.hasMarkedText() else { return }
        let text = buffer.storage.string as NSString
        let now = textView.selectedRanges.map { text.lineRange(for: $0.rangeValue) }
        guard now != buffer.liveEditing else { return }
        let touched = (buffer.liveEditing + now).filter { NSMaxRange($0) <= text.length }
        guard let first = touched.map(\.location).min(), let last = touched.map(NSMaxRange).max() else { return }
        // A selection across many lines restyles them all; a caret, two.
        applyLivePreview(over: NSRange(location: first, length: max(0, last - first)), in: buffer)
        buffer.liveEditing = now
    }

    /// ⌘E in Obsidian: Live Preview or the Markdown as written, for this note.
    func toggleLivePreview() {
        guard let buffer = active, buffer.isNote else { return }
        buffer.livePreview.toggle()
        buffer.painted = IndexSet()
        let all = NSRange(location: 0, length: buffer.storage.length)
        buffer.storage.beginEditing()
        buffer.storage.setAttributes(baseAttributes, range: all)
        buffer.storage.endEditing()
        setLiveLayout(buffer.livePreview)
        paintVisible()
    }

    /// A click in Live Preview: a box ticks its task, a link opens — on
    /// lines not being edited (there the click places the caret, as typed).
    func liveClick(at index: Int) -> Bool {
        guard let buffer = active, buffer.livePreview, index < buffer.storage.length else { return false }
        let storage = buffer.storage
        let text = storage.string as NSString
        let line = text.lineRange(for: NSRange(location: index, length: 0))
        if buffer.liveEditing.contains(where: { NSIntersectionRange($0, line).length > 0 }) { return false }
        if case .checkbox = storage.attribute(.noteDecoration, at: index, effectiveRange: nil) as? NoteDecoration {
            let number = text.substring(to: line.location).components(separatedBy: "\n").count - 1
            toggleNoteTask(line: number)
            return true
        }
        if var target = storage.attribute(.noteLink, at: index, effectiveRange: nil) as? String {
            let markdown = target.hasPrefix("md:")
            if markdown { target.removeFirst(3) }
            var anchor: String?
            if let hash = target.firstIndex(of: "#") {
                anchor = String(target[target.index(after: hash)...])
                target = String(target[..<hash])
            }
            followNoteLink(target, anchor: anchor, markdown: markdown)
            return true
        }
        if let link = storage.attribute(.noteURL, at: index, effectiveRange: nil) as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }
}
