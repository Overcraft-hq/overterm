import AppKit

/// Check Out in a New Worktree (GIT-G2's last slice, P06): a pull request
/// in a worktree of its own, a tab in it — asked first, never over one
/// that is there. Its branch where it is this repository's, so it can be
/// committed on; a fork's detached at its head through `gh pr checkout
/// --detach`, no branch made or moved.
extension TerminalWindowController {
    /// How it is checked out. Pure.
    package enum PullRequestCheckout: Equatable {
        /// Its branch is already a worktree's: a tab there, nothing made.
        case open(URL)
        /// The branch is there locally: `git worktree add <path> <branch>`.
        case localBranch(path: URL)
        /// Only on origin: fetched, then a tracking branch of the same name.
        case remoteBranch(path: URL)
        /// A fork's: detached, `gh pr checkout <n> --detach` in it.
        case fork(path: URL)

        package var path: URL {
            switch self {
            case .open(let path), .localBranch(let path), .remoteBranch(let path), .fork(let path): path
            }
        }

        package func gitArguments(branch: String) -> [String]? {
            switch self {
            case .open: nil
            case .localBranch(let path): ["worktree", "add", "--", path.path, branch]
            case .remoteBranch(let path): ["worktree", "add", "--track", "-b", branch, "--", path.path, "origin/\(branch)"]
            case .fork(let path): ["worktree", "add", "--detach", "--", path.path, "HEAD"]
            }
        }

        /// The question's detail.
        package func said(number: Int, branch: String) -> String {
            switch self {
            case .open: "\(branch) is already checked out there."
            case .localBranch(let path): "A new worktree at \(path.path), on its branch \(branch)."
            case .remoteBranch(let path): "A new worktree at \(path.path), on \(branch) fetched from origin and tracking it."
            case .fork(let path):
                "A new worktree at \(path.path), detached at #\(number)'s head, fetched by gh pr checkout \(number) --detach — it is a fork's, so no branch is made or moved in your repository."
            }
        }
    }

    /// The shown pull request, checked out.
    package func checkOutShownPullRequest() {
        guard let detail = pullRequest.detail else { return NSSound.beep() }
        checkOutPullRequest(number: detail.summary.number, branch: detail.summary.branch, fork: detail.crossRepository)
    }

    package func checkOutPullRequest(number: Int, branch: String, fork: Bool) {
        guard let repo = worktrees.main?.path, !branch.hasPrefix("-") else { return NSSound.beep() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.worktrees.refresh()
            let how: PullRequestCheckout
            if !fork, let there = self.worktrees.worktrees.first(where: { $0.branch == branch }) {
                how = .open(there.path)
            } else {
                let location = Settings.shared.worktreeLocation
                let path = TaskCreator.worktreePath(repo: repo, branch: fork ? "pr-\(number)" : branch, location: location)
                guard !FileManager.default.fileExists(atPath: path.path) else {
                    return self.pullRequestCheckoutRefused("\(path.lastPathComponent) already exists", "Open a tab there, or remove it first.")
                }
                if fork {
                    how = .fork(path: path)
                } else {
                    let local = (try? await Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: repo)) != nil
                    how = local ? .localBranch(path: path) : .remoteBranch(path: path)
                }
                if location == .inside { await TaskCreator.excludeWorktreesFolder(in: repo) }
            }
            if case .open(let path) = how { return self.openPullRequestWorktree(path, number: number) }
            let asked: Bool
            if let pullRequestCheckoutRecorder = self.pullRequestCheckoutRecorder {
                asked = pullRequestCheckoutRecorder(how)
            } else {
                asked =
                    await WriteConfirmation(
                        title: "Check out #\(number) in a new worktree?", scope: nil, detail: how.said(number: number, branch: branch), button: "Check Out"
                    ).ask(on: self.window) != nil
            }
            guard asked, let add = how.gitArguments(branch: branch) else { return }
            do {
                if case .remoteBranch = how { _ = try await Git.run(["fetch", "origin", "--", branch], in: repo, timeout: nil) }
                _ = try await Git.run(add, in: repo, timeout: nil)
            } catch let error as GitError {
                return self.pullRequestCheckoutRefused("Not checked out", error.stderr.split(separator: "\n").first.map(String.init) ?? "git couldn’t make the worktree.")
            } catch {
                return self.pullRequestCheckoutRefused("Not checked out", error.localizedDescription)
            }
            if case .fork(let path) = how {
                do {
                    _ = try await GitHub.run(["pr", "checkout", "\(number)", "--detach"], in: path, timeout: 300)
                } catch {
                    // Not left behind at the main checkout's HEAD.
                    _ = try? await Git.run(["worktree", "remove", "--force", path.path], in: repo, timeout: 60)
                    return self.pullRequestCheckoutRefused("Not checked out", "gh pr checkout \(number) --detach failed: \(error.localizedDescription)")
                }
            }
            await self.worktrees.refresh()
            await self.prepareTerraformWorktree(how.path)
            self.openPullRequestWorktree(how.path, number: number)
        }
    }

    /// A tab in it, named after the pull request — the one there already if any.
    private func openPullRequestWorktree(_ path: URL, number: Int) {
        let resolved = path.standardizedFileURL.path
        if let tab = store.tabs.first(where: { $0.workingDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == resolved }) {
            return reveal(tabID: tab.id)
        }
        newTab(in: path)
        store.selected?.customTitle = "#\(number)"
    }

    private func pullRequestCheckoutRefused(_ title: String, _ detail: String) {
        if let pullRequestProblemRecorder { return pullRequestProblemRecorder("\(title): \(detail)") }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}
