import Foundation

/// Just enough highlighting to read code: comments, strings, numbers and
/// keywords, by file extension. Regex, not a parser — a mis-coloured edge
/// case is acceptable, a slow editor is not.
enum SyntaxHighlighter {
    enum Kind: Equatable { case comment, string, number, keyword }

    struct Language {
        let lineComment: [String]
        let blockComment: (open: String, close: String)?
        /// Quote characters that delimit single-line strings.
        let quotes: [Character]
        /// Backtick/template or triple-quoted strings that may span lines.
        let multilineStrings: [String]
        let keywords: Set<String>
    }

    private static let cLike = (line: ["//"], block: ("/*", "*/"))

    static func language(for url: URL) -> Language? {
        let name = url.lastPathComponent
        if name == "Dockerfile" || name.hasPrefix("Dockerfile.") {
            return Language(lineComment: ["#"], blockComment: nil, quotes: ["\"", "'"], multilineStrings: [], keywords: dockerfile)
        }
        if name == "Makefile" || name == "Justfile" {
            return Language(lineComment: ["#"], blockComment: nil, quotes: ["\"", "'"], multilineStrings: [], keywords: shell)
        }
        switch url.pathExtension.lowercased() {
        case "swift":
            return Language(lineComment: cLike.line, blockComment: cLike.block, quotes: ["\""], multilineStrings: ["\"\"\""], keywords: swift)
        case "go":
            return Language(lineComment: cLike.line, blockComment: cLike.block, quotes: ["\"", "'"], multilineStrings: ["`"], keywords: go)
        case "ts", "tsx", "js", "jsx", "mjs", "cjs":
            return Language(lineComment: cLike.line, blockComment: cLike.block, quotes: ["\"", "'"], multilineStrings: ["`"], keywords: typescript)
        case "rs":
            return Language(lineComment: cLike.line, blockComment: cLike.block, quotes: ["\""], multilineStrings: [], keywords: rust)
        case "zig":
            return Language(lineComment: cLike.line, blockComment: nil, quotes: ["\"", "'"], multilineStrings: [], keywords: zig)
        case "c", "h", "cc", "cpp", "hpp", "m":
            return Language(lineComment: cLike.line, blockComment: cLike.block, quotes: ["\"", "'"], multilineStrings: [], keywords: c)
        case "py":
            return Language(lineComment: ["#"], blockComment: nil, quotes: ["\"", "'"], multilineStrings: ["\"\"\"", "'''"], keywords: python)
        case "sh", "bash", "zsh", "fish", "env":
            return Language(lineComment: ["#"], blockComment: nil, quotes: ["\"", "'"], multilineStrings: [], keywords: shell)
        case "yaml", "yml", "toml", "ini", "conf":
            return Language(lineComment: ["#"], blockComment: nil, quotes: ["\"", "'"], multilineStrings: [], keywords: ["true", "false", "null", "yes", "no", "on", "off"])
        case "json", "jsonc":
            return Language(lineComment: ["//"], blockComment: cLike.block, quotes: ["\""], multilineStrings: [], keywords: ["true", "false", "null"])
        case "sql":
            return Language(lineComment: ["--"], blockComment: cLike.block, quotes: ["'", "\""], multilineStrings: [], keywords: sql)
        case "md", "markdown":
            return Language(lineComment: [], blockComment: ("<!--", "-->"), quotes: [], multilineStrings: ["```"], keywords: [])
        default:
            return nil
        }
    }

    /// Token ranges (UTF-16, for NSAttributedString) in document order.
    static func tokens(in text: String, language: Language) -> [(NSRange, Kind)] {
        let ns = text as NSString
        var tokens: [(NSRange, Kind)] = []

        // Comments and strings in one left-to-right pass, so a quote inside a
        // comment (or // inside a string) is not mistaken for the other.
        var alternatives: [(String, Kind)] = []
        if let block = language.blockComment {
            alternatives.append((NSRegularExpression.escapedPattern(for: block.open) + "[\\s\\S]*?(?:" + NSRegularExpression.escapedPattern(for: block.close) + "|$(?![\\s\\S]))", .comment))
        }
        for delimiter in language.multilineStrings {
            let d = NSRegularExpression.escapedPattern(for: delimiter)
            alternatives.append((d + "[\\s\\S]*?(?:" + d + "|$(?![\\s\\S]))", .string))
        }
        for marker in language.lineComment {
            alternatives.append((NSRegularExpression.escapedPattern(for: marker) + "[^\\n]*", .comment))
        }
        for quote in language.quotes {
            let q = NSRegularExpression.escapedPattern(for: String(quote))
            alternatives.append((q + "(?:\\\\.|[^" + q + "\\\\\\n])*" + q + "?", .string))
        }
        var covered = IndexSet()
        if !alternatives.isEmpty {
            let pattern = alternatives.map { "(" + $0.0 + ")" }.joined(separator: "|")
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    guard let group = (1...alternatives.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
                    tokens.append((match.range, alternatives[group - 1].1))
                    covered.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
                }
            }
        }

        // Numbers and keywords, outside comments and strings.
        let wordPattern = "\\b(?:0x[0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b|\\b[A-Za-z_][A-Za-z0-9_]*\\b"
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard !covered.contains(match.range.location) else { continue }
                let word = ns.substring(with: match.range)
                if let first = word.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
                    tokens.append((match.range, .number))
                } else if language.keywords.contains(word) {
                    tokens.append((match.range, .keyword))
                }
            }
        }
        return tokens.sorted { $0.0.location < $1.0.location }
    }

    // MARK: Keywords

    static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer",
        "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "let", "lazy", "nil", "nonisolated", "open", "operator", "override",
        "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while",
    ]
    static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go",
        "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch",
        "true", "type", "var",
    ]
    static let typescript: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in",
        "instanceof", "interface", "keyof", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return",
        "satisfies", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void",
        "while", "yield",
    ]
    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False",
        "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise",
        "return", "True", "try", "while", "with", "yield",
    ]
    static let shell: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly",
        "return", "set", "then", "until", "while",
    ]
    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
        "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
        "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    static let zig: Set<String> = [
        "align", "and", "break", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export",
        "extern", "false", "fn", "for", "if", "inline", "null", "or", "orelse", "packed", "pub", "return", "struct", "switch",
        "test", "true", "try", "undefined", "union", "unreachable", "var", "while",
    ]
    static let c: Set<String> = [
        "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto",
        "if", "int", "long", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned",
        "void", "volatile", "while", "bool", "true", "false", "NULL",
    ]
    static let sql: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP",
        "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP",
        "HAVING", "LIMIT", "OFFSET", "PRIMARY", "KEY", "REFERENCES", "DEFAULT", "select", "from", "where", "insert", "into",
        "values", "update", "set", "delete", "create", "table", "alter", "drop", "index", "join", "on", "and", "or", "not", "null",
        "as", "order", "by", "group", "limit",
    ]
    static let dockerfile: Set<String> = [
        "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "ARG", "WORKDIR", "EXPOSE", "ENTRYPOINT", "USER", "LABEL", "VOLUME", "AS",
        "HEALTHCHECK", "SHELL",
    ]
}
