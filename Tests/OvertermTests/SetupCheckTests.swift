import XCTest

@testable import Overterm

/// Onboarding 6.1, 3.1–3.2: the setup check's three blocking rows from
/// facts alone, and the probe that fills them — which only looks (a file's
/// existence, whether it is executable), never inside the agents' folders,
/// never under Documents, Desktop or iCloud Drive (risk 11).
final class SetupCheckTests: XCTestCase {
    private let home = "/Users/someone"
    private var places: SetupProbe.Places {
        SetupProbe.Places(home: home, claudeProjects: home + "/.claude/projects", codexSessions: home + "/.codex/sessions")
    }

    func testTheShellNotAnsweredIsSaidSo() {
        let rows = SetupCheck.rows(facts: SetupFacts(shellAnswered: false), home: home)
        XCTAssertEqual(rows.map(\.id), [.agents, .git, .gh])
        XCTAssertEqual(rows[0].detail, "Asking your shell…")
        XCTAssertFalse(rows[0].isProblem)
    }

    func testAgentsFoundAndUsedHereBefore() {
        let facts = SetupFacts(
            shellAnswered: true,
            agents: [.codex: .found(URL(fileURLWithPath: "/opt/homebrew/bin/codex"), onPath: true), .claude: .found(URL(fileURLWithPath: "/x/claude"), onPath: true)],
            usedBefore: [.codex], gh: URL(fileURLWithPath: "/opt/homebrew/bin/gh"))
        XCTAssertEqual(facts.agentsFound, [.codex, .claude], "used here before first")
        let rows = SetupCheck.rows(facts: facts, home: home)
        XCTAssertEqual(rows[0].detail, "found: Codex · used here before, Claude Code")
        XCTAssertFalse(rows.contains(where: \.isProblem))
        XCTAssertFalse(rows.contains { $0.detail.contains("signed in") || $0.detail.contains("installed") }, "found, never signed in")
    }

    func testNothingFound() {
        let facts = SetupFacts(shellAnswered: true, agents: [.claude: .missing], developerTools: false, gh: nil)
        let rows = SetupCheck.rows(facts: facts, home: home)
        XCTAssertEqual(rows.map(\.detail), ["No agent found on your PATH.", "Command Line Tools not found", "not found · pull requests and CI need it"])
        XCTAssertTrue(rows.allSatisfy(\.isProblem))
    }

    /// gh on the shell's PATH but in none of the three folders Overterm runs it from.
    func testGhOnThePathButNotWhereOvertermLooks() {
        let facts = SetupFacts(shellAnswered: true, gh: nil, ghOnPath: URL(fileURLWithPath: home + "/.local/share/mise/shims/gh"))
        let row = SetupCheck.rows(facts: facts, home: home)[2]
        XCTAssertEqual(row.detail, "on your PATH at ~/.local/share/mise/shims/gh, but Overterm looks in three folders")
        XCTAssertTrue(row.isProblem)
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
        XCTAssertEqual(looked, [home + "/.claude/projects", home + "/.codex/sessions", "/Library/Developer/CommandLineTools"])
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
