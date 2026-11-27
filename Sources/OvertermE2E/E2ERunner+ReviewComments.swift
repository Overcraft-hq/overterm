#if E2E
import AppKit

/// GIT-G3 (Overcraft-hq/issue-tracker#17): a pull request's threads at
/// their lines in its review, and comments on picked lines posted with a
/// decision as one review — asked first, nothing posted when cancelled.
extension E2ERunner {
    /// On `pr`, the stand-in gh's #9; what it posts lands in `posted`.
    func reviewCommentsChecks(_ pr: ReviewModel, posted: URL) async {
        try? FileManager.default.removeItem(at: posted)
        check("the pull request's threads are read with it", await eventually(5) { pr.threads.map(\.id) == [71] }, "\(pr.threads.map(\.id))")
        pr.select("server.go")
        _ = await eventually(5) { pr.diffs["server.go"] != nil }
        guard let fast = pr.diffs["server.go"]?.lines.first(where: { $0.text == "func fast() {}" }) else {
            return check("server.go's diff has the changed line", false)
        }
        check("the thread is drawn under its line", pr.placedThreads["server.go"]?[fast.id]?.map(\.id) == [71], "\(pr.placedThreads)")

        // A comment on the picked line, kept for the review.
        pr.pickLine(fast.id, extending: false)
        pr.draft = "Name it for what it does."
        check("a comment on the picked line is kept for the review", pr.addDraftComment() && pr.drafts.count == 1)
        let kept = pr.drafts.first
        check("anchored on the new side, line 2", kept?.line == 2 && kept?.side == .right && kept?.startLine == nil, "\(String(describing: kept))")

        // Cancelled: nothing posted, the comment kept.
        app.reviewSubmitRecorder = { _ in nil }
        app.submitReview(pr)
        await pause(0.5)
        check("cancelled, nothing is posted", !FileManager.default.fileExists(atPath: posted.path) && pr.drafts.count == 1)

        // Request Changes, with a summary: one request with the comment in it.
        var asked: [ReviewDraftComment] = []
        app.reviewSubmitRecorder = { comments in
            asked = comments
            return (.requestChanges, "One thing before merging.")
        }
        defer { app.reviewSubmitRecorder = nil }
        app.submitReview(pr)
        check("asked with the comments it posts", await eventually(5) { asked.count == 1 })
        check("posted as one review", await eventually(8) { FileManager.default.fileExists(atPath: posted.path) })
        let sent = (try? Data(contentsOf: posted)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let comments = sent?["comments"] as? [[String: Any]]
        check(
            "its decision, summary and comment, where it was put",
            sent?["event"] as? String == "REQUEST_CHANGES" && sent?["body"] as? String == "One thing before merging."
                && comments?.count == 1 && comments?.first?["path"] as? String == "server.go" && comments?.first?["line"] as? Int == 2
                && comments?.first?["side"] as? String == "RIGHT" && comments?.first?["body"] as? String == "Name it for what it does.",
            "\(sent ?? [:])")
        check("posted, the kept comments are GitHub's now", await eventually(3) { pr.drafts.isEmpty })
        try? FileManager.default.removeItem(at: posted)
    }
}
#endif
