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
    /// before the closing brace. Nil when the text isn't laid out so (a
    /// one-line object, say): the caller rewrites the whole file instead.
    static func setting(_ text: String, key: String, json: String?) -> String? {
        var lines = text.components(separatedBy: "\n")
        let quotedKey = "\"" + key.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        // An existing entry: "key": value[,] [// comment]
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(quotedKey) }) {
            let line = lines[index]
            guard let colon = line.range(of: ":", range: line.range(of: quotedKey)!.upperBound..<line.endIndex) else { return nil }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = line[colon.upperBound...]
            guard let valueEnd = endOfValue(in: rest) else { return nil }
            let tail = String(rest[valueEnd...])  // ",", " // comment", …
            if let json {
                lines[index] = indent + quotedKey + ": " + json + tail
            } else {
                lines.remove(at: index)
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
        // A list on one line, as the app writes them: to its closing bracket.
        if rest[index] == "[" {
            var i = rest.index(after: index)
            var inString = false
            while i < rest.endIndex {
                if inString, rest[i] == "\\" {
                    i = rest.index(i, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
                    continue
                }
                if rest[i] == "\"" { inString.toggle() }
                if !inString, rest[i] == "]" { return rest.index(after: i) }
                i = rest.index(after: i)
            }
            return nil
        }
        // Objects, and lists over several lines, aren't edited in place.
        if rest[index] == "{" { return nil }
        var i = index
        while i < rest.endIndex, !",/ \t".contains(rest[i]) { i = rest.index(after: i) }
        return i
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
