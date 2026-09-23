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
