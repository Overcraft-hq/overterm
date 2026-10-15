import Foundation

/// A syntax token in one diff line: a UTF-16 range in the line's text.
struct DiffToken: Equatable {
    let range: NSRange
    let kind: SyntaxHighlighter.Kind
}

/// How a diff line is drawn besides its text and its green/red tint.
struct DiffLineStyle: Equatable {
    /// Syntax colours: in order, not overlapping, UTF-16 in the line's text.
    var tokens: [DiffToken] = []
    /// The part that changed against the line it is paired with — a removed
    /// line's against the added line that replaced it, and back — UTF-16,
    /// whole characters. nil: unpaired, too unlike its pair to say, or the
    /// side of an insertion (or deletion) with nothing of its own.
    var changed: NSRange?

    var isEmpty: Bool { tokens.isEmpty && changed == nil }
}

/// What makes a diff read like code, as the Claude Code desktop app shows
/// one: syntax colours, and in a line that was edited rather than replaced
/// the part that changed. Worked out once per file as its diff loads
/// (`DiffModel.FileDiff`, off the main thread), never while drawing.
enum DiffHighlight {
    /// A removed and an added line sharing less than this (percent of the
    /// longer, in characters) were replaced, not edited: no mark.
    static let minSharedPercent = 40
    /// Lines longer than this (UTF-16) aren't compared: minified code, where
    /// a mark says nothing.
    static let maxComparedLength = 10_000
    /// A hunk side longer than this (UTF-16) isn't tokenized — the editor's
    /// limit (SyntaxHighlighter.maxLength).
    static let maxTokenizedLength = SyntaxHighlighter.maxLength

    /// Each line's style, by `DiffLine.id`; lines with nothing to draw are
    /// left out. `language` nil (a file the highlighter doesn't know): no
    /// colours, changed parts still.
    static func styles(for lines: [DiffLine], language: SyntaxHighlighter.Language?) -> [Int: DiffLineStyle] {
        var styles: [Int: DiffLineStyle] = [:]
        if let language {
            for (index, tokens) in syntaxTokens(for: lines, language: language) {
                styles[lines[index].id, default: DiffLineStyle()].tokens = tokens
            }
        }
        for (removed, added) in pairs(in: lines) {
            let old = lines[removed].text
            let new = lines[added].text
            guard old.utf16.count <= maxComparedLength, new.utf16.count <= maxComparedLength,
                let ranges = changedRanges(old: old, new: new)
            else { continue }
            if ranges.old.length > 0 { styles[lines[removed].id, default: DiffLineStyle()].changed = ranges.old }
            if ranges.new.length > 0 { styles[lines[added].id, default: DiffLineStyle()].changed = ranges.new }
        }
        return styles
    }

    // MARK: Syntax colours

