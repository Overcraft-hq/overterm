import AppKit

/// What the completion list holds: the word being completed and the
/// candidates for it — the language server's, then the file's own words.
struct CompletionState {
    struct Candidate {
        let label: String
        let filterText: String
        let insertText: String
        let isSnippet: Bool
        let badge: String
        let badgeColor: NSColor
        let detail: String
        let edit: LSP.TextEdit?
        let additionalEdits: [LSP.TextEdit]
        let sortText: String
        let fromServer: Bool
    }

    /// Where the word being completed starts.
    var anchor: Int
    /// The caret when the server was asked: its edits are about that text.
    var requestedAt: Int
    /// The file asked about — an answer for another is dropped.
    weak var buffer: EditorBuffer?
    /// The server said the list isn't all: typing on asks again.
    var incomplete = false
    var candidates: [Candidate]
    /// Indices into `candidates`, as the list shows them.
    var shown: [Int] = []
    /// Answers for an older request are dropped.
    var generation: Int
}

extension EditorViewController: CodeTextViewHost {
    // MARK: Keys

    func codeTextView(_ view: CodeTextView, handleKey event: NSEvent, equivalent: Bool) -> Bool {
        if !equivalent, completionPopup.isVisible, handleCompletionKey(event) { return true }
        let combo = KeyCombo(pressed: event)
        // Before the menu only ⌘ keys: the rest come back through keyDown,
        // and answering them twice would run them twice.
        if equivalent, combo?.command != true { return false }
        // The editor's shortcuts before vim: they all carry a modifier or are
        // function keys, which vim's normal mode would swallow (⇧⎋ is the
        // keyboard's only way out of zoom).
        if let combo, let command = KeyCommands.all.first(where: { $0.editor && Keybindings.shared.key(for: $0) == combo }) {
            return perform(command.id)
        }
        if !equivalent, combo == KeyCombo(key: "escape"), hover != nil {
            hideTransientUI()
            return true
        }
        if !equivalent, let vim, let key = Self.vimKey(event), vim.handle(key) {
            updateVimChrome()
            return true
        }
        return false
    }

    /// Runs an editor command; false when it doesn't apply here (so the key
    /// does what it would have).
    @discardableResult
    func perform(_ id: String) -> Bool {
        guard let buffer = active, buffer.document.unavailable == nil || ["editor.closeFile", "editor.toggleZoom"].contains(id) else {
            return false
        }
        let text = textView.string as NSString
        let selections = textView.selectedRanges.map(\.rangeValue)
        switch id {
        case "editor.goToFile": goToFile()
        case "editor.goToLine": goToLine()
        case "editor.goToSymbol": goToSymbol()
        case "editor.goToDefinition": goToDefinition(at: textView.selectedRange().location)
        case "editor.findReferences": findReferences()
        case "editor.goBack": goBack()
        case "editor.goForward": goForward()
        case "editor.nextProblem": goToProblem(forward: true)
        case "editor.previousProblem": goToProblem(forward: false)
        case "editor.showHover": showHover(at: textView.selectedRange().location, fromKeyboard: true)
        case "editor.complete": triggerCompletion(manual: true)
        case "editor.format": formatDocument {}
        case "editor.toggleComment":
            guard let style = commentStyle(for: buffer) else { return true }
            apply(EditCommands.toggleLineComment(in: text, selections: selections, style: style))
        case "editor.moveLineUp": apply(EditCommands.moveLines(.up, in: text, selections: selections))
        case "editor.moveLineDown": apply(EditCommands.moveLines(.down, in: text, selections: selections))
        case "editor.duplicateLineUp": apply(EditCommands.duplicateLines(.up, in: text, selections: selections))
        case "editor.duplicateLineDown": apply(EditCommands.duplicateLines(.down, in: text, selections: selections))
        case "editor.deleteLine": apply(EditCommands.deleteLines(in: text, selections: selections))
        case "editor.insertLineBelow":
            apply(EditCommands.insertLineBelow(in: text, selections: selections, style: buffer.indentStyle, languageID: buffer.languageID))
        case "editor.insertLineAbove": apply(EditCommands.insertLineAbove(in: text, selections: selections))
        case "editor.selectNext":
            guard let next = EditCommands.selectNextOccurrence(in: text, selections: selections, wholeWord: occurrenceWholeWord) else { return true }
            select(next)
        case "editor.selectAll":
            guard let all = EditCommands.selectAllOccurrences(in: text, selections: selections, wholeWord: occurrenceWholeWord) else { return true }
            select(all)
        case "editor.joinLines": apply(EditCommands.joinLines(in: text, selections: selections))
        case "editor.indent": apply(EditCommands.indent(in: text, selections: selections, style: buffer.indentStyle))
        case "editor.outdent":
            apply(EditCommands.outdent(in: text, selections: selections, style: buffer.indentStyle, tabWidth: Settings.shared.editorTabSize))
        case "editor.toggleSoftWrap":
            buffer.wrapOverride = !(textView.textContainer?.widthTracksTextView ?? false)
            applyWrap()
        case "editor.toggleZoom": onToggleZoom?()
        case "editor.closeFile": closeBuffer(at: activeIndex)
        case "editor.nextFile": activate((activeIndex + 1) % buffers.count)
        case "editor.previousFile": activate((activeIndex - 1 + buffers.count) % buffers.count)
        default: return false
        }
        return true
    }

