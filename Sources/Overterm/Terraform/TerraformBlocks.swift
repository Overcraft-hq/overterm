import Foundation

/// A file's top-level blocks — `resource "aws_s3_bucket" "logs" { … }`,
/// `variable "region" { … }`, `locals { … }` — and its top-level
/// attributes (a `.tfvars` file's `region = "eu-west-1"`), by a line-and-
/// brace scan that knows HCL's strings, templates (`"${…}"`), heredocs and
/// comments (analysis 4.12, 4.14). Pure; ranges are UTF-16, the editor's.
/// What it doesn't understand it skips: it never throws.
struct TerraformBlocks: Equatable, Sendable {
    struct Block: Equatable, Sendable {
        /// `resource`, `data`, `variable`, `output`, `locals`, `module`…
        var type: String
        /// The labels, unquoted: `["aws_s3_bucket", "logs"]`.
        var labels: [String]
        /// From the type's first character to the closing brace (to the
        /// end of the text when it never closes).
        var range: NSRange
        /// The name a jump selects: the last label's text inside its
        /// quotes, else the type.
        var nameRange: NSRange
        /// A `locals` block's names, and any block's attributes one level in.
        var attributes: [Attribute]
    }

    struct Attribute: Equatable, Sendable {
        var name: String
        var nameRange: NSRange
        /// The value when it is one plain literal on its line: a string
        /// without a template (`"acme-tfstate"`), `true`, `false`, or a
        /// bare word; nil for anything else (an expression, a number, an
        /// object). What the root facts read (the backend's keys, a
        /// module's `source`, `required_version`), never evaluated.
        var value: String? = nil
    }

    var blocks: [Block]
    /// Attributes outside any block.
    var attributes: [Attribute]

    init(blocks: [Block] = [], attributes: [Attribute] = []) {
        self.blocks = blocks
        self.attributes = attributes
    }

    // MARK: Scanning

    private enum Token: Equatable {
        case identifier(String, NSRange)
        /// A quoted string: its text when it has no template, its inside's range.
        case string(String?, NSRange)
        /// `{`, `[` or `(`; only a brace opens a block.
        case open(NSRange, brace: Bool)
        case close(NSRange)
        case equals
        case newline
        case other
    }

