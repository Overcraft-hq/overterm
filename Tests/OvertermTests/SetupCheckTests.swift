import XCTest

@testable import Overterm

/// Onboarding 6.1, 7.7, 3.1–3.2: the Setup page's core rows from facts
/// alone — found, missing and turned-off words, where Overterm looked —
/// and the probe that fills them, which only looks (a file's existence,
/// whether it is executable), never inside the agents' folders, never
/// under Documents, Desktop or iCloud Drive (risk 11).
final class SetupCheckTests: XCTestCase {
    private let home = "/Users/someone"
    private var places: SetupProbe.Places {
        SetupProbe.Places(home: home, claudeProjects: home + "/.claude/projects", codexSessions: home + "/.codex/sessions")
    }

    private func row(_ id: SetupRow.ID, _ facts: SetupFacts) -> SetupRow? {
        SetupCheck.rows(facts: facts, home: home).first { $0.id == id }
    }

    /// The core rows, in order: the shell, git, gh, one per agent — every
    /// one of `Agent.allCases` (a sixth agent gets its row: risk 9) —,
    /// notifications, the bridge.
    func testEveryAgentHasARow() {
        let rows = SetupCheck.rows(facts: SetupFacts(shellAnswered: true), home: home)
        let agents: [SetupRow.ID] = Agent.allCases.map { agent in .agent(agent) }
        let expected: [SetupRow.ID] = [.shell, .git, .gh] + agents + [.notifications, .bridge]
        XCTAssertEqual(rows.map(\.id), expected)
        XCTAssertEqual(Agent.allCases.count, 5, "a new agent: its row, its install page, and this count")
        XCTAssertEqual(Set(rows.map(\.id.key)).count, rows.count, "each row its own identifier")
        XCTAssertTrue(rows.allSatisfy { $0.looked != nil }, "every core row says where Overterm looked")
    }

    func testTheShellNotAnsweredIsSaidSo() {
        let facts = SetupFacts(shellAnswered: false)
        XCTAssertEqual(row(.shell, facts)?.detail, "didn't answer in 10 s")
        XCTAssertEqual(row(.shell, facts)?.isProblem, true)
        XCTAssertEqual(row(.agent(.codex), facts)?.detail, "not looked for: the shell didn't answer")
        XCTAssertEqual(row(.shell, SetupFacts(shellAnswered: true))?.detail, "answered")
    }

