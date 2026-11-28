import AppKit

/// What Overgit's buttons and menus run: pull and push, branches made,
/// merged, rebased, renamed and deleted, commits picked, reverted and reset
/// to, tags, stashes — and the way out of a merge or rebase that stopped.
///
/// A name is asked for in a sheet; anything that loses work (a hard reset,
/// a branch not merged, a remote branch, a tag) is asked about first. Every
/// command runs in the checkout the panel is about, through `Git.run`, and
/// everything that reads git is refreshed after it.
extension TerminalWindowController {
    /// `answer` and `confirmed` stand in for the sheets (the scenarios).
    @discardableResult
    package func overgit(_ command: OvergitCommand, answer: String? = nil, confirmed: Bool = false) async -> Bool {
        guard let root = overgit.root ?? diff.root, overgit.running == nil else { return false }
        let current = diff.branch
        func ask(_ title: String, _ detail: String, initial: String = "", button: String) async -> String? {
            if let answer { return answer }
            return await promptForName(title, detail, initial: initial, button: button)
        }
        func sure(_ title: String, _ detail: String, button: String) async -> Bool {
            confirmed ? true : await confirmGit(title, detail, button: button, in: root, on: current)
        }
        /// Where a branch (or, `branch` nil, a tag) goes: `answer` names it in a scenario.
        func remote(for branch: String?, _ title: String) async -> String? {
            switch await PushRemote.read(branch: branch, in: root) {
            case .remote(let name): return name
            case .none:
                alert("No remote to push to", "Add one first: git remote add <name> <url>.")
                return nil
            case .ask(let remotes, let suggested):
                if let answer { return remotes.contains(answer) ? answer : nil }
                return await promptForRemote(title, remotes: remotes, suggested: suggested)
            }
        }
        let run = { (arguments: [String], failure: String) in
            await self.runGit(arguments, in: root, command: command, failure: failure)
        }

        switch command {
        case .fetch:
            return await run(["fetch", "--all", "--prune"], "Couldn’t fetch")
        case .pull(let rebase):
            return await run(rebase ? ["pull", "--rebase"] : ["pull"], "Couldn’t pull \(current ?? "")")
        case .push:
            // To its upstream; the first time, to the remote git would push
            // it to — or the one picked — as its upstream (GIT-U8).
            guard overgit.tracking.upstream == nil else { return await run(["push"], "Couldn’t push \(current ?? "")") }
            guard let current, let remote = await remote(for: current, "Publish \(current)") else { return false }
            return await run(PushRemote.pushArguments(remote: remote, branch: current, setUpstream: true), "Couldn’t publish \(current)")

        case .newBranch(let from):
            let base = from ?? current ?? "HEAD"
            guard let name = await ask("New Branch", "From \(base). It is checked out.", button: "Create")?.trimmed, !name.isEmpty
            else { return false }
            return await run(["switch", "-c", name] + (from.map { [$0] } ?? []), "Couldn’t create \(name)")
        case .stash:
            guard let message = await ask("Stash Changes", "Uncommitted changes, untracked files too, put aside.", button: "Stash")
            else { return false }
            let named = message.trimmed.isEmpty ? [] : ["-m", message.trimmed]
            return await run(["stash", "push", "--include-untracked"] + named, "Couldn’t stash")
        case .stashStaged:
            // GIT-G9: only what is staged; the rest stays in the files.
            guard let message = await ask("Stash Staged Changes", "Only what is staged is put aside; unstaged changes stay.", button: "Stash")
            else { return false }
            let named = message.trimmed.isEmpty ? [] : ["-m", message.trimmed]
            return await run(["stash", "push", "--staged"] + named, "Couldn’t stash")
        case .popStash(let stash):
            return await run(["stash", "pop", stash.ref], "Couldn’t pop \(stash.ref)")

        case .merge(let ref):
            return await run(["merge", "--no-edit", ref], "Couldn’t merge \(ref) into \(current ?? "HEAD")")
        case .rebase(let onto):
            if let asked = await rewriteQuestion(command, in: root, current: current) {
                guard await sure(asked.title, asked.detail, button: "Rebase") else { return false }
            }
            return await run(["rebase", onto], "Couldn’t rebase \(current ?? "HEAD") onto \(onto)")

        case .pushBranch(let branch):
            // `git push <branch>` reads the branch as a remote: always name both.
            // One tracking a branch of another name (renamed) goes to that one.
            if let upstream = branch.upstream {
                let remotes = PushRemote.parse(remotes: (try? await Git.run(PushRemote.remotesArguments, in: root)) ?? "")
                if let (remote, name) = OvergitCommand.split(remoteBranch: upstream, remotes: remotes), remotes.contains(remote) {
                    return await run(["push", remote, "\(branch.name):\(name)"], "Couldn’t push \(branch.name)")
                }
            }
            guard let remote = await remote(for: branch.name, "Push \(branch.name)") else { return false }
            return await run(
                PushRemote.pushArguments(remote: remote, branch: branch.name, setUpstream: branch.upstream == nil), "Couldn’t push \(branch.name)")
        case .renameBranch(let branch):
            guard
                let name = await ask("Rename \(branch.name)", "Its upstream, if any, keeps its name.", initial: branch.name, button: "Rename")?
                    .trimmed, !name.isEmpty, name != branch.name
            else { return false }
            return await run(["branch", "-m", branch.name, name], "Couldn’t rename \(branch.name)")
        case .deleteBranch(let branch):
            if branch.isRemote {
                guard let (remote, name) = OvergitCommand.split(remoteBranch: branch.name, remotes: overgit.remotes.map(\.name)),
                    await sure("Delete \(branch.name) on \(remote)?", "The branch is deleted for everyone who uses \(remote).", button: "Delete")
                else { return false }
                return await run(["push", remote, "--delete", name], "Couldn’t delete \(branch.name)")
            }
            if await runGit(["branch", "-d", branch.name], in: root, command: command, failure: nil) { return true }
            // Not merged anywhere: its commits go with it — asked.
            guard
                await sure(
                    "\(branch.name) isn’t merged", "Deleting it loses the commits only it has (\(branch.sha) · \(branch.subject)).",
                    button: "Delete Anyway")
            else { return false }
            return await run(["branch", "-D", branch.name], "Couldn’t delete \(branch.name)")

        case .checkOutCommit(let ref):
            return await run(["switch", "--detach", ref], "Couldn’t check out \(ref)")
        case .cherryPick(let commit):
            return await run(["cherry-pick", commit.sha], "Couldn’t cherry-pick \(commit.shortSHA)")
        case .revert(let commit):
            return await run(["revert", "--no-edit", commit.sha], "Couldn’t revert \(commit.shortSHA)")
        case .reset(let commit, let mode):
            if mode == .hard {
                guard
                    await sure(
                        "Reset \(current ?? "HEAD") to \(commit.shortSHA), discarding changes?",
                        "Uncommitted changes and the commits after \(commit.shortSHA) leave the branch. Untracked files stay.",
                        button: "Reset")
                else { return false }
            } else if let asked = await rewriteQuestion(command, in: root, current: current) {
                guard await sure(asked.title, asked.detail, button: "Reset") else { return false }
            }
            return await run(["reset", "--\(mode.rawValue)", commit.sha], "Couldn’t reset to \(commit.shortSHA)")
        case .tag(let ref):
            guard let name = await ask("New Tag", "On \(ref).", button: "Create")?.trimmed, !name.isEmpty else { return false }
            return await run(["tag", name, ref], "Couldn’t tag \(ref)")

        case .pushTag(let tag):
            // The current branch's remote, as a branch's push would go, else the one picked.
            guard let remote = await remote(for: current, "Push the tag \(tag.name)") else { return false }
            return await run(["push", remote, "refs/tags/\(tag.name)"], "Couldn’t push \(tag.name)")
        case .deleteTag(let tag):
            guard await sure("Delete the tag \(tag.name)?", "Here only: a copy pushed to a remote stays there.", button: "Delete") else {
                return false
            }
            return await run(["tag", "-d", tag.name], "Couldn’t delete \(tag.name)")
        case .fetchRemote(let remote):
            return await run(["fetch", "--prune", remote.name], "Couldn’t fetch \(remote.name)")

        case .continueOperation:
            guard let state = overgit.inProgress else { return false }
            return await run(state.continueArguments, "Couldn’t continue \(state.title.lowercased())")
        case .abortOperation:
            guard let state = overgit.inProgress,
                await sure("Abort \(state.title.lowercased())?", "The branch goes back to where it was before.", button: "Abort")
            else { return false }
            return await run(state.abortArguments, "Couldn’t abort")
        }
    }

