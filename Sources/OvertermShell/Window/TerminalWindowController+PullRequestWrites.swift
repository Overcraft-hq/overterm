import AppKit

/// The pull request's writes (D-9 (c), P06): Create Pull Request… and, on
/// one, Mark Ready, Approve, Request Changes, Merge… and a failed run's
/// Re-run — each asked first, naming the repository and the pull request,
/// none an agent's.
extension TerminalWindowController {
    /// ⌘K and the menus: the checkout's branch's pull request, made.
    @objc package func createPullRequest(_ sender: Any?) {
        Task { @MainActor [weak self] in await self?.presentCreatePullRequest() }
    }

    /// What the sheet says, read now: the commits the base hasn't, whether
    /// the branch is published, how many aren't pushed. Nil off a branch.
    package func createPullRequestFacts() async -> CreatePullRequestFacts? {
        guard let root = diff.root, let branch = diff.branch else { return nil }
        func git(_ arguments: [String]) async -> String? {
            (try? await Git.run(arguments, in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let remote = await git(["remote", "get-url", "origin"]) ?? ""
        let repository = GitRemoteURL(remote)?.path ?? GitRemoteURL.withoutUserinfo(remote)
        // The repository's default branch, as origin says it, else the main worktree's.
        let originHead = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).map { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : $0 }
        let base = originHead ?? worktrees.main?.branch ?? "main"
        let upstream = await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        let unpushed = upstream == nil ? 0 : Int(await git(["rev-list", "--count", "@{u}..HEAD"]) ?? "") ?? 0
        // Against origin's base when there is one, else the local one.
        let against = await git(["rev-parse", "--verify", "--quiet", "origin/\(base)"]) != nil ? "origin/\(base)" : base
        let log = await git(["log", "--format=%s%x1f%b%x1e", "--max-count=200", "\(against)..HEAD"]) ?? ""
        return CreatePullRequestFacts(
            repository: repository.isEmpty ? (root.lastPathComponent) : repository, branch: branch, base: base,
            commits: PullRequestDraft.commits(log: log), publishes: upstream == nil, unpushed: unpushed)
    }

    package func presentCreatePullRequest() async {
        guard let facts = await createPullRequestFacts(), let root = diff.root else {
            return NSSound.beep()
        }
        presentSheet { [weak self] close in
            CreatePullRequestView(
                facts: facts,
                onCreate: { title, body, base, draft in
                    guard let self else { return nil }
                    let write = PullRequestWrite.create(title: title, body: body, base: base, head: facts.branch, draft: draft)
                    if let problem = write.problem { return problem }
                    if let failure = await self.openPullRequest(write, facts: facts, in: root) { return failure }
                    close()
                    return nil
                },
                onCancel: close)
        }
    }

    /// Published or pushed first where the sheet said so, then opened; the
    /// pane shows it. An error's words, or nil.
    package func openPullRequest(_ write: PullRequestWrite, facts: CreatePullRequestFacts, in root: URL) async -> String? {
        if facts.publishes || facts.unpushed > 0 {
            let arguments = facts.publishes ? ["push", "--set-upstream", "origin", "HEAD"] : ["push"]
            do {
                _ = try await Git.run(arguments, in: root, timeout: nil)
            } catch {
                return "Couldn’t push \(facts.branch): \(error.localizedDescription)"
            }
        }
        let created: Data
        do {
            created = try await GitHub.run(write.arguments, in: root, timeout: 60)
        } catch {
            return error.localizedDescription
        }
        await worktrees.refreshPullRequests()
        if let number = PullRequestDraft.number(created: String(decoding: created, as: UTF8.self)) {
            pullRequestCreatedRecorder?(number)
        }
        pullRequest.unpick()
        await pullRequest.refresh()
        showPullRequest(nil)
        return nil
    }

    /// The pane's own writes: asked, naming the repository and the pull
    /// request, then sent; the pane read again. A merge offers Clean Up.
    @discardableResult
    package func performPullRequestWrite(_ write: PullRequestWrite) async -> Bool {
        guard let root = pullRequest.root else { return false }
        if let problem = write.problem {
            showPullRequestProblem(problem)
            return false
        }
        let repository = pullRequest.detail?.summary.url.flatMap(Self.repository(of:)) ?? root.lastPathComponent
        let words = write.question(repository: repository)
        let asked: Bool
        if let pullRequestWriteRecorder {
            asked = pullRequestWriteRecorder(write)
        } else {
            asked =
                await WriteConfirmation(title: words.title, scope: words.scope, detail: words.detail, button: words.button, critical: write.destroys, destroys: write.destroys)
                .ask(on: window) != nil
        }
        guard asked else { return false }
        do {
            _ = try await GitHub.run(write.arguments, in: root, timeout: 60)
        } catch {
            showPullRequestProblem(error.localizedDescription)
            return false
        }
        await pullRequest.refresh()
        await worktrees.refreshPullRequests()
        // Merged: what can go now is offered (a scenario's recorder says it
        // was merged; the clean-up is its own, asked, elsewhere).
        if case .merge = write, pullRequestWriteRecorder == nil { cleanUpMergedWorktrees(nil) }
        return true
    }

    /// `acme/shop` from a pull request's URL (`https://github.com/acme/shop/pull/7`). Pure.
    package nonisolated static func repository(of url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    private func showPullRequestProblem(_ message: String) {
        if let pullRequestProblemRecorder { return pullRequestProblemRecorder(message) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "GitHub didn’t take it"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