    static func scan(_ text: String) -> TerraformBlocks {
        let tokens = tokenize(text as NSString)
        var result = TerraformBlocks()
        var depth = 0
        var lineStart = true
        var statement: [Token] = []
        // The block open at depth 1, and its start.
        var current: (type: String, labels: [String], start: Int, nameRange: NSRange, attributes: [Attribute])?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token {
            case .newline:
                lineStart = true
                statement = []
                continue
            case .open(_, let brace):
                if depth == 0, brace, case .identifier(let type, let typeRange)? = statement.first {
                    var labels: [String] = []
                    var nameRange = typeRange
                    var isBlock = true
                    for label in statement.dropFirst() {
                        switch label {
                        case .identifier(let name, let range):
                            labels.append(name)
                            nameRange = range
                        case .string(let name?, let range):
                            labels.append(name)
                            nameRange = range
                        default: isBlock = false
                        }
                    }
                    if isBlock { current = (type, labels, typeRange.location, nameRange, []) }
                }
                depth += 1
                statement = []
                lineStart = true
                continue
            case .close(let range):
                depth = max(0, depth - 1)
                if depth == 0, let block = current {
                    let end = NSMaxRange(range)
                    result.blocks.append(
                        Block(
                            type: block.type, labels: block.labels, range: NSRange(location: block.start, length: end - block.start),
                            nameRange: block.nameRange, attributes: block.attributes))
                    current = nil
                }
                statement = []
                lineStart = false
                continue
            case .equals:
                if statement.count == 1, case .identifier(let name, let range) = statement[0] {
                    let value = literal(after: index, in: tokens)
                    if depth == 0 {
                        result.attributes.append(Attribute(name: name, nameRange: range, value: value))
                    } else if depth == 1, current != nil {
                        current?.attributes.append(Attribute(name: name, nameRange: range, value: value))
                    }
                }
                statement = []
                lineStart = false
                continue
            default:
                if lineStart || !statement.isEmpty { statement.append(token) }
                lineStart = false
            }
        }
        // A block left open at the end: kept, up to the end of the text.
        if let block = current {
            let end = (text as NSString).length
            result.blocks.append(
                Block(
                    type: block.type, labels: block.labels, range: NSRange(location: block.start, length: end - block.start),
                    nameRange: block.nameRange, attributes: block.attributes))
        }
        return result
    }

    /// The literal at `index` when it ends its line (or the block): a
    /// plain string, or one word (`true`, `false`, `local`).
    private static func literal(after index: Int, in tokens: [Token]) -> String? {
        guard index < tokens.count else { return nil }
        let ends: Bool = {
            guard index + 1 < tokens.count else { return true }
            switch tokens[index + 1] {
            case .newline, .close: return true
            default: return false
            }
        }()
        guard ends else { return nil }
        switch tokens[index] {
        case .string(let text?, _): return text
        case .identifier(let word, _): return word
        default: return nil
        }
    }

    /// The text between a block's braces, and where it starts in `text`
    /// (UTF-16): scanned again, its own blocks are the nested ones
    /// (`terraform { backend "s3" { … } }`, a resource's `provisioner`).
    static func body(of block: Block, in text: String) -> (text: String, offset: Int)? {
        let ns = text as NSString
        let end = min(NSMaxRange(block.range), ns.length)
        var open = block.nameRange.location + block.nameRange.length
        while open < end, ns.character(at: open) != 0x7B { open += 1 }
        guard open < end else { return nil }
        let start = open + 1
        // The closing brace is the range's last character when the block closed.
        let close = end > start && ns.character(at: end - 1) == 0x7D ? end - 1 : end
        guard close >= start else { return nil }
        return (ns.substring(with: NSRange(location: start, length: close - start)), start)
    }

    /// The blocks inside `block`, by a scan of its body.
    static func nested(in block: Block, of text: String) -> TerraformBlocks {
        guard let body = body(of: block, in: text) else { return TerraformBlocks() }
        return scan(body.text)
    }

    private static func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    private static func isIdentifierPart(_ c: unichar) -> Bool {
        isIdentifierStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D
    }

    /// The top level's tokens. Inside a string or a template nothing is a
    /// token: what is in there never opens or closes a block.
    private static func tokenize(_ text: NSString) -> [Token] {
        let length = text.length
        var tokens: [Token] = []
        var i = 0
        func at(_ index: Int) -> unichar { index >= 0 && index < length ? text.character(at: index) : 0 }
        func skipLine() {
            while i < length, at(i) != 0x0A { i += 1 }
        }
        func skipBlockComment() {
            i += 2
            while i < length, !(at(i) == 0x2A && at(i + 1) == 0x2F) { i += 1 }
            i = min(length, i + 2)
        }
        /// From after an opening quote to after its closing one; templates
        /// inside skipped by brace depth, their own strings included.
        /// Returns the plain text when there was no template.
        func skipString() -> String? {
            var plain = ""
            var templated = false
            while i < length {
                let c = at(i)
                if c == 0x22 {
                    i += 1
                    return templated ? nil : plain
                }
                if c == 0x0A { return nil }  // an unterminated string ends at its line
                if c == 0x5C {
                    i += 2
                    templated = true
                    continue
                }
                if (c == 0x24 || c == 0x25), at(i + 1) == 0x7B {
                    if at(i - 1) == c {  // `$${` is a literal
                        i += 2
                        templated = true
                        continue
                    }
                    templated = true
                    i += 2
                    skipTemplate()
                    continue
                }
                plain.append(Character(UnicodeScalar(c) ?? " "))
                i += 1
            }
            return nil
        }
        func skipTemplate() {
            var depth = 0
            var guardSteps = 0
            while i < length, guardSteps < 1_000_000 {
                guardSteps += 1
                let c = at(i)
                switch c {
                case 0x22:
                    i += 1
                    _ = skipString()
                case 0x7B:
                    depth += 1
                    i += 1
                case 0x7D:
                    i += 1
                    if depth == 0 { return }
                    depth -= 1
                default:
                    i += 1
                }
            }
        }
        /// `<<EOF` or `<<-EOF`: everything to the line whose trimmed text is EOF.
        func skipHeredoc() -> Bool {
            var j = i + 2
            if at(j) == 0x2D { j += 1 }
            let markerStart = j
            while j < length, isIdentifierPart(at(j)) { j += 1 }
            guard j > markerStart, isIdentifierStart(at(markerStart)) else { return false }
            let marker = text.substring(with: NSRange(location: markerStart, length: j - markerStart))
            i = j
            skipLine()
            while i < length {
                i += 1  // past the newline
                let lineStart = i
                skipLine()
                let line = text.substring(with: NSRange(location: lineStart, length: i - lineStart)).trimmingCharacters(in: .whitespaces)
                if line == marker { return true }
            }
            return true
        }
        while i < length {
            let c = at(i)
            switch c {
            case 0x0A:
                tokens.append(.newline)
                i += 1
            case 0x20, 0x09, 0x0D:
                i += 1
            case 0x23:
                skipLine()
            case 0x2F where at(i + 1) == 0x2F:
                skipLine()
            case 0x2F where at(i + 1) == 0x2A:
                skipBlockComment()
            case 0x22:
                let start = i + 1
                i += 1
                let plain = skipString()
                let end = max(start, (plain != nil ? i - 1 : i))
                tokens.append(.string(plain, NSRange(location: start, length: end - start)))
            case 0x7B, 0x5B, 0x28:
                tokens.append(.open(NSRange(location: i, length: 1), brace: c == 0x7B))
                i += 1
            case 0x7D, 0x5D, 0x29:
                tokens.append(.close(NSRange(location: i, length: 1)))
                i += 1
            case 0x3D where at(i + 1) != 0x3D && at(i + 1) != 0x3E && ![0x3D, 0x21, 0x3C, 0x3E].contains(at(i - 1)):
                tokens.append(.equals)
                i += 1
            case 0x3C where at(i + 1) == 0x3C:
                if !skipHeredoc() {
                    tokens.append(.other)
                    i += 2
                }
            default:
                if isIdentifierStart(c) {
                    let start = i
                    while i < length, isIdentifierPart(at(i)) { i += 1 }
                    tokens.append(.identifier(text.substring(with: NSRange(location: start, length: i - start)), NSRange(location: start, length: i - start)))
                } else {
                    tokens.append(.other)
                    i += 1
                }
            }
        }
        return tokens
    }
}
