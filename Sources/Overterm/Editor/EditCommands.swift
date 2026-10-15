import Foundation

/// One replacement, against the text as it was before the edit (UTF-16).
struct TextChange: Equatable, Sendable {
    let range: NSRange
    let replacement: String
}

/// What an editing command does: its changes — sorted, not overlapping, all
/// against the original text, so the view applies them as one undo group
/// (`shouldChangeText(inRanges:replacementStrings:)`, then each from the last
/// back) — and the selections afterwards, in the new text, sorted.
struct TextEdit: Equatable, Sendable {
    var changes: [TextChange]
    var selections: [NSRange]

    /// `text` with the changes made — what the view ends up with.
    func applied(to text: String) -> String {
        let result = NSMutableString(string: text)
        for change in changes.reversed() { result.replaceCharacters(in: change.range, with: change.replacement) }
        return result as String
    }
}

/// How a file indents: what one level is.
enum IndentStyle: Equatable, Sendable {
    case tabs
    case spaces(Int)

    var unit: String {
        switch self {
        case .tabs: "\t"
        case .spaces(let count): String(repeating: " ", count: count)
        }
    }

    /// One level in columns; a tab is `tabWidth` wide.
    func width(tabWidth: Int = 4) -> Int {
        switch self {
        case .tabs: tabWidth
        case .spaces(let count): count
        }
    }

    /// Lines read for detection: past this many indented lines, or 1 MB, the
    /// answer doesn't change.
    static let maxIndentedLines = 1000
    static let maxScanned = 1 << 20

    /// The style the file already uses: tabs when more lines start with a tab
    /// than with spaces; otherwise the step most often seen between one line's
    /// indentation and the next one's (VS Code's guess). A single space is a
    /// doc comment's ` *`, not a level. A file with nothing indented gets the
    /// language's convention: tabs for Go and Makefiles, else four spaces.
    static func detect(in text: NSString, languageID: String? = nil) -> IndentStyle {
        let fallback: IndentStyle = (languageID == "go" || languageID == "make") ? .tabs : .spaces(4)
        let count = min(text.length, maxScanned)
        guard count > 0 else { return fallback }
        var buffer = [unichar](repeating: 0, count: count)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: count))
        var tabLines = 0
        var spaceLines = 0
        var steps = [Int](repeating: 0, count: 9)
        var previousSpaces: Int? = nil
        var i = 0
        while i < count, tabLines + spaceLines < maxIndentedLines {
            var spaces = 0
            var tabs = 0
            var j = i
            while j < count, buffer[j] == 0x20 || buffer[j] == 0x09 {
                if buffer[j] == 0x20 { spaces += 1 } else { tabs += 1 }
                j += 1
            }
            let blank = j >= count || buffer[j] == 0x0A || buffer[j] == 0x0D
            if !blank {
                if j > i, buffer[i] == 0x09 {
                    tabLines += 1
                    previousSpaces = nil
                } else if tabs == 0 {
                    if spaces >= 2 { spaceLines += 1 }
                    if spaces != 1 {
                        if let previous = previousSpaces {
                            let step = abs(spaces - previous)
                            if step >= 2, step <= 8 { steps[step] += 1 }
                        }
                        previousSpaces = spaces
                    }
                }
            }
            while j < count, buffer[j] != 0x0A { j += 1 }
            i = j + 1
        }
        if tabLines == 0, spaceLines == 0 { return fallback }
        if tabLines > spaceLines { return .tabs }
        // Ties go to the smaller step: 2 and 4 seen as often is a 2-space file
        // that closes two levels at once.
        var best = 0
        for step in 2...8 where steps[step] > (best == 0 ? 0 : steps[best]) { best = step }
        return .spaces(best == 0 ? 4 : best)
    }
}

/// A language's comment syntax, for ⌘/.
enum CommentStyle: Equatable, Sendable {
    /// The prefix as inserted, with its space: `"// "`.
    case line(String)
    /// Wrapped around each line: `<!-- … -->`.
    case block(open: String, close: String)
}

/// Where the partner of the bracket by the caret is.
struct BracketMatch: Equatable, Sendable {
    let bracket: Int
    let partner: Int
}

/// The selections ⌘D leaves, and whether it now matches whole words only
/// (it does when it started from a caret, as in VS Code and Zed). The view
/// passes `wholeWord` back on the next ⌘D, and forgets it when the
/// selection changes any other way.
struct OccurrenceSelection: Equatable, Sendable {
    var selections: [NSRange]
    var wholeWord: Bool
}

/// The editor's commands as Zed and VS Code have them — auto-indent, pairs,
/// line moves, comments, multi-cursor selection — as pure functions of the
/// text and the selections. Each reads only the lines it touches (the text
/// may be 4 MB), works in UTF-16 as NSTextView does, and never splits a
/// surrogate pair. nil: nothing to do (or, for typing, let the view type).
enum EditCommands {
    enum Direction: Sendable { case up, down }

    // MARK: Languages

    /// The id the commands key on, by file name (nil: plain text).
    static func languageID(forFileName name: String) -> String? {
        if name == "Dockerfile" || name.hasPrefix("Dockerfile.") { return "dockerfile" }
        if name == "Makefile" || name == "GNUmakefile" || name == "makefile" { return "make" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "go", "zig", "java", "sql", "lua", "toml", "css", "tsx", "jsx", "json", "jsonc", "html", "xml": return ext
        case "rs": return "rust"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx": return "cpp"
        case "m", "mm": return "objc"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "mts", "cts": return "typescript"
        case "kt", "kts": return "kotlin"
        case "py", "pyi": return "python"
        case "rb": return "ruby"
        case "sh", "bash", "zsh", "fish", "env": return "shell"
        case "yaml", "yml": return "yaml"
        case "mk": return "make"
        case "ex", "exs": return "elixir"
        case "hs": return "haskell"
        case "md", "markdown": return "markdown"
        case "htm": return "html"
        case "plist", "svg": return "xml"
        case "scss", "less": return "css"
        default: return nil
        }
    }

