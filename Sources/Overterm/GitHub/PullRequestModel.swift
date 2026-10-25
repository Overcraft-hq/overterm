import Foundation

/// The Pull Request pane: the PR of the selected tab's checkout's branch —
/// its checks, conversation and review threads — and writing to it.
/// Loaded only while the pane shows it; everything goes through gh.
@MainActor
final class PullRequestModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded, none
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detail: PullRequestDetail?
    @Published private(set) var threads: [ReviewThread] = []
    /// The last post that failed, said plainly.
    @Published private(set) var postError: String?
    @Published private(set) var posting = false

    private(set) var root: URL?
    private(set) var branch: String?
    /// A pull request picked in Overgit — not the checkout's branch's:
    /// shown by its number until the tab's branch changes or it is let go.
    @Published private(set) var picked: Int?
    /// Whether the pane is showing: nothing loads while it isn't.
    /// Showing it again asks again: comments and checks move meanwhile.
    var visible = false {
        didSet { if visible, !oldValue { Task { await refresh() } } }
    }

    /// The checkout and branch to show. A change resets and, if visible, loads.
    func show(root: URL?, branch: String?) {
        // Compared resolved: /var and /private/var are one checkout, and
        // taking them for two let go of a picked pull request at once.
        let same = root?.resolvingSymlinksInPath().path == self.root?.resolvingSymlinksInPath().path
        guard !same || branch != self.branch else { return }
        self.root = root
        self.branch = branch
        picked = nil
        reset()
    }

    /// Another pull request of the repository, by its number.
    func show(number: Int, in root: URL) {
        guard number != picked || root != self.root else { return }
        self.root = root
        picked = number
        reset()
    }

    /// Back to the checkout's branch's own.
    func unpick() {
        guard picked != nil else { return }
        picked = nil
        reset()
    }

    private func reset() {
        detail = nil
        threads = []
        postError = nil
        phase = .idle
        if visible { Task { await refresh() } }
    }

    func refresh() async {
        let picked = self.picked
        guard let root, let selector = picked.map(String.init) ?? branch else {
            phase = .none
            return
        }
        let branch = self.branch
        phase = .loading
        do {
            let data = try await GitHub.run(["pr", "view", selector, "--json", PullRequestDetail.viewFields], in: root)
            let detail = try PullRequestDetail.parse(data)
            let comments = try await GitHub.run(
                ["api", "repos/{owner}/{repo}/pulls/\(detail.summary.number)/comments", "--paginate"], in: root)
            let threads = try ReviewThread.parse(comments)
            // The tab may have moved on while gh ran.
            guard root == self.root, branch == self.branch, picked == self.picked else { return }
            self.detail = detail
            self.threads = threads
            phase = .loaded
        } catch GitHub.Failure.failed(let message) where message == GitHub.message(for: "no pull requests found") {
            guard root == self.root, branch == self.branch, picked == self.picked else { return }
            phase = .none
        } catch {
            guard root == self.root, branch == self.branch, picked == self.picked else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// A comment on the pull request. True when it was posted.
    @discardableResult
    func comment(_ text: String) async -> Bool {
        guard let number = detail?.summary.number else { return false }
        return await post(["pr", "comment", "\(number)", "--body", text])
    }

    /// A reply in a review thread. True when it was posted.
    @discardableResult
    func reply(to thread: ReviewThread, _ text: String) async -> Bool {
        guard let number = detail?.summary.number else { return false }
        return await post(["api", "repos/{owner}/{repo}/pulls/\(number)/comments/\(thread.id)/replies", "-f", "body=\(text)"])
    }

    private func post(_ arguments: [String]) async -> Bool {
        guard let root, !posting else { return false }
        posting = true
        postError = nil
        defer { posting = false }
        do {
            _ = try await GitHub.run(arguments, in: root)
            await refresh()
            return true
        } catch {
            postError = error.localizedDescription
            return false
        }
    }
}
