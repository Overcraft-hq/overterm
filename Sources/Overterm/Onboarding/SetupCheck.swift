import Foundation

/// What this Mac has of what Overterm leans on, as `SetupProbe` found it
/// (docs/design/onboarding/analysis.md, 6.1, 3.1, 7.7): paths, flags and
/// counts, nothing else — never a value of the shell's environment, never
/// anything read inside a file. Kept in memory only, while the page or the
/// card that asked shows.
package struct SetupFacts: Equatable, Sendable {
    /// Whether the login shell has said its PATH. Until it has, the agents'
    /// rows say "Asking your shell…".
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
    /// Gemini CLI's system defaults file is set — the file, or its variable
    /// in the app's environment: the launch leaves it alone, so Overterm's
    /// tools aren't handed to Gemini CLI (`AgentLaunch`, the same two tests).
    package var geminiSystemDefaults: Bool
    /// Notifications as macOS says now — never a kept "allowed" (D-14); nil: not read.
    package var notifications: NotificationPermission?
    /// The agents' tool groups Settings turns on (`BrowserBridge.wanted`'s eight).
    package var toolGroups: Int
    /// The bridge is listening (`BrowserBridge.isServing`).
    package var bridgeServing: Bool

    package init(
        shellAnswered: Bool, agents: [Agent: AgentFinder.Result] = [:], usedBefore: Set<Agent> = [], developerTools: Bool = true, gh: URL? = nil,
        ghOnPath: URL? = nil, geminiSystemDefaults: Bool = false, notifications: NotificationPermission? = nil, toolGroups: Int = 0,
        bridgeServing: Bool = false
    ) {
        self.shellAnswered = shellAnswered
        self.agents = agents
        self.usedBefore = usedBefore
        self.developerTools = developerTools
        self.gh = gh
        self.ghOnPath = ghOnPath
        self.geminiSystemDefaults = geminiSystemDefaults
        self.notifications = notifications
        self.toolGroups = toolGroups
        self.bridgeServing = bridgeServing
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

/// One row of a setup check: what it is about, what was found, where
/// Overterm looked, and what the person can do about it.
package struct SetupRow: Equatable, Sendable {
    package enum ID: Hashable, Sendable {
        case shell, git, gh
        case agent(Agent)
        case notifications, bridge
        case docker, dockerEngine
        case dockerPlugin(String)
        case kubectl, kubeconfig, kubePlugins, helm, terraform, tofu, languageServers, simulator, ghosttyConfig

        /// Its accessibility identifier's last part.
        package var key: String {
            switch self {
            case .shell: "shell"
            case .git: "git"
            case .gh: "gh"
            case .agent(let agent): "agent.\(agent.rawValue)"
            case .notifications: "notifications"
            case .bridge: "bridge"
            case .docker: "docker"
            case .dockerEngine: "dockerEngine"
            case .dockerPlugin(let name): "dockerPlugin.\(name)"
            case .kubectl: "kubectl"
            case .kubeconfig: "kubeconfig"
            case .kubePlugins: "kubePlugins"
            case .helm: "helm"
            case .terraform: "terraform"
            case .tofu: "tofu"
            case .languageServers: "languageServers"
            case .simulator: "simulator"
            case .ghosttyConfig: "ghosttyConfig"
            }
        }
    }

    /// What a row offers. Nothing fixes anything (3.2): a command is copied
    /// or typed into a new tab with no Return, a link opens a page.
    package enum Action: Equatable, Sendable {
        /// Copy, and Put in a New Tab.
        case command(String)
        /// The tool's own install page — an agent's, never a command that
        /// would go stale (risk 13).
        case page(URL)
        /// A Settings page, at a setting.
        case settings(SettingsSection, key: String?)
        /// macOS's question, by this click (D-6).
        case allowNotifications
    }

    package let id: ID
    package let title: String
    package let detail: String
    /// Found: the dot is filled. The words say it too — the dot is never alone.
    package let found: Bool
    /// Something Overterm leans on is missing or not where it looks.
    package let isProblem: Bool
    /// Where Overterm looked, in a line under it.
    package let looked: String?
    package let action: Action?
    /// More, folded under it (each language server).
    package let more: [String]

    package init(
        id: ID, title: String, detail: String, found: Bool, isProblem: Bool = false, looked: String? = nil, action: Action? = nil, more: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.found = found
        self.isProblem = isProblem
        self.looked = looked
        self.action = action
        self.more = more
    }
}

/// The rows of the setup check (6.1, 6.3, 7.7), pure. The core rows always:
/// the shell, git, the GitHub CLI, one per agent (`Agent.allCases` — a new
/// agent gets its row, `SetupCheckTests` holds it), notifications, the
/// bridge. The panels' rows only when that section is opened. The Start
/// card's second step shows git's and gh's when they are wrong
/// (`StartText.problems`).
///
/// Its words are "found" and "used here before", never "signed in" or
/// "installed": nothing was run to find out (3.2).
package enum SetupCheck {
    // MARK: The page's words

    package static let title = "Setup"
    /// The login shell's startup files run when it is asked, so never "Nothing was run" (14.1).
    package static let note = "Found by asking your login shell for its PATH and looking at files. No tool was run."
    package static let asking = "Asking your shell…"
    package static let checkAgain = "Check Again"
    package static let runsByItselfTitle = "What runs by itself"
    package static let usageTitle = "Ask the agents for fresh usage numbers"
    /// D-7: what `general.usageAsk` does, beside its switch.
    package static let usageDetail =
        "Runs the agent's own usage command (claude -p \"/usage\") every ten minutes while Overterm is in front. Off, the usage pane shows the last figures the agent wrote down."
    package static let gettingStartedTitle = "Getting started"
    /// D-12.
    package static let keptHere = "Kept on this Mac only."
    package static let noStepsYet = "No step of Getting Started done yet."
    package static let resetTips = "Reset Tips"
    package static let copy = "Copy"
    package static let putInNewTab = "Put in a New Tab"
    package static let installPage = "Its install page"
    package static let allowNotifications = "Allow…"

    /// The core rows.
    package static func rows(facts: SetupFacts, home: String = NSHomeDirectory()) -> [SetupRow] {
        [shellRow(facts), gitRow(facts), ghRow(facts, home: home)] + Agent.allCases.map { agentRow($0, facts, home: home) }
            + [notificationsRow(facts), bridgeRow(facts)]
    }

    // MARK: Install pages and commands (risk 13: one table, listed by a test)

    /// Each agent's own install page: a link, never a fixed command.
    package static func installPage(_ agent: Agent) -> URL {
        switch agent {
        case .claude: URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!
        case .codex: URL(string: "https://github.com/openai/codex")!
        case .opencode: URL(string: "https://opencode.ai")!
        case .pi: URL(string: "https://github.com/badlogic/pi-mono")!
        case .gemini: URL(string: "https://github.com/google-gemini/gemini-cli")!
        }
    }

    /// The commands a row offers to copy or type into a new tab, by row.
    package static let installCommands: [String: String] = [
        SetupRow.ID.git.key: "xcode-select --install",
        SetupRow.ID.gh.key: "brew install gh",
    ]

    /// GitHub CLI's own words for signing in; never checked here (`gh auth status` reads its token store).
    package static let ghLogin = "gh auth login"

    // MARK: Core rows

    private static func shellRow(_ facts: SetupFacts) -> SetupRow {
        SetupRow(
            id: .shell, title: "Shell", detail: facts.shellAnswered ? "answered" : "didn't answer in \(Int(ShellEnvironment.timeout)) s",
            found: facts.shellAnswered, isProblem: !facts.shellAnswered, looked: "Your login shell, asked once for its PATH. No value is shown.")
    }

    private static func gitRow(_ facts: SetupFacts) -> SetupRow {
        let looked = "Only whether /Library/Developer/CommandLineTools or /Applications/Xcode.app is there: git isn't run to find out."
        return facts.developerTools
            ? SetupRow(id: .git, title: "git", detail: "Command Line Tools found", found: true, looked: looked)
            : SetupRow(
                id: .git, title: "git", detail: "Command Line Tools not found", found: false, isProblem: true, looked: looked,
                action: installCommands[SetupRow.ID.git.key].map(SetupRow.Action.command))
    }

    private static func ghRow(_ facts: SetupFacts, home: String) -> SetupRow {
        let looked = "Overterm runs gh from /opt/homebrew/bin, /usr/local/bin or /usr/bin."
        if let gh = facts.gh {
            return SetupRow(
                id: .gh, title: "GitHub CLI", detail: "\(tilde(gh.path, home: home)) · whether you're logged in isn't checked", found: true,
                looked: looked, action: .command(ghLogin))
        }
        let command = installCommands[SetupRow.ID.gh.key].map(SetupRow.Action.command)
        if let onPath = facts.ghOnPath {
            return SetupRow(
                id: .gh, title: "GitHub CLI", detail: "on your PATH at \(tilde(onPath.path, home: home)), but Overterm looks in three folders", found: false,
                isProblem: true, looked: looked, action: command)
        }
        return SetupRow(
            id: .gh, title: "GitHub CLI", detail: "not found · pull requests, CI and update checks need it", found: false, isProblem: true, looked: looked,
            action: command)
    }

    private static func agentRow(_ agent: Agent, _ facts: SetupFacts, home: String) -> SetupRow {
        let id = SetupRow.ID.agent(agent)
        let looked =
            agent == .claude
            ? "Your login shell's PATH, where its tab looks, then Claude Code's installers' places. Never run."
            : "Your login shell's PATH, where its tab looks. Never run."
        // pi has no MCP, by design: said whether it is found or not.
        let suffix = agent == .pi ? " · gets no Overterm tools" : ""
        let page = SetupRow.Action.page(installPage(agent))
        guard facts.shellAnswered else {
            return SetupRow(id: id, title: agent.productName, detail: "not looked for: the shell didn't answer" + suffix, found: false, looked: looked)
        }
        switch facts.agents[agent] ?? .unknown {
        case .found(let url, let onPath):
            var detail = tilde(url.path, home: home)
            if !onPath { detail = "at \(detail), not on your PATH: its tab won't find it unless an alias names it" }
            if facts.usedBefore.contains(agent) { detail += " · used here before" }
            if agent == .gemini, facts.geminiSystemDefaults {
                detail += " · a system defaults file is set, so Overterm's tools aren't handed to it"
            }
            return SetupRow(id: id, title: agent.productName, detail: detail + suffix, found: onPath, looked: looked, action: onPath ? nil : page)
        case .missing, .unknown:
            return SetupRow(id: id, title: agent.productName, detail: "not on your PATH" + suffix, found: false, looked: looked, action: page)
        }
    }

    private static func notificationsRow(_ facts: SetupFacts) -> SetupRow {
        let looked = "As macOS says now; nothing kept."
        switch facts.notifications {
        case .notAsked?:
            return SetupRow(id: .notifications, title: "Notifications", detail: "not asked yet", found: false, looked: looked, action: .allowNotifications)
        case .allowed?:
            return SetupRow(id: .notifications, title: "Notifications", detail: "allowed", found: true, looked: looked)
        case .denied?:
            return SetupRow(
                id: .notifications, title: "Notifications", detail: "turned off in System Settings ▸ Notifications", found: false, looked: looked)
        case nil:
            return SetupRow(id: .notifications, title: "Notifications", detail: "not read", found: false, looked: looked)
        }
    }

    private static func bridgeRow(_ facts: SetupFacts) -> SetupRow {
        let looked = "On this Mac only (loopback), a token per pane. Nothing was sent."
        let settings = SetupRow.Action.settings(.agents, key: nil)
        guard facts.toolGroups > 0 else {
            return SetupRow(id: .bridge, title: "Agents' tools", detail: "off · no agent gets Overterm's tools", found: false, looked: looked, action: settings)
        }
        let groups = facts.toolGroups == 1 ? "1 tool group" : "\(facts.toolGroups) tool groups"
        guard facts.bridgeServing else {
            return SetupRow(
                id: .bridge, title: "Agents' tools", detail: "not serving: its listener didn't start (\(groups) on)", found: false, isProblem: true,
                looked: looked, action: settings)
        }
        return SetupRow(id: .bridge, title: "Agents' tools", detail: "serving \(groups) · Settings ▸ Agents", found: true, looked: looked, action: settings)
    }

    // MARK: Getting started (D-12)

    /// The person's own step times, from the first launch when it is known,
    /// else from the first step done. Nil when no step is done.
    package static func stepTimes(_ steps: [StartState.Step: Date], firstLaunch: Date?) -> String? {
        let done = StartState.Step.allCases.compactMap { step in steps[step].map { (step, $0) } }
        guard let first = done.first else { return nil }
        let origin = firstLaunch ?? done.map { pair in pair.1 }.min() ?? first.1
        var parts: [String] = []
        for (index, (step, date)) in done.enumerated() {
            let after = duration(date.timeIntervalSince(origin))
            let phrase = stepPhrase(step)
            if index == 0 {
                let capital = phrase.prefix(1).uppercased() + phrase.dropFirst()
                parts.append(firstLaunch == nil ? capital : "\(capital) \(after) after the first launch")
            } else {
                parts.append("\(phrase) after \(after)")
            }
        }
        return parts.joined(separator: " · ")
    }

    package static func stepPhrase(_ step: StartState.Step) -> String {
        switch step {
        case .repository: "opened a repository"
        case .agent: "picked what works on it"
        case .task: "first task"
        case .answered: "answered a tab"
        case .changes: "saw the changes"
        }
    }

    /// "under a minute", "6 min", "3 h", "2 days". Pure.
    package static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "under a minute" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 48 * 3600 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86400)) days"
    }

    /// A path with the home folder as `~`.
    package static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }
}
