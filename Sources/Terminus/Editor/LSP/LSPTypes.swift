import Foundation

/// The Language Server Protocol's shapes, as the editor wants them: what a
/// server may answer in several forms (a list or a CompletionList,
/// Locations or LocationLinks, three kinds of hover contents, nested or flat
/// symbols) comes out in one. Decoding is lenient — servers vary, and one
/// odd item drops that item, not the answer.
///
/// Positions are UTF-16 code units, which is what NSString and NSTextView
/// index by: an offset into the text view's string is an LSP character as is.
/// The client offers only "utf-16", so no server picks another.
enum LSP {
    struct Position: Codable, Hashable, Sendable, Comparable {
        var line: Int
        /// UTF-16 units from the start of the line.
        var character: Int

        init(line: Int, character: Int) {
            self.line = line
            self.character = character
        }

        static func < (a: Position, b: Position) -> Bool {
            a.line != b.line ? a.line < b.line : a.character < b.character
        }
    }

    struct Range: Codable, Hashable, Sendable {
        var start: Position
        var end: Position

        init(start: Position, end: Position) {
            self.start = start
            self.end = end
        }
    }

    /// A place in a file. Decodes a Location and a LocationLink alike (the
    /// link's selection range — the name, not the whole declaration).
    struct Location: Decodable, Hashable, Sendable {
        var url: URL
        var range: Range

        init(url: URL, range: Range) {
            self.url = url
            self.range = range
        }