    /// How ⌘/ comments a line in this language; nil: it doesn't.
    static func commentPrefix(forLanguageID id: String?) -> CommentStyle? {
        switch id {
        case "swift", "go", "rust", "c", "cpp", "objc", "javascript", "typescript", "tsx", "jsx", "java", "kotlin", "zig", "json", "jsonc":
            .line("// ")
        case "python", "ruby", "shell", "yaml", "toml", "make", "dockerfile", "elixir": .line("# ")
        case "sql", "lua", "haskell": .line("-- ")
        case "markdown", "html", "xml": .block(open: "<!--", close: "-->")
        case "css": .block(open: "/*", close: "*/")
        default: nil
        }
    }

    /// The text's line ending — its first line's — for lines a command adds:
    /// a CRLF file keeps CRLF.
    static func lineEnding(of text: NSString) -> String {
        let newline = text.range(of: "\n", options: .literal)
        guard newline.location != NSNotFound, newline.location > 0, text.character(at: newline.location - 1) == 0x0D else { return "\n" }
        return "\r\n"
    }

    // MARK: Return

    /// Return, indented: the new line takes the current one's indentation,
    /// one level more after an opener at the end (`{ ( [`; `:` in Python
    /// and YAML; `do`/`then` in shell, Ruby, Lua, Elixir). Between a pair —
    /// `{|}` — the closer goes to a line of its own at the original
    /// indentation with the caret on the indented line between (Zed).
    /// Whitespace after the caret doesn't come along, and a line left with
    /// only whitespace is left empty.
    static func newline(in text: NSString, selections: [NSRange], style: IndentStyle, languageID: String? = nil) -> TextEdit {
        let scan = TextScanner(text)
        let eol = lineEnding(of: text)
        var builder = EditBuilder()
        for selection in sorted(selections) {
            let line = scan.line(at: selection.location)
            let wsEnd = scan.leadingWhitespaceEnd(line)
            let indent = scan.substring(line.start, min(wsEnd, selection.location))
            var start = selection.location
            if start > line.start, wsEnd >= start { start = line.start }
            let afterLine = scan.line(at: selection.upperBound)
            var end = selection.upperBound
            while end < afterLine.contentEnd, scan.isBlank(scan.unit(end)) { end += 1 }

            let opener = scan.opener(endingAt: selection.location, lineStart: line.start, languageID: languageID)
            var replacement = eol + indent
            if let opener { replacement += style.unit }
            let caret = replacement.utf16.count
            if let opener, let closer = pairs[opener], end < afterLine.contentEnd, scan.unit(end) == closer {
                replacement += eol + indent
            }
            builder.add(TextChange(range: NSRange(location: start, length: end - start), replacement: replacement), caret: caret)
        }
        return builder.edit()
    }

    /// ⌘↩: a new line below each caret's line, indented as Return at its end
    /// would, the caret on it. Several carets on a line make one.
    static func insertLineBelow(in text: NSString, selections: [NSRange], style: IndentStyle, languageID: String? = nil) -> TextEdit {
        let scan = TextScanner(text)
        let eol = lineEnding(of: text)
        var builder = EditBuilder()
        var last = -1
        for selection in sorted(selections) {
            let line = scan.line(at: selection.upperBound)
            guard line.start != last else { continue }
            last = line.start
            var indent = scan.substring(line.start, scan.leadingWhitespaceEnd(line))
            if scan.opener(endingAt: line.contentEnd, lineStart: line.start, languageID: languageID) != nil { indent += style.unit }
            let replacement = eol + indent
            builder.add(TextChange(range: NSRange(location: line.contentEnd, length: 0), replacement: replacement), caret: replacement.utf16.count)
        }
        return builder.edit()
    }

    /// ⇧⌘↩: a new line above each caret's line, at its indentation.
    static func insertLineAbove(in text: NSString, selections: [NSRange]) -> TextEdit {
        let scan = TextScanner(text)
        let eol = lineEnding(of: text)
        var builder = EditBuilder()
        var last = -1
        for selection in sorted(selections) {
            let line = scan.line(at: selection.location)
            guard line.start != last else { continue }
            last = line.start
            let indent = scan.substring(line.start, scan.leadingWhitespaceEnd(line))
            builder.add(TextChange(range: NSRange(location: line.start, length: 0), replacement: indent + eol), caret: indent.utf16.count)
        }
        return builder.edit()
    }

    // MARK: Pairs

