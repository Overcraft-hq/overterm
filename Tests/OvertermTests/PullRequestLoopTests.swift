import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// P06 (Overcraft-hq/issue-tracker#16): the pull request's writes (D-9 (c))
/// as gh's words and their questions, a new one's title and body from its
/// commits, a failed job's run and log, and CI's mark said only on news.
final class PullRequestLoopTests: XCTestCase {
    // MARK: The writes

    func testEachWriteIsGhsOwnWordsEveryValueAWordOfItsOwn() {
        XCTAssertEqual(
            PullRequestWrite.create(title: "Kupon kodu; rm -rf ~", body: "- a", base: "main", head: "feat/kupon", draft: true).arguments,
            ["pr", "create", "--title", "Kupon kodu; rm -rf ~", "--body", "- a", "--base", "main", "--head", "feat/kupon", "--draft"])
        XCTAssertEqual(PullRequestWrite.ready(number: 7).arguments, ["pr", "ready", "7"])
        XCTAssertEqual(PullRequestWrite.approve(number: 7, body: "").arguments, ["pr", "review", "7", "--approve"])
        XCTAssertEqual(PullRequestWrite.requestChanges(number: 7, body: "A test").arguments, ["pr", "review", "7", "--request-changes", "--body", "A test"])
        XCTAssertEqual(
            PullRequestWrite.merge(number: 7, method: .rebase, head: "abc").arguments, ["pr", "merge", "7", "--rebase", "--match-head-commit", "abc"])
        XCTAssertEqual(PullRequestWrite.rerunFailed(run: 11).arguments, ["run", "rerun", "11", "--failed"])
    }

    func testWhatCantBeSentIsSaidBeforeAsking() {
        XCTAssertNotNil(PullRequestWrite.requestChanges(number: 7, body: "  ").problem, "GitHub asks for a body")
        XCTAssertNotNil(PullRequestWrite.create(title: " ", body: "", base: "main", head: "feat/x", draft: false).problem)
        XCTAssertNotNil(PullRequestWrite.create(title: "T", body: "", base: "main", head: "main", draft: false).problem, "into itself")
        XCTAssertNil(PullRequestWrite.approve(number: 7, body: "").problem)
    }

    func testEveryQuestionNamesTheRepositoryAndThePullRequest() {
        for write in [
            PullRequestWrite.ready(number: 7), .approve(number: 7, body: ""), .requestChanges(number: 7, body: "x"),
            .merge(number: 7, method: .squash, head: nil),
        ] {
            XCTAssertEqual(write.question(repository: "acme/shop").scope, "acme/shop · #7")
        }
        XCTAssertEqual(
            PullRequestWrite.create(title: "T", body: "", base: "main", head: "feat/x", draft: false).question(repository: "acme/shop").scope,
            "acme/shop · feat/x → main")
        XCTAssertTrue(PullRequestWrite.merge(number: 7, method: .merge, head: nil).destroys, "a merge isn't undone from here")
        XCTAssertEqual(TerminalWindowController.repository(of: URL(string: "https://github.com/acme/shop/pull/7")!), "acme/shop")
    }

    // MARK: A new pull request's words

    func testANewPullRequestIsFilledFromItsCommits() {
        let one = [PullRequestDraft.Commit(subject: "Add the coupon field", body: "So a code can be typed.\n")]
        XCTAssertTrue(PullRequestDraft.fill(commits: one, branch: "feat/kupon-kodu") == ("Add the coupon field", "So a code can be typed."))
        let two = [PullRequestDraft.Commit(subject: "Test it"), PullRequestDraft.Commit(subject: "Add the coupon field")]
        let filled = PullRequestDraft.fill(commits: two, branch: "feat/kupon-kodu")
        XCTAssertEqual(filled.title, "Kupon kodu", "the branch's name")
        XCTAssertEqual(filled.body, "- Add the coupon field\n- Test it", "oldest first")
        XCTAssertEqual(
            PullRequestDraft.commits(log: "Second\u{1f}\u{1e}\nFirst\u{1f}Its body\n\u{1e}\n"),
            [PullRequestDraft.Commit(subject: "Second"), PullRequestDraft.Commit(subject: "First", body: "Its body")])
        XCTAssertEqual(PullRequestDraft.number(created: "Warning: 1 uncommitted change\nhttps://github.com/acme/shop/pull/42\n"), 42)
        XCTAssertNil(PullRequestDraft.number(created: "nothing"))
    }

    // MARK: A failed job

