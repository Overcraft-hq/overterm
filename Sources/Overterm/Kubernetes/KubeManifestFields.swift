import Foundation

/// A manifest's keys as the editor needs them for the cluster's docs
/// (3.15): each key's path through its object (`spec`, `template`, `spec`,
/// `containers`, `[]`, `image`), the document's apiVersion and kind, where
/// a key typed at the caret would go, and the keys the docs don't know.
/// A line scan, not a YAML parser: block maps and lists, `- ` items, quoted
/// keys, comments, block scalars and flow values skipped. Pure, bounded.
enum KubeManifestFields {
    struct Key: Equatable {
        var name: String
        /// Its path, itself last.
        var path: [String]
        /// The key's own characters (UTF-16).
        var range: NSRange
        var line: Int
        /// The line of what holds it (a key, or a `- ` item); -1 at the top.
        var holder: Int
        /// Its value on the line, when it has one.
        var value: String?
    }

    struct Document: Equatable {
        /// Its lines' characters, `---` excluded.
        var range: NSRange
        var keys: [Key]
        var apiVersion: String?
        var kind: String?

        var gvk: KubeGVK? { apiVersion.flatMap { api in kind.flatMap { KubeGVK(apiVersion: api, kind: $0) } } }
    }

    /// Where a key typed at the caret goes.
    struct Slot: Equatable {
        var document: Document
        /// The path of what will hold it.
        var parent: [String]
        /// The word typed so far, and its characters.
        var prefix: String
        var prefixRange: NSRange
        /// The keys already there beside it.
        var siblings: Set<String>
        /// Nothing follows the caret on its line: `name: ` can be inserted whole.
        var atLineEnd: Bool
    }

    /// Larger texts aren't scanned: no docs, no marks.
    static let maxLength = 2 << 20
    static let maxLines = 50_000

    private struct Entry {
        var indent: Int
        var segment: String
        var isItem: Bool
        var line: Int
    }

    private struct Line {
        var start: Int
        var chars: [UInt16]
    }

