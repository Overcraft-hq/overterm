import Foundation

/// A coding agent Overterm can start in a tab. Built in on purpose — two
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

    /// The agent a process is, by its name or its command's first word's
    /// file (`claude`, `/opt/homebrew/bin/codex`); nil for anything else.
    /// The window's poll and the census's light tick both ask this.
    static func of(name: String, command: String) -> Agent? {
        if let agent = Agent(rawValue: name) { return agent }
        guard let first = command.split(separator: " ").first else { return nil }
        return Agent(rawValue: (String(first) as NSString).lastPathComponent)
    }

    /// Picks one conversation back up (Claude Code's --resume); nil for
    /// an id that isn't one.
    static func claudeResume(session id: String, arguments: String = "") -> String? {
        ClaudeSession.isValidID(id) ? with("claude --resume \(id)", arguments) : nil
    }

    /// The command with Settings ▸ Agents' extra arguments (e.g. `--model opus`).
    func command(arguments: String) -> String { Self.with(command, arguments) }
    func resumeCommand(arguments: String) -> String { Self.with(resumeCommand, arguments) }

    private static func with(_ command: String, _ arguments: String) -> String {
        let extra = arguments.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return extra.isEmpty ? command : "\(command) \(extra)"
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}
