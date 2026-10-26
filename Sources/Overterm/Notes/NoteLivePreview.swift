import AppKit

extension NSAttributedString.Key {
    /// Markup Live Preview hides: no glyph is drawn for it (EditorLineHeight).
    static let noteHidden = NSAttributedString.Key("OvertermNoteHidden")
    /// What Live Preview draws over the text there (`NoteDecoration`).
    static let noteDecoration = NSAttributedString.Key("OvertermNoteDecoration")
    /// A link's target as written, followed on a click (`md:` before a
    /// Markdown link's path).
    static let noteLink = NSAttributedString.Key("OvertermNoteLink")
    /// A URL, opened on a click.
    static let noteURL = NSAttributedString.Key("OvertermNoteURL")
}

/// What Live Preview draws in place of markup.
enum NoteDecoration: Equatable {
    /// A task's box — over its `[ ]`, ticked or not.
    case checkbox(done: Bool)
    /// A list's `-`, as a dot.
    case bullet
    /// A quote's (or callout's) bar down its left.
    case quote
    /// `---` as a line across.
    case rule
    /// A fenced code block's lines, on a surface.
    case code
}

/// Obsidian's Live Preview, as attributes on the note's own text: headings
/// sized, emphasis, links and tags styled, and the markup — `**`, `[[`,
/// `# `, `- [ ] ` — hidden on every line but the ones being edited, where
/// it shows as typed. Nothing is inserted: the text stays the file. Pure:
/// text and lines in, attribute runs out.
struct NoteLivePreview {
    struct Fonts {
        var body: NSFont
        var mono: NSFont

        func heading(_ level: Int) -> NSFont {
            let scale: [CGFloat] = [1.75, 1.45, 1.25, 1.12, 1.0, 1.0]
            return NSFont.systemFont(ofSize: (body.pointSize * scale[min(max(level, 1), 6) - 1]).rounded(), weight: .bold)
        }
    }

    struct Colors {
        var text: NSColor
        var muted: NSColor
        var accent: NSColor
        var mark: NSColor
        var code: NSColor
        var heading: NSColor
    }

    typealias Run = (range: NSRange, attributes: [NSAttributedString.Key: Any])

    let fonts: Fonts
    let colors: Colors

