import Foundation

/// A coding agent Overterm can start in a tab. Built in on purpose — known
/// CLIs, not a plugin slot. Adding one is this enum: its name, commands,
/// symbol, how its process is recognised, and `AgentLaunch`'s handoffs
/// (the bridge, its own attention signal, Terraform's guard).
///
/// What each CLI was checked against (docs/architecture.md, Agents):
/// Claude Code 2.1, Codex (openai/codex c08843a), opencode 1.18.31,
/// pi 0.73.1, Gemini CLI 0.40.1.
enum Agent: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, codex, opencode, pi, gemini

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .pi: "pi"
        case .gemini: "Gemini"
        }
    }

    /// Typed into a fresh shell to start the agent.
    var command: String { rawValue }

    /// Typed into a restored tab to pick the last conversation back up in
    /// that directory — each CLI's own flag (`--help`):
    /// `opencode --continue` ("continue the last session"), `pi --continue`
    /// (the newest session of the directory), `gemini --resume latest`
    /// (sessions are per project).
    var resumeCommand: String {
        switch self {
        case .claude: "claude --continue"
        case .codex: "codex resume --last"
        case .opencode: "opencode --continue"
        case .pi: "pi --continue"
        case .gemini: "gemini --resume latest"
        }
    }

    /// Picks one conversation back up (Claude Code's --resume); nil for
    /// an id that isn't one.
    static func claudeResume(session id: String, launch: AgentLaunch = AgentLaunch()) -> String? {
        ClaudeSession.isValidID(id) ? launch.line("claude --resume \(id)") : nil
    }

    /// The command with what this launch adds (`AgentLaunch`: Settings ▸
    /// Agents' arguments, the bridge, the attention signal).
    func command(_ launch: AgentLaunch) -> String { launch.line(command) }
    func resumeCommand(_ launch: AgentLaunch) -> String { launch.line(resumeCommand) }
    /// With Settings ▸ Agents' arguments only.
    func command(arguments: String) -> String { command(AgentLaunch(arguments: arguments)) }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "curlybraces"
        case .pi: "p.circle"
        case .gemini: "diamond"
        }
    }

    /// Settings ▸ Agents' extra arguments for it.
    var argumentsKey: String { "agents.\(rawValue)Arguments" }

    /// The placeholder of that field: a flag the CLI's `--help` lists.
    var argumentsPlaceholder: String {
        switch self {
        case .claude: "--model opus"
        case .codex: "-m gpt-5"
        case .opencode: "-m anthropic/claude-sonnet-4-5"
        case .pi: "--model sonnet"
        case .gemini: "-m gemini-2.5-pro"
        }
    }

    /// Reads a clipboard image itself on ⌃V (`ImagePaste`): Claude Code,
    /// Codex; pi's README ("Ctrl+V to paste"), Gemini CLI's `input_paste`
    /// on ctrl+v with its clipboard-image read. opencode's isn't
    /// established, so ⌘V there is left alone.
    var takesClipboardImage: Bool { self != .opencode }

    // MARK: Recognising its process

    /// A process name (`ps -o comm`, MAXCOMLEN-cut) that is this agent:
    /// Claude Code, Codex's native binary, opencode's compiled Bun binary,
    /// and pi (it sets `process.title = "pi"`). Gemini CLI runs as `node`
    /// — found by its argv (`of(arguments:)`).
    static func of(processName name: String) -> Agent? {
        switch name {
        case "claude": .claude
        case "codex": .codex
        case "opencode": .opencode
        case "pi": .pi
        default: nil
        }
    }

    /// Interpreters an agent's script runs under.
    static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// The agent an argv runs: its first word by base name (`claude`,
    /// `/opt/homebrew/bin/codex`), or — under `node` — the script it runs,
    /// past the interpreter's flags: `node /opt/homebrew/bin/gemini`, and
    /// Gemini CLI's relaunched child, `node --max-old-space-size=… …/
    /// @google/gemini-cli/bundle/gemini.js`. Pure.
    static func of(arguments: [String]) -> Agent? {
        // The words as the line splits them: a word may hold several.
        let words = arguments.flatMap { $0.split(separator: " ").map(String.init) }
        guard let first = words.first else { return nil }
        let base = (first as NSString).lastPathComponent
        if let agent = Agent(rawValue: base) { return agent }
        guard interpreters.contains(base) || base.hasPrefix("node") else { return nil }
        guard let script = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        return of(script: script)
    }

    /// A script path an interpreter runs, by its name or its package.
    static func of(script: String) -> Agent? {
        var name = (script as NSString).lastPathComponent
        for suffix in [".js", ".mjs", ".cjs", ".ts"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        if let agent = Agent(rawValue: name) { return agent }
        let packages: [(String, Agent)] = [
            ("/@google/gemini-cli/", .gemini), ("/gemini-cli/bundle/", .gemini), ("/@mariozechner/pi-coding-agent/", .pi),
            ("/@openai/codex/", .codex), ("/@anthropic-ai/claude-code/", .claude), ("/opencode-ai/", .opencode),
        ]
        return packages.first { script.contains($0.0) }?.1
    }
}