    /// Opener → closer; a quote closes itself.
    static let pairs: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D, 0x22: 0x22, 0x27: 0x27, 0x60: 0x60]
    private static let closers: Set<unichar> = [0x29, 0x5D, 0x7D]
    private static let quotes: Set<unichar> = [0x22, 0x27, 0x60]
    /// A pair opens only before these, whitespace, or the end of the line
    /// (Zed's `autoclose_before`): typed before a word, `(` is just `(`.
    private static let pairsBefore: Set<unichar> = Set(";:.,=}])>".utf16)
    /// Where `'` is an apostrophe or a Rust lifetime more often than a quote.
    private static let noSingleQuotePairs: Set<String?> = [nil, "markdown", "rust", "plaintext"]

    /// A character typed at every selection, when it means more than itself:
    /// an opener or quote wraps a selection, or opens a pair; a closer typed
    /// before the same closer steps over it — when the line's pairs of that
    /// kind are balanced, which is what one auto-inserted looks like (a quote:
    /// when the line holds an even number of them). nil: type it as is.
    static func typeCharacter(_ character: String, in text: NSString, selections: [NSRange], languageID: String? = nil) -> TextEdit? {
        let units = Array(character.utf16)
        guard units.count == 1, let c = units.first, pairs[c] != nil || closers.contains(c) else { return nil }
        let scan = TextScanner(text)
        var builder = EditBuilder()
        var special = false
        for selection in sorted(selections) {
            if selection.length > 0, let close = pairs[c] {
                let inner = text.substring(with: selection)
                let replacement = character + inner + String(utf16CodeUnits: [close], count: 1)
                builder.add(TextChange(range: selection, replacement: replacement), selection: NSRange(location: 1, length: inner.utf16.count))
                special = true
                continue
            }
            let at = selection.location
            let next: unichar? = selection.upperBound < scan.length ? scan.unit(selection.upperBound) : nil
            if selection.length == 0, next == c, closers.contains(c) || quotes.contains(c), scan.overtypes(c, at: at) {
                builder.move(to: at + 1)
                special = true
                continue
            }
            let canOpen = next.map { scan.isWhitespaceOrNewline($0) || pairsBefore.contains($0) } ?? true
            var pair = false
            if let close = pairs[c], canOpen {
                if quotes.contains(c) {
                    let before = scan.scalar(before: at)
                    pair = !(c == 0x27 && noSingleQuotePairs.contains(languageID)) && !(before.map(isWord) ?? false) && before != Unicode.Scalar(c)
                } else {
                    pair = true
                }
                if pair {
                    builder.add(TextChange(range: selection, replacement: String(utf16CodeUnits: [c, close], count: 2)), caret: 1)
                    special = true
                }
            }
            if !pair { builder.add(TextChange(range: selection, replacement: character), caret: 1) }
        }
        return special ? builder.edit() : nil
    }

    /// Backspace: a caret inside an empty pair — `(|)`, `"|"` — deletes both
    /// halves. Other selections delete as usual (a selection, or the
    /// character before the caret, whole). nil when no caret is in a pair.
    static func deleteBackward(in text: NSString, selections: [NSRange]) -> TextEdit? {
        let scan = TextScanner(text)
        var builder = EditBuilder()
        var special = false
        for selection in sorted(selections) {
            let at = selection.location
            if selection.length > 0 {
                builder.add(TextChange(range: selection, replacement: ""), caret: 0)
            } else if at > 0, at < scan.length, let close = pairs[scan.unit(at - 1)], scan.unit(at) == close {
                builder.add(TextChange(range: NSRange(location: at - 1, length: 2), replacement: ""), caret: 0)
                special = true
            } else if at > 0 {
                builder.add(TextChange(range: text.rangeOfComposedCharacterSequence(at: at - 1), replacement: ""), caret: 0)
            } else {
                builder.move(to: 0)
            }
        }
        return special ? builder.edit() : nil
    }

    // MARK: Comments

    /// ⌘/ over the lines of every selection: when every non-blank line is
    /// commented, uncomments them all; otherwise comments each non-blank line
    /// at the block's least indentation, so the markers line up (VS Code,
    /// Zed). A block of only blank lines is commented at its indentation.
    static func toggleLineComment(in text: NSString, selections: [NSRange], style: CommentStyle) -> TextEdit? {
        let scan = TextScanner(text)
        let blocks = scan.blocks(for: sorted(selections))
        let open: String
        var close: String? = nil
        switch style {
        case .line(let prefix): open = prefix
        case .block(let o, let c):
            open = o
            close = c
        }
        let token = open.trimmingCharacters(in: .whitespaces) as NSString
        let closeToken = close.map { $0.trimmingCharacters(in: .whitespaces) as NSString }

        func commented(_ line: LineSpan, _ ws: Int) -> Bool {
            guard scan.hasPrefix(token, at: ws, before: line.contentEnd) else { return false }
            guard let closeToken else { return true }
            let end = scan.trimmedEnd(line)
            return end - ws >= token.length + closeToken.length && scan.hasPrefix(closeToken, at: end - closeToken.length, before: end)
        }

        var lines: [[LineSpan]] = blocks.map { scan.lines(in: $0) }
        var allCommented = true
        var anyNonBlank = false
        for line in lines.joined() {
            let ws = scan.leadingWhitespaceEnd(line)
            guard ws < line.contentEnd else { continue }
            anyNonBlank = true
            if !commented(line, ws) { allCommented = false }
        }
        var changes: [TextChange] = []
        // Closers inserted: a caret at the line's end stays before them.
        var closers = Set<Int>()
        if anyNonBlank, allCommented {
            for line in lines.joined() {
                let ws = scan.leadingWhitespaceEnd(line)
                guard ws < line.contentEnd else { continue }
                var openEnd = ws + token.length
                if openEnd < line.contentEnd, scan.unit(openEnd) == 0x20 { openEnd += 1 }
                changes.append(TextChange(range: NSRange(location: ws, length: openEnd - ws), replacement: ""))
                if let closeToken {
                    let end = scan.trimmedEnd(line)
                    var closeStart = end - closeToken.length
                    if closeStart - 1 >= openEnd, scan.unit(closeStart - 1) == 0x20 { closeStart -= 1 }
                    if closeStart >= openEnd { changes.append(TextChange(range: NSRange(location: closeStart, length: end - closeStart), replacement: "")) }
                }
            }
        } else {
            for index in lines.indices {
                // Only blank lines: comment them where they are.
                let nonBlank = lines[index].filter { scan.leadingWhitespaceEnd($0) < $0.contentEnd }
                if !nonBlank.isEmpty { lines[index] = nonBlank }
                let column = lines[index].map { scan.leadingWhitespaceEnd($0) - $0.start }.min() ?? 0
                for line in lines[index] {
                    changes.append(TextChange(range: NSRange(location: line.start + column, length: 0), replacement: open + (close == nil ? "" : " ")))
                    if let close {
                        let end = max(scan.trimmedEnd(line), line.start + column)
                        closers.insert(changes.count)
                        changes.append(TextChange(range: NSRange(location: end, length: 0), replacement: " " + close))
                    }
                }
            }
        }
        guard !changes.isEmpty else { return nil }
        return TextEdit(changes: changes, selections: mapSelections(sorted(selections), through: changes, before: closers))
    }

    // MARK: Indentation

    /// ⌘]: one level more on every line of every selection (blank lines of a
    /// multi-line selection stay empty).
    static func indent(in text: NSString, selections: [NSRange], style: IndentStyle) -> TextEdit? {
        let scan = TextScanner(text)
        var changes: [TextChange] = []
        for block in scan.blocks(for: sorted(selections)) {
            let lines = scan.lines(in: block)
            for line in lines where lines.count == 1 || line.contentEnd > line.start {
                changes.append(TextChange(range: NSRange(location: line.start, length: 0), replacement: style.unit))
            }
        }
        guard !changes.isEmpty else { return nil }
        return TextEdit(changes: changes, selections: mapSelections(sorted(selections), through: changes))
    }

    /// ⌘[: one level less — a tab, or up to a level's worth of spaces.
    static func outdent(in text: NSString, selections: [NSRange], style: IndentStyle, tabWidth: Int = 4) -> TextEdit? {
        let scan = TextScanner(text)
        let width = style.width(tabWidth: tabWidth)
        var changes: [TextChange] = []
        for block in scan.blocks(for: sorted(selections)) {
            for line in scan.lines(in: block) {
                var end = line.start
                if end < line.contentEnd, scan.unit(end) == 0x09 {
                    end += 1
                } else {
                    while end < line.contentEnd, end - line.start < width, scan.unit(end) == 0x20 { end += 1 }
                }
                if end > line.start { changes.append(TextChange(range: NSRange(location: line.start, length: end - line.start), replacement: "")) }
            }
        }
        guard !changes.isEmpty else { return nil }
        return TextEdit(changes: changes, selections: mapSelections(sorted(selections), through: changes))
    }

    /// Tab: carets get a level's worth up to the next stop (spaces) or a tab;
    /// a selection over more than one line is indented instead.
    static func insertTab(in text: NSString, selections: [NSRange], style: IndentStyle, tabWidth: Int = 4) -> TextEdit {
        let scan = TextScanner(text)
        let ordered = sorted(selections)
        if ordered.contains(where: { $0.length > 0 && scan.lineStart($0.location) != scan.line(at: $0.upperBound).start }),
            let edit = indent(in: text, selections: ordered, style: style)
        {
            return edit
        }
        var builder = EditBuilder()
        for selection in ordered {
            var replacement = style.unit
            if case .spaces(let count) = style {
                let column = scan.column(of: selection.location, tabWidth: tabWidth)
                replacement = String(repeating: " ", count: count - column % count)
            }
            builder.add(TextChange(range: selection, replacement: replacement), caret: replacement.utf16.count)
        }
        return builder.edit()
    }

    // MARK: Lines

    /// ⌥↑ / ⌥↓: the lines of each selection swap with the line above or
    /// below, the selections moving with them. A block at the edge stays.
    static func moveLines(_ direction: Direction, in text: NSString, selections: [NSRange]) -> TextEdit? {
        let scan = TextScanner(text)
        var changes: [TextChange] = []
        var result: [NSRange] = []
        for block in scan.blocks(for: sorted(selections)) {
            let body = scan.substring(block.start, block.contentEnd)
            let separator = scan.substring(block.contentEnd, block.end)
            var shift = 0
            switch direction {
            case .up:
                if let above = scan.line(before: block.first) {
                    let replacement = body + scan.substring(above.contentEnd, above.end) + scan.substring(above.start, above.contentEnd)
                    changes.append(TextChange(range: NSRange(location: above.start, length: block.contentEnd - above.start), replacement: replacement))
                    shift = above.start - block.start
                }
            case .down:
                if let below = scan.line(after: block.last) {
                    let replacement = scan.substring(below.start, below.contentEnd) + separator + body
                    changes.append(TextChange(range: NSRange(location: block.start, length: below.contentEnd - block.start), replacement: replacement))
                    shift = below.contentEnd - block.contentEnd
                }
            }
            // The lines swapped keep the text's length: nothing else moves.
            result += block.selections.map { NSRange(location: $0.location + shift, length: $0.length) }
        }
        guard !changes.isEmpty else { return nil }
        return TextEdit(changes: changes, selections: result)
    }

    /// ⇧⌥↓ / ⇧⌥↑: each selection's lines copied below (the selection moves
    /// to the copy) or above (it stays on the upper one, the copy).
    static func duplicateLines(_ direction: Direction, in text: NSString, selections: [NSRange]) -> TextEdit {
        let scan = TextScanner(text)
        let eol = lineEnding(of: text)
        var builder = EditBuilder()
        // Carets on adjacent lines duplicate a line each, not the two together.
        for block in scan.blocks(for: sorted(selections), mergingAdjacent: false) {
            let body = scan.substring(block.start, block.contentEnd)
            let separator = block.last.hasNewline ? scan.substring(block.contentEnd, block.end) : eol
            switch direction {
            case .down:
                let inserted = separator + body
                builder.add(
                    TextChange(range: NSRange(location: block.contentEnd, length: 0), replacement: inserted),
                    selections: block.selections.map { NSRange(location: $0.location - block.contentEnd + inserted.utf16.count, length: $0.length) })
            case .up:
                builder.add(
                    TextChange(range: NSRange(location: block.start, length: 0), replacement: body + separator),
                    selections: block.selections.map { NSRange(location: $0.location - block.start, length: $0.length) })
            }
        }
        return builder.edit()
    }

    /// ⇧⌘K: each selection's lines go, the caret to the line that takes their
    /// place, at the column it had (the last line goes with the newline
    /// before it).
    static func deleteLines(in text: NSString, selections: [NSRange]) -> TextEdit {
        let scan = TextScanner(text)
        var builder = EditBuilder()
        for block in scan.blocks(for: sorted(selections)) {
            let column = block.selections[0].location - scan.lineStart(block.selections[0].location)
            if block.last.hasNewline {
                let next = scan.line(at: block.end)
                let caret = scan.snap(min(next.start + column, next.contentEnd)) - block.end
                builder.add(TextChange(range: NSRange(location: block.start, length: block.end - block.start), replacement: ""), caret: caret)
            } else if let above = scan.line(before: block.first) {
                let caret = scan.snap(min(above.start + column, above.contentEnd)) - above.contentEnd
                // Negative: the caret lands before the change, on the line above.
                builder.add(TextChange(range: NSRange(location: above.contentEnd, length: block.contentEnd - above.contentEnd), replacement: ""), caret: caret)
            } else {
                builder.add(TextChange(range: NSRange(location: block.start, length: block.contentEnd - block.start), replacement: ""), caret: 0)
            }
        }
        return builder.edit()
    }

    /// The whole lines of each selection, their newlines included.
    static func selectLine(in text: NSString, selections: [NSRange]) -> [NSRange] {
        let scan = TextScanner(text)
        return scan.blocks(for: sorted(selections)).map { NSRange(location: $0.start, length: $0.end - $0.start) }
    }

    /// ⌘L (VS Code, Zed): selects the caret's line; a selection already of
    /// whole lines takes the next line too.
    static func expandLineSelection(in text: NSString, selections: [NSRange]) -> [NSRange] {
        let scan = TextScanner(text)
        var expanded: [NSRange] = []
        for selection in sorted(selections) {
            let aligned =
                selection.length > 0 && scan.lineStart(selection.location) == selection.location
                && (selection.upperBound == scan.length || scan.unit(selection.upperBound - 1) == 0x0A)
            if aligned, selection.upperBound < scan.length {
                let next = scan.line(at: selection.upperBound)
                expanded.append(NSRange(location: selection.location, length: next.end - selection.location))
            } else if aligned {
                expanded.append(selection)
            } else {
                let block = scan.blocks(for: [selection])[0]
                expanded.append(NSRange(location: block.start, length: block.end - block.start))
            }
        }
        return merged(expanded)
    }

    /// ⌃J: a caret's line joins the next; a selection's lines join each
    /// other. One space where they meet (none next to a blank line), the
    /// whitespace around the join gone; a caret goes to the join.
    static func joinLines(in text: NSString, selections: [NSRange]) -> TextEdit? {
        let scan = TextScanner(text)
        var changes: [TextChange] = []
        var carets: [Int: Int] = [:]  // a single-line block's caret → its join's change
        for block in scan.blocks(for: sorted(selections)) {
            var lines = scan.lines(in: block)
            if lines.count == 1 {
                guard let next = scan.line(after: block.last) else { continue }
                lines.append(next)
            }
            for (index, (line, next)) in zip(lines, lines.dropFirst()).enumerated() {
                let end = scan.trimmedEnd(line)
                let nextStart = scan.leadingWhitespaceEnd(next)
                let space = end > line.start && nextStart < next.contentEnd
                if index == 0, scan.lines(in: block).count == 1 {
                    for selection in block.selections where selection.length == 0 { carets[selection.location] = changes.count }
                }
                changes.append(TextChange(range: NSRange(location: end, length: nextStart - end), replacement: space ? " " : ""))
            }
        }
        guard !changes.isEmpty else { return nil }
        var mapped = mapSelections(sorted(selections), through: changes)
        // Carets go to their join: where the change lands in the new text.
        var delta = 0
        var deltas: [Int] = []
        for change in changes {
            deltas.append(delta)
            delta += change.replacement.utf16.count - change.range.length
        }
        for (index, selection) in sorted(selections).enumerated() where selection.length == 0 {
            if let change = carets[selection.location] { mapped[index] = NSRange(location: changes[change].range.location + deltas[change], length: 0) }
        }
        return TextEdit(changes: changes, selections: merged(mapped))
    }

    // MARK: Occurrences

    /// ⌘D: carets first select the word they are in (and the search becomes
    /// whole-word); then the next occurrence of the last selection's text
    /// after it is added, wrapping past the end, skipping what is selected.
    /// Case-sensitive. nil: nothing (more) to select.
    static func selectNextOccurrence(in text: NSString, selections: [NSRange], wholeWord: Bool) -> OccurrenceSelection? {
        let scan = TextScanner(text)
        let ordered = sorted(selections)
        guard let last = ordered.last else { return nil }
        if ordered.contains(where: { $0.length == 0 }) {
            let words = ordered.map { $0.length == 0 ? (scan.word(at: $0.location) ?? $0) : $0 }
            guard words != ordered else { return nil }
            return OccurrenceSelection(selections: merged(words), wholeWord: true)
        }
        let needle = text.substring(with: last)
        let from = last.upperBound
        for range in [NSRange(location: from, length: scan.length - from), NSRange(location: 0, length: from)] {
            var searchFrom = range.location
            while searchFrom < range.upperBound {
                let found = text.range(of: needle, options: .literal, range: NSRange(location: searchFrom, length: range.upperBound - searchFrom))
                guard found.location != NSNotFound else { break }
                searchFrom = found.location + 1
                if wholeWord, !scan.isWholeWord(found) { continue }
                if ordered.contains(where: { NSIntersectionRange($0, found).length > 0 }) { continue }
                return OccurrenceSelection(selections: (ordered + [found]).sorted { $0.location < $1.location }, wholeWord: wholeWord)
            }
        }
        return nil
    }

    /// Past this many, ⇧⌘L stops: more carets than anyone can follow.
    static let maxOccurrences = 10_000

    /// ⇧⌘L: every occurrence of the last selection's text (of the word at a
    /// caret, whole-word).
    static func selectAllOccurrences(in text: NSString, selections: [NSRange], wholeWord: Bool) -> OccurrenceSelection? {
        let scan = TextScanner(text)
        guard var last = sorted(selections).last else { return nil }
        var whole = wholeWord
        if last.length == 0 {
            guard let word = scan.word(at: last.location) else { return nil }
            last = word
            whole = true
        }
        let needle = text.substring(with: last)
        var found: [NSRange] = []
        var from = 0
        while from < scan.length, found.count < maxOccurrences {
            let range = text.range(of: needle, options: .literal, range: NSRange(location: from, length: scan.length - from))
            guard range.location != NSNotFound else { break }
            if !whole || scan.isWholeWord(range) {
                found.append(range)
                from = range.upperBound
            } else {
                from = range.location + 1
            }
        }
        return found.isEmpty ? nil : OccurrenceSelection(selections: found, wholeWord: whole)
    }

    // MARK: Brackets

    /// How far a bracket's partner is looked for, each way (UTF-16).
    static let maxBracketScan = 200_000
    private static let bracketPartners: [unichar: (partner: unichar, forward: Bool)] = [
        0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true), 0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false),
    ]

    /// The bracket just before the caret — or else at it — and its partner,
    /// counting only brackets of its kind and skipping the positions `skip`
    /// says are inside strings or comments (the highlighter's tokens).
    static func matchingBracket(at index: Int, in text: NSString, skip: (Int) -> Bool = { _ in false }) -> BracketMatch? {
        let length = text.length
        for position in [index - 1, index] where position >= 0 && position < length && !skip(position) {
            let c = text.character(at: position)
            guard let entry = bracketPartners[c] else { continue }
            let (partner, forward) = entry
            var depth = 0
            let found: Int? = TextScanner(text).scan(from: position, forward: forward, limit: maxBracketScan) { i, unit in
                if unit == c, !skip(i) {
                    depth += 1
                } else if unit == partner, !skip(i) {
                    depth -= 1
                    if depth == 0 { return true }
                }
                return false
            }
            if let found { return BracketMatch(bracket: position, partner: found) }
        }
        return nil
    }

    // MARK: Indent guides

    /// How far a blank line looks for the lines around it.
    static let maxGuideLookaround = 1000

    /// The indent guides of `lines` (0-based, by `LineIndex.starts`): per
    /// line, how many levels deep it is — guides at columns 0, w, 2w… below
    /// that, w the indent width (columns, tabs `tabWidth` wide). A blank line
    /// takes the shallower of the non-blank lines around it, so guides run
    /// through the gaps in a block and stop where it ends (Zed).
    static func indentGuides(in text: NSString, lineStarts: [Int], lines: Range<Int>, indentWidth: Int, tabWidth: Int = 4) -> [Int] {
        let scan = TextScanner(text)
        let width = max(1, indentWidth)
        let count = lineStarts.count
        let visible = lines.clamped(to: 0..<count)
        func level(_ line: Int) -> Int? {
            let start = lineStarts[line]
            let end = line + 1 < count ? lineStarts[line + 1] - 1 : scan.length
            var column = 0
            var i = start
            while i < end {
                let unit = scan.unit(i)
                if unit == 0x20 {
                    column += 1
                } else if unit == 0x09 {
                    column += tabWidth - column % tabWidth
                } else if unit == 0x0D || unit == 0x0A {
                    return nil
                } else {
                    return column / width
                }
                i += 1
            }
            return nil
        }
        var levels = visible.map { level($0) }
        // The nearest non-blank line above the first and below the last.
        var above: Int? = nil
        var line = visible.lowerBound - 1
        while above == nil, line >= 0, visible.lowerBound - line <= maxGuideLookaround {
            above = level(line)
            line -= 1
        }
        var below: Int? = nil
        line = visible.upperBound
        while below == nil, line < count, line - visible.upperBound < maxGuideLookaround {
            below = level(line)
            line += 1
        }
        var previous = levels.map { _ in Int?.none }
        var carry = above
        for i in levels.indices {
            previous[i] = carry
            if let level = levels[i] { carry = level }
        }
        carry = below
        for i in levels.indices.reversed() {
            if let level = levels[i] {
                carry = level
            } else {
                levels[i] = min(previous[i] ?? 0, carry ?? 0)
            }
        }
        return levels.map { $0 ?? 0 }
    }

    // MARK: Helpers

    private static func sorted(_ selections: [NSRange]) -> [NSRange] {
        selections.sorted { $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length) }
    }

    /// Overlapping selections made one (carets that land on each other too).
    static func merged(_ selections: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for selection in sorted(selections) {
            if let last = result.last,
                selection.location < last.upperBound || selection == last || (selection.location == last.upperBound && selection.length > 0 && last.length > 0)
            {
                result[result.count - 1] = NSUnionRange(last, selection)
            } else {
                result.append(selection)
            }
        }
        return result
    }

    /// Selections carried through changes: a caret moves with an insertion
    /// at it; a selection takes in what is inserted inside it but not at
    /// its edges' outsides (its start stays before, its end after).
    /// `before`: indices of insertions a caret at them stays in front of.
    static func mapSelections(_ selections: [NSRange], through changes: [TextChange], before: Set<Int> = []) -> [NSRange] {
        var mapper = PositionMapper(changes: changes, before: before)
        return selections.map { selection in
            if selection.length == 0 { return NSRange(location: mapper.map(selection.location, after: true, caret: true), length: 0) }
            let start = mapper.map(selection.location, after: false)
            let end = mapper.map(selection.upperBound, after: true)
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F
        }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}

