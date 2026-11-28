import AppKit
import Combine

/// A note of the vault in the editor: its preview (⇧⌘V, the eye) is the
/// reading view, Obsidian's — links followed, tasks ticked in the text,
/// embeds and diagrams drawn.
extension EditorViewController {
    package var notes: NotesModel { NotesModel.shared }

    /// A Markdown file inside the vault is a note.
    package func attachNote(_ buffer: EditorBuffer) {
        guard Settings.shared.notesEnabled, let url = buffer.url, url.pathExtension.lowercased() == "md",
            buffer.document.unavailable == nil, notes.vault.contains(url)
        else { return }
        buffer.isNote = true
        buffer.livePreview = Settings.shared.notesLivePreview
        // Prose wraps.
        buffer.wrapOverride = true
    }

    /// Shows the reading view over the text, or the text, as the buffer asks.
    package func showNote(_ buffer: EditorBuffer) {
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
        reader.onOpenLink = { [weak self] target, anchor, markdown, _ in self?.followNoteLink(target, anchor: anchor, markdown: markdown, from: .reader) }
        reader.onOpenURL = { Self.openExternal($0) }
        reader.onToggleTask = { [weak self] line in self?.toggleNoteTask(line: line) }
        reader.onTag = { [weak self] tag in self?.onNoteTag?(tag) }
        reader.onRunBlock = { [weak self] line in self?.runNoteBlock(openingAt: line) }
        reader.noteUndo = { [weak self] in self?.active.flatMap { $0.isNote ? $0.undo : nil } }
        reader.onUndone = { [weak self] in
            guard let self, let buffer = self.active, buffer.showsPreview else { return }
            self.renderNote(buffer)
        }
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

    /// A link out of a note: the web, mail, Obsidian's own — the schemes a
    /// note has reason to name. Anything else (an app's private scheme in a
    /// note an agent or a shared vault planted) is not opened.
    package static func openExternal(_ url: URL) {
        guard ["http", "https", "mailto", "obsidian"].contains(url.scheme?.lowercased() ?? "") else { return NSSound.beep() }
        NSWorkspace.shared.open(url)
    }

    /// Draws the note — once the index can say what its links mean.
    package func renderNote(_ buffer: EditorBuffer, scrollTo anchor: String? = nil) {
        guard let url = buffer.url, let reader = noteReader else { return }
        reader.loadsRemoteImages = Settings.shared.notesRemoteImages
        let notes = self.notes
        notes.whenLoaded { [weak self, weak buffer] in
            guard let self, let buffer, buffer === self.active, buffer.showsPreview else { return }
            let path = notes.path(of: url)
            let open = Dictionary(
                self.buffers.compactMap { other in other.url.map { (notes.path(of: $0), other.storage.string) } },
                uniquingKeysWith: { first, _ in first })
            let payload = NoteRenderPayload.make(path: path, text: buffer.storage.string, index: notes.index) { embedded in
                // An open note's text as it is now, edits and all. One iCloud
                // still has is asked for and drawn with the next render.
                if let text = open[embedded] { return text }
                let url = notes.url(of: embedded)
                if NoteFiles.isEvicted(url) {
                    NoteFiles.whenDownloaded(url) { [weak self, weak buffer] arrived in
                        guard arrived, let self, let buffer else { return }
                        self.noteReader?.invalidate()
                        self.renderNote(buffer)
                    }
                    return nil
                }
                return try? NoteFiles.read(url)
            }
            reader.vaultRoot = notes.vault.root
            reader.show(payload, settings: notes.vault.settings, theme: self.theme, scrollTo: anchor)
        }
    }

    /// A link in a note: the note it names, opened at its heading or block
    /// — or, for a note not written yet, written (as Obsidian does on a
    /// click) where new notes go. It opens in the mode it was clicked in, as
    /// Obsidian's pane keeps its mode: from the reading view (or a drawing)
    /// it reads, from Live Preview it is written in.
    package func followNoteLink(_ target: String, anchor: String?, markdown: Bool, from origin: NoteLinkOrigin) {
        guard let current = active?.url else { return }
        // `[[#Heading]]` in Live Preview: a place in this note.
        if target.isEmpty, origin == .live {
            if let anchor { goToNoteAnchor(anchor) }
            return
        }
        // The index first: a link it hasn't read yet is not a note to write.
        notes.whenLoaded { [weak self] in self?.followLoadedNoteLink(target, anchor: anchor, markdown: markdown, from: current, origin: origin) }
    }

    /// The line of a heading or block in the text, the caret put there.
    private func goToNoteAnchor(_ anchor: String) {
        guard let line = NoteAnchor.line(of: anchor, in: textView.string) else { return }
        go(toLine: line + 1, column: 1)
    }

    private func followLoadedNoteLink(_ target: String, anchor: String?, markdown: Bool, from current: URL, origin: NoteLinkOrigin) {
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
            // Never over a note that is there: one the index missed is opened.
            if !FileManager.default.fileExists(atPath: url.path), !NoteFiles.isEvicted(url) {
                do {
                    try NoteFiles.create(url)
                } catch {
                    return
                }
                notes.reload()
            }
        }
        guard url.pathExtension.lowercased() == "md" else {
            // An image, a PDF: Finder's app for it.
            NSWorkspace.shared.open(url)
            return
        }
        if url.standardizedFileURL == current.standardizedFileURL {
            if let anchor {
                if origin == .live { goToNoteAnchor(anchor) } else { noteReader?.scrollTo(anchor: anchor) }
            }
            return
        }
        open(url) { [weak self] opened in
            guard opened, let self, let buffer = self.active else { return }
            // A drawing keeps its canvas, whatever the link was clicked in.
            guard buffer.isNote, buffer.drawing == nil else { return }
            // In the mode the link was clicked in: a note followed from the
            // reading view reads, one followed in Live Preview is written in.
            let reads = origin != .live
            if buffer.showsPreview != reads {
                buffer.showsPreview = reads
                self.updatePreview()
                if !reads { self.focus() }
            }
            if let anchor {
                if reads { self.renderNote(buffer, scrollTo: anchor) } else { self.goToNoteAnchor(anchor) }
            }
        }
    }

