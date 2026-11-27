import AppKit

/// A pull request's review written in the review tab (GIT-G3): the comments
/// kept on picked lines go to GitHub with a decision — Comment, Approve or
/// Request Changes — as one review, asked first (D-9), through `gh api`.
extension TerminalWindowController {
    /// Submit Review…: the decision and a summary asked, then posted.
    package func submitReview(_ review: ReviewModel) {
        guard let number = review.pullRequestNumber, !review.drafts.isEmpty else { return NSSound.beep() }
        let comments = review.drafts
        let title = review.pullRequest?.summary.title ?? review.title
        Task { @MainActor [weak self] in
            guard let self else { return }
            let decided: (ReviewComments.Event, String)?
            if let recorder = self.reviewSubmitRecorder {
                decided = recorder(comments)
            } else {
                decided = await self.askReviewDecision(number: number, title: title, comments: comments)
            }
            guard let (event, body) = decided else { return }
            let request = ReviewComments.request(comments, event: event, body: body, commit: review.pullRequest?.summary.headOid)
            if let problem = await Self.postReview(request, number: number, in: review.root) {
                return self.alert("The review wasn't posted", problem)
            }
            review.clearDraftComments()
            await review.loadThreads()
        }
    }

    /// `POST …/pulls/N/reviews` with the request as a file of its own
    /// (0600, removed after): nil when posted, else gh's words.
    package static func postReview(_ request: Data, number: Int, in root: URL) async -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-review-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: request, attributes: [.posixPermissions: 0o600]) else {
            return "Couldn't write the review's request."
        }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await GitHub.run(
                ["api", "--method", "POST", "repos/{owner}/{repo}/pulls/\(number)/reviews", "--input", file.path], in: root, timeout: 60)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The question: what goes, the decision, a summary; nil when cancelled.
    private func askReviewDecision(number: Int, title: String, comments: [ReviewDraftComment]) async -> (ReviewComments.Event, String)? {
        let asked = ReviewComments.question(number: number, title: title, comments: comments, event: .comment)
        let alert = NSAlert()
        alert.messageText = "Submit your review of #\(number) \(title)?"
        alert.informativeText = asked.detail
        alert.addButton(withTitle: "Submit Review")
        alert.addButton(withTitle: "Cancel")
        let decision = NSPopUpButton(frame: NSRect(x: 0, y: 34, width: 320, height: 26), pullsDown: false)
        decision.addItems(withTitles: ReviewComments.Event.allCases.map(\.title))
        let summary = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        summary.placeholderString = "A summary for the review (optional)"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 62))
        accessory.addSubview(decision)
        accessory.addSubview(summary)
        alert.accessoryView = accessory
        guard let window else { return nil }
        let response = await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard response == .alertFirstButtonReturn else { return nil }
        let event = ReviewComments.Event.allCases[max(0, decision.indexOfSelectedItem)]
        return (event, summary.stringValue)
    }
}
