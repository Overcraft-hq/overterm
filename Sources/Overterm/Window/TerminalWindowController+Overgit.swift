import AppKit
import Combine

/// Overgit: the git panel in the sidebar, and the few things its rows ask
/// the window to do.
extension TerminalWindowController {
    /// The panel reads git only while it is the one on screen and the
    /// sidebar is open — both can change without the view hearing about it,
    /// so the window is what tells it.
    func wireOvergit() {
        sidebarPanel.$panel
            // @Published fires before the value lands.
            .sink { [weak self] panel in
                DispatchQueue.main.async { self?.updateOvergitVisibility(panel: panel) }
            }
            .store(in: &cancellables)
        // The checkout changed under an agent (or anybody): the history did
        // too. Debounced, because a build writes a thousand files.
        diff.$files
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.overgit.refresh() } }
            .store(in: &cancellables)
        updateOvergitVisibility()
    }

    func updateOvergitVisibility(panel: SidebarPanel? = nil) {
        let shown = sidebarItem?.isCollapsed == false
        overgit.visible = shown && (panel ?? sidebarPanel.panel) == .git
    }

    /// View ▸ Overgit (⌥⌘G): the sidebar, on the git panel.
    @objc func showOvergit(_ sender: Any?) {
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .git
        updateOvergitVisibility()
    }

    /// The right pane, on the working tree's changes — the overview's
    /// `+x −y`.
    @objc func showChanges(_ sender: Any?) {
        rightPane.mode = .changes
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
    }

    /// Overgit ▸ Compare: what `head` has that `base` doesn't, in the
    /// right-hand pane. "HEAD" is the checkout's branch, by its name.
    func showCompare(base: String, head: String) {
        let name: (String) -> String = { [diff] ref in ref == "HEAD" ? diff.branch ?? "HEAD" : ref }
        compare.show(root: overgit.root ?? diff.root, base: name(base), head: name(head))
        rightPane.compareOpened = true
        rightPane.mode = .compare
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// A file clicked in Overgit's Changes: its diff in the changes pane.
    func showChangedFile(_ file: ChangedFile) {
        showChanges(nil)
        // A turn later: the pane lays its cards out as it opens.
        DispatchQueue.main.async { [weak self] in self?.diff.reveal(file.path) }
    }

    /// A commit was picked in the panel: the right-hand pane shows it.
    /// That pane is the slot the browser shares, so the browser steps
    /// aside as it does for the changes pane.
    func showCommit(_ commit: Commit) {
        overgit.selected = commit.sha
        commitDetail.show(root: overgit.root, sha: commit.sha)
        rightPane.mode = .commit
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// Checks `branch` out in the checkout the panel is about. A remote
    /// branch is tracked, which is what clicking one means.
    func checkOut(_ branch: BranchRef) {
        guard let root = diff.root else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let arguments = branch.isRemote ? ["checkout", "--track", branch.name] : ["checkout", branch.name]
                _ = try await Git.run(arguments, in: root)
                await self.diff.refresh()
                await self.overgit.refresh()
                await self.worktrees.refresh()
            } catch let error as GitError {
                self.alert("Couldn’t check out \(branch.name)", error.stderr)
            } catch {}
        }
    }

    func applyStash(_ stash: Stash) {
        run(["stash", "apply", stash.ref], failing: "Couldn’t apply \(stash.ref)")
    }

    /// Dropping one is not undoable, so it asks.
    func dropStash(_ stash: Stash) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Drop \(stash.ref)?"
        alert.informativeText = "\(stash.subject)\n\nThe stashed changes are gone for good."
        alert.addButton(withTitle: "Drop")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.run(["stash", "drop", stash.ref], failing: "Couldn’t drop \(stash.ref)")
        }
    }

    /// One git command in the current checkout, with everything that reads
    /// it refreshed after.
    private func run(_ arguments: [String], failing title: String) {
        guard let root = diff.root else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Git.run(arguments, in: root)
                await self.diff.refresh()
                await self.overgit.refresh()
            } catch let error as GitError {
                self.alert(title, error.stderr)
            } catch {}
        }
    }

    private func alert(_ title: String, _ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.isEmpty ? "git said nothing more." : message
        alert.beginSheetModal(for: window)
    }
}
