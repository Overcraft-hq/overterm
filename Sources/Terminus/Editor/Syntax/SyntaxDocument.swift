import Foundation
import TreeSitterKit

/// Edits not yet handed to the parser, merged into one: the span they
/// touched in the text as last parsed (`start..<oldEnd`) and in the text now
/// (`start..<newEnd`). A burst of typing is one tree edit, not one per key.
struct SyntaxEdit: Equatable, Sendable {
    var start: Int
    var oldEnd: Int
    var newEnd: Int

    init(location: Int, oldLength: Int, newLength: Int) {
        start = location
        oldEnd = location + oldLength
        newEnd = location + newLength
    }

    /// Adds an edit made to the text *after* this one (its numbers are in
    /// that text).
    mutating func merge(location: Int, oldLength: Int, newLength: Int) {
        let editEnd = location + oldLength
        let unionStart = min(start, location)
        let unionEnd = max(newEnd, editEnd)
        // Past this edit's end, the text as parsed is shifted by what it changed.
        let parsedEnd = unionEnd + (oldEnd - newEnd)
        start = unionStart
        oldEnd = parsedEnd
        newEnd = unionEnd + (newLength - oldLength)
    }
}

/// One document's syntax tree, kept off the main thread: the text view sends
/// each edit with the text it left, and asks for the colours of the lines on
/// screen. UTF-16 throughout — tree-sitter reads the text as NSString holds
/// it, so a byte offset is just twice an NSRange location.
final class SyntaxDocument: @unchecked Sendable {
    /// One capture: a range and Helix's name for it ("keyword.control.return").
    struct Span: Equatable, Sendable {
        let range: NSRange
        let capture: String
    }

    /// A definition, for ⇧⌘O where no language server answers.
    struct Symbol: Equatable, Sendable {
        let name: String
        let kind: String
        let range: NSRange
    }

    /// Past this (UTF-16 units) the file stays plain: parsing it on every
    /// edit would cost more than the colours are worth.
    static let maxLength = 8_000_000
    /// Injections inside injections (markdown → fence → its language) stop here.
    private static let maxDepth = 3

    let language: EditorLanguage
    private let queue = DispatchQueue(label: "overterm.syntax", qos: .userInitiated)
    // Everything below belongs to `queue`.
    private let parser: OpaquePointer
    private var tree: OpaquePointer?
    private var text: [UInt16] = []
    private var version = 0
    private var injectionParsers: [String: OpaquePointer] = [:]

    init(language: EditorLanguage) {
        self.language = language
        parser = ts_parser_new()
        ts_parser_set_language(parser, language.grammar)
    }

    deinit {
        if let tree { ts_tree_delete(tree) }
        ts_parser_delete(parser)
        for parser in injectionParsers.values { ts_parser_delete(parser) }
    }

    /// The document's text, from scratch (opening a file, reloading it).
    func reset(_ text: [UInt16], version: Int) {
        queue.async { [self] in
            if let tree { ts_tree_delete(tree) }
            tree = nil
            self.text = text
            self.version = version
            reparse(edit: nil)
        }
    }

    /// The text after `edit`, which the tree learns of first so only what
    /// changed is parsed again.
    func update(_ text: [UInt16], edit: SyntaxEdit, version: Int) {
        queue.async { [self] in
            let old = self.text
            self.text = text
            self.version = version
            reparse(edit: (edit, old))
        }
    }

    private func reparse(edit: (SyntaxEdit, [UInt16])?) {
        guard text.count <= Self.maxLength else {
            if let tree { ts_tree_delete(tree) }
            tree = nil
            return
        }
        if let (edit, old) = edit, let tree {
            var input = TSInputEdit(
                start_byte: UInt32(edit.start * 2), old_end_byte: UInt32(edit.oldEnd * 2), new_end_byte: UInt32(edit.newEnd * 2),
                start_point: Self.point(edit.start, in: old), old_end_point: Self.point(edit.oldEnd, in: old),
                new_end_point: Self.point(edit.newEnd, in: text))
            ts_tree_edit(tree, &input)
        }
        let parsed = parse(parser, old: tree)
        if let tree { ts_tree_delete(tree) }
        tree = parsed
    }

    private func parse(_ parser: OpaquePointer, old: OpaquePointer?) -> OpaquePointer? {
        text.withUnsafeBytes { bytes in
            ts_parser_parse_string_encoding(
                parser, old, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(bytes.count), TSInputEncodingUTF16LE)
        }
    }

    /// Row and byte column of a UTF-16 offset, as tree-sitter keeps them.
    static func point(_ offset: Int, in text: [UInt16]) -> TSPoint {
        let offset = min(offset, text.count)
        var row: UInt32 = 0
        var lineStart = 0
        text.withUnsafeBufferPointer { buffer in
            for i in 0..<offset where buffer[i] == 0x0A {
                row += 1
                lineStart = i + 1
            }
        }
        return TSPoint(row: row, column: UInt32((offset - lineStart) * 2))
    }