    private func select(_ occurrences: OccurrenceSelection) {
        textView.selectedRanges = occurrences.selections.map { NSValue(range: $0) }
        occurrenceWholeWord = occurrences.wholeWord
        if let last = occurrences.selections.last { textView.scrollRangeToVisible(last) }
    }

    private func commentStyle(for buffer: EditorBuffer) -> CommentStyle? {
        EditCommands.commentPrefix(forLanguageID: buffer.languageID)
            ?? buffer.language.flatMap { language in
                language.lineComment.map { .line($0) } ?? language.blockComment.map { .block(open: $0.open + " ", close: " " + $0.close) }
            }
    }

    /// An editing command's result, as one undoable change.
    func apply(_ edit: TextEdit?) {
        guard let edit else { return }
        textView.apply(edit.changes.map { (range: $0.range, text: $0.replacement) }, selecting: edit.selections)
    }

    // MARK: Typing

    func codeTextView(_ view: CodeTextView, willInsert text: String) -> Bool {
        guard let buffer = active else { return false }
        let selections = textView.selectedRanges.map(\.rangeValue)
        var handled = false
        if text.count == 1, let edit = EditCommands.typeCharacter(text, in: textView.string as NSString, selections: selections, languageID: buffer.languageID) {
            apply(edit)
            handled = true
        }
        // After the text view has typed it, when it types it.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.didType(text) } }
        return handled
    }

    func codeTextViewInsertNewline(_ view: CodeTextView) -> Bool {
        guard let buffer = active else { return false }
        apply(
            EditCommands.newline(
                in: textView.string as NSString, selections: textView.selectedRanges.map(\.rangeValue), style: buffer.indentStyle,
                languageID: buffer.languageID))
        return true
    }

    func codeTextView(_ view: CodeTextView, indent backwards: Bool) -> Bool {
        guard let buffer = active else { return false }
        let text = textView.string as NSString
        let selections = textView.selectedRanges.map(\.rangeValue)
        let multiline = selections.contains { text.substring(with: $0).contains("\n") }
        if backwards {
            apply(EditCommands.outdent(in: text, selections: selections, style: buffer.indentStyle, tabWidth: Settings.shared.editorTabSize))
        } else if multiline {
            apply(EditCommands.indent(in: text, selections: selections, style: buffer.indentStyle))
        } else {
            apply(EditCommands.insertTab(in: text, selections: selections, style: buffer.indentStyle, tabWidth: Settings.shared.editorTabSize))
        }
        return true
    }

