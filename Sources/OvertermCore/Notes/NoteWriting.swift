import Foundation

/// Writing Markdown in a note, as Obsidian helps with it: Return carries a
/// list, a task or a quote on — an empty item ends it — and a URL pasted
/// over a selection makes it a link. Pure.
package enum NoteWriting {
    private static let cache = RegexCache()

    /// `  - `, `* `, `1. `, `2) `, each with `[ ] ` after it for a task.
    private static let listPattern = #"^([ \t]*)(?:([-*+])|(\d{1,9})([.)]))([ \t]+)(\[[^\]\n]\][ \t]+)?"#
    /// `> `, `> > `.
    private static let quotePattern = #"^([ \t]*)((?:>[ \t]?)+)"#

    /// Return at the caret of a list, task or quote line: the next item
    /// begun — a number one more, a task's box empty — or, on an item with
    /// nothing written, the marker taken away and the list left. nil for any
    /// other line, a selection, or a caret before the marker or in a fence.
    package static func newline(in text: NSString, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let caret = selection.location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, [0x0A, 0x0D].contains(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let line = text.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        let column = caret - lineRange.location
        guard !inFence(text, before: lineRange.location) else { return nil }
        let eol = text.range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n"

        var prefix = 0
        var next = ""
        if let list = cache.regex(listPattern, []), let m = list.firstMatch(in: line, range: all) {
            prefix = m.range.length
            let indent = ns.substring(with: m.range(at: 1))
            let spacing = ns.substring(with: m.range(at: 5))
            let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
            if m.range(at: 2).location != NSNotFound {
                next = indent + ns.substring(with: m.range(at: 2)) + spacing + task
            } else {
                let number = (Int(ns.substring(with: m.range(at: 3))) ?? 0) + 1
                next = indent + "\(number)" + ns.substring(with: m.range(at: 4)) + spacing + task
            }
        } else if let quote = cache.regex(quotePattern, []), let m = quote.firstMatch(in: line, range: all) {
            prefix = m.range.length
            let marks = ns.substring(with: m.range(at: 2))
            next = ns.substring(with: m.range(at: 1)) + (marks.hasSuffix(" ") ? marks : marks + " ")
        } else {
            return nil
        }
        guard column >= prefix else { return nil }
        let rest = ns.substring(from: prefix).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            // An item with nothing in it: the list ends here, the line left empty.
            let change = TextChange(range: NSRange(location: lineRange.location, length: contentEnd - lineRange.location), replacement: "")
            return TextEdit(changes: [change], selections: [NSRange(location: lineRange.location, length: 0)])
        }
        let replacement = eol + next
        return TextEdit(
            changes: [TextChange(range: NSRange(location: caret, length: 0), replacement: replacement)],
            selections: [NSRange(location: caret + (replacement as NSString).length, length: 0)])
    }

    /// Whether `location` is inside a ``` or ~~~ fence: an odd number of
    /// fence lines before it.
    private static func inFence(_ text: NSString, before location: Int) -> Bool {
        var open: String?
        text.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let line = text.substring(with: range).trimmingCharacters(in: .whitespaces)
            for fence in ["```", "~~~"] where line.hasPrefix(fence) {
                if open == nil { open = fence } else if open == fence { open = nil }
            }
        }
        return open != nil
    }

    /// A URL pasted over a selection within one line: `[selection](url)`,
    /// the caret after it. nil when either isn't so.
    package static func linkPaste(_ pasted: String, over selection: NSRange, in text: NSString) -> TextEdit? {
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection.length > 0, NSMaxRange(selection) <= text.length,
            url.range(of: #"^https?://[^\s<>()\[\]]+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        else { return nil }
        let selected = text.substring(with: selection)
        guard !selected.contains("\n"), selected.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let link = "[\(selected)](\(url))"
        return TextEdit(
            changes: [TextChange(range: selection, replacement: link)],
            selections: [NSRange(location: selection.location + (link as NSString).length, length: 0)])
    }
}