    // MARK: Highlights

    /// The captures over `range` (and the languages injected in it), in the
    /// order to paint them: outer before inner, and for one node the later
    /// pattern last — so it wins, as Helix's queries expect (25.07 onward).
    /// `done` runs on the main queue with the version the spans are for.
    func highlights(in range: NSRange, done: @escaping @Sendable (_ version: Int, _ spans: [Span]) -> Void) {
        queue.async { [self] in
            var spans: [Span] = []
            if let tree { collect(tree, language, range, depth: 0, into: &spans) }
            let version = self.version
            DispatchQueue.main.async { done(version, spans) }
        }
    }

    /// The same, synchronously — for tests.
    func highlightsNow(in range: NSRange) -> [Span] {
        queue.sync {
            var spans: [Span] = []
            if let tree { collect(tree, language, range, depth: 0, into: &spans) }
            return spans
        }
    }

    private struct Ordered {
        let start: Int
        let length: Int
        let pattern: UInt32
        let capture: String
    }

    private func collect(_ tree: OpaquePointer, _ language: EditorLanguage, _ range: NSRange, depth: Int, into spans: inout [Span]) {
        let root = ts_tree_root_node(tree)
        if let query = language.highlights {
            var ordered: [Ordered] = []
            captures(query, root, range) { match, capture in
                let name = query.captureNames[Int(capture.index)]
                // Helix's private captures (`@_name`) only feed predicates.
                guard !name.hasPrefix("_"), name != "spell", name != "nospell" else { return }
                let start = Int(ts_node_start_byte(capture.node)) / 2
                let end = Int(ts_node_end_byte(capture.node)) / 2
                guard end > start else { return }
                ordered.append(Ordered(start: start, length: end - start, pattern: UInt32(match.pattern_index), capture: name))
            }
            ordered.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.length != $1.length { return $0.length > $1.length }
                return $0.pattern < $1.pattern
            }
            spans.append(contentsOf: ordered.map { Span(range: NSRange(location: $0.start, length: $0.length), capture: $0.capture) })
        }
        guard depth < Self.maxDepth else { return }
        for injection in injections(language, root, range) {
            guard let parsed = parseInjection(injection) else { continue }
            collect(parsed, injection.language, range, depth: depth + 1, into: &spans)
            ts_tree_delete(parsed)
        }
    }

    /// Each capture of `query` over `range` whose match passes its predicates.
    private func captures(_ query: SyntaxQuery, _ node: TSNode, _ range: NSRange, _ each: (TSQueryMatch, TSQueryCapture) -> Void) {
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_set_match_limit(cursor, 2048)
        ts_query_cursor_set_byte_range(cursor, UInt32(range.location * 2), UInt32(NSMaxRange(range) * 2))
        ts_query_cursor_exec(cursor, query.query, node)
        var match = TSQueryMatch()
        var index: UInt32 = 0
        var rejected = Set<UInt32>()
        var accepted = Set<UInt32>()
        while ts_query_cursor_next_capture(cursor, &match, &index) {
            guard let list = match.captures, !rejected.contains(match.id) else { continue }
            if !accepted.contains(match.id) {
                guard query.accepts(pattern: UInt32(match.pattern_index), captures: list, count: Int(match.capture_count), text: nodeText)
                else {
                    rejected.insert(match.id)
                    continue
                }
                accepted.insert(match.id)
            }
            each(match, list[Int(index)])
        }
    }

    private func nodeText(_ node: TSNode) -> String {
        let start = min(Int(ts_node_start_byte(node)) / 2, text.count)
        let end = min(Int(ts_node_end_byte(node)) / 2, text.count)
        guard end > start else { return "" }
        return text.withUnsafeBufferPointer { String(utf16CodeUnits: $0.baseAddress! + start, count: end - start) }
    }

    // MARK: Injections

    private struct Injection {
        let language: EditorLanguage
        var ranges: [TSRange]
    }

    /// The other languages inside `range`: a markdown fence's, the inline
    /// markdown in every paragraph, HTML's <script>. `injection.combined`
    /// patterns are one document across all their nodes.
    private func injections(_ language: EditorLanguage, _ root: TSNode, _ range: NSRange) -> [Injection] {
        guard let query = language.injections else { return [] }
        var separate: [Injection] = []
        var combined: [String: Injection] = [:]
        var combinedOrder: [String] = []
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_set_match_limit(cursor, 2048)
        ts_query_cursor_set_byte_range(cursor, UInt32(range.location * 2), UInt32(NSMaxRange(range) * 2))
        ts_query_cursor_exec(cursor, query.query, root)
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            guard let list = match.captures else { continue }
            let pattern = UInt32(match.pattern_index)
            guard query.accepts(pattern: pattern, captures: list, count: Int(match.capture_count), text: nodeText) else { continue }
            let settings = query.settings(of: pattern)
            var name = settings["injection.language"]
            var content: [TSNode] = []
            for i in 0..<Int(match.capture_count) {
                switch query.captureNames[Int(list[i].index)] {
                case "injection.language": name = nodeText(list[i].node)
                case "injection.content": content.append(list[i].node)
                default: break
                }
            }
            guard let name, let target = EditorLanguage.named(name), !content.isEmpty else { continue }
            let ranges = content.flatMap {
                Self.ranges(
                    of: $0, includeChildren: settings["injection.include-children"] != nil,
                    includeUnnamed: settings["injection.include-unnamed-children"] != nil)
            }
            guard !ranges.isEmpty else { continue }
            if settings["injection.combined"] != nil {
                let key = "\(pattern)/\(target.id)"
                if combined[key] == nil { combinedOrder.append(key) }
                combined[key, default: Injection(language: target, ranges: [])].ranges += ranges
            } else {
                separate.append(Injection(language: target, ranges: ranges))
            }
        }
        return separate + combinedOrder.compactMap { combined[$0] }
    }

    /// A node's text minus its children's, unless the query keeps them: the
    /// `> ` of a quoted fence is markdown, not the fence's language.
    private static func ranges(of node: TSNode, includeChildren: Bool, includeUnnamed: Bool) -> [TSRange] {
        let whole = TSRange(
            start_point: ts_node_start_point(node), end_point: ts_node_end_point(node), start_byte: ts_node_start_byte(node),
            end_byte: ts_node_end_byte(node))
        if includeChildren { return [whole] }
        var ranges: [TSRange] = []
        var start = (byte: whole.start_byte, point: whole.start_point)
        for i in 0..<ts_node_child_count(node) {
            let child = ts_node_child(node, i)
            if includeUnnamed && !ts_node_is_named(child) { continue }
            let childStart = ts_node_start_byte(child)
            if childStart > start.byte {
                ranges.append(
                    TSRange(start_point: start.point, end_point: ts_node_start_point(child), start_byte: start.byte, end_byte: childStart))
            }
            start = (ts_node_end_byte(child), ts_node_end_point(child))
        }
        if whole.end_byte > start.byte {
            ranges.append(TSRange(start_point: start.point, end_point: whole.end_point, start_byte: start.byte, end_byte: whole.end_byte))
        }
        return ranges
    }

    /// The injected language's tree over just its ranges of this text, so
    /// its offsets are the document's.
    private func parseInjection(_ injection: Injection) -> OpaquePointer? {
        let parser: OpaquePointer
        if let cached = injectionParsers[injection.language.id] {
            parser = cached
        } else {
            parser = ts_parser_new()
            ts_parser_set_language(parser, injection.language.grammar)
            injectionParsers[injection.language.id] = parser
        }
        let ranges = injection.ranges.sorted { $0.start_byte < $1.start_byte }
        let ok = ranges.withUnsafeBufferPointer { ts_parser_set_included_ranges(parser, $0.baseAddress, UInt32($0.count)) }
        guard ok else { return nil }
        return parse(parser, old: nil)
    }

    // MARK: Structure

    /// Definitions, by the language's tags query (Helix's `@definition.*`
    /// around a `@name`), for the symbol picker.
    func symbols(done: @escaping @Sendable ([Symbol]) -> Void) {
        queue.async { [self] in
            var symbols: [Symbol] = []
            if let tree, let query = language.tags {
                let cursor = ts_query_cursor_new()
                ts_query_cursor_exec(cursor, query.query, ts_tree_root_node(tree))
                var match = TSQueryMatch()
                while ts_query_cursor_next_match(cursor, &match) {
                    guard let list = match.captures else { continue }
                    var name: TSNode?
                    var kind: String?
                    for i in 0..<Int(match.capture_count) {
                        let capture = query.captureNames[Int(list[i].index)]
                        if capture == "name" {
                            name = list[i].node
                        } else if capture.hasPrefix("definition.") {
                            kind = String(capture.dropFirst("definition.".count))
                        }
                    }
                    guard let name, let kind else { continue }
                    let start = Int(ts_node_start_byte(name)) / 2
                    let end = Int(ts_node_end_byte(name)) / 2
                    symbols.append(Symbol(name: nodeText(name), kind: kind, range: NSRange(location: start, length: end - start)))
                }
                ts_query_cursor_delete(cursor)
            }
            DispatchQueue.main.async { done(symbols) }
        }
    }

    /// Waits for every edit sent so far to be parsed — for tests.
    func settle() { queue.sync {} }
}
