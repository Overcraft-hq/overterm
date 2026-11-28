import Foundation

/// A git command's failure as a person reads it (GIT-U6): the common ones
/// recognised in git's own words and said plainly, each with the next step
/// that fits it — never git's text alone in a window. Pure.
package enum GitFailure: Equatable, Sendable {
    /// A push refused: the remote has commits this branch doesn't.
    case remoteAhead
    /// A force push with a lease refused: someone pushed since this checkout last fetched.
    case leaseStale
    /// A pull that can't fast-forward and was given no way to reconcile.
    case diverged
    /// No upstream to pull from or push to.
    case noUpstream
    /// The remote refused who we are: a token, a key, a sign-in.
    case authentication
    /// A hook said no: its name, as git said it.
    case hook(String)
    /// Local changes a pull, a switch or a merge would overwrite.
    case localChanges
    /// Anything else: git's own words are all there is.
    case other

    /// What git's stderr says it was. Case-insensitive; the first that
    /// matches wins, the most specific first.
    package static func read(_ stderr: String) -> GitFailure {
        let text = stderr.lowercased()
        func has(_ any: String...) -> Bool { any.contains { text.contains($0) } }
        if has("hook declined", "pre-push hook", "pre-receive hook declined", "pre-commit hook", "commit-msg hook") {
            return .hook(hookName(in: stderr) ?? "a hook")
        }
        if has(
            "authentication failed", "permission denied (publickey", "could not read username", "terminal prompts disabled",
            "the requested url returned error: 403", "invalid username or password", "repository not found", "could not read from remote repository")
        {
            return .authentication
        }
        if has("(stale info)") { return .leaseStale }
        if has("updates were rejected because the remote contains work", "(fetch first)", "non-fast-forward", "updates were rejected because the tip of your current branch is behind") {
            return .remoteAhead
        }
        if has("need to specify how to reconcile divergent branches", "not possible to fast-forward", "have diverged") { return .diverged }
        if has("has no upstream branch", "there is no tracking information for the current branch") { return .noUpstream }
        if has("would be overwritten by", "please commit your changes or stash them") { return .localChanges }
        return .other
    }

    /// `pre-push`, `pre-receive`… as git wrote it, if it did.
    private static func hookName(in stderr: String) -> String? {
        for name in ["pre-push", "pre-receive", "pre-commit", "commit-msg", "update", "post-receive"]
        where stderr.range(of: "\(name) hook", options: .caseInsensitive) != nil {
            return name
        }
        return nil
    }

    /// The sentence said in its place: what happened, in plain words.
    package func sentence(branch: String?) -> String {
        let name = branch.map { "\($0)" } ?? "This branch"
        switch self {
        case .remoteAhead:
            return "\(name) on the remote has commits that aren't here: pull them first, then push — or replace the remote's with yours."
        case .leaseStale:
            return "Someone pushed to \(name) since this checkout last fetched it: nothing was replaced. Fetch, look at what they pushed, then decide."
        case .diverged:
            return "\(name) and its upstream have each moved on: merge theirs into yours, or replay yours on top of theirs (rebase)."
        case .noUpstream:
            return "\(name) tracks no branch on a remote yet: publish it to set one."
        case .authentication:
            return "The remote refused the credentials: sign in again (gh auth login), or check the SSH key or token git uses for it."
        case .hook(let hook):
            return "The \(hook) hook stopped it: what it said is below. Fix that, or run it again once the hook passes."
        case .localChanges:
            return "Uncommitted changes would be overwritten: commit or stash them first."
        case .other:
            return "git said:"
        }
    }

    /// What can be done next, from the failure's window, in order.
    package enum Next: Equatable, Sendable {
        case pullThenPush
        case pullRebaseThenPush
        /// `push --force-with-lease`: always asked, naming the branch.
        case forcePushWithLease
        case pullRebase
        case pullMerge
        case publish
        case stash

        package var title: String {
            switch self {
            case .pullThenPush: "Pull then Push"
            case .pullRebaseThenPush: "Pull with Rebase then Push"
            case .forcePushWithLease: "Force Push with Lease…"
            case .pullRebase: "Pull with Rebase"
            case .pullMerge: "Pull with Merge"
            case .publish: "Publish"
            case .stash: "Stash Changes…"
            }
        }
    }

    /// The next steps a failure of a `push` or a `pull` offers. A force
    /// push is never offered on the default branch, nor on a detached HEAD.
    package func next(pushing: Bool, branch: String?, isDefault: Bool) -> [Next] {
        switch self {
        case .remoteAhead where pushing:
            var steps: [Next] = [.pullThenPush, .pullRebaseThenPush]
            if branch != nil, !isDefault { steps.append(.forcePushWithLease) }
            return steps
        case .diverged: return [.pullRebase, .pullMerge]
        case .noUpstream: return branch == nil ? [] : [.publish]
        case .localChanges: return [.stash]
        default: return []
        }
    }

    /// git's own words, the end of them, bounded: what is said under the sentence.
    package static func excerpt(_ stderr: String, lines: Int = 8, characters: Int = 900) -> String {
        let kept = stderr.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
        return kept.count > characters ? "…" + String(kept.suffix(characters)) : kept
    }

    /// What a force push with a lease runs: the lease on the remote's branch as this checkout last saw it.
    package static func forcePushArguments(remote: String, branch: String, target: String) -> [String] {
        ["push", "--force-with-lease=\(target):refs/remotes/\(remote)/\(target)", remote, "\(branch):\(target)"]
    }

    /// A branch name a force push may never take without a second look: the
    /// default branch by name when nothing better is known.
    package static func isDefault(_ branch: String?, defaultBranch: String?) -> Bool {
        guard let branch else { return false }
        if let defaultBranch {
            let short = defaultBranch.split(separator: "/").last.map(String.init) ?? defaultBranch
            return branch == defaultBranch || branch == short
        }
        return ["main", "master", "trunk", "develop"].contains(branch)
    }
}
