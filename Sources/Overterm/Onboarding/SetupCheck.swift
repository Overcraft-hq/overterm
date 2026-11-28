import Foundation

/// What this Mac has of what Overterm leans on, as `SetupProbe` found it
/// (docs/design/onboarding/analysis.md, 6.1, 3.1): paths, flags and
/// counts, nothing else — never a value of the shell's environment, never
/// anything read inside a file. Kept in memory only.
package struct SetupFacts: Equatable, Sendable {
    /// Whether the login shell has said its PATH. Until it has, the agents'
    /// row says "Asking your shell…".
    package var shellAnswered: Bool
    /// Each agent's CLI, where a new tab's shell would find it (`AgentFinder`).
    package var agents: [Agent: AgentFinder.Result]
    /// Claude Code and Codex, used on this Mac before: their own folders
    /// exist (`~/.claude/projects`, `~/.codex/sessions`) — never read.
    package var usedBefore: Set<Agent>
    /// Command Line Tools or Xcode is installed: git is there to run.
    package var developerTools: Bool
    /// `gh` where Overterm runs it from (`GitHub.executable`).
    package var gh: URL?
    /// `gh` on the login shell's PATH — told apart when Overterm doesn't look there.
    package var ghOnPath: URL?

    package init(
        shellAnswered: Bool, agents: [Agent: AgentFinder.Result] = [:], usedBefore: Set<Agent> = [], developerTools: Bool = true, gh: URL? = nil,
        ghOnPath: URL? = nil
    ) {
        self.shellAnswered = shellAnswered
        self.agents = agents
        self.usedBefore = usedBefore
        self.developerTools = developerTools
        self.gh = gh
        self.ghOnPath = ghOnPath
    }

    /// The agents a new tab's shell would find, used-here-before first,
    /// then in `Agent`'s order.
    package var agentsFound: [Agent] {
        let found = Agent.allCases.filter { candidate in
            if case .found(_, onPath: true) = agents[candidate] { return true }
            return false
        }
        return found.filter { usedBefore.contains($0) } + found.filter { !usedBefore.contains($0) }
    }
}

/// One row of a setup check: what it is about, and what was found.
package struct SetupRow: Equatable, Sendable {
    package enum ID: String, Sendable {
        case agents, git, gh
    }

    package let id: ID
    package let title: String
    package let detail: String
    /// Something Overterm leans on is missing or not where it looks.
    package let isProblem: Bool
}

/// The rows of the setup check (6.1, 6.3), pure. Stage 3 has the three
/// that block the first task — the agents, git, the GitHub CLI — for the
/// Start card's second step; the Setup page (stage 5) adds the rest.
///
/// Its words are "found" and "used here before", never "signed in" or
/// "installed": nothing was run to find out (3.2).
package enum SetupCheck {
    package static func rows(facts: SetupFacts, home: String = NSHomeDirectory()) -> [SetupRow] {
        [agentsRow(facts), gitRow(facts), ghRow(facts, home: home)]
    }

    private static func agentsRow(_ facts: SetupFacts) -> SetupRow {
        guard facts.shellAnswered else { return SetupRow(id: .agents, title: "Agents", detail: "Asking your shell…", isProblem: false) }
        let found = facts.agentsFound
        guard !found.isEmpty else { return SetupRow(id: .agents, title: "Agents", detail: "No agent found on your PATH.", isProblem: true) }
        let names = found.map { $0.productName + (facts.usedBefore.contains($0) ? " · used here before" : "") }
        return SetupRow(id: .agents, title: "Agents", detail: "found: " + names.joined(separator: ", "), isProblem: false)
    }

    private static func gitRow(_ facts: SetupFacts) -> SetupRow {
        facts.developerTools
            ? SetupRow(id: .git, title: "git", detail: "found", isProblem: false)
            : SetupRow(id: .git, title: "git", detail: "Command Line Tools not found", isProblem: true)
    }

    private static func ghRow(_ facts: SetupFacts, home: String) -> SetupRow {
        if facts.gh != nil { return SetupRow(id: .gh, title: "GitHub CLI", detail: "found", isProblem: false) }
        if let onPath = facts.ghOnPath {
            let path = onPath.path.hasPrefix(home + "/") ? "~" + String(onPath.path.dropFirst(home.count)) : onPath.path
            return SetupRow(id: .gh, title: "GitHub CLI", detail: "on your PATH at \(path), but Overterm looks in three folders", isProblem: true)
        }
        return SetupRow(id: .gh, title: "GitHub CLI", detail: "not found · pull requests and CI need it", isProblem: true)
    }
}
