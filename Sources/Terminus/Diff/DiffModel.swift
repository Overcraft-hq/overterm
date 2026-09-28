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
/// per-file diffs — and why each file changed — only load while
/// `panelVisible`.
@MainActor
final class DiffModel: ObservableObject {
    struct FileDiff {
        let lines: [DiffLine]
        let truncated: Bool
        /// Each line's syntax colours and changed part, by `DiffLine.id`;
        /// lines with neither are left out.
        let styles: [Int: DiffLineStyle]

        /// A file's `git diff`: its hunks and their lines (the card's header
        /// already names the file), at most `limit`, each styled — the
        /// work done once as the diff loads, never while drawing.
        init(parsing diff: String, path: String, limit: Int = DiffModel.maxDiffLines) {
            let parsed = UnifiedDiff.parse(diff, limit: limit)
            lines = parsed.lines.filter { $0.kind != .meta || $0.text.hasPrefix("\\") }
            truncated = parsed.truncated
            styles = DiffHighlight.styles(for: lines, language: SyntaxHighlighter.language(for: URL(fileURLWithPath: path)))
        }

        func style(of line: DiffLine) -> DiffLineStyle { styles[line.id] ?? DiffLineStyle() }
    }

    enum Scope: String {
        case uncommitted, branch
    }

    /// What `.branch` compares the working tree with — or why it can't.
    enum BranchComparison: Equatable {
        /// merge-base(HEAD, base); `base` as `branchBase` names it.
        case since(mergeBase: String, base: String)
        /// No HEAD yet.
        case noCommits
        /// Neither origin/HEAD, nor a main worktree on another branch, nor
        /// any of `fallbackBases`.
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

