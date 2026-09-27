import Foundation

/// Which linked worktrees are done with: their branch is merged.
///
/// "Merged" is either
/// - the upstream is `[gone]`: pushed, then deleted on the remote — what
///   GitHub does on merge, and the only trace a squash merge leaves; or
/// - pushed, and the tip is reachable from the default branch (a merge
///   commit or a fast-forward).
///
/// Reachability alone is not enough: a New Task branch with no commits yet
/// is reachable from main too. Never pushed means never merged here.
enum MergedWorktrees {
    struct Branch: Equatable {
        let name: String
        let hasUpstream: Bool
        let upstreamGone: Bool
    }

    enum Reason: Equatable {
        case upstreamGone
        case mergedInto(String)
        /// Its pull request is merged, and the branch has nothing since.
        case pullRequestMerged(Int)
    }

    /// Merged pull requests of linked worktrees' branches, where the branch
    /// still points at the merged head: a reused branch name with new work
    /// on it is not merged. `tips`: branch → commit.
    static func mergedByPullRequest(
        _ pullRequests: [String: PullRequestSummary], branches: [String], tips: [String: String]
    ) -> [String: Reason] {
        var result: [String: Reason] = [:]
        for branch in branches {
            guard let pr = pullRequests[branch], pr.state == .merged, let head = pr.headOid, tips[branch] == head else { continue }
            result[branch] = .pullRequestMerged(pr.number)
        }
        return result
    }

    /// `git for-each-ref --format=%(refname:short)%00%(upstream:short)%00%(upstream:track) refs/heads`
    static func parse(refs output: String) -> [Branch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard let name = fields.first, !name.isEmpty else { return nil }
            let upstream = fields.count > 1 ? fields[1] : ""
            let track = fields.count > 2 ? fields[2] : ""
            return Branch(name: name, hasUpstream: !upstream.isEmpty, upstreamGone: track == "[gone]")
        }
    }

    /// The pure decision: `reachable` is `git branch --merged <base>`;
    /// `pushed` the branches whose tip is on some remote ref. A gone upstream
    /// alone is not enough: after a squash merge you may have committed on
    /// and never pushed — Clean Up would delete those commits with the
    /// branch. Unpushed, it takes a merged pull request at that very tip
    /// (mergedByPullRequest) to count.
    static func merged(branches: [Branch], reachable: Set<String>, pushed: Set<String>, base: String, protected: Set<String>)
        -> [String: Reason]
    {
        var result: [String: Reason] = [:]
        for branch in branches where !protected.contains(branch.name) {
            if branch.upstreamGone {
                if pushed.contains(branch.name) { result[branch.name] = .upstreamGone }
            } else if branch.hasUpstream, reachable.contains(branch.name) {
                result[branch.name] = .mergedInto(base)
            }
        }
        return result
    }

    /// The default branch to compare against: the remote's HEAD
    /// (`origin/main`), else the main worktree's branch.
    static func base(in repo: URL, mainBranch: String?) async -> String? {
        let remoteHead = try? await Git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: repo)
        if let remoteHead = remoteHead?.trimmingCharacters(in: .whitespacesAndNewlines), !remoteHead.isEmpty {
            return remoteHead
        }
        return mainBranch
    }

    /// The same, finding the main worktree's branch itself.
    static func base(in repo: URL) async -> String? {
        let listed = (try? await Git.run(["worktree", "list", "--porcelain"], in: repo)).map(Worktree.parse(porcelain:)) ?? []
        return await base(in: repo, mainBranch: listed.first { $0.isMain }?.branch)
    }

    /// Merged branches among `worktrees`' (the main worktree's is never one).
    static func find(in repo: URL, worktrees: [Worktree]) async -> [String: Reason] {
        let mainBranch = worktrees.first { $0.isMain }?.branch
        guard let base = await base(in: repo, mainBranch: mainBranch) else { return [:] }
        let format = "--format=%(refname:short)%00%(upstream:short)%00%(upstream:track)"
        guard let refs = try? await Git.run(["for-each-ref", format, "refs/heads"], in: repo) else { return [:] }
        let listed = (try? await Git.run(["branch", "--format=%(refname:short)", "--merged", base], in: repo)) ?? ""
        let reachable = Set(listed.split(separator: "\n").map(String.init))
        // The base itself, and main's branch, are never "merged away".
        let shortBase = base.split(separator: "/", maxSplits: 1).last.map(String.init) ?? base
        let protected = Set([mainBranch, shortBase].compactMap { $0 })
        let inWorktrees = Set(worktrees.filter { !$0.isMain }.compactMap(\.branch))
        let pushed = await pushedBranches(in: repo)
        return merged(branches: parse(refs: refs), reachable: reachable, pushed: pushed, base: base, protected: protected)
            .filter { inWorktrees.contains($0.key) }
    }

    /// Branches whose tip is on some remote ref — so all their commits are.
    /// One `rev-list` of every local commit no remote has, not one call per
    /// branch.
    static func pushedBranches(in repo: URL) async -> Set<String> {
        guard let tips = try? await Git.run(["for-each-ref", "--format=%(refname:short)%00%(objectname)", "refs/heads"], in: repo),
            let unpushed = try? await Git.run(["rev-list", "--branches", "--not", "--remotes"], in: repo)
        else { return [] }
        let local = Set(unpushed.split(separator: "\n").map(String.init))
        var pushed: Set<String> = []
        for line in tips.split(separator: "\n") {
            let fields = line.split(separator: "\0").map(String.init)
            if fields.count == 2, !local.contains(fields[1]) { pushed.insert(fields[0]) }
        }
        return pushed
    }

    /// `git fetch --prune`, so gone upstreams and new merges show. Best
    /// effort: offline, or no remote, just leaves the local view.
    static func fetch(in repo: URL) async {
        // BatchMode: an ssh passphrase prompt nobody can see would hang it.
        _ = try? await Git.run(["-c", "core.sshCommand=ssh -o BatchMode=yes", "fetch", "--prune", "--quiet"], in: repo)
    }
}
