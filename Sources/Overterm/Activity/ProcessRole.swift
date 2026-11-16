import Foundation

/// What a process is to the agent or the pane it runs under (docs/design/
/// activity/analysis.md, 6.5, Roles), read from its name and its masked
/// argv — never the raw one. Pure.
enum ProcessRole: String, Hashable, Sendable, CaseIterable {
    /// An MCP server: `mcp` a word of its argv (`@playwright/mcp`,
    /// `acme-mcp-server`), `@modelcontextprotocol/…`.
    case mcp
    /// A shell run with a command: an agent's Bash tool, Codex's snapshot
    /// shells.
    case shell
    /// It listens on TCP.
    case server
    /// A build or a test run.
    case build
    case other

    /// Its words in the agent row's counts.
    func counted(_ count: Int) -> String {
        switch self {
        case .mcp: "\(count) MCP"
        case .shell: count == 1 ? "1 shell" : "\(count) shells"
        case .server: count == 1 ? "1 server" : "\(count) servers"
        case .build: count == 1 ? "1 build" : "\(count) builds"
        case .other: count == 1 ? "1 other" : "\(count) others"
        }
    }

    static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "ksh"]
    static let packageRunners: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    /// `name`'s role, its masked `command` read word by word, `listensTCP`
    /// whether it holds a TCP listener now.
    static func of(name: String, command: String?, listensTCP: Bool) -> ProcessRole {
        let words = (command ?? "").split(separator: " ").map(String.init)
        let base = words.first.map { ($0 as NSString).lastPathComponent } ?? name
        if isMCP(name) || words.contains(where: isMCP) { return .mcp }
        if shells.contains(name) || shells.contains(base),
            words.dropFirst().contains(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" || $0 == "-cl" })
        {
            return .shell
        }
        if listensTCP { return .server }
        if isBuild(name: name, base: base, words: words) { return .build }
        return .other
    }

    /// A word naming an MCP server: `mcp` one of its alphanumeric runs, or
    /// the protocol's own scope.
    static func isMCP(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.contains("@modelcontextprotocol/") || lower.contains("mcp-server") { return true }
        return lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("mcp")
    }

    private static func isBuild(name: String, base: String, words: [String]) -> Bool {
        let rest = Array(words.dropFirst())
        if ["cargo", "xcodebuild", "pytest"].contains(name) || ["cargo", "xcodebuild", "pytest"].contains(base) { return true }
        if packageRunners.contains(base) || packageRunners.contains(name) {
            return rest.first == "test" || (rest.first == "run" && rest.dropFirst().first == "test")
        }
        if base == "swift" || name == "swift-build" { return rest.first == "build" || rest.first == "test" || name == "swift-build" }
        if base == "go" { return rest.first == "test" }
        if base.hasPrefix("python") { return rest.starts(with: ["-m", "pytest"]) }
        return false
    }
}