    /// Runs one command, saying so in the overview, and reads everything
    /// again after — success or not: a merge that stopped on a conflict
    /// changed the working tree all the same. `failure` nil: no alert.
    @discardableResult
    private func runGit(_ arguments: [String], in root: URL, command: OvergitCommand, failure: String?) async -> Bool {
        overgit.running = command.progress
        defer { overgit.running = nil }
        var problem: GitError?
        do {
            _ = try await Git.run(arguments, in: root, timeout: command.isNetwork ? nil : Git.defaultTimeout)
        } catch let error as GitError {
            problem = error
        } catch {}
        await diff.refresh()
        await overgit.refresh()
        if command.isNetwork || problem == nil { await worktrees.refresh() }
        guard let problem else { return true }
        // Done before it is said: a next step picked from the failure runs a command of its own.
        overgit.running = nil
        if let failure {
            if let state = overgit.inProgress {
                alert(failure, "\(state.title) stopped on conflicts. Resolve them in Changes, stage them, then Continue — or Abort.")
            } else {
                await sayGitFailure(failure, problem, command: command, root: root)
            }
        }
        return false
    }

    /// A failure said plainly, git's own words under it, and the next steps
    /// that fit it as buttons (GIT-U6) — a push the remote refused, a pull
    /// that can't fast-forward, no upstream, a sign-in, a hook.
    private func sayGitFailure(_ title: String, _ problem: GitError, command: OvergitCommand, root: URL) async {
        let kind = GitFailure.read(problem.stderr)
        let branch = diff.branch
        let pushing = command == .push
        let pulling: Bool
        if case .pull = command { pulling = true } else { pulling = false }
        var steps: [GitFailure.Next] = []
        if pushing || pulling {
            let isDefault = GitFailure.isDefault(branch, defaultBranch: await MergedWorktrees.base(in: root))
            steps = kind.next(pushing: pushing, branch: branch, isDefault: isDefault)
        }
        let said = GitFailure.excerpt(problem.errorDescription ?? "")
        let message = kind == .other ? (said.isEmpty ? "git said nothing more." : said) : kind.sentence(branch: branch) + (said.isEmpty ? "" : "\n\ngit said:\n" + said)
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for step in steps { alert.addButton(withTitle: step.title) }
        alert.addButton(withTitle: steps.isEmpty ? "OK" : "Cancel")
        let response = await alert.beginSheetModal(for: window)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard steps.indices.contains(index) else { return }
        await gitNextStep(steps[index], branch: branch, root: root)
    }

