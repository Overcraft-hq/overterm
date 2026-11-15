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
    /// The census's light tick and every reader of a tab's tree ask this.
    static func of(name: String, command: String) -> Agent? {
        of(name: name, argv: nil, command: command)
    }

    /// The same, with the agent argv[0]'s raw word names, as the census
    /// read it (`ProcessArguments.agent`) — a masked first word may hide it
    /// (a long relative path reads as a base64 blob) —, else the masked
    /// command's first word.
    static func of(name: String, argv: Agent?, command: String) -> Agent? {
        if let agent = Agent(rawValue: name) { return agent }
        if let argv { return argv }
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