    func codeTextViewDeleteBackward(_ view: CodeTextView) -> Bool {
        defer { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.refilterCompletion() } } }
        guard let edit = EditCommands.deleteBackward(in: textView.string as NSString, selections: textView.selectedRanges.map(\.rangeValue))
        else { return false }
        apply(edit)
        return true
    }

    func codeTextView(_ view: CodeTextView, commandClickAt index: Int) -> Bool {
        guard let buffer = active, server(for: buffer) != nil else { return false }
        textView.setSelectedRange(NSRange(location: index, length: 0))
        goToDefinition(at: index)
        return true
    }

    func codeTextView(_ view: CodeTextView, hoverAt index: Int?) {
        guard let index else { return }
        showHover(at: index, fromKeyboard: false)
    }

    func codeTextViewContextMenu(_ view: CodeTextView, for menu: NSMenu) -> NSMenu {
        let items: [(String, String)] = [
            ("Go to Definition", "editor.goToDefinition"), ("Find All References", "editor.findReferences"),
            ("Go to Symbol in File…", "editor.goToSymbol"), ("Format Document", "editor.format"),
            ("Toggle Line Comment", "editor.toggleComment"),
        ]
        var index = 0
        for (title, id) in items {
            let item = NSMenuItem(title: title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            if let command = KeyCommands.byID[id], let key = Keybindings.shared.key(for: command) {
                (item.keyEquivalent, item.keyEquivalentModifierMask) = key.menuKey
            }
            menu.insertItem(item, at: index)
            index += 1
        }
        menu.insertItem(.separator(), at: index)
        return menu
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(id)
    }

    // MARK: Completion

    private func didType(_ text: String) {
        guard let buffer = active, textView.selectedRanges.count == 1 else { return dismissCompletion() }
        if let state = completion {
            if text.unicodeScalars.allSatisfy({ Self.isWordUnit(unichar(min($0.value, 0xFFFF))) }) {
                // An incomplete list is the server's first answer, not its
                // last: ask again for the longer word (the list stays meanwhile).
                if state.incomplete, server(for: buffer) != nil { return triggerCompletion(manual: true) }
                return refilterCompletion()
            }
            dismissCompletion()
        }
        let triggers = server(for: buffer)?.capabilities?.completionTriggerCharacters ?? []
        if triggers.contains(text) {
            triggerCompletion(manual: false, character: text)
            return
        }
        guard Settings.shared.editorCompletions, text.count == 1,
            text.unicodeScalars.allSatisfy({ Self.isWordUnit(unichar(min($0.value, 0xFFFF))) })
        else { return }
        let caret = textView.selectedRange().location
        let word = wordStart(before: caret)
        // A letter or two in: a word, not every keystroke.
        if caret - word >= 2 { triggerCompletion(manual: false) }
    }

    private func wordStart(before caret: Int) -> Int {
        let text = textView.string as NSString
        var start = min(caret, text.length)
        while start > 0, Self.isWordUnit(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    func triggerCompletion(manual: Bool, character: String? = nil) {
        guard let buffer = active, textView.selectedRanges.count == 1, textView.selectedRange().length == 0 else { return }
        let caret = textView.selectedRange().location
        let anchor = wordStart(before: caret)
        // Never reused, not even after a dismissal: an answer to an older
        // request (another file's, maybe) must not land on this one.
        completionRequests += 1
        let generation = completionRequests
        let words = CompletionMatch.bufferWords(in: textView.string as NSString, near: caret).prefix(2000).map { word in
            CompletionState.Candidate(
                label: word, filterText: word, insertText: word, isSnippet: false, badge: "abc", badgeColor: theme.hint, detail: "",
                edit: nil, additionalEdits: [], sortText: word, fromServer: false)
        }
        // Asking again for the same word: the server's last list stays up
        // until its new one arrives, so the list doesn't flicker to words.
        let kept = completion.flatMap { $0.buffer === buffer && $0.anchor == anchor ? $0.candidates.filter(\.fromServer) : nil } ?? []
        completion = CompletionState(anchor: anchor, requestedAt: caret, buffer: buffer, candidates: kept + Array(words), generation: generation)
        refilterCompletion(manual: manual)
        guard let server = server(for: buffer), let url = buffer.url else { return }
        flushServerChange(buffer)
        let position = lspPosition(of: caret)
        Task { [weak self] in
            let list = try? await server.completion(url, at: position, trigger: character)
            guard let self, let list, self.completion?.generation == generation, self.completion?.buffer === buffer,
                buffer === self.active
            else { return }
            let items = list.items.prefix(1500).map { self.candidate(from: $0) }
            let words = self.completion?.candidates.filter { !$0.fromServer } ?? []
            self.completion?.candidates = items + words
            self.completion?.incomplete = list.isIncomplete
            self.refilterCompletion(manual: true)
        }
    }

    private func candidate(from item: LSP.CompletionItem) -> CompletionState.Candidate {
        let (badge, color) = Self.badge(forCompletionKind: item.kind, theme: theme)
        return CompletionState.Candidate(
            label: item.label, filterText: item.filterText ?? item.label, insertText: item.text, isSnippet: item.isSnippet,
            badge: badge, badgeColor: color, detail: item.detail ?? "", edit: item.textEdit, additionalEdits: item.additionalTextEdits,
            sortText: item.sortText ?? item.label, fromServer: true)
    }

    /// Re-ranks the list for the word as it now is; gone when the caret
    /// left the word or nothing matches.
    func refilterCompletion(manual: Bool = false) {
        guard var state = completion else { return }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard textView.selectedRanges.count == 1, caret >= state.anchor, caret <= text.length else { return dismissCompletion() }
        let query = text.substring(with: NSRange(location: state.anchor, length: caret - state.anchor))
        if query.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "$" }) { return dismissCompletion() }
        var ranked: [(index: Int, score: Int, matched: [Int])] = []
        for (i, candidate) in state.candidates.enumerated() {
            if query.isEmpty {
                // Right after a "." — the server's list as it ordered it.
                if candidate.fromServer { ranked.append((i, 0, [])) }
                continue
            }
            if !candidate.fromServer, candidate.label == query { continue }
            guard let match = CompletionMatch.score(candidate: candidate.filterText, query: query) else { continue }
            ranked.append((i, match.score + (candidate.fromServer ? 8 : 0), candidate.filterText == candidate.label ? match.matched : []))
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return state.candidates[$0.index].sortText < state.candidates[$1.index].sortText
        }
        ranked = Array(ranked.prefix(200))
        state.shown = ranked.map(\.index)
        completion = state
        guard !ranked.isEmpty, let window = view.window else { return completionPopup.hide() }
        if !manual, query.isEmpty { return completionPopup.hide() }
        let items = ranked.map { entry -> EditorListItem in
            let candidate = state.candidates[entry.index]
            return EditorListItem(
                title: candidate.label, detail: candidate.detail, badge: candidate.badge, badgeColor: candidate.badgeColor,
                matched: entry.matched)
        }
        let details = ranked.map { state.candidates[$0.index].detail }
        completionPopup.show(items, details: details, at: textView.screenRect(forCharacterAt: state.anchor), in: window)
    }

    func updateCompletionForSelection() {
        guard let state = completion else { return }
        let caret = textView.selectedRange().location
        if textView.selectedRanges.count != 1 || textView.selectedRange().length > 0 || caret < state.anchor { dismissCompletion() }
    }

    func dismissCompletion() {
        completion = nil
        completionPopup.hide()
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        let control = event.modifierFlags.contains(.control)
        switch event.keyCode {
        case 125: completionPopup.move(1)
        case 126: completionPopup.move(-1)
        case 36, 76, 48: acceptCompletion(at: completionPopup.selectedIndex)
        case 53: dismissCompletion()
        case 45 where control: completionPopup.move(1)  // ⌃N
        case 35 where control: completionPopup.move(-1)  // ⌃P
        default: return false
        }
        return true
    }

    func acceptCompletion(at index: Int) {
        guard let state = completion, state.shown.indices.contains(index), active != nil else { return dismissCompletion() }
        let candidate = state.candidates[state.shown[index]]
        dismissCompletion()
        let caret = textView.selectedRange().location
        var start = state.anchor
        var end = caret
        if let edit = candidate.edit {
            // The server's range is in the text it saw: what was typed since
            // (at the caret, inside the range) moves its end along.
            start = min(offset(of: edit.range.start), caret)
            end = max(caret, offset(of: edit.range.end) + (caret - state.requestedAt))
            end = min(end, (textView.string as NSString).length)
        }
        let (text, cursor) = candidate.isSnippet ? Self.expandSnippet(candidate.insertText) : (candidate.insertText, nil)
        var changes = [(range: NSRange(location: start, length: end - start), text: text)]
        var shift = 0
        for extra in candidate.additionalEdits {
            let range = range(of: extra.range)
            // Auto-imports land above the word; keep them off it.
            guard NSMaxRange(range) <= start || range.location >= end else { continue }
            changes.append((range: range, text: extra.newText))
            if NSMaxRange(range) <= start { shift += (extra.newText as NSString).length - range.length }
        }
        let caretAfter = start + shift + (cursor ?? (text as NSString).length)
        textView.apply(changes, selecting: [NSRange(location: caretAfter, length: 0)])
    }

    /// A snippet as plain text: placeholders keep their default, the
    /// caret goes to `$0` (else the first stop, else the end).
    static func expandSnippet(_ snippet: String) -> (String, Int?) {
        var out = ""
        var firstStop: Int?
        var finalStop: Int?
        var chars = Array(snippet)
        var i = 0
        func utf16Count() -> Int { (out as NSString).length }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1].isNumber {
                    var j = i + 1
                    var number = ""
                    while j < chars.count, chars[j].isNumber {
                        number.append(chars[j])
                        j += 1
                    }
                    if number == "0" { finalStop = utf16Count() } else if firstStop == nil { firstStop = utf16Count() }
                    i = j
                    continue
                }
                if chars[i + 1] == "{" {
                    var j = i + 2
                    var number = ""
                    while j < chars.count, chars[j].isNumber {
                        number.append(chars[j])
                        j += 1
                    }
                    if !number.isEmpty {
                        if number == "0" { finalStop = utf16Count() } else if firstStop == nil { firstStop = utf16Count() }
                        if j < chars.count, chars[j] == ":" {
                            // The default, up to the matching brace (nested ones kept as text).
                            var depth = 1
                            j += 1
                            var inner = ""
                            while j < chars.count {
                                if chars[j] == "{" { depth += 1 }
                                if chars[j] == "}" {
                                    depth -= 1
                                    if depth == 0 { break }
                                }
                                inner.append(chars[j])
                                j += 1
                            }
                            out += expandSnippet(inner).0
                        } else if j < chars.count, chars[j] == "|" {
                            // A choice: its first option.
                            var option = ""
                            j += 1
                            while j < chars.count, chars[j] != ",", chars[j] != "|" {
                                option.append(chars[j])
                                j += 1
                            }
                            out += option
                            while j < chars.count, chars[j] != "}" { j += 1 }
                        } else {
                            while j < chars.count, chars[j] != "}" { j += 1 }
                        }
                        i = j + 1
                        continue
                    }
                }
            }
            out.append(c)
            i += 1
        }
        chars = []
        return (out, finalStop ?? firstStop)
    }

    static func badge(forCompletionKind kind: Int?, theme: EditorTheme) -> (String, NSColor) {
        let keyword = theme.style(for: "keyword")?.color ?? theme.text
        let function = theme.style(for: "function")?.color ?? theme.text
        let type = theme.style(for: "type")?.color ?? theme.text
        let property = theme.style(for: "variable.other.member")?.color ?? theme.text
        let constant = theme.style(for: "constant")?.color ?? theme.text
        switch kind {
        case 2, 3, 4: return ("fn", function)
        case 5, 10: return ("fld", property)
        case 6: return ("var", theme.text)
        case 7, 22: return ("T", type)
        case 8: return ("I", type)
        case 9: return ("mod", type)
        case 13: return ("enum", type)
        case 14: return ("kw", keyword)
        case 15: return ("snip", theme.hint)
        case 20: return ("case", function)
        case 21: return ("K", constant)
        case 25: return ("T", type)
        default: return ("•", theme.hint)
        }
    }

    // MARK: Vim

    func startVim() {
        let engine = VimEngine(buffer: self)
        engine.onModeChange = { [weak self] _ in self?.updateVimChrome() }
        engine.onStatusChange = { [weak self] _ in self?.updateVimChrome() }
        engine.exCommand = { [weak self] command in self?.exCommand(command) }
        vim = engine
        engine.reset()
        updateVimChrome()
    }

    func stopVim() {
        vim = nil
        updateVimChrome()
    }

    func updateVimChrome() {
        guard isViewLoaded else { return }
        guard let vim else {
            textView.blockCursor = false
            statusBar.update(mode: "")
            return
        }
        textView.blockCursor = vim.mode != .insert && vim.mode != .replace && vim.mode != .commandLine
        statusBar.update(mode: vim.statusText.isEmpty ? "-- NORMAL --" : vim.statusText)
    }

    private func exCommand(_ command: String) -> String? {
        switch command.trimmingCharacters(in: .whitespaces) {
        case "w", "write":
            saveDocument(nil)
        case "q", "quit", "q!":
            closeBuffer(at: activeIndex)
        case "wq", "x", "xit":
            saveDocument(nil)
            closeBuffer(at: activeIndex)
        case "wa", "wall":
            for buffer in buffers where buffer.document.isDirty { save(buffer, overwriting: false) }
        case "qa", "qall":
            requestClose()
        case "noh", "nohlsearch":
            break
        default:
            return "Not an editor command: \(command)"
        }
        return nil
    }

    static func vimKey(_ event: NSEvent) -> VimKey? {
        var modifiers: VimKey.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let named: VimKey.Named?
        switch event.keyCode {
        case 53: named = .escape
        case 36, 76: named = .enter
        case 51: named = .backspace
        case 117: named = .delete
        case 48: named = .tab
        case 123: named = .left
        case 124: named = .right
        case 125: named = .down
        case 126: named = .up
        case 115: named = .home
        case 119: named = .end
        case 116: named = .pageUp
        case 121: named = .pageDown
        default: named = nil
        }
        if let named { return VimKey(named, modifiers: modifiers) }
        // Option applied (a Turkish Q types { with ⌥); with ⌃, the bare key.
        let characters = flags.contains(.control) ? event.charactersIgnoringModifiers : event.characters
        guard let characters, !characters.isEmpty else { return nil }
        return VimKey(characters, modifiers: modifiers)
    }
}

