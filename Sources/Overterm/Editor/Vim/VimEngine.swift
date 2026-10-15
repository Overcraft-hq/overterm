import Foundation

/// Vim's modal editing over a `VimBuffer`: the core of Zed's vim mode. Pure
/// logic — the text view sends it every key (`handle`) and draws the cursor
/// from `mode`; the engine edits through the buffer.
///
/// In insert mode it only takes Esc (and ⌃[ ⌃c): typing is the text view's,
/// which the engine watches to repeat it with `.`.
@MainActor
final class VimEngine {
    unowned let buffer: VimBuffer

    /// Set by the engine only (internal for its extensions).
    var mode: VimMode = .normal {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    var onModeChange: ((VimMode) -> Void)?
    /// `statusText` whenever it changes.
    var onStatusChange: ((String) -> Void)?
    /// An ex command the engine doesn't run itself (`w`, `q`, `wq`, `x`, …),
    /// as typed after the `:`. Returns an error to show, or nil.
    var exCommand: ((String) -> String?)?

    /// What is being typed after `:` `/` `?`, the prefix included.
    var commandLine: String?
    /// The last error (`Pattern not found: foo`), until the next key.
    var message: String?
    /// Keys typed toward a command not yet complete (`2d`, `"a`).
    var pendingKeys: String { pending.joined() }
    /// True while the engine itself sets `buffer.selection`: the adapter's
    /// selection-change notice should not call `selectionDidChange` then.
    private(set) var isSettingSelection = false

    var isVisual: Bool { mode == .visual || mode == .visualLine }

    /// The cursor's offset: the block cursor's character in normal and
    /// visual modes.
    var cursor: Int {
        isVisual ? visualCursor : buffer.selection.location
    }

    var statusText: String {
        if let commandLine { return commandLine }
        if let message { return message }
        var parts: [String] = []
        switch mode {
        case .insert: parts.append("-- INSERT --")
        case .visual: parts.append("-- VISUAL --")
        case .visualLine: parts.append("-- VISUAL LINE --")
        case .replace: parts.append("-- REPLACE --")
        case .normal, .commandLine: break
        }
        if !pending.isEmpty { parts.append(pending.joined()) }
        return parts.joined(separator: " ")
    }

    // MARK: State

    var pending: [String] = []
    /// The column j/k aim for; `Int.max` after `$`.
    var desiredColumn: Int?
    var visualAnchor = 0
    var visualCursor = 0
    var lastVisual: (anchor: Int, cursor: Int, linewise: Bool)?
    var lastFind: (char: String, forward: Bool, till: Bool)?
    var lastSearch: (pattern: String, forward: Bool, caseSensitive: Bool?)?
    var regexCache: (key: String, regex: NSRegularExpression)?
    var registers: [Character: (text: String, linewise: Bool)] = [:]
    /// The last thing put on the clipboard, to know a line yank when it comes back.
    var lastYank: (text: String, linewise: Bool)?
    var marks: [Character: Int] = [:]
    var lastJump: Int?
    var lastChange: Change?
    /// The change that entered insert mode, completed with the typing at Esc.
    var pendingChange: Change?
    var isReplaying = false
    var openGroups = 0
    var commandLineReturn: VimMode = .normal
    var commandLineCount: Int?
    private var lastStatus = ""

    // Insert mode: what was typed, two ways. The text between where insert
    // began and the caret catches autoindent; the keys are the fallback
    // once the caret moved or deleted past the start.
    var insertStart = 0
    var insertLength = 0
    var insertKeys = ""
    var insertDeletedBefore = 0
    var insertMoved = false
    var insertCount = 1
    var insertRepeatPrefix = ""
    var insertAutoIndent = false
    // Replace mode: what each typed character overwrote, for backspace.
    var replaceStack: [(position: Int, original: String, length: Int)] = []
    var replaceTyped = ""

    struct Change {
        var command: VimCommand
        var extent: VisualExtent?
        var inserted = ""
        var deletedBefore = 0
    }

    /// A visual selection's size, for `.` to select the same from the cursor.
    struct VisualExtent {
        var linewise: Bool
        var lines: Int
        var columns: Int
    }

    init(buffer: VimBuffer) {
        self.buffer = buffer
    }

    var text: VimText { VimText(buffer.text) }

    /// Back to normal mode with the cursor on a character — after a load,
    /// or when vim mode is switched on.
    func reset() {
        while openGroups > 0 { endGroup() }
        pending = []
        commandLine = nil
        message = nil
        mode = .normal
        setCursor(text.clampNormal(buffer.selection.location))
        publish()
    }

    /// The selection changed outside the engine (a click, a drag): a drag
    /// in normal mode is a visual selection, a click in visual ends it.
    func selectionDidChange() {
        guard !isSettingSelection else { return }
        let sel = buffer.selection
        let t = text
        switch mode {
        case .normal, .visual, .visualLine:
            pending = []
            if sel.length > 0 {
                visualAnchor = sel.location
                visualCursor = t.prev(NSMaxRange(sel))
                if mode == .normal { mode = .visual }
            } else {
                mode = .normal
                let c = t.clampNormal(sel.location)
                if c != sel.location { setCursor(c) }
            }
            desiredColumn = nil
            publish()
        default: break
        }
    }

    /// Paste into the command line (⌘V while `:` or `/` is open).
    func appendToCommandLine(_ string: String) {
        guard commandLine != nil else { return }
        commandLine! += string.replacingOccurrences(of: "\n", with: " ")
        publish()
    }

    // MARK: Keys

    /// Whether the engine took the key; false leaves it to the text view.
    @discardableResult
    func handle(_ key: VimKey) -> Bool {
        if key.modifiers.contains(.command) { return false }
        switch mode {
        case .insert:
            return handleInsert(key)
        case .replace:
            handleReplace(key)
        case .commandLine:
            handleCommandLine(key)
        case .normal, .visual, .visualLine:
            message = nil
            for token in key.tokens where isVisual || mode == .normal {
                feed(token)
            }
        }
        publish()
        return true
    }

    func feed(_ token: String) {
        if (token == "<esc>" || token == "<c-c>") && !pending.isEmpty {
            pending = []
            return
        }
        pending.append(token)
        switch VimParser.parse(pending, visual: isVisual) {
        case .incomplete: break
        case .invalid: pending = []
        case .complete(let command):
            pending = []
            run(command)
        }
    }

    func publish() {
        let s = statusText
        if s != lastStatus {
            lastStatus = s
            onStatusChange?(s)
        }
    }

    // MARK: Running commands

    func run(_ command: VimCommand) {
        if case .action(.repeatLast) = command.kind {
            repeatLast(count: command.count)
            return
        }
        let change = command.isChange
        let extent = isVisual ? visualExtent() : nil
        if change { beginGroup() }
        let ok = execute(command)
        if change {
            if ok && !isReplaying {
                let c = Change(command: command, extent: extent)
                if mode == .insert || mode == .replace { pendingChange = c } else { lastChange = c }
            }
            if mode != .insert && mode != .replace { endGroup() }
        }
    }

    @discardableResult
    func execute(_ command: VimCommand) -> Bool {
        switch command.kind {
        case .move(let m): return move(m, count: command.count)
        case .operate(let op, let target): return operate(op, target, command)
        case .select(let object): return selectObject(object, count: command.count)
        case .action(let a): return perform(a, command)
        }
    }

    func perform(_ action: VimAction, _ command: VimCommand) -> Bool {
        let n = max(1, command.count ?? 1)
        switch action {
        case .insert(let kind): return insert(kind, count: n)
        case .put(let before): return isVisual ? visualPut(before: before, command) : put(before: before, command)
        case .join(let spaces): return join(spaces: spaces, count: command.count)
        case .toggleCaseChar: return toggleCaseChars(n)
        case .replaceChar(let c): return isVisual ? visualReplace(with: c) : replaceChars(with: c, count: n)
        case .replaceMode:
            enterReplace()
            return true
        case .undo:
            for _ in 0..<n { buffer.undo() }
            afterUndo()
            return true
        case .redo:
            for _ in 0..<n { buffer.redo() }
            afterUndo()
            return true
        case .repeatLast:
            repeatLast(count: command.count)
            return true
        case .visual(let linewise):
            let target: VimMode = linewise ? .visualLine : .visual
            if mode == target {
                exitVisual()
            } else if isVisual {
                mode = target
                updateVisualSelection()
            } else {
                let p = text.clampNormal(buffer.selection.location)
                visualAnchor = p
                visualCursor = p
                mode = target
                updateVisualSelection()
            }
            return true
        case .reselect:
            guard let last = lastVisual else { return false }
            let t = text
            visualAnchor = t.clampVisual(last.anchor)
            visualCursor = t.clampVisual(last.cursor)
            mode = last.linewise ? .visualLine : .visual
            updateVisualSelection()
            return true
        case .swapEnds:
            swap(&visualAnchor, &visualCursor)
            updateVisualSelection()
            return true
        case .scroll(let request, let firstNonBlank):
            if firstNonBlank {
                let t = text
                place(t.firstNonBlank(cursor), t)
            }
            buffer.scroll(request)
            return true
        case .scrollLines(let delta):
            scrollLines(delta * n)
            return true
        case .setMark(let c):
            marks[c] = cursor
            return true
        case .commandLine(let c):
            commandLineCount = command.count
            if c == ":" && isVisual {
                exitVisual()
                commandLine = ":'<,'>"
                commandLineReturn = .normal
            } else {
                commandLine = String(c)
                commandLineReturn = mode
            }
            mode = .commandLine
            return true
        case .cancel:
            if isVisual { exitVisual() }
            return true
        }
    }

    func afterUndo() {
        if isVisual { exitVisual() }
        let t = text
        setCursor(t.clampNormal(buffer.selection.location))
        desiredColumn = nil
    }

    // MARK: Dot

    func repeatLast(count: Int?) {
        guard var change = lastChange else { return }
        if let count { change.command.count = count }
        isReplaying = true
        defer { isReplaying = false }
        beginGroup()
        if let extent = change.extent {
            select(extent)
        } else if isVisual {
            exitVisual()
        }
        execute(change.command)
        if mode == .insert {
            var at = buffer.selection.location
            if change.deletedBefore > 0 {
                let t = text
                var from = at
                for _ in 0..<change.deletedBefore where from > 0 { from = t.prev(from) }
                buffer.replace(NSRange(location: from, length: at - from), with: "")
                at = from
            }
            buffer.replace(NSRange(location: at, length: 0), with: change.inserted)
            setSelection(NSRange(location: at + change.inserted.utf16.count, length: 0))
            exitInsert()
        } else if mode == .replace {
            for ch in change.inserted { typeOver(String(ch)) }
            exitReplace()
        }
        endGroup()
    }

    func visualExtent() -> VisualExtent {
        let t = text
        let a = min(visualAnchor, visualCursor)
        let b = max(visualAnchor, visualCursor)
        var lines = 0
        var ls = t.lineStart(a)
        let last = t.lineStart(b)
        while ls < last {
            ls = t.lineEnd(ls) + 1
            lines += 1
        }
        if mode == .visualLine { return VisualExtent(linewise: true, lines: lines, columns: 0) }
        if lines == 0 {
            var cols = 0
            var i = a
            while i < b {
                i = t.next(i)
                cols += 1
            }
            return VisualExtent(linewise: false, lines: 0, columns: cols)
        }
        return VisualExtent(linewise: false, lines: lines, columns: t.column(b))
    }

    func select(_ extent: VisualExtent) {
        let t = text
        let p = isVisual ? min(visualAnchor, visualCursor) : t.clampNormal(buffer.selection.location)
        visualAnchor = p
        if extent.linewise {
            visualCursor = t.lineDown(p, extent.lines).start
            mode = .visualLine
        } else if extent.lines == 0 {
            var i = p
            for _ in 0..<extent.columns where i < t.length - 1 { i = t.next(i) }
            visualCursor = t.clampVisual(i)
            mode = .visual
        } else {
            let ls = t.lineDown(p, extent.lines).start
            visualCursor = t.clampVisual(t.position(column: extent.columns, lineStart: ls))
            mode = .visual
        }
        updateVisualSelection()
    }

    // MARK: Undo groups

    func beginGroup() {
        buffer.beginUndoGroup()
        openGroups += 1
    }

    func endGroup() {
        guard openGroups > 0 else { return }
        openGroups -= 1
        buffer.endUndoGroup()
    }

    // MARK: Cursor and selection

    func setSelection(_ range: NSRange) {
        isSettingSelection = true
        buffer.selection = range
        isSettingSelection = false
    }

    func setCursor(_ p: Int) {
        setSelection(NSRange(location: p, length: 0))
    }

    /// Where the cursor goes after a move or an edit: visual mode moves its
    /// end of the selection.
    func place(_ p: Int, _ t: VimText, allowLineEnd: Bool = false) {
        if isVisual {
            visualCursor = allowLineEnd ? t.clampVisual(p) : t.clampNormal(p)
            updateVisualSelection()
        } else {
            setCursor(t.clampNormal(p))
        }
    }

    func updateVisualSelection() {
        let t = text
        let a = min(visualAnchor, visualCursor)
        let b = max(visualAnchor, visualCursor)
        if mode == .visualLine {
            let le = t.lineEnd(b)
            let start = t.lineStart(a)
            setSelection(NSRange(location: start, length: min(t.length, le + 1) - start))
        } else {
            setSelection(NSRange(location: a, length: min(t.length, t.next(b)) - a))
        }
    }

    func exitVisual() {
        lastVisual = (visualAnchor, visualCursor, mode == .visualLine)
        mode = .normal
        let t = text
        setCursor(t.clampNormal(visualCursor))
    }

    func selectObject(_ object: VimTextObject, count: Int?) -> Bool {
        let t = text
        let current = buffer.selection
        guard var range = textObject(object, at: visualCursor, count: count, op: nil, t) else { return false }
        if case .chars(let r) = range, r == current, case .pair = object,
            let outer = textObject(object, at: visualCursor, count: (count ?? 1) + 1, op: nil, t)
        {
            range = outer
        }
        switch range {
        case .lines(let first, let last):
            if mode == .visualLine && visualAnchor != visualCursor {
                visualCursor = visualCursor >= visualAnchor ? t.lineEnd(last) : t.lineStart(first)
            } else {
                visualAnchor = t.lineStart(first)
                visualCursor = t.lineStart(last)
            }
            mode = .visualLine
        case .chars(let r):
            guard r.length > 0 else { return false }
            let end = t.prev(NSMaxRange(r))
            if visualAnchor == visualCursor || mode == .visualLine {
                visualAnchor = r.location
                visualCursor = end
            } else if visualCursor >= visualAnchor {
                visualAnchor = min(visualAnchor, r.location)
                visualCursor = max(visualCursor, end)
            } else {
                visualCursor = min(visualCursor, r.location)
            }
            mode = .visual
        }
        updateVisualSelection()
        return true
    }

    // MARK: Registers

    /// Yanks and deletes go to the clipboard unless a register is named;
    /// `_` swallows them.
    func store(_ string: String, linewise: Bool, register: Character?) {
        switch register {
        case "_":
            return
        case .some(let c) where c.isASCII && c.isLowercase:
            registers[c] = (string, linewise)
        case .some(let c) where c.isASCII && c.isUppercase:
            let key = Character(c.lowercased())
            if let old = registers[key] {
                let joined = old.linewise && !old.text.hasSuffix("\n") ? old.text + "\n" + string : old.text + string
                registers[key] = (joined, old.linewise || linewise)
            } else {
                registers[key] = (string, linewise)
            }
        default:
            buffer.clipboard = string
            lastYank = (string, linewise)
        }
    }

    func read(register: Character?) -> (text: String, linewise: Bool)? {
        switch register {
        case "_":
            return nil
        case .some(let c) where c.isASCII && c.isLetter:
            return registers[Character(c.lowercased())]
        default:
            guard let s = buffer.clipboard else { return nil }
            if let last = lastYank, last.text == s { return last }
            return (s, false)
        }
    }

    // MARK: Insert mode

    func insert(_ kind: VimInsert, count: Int) -> Bool {
        let t = text
        let p = t.clampNormal(buffer.selection.location)
        insertRepeatPrefix = ""
        switch kind {
        case .before:
            enterInsert(at: p, count: count)
        case .after:
            enterInsert(at: t.lineIsEmpty(p) ? p : t.next(p), count: count)
        case .lineStart:
            enterInsert(at: t.lineStart(p), count: count)
        case .lineFirstNonBlank:
            enterInsert(at: t.firstNonBlank(p), count: count)
        case .lineEnd:
            enterInsert(at: t.lineEnd(p), count: count)
        case .lineBelow:
            let le = t.lineEnd(p)
            var indent = t.indentation(p)
            // What Zed's autoindent does after an opening bracket.
            var i = le
            while i > t.lineStart(p) && t.isBlank(i - 1) { i -= 1 }
            if i > t.lineStart(p), [123, 91, 40].contains(t[i - 1]) { indent += buffer.indentUnit() }
            buffer.replace(NSRange(location: le, length: 0), with: "\n" + indent)
            enterInsert(at: le + 1 + indent.utf16.count, count: count)
            insertRepeatPrefix = "\n" + indent
            insertAutoIndent = !indent.isEmpty
        case .lineAbove:
            let ls = t.lineStart(p)
            let indent = t.indentation(p)
            buffer.replace(NSRange(location: ls, length: 0), with: indent + "\n")
            enterInsert(at: ls + indent.utf16.count, count: count)
            insertRepeatPrefix = "\n" + indent
            insertAutoIndent = !indent.isEmpty
        }
        return true
    }

    func enterInsert(at p: Int, count: Int = 1) {
        setCursor(p)
        insertStart = p
        insertLength = buffer.text.length
        insertKeys = ""
        insertDeletedBefore = 0
        insertMoved = false
        insertCount = count
        insertAutoIndent = false
        desiredColumn = nil
        mode = .insert
    }

    func handleInsert(_ key: VimKey) -> Bool {
        let tokens = key.tokens
        if tokens == ["<esc>"] || tokens == ["<c-c>"] {
            exitInsert()
            publish()
            return true
        }
        if key.modifiers.contains(.control) || key.modifiers.contains(.option) && key.named != nil {
            insertMoved = true
            insertKeys = ""
            return false
        }
        switch key.named {
        case .backspace:
            if insertKeys.isEmpty { insertDeletedBefore += 1 } else { insertKeys.removeLast() }
        case .enter: insertKeys += "\n"
        case .tab: insertKeys += "\t"
        case .some:
            insertMoved = true
            insertKeys = ""
        case nil:
            insertKeys += key.characters
        }
        return false
    }

    func exitInsert() {
        var t = text
        var sel = min(buffer.selection.location, t.length)
        let typed: String
        if !insertMoved && insertDeletedBefore == 0 && sel >= insertStart && t.length - insertLength == sel - insertStart {
            typed = t.substring(insertStart, sel)
        } else {
            typed = insertKeys
        }
        if typed.isEmpty && insertAutoIndent && t.lineIsBlank(sel) {
            // Esc on a line `o` indented and nothing typed: no trailing blanks.
            let ls = t.lineStart(sel)
            buffer.replace(NSRange(location: ls, length: t.lineEnd(ls) - ls), with: "")
            sel = ls
            t = text
        } else if insertCount > 1 && !typed.isEmpty {
            let extra = String(repeating: insertRepeatPrefix + typed, count: insertCount - 1)
            buffer.replace(NSRange(location: sel, length: 0), with: extra)
            sel += extra.utf16.count
            t = text
        }
        if var change = pendingChange {
            change.inserted = typed
            change.deletedBefore = insertDeletedBefore
            lastChange = change
            pendingChange = nil
        }
        while openGroups > 0 { endGroup() }
        mode = .normal
        let ls = t.lineStart(sel)
        setCursor(t.clampNormal(sel > ls ? t.prev(sel) : sel))
        desiredColumn = nil
    }

    // MARK: Replace mode

    func enterReplace() {
        replaceStack = []
        replaceTyped = ""
        desiredColumn = nil
        mode = .replace
    }

    func handleReplace(_ key: VimKey) {
        let tokens = key.tokens
        if tokens == ["<esc>"] || tokens == ["<c-c>"] {
            exitReplace()
            return
        }
        switch key.named {
        case .backspace:
            if let last = replaceStack.popLast() {
                buffer.replace(NSRange(location: last.position, length: last.length), with: last.original)
                setCursor(last.position)
                if !replaceTyped.isEmpty { replaceTyped.removeLast() }
            } else {
                setCursor(text.prev(buffer.selection.location))
            }
        case .enter: typeOver("\n")
        case .tab: typeOver("\t")
        case .some: break
        case nil:
            guard !key.modifiers.contains(.control) else { return }
            for ch in key.characters { typeOver(String(ch)) }
        }
    }

    func typeOver(_ s: String) {
        let t = text
        let p = min(buffer.selection.location, t.length)
        var original = ""
        var range = NSRange(location: p, length: 0)
        if p < t.length && !t.isNewline(p) && s != "\n" {
            range.length = t.next(p) - p
            original = t.substring(range)
        }
        buffer.replace(range, with: s)
        replaceStack.append((p, original, s.utf16.count))
        replaceTyped += s
        setCursor(p + s.utf16.count)
    }

    func exitReplace() {
        if var change = pendingChange {
            change.inserted = replaceTyped
            lastChange = change
            pendingChange = nil
        }
        while openGroups > 0 { endGroup() }
        mode = .normal
        let t = text
        let sel = min(buffer.selection.location, t.length)
        let ls = t.lineStart(sel)
        setCursor(t.clampNormal(sel > ls ? t.prev(sel) : sel))
    }

    // MARK: Scrolling

    func scrollLines(_ delta: Int) {
        buffer.scroll(.lines(delta))
        let t = text
        let visible = buffer.visibleCharacterRange
        guard visible.length > 0 else { return }
        let p = cursor
        var top = t.lineStart(visible.location)
        if top < visible.location { top = min(t.length, t.lineEnd(top) + 1) }
        let bottom = t.lineStart(max(visible.location, NSMaxRange(visible) - 1))
        let goal = desiredColumn ?? t.column(p)
        if p < top {
            place(t.position(column: goal, lineStart: top), t)
            desiredColumn = goal
        } else if p > t.lineEnd(bottom) && bottom >= top {
            place(t.position(column: goal, lineStart: bottom), t)
            desiredColumn = goal
        }
    }

    /// Lines on screen, for the page moves.
    func visibleLineCount(_ t: VimText) -> Int {
        let visible = buffer.visibleCharacterRange
        var lines = 1
        var i = visible.location
        let end = min(NSMaxRange(visible), t.length)
        while i < end - 1 {
            if t[i] == VimText.newline { lines += 1 }
            i += 1
        }
        return lines
    }
}