    func testAgentsFoundAndUsedHereBefore() {
        let facts = SetupFacts(
            shellAnswered: true,
            agents: [
                .codex: .found(URL(fileURLWithPath: "/opt/homebrew/bin/codex"), onPath: true),
                .claude: .found(URL(fileURLWithPath: home + "/.local/bin/claude"), onPath: true),
                .opencode: .missing,
            ],
            usedBefore: [.codex, .claude], gh: URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
        XCTAssertEqual(facts.agentsFound, [.claude, .codex], "used here before first, then Agent's order")
        XCTAssertEqual(row(.agent(.claude), facts)?.detail, "~/.local/bin/claude · used here before")
        XCTAssertEqual(row(.agent(.codex), facts)?.detail, "/opt/homebrew/bin/codex · used here before")
        XCTAssertEqual(row(.agent(.codex), facts)?.found, true)
        XCTAssertNil(row(.agent(.codex), facts)?.action, "found: nothing to offer")
        XCTAssertEqual(row(.agent(.opencode), facts)?.detail, "not on your PATH")
        XCTAssertEqual(row(.agent(.opencode), facts)?.action, .page(SetupCheck.installPage(.opencode)))
        let rows = SetupCheck.rows(facts: facts, home: home)
        XCTAssertFalse(rows.contains { $0.detail.contains("signed in") || $0.detail.contains("installed") }, "found, never signed in")
    }

    /// Found only in one of Claude Code's installers' places: not where its tab looks.
    func testAnAgentOffThePath() {
        let facts = SetupFacts(shellAnswered: true, agents: [.claude: .found(URL(fileURLWithPath: home + "/.claude/local/claude"), onPath: false)])
        let claude = row(.agent(.claude), facts)
        XCTAssertEqual(claude?.detail, "at ~/.claude/local/claude, not on your PATH: its tab won't find it unless an alias names it")
        XCTAssertEqual(claude?.found, false)
        XCTAssertEqual(claude?.action, .page(SetupCheck.installPage(.claude)))
    }

    /// pi gets no tools, found or not; Gemini CLI's system defaults said once found.
    func testPiAndGeminisOwnWords() {
        let missing = SetupFacts(shellAnswered: true, agents: [.pi: .missing, .gemini: .missing], geminiSystemDefaults: true)
        XCTAssertEqual(row(.agent(.pi), missing)?.detail, "not on your PATH · gets no Overterm tools")
        XCTAssertEqual(row(.agent(.gemini), missing)?.detail, "not on your PATH")
        let found = SetupFacts(
            shellAnswered: true,
            agents: [
                .pi: .found(URL(fileURLWithPath: "/opt/homebrew/bin/pi"), onPath: true),
                .gemini: .found(URL(fileURLWithPath: "/opt/homebrew/bin/gemini"), onPath: true),
            ], geminiSystemDefaults: true)
        XCTAssertEqual(row(.agent(.pi), found)?.detail, "/opt/homebrew/bin/pi · gets no Overterm tools")
        XCTAssertEqual(
            row(.agent(.gemini), found)?.detail, "/opt/homebrew/bin/gemini · a system defaults file is set, so Overterm's tools aren't handed to it")
        var plain = found
        plain.geminiSystemDefaults = false
        XCTAssertEqual(row(.agent(.gemini), plain)?.detail, "/opt/homebrew/bin/gemini")
    }

    func testGitAndGhMissing() {
        let facts = SetupFacts(shellAnswered: true, developerTools: false, gh: nil)
        XCTAssertEqual(row(.git, facts)?.detail, "Command Line Tools not found")
        XCTAssertEqual(row(.git, facts)?.action, .command("xcode-select --install"))
        XCTAssertEqual(row(.gh, facts)?.detail, "not found · pull requests, CI and update checks need it")
        XCTAssertEqual(row(.gh, facts)?.action, .command("brew install gh"))
        XCTAssertTrue([row(.git, facts), row(.gh, facts)].allSatisfy { $0?.isProblem == true })
        XCTAssertEqual(row(.git, SetupFacts(shellAnswered: true))?.detail, "Command Line Tools found")
    }

    /// gh found: its place, and the login command shown — never checked.
    func testGhFoundIsNeverSaidLoggedIn() {
        let gh = row(.gh, SetupFacts(shellAnswered: true, gh: URL(fileURLWithPath: "/opt/homebrew/bin/gh")))
        XCTAssertEqual(gh?.detail, "/opt/homebrew/bin/gh · whether you're logged in isn't checked")
        XCTAssertEqual(gh?.action, .command("gh auth login"))
        XCTAssertEqual(gh?.isProblem, false)
    }

    /// gh on the shell's PATH but in none of the three folders Overterm runs it from.
    func testGhOnThePathButNotWhereOvertermLooks() {
        let facts = SetupFacts(shellAnswered: true, gh: nil, ghOnPath: URL(fileURLWithPath: home + "/.local/share/mise/shims/gh"))
        let gh = row(.gh, facts)
        XCTAssertEqual(gh?.detail, "on your PATH at ~/.local/share/mise/shims/gh, but Overterm looks in three folders")
        XCTAssertEqual(gh?.isProblem, true)
    }

    /// As macOS says now; Allow… only while it hasn't asked.
    func testNotifications() {
        func notifications(_ permission: NotificationPermission?) -> SetupRow? { row(.notifications, SetupFacts(shellAnswered: true, notifications: permission)) }
        XCTAssertEqual(notifications(.notAsked)?.detail, "not asked yet")
        XCTAssertEqual(notifications(.notAsked)?.action, .allowNotifications)
        XCTAssertEqual(notifications(.allowed)?.detail, "allowed")
        XCTAssertNil(notifications(.allowed)?.action)
        XCTAssertEqual(notifications(.denied)?.detail, "turned off in System Settings ▸ Notifications")
        XCTAssertNil(notifications(.denied)?.action, "nothing here asks again")
        XCTAssertEqual(notifications(nil)?.detail, "not read")
    }

    /// Serving, off in Settings, or wanted but not listening.
    func testTheBridge() {
        XCTAssertEqual(row(.bridge, SetupFacts(shellAnswered: true, toolGroups: 8, bridgeServing: true))?.detail, "serving 8 tool groups · Settings ▸ Agents")
        XCTAssertEqual(row(.bridge, SetupFacts(shellAnswered: true, toolGroups: 1, bridgeServing: true))?.detail, "serving 1 tool group · Settings ▸ Agents")
        let off = row(.bridge, SetupFacts(shellAnswered: true, toolGroups: 0))
        XCTAssertEqual(off?.detail, "off · no agent gets Overterm's tools")
        XCTAssertEqual(off?.isProblem, false)
        let down = row(.bridge, SetupFacts(shellAnswered: true, toolGroups: 3, bridgeServing: false))
        XCTAssertEqual(down?.detail, "not serving: its listener didn't start (3 tool groups on)")
        XCTAssertEqual(down?.isProblem, true)
        XCTAssertEqual(down?.action, .settings(.agents, key: nil))
    }

    /// The page's words: no tool was run — never "nothing was run" (14.1).
    func testThePageSaysNoToolWasRun() {
        XCTAssertEqual(SetupCheck.note, "Found by asking your login shell for its PATH and looking at files. No tool was run.")
        XCTAssertTrue(SetupCheck.usageDetail.contains("every ten minutes"), "D-7: what general.usageAsk does")
        XCTAssertEqual(SetupCheck.keptHere, "Kept on this Mac only.")
    }

    /// Risk 13: the install links and commands in one table, listed here
    /// for review. Agents get their own page, never a fixed command.
    func testTheInstallTable() {
        XCTAssertEqual(
            Agent.allCases.map { SetupCheck.installPage($0).absoluteString },
            [
                "https://docs.anthropic.com/en/docs/claude-code/setup", "https://github.com/openai/codex", "https://opencode.ai",
                "https://github.com/badlogic/pi-mono", "https://github.com/google-gemini/gemini-cli",
            ])
        XCTAssertTrue(Agent.allCases.allSatisfy { SetupCheck.installPage($0).scheme == "https" })
        XCTAssertEqual(SetupCheck.installCommands, ["git": "xcode-select --install", "gh": "brew install gh"])
        XCTAssertFalse(Agent.allCases.contains { SetupCheck.installCommands[SetupRow.ID.agent($0).key] != nil }, "no agent has a fixed command")
    }

    /// D-12: the person's own step times, from the first launch.
    func testStepTimes() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(SetupCheck.stepTimes([:], firstLaunch: launch))
        let steps: [StartState.Step: Date] = [
            .repository: launch.addingTimeInterval(120), .task: launch.addingTimeInterval(360), .changes: launch.addingTimeInterval(3 * 3600),
        ]
        XCTAssertEqual(
            SetupCheck.stepTimes(steps, firstLaunch: launch),
            "Opened a repository 2 min after the first launch · first task after 6 min · saw the changes after 3 h")
        XCTAssertEqual(
            SetupCheck.stepTimes(steps, firstLaunch: nil), "Opened a repository · first task after 4 min · saw the changes after 2 h",
            "without the first launch: from the first step done")
        XCTAssertEqual(SetupCheck.duration(30), "under a minute")
        XCTAssertEqual(SetupCheck.duration(3 * 86400), "3 days")
    }

