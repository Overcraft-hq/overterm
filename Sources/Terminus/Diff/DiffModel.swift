import Foundation

/// The working-tree changes of one checkout (vs HEAD, staged and unstaged
/// together) and the diff of the selected file. Only does work while the
/// panel is showing.
@MainActor
final class DiffModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var files: [ChangedFile] = []
    @Published private(set) var branch: String?
    @Published private(set) var selectedPath: String?
    @Published private(set) var lines: [DiffLine] = []
    @Published private(set) var truncated = false
    @Published private(set) var error: String?

    /// The panel is open. Watching and git calls happen only then.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? start() : stop()
        }
    }

    private var watcher: DirectoryWatcher?
    private var pendingRefresh: Task<Void, Never>?
    /// Bumped per request, so a slow git answer for an old root or file
    /// can't overwrite a newer one.
    private var generation = 0

    var totals: (added: Int, removed: Int) {
        files.reduce(into: (0, 0)) { sum, file in
            sum.0 += file.added ?? 0
            sum.1 += file.removed ?? 0
        }
    }

    func setRoot(_ url: URL?) {
        guard url != root else { return }
        root = url
        files = []
        selectedPath = nil
        lines = []
        if isActive {
            stop()
            start()
        }
    }

    func select(_ path: String) {
        selectedPath = path
        Task { await loadDiff() }
    }

    private func start() {
        guard let root else { return }
        watcher = DirectoryWatcher(root: root, latency: 0.2) { [weak self] _ in self?.scheduleRefresh() }
        Task { await refresh() }
    }

    private func stop() {
        watcher?.stop()
        watcher = nil
        pendingRefresh?.cancel()
    }

    /// Coalesces a burst of file events (an agent writing many files) into
    /// one git status.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let root, isActive else { return }
        generation += 1
        let ticket = generation
        do {
            async let status = Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
            async let numstat = Git.run(["diff", "--numstat", "-z", "HEAD"], in: root)
            async let head = Git.run(["branch", "--show-current"], in: root)
            var changed = GitStatus.parse(porcelainZ: try await status)
            let counts = GitStatus.parse(numstatZ: (try? await numstat) ?? "")
            for i in changed.indices {
                changed[i].added = counts[changed[i].path]?.added ?? nil
                changed[i].removed = counts[changed[i].path]?.removed ?? nil
            }
            let branchName = (try? await head)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ticket == generation else { return }
            files = changed
            branch = branchName?.isEmpty == false ? branchName : nil
            error = nil
            if selectedPath == nil || !changed.contains(where: { $0.path == selectedPath }) {
                selectedPath = changed.first?.path
            }
            await loadDiff()
        } catch {
            guard ticket == generation else { return }
            files = []
            lines = []
            self.error = (error as? GitError).map { _ in "Not a git repository" } ?? error.localizedDescription
        }
    }

    // MARK: Staging and committing

    /// Set when a stage/discard/commit fails; shown in the panel.
    @Published var actionError: String?

    var stagedCount: Int { files.filter(\.isStaged).count }

    /// Stages the whole file, or unstages it if it is fully staged.
    func toggleStaged(_ file: ChangedFile) async {
        await perform(file.stageState == .full ? ["restore", "--staged", "--", file.path] : ["add", "--", file.path])
    }

    func stage(_ file: ChangedFile) async { await perform(["add", "--", file.path]) }
    func unstage(_ file: ChangedFile) async { await perform(["restore", "--staged", "--", file.path]) }
    func stageAll() async { await perform(["add", "--all"]) }

    /// Throws the file's changes away: back to HEAD, staged and unstaged. An
    /// untracked file goes to the Trash, not oblivion.
    func discard(_ file: ChangedFile) async {
        guard let root else { return }
        if file.kind == .untracked {
            do {
                try FileManager.default.trashItem(at: root.appendingPathComponent(file.path), resultingItemURL: nil)
            } catch {
                actionError = error.localizedDescription
            }
            await refresh()
        } else {
            await perform(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + [file.originalPath, file.path].compactMap { $0 })
        }
    }

    /// Commits what is staged. Returns whether it worked (the panel clears
    /// its message field then).
    func commit(message: String) async -> Bool {
        await perform(["commit", "-m", message])
    }

    @discardableResult
    private func perform(_ arguments: [String]) async -> Bool {
        guard let root else { return false }
        defer { Task { await refresh() } }
        do {
            _ = try await Git.run(arguments, in: root)
            actionError = nil
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    private func loadDiff() async {
        guard let root, let path = selectedPath, let file = files.first(where: { $0.path == path }) else {
            lines = []
            return
        }
        let ticket = generation
        let arguments: [String]
        switch file.kind {
        case .untracked: arguments = ["diff", "--no-color", "--no-index", "--", "/dev/null", path]
        case .renamed: arguments = ["diff", "--no-color", "-M", "HEAD", "--", file.originalPath ?? path, path]
        default: arguments = ["diff", "--no-color", "HEAD", "--", path]
        }
        let text = (try? await Git.run(arguments, in: root, success: [0, 1])) ?? ""
        guard ticket == generation, path == selectedPath else { return }
        let parsed = UnifiedDiff.parse(text)
        lines = parsed.lines
        truncated = parsed.truncated
    }
}