    /// One of a failure's next steps, by the panel's own commands.
    package func gitNextStep(_ step: GitFailure.Next, branch: String?, root: URL, confirmed: Bool = false) async {
        switch step {
        case .pullThenPush:
            // A merge said outright: a plain pull refuses divergent branches where pull.rebase isn't set.
            if await runGit(["pull", "--no-rebase"], in: root, command: .pull(rebase: false), failure: "Couldn’t pull \(branch ?? "")") {
                await overgit(.push, confirmed: confirmed)
            }
        case .pullRebaseThenPush:
            if await overgit(.pull(rebase: true), confirmed: confirmed) { await overgit(.push, confirmed: confirmed) }
        case .pullRebase:
            await overgit(.pull(rebase: true), confirmed: confirmed)
        case .pullMerge:
            // A plain pull refuses again where pull.rebase isn't set: a merge said outright.
            await runGit(["pull", "--no-rebase"], in: root, command: .pull(rebase: false), failure: "Couldn’t pull \(branch ?? "")")
        case .publish:
            await overgit(.push, confirmed: confirmed)
        case .stash:
            await overgit(.stash, confirmed: confirmed)
        case .forcePushWithLease:
            await forcePushWithLease(branch: branch, root: root, confirmed: confirmed)
        }
    }

    /// `git push --force-with-lease`: the remote's branch replaced by this
    /// one only if nobody pushed there since this checkout last fetched it.
    /// Always asked, the branch and the remote named; never the default branch.
    private func forcePushWithLease(branch: String?, root: URL, confirmed: Bool) async {
        guard let branch else { return }
        guard !GitFailure.isDefault(branch, defaultBranch: await MergedWorktrees.base(in: root)) else {
            return alert("Not on the default branch", "\(branch) is the default branch: it is never force-pushed from here.")
        }
        let remotes = PushRemote.parse(remotes: (try? await Git.run(PushRemote.remotesArguments, in: root)) ?? "")
        var remote: String?
        var target = branch
        if let upstream = overgit.tracking.upstream, let (name, onRemote) = OvergitCommand.split(remoteBranch: upstream, remotes: remotes) {
            remote = name
            target = onRemote
        } else if case .remote(let name) = await PushRemote.read(branch: branch, in: root) {
            remote = name
        }
        guard let remote else { return alert("No remote to push to", "Add one first: git remote add <name> <url>.") }
        if !confirmed {
            let asked = WriteConfirmation(
                title: "Force push \(branch) to \(remote)/\(target)?", scope: Self.gitScope(root: root, branch: branch),
                detail:
                    "\(remote)/\(target)'s commits that aren't in \(branch) are replaced by this branch's — with a lease: if someone pushed there since this checkout last fetched, nothing is replaced and it says so.\n\nEquals: git \(GitFailure.forcePushArguments(remote: remote, branch: branch, target: target).joined(separator: " "))",
                button: "Force Push", destroys: true)
            guard let window, await asked.ask(on: window) != nil else { return }
        }
        await runGit(GitFailure.forcePushArguments(remote: remote, branch: branch, target: target), in: root, command: .push, failure: "Couldn’t force push \(branch)")
    }

