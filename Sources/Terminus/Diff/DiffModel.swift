import Foundation

/// The changes of one checkout, in one of two scopes, and — while the panel
/// is open — every shown file's diff:
/// - uncommitted: staged and unstaged together, against HEAD (or the empty
///   tree before the first commit) — what staging and committing act on;
/// - branch: everything since the branch left the default branch, its
///   commits and what is not committed yet, against merge-base(HEAD, base).
///   Committed work stays visible after the agent commits.
///
/// Both lists' counts are always live (the title-bar badge shows one); the
/// per-file diffs only load while `panelVisible`.
@MainActor
final class DiffModel: ObservableObject {
    struct FileDiff {
        let lines: [DiffLine]
        let truncated: Bool
    }

    enum Scope: String {
        case uncommitted, branch
    }

    /// What `.branch` compares the working tree with — or why it can't.
    enum BranchComparison: Equatable {
        /// merge-base(HEAD, base); `base` as MergedWorktrees.base names it.
        case since(mergeBase: String, base: String)
        /// No HEAD yet.
        case noCommits
        /// Neither origin/HEAD nor a main worktree on a branch.
        case noBase
        /// HEAD is on the base branch itself.
        case onBase(String)
        /// HEAD shares no history with the base.
        case unrelated(String)

        var mergeBase: String? {
            if case .since(let mergeBase, _) = self { mergeBase } else { nil }
        }

        /// Why `.branch` can't be shown; nil when it can.
        var unavailable: String? {
            switch self {
            case .since: nil
            case .noCommits: "No commits yet — nothing to compare with"
            case .noBase: "No default branch found — nothing to compare with"
            case .onBase(let branch): "On \(branch) — nothing to compare with"
            case .unrelated(let base): "No history shared with \(base) — nothing to compare with"
            }
        }
    }

    /// What the ± badge in the title bar shows.
    enum Badge: Equatable {
        case uncommitted(added: Int, removed: Int)
        case branch(added: Int, removed: Int)
        case plain
    }

    @Published private(set) var root: URL?
    /// Why this checkout is the one shown (set by the window).
    @Published var showing: CheckoutReason = .shell
    /// Uncommitted: staged, unstaged and untracked, against HEAD.
    @Published private(set) var files: [ChangedFile] = []
    /// Everything since the branch left its base, committed or not.
    @Published private(set) var branchFiles: [ChangedFile] = []
    /// The branch's commits since then, newest first.
    @Published private(set) var commits: [BranchCommit] = []
    /// There were more than `maxCommits`.
    @Published private(set) var moreCommits = false
    /// nil until the checkout's first refresh.
    @Published private(set) var comparison: BranchComparison?
    /// The one picked in the pane (`choose`); remembered.
    @Published private(set) var scope: Scope
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
    /// Commits listed at most: a base far behind is no reason to parse
    /// thousands on every refresh.
    static let maxCommits = 100
    /// git's well-known empty tree: the base before a repository's first commit.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    /// The picked scope, in AppEnvironment.defaults.
    static let scopeKey = "diffScope"