/// Positions in the original text carried into the edited one; queries must
/// come in ascending order (sorted selections, start before end).
struct PositionMapper {
    let changes: [TextChange]
    let before: Set<Int>
    private var index = 0
    private var delta = 0

    init(changes: [TextChange], before: Set<Int> = []) {
        self.changes = changes
        self.before = before
    }

    /// `after`: a position at an insertion, or inside a replaced range, goes
    /// after the new text rather than before it — but a `caret` stays in
    /// front of the insertions in `before`.
    mutating func map(_ position: Int, after: Bool, caret: Bool = false) -> Int {
        while index < changes.count {
            let change = changes[index]
            let end = NSMaxRange(change.range)
            guard end < position || (end == position && change.range.length > 0) else { break }
            delta += change.replacement.utf16.count - change.range.length
            index += 1
        }
        if index < changes.count, changes[index].range.location <= position {
            let base = changes[index].range.location + delta
            return after && !(caret && before.contains(index)) ? base + changes[index].replacement.utf16.count : base
        }
        return position + delta
    }
}

/// Builds an edit change by change, in text order, each with the selections
/// it leaves relative to where it starts in the new text.
private struct EditBuilder {
    var changes: [TextChange] = []
    var selections: [NSRange] = []
    private var delta = 0

    mutating func add(_ change: TextChange, caret: Int) {
        add(change, selections: [NSRange(location: caret, length: 0)])
    }

