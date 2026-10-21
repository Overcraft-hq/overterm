import Foundation

/// A Bruno file (`.bru`): blocks — `name { … }`, or `name [ … ]` for a
/// list — and whatever lies between them, kept as it was written.
///
/// Reading a file and writing it back with nothing changed gives the same
/// bytes. A change rewrites only the block it is in, the way Bruno's own
/// writer lays a block out, so the diff in the checkout shows the edit and
/// nothing else: the same file is opened by Bruno, `bru run` and agents.
struct BruFile: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        /// Text between blocks, as written — blank lines, mostly.
        case gap(String)
        case block(BruBlock)
    }

    private(set) var segments: [Segment]
    /// "\r\n" for a file written on Windows: a block rewritten here keeps
    /// the file's line ending rather than mixing two in one file.
    private(set) var lineEnding = "\n"

    init(parsing text: String) {
        segments = Self.parse(text)
        if text.contains("\r\n") { lineEnding = "\r\n" }
    }

    init() {
        segments = []
    }

    /// The file's text: untouched blocks as they were read, changed ones
    /// as Bruno writes them.
    var text: String {
        segments.map {
            switch $0 {
            // By byte: to Swift "\r\n" is one Character, which contains("\r") misses.
            case .gap(let text): lineEnding == "\n" || text.utf8.contains(13) ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
            case .block(let block): block.source ?? (lineEnding == "\n" ? block.written : block.written.replacingOccurrences(of: "\n", with: lineEnding))
            }
        }.joined()
    }

    var blocks: [BruBlock] {
        segments.compactMap { if case .block(let block) = $0 { block } else { nil } }
    }

    func block(_ name: String) -> BruBlock? { blocks.first { $0.name == name } }

    func has(_ name: String) -> Bool { block(name) != nil }

    // MARK: Reading

    /// A dictionary block's pairs, in their order; [] when the block is
    /// missing or isn't one.
    func pairs(_ name: String) -> [BruPair] {
        if case .dictionary(let pairs) = block(name)?.content { return pairs }
        return []
    }

    /// The first enabled value of `key` in a dictionary block.
    func value(_ key: String, in name: String) -> String? {
        pairs(name).first { $0.key == key && $0.enabled }?.value
    }

    func textBlock(_ name: String) -> String? {
        if case .text(let text) = block(name)?.content { return text }
        return nil
    }

    func list(_ name: String) -> [String] {
        if case .list(let items) = block(name)?.content { return items }
        return []
    }

    // MARK: Writing

    /// Replaces a dictionary block's pairs; an empty list removes the block
    /// unless `keepEmpty` (a method block always stays).
    mutating func setPairs(_ name: String, _ pairs: [BruPair], keepEmpty: Bool = false) {
        if pairs.isEmpty && !keepEmpty { return remove(name) }
        set(BruBlock(name: name, content: .dictionary(pairs)))
    }

    /// Sets `key` in a dictionary block, where it was or at its end.
    mutating func setValue(_ value: String, for key: String, in name: String) {
        var pairs = self.pairs(name)
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            guard pairs[index].value != value || !pairs[index].enabled else { return }
            pairs[index].value = value
            pairs[index].enabled = true
        } else {
            pairs.append(BruPair(key: key, value: value))
        }
        setPairs(name, pairs, keepEmpty: true)
    }

    mutating func removeValue(_ key: String, in name: String) {
        let pairs = self.pairs(name)
        guard pairs.contains(where: { $0.key == key }) else { return }
        setPairs(name, pairs.filter { $0.key != key }, keepEmpty: true)
    }

    /// Replaces a text block (a body, a script, the docs); nil removes it.
    mutating func setText(_ name: String, _ text: String?) {
        guard let text else { return remove(name) }
        set(BruBlock(name: name, content: .text(text)))
    }

    mutating func setList(_ name: String, _ items: [String]) {
        if items.isEmpty { return remove(name) }
        set(BruBlock(name: name, content: .list(items)))
    }

    /// The block named `old` is called `new` now, its content kept — a
    /// request's method changing, `get {` to `post {`.
    mutating func rename(_ old: String, to new: String) {
        guard old != new, let index = index(of: old), case .block(var block) = segments[index] else { return }
        remove(new)
        block.name = new
        block.source = nil
        segments[self.index(of: old) ?? index] = .block(block)
    }

    mutating func remove(_ name: String) {
        guard let index = index(of: name) else { return }
        segments.remove(at: index)
        // The blank line that kept it apart from its neighbour goes with it:
        // the one before, or for the first block the one after.
        func isBlankGap(_ at: Int) -> Bool {
            guard segments.indices.contains(at), case .gap(let gap) = segments[at] else { return false }
            return gap.allSatisfy(\.isNewline)
        }
        if index > 0, isBlankGap(index - 1) {
            segments.remove(at: index - 1)
        } else if index == 0, isBlankGap(0) {
            segments.remove(at: 0)
        }
    }

    /// In place if the file has the block; else where Bruno's writer puts
    /// it, after the blocks that come before it in `order`.
    private mutating func set(_ block: BruBlock) {
        if let index = index(of: block.name), case .block(let old) = segments[index] {
            guard old.content != block.content else { return }
            segments[index] = .block(block)
            return
        }
        let rank = Self.rank(of: block.name)
        var insertAt = segments.count
        for (index, segment) in segments.enumerated() {
            if case .block(let other) = segment, Self.rank(of: other.name) > rank {
                insertAt = index
                break
            }
        }
        // Blocks are one blank line apart, as Bruno writes them.
        if insertAt == segments.count {
            if !segments.isEmpty, !text.hasSuffix("\n\n") { segments.append(.gap(text.hasSuffix("\n") ? "\n" : "\n\n")) }
            segments.append(.block(block))
        } else {
            segments.insert(contentsOf: [.block(block), .gap("\n")], at: insertAt)
        }
    }

    private func index(of name: String) -> Int? {
        segments.firstIndex { if case .block(let block) = $0 { block.name == name } else { false } }
    }

    /// The order Bruno's writer emits blocks in; unknown names go last.
    static let order: [String] = [
        "meta", "get", "post", "put", "patch", "delete", "options", "head", "connect", "trace", "http", "graphql",
        "params:query", "params:path", "headers",
        "auth", "auth:awsv4", "auth:basic", "auth:bearer", "auth:digest", "auth:ntlm", "auth:oauth2", "auth:wsse", "auth:apikey",
        "body", "body:json", "body:text", "body:xml", "body:sparql", "body:form-urlencoded", "body:multipart-form", "body:file",
        "body:graphql", "body:graphql:vars",
        "vars", "vars:secret", "vars:pre-request", "vars:post-response", "assert",
        "script:pre-request", "script:post-response", "tests", "settings", "docs",
    ]

    private static func rank(of name: String) -> Int {
        order.firstIndex(of: name) ?? order.count
    }

    // MARK: Parsing

    /// Blocks whose content is text, written indented by two spaces;
    /// every other `{ }` block holds `key: value` lines.
    static func isTextBlock(_ name: String) -> Bool {
        name.hasPrefix("body:") && !["body:form-urlencoded", "body:multipart-form", "body:file"].contains(name)
            || name.hasPrefix("script:") || name == "tests" || name == "docs"
    }

    private static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var gap = ""
        var lines = text.components(separatedBy: "\n")
        // "a\n" splits into ["a", ""]: then the last element is no line. A
        // file without a final newline keeps its last line, and has none
        // written after it.
        let endsInNewline = lines.last == ""
        if endsInNewline { lines.removeLast() }
        func newline(after line: Int) -> String { line == lines.count - 1 && !endsInNewline ? "" : "\n" }
        var index = 0
        func flushGap() {
            if !gap.isEmpty { segments.append(.gap(gap)) }
            gap = ""
        }
        while index < lines.count {
            let line = lines[index]
            if let (name, closer) = opening(line) {
                // The block runs to its closer at the start of a line.
                var end = index + 1
                while end < lines.count, lines[end].trimmingCharacters(in: .whitespacesAndNewlines) != closer || lines[end].hasPrefix(" ") {
                    end += 1
                }
                if end < lines.count {
                    flushGap()
                    // A CRLF file's lines end in "\r": the content goes without
                    // it, the source (and so the bytes) with it.
                    let body = lines[(index + 1)..<end].map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
                    let source = lines[index...end].joined(separator: "\n") + newline(after: end)
                    segments.append(.block(BruBlock(name: name, content: content(of: name, closer: closer, body), source: source)))
                    index = end + 1
                    continue
                }
            }
            gap += line + newline(after: index)
            index += 1
        }
        flushGap()
        return segments
    }

    /// `name {` or `name [` on a line of its own.
    private static func opening(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.hasPrefix(" "), let last = trimmed.last, last == "{" || last == "[" else { return nil }
        let name = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_" }) else { return nil }
        return (name, last == "{" ? "}" : "]")
    }

    private static func content(of name: String, closer: String, _ lines: [String]) -> BruBlock.Content {
        if closer == "]" {
            return .list(
                lines.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        if isTextBlock(name) {
            return .text(lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n"))
        }
        return .dictionary(pairs(lines))
    }

    private static func pairs(_ lines: [String]) -> [BruPair] {
        var pairs: [BruPair] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard !line.isEmpty, var pair = BruPair(line: line) else { continue }
            // key: ''' … ''' — a value over several lines, indented four.
            if pair.value == "'''" {
                var value: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "'''" {
                    let line = lines[index]
                    value.append(line.hasPrefix("    ") ? String(line.dropFirst(4)) : line.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                index += 1
                pair.value = value.joined(separator: "\n")
            }
            pairs.append(pair)
        }
        return pairs
    }
}

/// One block of a Bruno file.
struct BruBlock: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case dictionary([BruPair])
        case text(String)
        case list([String])
    }

    var name: String
    var content: Content
    /// The block as it was read; nil once changed, when it is written anew.
    fileprivate(set) var source: String?

    init(name: String, content: Content) {
        self.name = name
        self.content = content
    }

    fileprivate init(name: String, content: Content, source: String) {
        self.name = name
        self.content = content
        self.source = source
    }

    /// As Bruno's writer lays it out (jsonToBru): two spaces in, the
    /// closer at the start of its line.
    var written: String {
        switch content {
        case .dictionary(let pairs):
            return "\(name) {\n" + pairs.map { "  " + $0.written + "\n" }.joined() + "}\n"
        case .text(let text):
            // Every line indented, empty ones too: Bruno's indentString.
            let body = text.isEmpty ? "" : text.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n"
            return "\(name) {\n" + body + "}\n"
        case .list(let items):
            return "\(name) [\n" + items.map { "  " + $0 }.joined(separator: ",\n") + (items.isEmpty ? "" : "\n") + "]\n"
        }
    }
}

/// `key: value` in a dictionary block; `~key` is there but switched off.
struct BruPair: Equatable, Hashable, Sendable {
    var key: String
    var value: String
    var enabled = true

    init(key: String, value: String, enabled: Bool = true) {
        self.key = key
        self.value = value
        self.enabled = enabled
    }

    /// A line of a dictionary block, its indent already gone.
    init?(line: String) {
        var rest = Substring(line)
        enabled = !rest.hasPrefix("~")
        if !enabled { rest = rest.dropFirst() }
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            // A quoted key may hold a colon.
            key = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            rest = rest[rest.index(after: colon)...]
        } else {
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            key = rest[..<colon].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: colon)...]
        }
        value = rest.trimmingCharacters(in: .whitespaces)
    }

    var written: String {
        let needsQuotes = key.contains(":") || key.hasPrefix("~") || key.hasPrefix("\"") || key != key.trimmingCharacters(in: .whitespaces)
        let name = (enabled ? "" : "~") + (needsQuotes ? "\"\(key)\"" : key)
        guard value.contains("\n") else { return value.isEmpty ? "\(name): " : "\(name): \(value)" }
        let lines = value.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
        return "\(name): '''\n\(lines)\n  '''"
    }
}
