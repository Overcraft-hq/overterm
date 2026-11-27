import AppKit

/// Review tabs: a branch, some commits or a pull request, read as a
/// reviewer reads them — a page over the window's body, as Settings is.
extension TerminalWindowController {
    package var shownReview: ReviewModel? {
        guard let id = store.reviewShowing else { return nil }
        return store.reviews.first { $0.id == id }
    }

    package var reviewActions: ReviewActions {
        ReviewActions(
            openFile: { [weak self] review, file in self?.openReviewedFile(review, file) },
            openOnGitHub: { NSWorkspace.shared.open($0) },
            sendNotes: { [weak self] in self?.sendReviewNotes($0) },
            noteRecipient: { [weak self] in self?.reviewNoteRecipient($0) },
            askAboutLines: { [weak self] in self?.askAboutReviewLines($0) },
            terraform: terraformReviewActions)
    }

    /// Opens a review tab — or the one already open for the same thing.
    @discardableResult
    package func openReview(_ source: ReviewSource, in root: URL) -> ReviewModel {
        let resolved = root.resolvingSymlinksInPath().path
        if let open = store.reviews.first(where: { $0.source == source && $0.root.resolvingSymlinksInPath().path == resolved }) {
            showReview(open)
            Task { await open.load() }
            return open
        }
        let review = ReviewModel(root: root, source: source)
        store.reviews.append(review)
        watchTerraformReview(review)
        showReview(review)
        Task { await review.load() }
        return review
    }

    package func showReview(_ review: ReviewModel) {
        guard let reviewView else { return }
        hideAgentOverview()
        if peek.isOpen { peek.close() }
        hideSpotlight(keepTerminalSearch: false)
        // The pages (Settings, Docker) and a review take turns.
        hideOverlay(focus: false)
        store.reviewShowing = review.id
        reviewView.isHidden = false
        window?.makeFirstResponder(reviewView)
        showTerraformReview(review)
    }

    /// Uncovers the selected terminal tab; the review tabs stay in the strip.
    package func hideReviewPage(focus: Bool = true) {
        guard store.reviewShowing != nil else { return }
        store.reviewShowing = nil
        reviewView?.isHidden = true
        if focus { focusSelectedTerminal() }
    }

    /// Its ✕, or ⌘W while it shows.
    package func closeReview(_ review: ReviewModel) {
        if store.reviewShowing == review.id { hideReviewPage() }
        store.reviews.removeAll { $0.id == review.id }
    }

    /// The file in the editor, at the change being read — the checkout's
    /// copy, which is the reviewed one for the branch and may not be for
    /// the rest.
    private func openReviewedFile(_ review: ReviewModel, _ file: ChangedFile) {
        let url = review.root.appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return alert("\(file.path) isn’t in this checkout", "It is only in what is under review.")
        }
        let target = review.scrollTarget
        let line = review.diffs[file.path]?.lines.first { $0.id >= (target ?? 0) && $0.newNumber != nil }?.newNumber
        hideReviewPage(focus: false)
        openInEditor(url, line: line)
    }

    // MARK: What opens one

    /// View ▸ Review Branch (⇧⌘R), the changes pane's Review: the checkout's
    /// branch since it left its base, uncommitted changes and all.
    @objc package func reviewBranch(_ sender: Any?) {
        guard let root = diff.root else { return NSSound.beep() }
        guard case .since(let mergeBase, let base) = diff.comparison else {
            // On the base branch (main), or before a first commit: what
            // isn't committed is what there is to review.
            if !diff.files.isEmpty { return reviewUncommitted(nil) }
            return alert("Nothing to review", diff.comparison?.unavailable ?? "This checkout has no branch to compare.")
        }
        openReview(.branch(mergeBase: mergeBase, base: base, branch: diff.branch ?? "HEAD"), in: root)
    }

    /// The changes pane's Uncommitted, and the palette's: staged, unstaged
    /// and untracked, against HEAD.
    @objc package func reviewUncommitted(_ sender: Any?) {
        guard let root = diff.root else { return NSSound.beep() }
        guard !diff.files.isEmpty else { return alert("Nothing to review", "There are no uncommitted changes in this checkout.") }
        openReview(.uncommitted(branch: diff.branch), in: root)
    }

    /// Overgit's commits: one, or a run of them — picked in either order,
    /// reviewed oldest first.
    package func reviewCommits(from: String, to: String) {
        guard let root = overgit.root ?? diff.root else { return }
        guard from != to else {
            openReview(.commits(from: from, to: to), in: root)
            return
        }
        Task { [weak self] in
            // `to` has nothing `from` lacks: `to` is the older one.
            let count = try? await Git.run(["rev-list", "--count", "\(from)..\(to)"], in: root)
            let backwards = count?.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
            self?.openReview(.commits(from: backwards ? to : from, to: backwards ? from : to), in: root)
        }
    }

    /// Overgit's branches and Compare: what `head` has that `base` doesn't.
    package func reviewRange(base: String, head: String) {
        guard let root = overgit.root ?? diff.root else { return }
        let name: (String) -> String = { [diff] ref in ref == "HEAD" ? diff.branch ?? "HEAD" : ref }
        openReview(.range(base: name(base), head: name(head)), in: root)
    }

    /// A branch against the base the changes pane compares with — or,
    /// with the checkout on that base itself, against the checkout's branch.
    package func reviewBranchRef(_ branch: String) {
        if case .since(_, let base) = diff.comparison { return reviewRange(base: base, head: branch) }
        reviewRange(base: "HEAD", head: branch)
    }

    /// The checkout's branch's pull request, as the strip's chip knows it.
    package func reviewCurrentPullRequest() {
        guard let branch = diff.branch, let pr = worktrees.pullRequests[branch] else {
            return alert("No pull request", diff.branch.map { "\($0) has no pull request on GitHub." } ?? "This checkout isn’t on a branch.")
        }
        reviewPullRequest(pr.number)
    }

    /// A pull request, by its number.
    package func reviewPullRequest(_ number: Int) {
        guard let root = overgit.root ?? diff.root else { return NSSound.beep() }
        openReview(.pullRequest(number: number), in: root)
    }
}
