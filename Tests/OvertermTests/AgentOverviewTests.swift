import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI

final class AgentOverviewTests: XCTestCase {
    private func lines(_ objects: [String]) -> [Data] { objects.map { Data($0.utf8) } }

    private let title = #"{"type":"ai-title","aiTitle":"Fix the flaky login","sessionId":"s"}"#
    private let prompt = #"{"type":"user","gitBranch":"feat/login","message":{"role":"user","content":"make the login test pass"}}"#
    private let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
    private let reply = #"{"type":"assistant","gitBranch":"feat/login","message":{"content":[{"type":"text","text":"I found the race."}]}}"#
    private let tool =
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"make test\nmake lint","description":"Run the tests"}}]}}"#

    func testWhatItIsDoingNow() {
        let activity = ClaudeActivity.parse(lines: lines([title, prompt, reply, tool, toolResult]))
        XCTAssertEqual(activity.title, "Fix the flaky login")
        XCTAssertEqual(activity.lastPrompt, "make the login test pass", "a tool result is not a prompt")
        XCTAssertEqual(activity.lastReply, "I found the race.")
        XCTAssertEqual(activity.currentTool, "Bash: make test", "the command's first line")
        XCTAssertEqual(activity.branch, "feat/login")
    }

    func testWordsAfterTheToolMeanItIsNotRunningOne() {
        let activity = ClaudeActivity.parse(lines: lines([prompt, tool, toolResult, reply]))
        XCTAssertNil(activity.currentTool)
        XCTAssertEqual(activity.lastReply, "I found the race.")
    }

    func testLastPromptLineWinsAndJunkIsSkipped() {
        let activity = ClaudeActivity.parse(
            lines: lines([prompt, "{not json", #"{"type":"last-prompt","lastPrompt":"ship it"}"#, #"{"type":"mode","mode":"x"}"#]))
        XCTAssertEqual(activity.lastPrompt, "ship it")
    }

    func testReadingTheTailOfABigTranscript() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        // Older than the tail: must not be what it reports.
        var text = #"{"type":"ai-title","aiTitle":"old"}"# + "\n"
        text += String(repeating: #"{"type":"progress","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}"# + "\n", count: 12_000)
        text += [title, reply].joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let activity = try XCTUnwrap(ClaudeActivity.read(file))
        XCTAssertEqual(activity.title, "Fix the flaky login")
        XCTAssertEqual(activity.lastReply, "I found the race.")
        XCTAssertNotNil(activity.updated)
    }

    func testCardsNeedingYouComeFirst() {
        func card(_ title: String, _ events: [TerminalEvent], agent: Agent? = .claude) -> AgentOverviewModel.Card {
            var activity = TabActivity()
            events.forEach { activity.handle($0, visible: false) }
            return .init(
                id: UUID(), title: title, color: nil, agent: agent, agentRunning: agent != nil, activity: activity, directory: nil,
                branch: nil, claude: nil, panes: 1)
        }
        let cards = [
            card("shell", [], agent: nil), card("idle agent", []), card("working", [.progress(active: true, failed: false)]),
            card("waiting", [.notification(title: "Claude Code", body: "needs you")]),
            card("failed", [.progress(active: false, failed: true)]),
        ]
        XCTAssertEqual(AgentOverviewModel.ordered(cards).map(\.title), ["waiting", "failed", "working", "idle agent", "shell"])
    }

    func testBranchFromHeadIncludingALinkedWorktree() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-branch-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        let worktree = base.appendingPathComponent("wt")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "i"], in: repo)
        _ = try await Git.run(["worktree", "add", "-q", "-b", "feat/x", worktree.path], in: repo)
        XCTAssertEqual(AgentOverviewModel.branch(in: repo.appendingPathComponent("src").path), "main", "from a subdirectory")
        XCTAssertEqual(AgentOverviewModel.branch(in: worktree.path), "feat/x", "through the .git file")
        XCTAssertNil(AgentOverviewModel.branch(in: base.path), "not in a repository")
        XCTAssertEqual(AgentOverviewModel.branch(in: repo.path + "/src/../src/.."), "main", "its ..s resolved first")
    }

    /// The walk up stops (2.4 item 11, CLAUDE.md's "/" rule): at the top,
    /// from "/" itself and from a folder whose `..`s climb past it, and
    /// after its bound from a deep folder — a repository further up than
    /// that isn't looked for.
    func testTheWalkUpIsBounded() throws {
        XCTAssertNil(AgentOverviewModel.branch(in: "/"))
        XCTAssertNil(AgentOverviewModel.branch(in: "/.."))
        XCTAssertNil(AgentOverviewModel.branch(in: "/fake-acme/../../../.."))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-deep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/acme\n".utf8).write(to: base.appendingPathComponent(".git/HEAD"))
        let deep = (0..<80).reduce(base) { url, _ in url.appendingPathComponent("d") }
        XCTAssertNil(AgentOverviewModel.branch(in: deep.path), "80 levels down: past the bound, the folder needn't exist")
        XCTAssertEqual(AgentOverviewModel.branch(in: deep.path, limit: 81), "acme", "within it")
        XCTAssertNil(AgentOverviewModel.branch(in: (0..<5_000).map { _ in "d" }.joined(separator: "/")), "a relative path thousands deep")
    }

    /// The overview polls every 2 s; a refresh slower than that must not
    /// start another behind it.
    @MainActor
    func testARefreshInFlightIsNotStartedAgain() async {
        let model = AgentOverviewModel()
        let first = Task { await model.refresh([]) }
        // Started when the task first runs on the main actor — one yield
        // wasn't always enough on a loaded CI runner.
        for _ in 0..<200 where !model.isRefreshing { await Task.yield() }
        XCTAssertTrue(model.isRefreshing, "the first refresh is reading off the main thread")
        await model.refresh([])  // returns at once
        XCTAssertTrue(model.isRefreshing, "the skipped call did not end the first one's flag")
        await first.value
        XCTAssertFalse(model.isRefreshing)
    }
}
