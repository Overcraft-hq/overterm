import XCTest

@testable import Overterm

/// What Overgit reads of a checkout's state, and how it names a remote branch.
final class GitStateTests: XCTestCase {
    private func gitDir(with names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            if name.hasPrefix("rebase-") {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            } else {
                try Data().write(to: dir.appendingPathComponent(name))
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInProgress() throws {
        XCTAssertNil(GitInProgress.read(gitDir: try gitDir(with: ["HEAD", "ORIG_HEAD"])))
        XCTAssertEqual(GitInProgress.read(gitDir: try gitDir(with: ["MERGE_HEAD"])), .merge)
        XCTAssertEqual(GitInProgress.read(gitDir: try gitDir(with: ["CHERRY_PICK_HEAD"])), .cherryPick)
        XCTAssertEqual(GitInProgress.read(gitDir: try gitDir(with: ["REVERT_HEAD"])), .revert)
        // A rebase stopped on a merge commit has MERGE_HEAD too: it is the rebase.
        XCTAssertEqual(GitInProgress.read(gitDir: try gitDir(with: ["rebase-merge", "MERGE_HEAD"])), .rebase)
        XCTAssertEqual(GitInProgress.read(gitDir: try gitDir(with: ["rebase-apply"])), .rebase)
    }

    func testContinueWaitsForNoEditor() {
        XCTAssertEqual(GitInProgress.merge.continueArguments, ["-c", "core.editor=true", "merge", "--continue"])
        XCTAssertEqual(GitInProgress.cherryPick.abortArguments, ["cherry-pick", "--abort"])
    }

    func testTracking() {
        XCTAssertEqual(BranchTracking.parse(upstream: nil, counts: nil), BranchTracking())
        XCTAssertEqual(BranchTracking.parse(upstream: "\n", counts: "1\t2"), BranchTracking())
        XCTAssertEqual(BranchTracking.parse(upstream: "origin/main\n", counts: "3\t1\n"), BranchTracking(upstream: "origin/main", ahead: 3, behind: 1))
        XCTAssertEqual(BranchTracking.parse(upstream: "origin/main", counts: nil), BranchTracking(upstream: "origin/main"))
    }

    func testRemoteBranchSplit() {
        XCTAssertEqual(OvergitCommand.split(remoteBranch: "origin/feature/x", remotes: ["origin"])?.branch, "feature/x")
        // A remote whose name has a slash: the longest that fits.
        let split = OvergitCommand.split(remoteBranch: "team/a/fix", remotes: ["team", "team/a"])
        XCTAssertEqual(split?.remote, "team/a")
        XCTAssertEqual(split?.branch, "fix")
        XCTAssertEqual(OvergitCommand.split(remoteBranch: "upstream/main", remotes: [])?.remote, "upstream")
        XCTAssertNil(OvergitCommand.split(remoteBranch: "main", remotes: ["origin"]))
    }
}
