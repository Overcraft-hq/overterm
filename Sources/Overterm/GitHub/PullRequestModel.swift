import Foundation

/// The Pull Request pane: the PR of the selected tab's checkout's branch —
/// its checks, conversation and review threads — and writing to it.
/// Loaded only while the pane shows it; everything goes through gh.
@MainActor
package final class PullRequestModel: ObservableObject {
    package init() {}

    package enum Phase: Equatable {
        case idle, loading, loaded, none
        case failed(String)
    }

    @Published package private(set) var phase: Phase = .idle
    @Published package private(set) var detail: PullRequestDetail?
    @Published package private(set) var threads: [ReviewThread] = []
    /// The last post that failed, said plainly.
    @Published package private(set) var postError: String?
    @Published package private(set) var posting = false

    /// A failed check's log, as asked for (GIT-G5): read once a check, the
    /// failed step's tail, masked (`CILog.tail`).
    package enum CheckLog: Equatable {
        case loading
        case loaded(String)
        case failed(String)
    }
    /// By the check's name; forgotten with the pull request shown.
    @Published package private(set) var logs: [String: CheckLog] = [:]

    /// `check`'s failed step's log, read now unless it is already there.
    package func loadLog(of check: Check) async {
        guard let root, logs[check.name] == nil || logs[check.name].map({ if case .failed = $0 { true } else { false } }) == true else { return }
        guard let job = check.actionsJob else {
            logs[check.name] = .failed("Not a GitHub Actions job: its log is on its own page.")
            return
        }
        logs[check.name] = .loading
        do {
            let data = try await GitHub.run(CILog.arguments(run: job.run, job: job.job), in: root, timeout: 30)
            let text = CILog.tail(String(decoding: data, as: UTF8.self))
            logs[check.name] = .loaded(text.isEmpty ? "(no output from the failed steps)" : text)
        } catch {
            logs[check.name] = .failed(error.localizedDescription)
        }
    }

    /// Its log hidden again.
    package func closeLog(of check: Check) { logs[check.name] = nil }

    package private(set) var root: URL?
    package private(set) var branch: String?
    /// A pull request picked in Overgit — not the checkout's branch's:
    /// shown by its number until the tab's branch changes or it is let go.
    @Published package private(set) var picked: Int?
    /// Whether the pane is showing: nothing loads while it isn't.
    /// Showing it again asks again: comments and checks move meanwhile.
    package var visible = false {
        didSet { if visible, !oldValue { Task { await refresh() } } }
    }

    /// The checkout and branch to show. A change resets and, if visible, loads.
    package func show(root: URL?, branch: String?) {
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
    package func show(number: Int, in root: URL) {
        guard number != picked || root != self.root else { return }
        self.root = root
        picked = number
        reset()
    }

    /// Back to the checkout's branch's own.
    package func unpick() {
        guard picked != nil else { return }
        picked = nil
        reset()
    }

    private func reset() {
        detail = nil
        threads = []
        logs = [:]
        postError = nil
        phase = .idle
        if visible { Task { await refresh() } }
    }

    package func refresh() async {
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
    package func comment(_ text: String) async -> Bool {
        guard let number = detail?.summary.number else { return false }
        return await post(["pr", "comment", "\(number)", "--body", text])
    }

    /// A reply in a review thread. True when it was posted.
    @discardableResult
    package func reply(to thread: ReviewThread, _ text: String) async -> Bool {
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
