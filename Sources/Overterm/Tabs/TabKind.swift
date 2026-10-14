import Foundation

/// What a tab *is*, at a glance: the glyph in its icon tile.
///
/// Four kinds, because in a window full of worktrees those are the four
/// things a terminal turns out to be — an agent you are talking to, a
/// server you left running, a shell you type in, a machine you are on.
/// Shape carries it faster than the title does, and the title is often
/// truncated anyway.
///
/// Pure, so the rule can be read and tested without a process tree.
enum TabKind: String, Equatable {
    case agent, server, shell, ssh

    /// The SF Symbol for the tile. An agent tab uses its own agent's symbol
    /// instead (`Agent.symbol`); this is the fallback.
    var symbol: String {
        switch self {
        case .agent: "sparkles"
        case .server: "cube"
        case .shell: "chevron.right"
        case .ssh: "globe"
        }
    }

    var name: String {
        switch self {
        case .agent: "Agent"
        case .server: "Server"
        case .shell: "Shell"
        case .ssh: "Remote"
        }
    }

    /// `title` is what the shell last set — with shell integration that is
    /// the running command, which is the only cheap evidence there is.
    /// `hasPort` is whether anything in the tab's process tree listens
    /// (`ListeningPorts`), which is what makes a shell a server.
    static func of(agent: Agent?, title: String, hasPort: Bool) -> TabKind {
        if agent != nil { return .agent }
        if isRemote(title) { return .ssh }
        if hasPort { return .server }
        return .shell
    }

    /// `ssh host`, `mosh host`, or a prompt a remote shell set — `user@host`
    /// before any space, which is what ssh leaves in the title.
    private static func isRemote(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let first = trimmed.prefix { !$0.isWhitespace }
        if first == "ssh" || first == "mosh" { return true }
        guard let at = first.firstIndex(of: "@") else { return false }
        return at != first.startIndex && first.index(after: at) != first.endIndex && !first.contains("/")
    }
}
