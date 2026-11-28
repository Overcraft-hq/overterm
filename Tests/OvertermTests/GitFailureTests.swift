import XCTest

@testable import OvertermCore

/// GIT-U6: a git failure read from git's own words, said plainly, with the
/// next steps that fit it.
final class GitFailureTests: XCTestCase {
    func testTheCommonFailuresAreRecognisedInGitsOwnWords() {
        let fetchFirst = """
            To github.com:acme/shop.git
             ! [rejected]        feature -> feature (fetch first)
            error: failed to push some refs to 'github.com:acme/shop.git'
            hint: Updates were rejected because the remote contains work that you do not
            hint: have locally.
            """
        XCTAssertEqual(GitFailure.read(fetchFirst), .remoteAhead)
        XCTAssertEqual(GitFailure.read(" ! [rejected]        main -> main (non-fast-forward)\nerror: failed to push some refs"), .remoteAhead)
        XCTAssertEqual(
            GitFailure.read("hint: You have divergent branches and need to specify how to reconcile them.\nfatal: Need to specify how to reconcile divergent branches."),
            .diverged)
        XCTAssertEqual(GitFailure.read("There is no tracking information for the current branch.\nPlease specify which branch you want to merge with."), .noUpstream)
        XCTAssertEqual(GitFailure.read("remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/acme/shop.git/'"), .authentication)
        XCTAssertEqual(GitFailure.read("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."), .authentication)
        XCTAssertEqual(GitFailure.read("husky - pre-push hook exited with code 1 (error)\nerror: failed to push some refs to 'origin'"), .hook("pre-push"))
        XCTAssertEqual(
            GitFailure.read("error: Your local changes to the following files would be overwritten by merge:\n\tapi/bank.ts\nPlease commit your changes or stash them before you merge."),
            .localChanges)
        XCTAssertEqual(GitFailure.read(" ! [rejected]        feature -> feature (stale info)\nerror: failed to push some refs"), .leaseStale)
        XCTAssertEqual(GitFailure.leaseStale.next(pushing: true, branch: "feature", isDefault: false), [], "a lease's no isn't retried for you")
        XCTAssertEqual(GitFailure.read("fatal: something nobody planned for"), .other)
    }

    func testTheNextStepsFitTheFailure() {
        XCTAssertEqual(
            GitFailure.remoteAhead.next(pushing: true, branch: "feature", isDefault: false), [.pullThenPush, .pullRebaseThenPush, .forcePushWithLease])
        XCTAssertEqual(GitFailure.remoteAhead.next(pushing: true, branch: "main", isDefault: true), [.pullThenPush, .pullRebaseThenPush], "never a force push to the default branch")
        XCTAssertEqual(GitFailure.remoteAhead.next(pushing: true, branch: nil, isDefault: false), [.pullThenPush, .pullRebaseThenPush], "nor from a detached HEAD")
        XCTAssertEqual(GitFailure.diverged.next(pushing: false, branch: "feature", isDefault: false), [.pullRebase, .pullMerge])
        XCTAssertEqual(GitFailure.noUpstream.next(pushing: false, branch: "feature", isDefault: false), [.publish])
        XCTAssertEqual(GitFailure.localChanges.next(pushing: false, branch: "feature", isDefault: false), [.stash])
        XCTAssertEqual(GitFailure.authentication.next(pushing: true, branch: "feature", isDefault: false), [], "a sign-in is said, not retried")
    }

    func testTheDefaultBranchAndTheLease() {
        XCTAssertTrue(GitFailure.isDefault("main", defaultBranch: "origin/main"))
        XCTAssertFalse(GitFailure.isDefault("feature", defaultBranch: "origin/main"))
        XCTAssertTrue(GitFailure.isDefault("trunk", defaultBranch: "origin/trunk"))
        XCTAssertTrue(GitFailure.isDefault("master", defaultBranch: nil), "by name when nothing better is known")
        XCTAssertFalse(GitFailure.isDefault(nil, defaultBranch: "origin/main"))
        XCTAssertEqual(
            GitFailure.forcePushArguments(remote: "origin", branch: "feature", target: "feature"),
            ["push", "--force-with-lease=feature:refs/remotes/origin/feature", "origin", "feature:feature"])
    }

    func testGitsOwnWordsAreBoundedAndSaid() {
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = GitFailure.excerpt(long)
        XCTAssertTrue(excerpt.hasSuffix("line 40") && !excerpt.contains("line 32\n"), excerpt)
        XCTAssertTrue(GitFailure.remoteAhead.sentence(branch: "feature").hasPrefix("feature on the remote has commits"))
        XCTAssertTrue(GitFailure.hook("pre-push").sentence(branch: nil).contains("The pre-push hook"))
    }
}
