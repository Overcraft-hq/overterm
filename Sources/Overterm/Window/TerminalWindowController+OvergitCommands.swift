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
    func overgit(_ command: OvergitCommand, answer: String? = nil, confirmed: Bool = false) async -> Bool {
        guard let root = overgit.root ?? diff.root, overgit.running == nil else { return false }
        let current = diff.branch
        func ask(_ title: String, _ detail: String, initial: String = "", button: String) async -> String? {
            if let answer { return answer }
            return await promptForName(title, detail, initial: initial, button: button)
        }
        func sure(_ title: String, _ detail: String, button: String) async -> Bool {
            confirmed ? true : await confirmGit(title, detail, button: button)
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
            // To its upstream, or, the first time, to origin as its upstream.
            let arguments = overgit.tracking.upstream == nil ? ["push", "--set-upstream", "origin", "HEAD"] : ["push"]
            return await run(arguments, "Couldn’t push \(current ?? "")")

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
        case .popStash(let stash):
            return await run(["stash", "pop", stash.ref], "Couldn’t pop \(stash.ref)")

        case .merge(let ref):
            return await run(["merge", "--no-edit", ref], "Couldn’t merge \(ref) into \(current ?? "HEAD")")
        case .rebase(let onto):
            return await run(["rebase", onto], "Couldn’t rebase \(current ?? "HEAD") onto \(onto)")

        case .pushBranch(let branch):
            let upstream = branch.upstream == nil ? ["--set-upstream", "origin"] : []
            return await run(["push"] + upstream + [branch.name], "Couldn’t push \(branch.name)")
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
            }
            return await run(["reset", "--\(mode.rawValue)", commit.sha], "Couldn’t reset to \(commit.shortSHA)")
        case .tag(let ref):
            guard let name = await ask("New Tag", "On \(ref).", button: "Create")?.trimmed, !name.isEmpty else { return false }
            return await run(["tag", name, ref], "Couldn’t tag \(ref)")

        case .pushTag(let tag):
            return await run(["push", "origin", "refs/tags/\(tag.name)"], "Couldn’t push \(tag.name)")
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
        if let failure {
            if let state = overgit.inProgress {
                alert(failure, "\(state.title) stopped on conflicts. Resolve them in Changes, stage them, then Continue — or Abort.")
            } else {
                alert(failure, problem.errorDescription ?? "")
            }
        }
        return false
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

    private func confirmGit(_ title: String, _ detail: String, button: String) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
