import Foundation

/// The working-tree changes of one checkout — staged and unstaged together,
/// against HEAD (or the empty tree before the first commit) — and, while
/// the panel is open, every changed file's diff.
///
/// The counts are always live (the title-bar badge shows them); the
/// per-file diffs only load while `panelVisible`.
@MainActor
final class DiffModel: ObservableObject {
    struct FileDiff {
        let lines: [DiffLine]
        let truncated: Bool
    }

    @Published private(set) var root: URL?
    @Published private(set) var files: [ChangedFile] = []
    @Published private(set) var branch: String?
    @Published private(set) var diffs: [String: FileDiff] = [:]
    /// Cards the user folded.
    @Published var collapsed: Set<String> = []
    @Published private(set) var error: String?

    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue, panelVisible else { return }
            Task { await refresh() }
        }
    }

    /// Diffs past this many files aren't loaded — a huge change set is for
    /// the terminal, not a panel.
    static let maxDiffedFiles = 60
    /// git's well-known empty tree: the base before a repository's first commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    private var watcher: DirectoryWatcher?
    private var pendingRefresh: Task<Void, Never>?
    /// Bumped per refresh, so a slow git answer for an old root can't
    /// overwrite a newer one.
    private var generation = 0

    var totals: (added: Int, removed: Int) {
        files.reduce(into: (0, 0)) { sum, file in
            sum.0 += file.added ?? 0
            sum.1 += file.removed ?? 0
        }
    }

    /// Follows the selected tab's checkout. Watching starts right away: the
    /// badge wants counts whether or not the panel is open.
    func setRoot(_ url: URL?) {
        guard url != root else { return }
        root = url
        files = []
        diffs = [:]
        collapsed = []
        branch = nil
        error = nil
        watcher?.stop()
        watcher = nil
        pendingRefresh?.cancel()
        guard let url else { return }
        watcher = DirectoryWatcher(root: url, latency: 0.2) { [weak self] _ in self?.scheduleRefresh() }
        Task { await refresh() }
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
        guard let root else { return }
        generation += 1
        let ticket = generation
        do {
            let status = try await Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
            let base = await Self.base(in: root)
            let numstat = (try? await Git.run(["diff", "--numstat", "-z", base], in: root)) ?? ""
            let head = (try? await Git.run(["branch", "--show-current"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            var changed = GitStatus.parse(porcelainZ: status)
            let counts = GitStatus.parse(numstatZ: numstat)
            for i in changed.indices {
                if changed[i].kind == .untracked {
                    // numstat doesn't see untracked files; their lines are all additions.
                    changed[i].added = Self.lineCount(root.appendingPathComponent(changed[i].path))
                    changed[i].removed = changed[i].added == nil ? nil : 0
                } else {
                    changed[i].added = counts[changed[i].path]?.added ?? nil
                    changed[i].removed = counts[changed[i].path]?.removed ?? nil
                }
            }
            guard ticket == generation else { return }
            files = changed
            branch = head?.isEmpty == false ? head : nil
            error = nil
            if panelVisible { await loadDiffs(base: base, ticket: ticket) }
        } catch {
            guard ticket == generation else { return }
            files = []
            diffs = [:]
            self.error = error is GitError ? "Not a git repository" : error.localizedDescription
        }
    }

    /// HEAD, or the empty tree when there is no commit yet.
    private static func base(in root: URL) async -> String {
        (try? await Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)) != nil ? "HEAD" : emptyTree
    }

    /// Lines in a small text file; nil for binary, unreadable or > 1 MB.
    nonisolated static func lineCount(_ url: URL) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= 1_048_576,
            let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0)
        else { return nil }
        if data.isEmpty { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    private func loadDiffs(base: String, ticket: Int) async {
        guard let root else { return }
        var loaded: [String: FileDiff] = [:]
        for file in files.prefix(Self.maxDiffedFiles) {
            let arguments: [String]
            switch file.kind {
            case .untracked: arguments = ["diff", "--no-color", "--no-index", "--", "/dev/null", file.path]
            case .renamed: arguments = ["diff", "--no-color", "-M", base, "--", file.originalPath ?? file.path, file.path]
            default: arguments = ["diff", "--no-color", base, "--", file.path]
            }
            let text = (try? await Git.run(arguments, in: root, success: [0, 1])) ?? ""
            let parsed = UnifiedDiff.parse(text, limit: 3_000)
            // Only hunks and their lines: the card header already names the file.
            loaded[file.path] = FileDiff(lines: parsed.lines.filter { $0.kind != .meta || $0.text.hasPrefix("\\") }, truncated: parsed.truncated)
        }
        guard ticket == generation else { return }
        diffs = loaded
    }

    // MARK: Staging and committing

    /// Set when a stage/discard/commit fails; shown in the panel.
    @Published var actionError: String?

    var stagedCount: Int { files.filter(\.isStaged).count }

    /// Stages the whole file, or unstages it if it is fully staged.
    func toggleStaged(_ file: ChangedFile) async {
        if file.stageState == .full { await unstage(file) } else { await stage(file) }
    }

    func stage(_ file: ChangedFile) async { await perform(["add", "--", file.path]) }

    /// A newly added file isn't in HEAD (and before the first commit there
    /// is no HEAD), so `restore --staged` can't apply: drop it from the index.
    /// --force because git refuses --cached when the index differs from both
    /// HEAD and the file (added, then edited); --cached never touches the file.
    func unstage(_ file: ChangedFile) async {
        await perform(file.kind == .added ? ["rm", "--cached", "--force", "--quiet", "--", file.path] : ["restore", "--staged", "--", file.path])
    }

    func stageAll() async { await perform(["add", "--all"]) }

    /// Throws the file's changes away: back to HEAD, staged and unstaged. A
    /// file HEAD doesn't have (untracked, or newly added) goes to the Trash,
    /// not oblivion.
    func discard(_ file: ChangedFile) async {
        guard let root else { return }
        if file.kind == .untracked || file.kind == .added {
            // Not in HEAD: take it out of the index (if there), then Trash it.
            if file.kind == .added { _ = try? await Git.run(["rm", "--cached", "--force", "--quiet", "--", file.path], in: root) }
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

    /// Nothing staged: stage everything, then commit — Warp's one-button path.
    func commitAll(message: String) async -> Bool {
        guard await perform(["add", "--all"]) else { return false }
        return await perform(["commit", "-m", message])
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
}
