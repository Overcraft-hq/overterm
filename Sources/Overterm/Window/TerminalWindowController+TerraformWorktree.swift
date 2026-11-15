import Foundation

// MARK: New Task's Terraform (docs/design/terraform/analysis.md 2.1, 3.7, stage 2b)

extension TerminalWindowController {
    /// A worktree New Task just made: its roots read against the
    /// repository's other worktrees — the no-state warning, the lock files,
    /// the workspace not copied — and initialised without their backend
    /// where nothing flagged is fetched (`TerraformWorktreeSetup`). The
    /// panel reads again once it is done. The other worktrees are the
    /// window's list when it already has the new one (CLAUDE.md: never
    /// asked twice); else — the window's list follows the selected tab and
    /// may still be another repository's — one `git worktree list` there.
    func prepareTerraformWorktree(_ path: URL) async {
        guard Settings.shared.terraformEnabled else { return }
        var listed = worktrees.worktrees
        if TerraformWorktree.others(listed, of: path).isEmpty {
            listed = (try? await Git.run(["worktree", "list", "--porcelain"], in: path)).map(Worktree.parse(porcelain:)) ?? []
        }
        let others = TerraformWorktree.others(listed, of: path)
        TerraformWorktreeSetup.shared.prepare(path, others: others, initialize: Settings.shared.terraformNewWorktreeInit) { [weak self] in
            self?.terraformPanel.refresh()
        }
    }
}