    /// What a rebase or a soft/mixed reset asks before it rewrites commits
    /// a remote already has (GIT-U7); nil when it touches none — the
    /// everyday case goes without a word. The scenarios ask it directly.
    package func rewriteQuestion(_ command: OvergitCommand, in root: URL, current: String?) async -> (title: String, detail: String)? {
        let base: String
        switch command {
        case .rebase(let onto):
            // Onto an ancestor: nothing is made again.
            if (try? await Git.run(OvergitRewrite.ancestorArguments(onto), in: root)) != nil { return nil }
            base = onto
        case .reset(let commit, let mode) where mode != .hard: base = commit.sha
        default: return nil
        }
        func count(_ arguments: [String]) async -> Int? {
            (try? await Git.run(arguments, in: root)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let total = await count(OvergitRewrite.countArguments(base: base)), total > 0 else { return nil }
        // Unreadable: counted as all pushed — asking once too often is the cheap mistake.
        let unpushed = await count(OvergitRewrite.unpushedArguments(base: base)) ?? 0
        return OvergitRewrite.question(command, current: current, pushed: total - unpushed)
    }

    /// One of several remotes, in a sheet; nil when cancelled.
    private func promptForRemote(_ title: String, remotes: [String], suggested: String?) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText =
            "This repository has \(remotes.count) remotes and nothing says which one this goes to (remote.pushDefault, or the branch's pushRemote). Pick one; the branch then tracks it."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: remotes)
        if let suggested { popup.selectItem(withTitle: suggested) }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Push")
        alert.addButton(withTitle: "Cancel")
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil
    }

    /// A name, in a sheet; nil when cancelled.
    private func promptForName(_ title: String, _ detail: String, initial: String, button: String) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// What loses work: the shared sheet, the repository and the branch
    /// checked out as its scope, Return on Cancel (D-1).
    private func confirmGit(_ title: String, _ detail: String, button: String, in root: URL, on branch: String?) async -> Bool {
        guard let window else { return false }
        let asked = WriteConfirmation(
            title: title, scope: Self.gitScope(root: root, branch: branch), detail: detail, button: button, destroys: true)
        return await asked.ask(on: window) != nil
    }

    /// The checkout with `~` for home, and the branch checked out: "~/src/app
    /// · on main". Pure.
    package nonisolated static func gitScope(root: URL, branch: String?) -> String {
        let place = (root.path as NSString).abbreviatingWithTildeInPath
        return branch.map { "\(place) · on \($0)" } ?? place
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