/// `/` at the start of a line: what can be put there — headings, lists, a
/// callout, a fenced block (a runnable shell one), a table, a notes table,
/// the date. Pure.
package enum NoteSlashCommands {
    package struct Command: Equatable, Sendable {
        package var label: String
        /// The text put in place of `/query`; `$0` is where the caret goes.
        package var insert: String
        package var detail: String
        /// Other words it is found by.
        package var aliases: [String] = []
    }

    /// The commands, today's date and time in them.
    package static func all(now: Date = Date()) -> [Command] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        return [
            Command(label: "Heading 1", insert: "# $0", detail: "#", aliases: ["h1", "title"]),
            Command(label: "Heading 2", insert: "## $0", detail: "##", aliases: ["h2"]),
            Command(label: "Heading 3", insert: "### $0", detail: "###", aliases: ["h3"]),
            Command(label: "Task", insert: "- [ ] $0", detail: "- [ ]", aliases: ["todo", "checkbox"]),
            Command(label: "Bullet List", insert: "- $0", detail: "-", aliases: ["list", "ul"]),
            Command(label: "Numbered List", insert: "1. $0", detail: "1.", aliases: ["ol", "ordered"]),
            Command(label: "Quote", insert: "> $0", detail: ">", aliases: ["blockquote"]),
            Command(label: "Callout", insert: "> [!note] $0\n> ", detail: "> [!note]", aliases: ["admonition", "info", "warning", "tip"]),
            Command(label: "Code Block", insert: "```\n$0\n```", detail: "```", aliases: ["fence", "pre"]),
            Command(label: "Runnable Shell Block", insert: "```bash\n$0\n```", detail: "▶ Run in terminal", aliases: ["run", "bash", "shell", "runbook"]),
            Command(label: "Table", insert: "| $0 |  |\n| --- | --- |\n|  |  |", detail: "| |", aliases: ["grid"]),
            Command(
                label: "Notes Table", insert: "```dataview\nTABLE $0\nFROM \"\"\nSORT file.name ASC\n```", detail: "from properties",
                aliases: ["dataview", "query", "base", "properties"]),
            Command(label: "Divider", insert: "---\n$0", detail: "---", aliases: ["hr", "rule", "line"]),
            Command(label: "Link to Note", insert: "[[$0]]", detail: "[[ ]]", aliases: ["wikilink"]),
            Command(label: "Math Block", insert: "$$\n$0\n$$", detail: "$$", aliases: ["latex", "equation"]),
            Command(label: "Bold", insert: "**$0**", detail: "**", aliases: ["strong"]),
            Command(label: "Italic", insert: "_$0_", detail: "_", aliases: ["emphasis"]),
            Command(label: "Highlight", insert: "==$0==", detail: "==", aliases: ["mark"]),
            Command(label: "Strikethrough", insert: "~~$0~~", detail: "~~", aliases: ["strike"]),
            Command(label: "Today’s Date", insert: day.string(from: now) + "$0", detail: day.string(from: now), aliases: ["date", "today"]),
            Command(label: "Time", insert: time.string(from: now) + "$0", detail: time.string(from: now), aliases: ["now", "clock"]),
        ]
    }

    /// The commands a query finds: a label or alias starting with it first,
    /// then holding it. Every one for an empty query.
    package static func matching(_ query: String, now: Date = Date()) -> [Command] {
        let all = all(now: now)
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        func words(_ command: Command) -> [String] { [command.label.lowercased()] + command.aliases }
        let starts = all.filter { words($0).contains { $0.hasPrefix(q) || $0.split(separator: " ").contains { $0.hasPrefix(q) } } }
        let holds = all.filter { command in !starts.contains(command) && words(command).contains { $0.contains(q) } }
        return starts + holds
    }

    /// `insert` without its `$0`, and where the caret goes in it (UTF-16).
    package static func expand(_ insert: String) -> (text: String, caret: Int) {
        let ns = insert as NSString
        let marker = ns.range(of: "$0")
        guard marker.location != NSNotFound else { return (insert, ns.length) }
        return (ns.replacingCharacters(in: marker, with: ""), marker.location)
    }
}

