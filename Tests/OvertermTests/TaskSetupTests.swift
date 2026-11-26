import XCTest

@testable import Overterm

/// P05 (Overcraft-hq/issue-tracker#15), GIT-G11 with D-7 (a): a
/// repository's untracked files copied into a new worktree, only from
/// inside it and only into the worktree; a setup command typed before the
/// agent; the setup kept in Overterm's folder, never in the repository.
final class TaskSetupTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-setup-\(UUID().uuidString)")
        repo = root.appendingPathComponent("shop-api")
        worktree = root.appendingPathComponent("shop-api-wt-feat-kupon")
        for folder in [repo!, worktree!, root.appendingPathComponent("elsewhere")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTheFieldsAreReadAsTheyAreMeant() {
        XCTAssertEqual(TaskSetup.paths(" .env, .env.local\nconfig/dev.json,, .env "), [".env", ".env.local", "config/dev.json"])
        XCTAssertEqual(TaskSetup.firstLine(setup: "npm ci", agent: "claude"), "{ npm ci; } && claude", "the agent only once the setup succeeded")
        XCTAssertEqual(TaskSetup.firstLine(setup: "npm ci;", agent: "claude"), "{ npm ci; } && claude", "a trailing ; isn't doubled")
        XCTAssertEqual(TaskSetup.firstLine(setup: "cd app; npm ci", agent: "claude"), "{ cd app; npm ci; } && claude", "one group, its cd kept")
        XCTAssertEqual(TaskSetup.firstLine(setup: "npm run watch &", agent: "claude"), "{ npm run watch & } && claude")
        XCTAssertEqual(TaskSetup.firstLine(setup: "  ", agent: "claude"), "claude", "no setup: today's line")
        XCTAssertEqual(TaskSetup.firstLine(setup: "npm ci", agent: nil), "npm ci")
        XCTAssertNil(TaskSetup.firstLine(setup: "", agent: nil))
        XCTAssertNotNil(TaskSetup.commandProblem("npm ci\nnpm test"), "one line")
        XCTAssertNil(TaskSetup.commandProblem("npm ci && npm run build"))
    }

    func testTheFilesInsideTheRepositoryAreCopied() throws {
        try write("API_KEY=from-the-repo\n", ".env", in: repo)
        try write("{\"port\": 3001}", "config/dev.json", in: repo)
        try write("a", "fixtures/one.txt", in: repo)
        let report = TaskSetupCopy.copy([".env", "config/dev.json", "fixtures", ".env.local"], from: repo, into: worktree)
        XCTAssertEqual(report.copied, [".env", "config/dev.json", "fixtures"])
        XCTAssertEqual(report.skipped.map(\.path), [".env.local"], "what isn't there is said, not made")
        XCTAssertEqual(try Data(contentsOf: worktree.appendingPathComponent(".env")), try Data(contentsOf: repo.appendingPathComponent(".env")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("fixtures/one.txt").path), "a folder whole")
    }

    func testNothingLeavesTheRepositoryOrLandsOutsideTheWorktree() throws {
        try write("secret", "credentials", in: root.appendingPathComponent("elsewhere"))
        // A link in the repository to a file outside it.
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent(".env"), withDestinationURL: root.appendingPathComponent("elsewhere/credentials"))
        let report = TaskSetupCopy.copy(["../elsewhere/credentials", "/etc/hosts", "~/.ssh/config", ".git/config", ".env"], from: repo, into: worktree)
        XCTAssertTrue(report.copied.isEmpty, "\(report.copied)")
        XCTAssertEqual(report.skipped.count, 5)
        XCTAssertEqual(report.skipped.last?.why, "it leads outside the repository")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".env").path))

        // A folder of the worktree's that is a link elsewhere is never written through.
        try write("x", "config/dev.json", in: repo)
        try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent("config"), withDestinationURL: root.appendingPathComponent("elsewhere"))
        let through = TaskSetupCopy.copy(["config/dev.json"], from: repo, into: worktree)
        XCTAssertEqual(through.skipped.map(\.why), ["its place in the worktree leads outside it"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("elsewhere/dev.json").path))
    }

    func testWhatTheWorktreeHasIsKept() throws {
        try write("repo's", ".env", in: repo)
        try write("worktree's own", ".env", in: worktree)
        let report = TaskSetupCopy.copy([".env"], from: repo, into: worktree)
        XCTAssertEqual(report.skipped.map(\.why), ["the worktree already has it"])
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent(".env"), encoding: .utf8), "worktree's own")
    }

    func testTheSetupIsKeptInOvertermsFolderByRepository() throws {
        let file = root.appendingPathComponent("support/task-setups.json")
        let setup = TaskSetup(copy: [".env"], command: "npm ci")
        try TaskSetupStore.save(setup, for: repo, file: file)
        XCTAssertEqual(TaskSetupStore.setup(for: repo, file: file), setup)
        XCTAssertEqual(TaskSetupStore.setup(for: worktree, file: file), TaskSetup(), "another repository has none")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let inRepo = try FileManager.default.contentsOfDirectory(atPath: repo.path)
        XCTAssertTrue(inRepo.isEmpty, "nothing written into the repository: \(inRepo)")
        try TaskSetupStore.save(TaskSetup(), for: repo, file: file)
        XCTAssertTrue(TaskSetupStore.load(file: file).isEmpty, "an empty setup forgets it")
    }
}