        /// The scope whose totals it shows — the one a click on it opens;
        /// none for the plain ±.
        var scope: Scope? {
            switch self {
            case .uncommitted: .uncommitted
            case .branch: .branch
            case .plain: nil
            }
        }
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
    /// Folded or not, by path: how each card started when first shown in
    /// the pane, or how the user left it. Kept while the pane stays on this
    /// checkout, in either scope; another starts afresh.
    @Published private(set) var folded: [String: Bool] = [:]
    /// Collapse All / Expand All: how the cards shown after it start.
    private var allFolded: Bool?
    /// Cards whose why the user opened: every reason, in full.
    @Published private(set) var openWhy: Set<String> = []
    @Published private(set) var error: String?
    /// Why each file changed, by path: what Claude said making its edits,
    /// newest first (ClaudeEdits.byFile) — from the checkout's session
    /// transcripts, read only while the panel is open.
    @Published private(set) var reasons: [String: [ClaudeEdit]] = [:]
    /// The branch's commits that touched each file, newest first.
    @Published private(set) var commitsByFile: [String: [BranchCommit]] = [:]

    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue, panelVisible else { return }
            Task { await refresh() }
        }
    }

    /// Diffs past this many files aren't loaded — a huge change set is for
    /// the terminal, not a panel.
    static let maxDiffedFiles = 60
    /// Lines of one file's diff shown at most.
    nonisolated static let maxDiffLines = 3_000
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
    /// Reads Claude Code's transcripts for `reasons`; none, no reasons (a
    /// unit test's model never reads ~/.claude).
    private let transcripts: ClaudeEditsReader?
    /// Bumped per root, so reasons read for another checkout are dropped.
    private var reasonsGeneration = 0
    private var readingReasons = false
    private var readReasonsAgain = false

    init(defaults: UserDefaults = AppEnvironment.defaults, transcripts: ClaudeEditsReader? = nil) {
        self.defaults = defaults
        self.transcripts = transcripts
        scope = defaults.string(forKey: Self.scopeKey).flatMap(Scope.init(rawValue:)) ?? .uncommitted
    }

    /// The pane's Uncommitted | Branch switch.
    func choose(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        defaults.set(scope.rawValue, forKey: Self.scopeKey)
        // The other list's cards not seen yet start now, as it shows.
        settleFolds()
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
        reasons = [:]
        commitsByFile = [:]
        reasonsGeneration += 1
        openWhy = []
        folded = [:]
        allFolded = nil
        branch = nil
        error = nil
        watcher?.stop()
        watcher = nil
        gitWatcher?.stop()
        gitWatcher = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingSince = nil
        guard let url else { return }
        Task { await watch(url) }
        Task { await refresh() }
    }

    /// Watches the checkout, and git's state outside it — only once git says
    /// it is a work tree. A tab in ~ (no repository) watched all of home, and
    /// every change in ~/Library ran a git status that could only fail.
    private func watch(_ url: URL) async {
        guard (try? await Git.run(["rev-parse", "--is-inside-work-tree"], in: url)) != nil, url == root else { return }
        watcher = DirectoryWatcher(root: url, latency: 0.2) { [weak self] _ in self?.scheduleRefresh() }
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
    /// When the first change of the burst now waiting for a refresh came.
    private var pendingSince: Date?
    /// The refresh running, and whether another was asked for meanwhile.
    private var refreshLoop: Task<Void, Never>?
    private var refreshAgain = false

    /// A refresh 0.4 s after the changes stop — but no later than 2 s after
    /// the first: a build writing steadily kept a plain debounce waiting,
    /// and the badge never moved.
    private func scheduleRefresh() {
        let now = Date()
        if let pendingSince, let pendingRefresh, !pendingRefresh.isCancelled, now.timeIntervalSince(pendingSince) >= 2 { return }
        if pendingSince == nil { pendingSince = now }
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingSince = nil
            self.pendingRefresh = nil
            await self.refresh()
        }
    }

    /// One refresh at a time: asked while one runs, it runs once more after
    /// it — however many asked — and every caller returns after a refresh
    /// that started after its call. Overlapping ones (each six-odd git
    /// processes) stacked up under a stream of changes.
    func refresh() async {
        if let refreshLoop {
            refreshAgain = true
            await refreshLoop.value
            return
        }
        let loop = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.refreshAgain = false
                await self.refreshOnce()
            } while self.refreshAgain
            // In the same turn as the last check: a call arriving later
            // starts a new loop rather than waiting on this finished one.
            self.refreshLoop = nil
        }
        refreshLoop = loop
        await loop.value
    }

    private func refreshOnce() async {
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
            let changed = await Self.counted(GitStatus.parse(porcelainZ: status), GitStatus.parse(numstatZ: numstat), in: root)
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
            commitsByFile = BranchLog.byFile(commits)
            moreCommits = log.count > Self.maxCommits
            self.comparison = comparison
            branch = branchName
            error = nil
            if panelVisible {
                settleFolds()
                readReasons()
                await loadDiffs(head: head, ticket: ticket)
            }
        } catch {
            guard ticket == generation else { return }
            files = []
            branchFiles = []
            commits = []
            commitsByFile = [:]
            moreCommits = false
            comparison = nil
            diffs = [:]
            reasons = [:]
            self.error = error is GitError ? "Not a git repository" : error.localizedDescription
        }
    }

    /// Fills in each file's counts from numstat; an untracked file's lines
    /// (numstat doesn't see those) are all additions. Off the main thread:
    /// that reads every untracked file, and an agent can leave thousands.
    private static func counted(
        _ files: [ChangedFile], _ counts: [String: (added: Int?, removed: Int?)], in root: URL
    ) async -> [ChangedFile] {
        await Task.detached(priority: .userInitiated) { countedNow(files, counts, in: root) }.value
    }

    nonisolated private static func countedNow(
        _ files: [ChangedFile], _ counts: [String: (added: Int?, removed: Int?)], in root: URL
    ) -> [ChangedFile] {
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

    /// The merge-base of HEAD and the default branch (see `branchBase`) —
    /// or why there is none to use.
    private static func comparison(in root: URL, hasHead: Bool, branch: String?) async -> BranchComparison {
        guard hasHead else { return .noCommits }
        let preferred = await MergedWorktrees.base(in: root)
        func isCurrent(_ base: String) -> Bool { branch.map { isBranch(base, $0) } ?? false }
        // The fallback costs a git call: only when the default branch won't do.
        let existing = preferred.map(isCurrent) == false ? [] : await existingRefs(fallbackBases, in: root)
        guard let base = branchBase(default: preferred, current: branch, existing: existing) else {
            // Nothing but the branch itself (main, and its origin/main) to compare with.
            if let branch, preferred.map(isCurrent) == true || existing.contains(where: isCurrent) { return .onBase(branch) }
            return .noBase
        }
        let mergeBase = (try? await Git.run(["merge-base", "HEAD", base], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mergeBase, !mergeBase.isEmpty else { return .unrelated(base) }
        return .since(mergeBase: mergeBase, base: base)
    }

    /// Tried in order when the default branch can't be used.
    nonisolated static let fallbackBases = ["origin/main", "origin/master", "main", "master"]

    /// What Branch compares with: `preferred` — MergedWorktrees.base, the
    /// default branch merged worktrees are judged by (origin/HEAD, else the
    /// main worktree's branch) — unless it is missing or is `current`
    /// itself; then the first of `fallbackBases` that exists and isn't. A
    /// repository pushed from a local init has no origin/HEAD, and its main
    /// checkout may be on a feature branch: that branch then gets main.
    /// MergedWorktrees.base itself stays as it is: clean-up relies on it.
    nonisolated static func branchBase(default preferred: String?, current: String?, existing: Set<String>) -> String? {
        func isCurrent(_ base: String) -> Bool { current.map { isBranch(base, $0) } ?? false }
        if let preferred, !isCurrent(preferred) { return preferred }
        return fallbackBases.first { existing.contains($0) && !isCurrent($0) }
    }

    /// Which of `names` (a branch, or origin/<branch>) exist.
    private static func existingRefs(_ names: [String], in root: URL) async -> Set<String> {
        let refs = names.map { $0.hasPrefix("origin/") ? "refs/remotes/\($0)" : "refs/heads/\($0)" }
        let listed = (try? await Git.run(["for-each-ref", "--format=%(refname)"] + refs, in: root)) ?? ""
        let found = Set(listed.split(separator: "\n").map(String.init))
        return Set(zip(names, refs).filter { found.contains($0.1) }.map(\.0))
    }

    /// `base` names `branch`: the branch itself, or its origin/ twin.
    nonisolated private static func isBranch(_ base: String, _ branch: String) -> Bool {
        base == branch || base == "origin/\(branch)"
    }

    /// Everything that differs from the merge-base: the tracked files git
    /// diff compares (committed, staged, unstaged; renames paired), and the
    /// untracked ones, already counted.
    private static func branchFiles(in root: URL, since mergeBase: String, untracked: [ChangedFile]) async -> [ChangedFile] {
        let names = (try? await Git.run(["diff", "--name-status", "-z", "-M", mergeBase], in: root)) ?? ""
        let numstat = (try? await Git.run(["diff", "--numstat", "-z", "-M", mergeBase], in: root)) ?? ""
        var files = await counted(GitStatus.parse(nameStatusZ: names), GitStatus.parse(numstatZ: numstat), in: root)
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
            loaded[file.path] = await Self.fileDiff(parsing: text, path: file.path)
        }
        guard ticket == generation else { return }
        diffs = loaded
    }

    /// Parses and styles a file's diff off the main thread: tokenizing a
    /// capped diff takes milliseconds, which a scroll can't spare.
    nonisolated static func fileDiff(parsing text: String, path: String) async -> FileDiff {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FileDiff(parsing: text, path: path))
            }
        }
    }

    // MARK: Folding

    /// More files changed than this, and cards start folded: the pane reads
    /// as a list of files with their counts, a click opening one.
    static let startFoldedAbove = 8

    func isFolded(_ path: String) -> Bool { folded[path] ?? startsFolded }

    /// How a card not shown before starts: as Collapse All or Expand All
    /// last said, else folded when the list is long.
    private var startsFolded: Bool { allFolded ?? (shownFiles.count > Self.startFoldedAbove) }

    /// Every card shown is folded: the header offers Expand All.
    var everyCardFolded: Bool { shownFiles.allSatisfy { isFolded($0.path) } }

    /// A click on a card's header.
    func toggleFold(_ path: String) { folded[path] = !isFolded(path) }

    /// The pane header's Collapse All: every card, and those shown later.
    func collapseAll() { foldAll(true) }

    /// The pane header's Expand All: every card, and those shown later.
    func expandAll() { foldAll(false) }

    private func foldAll(_ fold: Bool) {
        allFolded = fold
        folded = Dictionary(shownFiles.map { ($0.path, fold) }, uniquingKeysWith: { first, _ in first })
    }

    /// Settles how the cards shown for the first time start, so a refresh
    /// never folds or opens a card by itself: the list growing past 8 folds
    /// only the cards that come then — an open one may be being read. Only
    /// while the pane is open: a card never shown hasn't started, and the
    /// pane opened on many files is a list, however they came.
    private func settleFolds() {
        guard panelVisible else { return }
        let start = startsFolded
        let new = shownFiles.filter { folded[$0.path] == nil }
        guard !new.isEmpty else { return }
        var settled = folded
        for file in new { settled[file.path] = start }
        folded = settled
    }

    // MARK: Why

    /// What a file's card says about why it changed: what Claude said making
    /// its edits — the newest, or all once opened — and, in Branch, the
    /// commits that touched it.
    func why(for path: String) -> FileWhy {
        FileWhy(reasons: reasons[path] ?? [], commits: shownScope == .branch ? commitsByFile[path] ?? [] : [], open: openWhy.contains(path))
    }

    /// A click on a card's why: all of it, or back to the newest.
    func toggleWhy(_ path: String) {
        if openWhy.contains(path) { openWhy.remove(path) } else { openWhy.insert(path) }
    }

    /// Transcripts are read this far back when the branch gives no better
    /// point (on the default branch, before the first commit).
    nonisolated static let reasonsWindow: TimeInterval = 7 * 86_400

    /// Reads, off the main thread, what the checkout's Claude sessions said
    /// making their edits. One read at a time: asked again meanwhile, it
    /// reads once more when done — a burst of refreshes is two reads, and an
    /// agent writing all the time can't keep a slow first read from landing.
    /// Reads after the first parse only what the transcripts appended.
    private func readReasons() {
        guard panelVisible, let root, let transcripts else { return }
        guard !readingReasons else {
            readReasonsAgain = true
            return
        }
        readingReasons = true
        let ticket = reasonsGeneration
        let mergeBase = comparison?.mergeBase
        Task {
            let since = await Self.reasonsSince(mergeBase: mergeBase, in: root)
            let main = await Self.mainWorktree(of: root)
            let read = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let edits = transcripts.edits(in: [root.path], exactly: main.map { [$0] } ?? [], since: since)
                    continuation.resume(returning: ClaudeEdits.byFile(edits, root: root, since: since))
                }
            }
            readingReasons = false
            if ticket == reasonsGeneration, read != reasons { reasons = read }
            if readReasonsAgain {
                readReasonsAgain = false
                readReasons()
            }
        }
    }

    /// Since when an edit can be about this checkout's changes: since the
    /// branch left its base — the merge-base, or its oldest commit if older
    /// (a rebase moves the merge-base on, not the work) — else a week back.
    /// Older transcripts aren't read at all, so a long history stays cheap.
    nonisolated static func reasonsSince(mergeBase: String?, in root: URL, now: Date = Date()) async -> Date {
        let fallback = now.addingTimeInterval(-reasonsWindow)
        guard let mergeBase,
            let times = try? await Git.run(["log", "--boundary", "--no-show-signature", "--format=%at %ct", "\(mergeBase)..HEAD"], in: root)
        else { return fallback }
        return times.split(whereSeparator: \.isWhitespace).compactMap { TimeInterval($0) }.min().map(Date.init(timeIntervalSince1970:)) ?? fallback
    }

    /// The repository's main checkout, when `root` is another worktree of
    /// it: a session started there and moved here (EnterWorktree) keeps its
    /// transcript under the main checkout's name.
    nonisolated static func mainWorktree(of root: URL) async -> String? {
        guard let listed = try? await Git.run(["worktree", "list", "--porcelain"], in: root),
            let main = Worktree.parse(porcelain: listed).first(where: \.isMain), !main.isBare,
            ClaudeEdits.canonical(main.path.path) != ClaudeEdits.canonical(root.path)
        else { return nil }
        return main.path.path
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
        await perform(["commit", "-m", message], timeout: nil)
    }

    /// Nothing staged: stage everything, then commit — Warp's one-button path.
    func commitAll(message: String) async -> Bool {
        guard await perform(["add", "--all"]) else { return false }
        return await perform(["commit", "-m", message], timeout: nil)
    }

    @discardableResult
    private func perform(_ arguments: [String], timeout: TimeInterval? = Git.defaultTimeout) async -> Bool {
        guard let root else { return false }
        defer { Task { await refresh() } }
        do {
            _ = try await Git.run(arguments, in: root, timeout: timeout)
            actionError = nil
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}

/// Why a file changed, as its card shows it.
struct FileWhy: Equatable {
    /// What Claude said making its edits, newest first.
    let reasons: [ClaudeEdit]
    /// The branch's commits that touched it (Branch only), newest first.
    let commits: [BranchCommit]
    /// Opened: every reason, in full; else the newest, in two lines.
    let open: Bool

    /// Nothing to say: no strip at all.
    var isEmpty: Bool { reasons.isEmpty && commits.isEmpty }
    var shownReasons: [ClaudeEdit] { open ? reasons : Array(reasons.prefix(1)) }
    /// Reasons a click would show.
    var hiddenReasons: Int { reasons.count - shownReasons.count }
}