    func testAFailedJobKnowsItsRunAndJob() throws {
        let list = Data(
            #"""
            [{"number":7,"title":"T","headRefName":"feat/x","headRefOid":"abc","state":"OPEN","isDraft":false,"url":null,
              "statusCheckRollup":[
                {"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"FAILURE","workflowName":"CI",
                 "detailsUrl":"https://github.com/acme/shop/actions/runs/11/job/22"},
                {"__typename":"StatusContext","context":"deploy","state":"FAILURE","targetUrl":"https://ci.acme.example/4"}]}]
            """#.utf8)
        let pr = try XCTUnwrap(PullRequestSummary.parseList(list).first)
        XCTAssertEqual(pr.checks.failing.map(\.name), ["Lint", "deploy"])
        let lint = pr.checks.failing[0]
        XCTAssertEqual(lint.workflow, "CI")
        XCTAssertEqual(lint.actionsJob?.run, 11)
        XCTAssertEqual(lint.actionsJob?.job, 22)
        XCTAssertNil(pr.checks.failing[1].actionsJob, "another CI's status has no log here")
        XCTAssertEqual(CILog.arguments(run: 11, job: 22), ["run", "view", "11", "--job", "22", "--log-failed"])
    }

    func testALogIsItsTailStepsHeadedNothingSecret() {
        let raw = [
            "lint\tSet up job\t2026-11-27T10:00:00.1234567Z Runner ready",
            "lint\tRun lint\t2026-11-27T10:00:01.1234567Z \u{1b}[31merror: unused import\u{1b}[0m",
            "lint\tRun lint\t2026-11-27T10:00:02.1234567Z GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "lint\tRun lint\t2026-11-27T10:00:03.1234567Z clone https://bot:hunter2@github.com/acme/shop.git",
        ].joined(separator: "\n")
        let text = CILog.tail(raw)
        XCTAssertTrue(text.hasPrefix("── Set up job ──\nRunner ready\n── Run lint ──\nerror: unused import"), text)
        XCTAssertFalse(text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"), text)
        XCTAssertFalse(text.contains("hunter2"), text)
        let long = (1...500).map { "job\tstep\t2026-11-27T10:00:00Z line \($0)" }.joined(separator: "\n")
        let tail = CILog.tail(long, maxLines: 50)
        XCTAssertTrue(tail.hasPrefix("… 451 earlier lines") && tail.hasSuffix("line 500"), String(tail.prefix(40)))
    }

    func testTheBriefFencesTheLogAsData() {
        let lint = Check(name: "Lint", state: .failure, url: URL(string: "https://github.com/acme/shop/actions/runs/11/job/22"), workflow: "CI")
        let failure = CIFailure(number: 7, title: "T", branch: "feat/x", head: "abcdef0123456789", failing: [lint])
        let brief = CIBrief.text(failure, logs: [(lint, ".github/workflows/ci.yml", "a ``` fence inside")])
        XCTAssertTrue(brief.contains("CI failed on pull request #7 (feat/x) at abcdef012345."), brief)
        XCTAssertTrue(brief.contains("Check: Lint — workflow CI (.github/workflows/ci.yml)"), brief)
        XCTAssertTrue(brief.contains("````\na ``` fence inside\n````"), "fenced longer than any run inside: \(brief)")
        XCTAssertTrue(brief.contains("Don't push."))
    }

    // MARK: CI's mark, only on news

    private func pr(_ checks: [Check], head: String = "a", state: PullRequestSummary.State = .open) -> PullRequestSummary {
        PullRequestSummary(number: 7, title: "T", branch: "feat/x", state: state, url: nil, checks: CheckSummary(checks), headOid: head)
    }
    private func check(_ name: String, _ state: Check.State) -> Check { Check(name: name, state: state, url: nil) }

    func testCIsMarkIsSaidOnlyOnTheWayIntoRed() {
        let green = pr([check("Go", .success), check("Lint", .success)])
        let red = pr([check("Go", .success), check("Lint", .failure)])
        guard case .failed(let failure) = CIFailure.change(previous: green, now: red, standing: nil) else { return XCTFail("red: news") }
        XCTAssertEqual(failure.note, "CI failed: Lint")
        XCTAssertEqual(CIFailure.change(previous: red, now: red, standing: failure), .none, "the same red again")
        XCTAssertEqual(CIFailure.change(previous: red, now: red, standing: nil), .none, "red already at launch, past its baseline")
        let worse = pr([check("Go", .failure), check("Lint", .failure)])
        guard case .failed(let grown) = CIFailure.change(previous: red, now: worse, standing: failure) else { return XCTFail("more red: news") }
        XCTAssertEqual(grown.note, "CI failed: Go and 1 more")
        guard case .failed = CIFailure.change(previous: nil, now: red, standing: nil) else { return XCTFail("a pull request first seen red") }
    }

    func testANewRunKeepsTheCardAndGreenTakesItBack() {
        let red = pr([check("Lint", .failure)])
        guard case .failed(let failure) = CIFailure.change(previous: pr([check("Lint", .success)]), now: red, standing: nil) else { return XCTFail() }
        let running = pr([check("Lint", .pending)], head: "b")
        guard case .rerunning(let still) = CIFailure.change(previous: red, now: running, standing: failure) else { return XCTFail("a new run going") }
        XCTAssertEqual(still.note, "CI failed: Lint — running again")
        XCTAssertEqual(CIFailure.change(previous: running, now: running, standing: still), .none)
        guard case .failed = CIFailure.change(previous: running, now: pr([check("Lint", .failure)], head: "b"), standing: still) else {
            return XCTFail("the new run failed too: news")
        }
        XCTAssertEqual(CIFailure.change(previous: running, now: pr([check("Lint", .success)], head: "b"), standing: still), .recovered)
        XCTAssertEqual(CIFailure.change(previous: red, now: pr([check("Lint", .failure)], state: .merged), standing: failure), .recovered, "merged")
        XCTAssertEqual(CIFailure.change(previous: red, now: nil, standing: failure), .recovered, "gone")
    }

    func testCIsMarkComesAndGoesOnItsOwn() {
        var activity = TabActivity()
        XCTAssertFalse(activity.ciFailed("CI failed: Lint", visible: true), "in front of you, no mark")
        XCTAssertTrue(activity.ciFailed("CI failed: Lint", visible: false))
        XCTAssertTrue(activity.fromCI && activity.mark == .failed)
        XCTAssertTrue(activity.ciRecovered())
        XCTAssertEqual(activity.mark, .none)
        activity.clusterFailed("pod crashed", visible: false)
        XCTAssertFalse(activity.ciRecovered(), "another's mark stays")
    }
}
