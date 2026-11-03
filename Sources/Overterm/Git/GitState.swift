import Foundation

/// A merge, rebase, cherry-pick or revert that stopped — on a conflict,
/// usually — and waits to be continued or aborted. Read off the files git
/// leaves in the repository's git directory while one is under way.
enum GitInProgress: String, Equatable, Sendable {
    case merge, rebase, cherryPick, revert

    /// `gitDir`: `git rev-parse --absolute-git-dir` — a worktree's own.
    static func read(gitDir: URL) -> GitInProgress? {
        let exists = { (name: String) in FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    var title: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-picking"
        case .revert: "Reverting"
        }
    }

    var command: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }

    /// No editor to wait for: the message git prepared is the one used.
    var continueArguments: [String] { ["-c", "core.editor=true", command, "--continue"] }
    var abortArguments: [String] { [command, "--abort"] }
}

/// The checked-out branch against its upstream: what the overview's Pull
/// and Push say. Read whatever sections are open — the Branches list is
/// often shut.
struct BranchTracking: Equatable, Sendable {
    var upstream: String?
    var ahead = 0
    var behind = 0

    static let arguments = ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
    static let countArguments = ["rev-list", "--left-right", "--count", "HEAD...@{u}"]

    /// `upstream`: rev-parse's answer (nil when there is none); `counts`:
    /// rev-list's "ahead<TAB>behind".
    static func parse(upstream: String?, counts: String?) -> BranchTracking {
        let name = upstream?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return BranchTracking() }
        let numbers = (counts ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return BranchTracking(upstream: name, ahead: numbers.first ?? 0, behind: numbers.dropFirst().first ?? 0)
    }
}

/// What Overgit's buttons and menus ask git to do. The window runs them
/// (`TerminalWindowController.overgit(_:)`), asking first where a name is
/// needed or something is lost.
enum OvergitCommand: Equatable {
    enum ResetMode: String, CaseIterable { case soft, mixed, hard }

    case fetch, pull(rebase: Bool), push
    case newBranch(from: String?)
    case stash, popStash(Stash)
    case merge(String), rebase(onto: String)
    case pushBranch(BranchRef), renameBranch(BranchRef), deleteBranch(BranchRef)
    case checkOutCommit(String), cherryPick(Commit), revert(Commit), reset(Commit, ResetMode), tag(at: String)
    case pushTag(TagRef), deleteTag(TagRef)
    case fetchRemote(Remote)
    case continueOperation, abortOperation

    /// What the overview says while it runs.
    var progress: String {
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
    var isNetwork: Bool {
        switch self {
        case .fetch, .pull, .push, .pushBranch, .pushTag, .fetchRemote: true
        case .deleteBranch(let branch): branch.isRemote
        default: false
        }
    }

    /// `origin/feature/x` → (`origin`, `feature/x`), by the remotes there are.
    static func split(remoteBranch name: String, remotes: [String]) -> (remote: String, branch: String)? {
        for remote in remotes.sorted(by: { $0.count > $1.count }) where name.hasPrefix(remote + "/") {
            return (remote, String(name.dropFirst(remote.count + 1)))
        }
        guard let slash = name.firstIndex(of: "/") else { return nil }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }
}
