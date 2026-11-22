import Foundation

/// A pull request as the worktree list and title bar show it: from one
/// `gh pr list --json …` per repository.
package struct PullRequestSummary: Equatable {
    package enum State: Equatable {
        case open, draft, merged, closed
    }

    package let number: Int
    package let title: String
    package let branch: String
    package let state: State
    package let url: URL?
    package let checks: CheckSummary
    /// The head commit — a merged PR's says which commit was merged.
    package var headOid: String? = nil

    /// `gh pr list` fields this parses.
    package static let listFields = "number,title,headRefName,headRefOid,state,isDraft,url,statusCheckRollup"

    /// Two lists as one, each pull request once (the first list's), newest first.
    package static func merged(_ first: [PullRequestSummary], _ second: [PullRequestSummary]) -> [PullRequestSummary] {
        var seen = Set<Int>()
        return (first + second).filter { seen.insert($0.number).inserted }.sorted { $0.number > $1.number }
    }

    /// The pull request to show per head branch: an open one over a
    /// merged or closed one, then the newest (gh lists newest first).
    package static func byBranch(_ list: [PullRequestSummary]) -> [String: PullRequestSummary] {
        var result: [String: PullRequestSummary] = [:]
        for pr in list {
            guard let existing = result[pr.branch] else {
                result[pr.branch] = pr
                continue
            }
            let isLive = pr.state == .open || pr.state == .draft
            let existingLive = existing.state == .open || existing.state == .draft
            if isLive, !existingLive { result[pr.branch] = pr }
        }
        return result
    }

    package static func parseList(_ data: Data) throws -> [PullRequestSummary] {
        try JSONDecoder().decode([GH.PullRequest].self, from: data).map(\.summary)
    }
}

/// Where CI stands, from a status check rollup.
package struct CheckSummary: Equatable {
    package var passed = 0
    package var failed = 0
    package var pending = 0
    package var total: Int { passed + failed + pending }

    package enum Overall { case none, passing, failing, pending }

    /// Failing as soon as one fails; pending while any runs; else passing.
    package var overall: Overall {
        if failed > 0 { return .failing }
        if pending > 0 { return .pending }
        return passed > 0 ? .passing : .none
    }

    package init(passed: Int = 0, failed: Int = 0, pending: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
    }

    package init(_ checks: [Check]) {
        for check in checks {
            switch check.state {
            case .success: passed += 1
            case .failure: failed += 1
            case .pending: pending += 1
            case .skipped: break
            }
        }
    }
}

/// One CI check: a GitHub Actions job (CheckRun) or a commit status
/// (StatusContext) — gh's rollup mixes both.
package struct Check: Equatable, Identifiable {
    package enum State: Equatable { case success, failure, pending, skipped }

    package let name: String
    package let state: State
    package let url: URL?
    package var id: String { name }
}

/// Everything the Pull Request pane shows.
package struct PullRequestDetail: Equatable {
    package let summary: PullRequestSummary
    package let body: String
    package let author: String
    package let base: String
    package let additions: Int
    package let deletions: Int
    package let changedFiles: Int
    package let checks: [Check]
    /// Comments and review summaries, oldest first.
    package let conversation: [ConversationItem]
    /// From a fork (unknown counts as one): its branch's name says nothing
    /// of this repository's branches.
    package var crossRepository = true

    package static let viewFields =
        "number,title,headRefName,headRefOid,isCrossRepository,baseRefName,state,isDraft,url,statusCheckRollup,body,author,additions,deletions,changedFiles,comments,reviews"

    package static func parse(_ data: Data) throws -> PullRequestDetail {
        let pr = try JSONDecoder().decode(GH.PullRequest.self, from: data)
        let comments = (pr.comments ?? []).map {
            ConversationItem(id: $0.id, author: $0.author?.login ?? "ghost", body: $0.body, date: GH.date($0.createdAt), kind: .comment, url: $0.url.flatMap(URL.init))
        }
        // A review with neither text nor a verdict (only inline comments)
        // is shown by its threads, not as an empty entry.
        let reviews = (pr.reviews ?? []).compactMap { review -> ConversationItem? in
            let verdict = ConversationItem.Kind.review(review.state ?? "COMMENTED")
            guard !review.body.isEmpty || review.state == "APPROVED" || review.state == "CHANGES_REQUESTED" else { return nil }
            return ConversationItem(
                id: review.id, author: review.author?.login ?? "ghost", body: review.body, date: GH.date(review.submittedAt), kind: verdict,
                url: nil)
        }
        return PullRequestDetail(
            summary: pr.summary, body: pr.body ?? "", author: pr.author?.login ?? "ghost", base: pr.baseRefName ?? "",
            additions: pr.additions ?? 0, deletions: pr.deletions ?? 0, changedFiles: pr.changedFiles ?? 0,
            checks: (pr.statusCheckRollup ?? []).map(\.check),
            conversation: (comments + reviews).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) },
            crossRepository: pr.isCrossRepository ?? true)
    }
}

package struct ConversationItem: Equatable, Identifiable {
    package enum Kind: Equatable {
        case comment
        /// APPROVED, CHANGES_REQUESTED, COMMENTED, …
        case review(String)
    }

    package let id: String
    package let author: String
    package let body: String
    package let date: Date?
    package let kind: Kind
    package let url: URL?
}

