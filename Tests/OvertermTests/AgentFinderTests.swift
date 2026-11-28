import XCTest

@testable import Overterm
@testable import OvertermShell

/// Onboarding 7.4: an agent's CLI where a new tab's shell would look, or
/// said before its command is typed. Nothing is run: every lookup is an
/// injected `isExecutable`.
final class AgentFinderTests: XCTestCase {
    private let home = "/Users/someone"

    private func find(_ agent: Agent, path: String?, executables: Set<String>, known: [String]? = nil) -> AgentFinder.Result {
        var asked: [String] = []
        let result = AgentFinder.find(
            agent, environment: path.map { ["PATH": $0] }, knownPaths: known ?? AgentFinder.knownPaths(for: agent, home: home),
            isExecutable: { candidate in
                asked.append(candidate)
                return executables.contains(candidate)
            })
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("/") }, "only paths are looked at: \(asked)")
        return result
    }

    func testFoundOnTheShellsPath() {
        let result = find(.codex, path: "/usr/bin:/opt/homebrew/bin:\(home)/.bun/bin", executables: ["\(home)/.bun/bin/codex"])
        XCTAssertEqual(result, .found(URL(fileURLWithPath: "\(home)/.bun/bin/codex"), onPath: true))
        XCTAssertFalse(result.isNotFound)
        XCTAssertNil(result.pickerNote)
        XCTAssertNil(AgentFinder.warning(.codex, result), "nothing said: the command goes as before")
    }

    func testMissing() {
        let result = find(.gemini, path: "/usr/bin:/bin", executables: ["/usr/bin/git"])
        XCTAssertEqual(result, .missing)
        XCTAssertTrue(result.isNotFound)
        XCTAssertEqual(result.pickerNote, "not found")
        let warning = AgentFinder.warning(.gemini, result)
        XCTAssertEqual(warning?.title, "Gemini CLI isn’t on your PATH.")
        XCTAssertEqual(warning?.detail, "Overterm looked where a new tab’s shell looks.")
        XCTAssertFalse((warning?.title ?? "").contains("installed"), "not found, never not installed")
    }

    /// The shell hasn't answered: nothing changes, nothing is looked at.
    func testUnknownUntilTheShellAnswers() {
        let result = find(.claude, path: nil, executables: ["\(home)/.local/bin/claude"])
        XCTAssertEqual(result, .unknown)
        XCTAssertFalse(result.isNotFound)
        XCTAssertNil(result.pickerNote)
        XCTAssertNil(AgentFinder.warning(.claude, result))
    }

    /// Claude Code's installers' places: found there and not on the PATH —
    /// its local install, reached by an alias — nothing is said and nothing
    /// falls back; the picker's note is quiet.
    func testClaudeCodesKnownPlaces() {
        XCTAssertEqual(
            AgentFinder.knownPaths(for: .claude, home: home),
            ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.bun/bin/claude"])
        XCTAssertEqual(AgentFinder.knownPaths(for: .codex, home: home), [], "other agents have none")

        let offPath = find(.claude, path: "/usr/bin:/bin", executables: ["\(home)/.claude/local/claude"])
        XCTAssertEqual(offPath, .found(URL(fileURLWithPath: "\(home)/.claude/local/claude"), onPath: false))
        XCTAssertFalse(offPath.isNotFound, "found: an alias may reach it")
        XCTAssertEqual(offPath.pickerNote, "not on PATH")
        XCTAssertNil(AgentFinder.warning(.claude, offPath), "no warning before its tab")

        let onPath = find(.claude, path: "/usr/bin:\(home)/.local/bin", executables: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude"])
        XCTAssertEqual(onPath, .found(URL(fileURLWithPath: "\(home)/.local/bin/claude"), onPath: true), "the PATH first")
    }

    /// A PATH folder under Documents, Desktop or iCloud Drive is never
    /// looked in: macOS would ask the person first.
    func testProtectedPathFoldersAreNotLookedIn() {
        var asked: [String] = []
        let result = AgentFinder.find(
            .codex, environment: ["PATH": "\(home)/Documents/bin:\(home)/Library/Mobile Documents/x:/usr/local/bin"], home: home,
            isExecutable: { candidate in
                asked.append(candidate)
                return true
            })
        XCTAssertEqual(result, .found(URL(fileURLWithPath: "/usr/local/bin/codex"), onPath: true))
        XCTAssertEqual(asked, ["/usr/local/bin/codex"], "nothing protected asked about")
    }

    func testAnEmptyPathIsMissingNotUnknown() {
        XCTAssertEqual(find(.pi, path: "", executables: []), .missing)
    }

    // MARK: New Task's picker

    func testThePickerMarksAnAgentNotFound() {
        XCTAssertEqual(NewTaskView.pickerTitle(.claude, .missing), "Claude (not found)")
        XCTAssertEqual(NewTaskView.pickerTitle(.claude, .unknown), "Claude")
        XCTAssertEqual(NewTaskView.pickerTitle(.claude, nil), "Claude")
        XCTAssertEqual(NewTaskView.pickerTitle(.codex, .found(URL(fileURLWithPath: "/usr/local/bin/codex"), onPath: true)), "Codex")
        XCTAssertEqual(
            NewTaskView.pickerTitle(.claude, .found(URL(fileURLWithPath: "\(home)/.claude/local/claude"), onPath: false)), "Claude (not on PATH)",
            "shown as any agent, with a quiet note")
    }

    func testThePickerStartsWithShellOnlyOnlyWhenTheSetAgentIsMissing() {
        XCTAssertNil(NewTaskView.startingAgent(.claude, [.claude: .missing]))
        XCTAssertEqual(
            NewTaskView.startingAgent(.claude, [.claude: .found(URL(fileURLWithPath: "\(home)/.claude/local/claude"), onPath: false)]), .claude,
            "found off the PATH (an alias's): starts as set")
        XCTAssertEqual(NewTaskView.startingAgent(.claude, [.claude: .unknown]), .claude, "not known yet: as before")
        XCTAssertEqual(NewTaskView.startingAgent(.claude, [:]), .claude)
        XCTAssertEqual(NewTaskView.startingAgent(.codex, [.claude: .missing]), .codex)
        XCTAssertNil(NewTaskView.startingAgent(nil, [:]))
    }
}
