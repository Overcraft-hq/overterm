#if E2E
import AppKit
import Foundation

/// The pull request loop (P06): a failed check's log in the pane, the
/// writes asked and sent (D-9 (c)), CI going red marking a tab with the
/// Inbox's card and Ask Agent to Fix, green taking them back, and Create
/// Pull Request publishing a branch first. All against the scenario's
/// stand-in gh: nothing reaches GitHub.
extension E2ERunner {
    func pullRequestLoopChecks(repo: URL, feature: URL, log: URL) async {
        func logged() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        func setChecks(_ checks: [(String, String?)]) {
            let json = "[" + checks.map { "[\"\($0.0)\", \($0.1.map { "\"\($0)\"" } ?? "null")]" }.joined(separator: ",") + "]"
            try? json.write(toFile: log.path + ".checks", atomically: true, encoding: .utf8)
        }

        // The feature's tab, its pull request in the pane.
        guard let featureTab = app.store.tabs.first(where: { $0.workingDirectory == feature.path || app.branch(of: $0) == "feat/pr" }) else {
            return check("the feature's tab", false)
        }
        app.reveal(tabID: featureTab.id)
        _ = await eventually(5) { self.app.diff.branch == "feat/pr" }
        app.showPullRequest(nil)
        _ = await eventually(8) { self.app.pullRequest.detail?.summary.number == 7 }
        guard let lint = app.pullRequest.detail?.checks.first(where: { $0.name == "Lint" }) else { return check("its failing check", false) }
        check("a failed check is a GitHub Actions job, its run and job read", lint.actionsJob?.run == 11 && lint.actionsJob?.job == 22 && lint.workflow == "CI")

        // Its log, here: the failed step's tail, no timestamps or colours, no token.
        await app.pullRequest.loadLog(of: lint)
        guard case .loaded(let text)? = app.pullRequest.logs["Lint"] else {
            return check("its log loads in the pane", false, "\(String(describing: app.pullRequest.logs["Lint"]))")
        }
        check("its log loads in the pane", text.contains("error: lint failed in app.swift:2") && text.contains("── Run golangci-lint ──"), text)
        check("without timestamps or escapes", !text.contains("2026-11-27T") && !text.contains("\u{1b}"), text)
        check("and never the token it printed", !text.contains("ghp_e2eFakeTokenValue"), text)

        // The writes: asked (the recorder answers), then sent as gh's words.
        var asked: [PullRequestWrite] = []
        var refused: [String] = []
        app.pullRequestWriteRecorder = {
            asked.append($0); return true
        }
        app.pullRequestProblemRecorder = { refused.append($0) }
        await app.performPullRequestWrite(.ready(number: 7))
        await app.performPullRequestWrite(.approve(number: 7, body: "Looks right"))
        await app.performPullRequestWrite(.requestChanges(number: 7, body: ""))
        await app.performPullRequestWrite(.merge(number: 7, method: .squash, head: "x"))
        await app.performPullRequestWrite(.rerunFailed(run: 11))
        let sent = logged()
        check("Mark Ready is asked, then sent", asked.first == .ready(number: 7) && sent.contains("write ready 7"), sent)
        check("Approve sends its body", sent.contains("write review 7 --approve --body Looks right"), sent)
        check("Request Changes with nothing said is refused before asking", refused.count == 1 && !sent.contains("--request-changes"), "\(refused)")
        check("Merge only at the head shown", sent.contains("write merge 7 --squash --match-head-commit x"), sent)
        check("Re-run Failed Jobs", sent.contains("write rerun 11 --failed"), sent)
        // A write declined sends nothing.
        app.pullRequestWriteRecorder = { _ in false }
        await app.performPullRequestWrite(.ready(number: 7))
        check("a write declined sends nothing", logged().components(separatedBy: "write ready 7").count == 2)
        app.pullRequestWriteRecorder = nil
        app.pullRequestProblemRecorder = nil

        // CI on the feature's branch, the tab not in front: green, then red.
        app.newTab(in: repo)
        _ = await eventually(5) { self.app.diff.branch == "main" }
        setChecks([("Go", "SUCCESS"), ("Lint", "SUCCESS")])
        await app.worktrees.refreshPullRequests()
        check("green: no mark", featureTab.ciFailure == nil)
        setChecks([("Go", "SUCCESS"), ("Lint", "FAILURE")])
        await app.worktrees.refreshPullRequests()
        check(
            "red on the way in: the tab is marked, with its check named",
            await eventually(3) { featureTab.ciFailure?.failing.map(\.name) == ["Lint"] } && featureTab.activity.mark == .failed
                && featureTab.activity.note == "CI failed: Lint", featureTab.activity.note ?? "no note")
        app.refreshInbox()
        let entry = app.inbox.entries.first { $0.id == featureTab.id }
        check("the Inbox has its card", entry?.ci != nil && entry?.headline.contains("CI failed: Lint") == true, entry?.headline ?? "no card")
        await app.worktrees.refreshPullRequests()
        check("the same red again is no news", featureTab.ciFailure != nil && featureTab.activity.mark == .failed)

        // Ask Agent to Fix: the brief with the log's tail, masked, typed nowhere yet.
        app.askAgentToFixCI(on: featureTab.id)
        let shown = await eventually(10) { self.window.attachedSheet != nil && self.app.askAgent.isOpen }
        let brief = app.askAgent.prompt(diff: nil)
        check(
            "Ask Agent to Fix offers the brief: the check, its workflow file, its log, no token",
            shown && brief.contains("Check: Lint — workflow CI (.github/workflows/ci.yml)") && brief.contains("error: lint failed")
                && !brief.contains("ghp_e2eFakeTokenValue"), "\(brief.prefix(400))")
        app.askAgent.stop()
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(5) { self.window.attachedSheet == nil }

        // A push: the new run going keeps the card, said; green takes it back.
        setChecks([("Go", "SUCCESS"), ("Lint", nil)])
        await app.worktrees.refreshPullRequests()
        check("a new run going keeps the card, said", featureTab.ciFailure?.rerunning == true, featureTab.ciFailure?.note ?? "gone")
        setChecks([("Go", "SUCCESS"), ("Lint", "SUCCESS")])
        await app.worktrees.refreshPullRequests()
        check("green again: the card and the mark go", featureTab.ciFailure == nil && featureTab.activity.mark == .none)
        app.refreshInbox()
        check("and the Inbox has none", !app.inbox.entries.contains { $0.id == featureTab.id && $0.ci != nil })

        // Create Pull Request: a branch with none, published first.
        let origin = scratch.appendingPathComponent("origin.git")
        try? await git(["init", "-q", "--bare", origin.path], in: scratch)
        try? await git(["remote", "add", "origin", origin.path], in: repo)
        let fresh = scratch.appendingPathComponent("wt-new")
        try? await git(["worktree", "add", "-q", "-b", "feat/new", fresh.path], in: repo)
        try? "c\n".write(to: fresh.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
        try? await git(["add", "."], in: fresh)
        try? await git(["-c", "user.email=e2e@example.test", "-c", "user.name=e2e", "commit", "-q", "-m", "Add the new thing"], in: fresh)
        app.newTab(in: fresh)
        _ = await eventually(5) { self.app.diff.branch == "feat/new" }
        guard let facts = await app.createPullRequestFacts() else { return check("Create Pull Request reads its facts", false) }
        check(
            "the sheet's facts: its commit, the base, published first",
            facts.commits.map(\.subject) == ["Add the new thing"] && facts.base == "main" && facts.publishes,
            "\(facts.commits.map(\.subject)) \(facts.base) \(facts.publishes)")
        let filled = PullRequestDraft.fill(commits: facts.commits, branch: facts.branch)
        var created: Int?
        app.pullRequestCreatedRecorder = { created = $0 }
        let failure = await app.openPullRequest(
            .create(title: filled.title, body: filled.body, base: facts.base, head: facts.branch, draft: true), facts: facts, in: fresh)
        app.pullRequestCreatedRecorder = nil
        let pushed = (try? await Git.run(["ls-remote", "origin", "refs/heads/feat/new"], in: repo)) ?? ""
        check("the branch is published first", failure == nil && !pushed.isEmpty, failure ?? "not pushed")
        check(
            "then the pull request opened, draft, from its commit",
            logged().contains("write create --title Add the new thing --body  --base main --head feat/new --draft") && created == 8,
            logged())

        // Check Out in a New Worktree: its branch checked out already is
        // its tab; a branch only on origin made one, tracking it; a fork
        // declined, nothing made.
        var checkouts: [TerminalWindowController.PullRequestCheckout] = []
        app.pullRequestCheckoutRecorder = {
            checkouts.append($0); return true
        }
        app.checkOutPullRequest(number: 7, branch: "feat/pr", fork: false)
        check(
            "a pull request whose branch is a worktree's opens there, nothing asked",
            await eventually(5) { self.app.store.selected?.workingDirectory == feature.path } && checkouts.isEmpty,
            app.store.selected?.workingDirectory ?? "none")
        try? await git(["branch", "feat/remote-only"], in: repo)
        try? await git(["push", "-q", "origin", "feat/remote-only"], in: repo)
        try? await git(["branch", "-D", "feat/remote-only"], in: repo)
        app.checkOutPullRequest(number: 9, branch: "feat/remote-only", fork: false)
        let made = TaskCreator.worktreePath(repo: repo, branch: "feat/remote-only", location: Settings.shared.worktreeLocation)
        let checkedOut = await eventually(15) { self.app.store.selected?.title == "#9" }
        let upstream = (try? await Git.run(["rev-parse", "--abbrev-ref", "@{u}"], in: made))?.trimmingCharacters(in: .whitespacesAndNewlines)
        check(
            "a branch only on origin: asked, then a worktree on it, tracking origin, its tab",
            checkedOut && checkouts.count == 1 && upstream == "origin/feat/remote-only", "\(checkouts) \(upstream ?? "no upstream")")
        app.pullRequestCheckoutRecorder = {
            checkouts.append($0); return false
        }
        app.checkOutPullRequest(number: 11, branch: "patch-1", fork: true)
        let forkPath = TaskCreator.worktreePath(repo: repo, branch: "pr-11", location: Settings.shared.worktreeLocation)
        _ = await eventually(5) { checkouts.count == 2 }
        check("a fork's, declined: nothing made", checkouts.last == TerminalWindowController.PullRequestCheckout.fork(path: forkPath) && !FileManager.default.fileExists(atPath: forkPath.path))
        app.pullRequestCheckoutRecorder = nil
    }
}
#endif