        private enum Keys: String, CodingKey { case uri, range, targetUri, targetRange, targetSelectionRange }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let target = try container.decodeIfPresent(String.self, forKey: .targetUri) {
                url = try LSP.decodeURL(target, codingPath: decoder.codingPath)
                range =
                    try container.decodeIfPresent(Range.self, forKey: .targetSelectionRange)
                    ?? container.decode(Range.self, forKey: .targetRange)
            } else {
                url = try LSP.decodeURL(container.decode(String.self, forKey: .uri), codingPath: decoder.codingPath)
                range = try container.decode(Range.self, forKey: .range)
            }
        }
    }

    struct TextEdit: Codable, Hashable, Sendable {
        var range: Range
        var newText: String

        init(range: Range, newText: String) {
            self.range = range
            self.newText = newText
        }
    }

    struct Diagnostic: Decodable, Hashable, Sendable {
        enum Severity: Int, Sendable { case error = 1, warning, information, hint }

        var range: Range
        /// 1 error … 4 hint; nil when the server didn't say (treat as an error).
        var severity: Int?
        var message: String
        var source: String?
        /// Servers send numbers or strings; kept as a string either way.
        var code: String?

        var level: Severity { severity.flatMap(Severity.init(rawValue:)) ?? .error }

        init(range: Range, severity: Int?, message: String, source: String? = nil, code: String? = nil) {
            self.range = range
            self.severity = severity
            self.message = message
            self.source = source
            self.code = code
        }

        private enum Keys: String, CodingKey { case range, severity, message, source, code }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            range = try container.decode(Range.self, forKey: .range)
            severity = try? container.decodeIfPresent(Int.self, forKey: .severity)
            message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? ""
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            code = LSP.flexibleString(container, .code)
        }
    }

    struct CompletionItem: Decodable, Hashable, Sendable {
        var label: String
        /// LSP's CompletionItemKind (1 text, 2 method, 3 function, 6 variable, 7 class, 14 keyword, 15 snippet…).
        var kind: Int?
        var detail: String?
        /// Markdown (or plain text, which reads the same).
        var documentation: String?
        var insertText: String?
        /// 1 plain text, 2 snippet (`$1`, `${2:name}`, `$0`).
        var insertTextFormat: Int?
        /// What to replace and with what. An InsertReplaceEdit arrives as its
        /// insert range: the edit that doesn't eat the rest of the word.
        var textEdit: TextEdit?
        var additionalTextEdits: [TextEdit]
        var sortText: String?
        var filterText: String?

        var isSnippet: Bool { insertTextFormat == 2 }
        /// The text the item puts in: textEdit's, else insertText, else the label.
        var text: String { textEdit?.newText ?? insertText ?? label }

        init(
            label: String, kind: Int? = nil, detail: String? = nil, documentation: String? = nil, insertText: String? = nil,
            insertTextFormat: Int? = nil, textEdit: TextEdit? = nil, additionalTextEdits: [TextEdit] = [], sortText: String? = nil,
            filterText: String? = nil
        ) {
            self.label = label
            self.kind = kind
            self.detail = detail
            self.documentation = documentation
            self.insertText = insertText
            self.insertTextFormat = insertTextFormat
            self.textEdit = textEdit
            self.additionalTextEdits = additionalTextEdits
            self.sortText = sortText
            self.filterText = filterText
        }

        private enum Keys: String, CodingKey {
            case label, kind, detail, documentation, insertText, insertTextFormat, textEdit, additionalTextEdits, sortText, filterText
        }
        private enum EditKeys: String, CodingKey { case range, insert, newText }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            label = try container.decode(String.self, forKey: .label)
            kind = try? container.decodeIfPresent(Int.self, forKey: .kind)
            detail = try? container.decodeIfPresent(String.self, forKey: .detail)
            documentation = try? container.decodeIfPresent(Markup.self, forKey: .documentation)?.text
            insertText = try? container.decodeIfPresent(String.self, forKey: .insertText)
            insertTextFormat = try? container.decodeIfPresent(Int.self, forKey: .insertTextFormat)
            if let edit = try? container.nestedContainer(keyedBy: EditKeys.self, forKey: .textEdit),
                let newText = try? edit.decode(String.self, forKey: .newText),
                let range = (try? edit.decode(Range.self, forKey: .range)) ?? (try? edit.decode(Range.self, forKey: .insert))
            {
                textEdit = TextEdit(range: range, newText: newText)
            }
            additionalTextEdits = (try? container.decodeIfPresent([Lenient<TextEdit>].self, forKey: .additionalTextEdits))?.compactMap(\.value) ?? []
            sortText = try? container.decodeIfPresent(String.self, forKey: .sortText)
            filterText = try? container.decodeIfPresent(String.self, forKey: .filterText)
        }
    }

    /// A completion answer. `isIncomplete`: the server cut the list short,
    /// so typing further should ask again rather than filter this one.
    struct CompletionList: Decodable, Sendable {
        var items: [CompletionItem]
        var isIncomplete: Bool

        init(items: [CompletionItem], isIncomplete: Bool) {
            self.items = items
            self.isIncomplete = isIncomplete
        }

        private enum Keys: String, CodingKey { case items, isIncomplete }

        /// null, `CompletionItem[]` or `CompletionList`.
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self.init(items: [], isIncomplete: false)
            } else if let items = try? single.decode([Lenient<CompletionItem>].self) {
                self.init(items: items.compactMap(\.value), isIncomplete: false)
            } else {
                let container = try decoder.container(keyedBy: Keys.self)
                let items = (try? container.decodeIfPresent([Lenient<CompletionItem>].self, forKey: .items)) ?? nil
                self.init(
                    items: items?.compactMap(\.value) ?? [],
                    isIncomplete: (try? container.decodeIfPresent(Bool.self, forKey: .isIncomplete)) ?? false)
            }
        }
    }

    struct Hover: Decodable, Hashable, Sendable {
        /// Markdown; a MarkedString with a language becomes a fenced block.
        var contents: String
        var range: Range?

        init(contents: String, range: Range? = nil) {
            self.contents = contents
            self.range = range
        }

        private enum Keys: String, CodingKey { case contents, range }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            if let many = try? container.decode([Markup].self, forKey: .contents) {
                contents = many.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            } else {
                contents = (try? container.decode(Markup.self, forKey: .contents))?.text ?? ""
            }
            range = try? container.decodeIfPresent(Range.self, forKey: .range)
        }
    }

    /// A document's outline, flattened: DocumentSymbols depth-first with
    /// their nesting in `depth`, SymbolInformation (which has no nesting) at 0
    /// in document order.
    struct Symbol: Hashable, Sendable {
        var name: String
        /// LSP's SymbolKind (5 class, 6 method, 12 function, 13 variable, 23 struct…).
        var kind: Int
        var detail: String?
        /// The whole declaration.
        var range: Range
        /// The name — where to put the cursor.
        var selectionRange: Range
        var depth: Int

        init(name: String, kind: Int, detail: String? = nil, range: Range, selectionRange: Range, depth: Int) {
            self.name = name
            self.kind = kind
            self.detail = detail
            self.range = range
            self.selectionRange = selectionRange
            self.depth = depth
        }
    }

    // MARK: - Answers in more than one shape

    /// Definition / references: null, a Location, Location[] or LocationLink[].
    struct Locations: Decodable, Sendable {
        var items: [Location]

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                items = []
            } else if let many = try? single.decode([Lenient<Location>].self) {
                items = many.compactMap(\.value)
            } else {
                items = [try single.decode(Location.self)]
            }
        }
    }

    /// documentSymbol: DocumentSymbol[] or SymbolInformation[] (or null).
    struct Symbols: Decodable, Sendable {
        var items: [Symbol]

        private struct Raw: Decodable {
            var name: String
            var kind: Int
            var detail: String?
            var range: Range?
            var selectionRange: Range?
            var children: [Lenient<Raw>]?
            var location: Location?
        }

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            guard !single.decodeNil() else {
                items = []
                return
            }
            let raw = try single.decode([Lenient<Raw>].self).compactMap(\.value)
            var flat: [Symbol] = []
            var hierarchical = false
            func walk(_ symbols: [Raw], depth: Int) {
                for symbol in symbols {
                    if let range = symbol.range {
                        hierarchical = true
                        flat.append(
                            Symbol(
                                name: symbol.name, kind: symbol.kind, detail: symbol.detail, range: range,
                                selectionRange: symbol.selectionRange ?? range, depth: depth))
                        walk(symbol.children?.compactMap(\.value) ?? [], depth: depth + 1)
                    } else if let location = symbol.location {
                        flat.append(
                            Symbol(name: symbol.name, kind: symbol.kind, range: location.range, selectionRange: location.range, depth: 0))
                    }
                }
            }
            walk(raw, depth: 0)
            // SymbolInformation comes in whatever order the server keeps it.
            if !hierarchical { flat.sort { $0.range.start < $1.range.start } }
            items = flat
        }
    }

    struct PublishDiagnostics: Decodable, Sendable {
        var url: URL
        var version: Int?
        var diagnostics: [Diagnostic]

        private enum Keys: String, CodingKey { case uri, version, diagnostics }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            url = try LSP.decodeURL(container.decode(String.self, forKey: .uri), codingPath: decoder.codingPath)
            version = try? container.decodeIfPresent(Int.self, forKey: .version)
            diagnostics = (try? container.decode([Lenient<Diagnostic>].self, forKey: .diagnostics))?.compactMap(\.value) ?? []
        }
    }

    /// MarkedString (a string, or `{language, value}`) or MarkupContent
    /// (`{kind, value}`), as markdown.
    struct Markup: Decodable {
        var text: String

        private enum Keys: String, CodingKey { case language, value, kind }

        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                text = string
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            let value = (try? container.decode(String.self, forKey: .value)) ?? ""
            if let language = try? container.decode(String.self, forKey: .language), !value.isEmpty {
                text = "```\(language)\n\(value)\n```"
            } else {
                text = value
            }
        }
    }

    /// Decodes to nil instead of failing, so one item a server got wrong
    /// doesn't lose the rest of an array.
    struct Lenient<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    fileprivate static func flexibleString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? container.decodeIfPresent(Int.self, forKey: key) { return String(int) }
        return nil
    }

    fileprivate static func decodeURL(_ uri: String, codingPath: [CodingKey]) throws -> URL {
        guard let url = url(fromURI: uri) else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "not a URI: \(uri)"))
        }
        return url
    }

    // MARK: - URIs

    /// A file's `file://` URI. Built by hand: URL(fileURLWithPath:) adds a
    /// trailing slash to an existing directory, and roots must not have one
    /// for some servers to match files under them.
    static func uri(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        return "file://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    /// A server's URI back as a file URL, made the way the editor makes them
    /// (percent-escapes decoded, standardized), so they compare equal.
    static func url(fromURI uri: String) -> URL? {
        guard let parsed = URL(string: uri) else { return nil }
        guard parsed.isFileURL else { return parsed }
        return URL(fileURLWithPath: parsed.path).standardizedFileURL
    }

    // MARK: - UTF-16 positions in text

    /// Where each line starts, in UTF-16 units. LSP ends lines at \n, \r\n and \r.
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        var index = 0
        while index < length {
            let unit = text.character(at: index)
            if unit == 0x0A {
                starts.append(index + 1)
            } else if unit == 0x0D {
                if index + 1 < length, text.character(at: index + 1) == 0x0A { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    /// `position` as a UTF-16 offset into `text`. A character past the line's
    /// end means its end (the spec's rule), a line past the last the text's end.
    static func offset(of position: Position, in text: NSString, lineStarts: [Int]? = nil) -> Int {
        let starts = lineStarts ?? Self.lineStarts(in: text)
        guard position.line >= 0 else { return 0 }
        guard position.line < starts.count else { return text.length }
        let start = starts[position.line]
        var end = position.line + 1 < starts.count ? starts[position.line + 1] : text.length
        // The line's own end, before its line break.
        if end > start, text.character(at: end - 1) == 0x0A { end -= 1 }
        if end > start, text.character(at: end - 1) == 0x0D { end -= 1 }
        return start + min(max(position.character, 0), end - start)
    }

    /// The position of a UTF-16 offset into `text`.
    static func position(ofOffset offset: Int, in text: NSString, lineStarts: [Int]? = nil) -> Position {
        let starts = lineStarts ?? Self.lineStarts(in: text)
        let offset = min(max(offset, 0), text.length)
        // The last line start at or before the offset.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return Position(line: low, character: offset - starts[low])
    }

    /// The UTF-16 NSRange a range covers in `text`.
    static func nsRange(of range: Range, in text: NSString, lineStarts: [Int]? = nil) -> NSRange {
        let starts = lineStarts ?? Self.lineStarts(in: text)
        let start = offset(of: range.start, in: text, lineStarts: starts)
        let end = max(start, offset(of: range.end, in: text, lineStarts: starts))
        return NSRange(location: start, length: end - start)
    }

    /// `edits` applied to `text`, as a server means them: every range refers
    /// to the text before any edit, so they go in from the end backwards.
    /// Inserts at the same place keep their order in the array.
    static func apply(_ edits: [TextEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        let starts = lineStarts(in: result)
        let ranges = edits.enumerated().map { index, edit in (index, nsRange(of: edit.range, in: result, lineStarts: starts), edit.newText) }
        let ordered = ranges.sorted { a, b in
            a.1.location != b.1.location ? a.1.location > b.1.location : a.0 > b.0
        }
        for (_, range, newText) in ordered {
            result.replaceCharacters(in: range, with: newText)
        }
        return result as String
    }
}
