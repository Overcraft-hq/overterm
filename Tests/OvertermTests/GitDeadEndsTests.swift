import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermOvergit

/// Issue #31's git dead ends: the remote a branch is published to, the
/// question before rewriting pushed commits, New Task's fields, the pull
/// requests' review and merge marks.
final class GitDeadEndsTests: XCTestCase {
    // MARK: GIT-U8 — which remote

    func testPushRemoteFollowsGitsOrder() {
        let remotes = ["origin", "fork"]
        let config = PushRemote.parse(
            config: "branch.Feature/X.pushremote\nfork\0remote.pushdefault\norigin\0branch.Feature/X.remote\norigin\0")
        XCTAssertEqual(config["branch.Feature/X.pushremote"], "fork", "a branch's own case is kept")
        XCTAssertEqual(PushRemote.choose(branch: "Feature/X", remotes: remotes, config: config), .remote("fork"))
        XCTAssertEqual(PushRemote.choose(branch: "other", remotes: remotes, config: config), .remote("origin"), "remote.pushDefault next")
        XCTAssertEqual(
            PushRemote.choose(branch: "other", remotes: remotes, config: ["branch.other.remote": "fork"]), .remote("fork"),
            "then the branch's remote")
    }

    func testPushRemoteOneRemoteWhateverItsName() {
        XCTAssertEqual(PushRemote.choose(branch: "x", remotes: ["upstream"], config: [:]), .remote("upstream"))
        XCTAssertEqual(PushRemote.choose(branch: "x", remotes: [], config: [:]), .none)
    }

    func testPushRemoteSeveralAndNothingSaidAsks() {
        XCTAssertEqual(
            PushRemote.choose(branch: "x", remotes: ["fork", "origin"], config: [:]), .ask(["fork", "origin"], suggested: "origin"))
        // A pushDefault naming a remote that was removed is passed over.
        XCTAssertEqual(
            PushRemote.choose(branch: nil, remotes: ["a", "b"], config: ["remote.pushdefault": "gone"]), .ask(["a", "b"], suggested: "a"))
    }

    func testPushArgumentsNameTheRemoteAndTheBranch() {
        XCTAssertEqual(PushRemote.pushArguments(remote: "fork", branch: "feat/x", setUpstream: true), ["push", "--set-upstream", "fork", "feat/x"])
        XCTAssertEqual(PushRemote.pushArguments(remote: "origin", branch: "feat/x", setUpstream: false), ["push", "origin", "feat/x"])
        XCTAssertEqual(PushRemote.parse(remotes: "origin\nfork\n\n"), ["origin", "fork"])
    }

    // MARK: GIT-U7 — rewriting pushed commits

    private func commit(_ sha: String) -> Commit {
        Commit(
            sha: sha, shortSHA: String(sha.prefix(7)), parents: [], author: "A", authorEmail: "a@x", date: Date(), relative: "now", subject: "s",
            body: "", refs: [])
    }

    func testRewriteAsksOnlyForPushedCommits() {
        XCTAssertNil(OvergitRewrite.question(.rebase(onto: "main"), current: "feat", pushed: 0))
        let rebase = OvergitRewrite.question(.rebase(onto: "main"), current: "feat", pushed: 3)
        XCTAssertEqual(rebase?.title, "Rebase feat onto main?")
        XCTAssertTrue(rebase?.detail.contains("3 commits of feat already on a remote") == true, rebase?.detail ?? "")
        let reset = OvergitRewrite.question(.reset(commit("abcdef1234"), .soft), current: "main", pushed: 1)
        XCTAssertEqual(reset?.title, "Reset main to abcdef1?")
        XCTAssertTrue(reset?.detail.contains("1 commit already on a remote") == true && reset?.detail.contains("staged") == true)
        XCTAssertNil(OvergitRewrite.question(.reset(commit("abcdef1234"), .hard), current: "main", pushed: 2), "hard asks its own question")
        XCTAssertNil(OvergitRewrite.question(.cherryPick(commit("abc")), current: "main", pushed: 2))
    }

    func testRewriteCountsAgainstEveryRemote() {
        XCTAssertEqual(OvergitRewrite.unpushedArguments(base: "abc"), ["rev-list", "--count", "HEAD", "^abc", "--not", "--remotes"])
        XCTAssertEqual(OvergitRewrite.countArguments(base: "abc"), ["rev-list", "--count", "HEAD", "^abc"])
    }