    /// Every path the probe touches, and how: only existence and
    /// executability, nothing inside the agents' folders but Claude Code's
    /// installers' own places, nothing under Documents, Desktop or iCloud.
    func testTheProbeOnlyLooks() {
        var looked: [String] = []
        var executable: [String] = []
        let environment = ["PATH": "/usr/bin:/opt/homebrew/bin:\(home)/.local/bin"]
        let facts = SetupProbe.facts(
            environment: environment, gh: nil, places: places,
            exists: { path in
                looked.append(path)
                return path == self.home + "/.claude/projects" || path == "/Library/Developer/CommandLineTools"
            },
            isExecutable: { path in
                executable.append(path)
                return path == "/opt/homebrew/bin/claude" || path == "/opt/homebrew/bin/gh"
            })
        XCTAssertEqual(
            looked,
            [home + "/.claude/projects", home + "/.codex/sessions", "/Library/Developer/CommandLineTools", AgentLaunchFiles.geminiSystemDefaults])
        let forbidden = ["/Documents", "/Desktop", "/Library/Mobile Documents", "/.claude.json", "/.codex/sessions/"]
        for path in looked + executable {
            XCTAssertFalse(forbidden.contains { path.contains($0) }, path)
        }
        let insideClaude = executable.filter { $0.hasPrefix(home + "/.claude/") }
        XCTAssertTrue(
            insideClaude.allSatisfy { $0 == home + "/.claude/local/claude" }, "only the installer's own place, checked as an executable: \(insideClaude)")
        XCTAssertTrue(facts.shellAnswered)
        XCTAssertEqual(facts.agents[.claude], .found(URL(fileURLWithPath: "/opt/homebrew/bin/claude"), onPath: true))
        XCTAssertEqual(facts.agents[.codex], .missing)
        XCTAssertEqual(facts.usedBefore, [.claude])
        XCTAssertTrue(facts.developerTools)
        XCTAssertEqual(facts.ghOnPath, URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
        XCTAssertFalse(facts.geminiSystemDefaults)
        XCTAssertTrue(
            SetupProbe.facts(environment: environment, gh: nil, places: places, exists: { _ in false }, isExecutable: { _ in false }, geminiVariable: true)
                .geminiSystemDefaults, "the variable in the app's environment counts, as the launch counts it")
    }

    /// A PATH folder under Desktop, Documents, Downloads or iCloud Drive is
    /// never looked in — macOS would ask the person —; the rest as before.
    func testTheProbeLooksInNoProtectedFolder() {
        var executable: [String] = []
        let environment = ["PATH": "\(home)/Documents/bin:\(home)/Desktop/bin:\(home)/Library/Mobile Documents/bin:\(home)/Downloads:/usr/local/bin"]
        let facts = SetupProbe.facts(
            environment: environment, gh: nil, places: places, exists: { _ in false },
            isExecutable: { path in
                executable.append(path)
                return path.hasSuffix("/claude") || path.hasSuffix("/gh")
            })
        XCTAssertFalse(executable.contains { path in SetupProbe.isProtected(path, home: home) }, "\(executable)")
        XCTAssertTrue(executable.contains("/usr/local/bin/codex"), "the rest of the PATH as before")
        XCTAssertEqual(facts.agents[.claude], .found(URL(fileURLWithPath: "/usr/local/bin/claude"), onPath: true))
        XCTAssertEqual(facts.ghOnPath, URL(fileURLWithPath: "/usr/local/bin/gh"))
        XCTAssertTrue(SetupProbe.isProtected(home + "/Documents", home: home))
        XCTAssertTrue(SetupProbe.isProtected(home + "/Desktop//bin/", home: home), "as the path standardizes")
        XCTAssertFalse(SetupProbe.isProtected(home + "/DocumentsArchive/bin", home: home))
        XCTAssertFalse(SetupProbe.isProtected(home + "/.local/bin", home: home))
    }

    /// Xcode selected elsewhere (`Xcode-beta.app`) counts, by the link
    /// `xcode-select` keeps — never run.
    func testASelectedXcodeElsewhereCounts() {
        let facts = SetupProbe.facts(
            environment: ["PATH": "/usr/bin"], gh: nil, places: places, exists: { path in path == "/var/db/xcode_select_link" }, isExecutable: { _ in false })
        XCTAssertTrue(facts.developerTools)
        let none = SetupProbe.facts(environment: ["PATH": "/usr/bin"], gh: nil, places: places, exists: { _ in false }, isExecutable: { _ in false })
        XCTAssertFalse(none.developerTools, "none: Command Line Tools not found, as before")
    }

    /// The shell not answered: agents unknown, nothing on its PATH looked for.
    func testTheShellNotAnsweredLooksForNothingOnItsPath() {
        var executable: [String] = []
        let facts = SetupProbe.facts(
            environment: nil, gh: nil, places: places, exists: { _ in false },
            isExecutable: { path in
                executable.append(path)
                return false
            })
        XCTAssertFalse(facts.shellAnswered)
        XCTAssertTrue(executable.isEmpty)
        XCTAssertTrue(facts.agents.values.allSatisfy { $0 == .unknown })
        XCTAssertNil(facts.ghOnPath)
        XCTAssertFalse(facts.developerTools)
    }
}