extension EditorViewController: VimBuffer {
    var text: NSString { textView.string as NSString }

    var selection: NSRange {
        get { textView.selectedRange() }
        set {
            settingSelection = true
            textView.setSelectedRange(newValue)
            textView.scrollRangeToVisible(newValue)
            settingSelection = false
        }
    }

    func replace(_ range: NSRange, with string: String) {
        textView.apply([(range: range, text: string)], selecting: nil)
    }

    /// Vim's transactions are not undo groups held open: the undo manager
    /// groups by event, and closes the top group when each key's event ends —
    /// vim's, from an insert, leaving its own open (and undo then raised).
    /// One key's command is one event, so one group already; an insert's
    /// typing coalesces into one step, cut at its start and end here.
    func beginUndoGroup() { textView.breakUndoCoalescing() }

    func endUndoGroup() { textView.breakUndoCoalescing() }

    func undo() { active?.undo.undo() }
    func redo() { active?.undo.redo() }

    var visibleCharacterRange: NSRange {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return NSRange(location: 0, length: 0) }
        return layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: textView.visibleRect, in: container), actualGlyphRange: nil)
    }

    func scroll(_ request: VimScroll) {
        let line = textView.lineRect(at: textView.selectedRange().location)
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        switch request {
        case .cursorToCenter: origin.y = line.midY - clip.bounds.height / 2
        case .cursorToTop: origin.y = line.minY
        case .cursorToBottom: origin.y = line.maxY - clip.bounds.height
        case .lines(let count): origin.y += CGFloat(count) * max(line.height, 1)
        }
        origin.y = max(-clip.contentInsets.top, origin.y)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func indentUnit() -> String { active?.indentUnit ?? "    " }

    var clipboard: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}