/// A note's headings as folds: each one's line and what is under it, to the
/// next heading as high. Pure.
package enum NoteFolding {
    package struct Section: Equatable, Sendable {
        /// Its level, its text and which of the same it is: a fold kept
        /// across edits that don't touch the heading.
        package var key: String
        /// The heading's line, its line break too.
        package var heading: NSRange
        /// What folding it hides: the lines under it.
        package var body: NSRange
    }

    package static func sections(in text: NSString) -> [Section] {
        let headings = NoteParser.parse(text as String).headings
        var seen: [String: Int] = [:]
        var sections: [Section] = []
        for (index, heading) in headings.enumerated() {
            guard NSMaxRange(heading.range) <= text.length else { continue }
            let line = text.lineRange(for: NSRange(location: heading.range.location, length: 0))
            let end = headings[(index + 1)...].first { $0.level <= heading.level }.map { text.lineRange(for: NSRange(location: $0.range.location, length: 0)).location } ?? text.length
            let base = "\(heading.level)|\(heading.text)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            let body = NSRange(location: NSMaxRange(line), length: max(0, end - NSMaxRange(line)))
            guard body.length > 0 else { continue }
            sections.append(Section(key: "\(base)|\(count)", heading: line, body: body))
        }
        return sections
    }

    /// The section to fold for a caret: the one whose heading line it is
    /// on, else the nearest one it is under.
    package static func section(at caret: Int, in sections: [Section]) -> Section? {
        if let on = sections.first(where: { NSLocationInRange(caret, $0.heading) }) { return on }
        return sections.filter { NSLocationInRange(caret, $0.body) || caret == NSMaxRange($0.body) && caret > $0.body.location }
            .min { $0.body.length < $1.body.length }
    }
}

/// A runnable block in a note: a shell fence — `bash`, `sh`, `zsh`,
/// `shell`, `console` — as the command it runs. A `console` block's
/// commands are its `$ ` lines, the output between them left. Pure.
package enum NoteRunbook {
    package static let languages: Set<String> = ["bash", "sh", "zsh", "shell", "console", "shell-session"]

    /// The command of the fence that opens on `line` (zero-based, the
    /// file's); nil when no shell fence opens there.
    package static func command(in text: String, openingAt line: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return nil }
        return command(lines: lines, from: line)
    }

    /// The command of the shell fence the caret's line is in (or opens).
    package static func command(in text: String, around line: Int) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return nil }
        var open: (fence: String, at: Int)?
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let current = open {
                guard closes(trimmed, current.fence) else { continue }
                if line >= current.at && line <= index { return command(lines: lines, from: current.at) }
                open = nil
            } else if let marker = fenceMarker(trimmed) {
                if index > line { return nil }
                open = (marker, index)
            }
        }
        // A fence never closed runs to the end.
        if let current = open, line >= current.at { return command(lines: lines, from: current.at) }
        return nil
    }

    private static func closes(_ trimmed: String, _ fence: String) -> Bool {
        trimmed.hasPrefix(fence) && trimmed.allSatisfy { $0 == fence.first }
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for character in ["`", "~"] {
            let run = trimmed.prefix { String($0) == character }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func command(lines: [String], from line: Int) -> String? {
        let opening = lines[line].trimmingCharacters(in: .whitespaces)
        guard let fence = fenceMarker(opening) else { return nil }
        let language = opening.dropFirst(fence.count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.lowercased() } ?? ""
        guard languages.contains(language) else { return nil }
        var body: [String] = []
        for raw in lines[(line + 1)...] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if closes(trimmed, fence) { break }
            body.append(raw)
        }
        if language == "console" || language == "shell-session" {
            body = body.compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("$ ") { return String(trimmed.dropFirst(2)) }
                return nil
            }
        }
        let command = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