    mutating func add(_ change: TextChange, selection: NSRange) {
        add(change, selections: [selection])
    }

    mutating func add(_ change: TextChange, selections relative: [NSRange]) {
        let start = change.range.location + delta
        selections += relative.map { NSRange(location: start + $0.location, length: $0.length) }
        if change.range.length > 0 || !change.replacement.isEmpty { changes.append(change) }
        delta += change.replacement.utf16.count - change.range.length
    }

    /// A caret that moves without changing anything (at an original position).
    mutating func move(to position: Int) {
        selections.append(NSRange(location: position + delta, length: 0))
    }

    func edit() -> TextEdit {
        TextEdit(changes: changes, selections: EditCommands.merged(selections))
    }
}

/// A line: where it starts, where its text ends (before `\r\n` or `\n`),
/// and where the next one starts.
struct LineSpan: Equatable {
    let start: Int
    let contentEnd: Int
    let end: Int
    var hasNewline: Bool { end > contentEnd }
}

/// The lines a group of selections covers, merged when they touch.
struct LineBlock {
    var first: LineSpan
    var last: LineSpan
    var selections: [NSRange]
    var start: Int { first.start }
    var contentEnd: Int { last.contentEnd }
    var end: Int { last.end }
}

/// Reads around an offset: lines are found by searching out from it
/// (NSString's own search), never by indexing the whole text.
struct TextScanner {
    let text: NSString
    let length: Int

