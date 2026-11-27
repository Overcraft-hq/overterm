import AppKit

/// A review's findings to the checkout's agent (P07, GIT-N2): the notes
/// written on picked lines as one brief, the picked lines to Ask Agent's
/// sheet (⌘L), a pull request's thread (Address This Thread). Typed in,
/// never sent — Return is the person's — and never into a tab at a
/// Terraform ask (`type(_:intoAgent:)`).
extension TerminalWindowController {
    /// The agent tabs working in `root`'s checkout, the selected one first,
    /// none at a Terraform ask.
    package func checkoutAgents(in root: URL) -> [Tab] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        func inside(_ path: String?) -> Bool {
            guard let path else { return false }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        let agents = store.tabs.filter { tab in
            tab.agent != nil && !terraformAsking(tab) && (inside(tab.workingDirectory) || tab.terminals.contains { inside($0.workingDirectory) })
        }
        let selected = store.selected?.id
        return agents.filter { $0.id == selected } + agents.filter { $0.id != selected }
    }

    /// Who Send names: the agent when the checkout has one tab of them.
    package func reviewNoteRecipient(_ review: ReviewModel) -> String? {
        let agents = checkoutAgents(in: review.root)
        guard agents.count == 1, let agent = agents.first?.agent else { return nil }
        return agent.name
    }

    /// Send: one agent tab in the checkout gets the brief typed in, and the
    /// notes are done with; otherwise Ask Agent's sheet, to pick one or a
    /// new tab there.
    package func sendReviewNotes(_ review: ReviewModel) {
        guard !review.notes.isEmpty else { return NSSound.beep() }
        let brief = review.notesBrief
        let agents = checkoutAgents(in: review.root)
        if let recorder = reviewNotesRecorder { return recorder(brief, agents) }
        if agents.count == 1, let agent = agents.first {
            hideReviewPage(focus: false)
            if type(brief, intoAgent: agent) { review.clearNotes() }
            return
        }
        let count = review.notes.count
        presentAskAgent(
            text: brief, command: nil, folder: review.root.path, targets: agents.isEmpty ? otherAgentTabs() : agents,
            subject: count == 1 ? "1 review note" : "\(count) review notes", diff: false, showsBrief: true)
    }

    /// ⌘L over a review: the picked lines, with where they are, to Ask
    /// Agent's sheet.
    package func askAboutReviewLines(_ review: ReviewModel) {
        guard let selection = review.lineSelection else { return NSSound.beep() }
        let lines = review.selectedLines
        guard !lines.isEmpty else { return NSSound.beep() }
        let text =
            "\(selection.path), \(ReviewNotes.span(lines)), in \(review.title):\n"
            + ReviewNotes.fenced(ReviewNotes.clean(ReviewNotes.excerpt(lines)), info: "diff")
        let agents = checkoutAgents(in: review.root)
        presentAskAgent(
            text: text, command: nil, folder: review.root.path, targets: agents.isEmpty ? otherAgentTabs() : agents,
            subject: ReviewNotes.span(lines), diff: false)
    }

    /// Address This Thread: the thread's place, its diff and its comments —
    /// fenced, said to be other people's words — to the checkout's agent.
    package func addressReviewThread(_ thread: ReviewThread, root: URL, title: String) {
        let brief = ReviewNotes.thread(thread, reviewing: title)
        let agents = checkoutAgents(in: root)
        if let recorder = reviewNotesRecorder { return recorder(brief, agents) }
        if agents.count == 1, let agent = agents.first {
            hideReviewPage(focus: false)
            type(brief, intoAgent: agent)
            return
        }
        presentAskAgent(
            text: brief, command: nil, folder: root.path, targets: agents.isEmpty ? otherAgentTabs() : agents,
            subject: "a review thread", diff: false, showsBrief: true)
    }

    /// The Pull Request pane's thread: its pull request's title, the checkout's agents.
    package func addressShownPullRequestThread(_ thread: ReviewThread) {
        guard let root = diff.root else { return NSSound.beep() }
        let title = pullRequest.detail.map { "pull request #\($0.summary.number) \($0.summary.title)" } ?? "this pull request"
        addressReviewThread(thread, root: root, title: title)
    }

    private func otherAgentTabs() -> [Tab] {
        store.tabs.filter { $0.agent != nil && !terraformAsking($0) }
    }
}
