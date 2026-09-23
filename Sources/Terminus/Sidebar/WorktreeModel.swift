import Foundation

/// The worktrees of the repository the selected tab is in.
@MainActor
final class WorktreeModel: ObservableObject {
    @Published private(set) var worktrees: [Worktree] = []
    /// A directory inside the repository (the file tree's root).
    private(set) var anchor: URL?

    func setAnchor(_ url: URL?) {
        guard url != anchor else { return }
        anchor = url
        Task { await refresh() }
    }

    /// Re-lists worktrees. Outside a repository the list is simply empty.
    func refresh() async {
        guard let anchor else {
            worktrees = []
            return
        }
        let listed = (try? await Git.run(["worktree", "list", "--porcelain"], in: anchor)).map(Worktree.parse(porcelain:)) ?? []
        // A tab switch may have moved the anchor while git ran.
        guard anchor == self.anchor else { return }
        worktrees = listed
    }

    /// The main worktree — where new worktrees are created from.
    var main: Worktree? { worktrees.first { $0.isMain } }
}
