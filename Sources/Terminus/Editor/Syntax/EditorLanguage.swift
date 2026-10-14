import Foundation
import TreeSitterKit

/// A language the editor parses: its tree-sitter grammar, the Helix queries
/// that colour it (Frameworks/TreeSitterQueries, bundled into Resources), and
/// how its files are recognised.
final class EditorLanguage: @unchecked Sendable {
    /// The grammar's name, as Scripts/build-treesitter.sh and the query
    /// directories have it: "typescript", "markdown_inline".
    let id: String
    /// As a person would say it, for the header.
    let name: String
    let extensions: Set<String>
    let fileNames: Set<String>
    /// What a markdown fence's info string or an injection query may call
    /// it: "js", "sh", "markdown.inline".
    let aliases: Set<String>
    /// ⌘/ — "// "; nil where a line comment doesn't exist (block-only).
    let lineComment: String?
    let blockComment: (open: String, close: String)?
    let grammar: OpaquePointer

    // Compiled on first use, on whichever thread asks first; a query is
    // immutable once built, and TSQuery is safe to share across cursors.
    private let lock = NSLock()
    private var compiled: [String: SyntaxQuery?] = [:]

    init(
        _ id: String, _ name: String, extensions: [String] = [], fileNames: [String] = [], aliases: [String] = [],
        lineComment: String? = "// ", blockComment: (String, String)? = nil, grammar: OpaquePointer
    ) {
        self.id = id
        self.name = name
        self.extensions = Set(extensions)
        self.fileNames = Set(fileNames)
        self.aliases = Set(aliases + [id])
        self.lineComment = lineComment
        self.blockComment = blockComment.map { (open: $0.0, close: $0.1) }
        self.grammar = grammar
    }

    var highlights: SyntaxQuery? { query("highlights") }
    var injections: SyntaxQuery? { query("injections") }
    /// Definitions for ⇧⌘O where no language server answers.
    var tags: SyntaxQuery? { query("tags") }

