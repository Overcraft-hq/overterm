import XCTest

@testable import Terminus

final class WorktreeTests: XCTestCase {
    private let porcelain = """
        worktree /Users/b/monorepo
        HEAD 087b072b8aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        branch refs/heads/main

        worktree /Users/b/monorepo-wt-cosign
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/feat/cosign
        locked

        worktree /Users/b/monorepo-wt-detached
        HEAD 2222222222222222222222222222222222222222
        detached

        """

    func testParsesEveryRecord() {
        let worktrees = Worktree.parse(porcelain: porcelain)
        XCTAssertEqual(worktrees.map(\.path.path), ["/Users/b/monorepo", "/Users/b/monorepo-wt-cosign", "/Users/b/monorepo-wt-detached"])
        XCTAssertEqual(worktrees.map(\.isMain), [true, false, false])
    }

    func testBranchesAreShortNamesWithSlashesKept() {
        let worktrees = Worktree.parse(porcelain: porcelain)
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feat/cosign", nil])
        XCTAssertTrue(worktrees[1].isLocked)
    }

    func testDetachedShowsShortHead() {
        let detached = Worktree.parse(porcelain: porcelain)[2]
        XCTAssertTrue(detached.isDetached)
        XCTAssertEqual(detached.displayName, "(2222222)")
    }

    func testBareRepository() {
        let worktrees = Worktree.parse(porcelain: "worktree /srv/repo.git\nbare\n")
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertTrue(worktrees[0].isBare)
        XCTAssertEqual(worktrees[0].displayName, "(bare)")
    }

    func testContainingPicksTheDeepestWorktree() {
        let worktrees = Worktree.parse(
            porcelain: """
                worktree /r
                HEAD a
                branch refs/heads/main

                worktree /r/.worktrees/x
                HEAD b
                branch refs/heads/x

                """)
        XCTAssertEqual(Worktree.containing("/r/.worktrees/x/src", in: worktrees)?.branch, "x")
        XCTAssertEqual(Worktree.containing("/r/src", in: worktrees)?.branch, "main")
        XCTAssertEqual(Worktree.containing("/r", in: worktrees)?.branch, "main")
        XCTAssertNil(Worktree.containing("/rx", in: worktrees), "a prefix-sibling is not inside")
    }
}

final class GitTests: XCTestCase {
    func testRunsInTheGivenDirectoryAndReportsFailures() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await Git.run(["init", "-q", "-b", "main"], in: dir)
        let top = try await Git.run(["rev-parse", "--show-toplevel"], in: dir)
        XCTAssertEqual(URL(fileURLWithPath: top.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath(), dir.resolvingSymlinksInPath())

        do {
            _ = try await Git.run(["rev-parse", "--verify", "no-such-ref"], in: dir)
            XCTFail("expected a GitError")
        } catch let error as GitError {
            XCTAssertNotEqual(error.status, 0)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}

final class WorktreeModelTests: XCTestCase {
    @MainActor
    func testListsARealRepositorysWorktrees() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-wt-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        _ = try await Git.run(["worktree", "add", "-q", "-b", "feat/x", base.appendingPathComponent("repo-wt-feat-x").path], in: repo)

        let model = WorktreeModel()
        model.setAnchor(base.appendingPathComponent("repo-wt-feat-x"))
        await model.refresh()
        XCTAssertEqual(model.worktrees.map(\.branch), ["main", "feat/x"])
        XCTAssertEqual(model.main?.path.resolvingSymlinksInPath(), repo.resolvingSymlinksInPath())
    }

    @MainActor
    func testOutsideARepositoryIsEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = WorktreeModel()
        model.setAnchor(dir)
        await model.refresh()
        XCTAssertTrue(model.worktrees.isEmpty)
    }
}

final class TaskCreatorTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(TaskCreator.slug("feat/cosign"), "feat-cosign")
        XCTAssertEqual(TaskCreator.slug("Fix: Tab // Focus!"), "fix-tab-focus")
        XCTAssertEqual(TaskCreator.slug("v1.2_x"), "v1.2_x")
    }

    func testWorktreePathIsASiblingOfTheRepo() {
        let path = TaskCreator.worktreePath(repo: URL(fileURLWithPath: "/Users/b/acme/monorepo"), branch: "feat/app-switcher")
        XCTAssertEqual(path.path, "/Users/b/acme/monorepo-wt-feat-app-switcher")
    }

    private func makeRepo() async throws -> (base: URL, repo: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-task-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        return (base, repo)
    }

    func testCreatesANewBranchWorktree() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        let path = try await TaskCreator.create(repo: repo, branch: "feat/x", base: "main")
        XCTAssertEqual(path.lastPathComponent, "repo-wt-feat-x")
        let head = try await Git.run(["branch", "--show-current"], in: path)
        XCTAssertEqual(head.trimmingCharacters(in: .newlines), "feat/x")
    }

    func testChecksOutAnExistingBranch() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try await Git.run(["branch", "existing"], in: repo)
        let path = try await TaskCreator.create(repo: repo, branch: "existing", base: "no-such-base")
        let head = try await Git.run(["branch", "--show-current"], in: path)
        XCTAssertEqual(head.trimmingCharacters(in: .newlines), "existing")
    }

    func testRejectsInvalidBranchNames() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            _ = try await TaskCreator.create(repo: repo, branch: "bad..name", base: "main")
            XCTFail("expected invalidBranch")
        } catch TaskCreator.Failure.invalidBranch {}
    }
}
