import Foundation

/// settings.json and keybindings.json as VS Code has them: JSON that may
/// hold comments and trailing commas (read as JSON5), edited by the app in
/// place — a value replaced on its own line — so what a person wrote by
/// hand, comments and order included, stays.
enum SettingsJSON {
    struct ParseError: Error, Equatable {
        let message: String
    }

    /// The file's top-level object; an empty or blank file is an empty one.
    static func object(from text: String) throws(ParseError) -> [String: Any] {
        guard let value = try parse(text) else { return [:] }
        guard let object = value as? [String: Any] else { throw ParseError(message: "settings.json must hold one object: { … }") }
        return object
    }

    /// The file's top-level array (keybindings.json); blank is empty.
    static func array(from text: String) throws(ParseError) -> [Any] {
        guard let value = try parse(text) else { return [] }
        guard let array = value as? [Any] else { throw ParseError(message: "keybindings.json must hold one list: [ … ]") }
        return array
    }

    private static func parse(_ text: String) throws(ParseError) -> Any? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !uncommented(text).isEmpty else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed, .fragmentsAllowed])
        } catch {
            let nsError = error as NSError
            let detail = nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? nsError.localizedDescription
            throw ParseError(message: detail)
        }
    }

    /// The text without comments or whitespace — to tell a file of only
    /// comments (empty) from one with content.
    private static func uncommented(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        var inString = false
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if inString {
                out.append(char)
                if char == "\\", next < text.endIndex {
                    out.append(text[next])
                    index = text.index(after: next)
                    continue
                }
                if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
                out.append(char)
            } else if char == "/", next < text.endIndex, text[next] == "/" {
                index = text[next...].firstIndex(of: "\n") ?? text.endIndex
                continue
            } else if char == "/", next < text.endIndex, text[next] == "*" {
                index = text[next...].range(of: "*/").map(\.upperBound) ?? text.endIndex
                continue
            } else if !char.isWhitespace {
                out.append(char)
            }
            index = next
        }
        return out
    }

    // MARK: Editing in place

    /// `text` with `key` set to `json` (a JSON value as text), or removed
    /// when `json` is nil. A key on a line of its own — as the app writes
    /// them, and as people do — is changed on that line; a new key goes
    /// before the closing brace. An object or a list a person wrote over
    /// several lines is written over several again, one of `members` (the
    /// new value's entries or items, `SettingValue.members`) a line, each
    /// with the comments it had — above it, after it on its line, inside
    /// it (moved above) —; an entry gone takes its comments with it, and
    /// those before the closing bracket stay there. Without `members` such
    /// a value becomes `json`'s one line. Nil when the text isn't laid out
    /// so (a one-line object, say): the caller rewrites the whole file instead.
    static func setting(_ text: String, key: String, json: String?, members: [(name: String, json: String)]? = nil) -> String? {
        var lines = text.components(separatedBy: "\n")
        let quotedKey = "\"" + key.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        // An existing entry: "key": value[,] [// comment]
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(quotedKey) }) {
            let line = lines[index]
            guard let colon = line.range(of: ":", range: line.range(of: quotedKey)!.upperBound..<line.endIndex) else { return nil }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = line[colon.upperBound...]
            var last = index
            let tail: String
            if let valueEnd = endOfValue(in: rest) {
                tail = String(rest[valueEnd...])  // ",", " // comment", …
            } else if let (endLine, end) = endOfValueOverLines(lines, from: index, after: colon.upperBound) {
                // An object or a list written over several lines by hand: those
                // lines become the value's one, every other line kept as it was.
                last = endLine
                tail = String(lines[endLine][end...])
                if json != nil, let members,
                    let written = overLines(lines, from: index, after: colon.upperBound, to: (endLine, end), head: indent + quotedKey + ": ", members: members, tail: tail)
                {
                    lines.replaceSubrange(index...last, with: written)
                    return lines.joined(separator: "\n")
                }
            } else {
                return nil
            }
            if let json {
                lines.replaceSubrange(index...last, with: [indent + quotedKey + ": " + json + tail])
            } else {
                lines.removeSubrange(index...last)
            }
            return lines.joined(separator: "\n")
        }
        guard let json else { return text }
        // A new entry, before the last closing brace.
        guard let closing = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("}") }) else { return nil }
        // The entry before it gets a comma, if it has none.
        if let previous = lines[..<closing].lastIndex(where: { !isBlankOrComment($0) }) {
            let trimmed = lines[previous].trimmingCharacters(in: .whitespaces)
            if trimmed != "{", !trimmed.hasSuffix("{") {
                guard let comma = commaPosition(in: lines[previous]) else { return nil }
                if lines[previous][..<comma].trimmingCharacters(in: .whitespaces).last != "," {
                    lines[previous].insert(",", at: comma)
                }
            }
        } else {
            return nil
        }
        let indent =
            lines[..<closing].last { !isBlankOrComment($0) && $0.trimmingCharacters(in: .whitespaces) != "{" }
            .map { String($0.prefix { $0 == " " || $0 == "\t" }) } ?? "  "
        lines.insert(indent + quotedKey + ": " + json, at: closing)
        return lines.joined(separator: "\n")
    }

    /// A whole file holding `values`, sorted — for a new file, or when the
    /// text can't be edited in place.
    static func text(of values: [String: SettingValue]) -> String {
        guard !values.isEmpty else { return "{\n}\n" }
        let lines = values.keys.sorted().map { "  \"\($0)\": \(values[$0]!.json)" }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*")
    }

    /// Where a scalar value starting after the colon ends: a string's
    /// closing quote, or the first comma, comment or space after a literal.
    private static func endOfValue(in rest: Substring) -> Substring.Index? {
        var index = rest.startIndex
        while index < rest.endIndex, rest[index] == " " || rest[index] == "\t" { index = rest.index(after: index) }
        guard index < rest.endIndex else { return nil }
        if rest[index] == "\"" {
            var i = rest.index(after: index)
            while i < rest.endIndex {
                if rest[i] == "\\" {
                    i = rest.index(i, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
                    continue
                }
                if rest[i] == "\"" { return rest.index(after: i) }
                i = rest.index(after: i)
            }
            return nil
        }
        // A list or an object on one line, as the app writes them: to the
        // bracket that closes it. Over several lines, `endOfValueOverLines` finds its end.
        if rest[index] == "[" || rest[index] == "{" {
            var i = rest.index(after: index)
            var depth = 1
            var inString = false
            while i < rest.endIndex {
                if inString, rest[i] == "\\" {
                    i = rest.index(i, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
                    continue
                }
                if rest[i] == "\"" { inString.toggle() }
                if !inString {
                    if rest[i] == "[" || rest[i] == "{" { depth += 1 }
                    if rest[i] == "]" || rest[i] == "}" {
                        depth -= 1
                        if depth == 0 { return rest.index(after: i) }
                    }
                }
                i = rest.index(after: i)
            }
            return nil
        }
        var i = index
        while i < rest.endIndex, !",/ \t".contains(rest[i]) { i = rest.index(after: i) }
        return i
    }

    /// Where an object or a list that opens after the colon on `lines[start]`
    /// closes, over the lines after it: its line, and the index just past
    /// its closing bracket. Strings and comments are passed over. Nil when
    /// the value isn't one, or never closes.
    private static func endOfValueOverLines(_ lines: [String], from start: Int, after colon: String.Index) -> (Int, String.Index)? {
        var depth = 0
        var inString = false
        var inBlockComment = false
        for lineIndex in start..<lines.count {
            let line = lines[lineIndex]
            var i = lineIndex == start ? colon : line.startIndex
            if lineIndex == start {
                // The value must open on the key's line.
                while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
                guard i < line.endIndex, line[i] == "{" || line[i] == "[" else { return nil }
            }
            while i < line.endIndex {
                let char = line[i]
                let next = line.index(after: i)
                if inBlockComment {
                    if char == "*", next < line.endIndex, line[next] == "/" {
                        inBlockComment = false
                        i = line.index(after: next)
                        continue
                    }
                } else if inString {
                    if char == "\\" {
                        i = line.index(i, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                        continue
                    }
                    if char == "\"" { inString = false }
                } else if char == "\"" {
                    inString = true
                } else if char == "/", next < line.endIndex, line[next] == "/" {
                    break
                } else if char == "/", next < line.endIndex, line[next] == "*" {
                    inBlockComment = true
                    i = line.index(after: next)
                    continue
                } else if char == "{" || char == "[" {
                    depth += 1
                } else if char == "}" || char == "]" {
                    depth -= 1
                    if depth == 0 { return (lineIndex, next) }
                }
                i = next
            }
        }
        return nil
    }

    /// A value written over several lines (`lines[start]` after `colon` to
    /// `end`, just past its closing bracket), rewritten as `head` and its
    /// opening bracket, then `members` one a line — each with the comments
    /// the member of its name had —, the comments before the closing
    /// bracket, and the bracket with `tail`. Nil when its members can't be
    /// told apart (the caller then writes it on one line).
    private static func overLines(
        _ lines: [String], from start: Int, after colon: String.Index, to end: (line: Int, index: String.Index), head: String,
        members: [(name: String, json: String)], tail: String
    ) -> [String]? {
        struct Old {
            let name: String
            var comments: [String] = []
            var trailing: [String] = []
        }
        var olds: [Old] = []
        var header: [String] = []
        var pending: [String] = []
        var memberIndent: String?
        var opener: Character?
        var depth = 0
        var inString = false
        var capturing: String.Index?
        var expecting = true
        var lastContentLine = -1
        var block: (text: String, line: Int)?

        func route(_ comment: String, line: Int) {
            if depth > 0, !olds.isEmpty {
                olds[olds.count - 1].comments.append(comment)  // inside an entry: kept above it
            } else if olds.isEmpty, line == start {
                header.append(comment)
            } else if !olds.isEmpty, lastContentLine == line {
                olds[olds.count - 1].trailing.append(comment)
            } else {
                pending.append(comment)
            }
        }

        for lineIndex in start...end.line {
            let line = lines[lineIndex]
            var i = lineIndex == start ? colon : line.startIndex
            if lineIndex == start {
                while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
                guard i < line.endIndex, line[i] == "{" || line[i] == "[" else { return nil }
                opener = line[i]
                i = line.index(after: i)
            }
            // The closing bracket itself isn't read.
            let limit = lineIndex == end.line ? line.index(before: end.index) : line.endIndex
            if var open = block {
                open.text += "\n"
                block = open
            }
            while i < limit {
                let char = line[i]
                let next = line.index(after: i)
                if var open = block {
                    if char == "*", next < line.endIndex, line[next] == "/" {
                        open.text += "*/"
                        block = nil
                        route(open.text, line: open.line)
                        i = line.index(after: next)
                        continue
                    }
                    open.text.append(char)
                    block = open
                } else if inString {
                    if char == "\\" {
                        i = line.index(i, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                        continue
                    }
                    if char == "\"" {
                        inString = false
                        lastContentLine = lineIndex
                        if let from = capturing {
                            capturing = nil
                            let raw = "\"" + line[from..<i] + "\""
                            guard let name = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed) as? String else {
                                return nil
                            }
                            olds.append(Old(name: name, comments: pending))
                            pending = []
                            expecting = false
                        }
                    }
                } else if char == "/", next < line.endIndex, line[next] == "/" {
                    var comment = String(line[i..<line.endIndex])
                    while comment.last?.isWhitespace == true { comment.removeLast() }
                    route(comment, line: lineIndex)
                    break
                } else if char == "/", next < line.endIndex, line[next] == "*" {
                    block = ("/*", lineIndex)
                    i = line.index(after: next)
                    continue
                } else if char == "\"" {
                    inString = true
                    if depth == 0, expecting {
                        capturing = next
                        if memberIndent == nil, line[..<i].allSatisfy({ $0 == " " || $0 == "\t" }) { memberIndent = String(line[..<i]) }
                    }
                } else if char == "{" || char == "[" {
                    depth += 1
                    lastContentLine = lineIndex
                } else if char == "}" || char == "]" {
                    depth -= 1
                    lastContentLine = lineIndex
                } else if char == ",", depth == 0 {
                    expecting = true
                    lastContentLine = lineIndex
                } else if !char.isWhitespace {
                    lastContentLine = lineIndex
                }
                i = next
            }
        }
        guard let opener, block == nil, !inString else { return nil }
        let closer: Character = opener == "{" ? "}" : "]"
        let indent = String(head.prefix { $0 == " " || $0 == "\t" })
        let inner = memberIndent ?? indent + "  "
        let closing = pending
        if members.isEmpty, header.isEmpty, closing.isEmpty { return [head + String(opener) + String(closer) + tail] }
        var out = [head + String(opener) + (header.isEmpty ? "" : " " + header.joined(separator: " "))]
        for (n, member) in members.enumerated() {
            let old = olds.first { $0.name == member.name }
            for comment in old?.comments ?? [] { out.append(inner + comment) }
            var line = inner + member.json + (n < members.count - 1 ? "," : "")
            if let trailing = old?.trailing, !trailing.isEmpty { line += " " + trailing.joined(separator: " ") }
            out.append(line)
        }
        for comment in closing { out.append(inner + comment) }
        out.append(indent + String(closer) + tail)
        return out
    }

    /// Where a comma goes on a value's line: after the value, before any
    /// trailing comment.
    private static func commaPosition(in line: String) -> String.Index? {
        var inString = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\\" && inString {
                index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString, char == "/", line.index(after: index) < line.endIndex, line[line.index(after: index)] == "/" {
                var end = index
                while end > line.startIndex, line[line.index(before: end)] == " " { end = line.index(before: end) }
                return end
            }
            index = line.index(after: index)
        }
        var end = line.endIndex
        while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
        return end
    }
}
