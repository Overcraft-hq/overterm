import Foundation

/// The worktrees of the repository the selected tab is in.
@MainActor
final class WorktreeModel: ObservableObject {
    @Published private(set) var worktrees: [Worktree] = []
    /// Branches of linked worktrees that are merged (see MergedWorktrees).
    @Published private(set) var merged: [String: MergedWorktrees.Reason] = [:]
    /// Each branch's pull request (gh), when there is one.
    @Published private(set) var pullRequests: [String: PullRequestSummary] = [:]
    /// Why pull requests aren't shown (no gh, not logged in, no remote) —
    /// for the repository shown now, never one asked about before: an error
    /// left over from a tab outside a repository (or a worktree whose .git
    /// points nowhere) hid the list of the next one.
    @Published private(set) var pullRequestError: String?
    private var pullRequestErrors: [URL: String] = [:]
    /// gh is network: a tab switch reuses what a minute-old list said.
    private var pullRequestCache: [URL: (at: Date, byBranch: [String: PullRequestSummary])] = [:]
    static let pullRequestMaxAge: TimeInterval = 60
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
    /// `fetch` also asks GitHub again for pull requests.
    func refresh(fetch: Bool = false) async {
        guard let anchor else {
            worktrees = []
            merged = [:]
            pullRequests = [:]
            return
        }
        if fetch { await MergedWorktrees.fetch(in: anchor) }
        let listed = (try? await Git.run(["worktree", "list", "--porcelain"], in: anchor)).map(Worktree.parse(porcelain:)) ?? []
        // Not in a repository (or in a worktree git can't follow): nothing
        // to ask GitHub about, and no error to show for it.
        guard let repo = listed.first(where: { $0.isMain })?.path else {
            guard anchor == self.anchor else { return }
            worktrees = []
            merged = [:]
            pullRequests = [:]
            pullRequestError = nil
            return
        }
        var merged = await MergedWorktrees.find(in: anchor, worktrees: listed)
        let pullRequests = await pullRequests(in: repo, force: fetch)
        let branches = listed.filter { !$0.isMain }.compactMap(\.branch)
        let tips = await Self.branchTips(in: repo)
        merged.merge(MergedWorktrees.mergedByPullRequest(pullRequests, branches: branches, tips: tips)) { git, _ in git }
        // A tab switch may have moved the anchor while git ran.
        guard anchor == self.anchor else { return }
        worktrees = listed
        self.merged = merged
        self.pullRequests = pullRequests
        pullRequestError = pullRequestErrors[repo]
    }

    /// Asks gh again for the current repository's pull requests (CI moves on
    /// while nothing local changes).
    func refreshPullRequests() async {
        if let repo = main?.path { pullRequestCache[repo] = nil }
        await refresh()
    }

    /// Open pull requests asked for at most — more than a repository has open.
    static let maxOpenPullRequests = 500

    private func pullRequests(in repo: URL, force: Bool) async -> [String: PullRequestSummary] {
        if !force, let cached = pullRequestCache[repo], Date().timeIntervalSince(cached.at) < Self.pullRequestMaxAge {
            return cached.byBranch
        }
        do {
            // Every open one, then the newest of all for the merged: the
            // newest 60 alone left out every open pull request older than
            // the last 60 merged — a busy repository showed 1 of 7.
            let open = try await GitHub.run(
                ["pr", "list", "--state", "open", "--limit", "\(Self.maxOpenPullRequests)", "--json", PullRequestSummary.listFields], in: repo)
            let recent = try await GitHub.run(
                ["pr", "list", "--state", "all", "--limit", "60", "--json", PullRequestSummary.listFields], in: repo)
            let byBranch = PullRequestSummary.byBranch(
                PullRequestSummary.merged(try PullRequestSummary.parseList(open), try PullRequestSummary.parseList(recent)))
            pullRequestCache[repo] = (Date(), byBranch)
            pullRequestErrors[repo] = nil
            return byBranch
        } catch {
            // What gh said last time stands only while there is no list:
            // a failed refresh of a list we have keeps showing the list.
            pullRequestErrors[repo] = pullRequestCache[repo] == nil ? error.localizedDescription : nil
            return pullRequestCache[repo]?.byBranch ?? [:]
        }
    }

    private static func branchTips(in repo: URL) async -> [String: String] {
        let output = (try? await Git.run(["for-each-ref", "--format=%(refname:short)%00%(objectname)", "refs/heads"], in: repo)) ?? ""
        var tips: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\0").map(String.init)
            if fields.count == 2 { tips[fields[0]] = fields[1] }
        }
        return tips
    }

    /// Linked worktrees there is no reason to keep: merged, or their
    /// directory already gone.
    var cleanable: [Worktree] {
        worktrees.filter { !$0.isMain && ($0.isPrunable || $0.branch.map { merged[$0] != nil } == true) }
    }

    /// The main worktree — where new worktrees are created from.
    var main: Worktree? { worktrees.first { $0.isMain } }
}
