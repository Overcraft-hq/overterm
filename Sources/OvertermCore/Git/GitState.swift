import Foundation

/// A merge, rebase, cherry-pick or revert that stopped — on a conflict,
/// usually — and waits to be continued or aborted. Read off the files git
/// leaves in the repository's git directory while one is under way.
package enum GitInProgress: String, Equatable, Sendable {
    case merge, rebase, cherryPick, revert

    /// `gitDir`: `git rev-parse --absolute-git-dir` — a worktree's own.
    package static func read(gitDir: URL) -> GitInProgress? {
        let exists = { (name: String) in FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    package var title: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        }
    }

    package var command: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    /// No editor to wait for: the message git prepared is the one used.
    package var continueArguments: [String] { ["-c", "core.editor=true", command, "--continue"] }
    package var abortArguments: [String] { [command, "--abort"] }
}

/// The checked-out branch against its upstream: what the overview's Pull
/// and Push say. Read whatever sections are open — the Branches list is
/// often shut.
package struct BranchTracking: Equatable, Sendable {
    package var upstream: String?
    package var ahead = 0
    package var behind = 0

    package init(upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    package static let arguments = ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
    package static let countArguments = ["rev-list", "--left-right", "--count", "HEAD...@{u}"]

    /// `upstream`: rev-parse's answer (nil when there is none); `counts`:
    /// rev-list's "ahead<TAB>behind".
    package static func parse(upstream: String?, counts: String?) -> BranchTracking {
        let name = upstream?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return BranchTracking() }
        let numbers = (counts ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return BranchTracking(upstream: name, ahead: numbers.first ?? 0, behind: numbers.dropFirst().first ?? 0)
    }
}

/// What Overgit's buttons and menus ask git to do. The window runs them
/// (`TerminalWindowController.overgit(_:)`), asking first where a name is
/// needed or something is lost.
package enum OvergitCommand: Equatable {
    package enum ResetMode: String, CaseIterable { case soft, mixed, hard }

    case fetch, pull(rebase: Bool), push
    case newBranch(from: String?)
    case stash, stashStaged, popStash(Stash)
    case merge(String), rebase(onto: String)
    case pushBranch(BranchRef), renameBranch(BranchRef), deleteBranch(BranchRef)
    case checkOutCommit(String), cherryPick(Commit), revert(Commit), reset(Commit, ResetMode), tag(at: String)
    case pushTag(TagRef), deleteTag(TagRef)
    case fetchRemote(Remote)
    case continueOperation, abortOperation

    /// What the overview says while it runs.
    package var progress: String {
        switch self {
        case .fetch, .fetchRemote: "Fetching…"
        case .pull: "Pulling…"
        case .push, .pushBranch, .pushTag: "Pushing…"
        case .merge: "Merging…"
        case .rebase: "Rebasing…"
        case .cherryPick: "Cherry-picking…"
        case .revert: "Reverting…"
        default: "Working…"
        }
    }

    /// Talks to a remote: no timeout — a push of a big branch takes what it takes.
    package var isNetwork: Bool {
        switch self {
        case .fetch, .pull, .push, .pushBranch, .pushTag, .fetchRemote: true
        case .deleteBranch(let branch): branch.isRemote
        default: false
        }
    }

    /// `origin/feature/x` → (`origin`, `feature/x`), by the remotes there are.
    package static func split(remoteBranch name: String, remotes: [String]) -> (remote: String, branch: String)? {
        for remote in remotes.sorted(by: { $0.count > $1.count }) where name.hasPrefix(remote + "/") {
            return (remote, String(name.dropFirst(remote.count + 1)))
        }
        guard let slash = name.firstIndex(of: "/") else { return nil }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }
}

/// A rebase or a soft/mixed reset rewrites the branch: the commits it takes
/// off are gone from it (a reset) or made again as new ones (a rebase).
/// Done to commits a remote already has, the next push needs force and
/// everyone who has them is left with the old ones — so it asks first,
/// naming how many (GIT-U7). Commits only this checkout has go without a
/// word: that is the everyday case, and easily undone. Pure.
package enum OvergitRewrite {
    /// The commits leaving the branch: `HEAD` without `base`'s.
    package static func countArguments(base: String) -> [String] { ["rev-list", "--count", "HEAD", "^\(base)"] }
    /// Those of them no remote branch has.
    package static func unpushedArguments(base: String) -> [String] { ["rev-list", "--count", "HEAD", "^\(base)", "--not", "--remotes"] }
    /// A rebase onto an ancestor of HEAD rewrites nothing (exit 0: it is one).
    package static func ancestorArguments(_ base: String) -> [String] { ["merge-base", "--is-ancestor", base, "HEAD"] }

    /// The question, or nil when nothing pushed is touched.
    package static func question(_ command: OvergitCommand, current: String?, pushed: Int) -> (title: String, detail: String)? {
        guard pushed > 0 else { return nil }
        let branch = current ?? "HEAD"
        let commits = pushed == 1 ? "1 commit" : "\(pushed) commits"
        let them = pushed == 1 ? "it" : "them"
        switch command {
        case .rebase(let onto):
            return (
                "Rebase \(branch) onto \(onto)?",
                "\(commits) of \(branch) already on a remote will be made again as new ones. Pushing after needs --force, and anyone who has \(them) is left with the old ones."
            )
        case .reset(let commit, let mode) where mode != .hard:
            let kept = mode == .soft ? "staged" : "unstaged"
            return (
                "Reset \(branch) to \(commit.shortSHA)?",
                "\(commits) already on a remote will leave \(branch); their changes stay in the files, \(kept). Pushing after needs --force."
            )
        default:
            return nil
        }
    }
}