    /// The runs for the lines in `range` (whole lines), the markup shown on
    /// the lines `editing` touches. The first run is the base over all of it.
    /// `blocks` are the note's (`blocks(in:)`), worked out once per edit.
    func runs(in text: NSString, range: NSRange, editing: [NSRange], blocks: [Block]) -> [Run] {
        var runs: [Run] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        runs.append((range, [.font: fonts.body, .foregroundColor: colors.text, .paragraphStyle: paragraph]))
        var location = range.location
        while location < NSMaxRange(range) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(line) }
            let content = NSRange(location: line.location, length: Self.contentLength(text, line))
            // The line the caret is on (or a selection touches) shows its markup.
            let shows = editing.contains { $0.location <= NSMaxRange(content) && NSMaxRange($0) >= line.location }
            if let block = blocks.first(where: { NSLocationInRange(line.location, $0.range) }) {
                style(block: block, line: content, in: text, shows: shows, into: &runs)
                continue
            }
            styleLine(content, in: text, shows: shows, into: &runs)
        }
        return runs
    }

    // MARK: Blocks: frontmatter and fenced code

    struct Block: Equatable {
        enum Kind { case frontmatter, code }
        var kind: Kind
        var range: NSRange
    }

    static func blocks(in text: NSString) -> [Block] {
        var blocks: [Block] = []
        if let front = NoteParser.parse(text.length > 20_000 ? text.substring(to: min(text.length, 20_000)) : text as String).frontmatterRange {
            blocks.append(Block(kind: .frontmatter, range: front))
        }
        let start = blocks.first.map { NSMaxRange($0.range) } ?? 0
        for range in NoteParser.codeRanges(in: text, from: start) {
            // Fenced blocks only: they start a line with ``` or ~~~.
            let first = text.substring(with: NSRange(location: range.location, length: min(3, range.length)))
            if first == "```" || first == "~~~" { blocks.append(Block(kind: .code, range: range)) }
        }
        return blocks
    }

    private func style(block: Block, line: NSRange, in text: NSString, shows: Bool, into runs: inout [Run]) {
        switch block.kind {
        case .frontmatter:
            runs.append((line, [.font: fonts.mono, .foregroundColor: colors.muted]))
        case .code:
            let isFence =
                text.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("```")
                || text.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("~~~")
            var attributes: [NSAttributedString.Key: Any] = [.font: fonts.mono, .foregroundColor: colors.code, .noteDecoration: NoteDecoration.code]
            if isFence { attributes[.foregroundColor] = colors.muted }
            runs.append((NSRange(location: line.location, length: max(line.length, 0)), attributes))
        }
    }

    // MARK: A line

    private static let cache = RegexCache()

    private func regex(_ pattern: String) -> NSRegularExpression? { Self.cache.regex(pattern, []) }

    private func styleLine(_ line: NSRange, in text: NSString, shows: Bool, into runs: inout [Run]) {
        guard line.length > 0 else { return }
        let string = text.substring(with: line)
        func at(_ local: NSRange) -> NSRange { NSRange(location: line.location + local.location, length: local.length) }
        func hide(_ local: NSRange) {
            guard local.length > 0, !shows else { return }
            runs.append((at(local), [.noteHidden: true]))
        }
        var inlineStart = 0
        // Headings: `## ` hidden, the text sized.
        if let m = regex(#"^(#{1,6})([ \t]+)"#)?.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
            let level = m.range(at: 1).length
            runs.append((line, [.font: fonts.heading(level), .foregroundColor: colors.heading]))
            if shows { runs.append((at(m.range), [.foregroundColor: colors.muted])) }
            hide(m.range)
            inlineStart = m.range.length
        } else if let m = regex(#"^(?:[ \t]*>[ \t]?)+"#)?.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
            // Quotes and callouts: the `>`s hidden, a bar drawn.
            // In from the bar, wrapped lines too.
            let indented = NSMutableParagraphStyle()
            indented.firstLineHeadIndent = 14
            indented.headIndent = 14
            indented.lineBreakMode = .byWordWrapping
            runs.append((line, [.noteDecoration: NoteDecoration.quote, .foregroundColor: colors.text.withAlphaComponent(0.85), .paragraphStyle: indented]))
            if shows { runs.append((at(m.range), [.foregroundColor: colors.muted])) }
            hide(m.range)
            inlineStart = m.range.length
            let rest = (string as NSString).substring(from: m.range.length)
            if let callout = regex(#"^\[!([\w-]+)\][+-]?[ \t]*"#)?.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                runs.append(
                    (
                        NSRange(location: line.location + m.range.length, length: line.length - m.range.length),
                        [.font: NSFont.systemFont(ofSize: fonts.body.pointSize, weight: .semibold), .foregroundColor: colors.accent]
                    ))
                hide(NSRange(location: m.range.length + callout.range.location, length: callout.range.length))
                inlineStart += callout.range.length
            }
        } else if let m = regex(#"^([ \t]*)([-*+])[ \t]+\[(.)\][ \t]"#)?.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
            // Tasks: `- [ ] ` becomes a box; done ones struck through.
            let status = (string as NSString).substring(with: m.range(at: 3))
            let done = status == "x" || status == "X"
            let box = NSRange(location: m.range(at: 2).location, length: m.range.length - m.range(at: 2).location)
            // The line being edited shows `- [ ]` as written and no box:
            // drawn over its own markup, the box doubled it up.
            if shows {
                runs.append((at(box), [.foregroundColor: colors.muted]))
            } else {
                runs.append((at(box), [.noteDecoration: NoteDecoration.checkbox(done: done), .foregroundColor: NSColor.clear]))
            }
            if done {
                let body = NSRange(location: m.range.length, length: line.length - m.range.length)
                runs.append((at(body), [.foregroundColor: colors.muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
            }
            inlineStart = m.range.length
        } else if let m = regex(#"^([ \t]*)([-*+])[ \t]"#)?.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
            // Likewise a bullet: its `-` while edited, the dot otherwise.
            runs.append(
                (at(m.range(at: 2)), shows ? [.foregroundColor: colors.muted] : [.noteDecoration: NoteDecoration.bullet, .foregroundColor: NSColor.clear]))
            inlineStart = m.range.length
        } else if let m = regex(#"^([ \t]*)(\d+[.)])[ \t]"#)?.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) {
            runs.append((at(m.range(at: 2)), [.foregroundColor: colors.muted]))
            inlineStart = m.range.length
        } else if regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)?.firstMatch(in: string, range: NSRange(location: 0, length: line.length)) != nil {
            runs.append((line, [.noteDecoration: NoteDecoration.rule, .foregroundColor: shows ? colors.muted : NSColor.clear]))
            return
        }
        styleInline(line, from: inlineStart, string: string, shows: shows, into: &runs)
    }

    // MARK: Inline

    private func styleInline(_ line: NSRange, from start: Int, string: String, shows: Bool, into runs: inout [Run]) {
        let ns = string as NSString
        let all = NSRange(location: start, length: ns.length - start)
        guard all.length > 0 else { return }
        func at(_ local: NSRange) -> NSRange { NSRange(location: line.location + local.location, length: local.length) }
        var taken = IndexSet()
        func free(_ range: NSRange) -> Bool { !taken.intersects(integersIn: range.location..<NSMaxRange(range)) }
        func take(_ range: NSRange) { taken.insert(integersIn: range.location..<NSMaxRange(range)) }
        func hide(_ local: NSRange) {
            guard local.length > 0 else { return }
            runs.append((at(local), shows ? [.foregroundColor: colors.muted] : [.noteHidden: true]))
        }
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            regex(pattern)?.enumerateMatches(in: string, range: all) { m, _, _ in
                if let m, free(m.range) { body(m) }
            }
        }
        // Code first: nothing inside it is markup.
        each(#"(`+)([^`]+?)\1"#) { m in
            runs.append((at(m.range(at: 2)), [.font: fonts.mono, .foregroundColor: colors.code, .backgroundColor: colors.mark.withAlphaComponent(0.12)]))
            hide(m.range(at: 1))
            hide(NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length))
            take(m.range)
        }
        // Comments: hidden, as Obsidian does, but where they're being edited.
        each(#"%%.*?%%"#) { m in
            runs.append((at(m.range), shows ? [.foregroundColor: colors.muted] : [.noteHidden: true]))
            take(m.range)
        }
        // Embeds: shown as written, dimmed (the reading view draws them).
        each(#"!\[\[[^\[\]\n]+?\]\]"#) { m in
            runs.append((at(m.range), [.foregroundColor: colors.muted]))
            take(m.range)
        }
        // [[target|alias]]: the alias (or the target) as a link.
        each(#"\[\[([^\[\]\|\n]+?)(?:(\\?\|)([^\[\]\n]+?))?\]\]"#) { m in
            let target = ns.substring(with: m.range(at: 1))
            let shown = m.range(at: 3).location != NSNotFound ? m.range(at: 3) : m.range(at: 1)
            runs.append((at(shown), [.foregroundColor: colors.accent, .noteLink: target, .cursor: NSCursor.pointingHand]))
            hide(NSRange(location: m.range.location, length: shown.location - m.range.location))
            hide(NSRange(location: NSMaxRange(shown), length: NSMaxRange(m.range) - NSMaxRange(shown)))
            take(m.range)
        }
        // [text](url): the text as a link.
        each(#"(?<!!)\[([^\]\n]+)\]\(([^)\s]+)(?:\s[^)]*)?\)"#) { m in
            let destination = ns.substring(with: m.range(at: 2))
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: colors.accent]
            if destination.contains("://") || destination.hasPrefix("mailto:") {
                attributes[.noteURL] = destination
            } else {
                // A path from the note's folder, not a name: marked so.
                attributes[.noteLink] = "md:" + (destination.removingPercentEncoding ?? destination)
            }
            runs.append((at(m.range(at: 1)), attributes))
            hide(NSRange(location: m.range.location, length: 1))
            hide(NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
            take(m.range)
        }
        // Bare URLs.
        each(#"https?://[^\s<>()\[\]]+"#) { m in
            runs.append((at(m.range), [.foregroundColor: colors.accent, .noteURL: ns.substring(with: m.range)]))
            take(m.range)
        }
        each(#"(?:^|(?<=[\s(]))#([\p{L}\p{N}_/\-]*[\p{L}_/\-][\p{L}\p{N}_/\-]*)"#) { m in
            runs.append((at(m.range), [.foregroundColor: colors.accent, .backgroundColor: colors.accent.withAlphaComponent(0.12)]))
            take(m.range)
        }
        // Emphasis: the markers hidden, the text styled.
        func emphasis(_ pattern: String, marker: Int, _ attributes: [NSAttributedString.Key: Any]) {
            each(pattern) { m in
                runs.append((at(m.range), attributes))
                hide(NSRange(location: m.range.location, length: marker))
                hide(NSRange(location: NSMaxRange(m.range) - marker, length: marker))
                take(NSRange(location: m.range.location, length: marker))
                take(NSRange(location: NSMaxRange(m.range) - marker, length: marker))
            }
        }
        let bold = NSFontManager.shared.convert(fonts.body, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(fonts.body, toHaveTrait: .italicFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        emphasis(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#, marker: 3, [.font: boldItalic])
        emphasis(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, marker: 2, [.font: bold])
        emphasis(#"(?<![\*\w])(\*|_)(?=\S)([^\*_]+?)(?<=\S)\1(?![\*\w])"#, marker: 1, [.font: italic])
        emphasis(#"~~(?=\S)(.+?)(?<=\S)~~"#, marker: 2, [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: colors.muted])
        emphasis(#"==(?=\S)(.+?)(?<=\S)=="#, marker: 2, [.backgroundColor: colors.mark])
        each(#"(?<!\$)\$(?=\S)[^$\n]+?(?<=\S)\$(?!\$)"#) { m in
            runs.append((at(m.range), [.foregroundColor: colors.code, .font: italic]))
        }
    }

    /// A line's length without its newline.
    static func contentLength(_ text: NSString, _ line: NSRange) -> Int {
        var length = line.length
        while length > 0 {
            let c = text.character(at: line.location + length - 1)
            guard c == 0x0A || c == 0x0D else { break }
            length -= 1
        }
        return length
    }
}
