import XCTest

@testable import Terminus

@MainActor
final class AgentSettingsTests: XCTestCase {
    func testArgumentsGoWhereverTheAgentStarts() {
        XCTAssertEqual(Agent.claude.command(arguments: " --model opus "), "claude --model opus")
        XCTAssertEqual(Agent.claude.command(arguments: ""), "claude")
        XCTAssertEqual(Agent.codex.resumeCommand(arguments: "-m gpt-5"), "codex resume --last -m gpt-5")
        XCTAssertEqual(
            Agent.claudeResume(session: "8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33", arguments: "--model opus"),
            "claude --resume 8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33 --model opus")
        XCTAssertEqual(Agent.claude.command(arguments: "--a\n--b"), "claude --a --b", "one line: typed into a shell")
    }

    func testAgentDefaultsKeepTodaysBehaviour() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-agent-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let settings = Settings(url: url, watch: false)
        XCTAssertEqual(settings.defaultTaskAgent, .claude)
        XCTAssertEqual(settings.worktreeLocation, .sibling)
        XCTAssertEqual(settings.arguments(for: .claude), "")
        settings.set("agents.newTaskAgent", .string("shell"))
        XCTAssertNil(Settings(url: url, watch: false).defaultTaskAgent, "a shell only")
    }

    func testWorktreeLocations() {
        let repo = URL(fileURLWithPath: "/Users/b/acme/monorepo")
        XCTAssertEqual(TaskCreator.worktreePath(repo: repo, branch: "feat/X y").path, "/Users/b/acme/monorepo-wt-feat-x-y")
        XCTAssertEqual(TaskCreator.worktreePath(repo: repo, branch: "feat/X y", location: .inside).path, "/Users/b/acme/monorepo/.worktrees/feat-x-y")
    }

    func testInsideWorktreesAreExcludedLocallyOnce() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-exclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "i"], in: repo)
        let path = try await TaskCreator.create(repo: repo, branch: "feat/in", base: "main", location: .inside)
        XCTAssertEqual(path.lastPathComponent, "feat-in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path))
        let status = try await Git.run(["status", "--porcelain"], in: repo)
        XCTAssertEqual(status, "", "the worktree folder is ignored in the main checkout")
        await TaskCreator.excludeWorktreesFolder(in: repo)
        let exclude = try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        XCTAssertEqual(exclude.components(separatedBy: "\n").filter { $0 == ".worktrees/" }.count, 1, "added once")
    }
}