    /// A checkbox clicked in the reading view: the task's `[ ]` in the
    /// text ticked — an ordinary edit, saved and undone like one.
    package func toggleNoteTask(line: Int) {
        guard let buffer = active, buffer.isNote else { return }
        let text = buffer.storage.string
        guard let edit = NoteEdits.toggleTask(in: text, line: line) else { return }
        replaceText(of: buffer, with: (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        renderNote(buffer)
    }

    /// ▶ Run in terminal, on a shell block of the reading view: the block
    /// that opens on that line (the file's) handed to the window, which asks.
    package func runNoteBlock(openingAt line: Int) {
        guard let buffer = active, buffer.isNote, let command = NoteRunbook.command(in: buffer.storage.string, openingAt: line) else {
            return NSSound.beep()
        }
        onRunNoteBlock?(command)
    }

    /// Run Code Block in Terminal: the shell block the caret is in.
    package func runNoteBlockAtCaret() {
        guard let buffer = active, buffer.isNote else { return NSSound.beep() }
        let text = buffer.storage.string as NSString
        let caret = min(textView.selectedRange().location, text.length)
        var line = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: caret), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        // A caret at a line's start is on that line, not the one before.
        if caret > 0, caret <= text.length, text.character(at: caret - 1) != 0x0A { line -= 1 }
        guard let command = NoteRunbook.command(in: buffer.storage.string, around: max(0, line)) else { return NSSound.beep() }
        onRunNoteBlock?(command)
    }
}

/// Where a followed link was clicked: the target opens in that mode.
package enum NoteLinkOrigin: Equatable, Sendable {
    /// The reading view (⇧⌘V).
    case reader
    /// The text, in Live Preview.
    case live
    /// An element's link on an Excalidraw canvas.
    case drawing
}

// MARK: Completing links and tags

extension EditorViewController {
    /// `[[` lists the vault's notes, `[[Note#` its headings, `#` the tags —
    /// shown, or the list kept up to date. False when the caret is in none.
    package func updateNoteCompletion() -> Bool {
        guard let buffer = active, buffer.isNote, let url = buffer.url, textView.selectedRanges.count == 1,
            textView.selectedRange().length == 0, let window = view.window
        else { return false }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard let context = NoteCompletion.context(before: before) else { return false }
        // `/` in code or frontmatter is code's own.
        if case .slash = context {
            if NoteWriting.isInFence(text, at: lineStart) { return false }
            if let front = NoteParser.parse(textView.string).frontmatterRange, NSLocationInRange(caret, front) { return false }
        }
        let start: Int
        switch context {
        case .link(_, let at), .heading(_, _, let at), .tag(_, let at), .slash(_, let at): start = lineStart + at
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
        case .slash: badge = "/"
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
    package func acceptNoteCompletion(_ candidate: CompletionState.Candidate, anchor: Int) {
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard anchor <= caret else { return }
        var end = caret
        var insert = candidate.insertText
        // A `/` command: the slash and what was typed after it give way to
        // its text, the caret where it says (`$0`).
        if candidate.badge == "/", anchor > 0 {
            let (text, offset) = NoteSlashCommands.expand(insert)
            textView.apply(
                [(range: NSRange(location: anchor - 1, length: caret - anchor + 1), text: text)],
                selecting: [NSRange(location: anchor - 1 + offset, length: 0)])
            return
        }
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
    package func pasteIntoNote(from pasteboard: NSPasteboard) -> Bool {
        guard let buffer = active, let url = buffer.url else { return false }
        // A URL over a selection: `[selection](url)`, as Obsidian pastes it.
        if textView.selectedRanges.count == 1, let pasted = pasteboard.string(forType: .string),
            let edit = NoteWriting.linkPaste(pasted, over: textView.selectedRange(), in: textView.string as NSString)
        {
            apply(edit)
            return true
        }
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
    package func insertTemplate(_ template: URL) {
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
    package func addTemplateItems(to menu: NSMenu) {
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
    package func setLiveLayout(_ live: Bool) {
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

    /// What a character typed into a note in Live Preview starts as: the
    /// note's body text (the restyle then makes it a heading's, a link's).
    package var liveTypingAttributes: [NSAttributedString.Key: Any] {
        let style = liveStyle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: style.fonts.body, .foregroundColor: style.colors.text, .paragraphStyle: paragraph]
    }

    private var liveStyle: NoteLivePreview {
        // From Settings' font, never `textView.font` — the first character's,
        // a heading's in a note that opens with one: each restyle grew it
        // by a heading's scale again.
        let size = max(13, lineHeight.font.pointSize + 2)
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
        return NoteLivePreview(
            fonts: .init(body: body, mono: mono),
            colors: .init(
                text: theme.text, muted: theme.lineNumber, accent: theme.info, mark: theme.warning.withAlphaComponent(0.3),
                code: theme.style(for: "string")?.color ?? theme.text, heading: theme.text))
    }

    /// Styles the lines in `range` (attributes only — the text is the file's).
    package func applyLivePreview(over range: NSRange, in buffer: EditorBuffer) {
        let storage = buffer.storage
        let text = storage.string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        let lines = text.lineRange(for: range)
        let styled = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: lines))
        styleLive(styled, at: lines.location, in: buffer)
        storage.beginEditing()
        Self.write(styled, at: lines.location, into: storage)
        storage.endEditing()
    }

    /// Live Preview's attributes over `target` — the note's whole lines from
    /// `location` on, coloured as code.
    package func styleLive(_ target: NSMutableAttributedString, at location: Int, in buffer: EditorBuffer) {
        let text = buffer.storage.string as NSString
        let lines = NSRange(location: location, length: target.length)
        guard lines.length > 0, NSMaxRange(lines) <= text.length else { return }
        if buffer.liveBlocks?.version != buffer.version {
            buffer.liveBlocks = (buffer.version, NoteLivePreview.blocks(in: text))
        }
        let editing = buffer === active ? textView.selectedRanges.map(\.rangeValue) : buffer.selection
        buffer.liveEditing = editing.map { text.lineRange(for: $0) }
        let runs = liveStyle.runs(in: text, range: lines, editing: editing, blocks: buffer.liveBlocks?.blocks ?? [])
        let all = NSRange(location: 0, length: target.length)
        for key in [NSAttributedString.Key.noteHidden, .noteFolded, .noteDecoration, .noteLink, .noteURL, .backgroundColor, .strikethroughStyle, .cursor] {
            target.removeAttribute(key, range: all)
        }
        for (index, run) in runs.enumerated() {
            let clipped = NSIntersectionRange(NSRange(location: run.range.location - location, length: run.range.length), all)
            guard clipped.length > 0 else { continue }
            if index == 0 { target.setAttributes(run.attributes, range: clipped) } else { target.addAttributes(run.attributes, range: clipped) }
        }
        // Folded headings: their lines hidden, the heading underlined dotted to say so.
        for section in foldedSections(in: buffer) {
            let body = NSIntersectionRange(NSRange(location: section.body.location - location, length: section.body.length), all)
            if body.length > 0 { target.addAttribute(.noteFolded, value: true, range: body) }
            let heading = NSIntersectionRange(NSRange(location: section.heading.location - location, length: section.heading.length), all)
            if heading.length > 0 {
                target.addAttributes(
                    [.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: theme.lineNumber],
                    range: heading)
            }
        }
    }

    /// The note's sections folded now, read once a version.
    private func foldedSections(in buffer: EditorBuffer) -> [NoteFolding.Section] {
        guard !buffer.foldedHeadings.isEmpty else { return [] }
        if buffer.foldSections?.version != buffer.version {
            buffer.foldSections = (buffer.version, NoteFolding.sections(in: buffer.storage.string as NSString))
        }
        let sections = buffer.foldSections?.sections ?? []
        // A heading gone or renamed takes its fold with it.
        buffer.foldedHeadings.formIntersection(sections.map(\.key))
        return sections.filter { buffer.foldedHeadings.contains($0.key) }
    }

    /// Fold Heading: the heading the caret is on (or the nearest above it)
    /// folds, or unfolds when it was folded. Live Preview's: its lines hide.
    package func toggleHeadingFold() {
        guard let buffer = active, buffer.isNote else { return NSSound.beep() }
        if !buffer.livePreview { toggleLivePreview() }
        let text = buffer.storage.string as NSString
        let sections = NoteFolding.sections(in: text)
        guard let section = NoteFolding.section(at: textView.selectedRange().location, in: sections) else { return NSSound.beep() }
        if buffer.foldedHeadings.remove(section.key) == nil {
            buffer.foldedHeadings.insert(section.key)
            // The caret out of what hides: at the heading's end.
            var end = NSMaxRange(section.heading)
            while end > section.heading.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        buffer.foldSections = (buffer.version, sections)
        applyLivePreview(over: NSUnionRange(section.heading, section.body), in: buffer)
    }

    /// Unfold All Headings.
    package func unfoldAllHeadings() {
        guard let buffer = active, buffer.isNote, !buffer.foldedHeadings.isEmpty else { return }
        let folded = foldedSections(in: buffer)
        buffer.foldedHeadings = []
        for section in folded { applyLivePreview(over: NSUnionRange(section.heading, section.body), in: buffer) }
    }

    /// A caret stepping into folded lines from just beside them — ↓ off the
    /// heading, ↑ from below — goes past them, as Obsidian's does; one
    /// jumping in (a search, a link) is left there, and the fold opens.
    package func caretPastFolds(from old: NSRange, to new: NSRange) -> NSRange {
        guard let buffer = active, buffer.isNote, buffer.livePreview, new.length == 0, !buffer.foldedHeadings.isEmpty else { return new }
        let text = buffer.storage.string as NSString
        for section in foldedSections(in: buffer) where NSLocationInRange(new.location, section.body) {
            if NSLocationInRange(old.location, section.heading) || old.location == section.body.location {
                // Down: to the line after the fold — the end, at the note's end.
                return NSRange(location: min(NSMaxRange(section.body), text.length), length: 0)
            }
            let after = NSMaxRange(section.body)
            if old.location >= after, old.location <= after + text.lineRange(for: NSRange(location: min(after, max(0, text.length - 1)), length: 0)).length {
                // Up: to the heading's end.
                var end = NSMaxRange(section.heading)
                while end > section.heading.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
                return NSRange(location: end, length: 0)
            }
        }
        return new
    }

    /// A caret moved into folded lines (a search, a link, arrows): they open.
    private func unfoldAroundCaret(in buffer: EditorBuffer) {
        guard !buffer.foldedHeadings.isEmpty else { return }
        let carets = textView.selectedRanges.map(\.rangeValue)
        // At the body's end too: a section running to the end of the note
        // ends where typing there goes.
        for section in foldedSections(in: buffer)
        where carets.contains(where: { NSLocationInRange($0.location, section.body) || $0.location == NSMaxRange(section.body) }) {
            buffer.foldedHeadings.remove(section.key)
            applyLivePreview(over: NSUnionRange(section.heading, section.body), in: buffer)
        }
    }


    /// The caret moved to other lines: those it left hide their markup,
    /// the ones it is on show theirs.
    package func updateLivePreviewEditing() {
        guard let buffer = active, buffer.livePreview, !textView.hasMarkedText() else { return }
        unfoldAroundCaret(in: buffer)
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
    package func toggleLivePreview() {
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
    package func liveClick(at index: Int) -> Bool {
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
            followNoteLink(target, anchor: anchor, markdown: markdown, from: .live)
            return true
        }
        if let link = storage.attribute(.noteURL, at: index, effectiveRange: nil) as? String, let url = URL(string: link) {
            Self.openExternal(url)
            return true
        }
        return false
    }
}
