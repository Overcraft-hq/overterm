import Foundation

/// Which side of a diff a line counts on, as GitHub says it.
package enum ReviewSide: String, Equatable, Sendable {
    /// The old file's: a removed line.
    case left = "LEFT"
    /// The new file's: an added or unchanged line.
    case right = "RIGHT"
}

/// A comment on picked lines of a pull request, kept until it goes with a
/// review (GIT-G3): where GitHub anchors it, and what it says.
package struct ReviewDraftComment: Identifiable, Equatable {
    package let id: UUID
    package let path: String
    /// The first line, when it covers more than one.
    package let startLine: Int?
    package let startSide: ReviewSide?
    package let line: Int
    package let side: ReviewSide
    package var body: String

    package init(id: UUID = UUID(), path: String, anchor: ReviewComments.Anchor, body: String) {
        self.id = id
        self.path = path
        startLine = anchor.startLine
        startSide = anchor.startSide
        line = anchor.line
        side = anchor.side
        self.body = body
    }

    /// "line 40", "lines 40–52", "removed line 12".
    package var span: String {
        let removed = side == .left && (startSide ?? side) == .left ? "removed " : ""
        guard let startLine, startLine != line || startSide != side else { return "\(removed)line \(line)" }
        return "\(removed)lines \(startLine)–\(line)"
    }
}

/// A pull request's review, written in the review tab (GIT-G3): where a
/// pick of lines lands on GitHub, the threads at their lines, and the one
/// request that posts the comments with a decision. Pure.
package enum ReviewComments {
    /// What a review is sent as.
    package enum Event: String, CaseIterable, Equatable, Sendable {
        case comment = "COMMENT"
        case approve = "APPROVE"
        case requestChanges = "REQUEST_CHANGES"

        package var title: String {
            switch self {
            case .comment: "Comment"
            case .approve: "Approve"
            case .requestChanges: "Request Changes"
            }
        }
    }

    /// Where GitHub puts a comment: its last line and side, and the first
    /// when it covers more than one.
    package struct Anchor: Equatable {
        package var startLine: Int?
        package var startSide: ReviewSide?
        package var line: Int
        package var side: ReviewSide
    }

    /// Where `picked` (a run of the diff, as the review picks it) lands on
    /// GitHub — or why it can't: a comment stays inside one hunk, on lines
    /// the diff shows.
    package static func anchor(_ picked: [DiffLine]) -> Result<Anchor, Refusal> {
        let lines = picked.drop { $0.kind == .hunk || $0.kind == .meta }
        guard !lines.contains(where: { $0.kind == .hunk || $0.kind == .meta }) else {
            return .failure(Refusal(message: "A comment on GitHub stays within one change: pick lines between two @@ headers."))
        }
        func place(_ line: DiffLine) -> (Int, ReviewSide)? {
            if let new = line.newNumber { return (new, .right) }
            if let old = line.oldNumber { return (old, .left) }
            return nil
        }
        guard let first = lines.first.flatMap(place), let last = lines.last.flatMap(place) else {
            return .failure(Refusal(message: "No line of the diff is picked."))
        }
        if first == last { return .success(Anchor(startLine: nil, startSide: nil, line: last.0, side: last.1)) }
        return .success(Anchor(startLine: first.0, startSide: first.1, line: last.0, side: last.1))
    }

    package struct Refusal: Error, Equatable {
        package let message: String
    }

    /// The threads of `path` by the diff line each is drawn under: its line
    /// on its side; an outdated one (no line) under none.
    package static func placed(_ threads: [ReviewThread], path: String, lines: [DiffLine]) -> [Int: [ReviewThread]] {
        var placed: [Int: [ReviewThread]] = [:]
        for thread in threads where thread.path == path {
            guard let number = thread.line,
                let line = lines.first(where: { thread.side == .left ? $0.oldNumber == number && $0.kind == .removed : $0.newNumber == number })
            else { continue }
            placed[line.id, default: []].append(thread)
        }
        return placed
    }

    /// `POST repos/{owner}/{repo}/pulls/N/reviews`' body: the decision, its
    /// text, every comment where it is anchored, at `commit` when known.
    package static func request(_ comments: [ReviewDraftComment], event: Event, body: String, commit: String?) -> Data {
        var object: [String: Any] = [
            "event": event.rawValue,
            "comments": comments.map { comment -> [String: Any] in
                var item: [String: Any] = ["path": comment.path, "line": comment.line, "side": comment.side.rawValue, "body": comment.body]
                if let start = comment.startLine, let side = comment.startSide {
                    item["start_line"] = start
                    item["start_side"] = side.rawValue
                }
                return item
            },
        ]
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { object["body"] = text }
        if let commit, !commit.isEmpty { object["commit_id"] = commit }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// What Submit Review asks (D-9: every write asked): what goes, with
    /// which decision, on which pull request.
    package static func question(number: Int, title: String, comments: [ReviewDraftComment], event: Event) -> (title: String, detail: String) {
        let count = comments.count == 1 ? "1 comment" : "\(comments.count) comments"
        let verb: String =
            switch event {
            case .comment: "Comment on"
            case .approve: "Approve"
            case .requestChanges: "Request changes on"
            }
        var lines = comments.prefix(20).map { "• \($0.path), \($0.span): \($0.body.split(separator: "\n").first.map(String.init) ?? "")" }
        if comments.count > 20 { lines.append("… and \(comments.count - 20) more") }
        return (
            "\(verb) #\(number) \(title), with \(count)?",
            (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n")
                + "Posted on GitHub as you, all at once, as one review — the others on the pull request are notified."
        )
    }
}