    private static func lines(_ text: NSString) -> [Line]? {
        guard text.length <= maxLength else { return nil }
        var lines: [Line] = []
        var start = 0
        let length = text.length
        var buffer = [UInt16](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&buffer, range: NSRange(location: 0, length: length)) }
        var index = 0
        while index <= length {
            if index == length || buffer[index] == 10 {
                var end = index
                if end > start, buffer[end - 1] == 13 { end -= 1 }
                lines.append(Line(start: start, chars: Array(buffer[start..<end])))
                guard lines.count <= maxLines else { return nil }
                start = index + 1
            }
            index += 1
        }
        return lines
    }

    private static let space: UInt16 = 32
    private static let dash: UInt16 = 45
    private static let colon: UInt16 = 58
    private static let hash: UInt16 = 35

    private static func isSeparator(_ chars: [UInt16]) -> Bool {
        let text = String(decoding: chars, as: UTF16.self)
        return text == "---" || text.hasPrefix("--- ") || text == "..." || text.hasPrefix("---\t")
    }

    /// A key at the start of `chars[from...]`: its name, where it ends
    /// (the colon) and its value; nil when the content isn't a key.
    private static func key(in chars: [UInt16], from: Int) -> (name: String, start: Int, end: Int, value: String)? {
        guard from < chars.count else { return nil }
        let first = chars[from]
        var nameStart = from
        var nameEnd: Int
        var colonAt: Int
        if first == 34 || first == 39 {  // " or '
            guard let close = chars[(from + 1)...].firstIndex(of: first) else { return nil }
            nameStart = from + 1
            nameEnd = close
            var at = close + 1
            while at < chars.count, chars[at] == space { at += 1 }
            guard at < chars.count, chars[at] == colon else { return nil }
            colonAt = at
        } else {
            if "#{[&*!|>%@`,?".utf16.contains(first) { return nil }
            var at = from
            colonAt = -1
            while at < chars.count {
                if chars[at] == hash, at > from, chars[at - 1] == space { return nil }
                if chars[at] == colon, at + 1 == chars.count || chars[at + 1] == space || chars[at + 1] == 9 {
                    colonAt = at
                    break
                }
                at += 1
            }
            guard colonAt > from else { return nil }
            nameEnd = colonAt
            while nameEnd > nameStart, chars[nameEnd - 1] == space { nameEnd -= 1 }
        }
        guard nameEnd > nameStart else { return nil }
        let name = String(decoding: chars[nameStart..<nameEnd], as: UTF16.self)
        var value = String(decoding: chars[(colonAt + 1)...], as: UTF16.self)
        if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
        if value.hasPrefix("#") { value = "" }
        return (name, nameStart, nameEnd, value.trimmingCharacters(in: .whitespaces))
    }

    private static func scalar(_ value: String) -> String {
        var text = value
        if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first { text = String(text.dropFirst().dropLast()) }
        return text
    }

    /// Whether a value opens lines of its own that hold no keys: a block
    /// scalar (`|`, `>`), a flow collection not closed on its line.
    private static func opensText(_ value: String) -> Bool {
        if value.hasPrefix("|") || value.hasPrefix(">") { return true }
        guard let first = value.first, first == "[" || first == "{" else { return false }
        var depth = 0
        for character in value {
            if character == "[" || character == "{" { depth += 1 }
            if character == "]" || character == "}" { depth -= 1 }
        }
        return depth > 0
    }

    /// The manifest's documents and their keys.
    static func documents(_ text: NSString) -> [Document] {
        guard let lines = lines(text) else { return [] }
        return scan(lines, upTo: nil).documents
    }

    private struct Scan {
        var documents: [Document] = []
        /// The stack as it stood after the line before `upTo`, its document's keys so far.
        var stack: [Entry] = []
        var current = Document(range: NSRange(location: 0, length: 0), keys: [])
        /// Lines indented past this are a block scalar's or a flow value's text.
        var textUnder: Int?
    }

    private static func scan(_ lines: [Line], upTo stop: Int?) -> Scan {
        var scan = Scan()
        var stack: [Entry] = []
        var current = Document(range: NSRange(location: lines.first?.start ?? 0, length: 0), keys: [])
        var textUnder: Int?
        func close(at end: Int) {
            current.range.length = max(0, end - current.range.location)
            scan.documents.append(current)
        }
        for (number, line) in lines.enumerated() {
            if let stop, number >= stop { break }
            let chars = line.chars
            var indent = 0
            while indent < chars.count, chars[indent] == space { indent += 1 }
            if indent == chars.count || chars[indent] == hash { continue }
            if let under = textUnder {
                if indent > under { continue }
                textUnder = nil
            }
            if indent == 0, isSeparator(chars) {
                close(at: line.start)
                current = Document(range: NSRange(location: line.start + chars.count + 1, length: 0), keys: [])
                stack = []
                continue
            }
            var column = indent
            while column < chars.count, chars[column] == dash, column + 1 == chars.count || chars[column + 1] == space {
                while let top = stack.last, top.indent > column || (top.indent == column && top.isItem) { stack.removeLast() }
                stack.append(Entry(indent: column, segment: "[]", isItem: true, line: number))
                column += 1
                while column < chars.count, chars[column] == space { column += 1 }
            }
            guard let found = key(in: chars, from: column) else { continue }
            while let top = stack.last, top.indent >= column { stack.removeLast() }
            let path = stack.map(\.segment) + [found.name]
            let range = NSRange(location: line.start + found.start, length: found.end - found.start)
            current.keys.append(
                Key(name: found.name, path: path, range: range, line: number, holder: stack.last?.line ?? -1, value: found.value.isEmpty ? nil : found.value))
            if path.count == 1, !found.value.isEmpty {
                if found.name == "apiVersion" { current.apiVersion = scalar(found.value) }
                if found.name == "kind" { current.kind = scalar(found.value) }
            }
            stack.append(Entry(indent: column, segment: found.name, isItem: false, line: number))
            if opensText(found.value) { textUnder = column }
        }
        scan.stack = stack
        scan.current = current
        scan.textUnder = textUnder
        if stop == nil { close(at: (lines.last.map { $0.start + $0.chars.count }) ?? 0) }
        return scan
    }

    /// The document and key at `offset`: the key's own characters, or its
    /// line's value.
    static func key(at offset: Int, in text: NSString) -> (document: Document, key: Key)? {
        for document in documents(text) where offset >= document.range.location && offset <= NSMaxRange(document.range) {
            let starts = document.keys.first { NSLocationInRange(offset, $0.range) || offset == NSMaxRange($0.range) }
            if let key = starts { return (document, key) }
            let line = text.lineRange(for: NSRange(location: min(offset, max(0, text.length - 1)), length: 0))
            if let key = document.keys.last(where: { NSLocationInRange($0.range.location, line) }) { return (document, key) }
        }
        return nil
    }

    /// Where a key typed at `caret` goes: nil unless the caret ends a word
    /// (perhaps empty) after the line's indent and any `- `.
    static func slot(at caret: Int, in text: NSString) -> Slot? {
        guard let lines = lines(text), caret <= text.length else { return nil }
        guard let number = lines.lastIndex(where: { $0.start <= caret }) else { return nil }
        let line = lines[number]
        let before = Array(line.chars.prefix(caret - line.start))
        var column = 0
        while column < before.count, before[column] == space { column += 1 }
        let indent = column
        var items: [Int] = []
        while column < before.count, before[column] == dash, column + 1 < before.count, before[column + 1] == space {
            items.append(column)
            column += 1
            while column < before.count, before[column] == space { column += 1 }
        }
        let word = before[column...]
        guard word.allSatisfy({ isWordUnit($0) }) else { return nil }
        let scan = scan(lines, upTo: number)
        var stack = scan.stack
        // Inside a block scalar's text, or a flow value's lines: no key goes there.
        if let under = scan.textUnder, indent > under { return nil }
        for item in items {
            while let top = stack.last, top.indent > item || (top.indent == item && top.isItem) { stack.removeLast() }
            stack.append(Entry(indent: item, segment: "[]", isItem: true, line: number))
        }
        while let top = stack.last, top.indent >= column { stack.removeLast() }
        let holder = stack.last?.line ?? -1
        // The document's keys after the caret's line too: the whole document's.
        let whole = documents(text).first { caret >= $0.range.location && caret <= NSMaxRange($0.range) } ?? scan.current
        let siblings = items.isEmpty ? Set(whole.keys.filter { $0.holder == holder && $0.line != number }.map(\.name)) : []
        let after = line.chars.dropFirst(caret - line.start)
        return Slot(
            document: whole, parent: stack.map(\.segment), prefix: String(decoding: Array(word), as: UTF16.self),
            prefixRange: NSRange(location: line.start + column, length: word.count), siblings: siblings,
            atLineEnd: after.allSatisfy { $0 == space })
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit == 45 || unit == 36
    }

    // MARK: Against the docs

    /// A key the cluster's docs don't know, said.
    struct Mark: Equatable {
        var range: NSRange
        var message: String
    }

    static let maxMarks = 200

    /// The keys `docs` has no field for, in every document whose kind it
    /// holds — a kind it doesn't serve marked on its `kind:`. `docs` gives
    /// the document for a kind as cached, and whose it is said; nil:
    /// nothing is said of that kind.
    static func marks(_ documents: [Document], docs: (KubeGVK) -> (document: KubeOpenAPIDocument, source: String)?) -> [Mark] {
        var marks: [Mark] = []
        for document in documents {
            guard let gvk = document.gvk, let (doc, source) = docs(gvk) else { continue }
            guard doc.root(for: gvk) != nil else {
                if let kind = document.keys.first(where: { $0.path == ["kind"] }) {
                    marks.append(Mark(range: kind.range, message: "\(source) serves no \(gvk.kind) at \(gvk.apiVersion)."))
                }
                continue
            }
            for key in document.keys where marks.count < maxMarks {
                if case .unknown(let index, let parent) = doc.lookup(gvk, key.path), index == key.path.count - 1 {
                    marks.append(Mark(range: key.range, message: "Unknown field \"\(key.name)\" in \(parent) — \(source) has no such field."))
                }
            }
        }
        return marks
    }

    /// The fields a key typed at `slot` could be: the holder's, less those
    /// already there, matching the word typed (case-insensitively, in order).
    static func candidates(_ slot: Slot, in doc: KubeOpenAPIDocument, gvk: KubeGVK) -> [KubeFieldSummary] {
        guard case .found(let holder) = doc.lookup(gvk, slot.parent) else { return [] }
        let typed = slot.prefix.lowercased()
        return holder.fields.filter { field in
            !slot.siblings.contains(field.name) && (typed.isEmpty || subsequence(typed, of: field.name.lowercased()))
        }
        .sorted { a, b in
            let aStarts = a.name.lowercased().hasPrefix(typed)
            let bStarts = b.name.lowercased().hasPrefix(typed)
            if aStarts != bStarts { return aStarts }
            if a.required != b.required { return a.required }
            return a.name < b.name
        }
    }

    private static func subsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = haystack[...]
        for character in needle {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}