/// Inline review comments on one line of one file: a root and its replies.
package struct ReviewThread: Equatable, Identifiable {
    package struct Comment: Equatable, Identifiable {
        package let id: Int
        package let author: String
        package let body: String
        package let date: Date?
    }

    /// The root comment's id — what a reply goes to.
    package let id: Int
    package let path: String
    /// Nil when the line is no longer in the diff (outdated).
    package let line: Int?
    /// The last lines of the diff hunk the thread is on.
    package let context: [String]
    package let comments: [Comment]
    package let url: URL?

    /// `gh api repos/{owner}/{repo}/pulls/N/comments --paginate` → threads,
    /// by file then line. Pages come back as concatenated arrays.
    package static func parse(_ data: Data) throws -> [ReviewThread] {
        let comments = try GH.decodePages([GH.ReviewComment].self, from: data).flatMap { $0 }
        var threads: [Int: [GH.ReviewComment]] = [:]
        var order: [Int] = []
        for comment in comments {
            let root = comment.in_reply_to_id ?? comment.id
            if threads[root] == nil { order.append(root) }
            threads[root, default: []].append(comment)
        }
        return order.compactMap { rootID -> ReviewThread? in
            guard let all = threads[rootID], let root = all.first(where: { $0.id == rootID }) ?? all.first else { return nil }
            let hunk = (root.diff_hunk ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return ReviewThread(
                id: rootID, path: root.path ?? "", line: root.line, context: Array(hunk.suffix(4)),
                comments: all.map { Comment(id: $0.id, author: $0.user?.login ?? "ghost", body: $0.body, date: GH.date($0.created_at)) },
                url: root.html_url.flatMap(URL.init))
        }
        .sorted { ($0.path, $0.line ?? 0) < ($1.path, $1.line ?? 0) }
    }
}

/// gh's JSON, as decoded. Only what Overterm reads.
package enum GH {
    package struct Login: Decodable { package let login: String }

    package struct RollupItem: Decodable {
        // CheckRun
        package let name: String?
        package let status: String?
        package let conclusion: String?
        package let detailsUrl: String?
        // StatusContext
        package let context: String?
        package let state: String?
        package let targetUrl: String?

        package var check: Check {
            let state: Check.State
            if let conclusion, !conclusion.isEmpty {
                switch conclusion {
                case "SUCCESS": state = .success
                case "SKIPPED", "NEUTRAL": state = .skipped
                default: state = .failure  // FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE, STALE
                }
            } else if let status, status != "COMPLETED" {
                state = .pending  // QUEUED, IN_PROGRESS, WAITING, PENDING
            } else {
                switch self.state {
                case "SUCCESS": state = .success
                case "PENDING", "EXPECTED": state = .pending
                case nil: state = .pending
                default: state = .failure  // FAILURE, ERROR
                }
            }
            return Check(name: name ?? context ?? "check", state: state, url: (detailsUrl ?? targetUrl).flatMap(URL.init))
        }
    }

    package struct Comment: Decodable {
        package let id: String
        package let author: Login?
        package let body: String
        package let createdAt: String?
        package let url: String?
    }

    package struct Review: Decodable {
        package let id: String
        package let author: Login?
        package let body: String
        package let state: String?
        package let submittedAt: String?
    }

    package struct PullRequest: Decodable {
        package let number: Int
        package let title: String
        package let headRefName: String
        package let headRefOid: String?
        package let isCrossRepository: Bool?
        package let state: String
        package let isDraft: Bool?
        package let url: String?
        package let statusCheckRollup: [RollupItem]?
        package let baseRefName: String?
        package let body: String?
        package let author: Login?
        package let additions: Int?
        package let deletions: Int?
        package let changedFiles: Int?
        package let comments: [Comment]?
        package let reviews: [Review]?

        package var summary: PullRequestSummary {
            let prState: PullRequestSummary.State =
                switch state {
                case "MERGED": .merged
                case "CLOSED": .closed
                default: isDraft == true ? .draft : .open
                }
            return PullRequestSummary(
                number: number, title: title, branch: headRefName, state: prState, url: url.flatMap(URL.init),
                checks: CheckSummary((statusCheckRollup ?? []).map(\.check)), headOid: headRefOid)
        }
    }

    package struct ReviewComment: Decodable {
        package let id: Int
        package let in_reply_to_id: Int?
        package let path: String?
        package let line: Int?
        package let body: String
        package let user: Login?
        package let created_at: String?
        package let html_url: String?
        package let diff_hunk: String?
    }

    /// `--paginate` prints one JSON array per page, back to back.
    package static func decodePages<T: Decodable>(_ type: T.Type, from data: Data) throws -> [T] {
        var pages: [T] = []
        var rest = data[...]
        while let start = rest.firstIndex(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) {
            rest = rest[start...]
            let end = try endOfValue(in: rest)
            pages.append(try JSONDecoder().decode(T.self, from: Data(rest[rest.startIndex..<end])))
            rest = rest[end...]
        }
        return pages
    }

    /// Where the JSON value starting at `data`'s start ends (strings and
    /// escapes respected).
    private static func endOfValue(in data: Data.SubSequence) throws -> Data.Index {
        var depth = 0
        var inString = false
        var escaped = false
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                switch byte {
                case 0x22: inString = true
                case 0x5B, 0x7B: depth += 1
                case 0x5D, 0x7D:
                    depth -= 1
                    if depth == 0 { return data.index(after: index) }
                default: break
                }
            }
            index = data.index(after: index)
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unterminated JSON"))
    }

    package static func date(_ string: String?) -> Date? {
        string.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