    init(_ text: NSString) {
        self.text = text
        length = text.length
    }

    func unit(_ i: Int) -> unichar { text.character(at: i) }

    func substring(_ from: Int, _ to: Int) -> String {
        to > from ? text.substring(with: NSRange(location: from, length: to - from)) : ""
    }

    func isBlank(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    func isWhitespaceOrNewline(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D }

    func lineStart(_ i: Int) -> Int {
        guard i > 0 else { return 0 }
        let newline = text.range(of: "\n", options: [.literal, .backwards], range: NSRange(location: 0, length: min(i, length)))
        return newline.location == NSNotFound ? 0 : newline.location + 1
    }

    func line(at i: Int) -> LineSpan {
        let start = lineStart(i)
        let newline = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: length - start))
        guard newline.location != NSNotFound else { return LineSpan(start: start, contentEnd: length, end: length) }
        var contentEnd = newline.location
        if contentEnd > start, unit(contentEnd - 1) == 0x0D { contentEnd -= 1 }
        return LineSpan(start: start, contentEnd: contentEnd, end: newline.location + 1)
    }

    func line(after line: LineSpan) -> LineSpan? { line.hasNewline ? self.line(at: line.end) : nil }

    func line(before line: LineSpan) -> LineSpan? { line.start > 0 ? self.line(at: line.start - 1) : nil }

    func leadingWhitespaceEnd(_ line: LineSpan) -> Int {
        var i = line.start
        while i < line.contentEnd, isBlank(unit(i)) { i += 1 }
        return i
    }

    /// After the line's last non-blank character (its start when blank).
    func trimmedEnd(_ line: LineSpan) -> Int {
        var i = line.contentEnd
        while i > line.start, isBlank(unit(i - 1)) { i -= 1 }
        return i
    }

    func hasPrefix(_ prefix: NSString, at i: Int, before end: Int) -> Bool {
        guard i >= 0, i + prefix.length <= end else { return false }
        return text.substring(with: NSRange(location: i, length: prefix.length)) == prefix as String
    }

    /// Visual column of an offset, tabs `tabWidth` wide.
    func column(of i: Int, tabWidth: Int) -> Int {
        var column = 0
        var j = lineStart(i)
        while j < i {
            column += unit(j) == 0x09 ? tabWidth - column % tabWidth : 1
            j += 1
        }
        return column
    }

    /// An offset moved back off the second half of a surrogate pair.
    func snap(_ i: Int) -> Int {
        guard i > 0, i < length else { return i }
        return text.rangeOfComposedCharacterSequence(at: i).location
    }

    func scalar(before i: Int) -> Unicode.Scalar? {
        guard i > 0 else { return nil }
        let low = unit(i - 1)
        if UTF16.isTrailSurrogate(low), i > 1, UTF16.isLeadSurrogate(unit(i - 2)) {
            return Unicode.Scalar(UInt32(0x10000 + ((Int(unit(i - 2)) - 0xD800) << 10) + (Int(low) - 0xDC00)))
        }
        return Unicode.Scalar(low)
    }

    func scalar(at i: Int) -> Unicode.Scalar? {
        guard i < length else { return nil }
        let high = unit(i)
        if UTF16.isLeadSurrogate(high), i + 1 < length, UTF16.isTrailSurrogate(unit(i + 1)) {
            return Unicode.Scalar(UInt32(0x10000 + ((Int(high) - 0xD800) << 10) + (Int(unit(i + 1)) - 0xDC00)))
        }
        return Unicode.Scalar(high)
    }

    /// The word around (or just before) a caret: letters, digits, `_`.
    func word(at i: Int) -> NSRange? {
        var start = i
        while let scalar = scalar(before: start), EditCommands.isWord(scalar) { start -= scalar.utf16.count }
        var end = i
        while let scalar = scalar(at: end), EditCommands.isWord(scalar) { end += scalar.utf16.count }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    func isWholeWord(_ range: NSRange) -> Bool {
        !(scalar(before: range.location).map(EditCommands.isWord) ?? false) && !(scalar(at: range.upperBound).map(EditCommands.isWord) ?? false)
    }

    /// The opener a line ends with before `i`, trailing blanks aside: a
    /// bracket, `:` in Python/YAML, or `do`/`then` where blocks open so.
    func opener(endingAt i: Int, lineStart: Int, languageID: String?) -> unichar? {
        var end = i
        while end > lineStart, isBlank(unit(end - 1)) { end -= 1 }
        guard end > lineStart else { return nil }
        let c = unit(end - 1)
        if c == 0x28 || c == 0x5B || c == 0x7B { return c }
        if c == 0x3A, languageID == "python" || languageID == "yaml" { return c }
        if ["shell", "ruby", "lua", "elixir"].contains(languageID) {
            for keyword in ["do", "then"] where end - lineStart >= keyword.utf16.count {
                let start = end - keyword.utf16.count
                // Indents like `:` does: a level, no pair to split.
                if substring(start, end) == keyword, !(scalar(before: start).map(EditCommands.isWord) ?? false) { return 0x3A }
            }
        }
        return nil
    }

    /// Whether typing closer `c` before the same character steps over it:
    /// the line's pairs of its kind are balanced (a quote: an even count).
    func overtypes(_ c: unichar, at i: Int) -> Bool {
        let line = line(at: i)
        let open: unichar? = c == 0x29 ? 0x28 : c == 0x5D ? 0x5B : c == 0x7D ? 0x7B : nil
        var opens = 0
        var closes = 0
        for j in line.start..<line.contentEnd {
            let u = unit(j)
            if let open, u == open { opens += 1 } else if u == c { closes += 1 }
        }
        return open == nil ? closes % 2 == 0 : opens <= closes
    }

    /// The lines selections cover — a selection ending at a line's start
    /// doesn't take that line — in blocks, touching ones merged (moving or
    /// commenting lines one block at a time would hit the same line twice).
    func blocks(for selections: [NSRange], mergingAdjacent: Bool = true) -> [LineBlock] {
        var blocks: [LineBlock] = []
        for selection in selections {
            let first = line(at: selection.location)
            var endIndex = selection.upperBound
            if selection.length > 0, endIndex > first.start, unit(endIndex - 1) == 0x0A { endIndex -= 1 }
            let last = endIndex < first.end || !first.hasNewline ? first : line(at: endIndex)
            if let previous = blocks.last,
                first.start < previous.end || first.start == previous.last.start || (mergingAdjacent && first.start == previous.end)
            {
                if last.end >= previous.last.end { blocks[blocks.count - 1].last = last }
                blocks[blocks.count - 1].selections.append(selection)
            } else {
                blocks.append(LineBlock(first: first, last: last, selections: [selection]))
            }
        }
        return blocks
    }

    func lines(in block: LineBlock) -> [LineSpan] {
        var result: [LineSpan] = []
        var line = block.first
        while true {
            result.append(line)
            guard line.start < block.last.start, let next = self.line(after: line) else { break }
            line = next
        }
        return result
    }

    /// Walks from `start` (excluded) one way, a chunk at a time, until
    /// `visit` says stop or `limit` units have gone by; the offset it stopped at.
    func scan(from start: Int, forward: Bool, limit: Int, _ visit: (Int, unichar) -> Bool) -> Int? {
        // The start itself counts: it opens the depth.
        if visit(start, unit(start)) { return start }
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        var scanned = 0
        var position = forward ? start + 1 : start
        while scanned < limit {
            let range: NSRange
            if forward {
                guard position < length else { return nil }
                range = NSRange(location: position, length: min(chunk, length - position, limit - scanned))
            } else {
                guard position > 0 else { return nil }
                let count = min(chunk, position, limit - scanned)
                range = NSRange(location: position - count, length: count)
            }
            text.getCharacters(&buffer, range: range)
            if forward {
                for k in 0..<range.length where visit(range.location + k, buffer[k]) { return range.location + k }
                position += range.length
            } else {
                for k in stride(from: range.length - 1, through: 0, by: -1) where visit(range.location + k, buffer[k]) { return range.location + k }
                position -= range.length
            }
            scanned += range.length
        }
        return nil
    }
}