    // MARK: GIT-U14 — New Task's fields

    func testBranchProblemsAsGitWouldRefuse() {
        XCTAssertNil(TaskFields.branchProblem(""))
        XCTAssertNil(TaskFields.branchProblem("feat/sign-in"))
        for bad in ["my change", "-x", "a..b", "a~1", "a:b", "feat/", "/feat", "a//b", "feat/.x", "a.lock", "x.", "a@{u}", "HEAD"] {
            XCTAssertNotNil(TaskFields.branchProblem(bad), bad)
        }
    }

    func testBranchNoteSaysAnExistingOneIsCheckedOut() {
        let note = TaskFields.branchNote("main", local: ["main"])
        XCTAssertEqual(note?.isProblem, false)
        XCTAssertTrue(note?.text.contains("checked out as it is") == true)
        XCTAssertNil(TaskFields.branchNote("feat/new", local: ["main"]))
        XCTAssertEqual(TaskFields.branchNote("a b", local: []).map(\.isProblem), true)
    }

    func testBaseNoteSaysAFromThatNamesNothing() {
        XCTAssertNil(TaskFields.baseNote("mian", resolves: nil, branchExists: false), "not read yet")
        XCTAssertNil(TaskFields.baseNote("main", resolves: true, branchExists: false))
        XCTAssertEqual(TaskFields.baseNote("mian", resolves: false, branchExists: false)?.isProblem, true)
        XCTAssertNil(TaskFields.baseNote("mian", resolves: false, branchExists: true), "unused for an existing branch")
        XCTAssertEqual(TaskFields.baseNote("--orphan", resolves: nil, branchExists: false)?.isProblem, true)
        XCTAssertEqual(TaskFields.resolveArguments("main"), ["rev-parse", "--verify", "--quiet", "main^{commit}"])
    }

    // MARK: GIT-G4 — review requested, decision, mergeability

    func testListDecodesReviewAndMergeFields() throws {
        let json = """
            [{"number": 9, "title": "Fix", "headRefName": "fix", "state": "OPEN", "isDraft": false, "author": {"login": "grace"},
              "reviewDecision": "CHANGES_REQUESTED", "mergeable": "CONFLICTING",
              "reviewRequests": [{"__typename": "User", "login": "ada"}, {"__typename": "Team", "name": "Core", "slug": "core"}]},
             {"number": 8, "title": "Old", "headRefName": "old", "state": "OPEN"}]
            """
        let list = try PullRequestSummary.parseList(Data(json.utf8))
        XCTAssertEqual(list[0].author, "grace")
        XCTAssertEqual(list[0].reviewDecision, .changesRequested)
        XCTAssertEqual(list[0].mergeable, .conflicting)
        XCTAssertEqual(list[0].reviewRequested, ["ada"], "a team is not a person")
        XCTAssertTrue(list[0].asks("Ada"))
        XCTAssertNil(list[1].reviewDecision)
        XCTAssertTrue(PullRequestSummary.listFields.contains("reviewRequests") && PullRequestSummary.listFields.contains("mergeable"))
        let marks = PullRequestRowView.marks(list[0], me: "ada").map(\.help)
        XCTAssertEqual(marks, ["Your review is requested", "Changes requested", "Conflicts with its base branch"])
    }

    func testPullRequestsGroupedForMe() {
        func pr(_ number: Int, author: String, asked: [String] = []) -> PullRequestSummary {
            var pr = PullRequestSummary(number: number, title: "t", branch: "b\(number)", state: .open, url: nil, checks: CheckSummary())
            pr.author = author
            pr.reviewRequested = asked
            return pr
        }
        let list = [pr(1, author: "grace"), pr(2, author: "ada"), pr(3, author: "linus", asked: ["ada"])]
        let groups = PullRequestSummary.grouped(list, me: "ada")
        XCTAssertEqual(groups.map(\.title), ["Needs your review", "Yours", "Others"])
        XCTAssertEqual(groups.map { $0.pullRequests.map(\.number) }, [[3], [2], [1]])
        let unnamed = PullRequestSummary.grouped(list, me: nil)
        XCTAssertEqual(unnamed.count, 1)
        XCTAssertNil(unnamed[0].title)
        XCTAssertEqual(unnamed[0].pullRequests.map(\.number), [3, 2, 1])
    }
}