    /// Tokens per line (by index in `lines`). Each hunk has two sides, each
    /// tokenized as one text: the old (context and removed lines) and the
    /// new (context and added lines) — a comment or string spanning lines is
    /// one token, as in the file. Context lines take the new side's: they
    /// read as the file does now.
    static func syntaxTokens(for lines: [DiffLine], language: SyntaxHighlighter.Language) -> [Int: [DiffToken]] {
        var tokens: [Int: [DiffToken]] = [:]
        var old: [Int] = []
        var new: [Int] = []
        var removals = false
        func endHunk() {
            // The old side only colours removed lines: none, no need to read it.
            if removals { tokenize(old, of: lines, language, into: &tokens) { lines[$0].kind == .removed } }
            tokenize(new, of: lines, language, into: &tokens) { _ in true }
            old = []
            new = []
            removals = false
        }
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .context:
                old.append(index)
                new.append(index)
            case .removed:
                old.append(index)
                removals = true
            case .added: new.append(index)
            // "\ No newline at end of file" ends a side, not the hunk.
            case .meta where line.text.hasPrefix("\\"): break
            case .hunk, .meta: endHunk()
            }
        }
        endHunk()
        return tokens
    }

    /// Tokenizes the lines at `indices` joined by newlines, and splits each
    /// token over the lines it covers; `keep` picks the lines to give them to.
    private static func tokenize(
        _ indices: [Int], of lines: [DiffLine], _ language: SyntaxHighlighter.Language, into tokens: inout [Int: [DiffToken]],
        keep: (Int) -> Bool
    ) {
        guard !indices.isEmpty else { return }
        // Where each line starts in the joined text, and how long it is.
        var starts: [Int] = []
        var lengths: [Int] = []
        starts.reserveCapacity(indices.count)
        lengths.reserveCapacity(indices.count)
        var offset = 0
        for index in indices {
            let length = lines[index].text.utf16.count
            starts.append(offset)
            lengths.append(length)
            offset += length + 1
        }
        guard offset - 1 <= maxTokenizedLength else { return }
        let text = indices.map { lines[$0].text }.joined(separator: "\n")
        // Tokens come in order and don't overlap: walk the lines along.
        var first = 0
        for (range, kind) in SyntaxHighlighter.tokens(in: text, language: language) {
            let end = NSMaxRange(range)
            while first + 1 < starts.count, starts[first + 1] <= range.location { first += 1 }
            var line = first
            while line < starts.count, starts[line] < end {
                let from = max(range.location, starts[line])
                let to = min(end, starts[line] + lengths[line])
                if to > from, keep(indices[line]) {
                    tokens[indices[line], default: []].append(DiffToken(range: NSRange(location: from - starts[line], length: to - from), kind: kind))
                }
                line += 1
            }
        }
    }

    // MARK: What changed in a line

    /// The removed and added lines to compare, by index in `lines`: in each
    /// hunk, a run of removed lines and the run of added lines right after
    /// it, paired in order (git writes a change as its removals, then its
    /// additions). What is left of the longer run has no pair.
    static func pairs(in lines: [DiffLine]) -> [(removed: Int, added: Int)] {
        var pairs: [(removed: Int, added: Int)] = []
        var removed: [Int] = []
        var added: [Int] = []
        func endRun() {
            pairs += zip(removed, added).map { (removed: $0, added: $1) }
            removed = []
            added = []
        }
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .removed:
                // Removals after additions start another change.
                if !added.isEmpty { endRun() }
                removed.append(index)
            case .added: added.append(index)
            // "\ No newline at end of file" may sit between the two runs.
            case .meta where line.text.hasPrefix("\\"): break
            case .context, .hunk, .meta: endRun()
            }
        }
        endRun()
        return pairs
    }

    /// What changed from `old` to `new`, as a UTF-16 range in each: what is
    /// left between their common prefix and common suffix. Both are counted
    /// in characters (grapheme clusters), so a range never cuts an emoji, a
    /// flag or a letter from its combining marks; characters are compared
    /// exactly (é written as one scalar or as e and an accent differ). nil
    /// when nothing changed, or the two share under `minSharedPercent` of
    /// the longer — a line replaced rather than edited, where a mark over
    /// nearly all of both would be noise.
    static func changedRanges(old: String, new: String) -> (old: NSRange, new: NSRange)? {
        let a = Array(old)
        let b = Array(new)
        let longest = max(a.count, b.count)
        var prefix = 0
        while prefix < a.count, prefix < b.count, same(a[prefix], b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, same(a[a.count - 1 - suffix], b[b.count - 1 - suffix]) { suffix += 1 }
        let shared = prefix + suffix
        guard shared < longest, shared * 100 >= longest * minSharedPercent else { return nil }
        return (range(of: a, prefix: prefix, suffix: suffix), range(of: b, prefix: prefix, suffix: suffix))
    }

    private static func same(_ a: Character, _ b: Character) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// The UTF-16 range of `characters` between the first `prefix` and the
    /// last `suffix`.
    private static func range(of characters: [Character], prefix: Int, suffix: Int) -> NSRange {
        let location = characters[..<prefix].reduce(0) { $0 + $1.utf16.count }
        let length = characters[prefix..<(characters.count - suffix)].reduce(0) { $0 + $1.utf16.count }
        return NSRange(location: location, length: length)
    }
}
