import Foundation

/// What the cluster wrote, made safe for git (docs/design/kubernetes/
/// gitops.md, 5.4): a revision only when it is SHA-shaped, then verified
/// as a commit (`rev-parse --verify --end-of-options <sha>^{commit}`), a
/// 12-character prefix only when it names exactly one; a ref refused when
/// it starts with `-`, holds `..`, `@{`, a NUL or whitespace, or breaks
/// `git check-ref-format`'s rules, and used as `refs/remotes/<remote>/<ref>`
/// after `--end-of-options`; pathspecs literal (`--literal-pathspecs`:
/// `:(top)`, `:!`, `:(attr:…)` and `:/` are plain names), after `--`, each
/// through `KubeGitOpsPath`. Every call here goes through `Git.run`;
/// nothing fetches.
enum KubeGitOpsGitArgs {
    /// Git's global option that makes every pathspec a plain name.
    static let literal = "--literal-pathspecs"

    /// A revision git may be given: SHA-shaped (7–40 hex digits), lowercased; else nil.
    static func revision(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard KubeDeployedCommit.isSHAShaped(text) else { return nil }
        return text.lowercased()
    }

    /// A ref (a branch or a tag the cluster names) git may be given; nil when refused.
    static func ref(_ text: String) -> String? {
        guard !text.isEmpty, !text.hasPrefix("-"), !text.contains(".."), !text.contains("@{"), text != "@" else { return nil }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return nil }
        // git check-ref-format's rules.
        guard !text.contains(where: { "~^:?*[\\".contains($0) }), !text.hasPrefix("/"), !text.hasSuffix("/"), !text.hasSuffix("."),
            !text.contains("//"), !text.hasSuffix(".lock")
        else { return nil }
        for component in text.split(separator: "/") where component.hasPrefix(".") || component.hasPrefix("-") || component.hasSuffix(".lock") {
            return nil
        }
        return text
    }

    /// `refs/remotes/<remote>/<ref>`, both checked; nil when either is refused.
    static func remoteRef(remote: String, _ ref: String) -> String? {
        guard let remote = Self.ref(remote), !remote.contains("/"), let ref = Self.ref(ref) else { return nil }
        return "refs/remotes/\(remote)/\(ref)"
    }

    /// The pathspecs of what is in the checkout: `.` for its root.
    static func pathspecs(_ resolved: [KubeGitOpsPath.Resolved]) -> [String] {
        var seen: Set<String> = []
        return resolved.compactMap(\.relative).map { $0.isEmpty ? "." : $0 }.filter { seen.insert($0).inserted }
    }

    /// `git --literal-pathspecs rev-parse --verify --end-of-options <sha>^{commit}`
    /// (not `--quiet`: an ambiguous prefix is told from a missing one by what git says).
    static func verifyArguments(_ sha: String) -> [String]? {
        guard let sha = revision(sha) else { return nil }
        return [literal, "rev-parse", "--verify", "--end-of-options", "\(sha)^{commit}"]
    }

    /// `git --literal-pathspecs rev-list --count <from>..<to> -- <paths>`:
    /// both revisions verified SHAs, or a checked `refs/remotes/…`.
    static func countArguments(from: String, to: String, pathspecs: [String]) -> [String]? {
        guard let from = revision(from) else { return nil }
        let to = revision(to) ?? (to.hasPrefix("refs/remotes/") ? ref(to) : nil)
        guard let to, !pathspecs.isEmpty else { return nil }
        return [literal, "rev-list", "--count", "--end-of-options", "\(from)..\(to)", "--"] + pathspecs
    }

    /// `git --literal-pathspecs diff --name-only <base>...HEAD -- <paths>`.
    static func changedArguments(base: String, pathspecs: [String]) -> [String]? {
        guard let base = revision(base), !pathspecs.isEmpty else { return nil }
        return [literal, "diff", "--name-only", "--end-of-options", "\(base)...HEAD", "--"] + pathspecs
    }

    enum Commit: Equatable, Sendable {
        /// The one commit it names, whole.
        case commit(String)
        /// A prefix several objects share.
        case ambiguous
        /// Not a commit in this checkout (not fetched, or not a commit).
        case missing
        /// Not SHA-shaped: never handed to git.
        case refused
    }

    /// `sha` as this checkout knows it: verified to be one commit.
    static func resolve(_ sha: String, in checkout: URL) async -> Commit {
        guard let arguments = verifyArguments(sha) else { return .refused }
        do {
            let full = try await Git.run(arguments, in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)
            return full.count == 40 ? .commit(full) : .missing
        } catch let error as GitError {
            return failure(error.stderr)
        } catch {
            return .missing
        }
    }

    /// What git's refusal says: several commits under one prefix (git
    /// won't pick, and neither does this), else none.
    static func failure(_ stderr: String) -> Commit {
        stderr.contains("is ambiguous") ? .ambiguous : .missing
    }
}
