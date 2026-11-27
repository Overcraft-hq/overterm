import Foundation

/// What Overterm writes on a pull request for the person (D-9 (c), P06),
/// each one asked first, naming the repository and the pull request: the
/// `gh` line it runs, and the question's words. Never an agent's: no MCP
/// tool reaches these. Pure.
package enum PullRequestWrite: Equatable, Sendable {
    case create(title: String, body: String, base: String, head: String, draft: Bool)
    /// A draft marked ready for review.
    case ready(number: Int)
    case approve(number: Int, body: String)
    /// A body is required: GitHub refuses a request for changes without one.
    case requestChanges(number: Int, body: String)
    /// Merged only if its head is still `head`: a push since the pane read
    /// it isn't merged unseen (`--match-head-commit`).
    case merge(number: Int, method: MergeMethod, head: String?)
    /// A workflow run's failed jobs run again.
    case rerunFailed(run: Int)

    package enum MergeMethod: String, CaseIterable, Sendable, Identifiable {
        case merge, squash, rebase
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .merge: "Create a Merge Commit"
            case .squash: "Squash and Merge"
            case .rebase: "Rebase and Merge"
            }
        }
    }

    /// `gh`'s words. Every value a word of its own: nothing goes through a shell.
    package var arguments: [String] {
        switch self {
        case .create(let title, let body, let base, let head, let draft):
            ["pr", "create", "--title", title, "--body", body, "--base", base, "--head", head] + (draft ? ["--draft"] : [])
        case .ready(let number):
            ["pr", "ready", "\(number)"]
        case .approve(let number, let body):
            ["pr", "review", "\(number)", "--approve"] + (body.isEmpty ? [] : ["--body", body])
        case .requestChanges(let number, let body):
            ["pr", "review", "\(number)", "--request-changes", "--body", body]
        case .merge(let number, let method, let head):
            ["pr", "merge", "\(number)", "--\(method.rawValue)"] + (head.map { ["--match-head-commit", $0] } ?? [])
        case .rerunFailed(let run):
            ["run", "rerun", "\(run)", "--failed"]
        }
    }

    /// Why it can't be sent as it is, or nil.
    package var problem: String? {
        switch self {
        case .create(let title, _, let base, let head, _):
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A title, please." }
            if base.trimmingCharacters(in: .whitespaces).isEmpty { return "A base branch, please." }
            if base == head { return "The base is the branch itself." }
            return nil
        case .requestChanges(_, let body):
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say what should change: GitHub asks for it." : nil
        default:
            return nil
        }
    }

    /// The question: its title, the line naming where it lands, what it
    /// does, its button. `repository`: `acme/shop`, as the remote names it.
    package func question(repository: String) -> (title: String, scope: String, detail: String, button: String) {
        switch self {
        case .create(let title, _, let base, let head, let draft):
            return (
                draft ? "Open a draft pull request?" : "Open a pull request?", "\(repository) · \(head) → \(base)",
                "“\(title)”, opened on GitHub in your name\(draft ? " as a draft" : "").", draft ? "Open Draft" : "Open Pull Request"
            )
        case .ready(let number):
            return ("Mark #\(number) ready for review?", "\(repository) · #\(number)", "Its reviewers are asked for a review.", "Mark Ready")
        case .approve(let number, _):
            return ("Approve #\(number)?", "\(repository) · #\(number)", "An approving review, in your name.", "Approve")
        case .requestChanges(let number, _):
            return ("Request changes on #\(number)?", "\(repository) · #\(number)", "A review asking for changes, in your name.", "Request Changes")
        case .merge(let number, let method, _):
            return (
                "Merge #\(number)?", "\(repository) · #\(number)",
                "\(method.title), on GitHub — not undone from here. Only if its head is still the one shown.", "Merge"
            )
        case .rerunFailed(let run):
            return ("Run the failed jobs again?", "\(repository) · run \(run)", "Its failed jobs run again on GitHub Actions.", "Re-run Failed Jobs")
        }
    }

    /// Whether its sheet is the critical one, Return on Cancel (D-1): a
    /// merge, not undone here.
    package var destroys: Bool { if case .merge = self { true } else { false } }
}

/// A new pull request's title and body from its commits, as `gh pr create
/// --fill` makes them: one commit, its subject and body; more, the
/// branch's name and the subjects listed, oldest first. Pure.
package enum PullRequestDraft {
    package struct Commit: Equatable, Sendable {
        package var subject: String
        package var body: String
        package init(subject: String, body: String = "") {
            self.subject = subject
            self.body = body
        }
    }

    /// `commits` newest first, as `git log` gives them.
    package static func fill(commits: [Commit], branch: String) -> (title: String, body: String) {
        let oldestFirst = commits.reversed()
        if commits.count == 1, let only = commits.first {
            return (only.subject, only.body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let body = oldestFirst.map { "- \($0.subject)" }.joined(separator: "\n")
        return (title(branch: branch), body)
    }

    /// `feat/kupon-kodu` → `Kupon kodu`: the last part, its dashes spaces.
    package static func title(branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// `git log --format=%s%x1f%b%x1e`'s records.
    package static func commits(log: String) -> [Commit] {
        log.split(separator: "\u{1e}").compactMap { record in
            let parts = record.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            let subject = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !subject.isEmpty else { return nil }
            return Commit(subject: subject, body: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
    }

    /// The new pull request's number, from the URL `gh pr create` prints.
    package static func number(created output: String) -> Int? {
        for line in output.split(separator: "\n").reversed() {
            guard let range = line.range(of: "/pull/") else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            if let number = Int(digits) { return number }
        }
        return nil
    }
}