    private let defaults: UserDefaults
    private var watcher: DirectoryWatcher?
    /// The git state kept outside the checkout: a linked worktree's index,
    /// HEAD and reflog are in the main repository's .git/worktrees/<name>, its
    /// branch in .git/refs. Without it a commit there went unseen.
    private var gitWatcher: DirectoryWatcher?
    private var pendingRefresh: Task<Void, Never>?
    /// Bumped per refresh, so a slow git answer for an old root can't
    /// overwrite a newer one.
    private var generation = 0

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
        scope = defaults.string(forKey: Self.scopeKey).flatMap(Scope.init(rawValue:)) ?? .uncommitted
    }

    /// The pane's Uncommitted | Branch switch.
    func choose(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        defaults.set(scope.rawValue, forKey: Self.scopeKey)
        // The diffs loaded, or loading, are against the other base.
        generation += 1
        diffs = [:]
        Task { await refresh() }
    }

    /// What the pane lists: Branch when picked and there is something to
    /// compare with, else Uncommitted.
    var shownScope: Scope { scope == .branch && comparison?.mergeBase != nil ? .branch : .uncommitted }
    var shownFiles: [ChangedFile] { shownScope == .branch ? branchFiles : files }

    var totals: (added: Int, removed: Int) { Self.totals(files) }
    var shownTotals: (added: Int, removed: Int) { Self.totals(shownFiles) }

    nonisolated static func totals(_ files: [ChangedFile]) -> (added: Int, removed: Int) {
        files.reduce(into: (0, 0)) { sum, file in
            sum.0 += file.added ?? 0
            sum.1 += file.removed ?? 0
        }
    }

    /// Under the switch when Branch is picked: what it compares with, or
    /// why there is nothing to compare with.
    var scopeNote: String? {
        guard scope == .branch, let comparison else { return nil }
        guard case .since(_, let base) = comparison else { return comparison.unavailable }
        return "Since \(base) · \(Self.commitCount(commits.count, more: moreCommits))"
    }

    nonisolated static func commitCount(_ count: Int, more: Bool) -> String {
        if more { return "\(count)+ commits" }
        switch count {
        case 0: return "no commits yet"
        case 1: return "1 commit"
        default: return "\(count) commits"
        }
    }

    /// A refresh worked (it always sets `comparison`): a git repository.
    var badge: Badge? { Self.badge(isRepository: error == nil && comparison != nil, uncommitted: files, branch: branchFiles) }

    /// In any repository, so the pane is one click away: what is uncommitted
    /// while there is some, else the branch's totals — the agent's work stays
    /// in sight after it commits — else a plain ±.
    nonisolated static func badge(isRepository: Bool, uncommitted: [ChangedFile], branch: [ChangedFile]) -> Badge? {
        guard isRepository else { return nil }
        if !uncommitted.isEmpty {
            let sum = totals(uncommitted)
            return .uncommitted(added: sum.added, removed: sum.removed)
        }
        if !branch.isEmpty {
            let sum = totals(branch)
            return .branch(added: sum.added, removed: sum.removed)
        }
        return .plain
    }

    /// Follows the selected tab's checkout. Watching starts right away: the
    /// badge wants counts whether or not the panel is open.
    func setRoot(_ url: URL?) {
        guard url != root else { return }
        root = url
        files = []
        branchFiles = []
        commits = []
        moreCommits = false
        comparison = nil
        diffs = [:]
        collapsed = []
        branch = nil
        error = nil
        watcher?.stop()
        watcher = nil
        gitWatcher?.stop()
        gitWatcher = nil
        pendingRefresh?.cancel()
        guard let url else { return }
        watcher = DirectoryWatcher(root: url, latency: 0.2) { [weak self] _ in self?.scheduleRefresh() }
        Task { await watchGitDirectories(of: url) }
        Task { await refresh() }
    }

    private func watchGitDirectories(of url: URL) async {
        let directories = await Self.gitDirectories(outside: url)
        // The tab may have moved on while git answered.
        guard url == root, !directories.isEmpty else { return }
        gitWatcher = DirectoryWatcher(roots: directories, latency: 0.2) { [weak self] _ in self?.scheduleRefresh() }
    }

    /// Where git keeps this checkout's state, when that is not inside it: the
    /// worktree's own git directory (index, HEAD, its reflog) and the
    /// repository's refs/ (its branch, origin/HEAD). A main checkout's .git
    /// is inside it, so none.
    nonisolated static func gitDirectories(outside root: URL) async -> [URL] {
        guard let output = try? await Git.run(["rev-parse", "--absolute-git-dir", "--git-common-dir"], in: root) else { return [] }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return [] }
        // --git-common-dir is relative to the checkout when it is inside it.
        let gitDir = URL(fileURLWithPath: lines[0])
        let common = lines[1].hasPrefix("/") ? URL(fileURLWithPath: lines[1]) : root.appendingPathComponent(lines[1])
        let inside = root.resolvingSymlinksInPath().path
        return [gitDir, common.appendingPathComponent("refs")].filter {
            let path = $0.resolvingSymlinksInPath().path
            return path != inside && !path.hasPrefix(inside + "/")
        }
    }

    /// Coalesces a burst of file events (an agent writing many files, git
    /// writing its index and refs) into one git status.
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
            let hasHead = (try? await Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)) != nil
            // HEAD, or the empty tree when there is no commit yet.
            let head = hasHead ? "HEAD" : Self.emptyTree
            let numstat = (try? await Git.run(["diff", "--numstat", "-z", head], in: root)) ?? ""
            let current = (try? await Git.run(["branch", "--show-current"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let branchName = current?.isEmpty == false ? current : nil
            let changed = Self.counted(GitStatus.parse(porcelainZ: status), GitStatus.parse(numstatZ: numstat), in: root)
            let comparison = await Self.comparison(in: root, hasHead: hasHead, branch: branchName)
            var onBranch: [ChangedFile] = []
            var log: [BranchCommit] = []
            if let mergeBase = comparison.mergeBase {
                onBranch = await Self.branchFiles(in: root, since: mergeBase, untracked: changed.filter { $0.kind == .untracked })
                let listed = try? await Git.run(BranchLog.arguments(since: mergeBase, limit: Self.maxCommits + 1), in: root)
                log = BranchLog.parse(listed ?? "")
            }
            guard ticket == generation else { return }
            files = changed
            branchFiles = onBranch
            commits = Array(log.prefix(Self.maxCommits))
            moreCommits = log.count > Self.maxCommits
            self.comparison = comparison
            branch = branchName
            error = nil
            if panelVisible { await loadDiffs(head: head, ticket: ticket) }
        } catch {
            guard ticket == generation else { return }
            files = []
            branchFiles = []
            commits = []
            moreCommits = false
            comparison = nil
            diffs = [:]
            self.error = error is GitError ? "Not a git repository" : error.localizedDescription
        }
    }

    /// Fills in each file's counts from numstat; an untracked file's lines
    /// (numstat doesn't see those) are all additions.
    private static func counted(_ files: [ChangedFile], _ counts: [String: (added: Int?, removed: Int?)], in root: URL) -> [ChangedFile] {
        var files = files
        for i in files.indices {
            if files[i].kind == .untracked {
                files[i].added = lineCount(root.appendingPathComponent(files[i].path))
                files[i].removed = files[i].added == nil ? nil : 0
            } else {
                files[i].added = counts[files[i].path]?.added ?? nil
                files[i].removed = counts[files[i].path]?.removed ?? nil
            }
        }
        return files
    }

    /// The merge-base of HEAD and the default branch (the one merged
    /// worktrees are judged by) — or why there is none to use.
    private static func comparison(in root: URL, hasHead: Bool, branch: String?) async -> BranchComparison {
        guard hasHead else { return .noCommits }
        guard let base = await MergedWorktrees.base(in: root) else { return .noBase }
        // The base is origin/<branch> or a local branch.
        if let branch, base == branch || base == "origin/\(branch)" { return .onBase(branch) }
        let mergeBase = (try? await Git.run(["merge-base", "HEAD", base], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mergeBase, !mergeBase.isEmpty else { return .unrelated(base) }
        return .since(mergeBase: mergeBase, base: base)
    }

    /// Everything that differs from the merge-base: the tracked files git
    /// diff compares (committed, staged, unstaged; renames paired), and the
    /// untracked ones, already counted.
    private static func branchFiles(in root: URL, since mergeBase: String, untracked: [ChangedFile]) async -> [ChangedFile] {
        let names = (try? await Git.run(["diff", "--name-status", "-z", "-M", mergeBase], in: root)) ?? ""
        let numstat = (try? await Git.run(["diff", "--numstat", "-z", "-M", mergeBase], in: root)) ?? ""
        var files = counted(GitStatus.parse(nameStatusZ: names), GitStatus.parse(numstatZ: numstat), in: root)
        let tracked = Set(files.map(\.path))
        files += untracked.filter { !tracked.contains($0.path) }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

    /// The shown scope's diffs: against HEAD (`head`: or the empty tree), or
    /// against the merge-base.
    private func loadDiffs(head: String, ticket: Int) async {
        guard let root else { return }
        let mergeBase = shownScope == .branch ? comparison?.mergeBase : nil
        let base = mergeBase ?? head
        var loaded: [String: FileDiff] = [:]
        for file in (mergeBase == nil ? files : branchFiles).prefix(Self.maxDiffedFiles) {
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
