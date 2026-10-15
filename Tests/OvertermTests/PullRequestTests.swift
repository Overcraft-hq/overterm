import XCTest

@testable import Overterm

/// gh's JSON, in the shapes it really returns (sampled from gh 2.87).
final class PullRequestTests: XCTestCase {
    private let list = Data(
        #"""
        [{"headRefName":"feat/a","headRefOid":"aaa","isDraft":false,"number":12,"state":"OPEN","title":"Feature A","url":"https://github.com/o/r/pull/12",
          "statusCheckRollup":[
            {"__typename":"CheckRun","name":"Go","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci/1"},
            {"__typename":"CheckRun","name":"Lint","status":"IN_PROGRESS","conclusion":"","detailsUrl":"https://ci/2"},
            {"__typename":"CheckRun","name":"Web","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":"https://ci/3"}]},
         {"headRefName":"feat/b","headRefOid":"bbb","isDraft":true,"number":11,"state":"OPEN","title":"B","url":null,
          "statusCheckRollup":[{"__typename":"StatusContext","context":"deploy","state":"FAILURE","targetUrl":"https://ci/4"}]},
         {"headRefName":"feat/a","headRefOid":"old","isDraft":false,"number":9,"state":"MERGED","title":"Old A","url":null,"statusCheckRollup":[]},
         {"headRefName":"feat/c","headRefOid":"ccc","isDraft":false,"number":8,"state":"MERGED","title":"C","url":null,"statusCheckRollup":[]},
         {"headRefName":"feat/d","headRefOid":"ddd","isDraft":false,"number":7,"state":"CLOSED","title":"D","url":null,"statusCheckRollup":[]}]
        """#.utf8)

    func testListParsesStatesAndChecks() throws {
        let prs = try PullRequestSummary.parseList(list)
        XCTAssertEqual(prs.map(\.state), [.open, .draft, .merged, .merged, .closed])
        XCTAssertEqual(prs[0].checks, CheckSummary(passed: 1, failed: 0, pending: 1), "skipped counts for nothing")
        XCTAssertEqual(prs[0].checks.overall, .pending)
        XCTAssertEqual(prs[1].checks.overall, .failing, "a failed StatusContext")
        XCTAssertEqual(prs[3].checks.overall, .none)
        XCTAssertEqual(prs[0].headOid, "aaa")
    }

    func testAnOpenPullRequestWinsOverAnOldMergedOne() throws {
        let byBranch = PullRequestSummary.byBranch(try PullRequestSummary.parseList(list))
        XCTAssertEqual(byBranch["feat/a"]?.number, 12)
        XCTAssertEqual(byBranch["feat/c"]?.state, .merged)
    }

    func testMergedByPullRequestOnlyWhenTheBranchIsStillAtTheMergedHead() throws {
        let byBranch = PullRequestSummary.byBranch(try PullRequestSummary.parseList(list))
        let merged = MergedWorktrees.mergedByPullRequest(
            byBranch, branches: ["feat/a", "feat/c", "feat/d", "reused"],
            tips: ["feat/a": "aaa", "feat/c": "ccc", "feat/d": "ddd"])
        XCTAssertEqual(merged, ["feat/c": .pullRequestMerged(8)], "open and closed ones aren't merged")
        let moved = MergedWorktrees.mergedByPullRequest(byBranch, branches: ["feat/c"], tips: ["feat/c": "new-work"])
        XCTAssertTrue(moved.isEmpty, "new commits since the merge: not merged")
    }

    func testDetailBuildsTheConversationInOrder() throws {
        let data = Data(
            #"""
            {"number":12,"title":"Feature A","headRefName":"feat/a","baseRefName":"main","state":"OPEN","isDraft":false,"url":"https://github.com/o/r/pull/12",
             "statusCheckRollup":[],"body":"Does **A**.","author":{"login":"bahattin"},"additions":10,"deletions":2,"changedFiles":3,
             "comments":[{"id":"IC_2","author":{"login":"claude"},"body":"Second","createdAt":"2026-09-20T10:00:00Z","url":"https://c/2"},
                         {"id":"IC_1","author":{"login":"bahattin"},"body":"First","createdAt":"2026-09-20T09:00:00Z","url":"https://c/1"}],
             "reviews":[{"id":"R_1","author":{"login":"rev"},"body":"","state":"APPROVED","submittedAt":"2026-09-20T09:30:00Z"},
                        {"id":"R_2","author":{"login":"claude"},"body":"","state":"COMMENTED","submittedAt":"2026-09-20T09:40:00Z"}]}
            """#.utf8)
        let detail = try PullRequestDetail.parse(data)
        XCTAssertEqual(detail.conversation.map(\.id), ["IC_1", "R_1", "IC_2"], "oldest first; an empty COMMENTED review is left to its threads")
        XCTAssertEqual(detail.conversation[1].kind, .review("APPROVED"))
        XCTAssertEqual(detail.base, "main")
        XCTAssertEqual(detail.body, "Does **A**.")
    }

    func testReviewThreadsGroupRepliesAcrossPages() throws {
        // --paginate: two arrays back to back.
        let data = Data(
            #"""
            [{"id":1,"path":"b.go","line":20,"body":"root b","user":{"login":"claude[bot]"},"created_at":"2026-09-20T08:00:00Z","html_url":"https://r/1","diff_hunk":"@@ -1 +1 @@\n+x\n+y"},
             {"id":2,"path":"a.go","line":5,"body":"root a","user":{"login":"rev"},"created_at":"2026-09-20T08:01:00Z","html_url":"https://r/2","diff_hunk":"@@\n+a"}]
            [{"id":3,"in_reply_to_id":1,"path":"b.go","line":20,"body":"a reply \"quoted\" ]","user":{"login":"bahattin"},"created_at":"2026-09-20T09:00:00Z"}]
            """#.utf8)
        let threads = try ReviewThread.parse(data)
        XCTAssertEqual(threads.map(\.path), ["a.go", "b.go"], "by file, then line")
        XCTAssertEqual(threads[1].id, 1)
        XCTAssertEqual(threads[1].comments.map(\.body), ["root b", #"a reply "quoted" ]"#])
        XCTAssertEqual(threads[1].context, ["@@ -1 +1 @@", "+x", "+y"])
    }

    func testGhErrorsAreSaidPlainly() {
        XCTAssertEqual(
            GitHub.message(for: "To get started with GitHub CLI, please run:  gh auth login"), "Not logged in to GitHub — run gh auth login.")
        XCTAssertEqual(GitHub.message(for: "no pull requests found for branch \"x\""), "No pull request for this branch.")
    }
}
