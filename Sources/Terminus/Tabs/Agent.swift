import Foundation

/// A coding agent Terminus can start in a tab. Built in on purpose — two
/// known CLIs, not a plugin slot.
enum Agent: String, CaseIterable, Identifiable, Codable {
    case claude, codex

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Typed into a fresh shell to start the agent.
    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    /// Typed into a restored tab to pick the last conversation back up in
    /// that directory.
    var resumeCommand: String {
        switch self {
        case .claude: "claude --continue"
        case .codex: "codex resume --last"
        }
    }

    /// Picks one conversation back up (Claude Code's --resume); nil for
    /// an id that isn't one.
    static func claudeResume(session id: String) -> String? {
        ClaudeSession.isValidID(id) ? "claude --resume \(id)" : nil
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}