    private func query(_ kind: String) -> SyntaxQuery? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = compiled[kind] { return cached }
        let source = Self.querySource(id, kind)
        let query = source.flatMap { SyntaxQuery(source: $0, language: grammar, name: "\(id)/\(kind)") }
        compiled[kind] = query
        return query
    }

    // MARK: Queries on disk

    /// Contents/Resources/TreeSitterQueries in the app; the build's copy
    /// in Frameworks/ for `swift test` and `swift run`.
    static let queriesDirectory: URL? = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("TreeSitterQueries"),
            FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("Frameworks/TreeSitterQueries")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }()

    /// A query file with Helix's `; inherits: ecma,_typescript` lines
    /// replaced by those files, where the line is: what comes after it is
    /// later, and later patterns win (SyntaxDocument).
    static func querySource(_ id: String, _ kind: String, depth: Int = 0) -> String? {
        guard depth < 5, let dir = queriesDirectory,
            let text = try? String(contentsOf: dir.appendingPathComponent("\(id)/\(kind).scm"), encoding: .utf8)
        else { return nil }
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";"), let colon = trimmed.range(of: "inherits:") {
                for parent in trimmed[colon.upperBound...].split(separator: ",") {
                    let name = parent.trimmingCharacters(in: .whitespaces)
                    if let inherited = querySource(name, kind, depth: depth + 1) { out += inherited + "\n" }
                }
            } else {
                out += line + "\n"
            }
        }
        return out
    }

    // MARK: Which language

    static func language(for url: URL) -> EditorLanguage? {
        let name = url.lastPathComponent
        if let byName = all.first(where: { $0.fileNames.contains(name) }) { return byName }
        if name.hasPrefix("Dockerfile.") || name.hasSuffix(".Dockerfile") { return named("dockerfile") }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : all.first { $0.extensions.contains(ext) }
    }

    /// An injection's or a fence's language: "ts", "Python", "markdown.inline".
    static func named(_ name: String) -> EditorLanguage? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        return byAlias[key]
    }

    private static let byAlias: [String: EditorLanguage] = {
        var map: [String: EditorLanguage] = [:]
        for language in all {
            for alias in language.aliases { map[alias.lowercased()] = map[alias.lowercased()] ?? language }
            for ext in language.extensions { map[ext] = map[ext] ?? language }
        }
        return map
    }()

    static let all: [EditorLanguage] = [
        EditorLanguage(
            "swift", "Swift", extensions: ["swift"], fileNames: [], aliases: [], blockComment: ("/*", "*/"),
            grammar: tree_sitter_swift()),
        EditorLanguage(
            "go", "Go", extensions: ["go"], aliases: ["golang"], blockComment: ("/*", "*/"), grammar: tree_sitter_go()),
        EditorLanguage(
            "typescript", "TypeScript", extensions: ["ts", "mts", "cts"], aliases: ["ts"], blockComment: ("/*", "*/"),
            grammar: tree_sitter_typescript()),
        EditorLanguage(
            "tsx", "TSX", extensions: ["tsx"], aliases: ["typescriptreact"], blockComment: ("/*", "*/"), grammar: tree_sitter_tsx()),
        EditorLanguage(
            "javascript", "JavaScript", extensions: ["js", "jsx", "mjs", "cjs"], aliases: ["js", "jsx", "node", "javascriptreact"],
            blockComment: ("/*", "*/"), grammar: tree_sitter_javascript()),
        EditorLanguage(
            "rust", "Rust", extensions: ["rs"], aliases: ["rs"], blockComment: ("/*", "*/"), grammar: tree_sitter_rust()),
        EditorLanguage(
            "python", "Python", extensions: ["py", "pyi", "pyw"], aliases: ["py", "python3"], lineComment: "# ",
            grammar: tree_sitter_python()),
        EditorLanguage(
            "json", "JSON", extensions: ["json", "jsonc", "json5", "jsonl"], fileNames: [".prettierrc", ".babelrc", ".eslintrc"],
            aliases: ["jsonc"], grammar: tree_sitter_json()),
        EditorLanguage(
            "bash", "Shell", extensions: ["sh", "bash", "zsh", "ksh", "env", "envrc"],
            fileNames: [".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile", ".env", ".envrc"],
            aliases: ["sh", "shell", "zsh", "shellscript", "console"], lineComment: "# ", grammar: tree_sitter_bash()),
        EditorLanguage("c", "C", extensions: ["c", "h"], blockComment: ("/*", "*/"), grammar: tree_sitter_c()),
        EditorLanguage(
            "cpp", "C++", extensions: ["cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm"], aliases: ["c++", "objc", "objective-c"],
            blockComment: ("/*", "*/"), grammar: tree_sitter_cpp()),
        EditorLanguage(
            "markdown", "Markdown", extensions: ["md", "markdown", "mdx", "mdc"], aliases: ["md"], lineComment: nil,
            blockComment: ("<!--", "-->"), grammar: tree_sitter_markdown()),
        EditorLanguage(
            "markdown_inline", "Markdown", aliases: ["markdown.inline", "markdown-inline"], lineComment: nil,
            grammar: tree_sitter_markdown_inline()),
        EditorLanguage(
            "yaml", "YAML", extensions: ["yaml", "yml"], fileNames: [".clang-format", ".yamllint"], aliases: ["yml"],
            lineComment: "# ", grammar: tree_sitter_yaml()),
        EditorLanguage(
            "toml", "TOML", extensions: ["toml"], fileNames: ["Cargo.lock", "uv.lock", "poetry.lock"], lineComment: "# ",
            grammar: tree_sitter_toml()),
        EditorLanguage("zig", "Zig", extensions: ["zig", "zon"], grammar: tree_sitter_zig()),
        EditorLanguage(
            "sql", "SQL", extensions: ["sql"], aliases: ["postgres", "postgresql", "mysql", "sqlite"], lineComment: "-- ",
            blockComment: ("/*", "*/"), grammar: tree_sitter_sql()),
        EditorLanguage(
            "html", "HTML", extensions: ["html", "htm", "xhtml", "svg", "xml", "plist"], aliases: ["xml"], lineComment: nil,
            blockComment: ("<!--", "-->"), grammar: tree_sitter_html()),
        EditorLanguage(
            "css", "CSS", extensions: ["css", "scss", "less"], aliases: ["scss"], lineComment: nil, blockComment: ("/*", "*/"),
            grammar: tree_sitter_css()),
        EditorLanguage(
            "dockerfile", "Dockerfile", extensions: ["dockerfile"], fileNames: ["Dockerfile", "Containerfile"],
            aliases: ["docker"], lineComment: "# ", grammar: tree_sitter_dockerfile()),
        EditorLanguage(
            "make", "Makefile", extensions: ["mk", "mak"], fileNames: ["Makefile", "makefile", "GNUmakefile", "Justfile", "justfile"],
            aliases: ["makefile"], lineComment: "# ", grammar: tree_sitter_make()),
        EditorLanguage("lua", "Lua", extensions: ["lua"], lineComment: "-- ", grammar: tree_sitter_lua()),
        EditorLanguage(
            "ruby", "Ruby", extensions: ["rb", "rake", "gemspec"], fileNames: ["Gemfile", "Rakefile", "Brewfile", "Podfile"],
            aliases: ["rb"], lineComment: "# ", grammar: tree_sitter_ruby()),
        EditorLanguage("java", "Java", extensions: ["java"], blockComment: ("/*", "*/"), grammar: tree_sitter_java()),
        EditorLanguage(
            "kotlin", "Kotlin", extensions: ["kt", "kts"], aliases: ["kt"], blockComment: ("/*", "*/"), grammar: tree_sitter_kotlin()),
        EditorLanguage(
            "diff", "Diff", extensions: ["diff", "patch"], aliases: ["patch"], lineComment: nil,
            grammar: tree_sitter_diff()),
    ]
}
