import Foundation

/// The worktrees of the repository the selected tab is in.
@MainActor
final class WorktreeModel: ObservableObject {
    @Published private(set) var worktrees: [Worktree] = []
    /// Branches of linked worktrees that are merged (see MergedWorktrees).
    @Published private(set) var merged: [String: MergedWorktrees.Reason] = [:]
    /// What the selected tab shows, and why (set by the window).
    @Published var showing: (root: URL, reason: CheckoutReason)?
    /// A directory inside the repository (the file tree's root).
    private(set) var anchor: URL?

    func setAnchor(_ url: URL?) {
        guard url != anchor else { return }
        anchor = url
        Task { await refresh() }
    }

    /// Re-lists worktrees. Outside a repository the list is simply empty.
    /// `fetch` first runs `git fetch --prune` (network), so merges made on
    /// the remote show up.
    func refresh(fetch: Bool = false) async {
        guard let anchor else {
            worktrees = []
            merged = [:]
            return
        }
        if fetch { await MergedWorktrees.fetch(in: anchor) }
        let listed = (try? await Git.run(["worktree", "list", "--porcelain"], in: anchor)).map(Worktree.parse(porcelain:)) ?? []
        let merged = await MergedWorktrees.find(in: anchor, worktrees: listed)
        // A tab switch may have moved the anchor while git ran.
        guard anchor == self.anchor else { return }
        worktrees = listed
        self.merged = merged
    }

    /// Linked worktrees there is no reason to keep: merged, or their
    /// directory already gone.
    var cleanable: [Worktree] {
        worktrees.filter { !$0.isMain && ($0.isPrunable || $0.branch.map { merged[$0] != nil } == true) }
    }

    /// The main worktree — where new worktrees are created from.
    var main: Worktree? { worktrees.first { $0.isMain } }
}
