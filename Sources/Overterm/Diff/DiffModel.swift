import Combine
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
package final class DiffModel: ObservableObject {
    package struct FileDiff {
        package let lines: [DiffLine]
        package let truncated: Bool
        /// Each line's syntax colours and changed part, by `DiffLine.id`;
        /// lines with neither are left out.
        package let styles: [Int: DiffLineStyle]
        /// Each hunk's own patch, by its `@@` line's id: what Stage,
        /// Unstage and Discard of that hunk apply (GIT-G1). None for a
        /// diff against a base — a branch's, a commit's.
        package private(set) var hunks: [Int: DiffHunk] = [:]
        /// Staged and not staged both: the id of the first line not staged,
        /// where the card says so.
        package private(set) var unstagedFrom: Int?

        /// A file's `git diff`: its hunks and their lines (the card's header
        /// already names the file), at most `limit`, each styled — the
        /// work done once as the diff loads, never while drawing.
        package init(parsing diff: String, path: String, limit: Int = DiffModel.maxDiffLines) {
            let parsed = UnifiedDiff.parse(diff, limit: limit)
            lines = parsed.lines.filter { $0.kind != .meta || $0.text.hasPrefix("\\") }
            truncated = parsed.truncated
            styles = DiffHighlight.styles(for: lines, language: SyntaxHighlighter.language(for: URL(fileURLWithPath: path)))
        }

        /// An uncommitted file's: what is staged (HEAD to the index), then
        /// what isn't (the index to the file), each hunk with its patch.
        package init(staged: String, unstaged: String, path: String, limit: Int = DiffModel.maxDiffLines) {
            self.init(parsing: staged + unstaged, path: path, limit: limit)
            let patches =
                DiffPatch.patches(staged).map { DiffHunk(side: .staged, patch: $0) } + DiffPatch.patches(unstaged).map { DiffHunk(side: .unstaged, patch: $0) }
            let headers = lines.filter { $0.kind == .hunk }
            hunks = Dictionary(zip(headers.map(\.id), patches).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
            let stagedCount = DiffPatch.split(staged).hunks.count
            if stagedCount > 0, stagedCount < headers.count { unstagedFrom = headers[stagedCount].id }
        }

        package func style(of line: DiffLine) -> DiffLineStyle { styles[line.id] ?? DiffLineStyle() }

        /// Whether the card's lines begin with the staged part.
        package var startsStaged: Bool { hunks.values.contains { $0.side == .staged } }
    }

    /// One hunk of an uncommitted file, and which side of the index it is.
    package struct DiffHunk: Equatable, Sendable {
        package enum Side: Sendable { case staged, unstaged }
        package let side: Side
        /// The file's header and this hunk: a patch of its own.
        package let patch: String
    }

    package enum Scope: String {
        case uncommitted, branch
    }

    /// What `.branch` compares the working tree with — or why it can't.
    package enum BranchComparison: Equatable {
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

        package var mergeBase: String? {
            if case .since(let mergeBase, _) = self { mergeBase } else { nil }
        }

        /// Why `.branch` can't be shown; nil when it can.
        package var unavailable: String? {
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
    package enum Badge: Equatable {
        case uncommitted(added: Int, removed: Int)
        case branch(added: Int, removed: Int)
        case plain

        /// The scope whose totals it shows — the one a click on it opens;
        /// none for the plain ±.
        package var scope: Scope? {
            switch self {
            case .uncommitted: .uncommitted
            case .branch: .branch
            case .plain: nil
            }
        }
    }

    @Published package private(set) var root: URL?
    /// Why this checkout is the one shown (set by the window).
    @Published package var showing: CheckoutReason = .shell
    /// Uncommitted: staged, unstaged and untracked, against HEAD.
    @Published package private(set) var files: [ChangedFile] = []
    /// Everything since the branch left its base, committed or not.
    @Published package private(set) var branchFiles: [ChangedFile] = []
    /// The branch's commits since then, newest first.
    @Published package private(set) var commits: [BranchCommit] = []
    /// There were more than `maxCommits`.
    @Published package private(set) var moreCommits = false
    /// nil until the checkout's first refresh.
    @Published package private(set) var comparison: BranchComparison?
    /// The one picked in the pane (`choose`); remembered.
    @Published package private(set) var scope: Scope
    @Published package private(set) var branch: String?
    /// HEAD's commit; set only when it moves.
    @Published package private(set) var head: String?
    /// Bumped when git wrote a remote-tracking ref (a fetch, a push): the
    /// rail's GitOps answers compared with `origin/<branch>` look again.
    /// Read from the watchers' paths — no git.
    @Published package private(set) var remoteRefsMoved = 0
    @Published package private(set) var diffs: [String: FileDiff] = [:]
    /// Folded or not, by path: how each card started when first shown in
    /// the pane, or how the user left it. Kept while the pane stays on this
    /// checkout, in either scope; another starts afresh.
    @Published package private(set) var folded: [String: Bool] = [:]
    /// Collapse All / Expand All: how the cards shown after it start.
    private var allFolded: Bool?
    /// Cards whose why the user opened: every reason, in full.
    @Published package private(set) var openWhy: Set<String> = []
    @Published package private(set) var error: String?
    /// Why each file changed, by path: what Claude said making its edits,
    /// newest first (ClaudeEdits.byFile) — from the checkout's session
    /// transcripts, read only while the panel is open.
    @Published package private(set) var reasons: [String: [ClaudeEdit]] = [:]
    /// The branch's commits that touched each file, newest first.
    @Published package private(set) var commitsByFile: [String: [BranchCommit]] = [:]

    /// Published: the pane renders nothing while hidden (RightPaneView).
    @Published package var panelVisible = false {
        didSet {
            guard panelVisible != oldValue, panelVisible else { return }
            Task { await refresh() }
        }
    }

    /// Lines of one file's diff shown at most.
    package nonisolated static let maxDiffLines = 3_000
    /// Commits listed at most: a base far behind is no reason to parse
    /// thousands on every refresh.
    package static let maxCommits = 100
    /// git's well-known empty tree: the base before a repository's first commit.
    package static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    /// The picked scope, in AppEnvironment.defaults.
    package static let scopeKey = "diffScope"

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

    package init(defaults: UserDefaults = AppEnvironment.defaults, transcripts: ClaudeEditsReader? = nil) {
        self.defaults = defaults
        self.transcripts = transcripts
        scope = defaults.string(forKey: Self.scopeKey).flatMap(Scope.init(rawValue:)) ?? .uncommitted
    }

    /// The pane's Uncommitted | Branch switch.
    package func choose(_ scope: Scope) {
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
    package var shownScope: Scope { scope == .branch && comparison?.mergeBase != nil ? .branch : .uncommitted }
    package var shownFiles: [ChangedFile] { shownScope == .branch ? branchFiles : files }

    package var totals: (added: Int, removed: Int) { Self.totals(files) }
    package var shownTotals: (added: Int, removed: Int) { Self.totals(shownFiles) }

    package nonisolated static func totals(_ files: [ChangedFile]) -> (added: Int, removed: Int) {
        files.reduce(into: (0, 0)) { sum, file in
            sum.0 += file.added ?? 0
            sum.1 += file.removed ?? 0
        }
    }

    /// Under the switch when Branch is picked: what it compares with, or
    /// why there is nothing to compare with.
    package var scopeNote: String? {
        guard scope == .branch, let comparison else { return nil }
        guard case .since(_, let base) = comparison else { return comparison.unavailable }
        return "Since \(base) · \(Self.commitCount(commits.count, more: moreCommits))"
    }

    package nonisolated static func commitCount(_ count: Int, more: Bool) -> String {
        if more { return "\(count)+ commits" }
        switch count {
        case 0: return "no commits yet"
        case 1: return "1 commit"
        default: return "\(count) commits"
        }
    }

    /// A refresh worked (it always sets `comparison`): a git repository.
    /// Whether the folder being watched is in a repository at all.
    /// `root` is not that question — it is set to whatever folder the tab
    /// is in, repository or not, and reading it as "there is a checkout"
    /// offered the Ask Agent sheet a git diff anywhere.
    package var isRepository: Bool { error == nil && comparison != nil }

    package var badge: Badge? { Self.badge(isRepository: isRepository, uncommitted: files, branch: branchFiles) }

    /// In any repository, so the pane is one click away: what is uncommitted
    /// while there is some, else the branch's totals — the agent's work stays
    /// in sight after it commits — else a plain ±.
    package nonisolated static func badge(isRepository: Bool, uncommitted: [ChangedFile], branch: [ChangedFile]) -> Badge? {
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
    package func setRoot(_ url: URL?) {
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
        head = nil
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
        watcher = DirectoryWatcher(root: url, latency: 0.2) { [weak self] paths in self?.changed(paths) }
        let directories = await Self.gitDirectories(outside: url)
        // The tab may have moved on while git answered.
        guard url == root, !directories.isEmpty else { return }
        gitWatcher = DirectoryWatcher(roots: directories, latency: 0.2) { [weak self] paths in self?.changed(paths) }
    }

    private func changed(_ paths: [String]) {
        if paths.contains(where: Self.isRemoteRef) { remoteRefsMoved &+= 1 }
        let counted = paths.filter { !Self.isNoise($0) }
        guard !counted.isEmpty else { return }
        changes.send(counted)
        scheduleRefresh()
    }

    /// What the watchers saw change, noise aside: the Terraform panel's
    /// "files changed", rather than a second watcher on the checkout.
    package let changes = PassthroughSubject<[String], Never>()
    /// Refreshes run: a scenario checks `init`'s writes cost none.
    package private(set) var refreshCount = 0

    /// A folder FSEvents reports whose changes say nothing about the
    /// checkout: what `terraform init` writes under `.terraform/` (~50 MB of
    /// providers) and Terragrunt's cache. Under `.terraform/`, only the
    /// folder itself (its `environment`, `terraform.tfstate`) and `modules/`
    /// count (analysis 4.12 step 6).
    package nonisolated static func isNoise(_ reported: String) -> Bool {
        // FSEvents ends a folder's path with "/".
        let path = reported.hasSuffix("/") ? String(reported.dropLast()) : reported
        if path.contains("/.terragrunt-cache/") || path.hasSuffix("/.terragrunt-cache") { return true }
        guard let range = path.range(of: "/.terraform/") else { return false }
        let below = path[range.upperBound...]
        return !(below == "modules" || below.hasPrefix("modules/"))
    }

    /// A directory FSEvents reports (a directory, not a file) that holds
    /// remote-tracking refs: a fetch writes `refs/remotes/<remote>/<branch>` loose.
    package nonisolated static func isRemoteRef(_ path: String) -> Bool {
        path.contains("/refs/remotes/") || path.hasSuffix("/refs/remotes")
    }

    /// Where git keeps this checkout's state, when that is not inside it: the
    /// worktree's own git directory (index, HEAD, its reflog) and the
    /// repository's refs/ (its branch, origin/HEAD). A main checkout's .git
    /// is inside it, so none.
    package nonisolated static func gitDirectories(outside root: URL) async -> [URL] {
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
    package func refresh() async {
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
        refreshCount += 1
        generation += 1
        let ticket = generation
        do {
            let status = try await Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
            let headCommit = (try? await Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasHead = headCommit != nil
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
            if self.head != headCommit { self.head = headCommit }
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
    package nonisolated static let fallbackBases = ["origin/main", "origin/master", "main", "master"]

    /// What Branch compares with: `preferred` — MergedWorktrees.base, the
    /// default branch merged worktrees are judged by (origin/HEAD, else the
    /// main worktree's branch) — unless it is missing or is `current`
    /// itself; then the first of `fallbackBases` that exists and isn't. A
    /// repository pushed from a local init has no origin/HEAD, and its main
    /// checkout may be on a feature branch: that branch then gets main.
    /// MergedWorktrees.base itself stays as it is: clean-up relies on it.
    package nonisolated static func branchBase(default preferred: String?, current: String?, existing: Set<String>) -> String? {
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
    package nonisolated static func lineCount(_ url: URL) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= 1_048_576,
            let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0)
        else { return nil }
        if data.isEmpty { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return data.last == 0x0A ? newlines : newlines + 1
    }

    /// The open cards' diffs, read again — a folded card's is read when it
    /// opens (GIT-G10): no cap on the files, and nothing read for a card
    /// nobody is looking at.
    private func loadDiffs(head: String, ticket: Int) async {
        let open = shownFiles.filter { !isFolded($0.path) }
        var loaded: [String: FileDiff] = [:]
        for file in open {
            guard let diff = await readDiff(of: file) else { continue }
            loaded[file.path] = diff
        }
        guard ticket == generation else { return }
        diffs = loaded
    }

    /// One card's diff, read as it opens: shown at once when it comes.
    private func loadDiff(of path: String) {
        guard panelVisible, diffs[path] == nil, let file = shownFiles.first(where: { $0.path == path }) else { return }
        let ticket = generation
        Task {
            guard let diff = await readDiff(of: file), ticket == generation, !isFolded(path) else { return }
            diffs[path] = diff
        }
    }

    /// What a card shows. Uncommitted: what is staged, then what isn't,
    /// each hunk with its patch — Stage, Unstage and Discard act on one;
    /// an untracked file whole. Branch: against the merge-base.
    private func readDiff(of file: ChangedFile) async -> FileDiff? {
        guard let root else { return nil }
        func diff(_ arguments: [String]) async -> String { (try? await Git.run(arguments, in: root, success: [0, 1])) ?? "" }
        let paths = file.kind == .renamed ? [file.originalPath ?? file.path, file.path] : [file.path]
        if shownScope == .branch, let mergeBase = comparison?.mergeBase {
            let text = await diff(
                file.kind == .untracked
                    ? ["diff", "--no-color", "--no-index", "--", "/dev/null", file.path]
                    : [Git.literalPathspecs, "diff", "--no-color", "-M", mergeBase, "--"] + paths)
            return await Self.fileDiff(parsing: text, path: file.path)
        }
        if file.kind == .untracked {
            return await Self.fileDiff(parsing: await diff(["diff", "--no-color", "--no-index", "--", "/dev/null", file.path]), path: file.path)
        }
        // Before the first commit, --cached compares with the empty tree.
        let staged = await diff(Self.uncommittedDiffArguments(staged: true, paths: paths))
        let unstaged = await diff(Self.uncommittedDiffArguments(staged: false, paths: [file.path]))
        return await Self.fileDiff(staged: staged, unstaged: unstaged, path: file.path)
    }

    /// An uncommitted card's two diffs, whose hunks become patches `git
    /// apply` takes back: each name a plain one (`page[1].txt` would match
    /// `page1.txt` too, and the patch would carry the other file's hunks),
    /// and `a/`/`b/` whatever `diff.noprefix` or `diff.mnemonicPrefix` say
    /// (apply strips one component: without them it patches another
    /// path). Pure.
    package nonisolated static func uncommittedDiffArguments(staged: Bool, paths: [String]) -> [String] {
        [Git.literalPathspecs, "diff", "--no-color", "--default-prefix"] + (staged ? ["--cached", "-M"] : []) + ["--"] + paths
    }

    /// Parses and styles a file's diff off the main thread: tokenizing a
    /// capped diff takes milliseconds, which a scroll can't spare.
    package nonisolated static func fileDiff(parsing text: String, path: String, limit: Int = maxDiffLines) async -> FileDiff {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FileDiff(parsing: text, path: path, limit: limit))
            }
        }
    }

    package nonisolated static func fileDiff(staged: String, unstaged: String, path: String) async -> FileDiff {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FileDiff(staged: staged, unstaged: unstaged, path: path))
            }
        }
    }

    // MARK: Folding

    /// More files changed than this, and cards start folded: the pane reads
    /// as a list of files with their counts, a click opening one.
    package static let startFoldedAbove = 8

    package func isFolded(_ path: String) -> Bool { folded[path] ?? startsFolded }

    /// How a card not shown before starts: as Collapse All or Expand All
    /// last said, else folded when the list is long.
    private var startsFolded: Bool { allFolded ?? (shownFiles.count > Self.startFoldedAbove) }

    /// Every card shown is folded: the header offers Expand All.
    package var everyCardFolded: Bool { shownFiles.allSatisfy { isFolded($0.path) } }

    /// A click on a card's header: opened, its diff is read.
    package func toggleFold(_ path: String) {
        folded[path] = !isFolded(path)
        if !isFolded(path) { loadDiff(of: path) }
    }

    /// A file asked for from elsewhere (Overgit): unfolded, and the pane
    /// scrolls to it.
    @Published package private(set) var revealed: (path: String, ticket: Int)?
    private var revealTicket = 0

    package func reveal(_ path: String) {
        if scope != .uncommitted { choose(.uncommitted) }
        folded[path] = false
        loadDiff(of: path)
        revealTicket += 1
        revealed = (path, revealTicket)
    }

    /// The pane header's Collapse All: every card, and those shown later.
    package func collapseAll() { foldAll(true) }

    /// The pane header's Expand All: every card, and those shown later.
    package func expandAll() { foldAll(false) }

    private func foldAll(_ fold: Bool) {
        allFolded = fold
        folded = Dictionary(shownFiles.map { ($0.path, fold) }, uniquingKeysWith: { first, _ in first })
        if !fold { shownFiles.forEach { loadDiff(of: $0.path) } }
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
    package func why(for path: String) -> FileWhy {
        FileWhy(reasons: reasons[path] ?? [], commits: shownScope == .branch ? commitsByFile[path] ?? [] : [], open: openWhy.contains(path))
    }

    /// A click on a card's why: all of it, or back to the newest.
    package func toggleWhy(_ path: String) {
        if openWhy.contains(path) { openWhy.remove(path) } else { openWhy.insert(path) }
    }

    /// Transcripts are read this far back when the branch gives no better
    /// point (on the default branch, before the first commit).
    package nonisolated static let reasonsWindow: TimeInterval = 7 * 86_400

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
    package nonisolated static func reasonsSince(mergeBase: String?, in root: URL, now: Date = Date()) async -> Date {
        let fallback = now.addingTimeInterval(-reasonsWindow)
        guard let mergeBase,
            let times = try? await Git.run(["log", "--boundary", "--no-show-signature", "--format=%at %ct", "\(mergeBase)..HEAD"], in: root)
        else { return fallback }
        return times.split(whereSeparator: \.isWhitespace).compactMap { TimeInterval($0) }.min().map(Date.init(timeIntervalSince1970:)) ?? fallback
    }

    /// The repository's main checkout, when `root` is another worktree of
    /// it: a session started there and moved here (EnterWorktree) keeps its
    /// transcript under the main checkout's name.
    package nonisolated static func mainWorktree(of root: URL) async -> String? {
        guard let listed = try? await Git.run(["worktree", "list", "--porcelain"], in: root),
            let main = Worktree.parse(porcelain: listed).first(where: \.isMain), !main.isBare,
            ClaudeEdits.canonical(main.path.path) != ClaudeEdits.canonical(root.path)
        else { return nil }
        return main.path.path
    }

    // MARK: Staging and committing

    /// Set when a stage/discard/commit fails; shown in the panel.
    @Published package var actionError: String?

    package var stagedCount: Int { files.filter(\.isStaged).count }

    /// Stages the whole file, or unstages it if it is fully staged.
    package func toggleStaged(_ file: ChangedFile) async {
        if file.stageState == .full { await unstage(file) } else { await stage(file) }
    }

    package func stage(_ file: ChangedFile) async { await perform(["add", "--", file.path]) }

    /// A newly added file isn't in HEAD (and before the first commit there
    /// is no HEAD), so `restore --staged` can't apply: drop it from the index.
    /// --force because git refuses --cached when the index differs from both
    /// HEAD and the file (added, then edited); --cached never touches the file.
    package func unstage(_ file: ChangedFile) async {
        await perform(file.kind == .added ? ["rm", "--cached", "--force", "--quiet", "--", file.path] : ["restore", "--staged", "--", file.path])
    }

    package func stageAll() async { await perform(["add", "--all"]) }

    /// Everything out of the index, the files left as they are.
    package func unstageAll() async {
        guard let root else { return }
        // Before the first commit there is no HEAD to restore from.
        let hasHead = (try? await Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)) != nil
        await perform(hasHead ? ["restore", "--staged", "--", "."] : ["rm", "-r", "--cached", "--quiet", "--", "."])
    }

    /// The last commit's message — what Amend starts from.
    package func lastCommitMessage() async -> String? {
        guard let root else { return nil }
        return (try? await Git.run(["log", "-1", "--format=%B"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pushes the branch — to its upstream, or, the first time, to origin
    /// as its upstream (what `git push` would tell you to do).
    @discardableResult
    package func push() async -> Bool {
        guard let root else { return false }
        let upstream = (try? await Git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root)) != nil
        return await perform(upstream ? ["push"] : ["push", "--set-upstream", "origin", "HEAD"], timeout: nil)
    }

    /// Throws the file's changes away: back to HEAD, staged and unstaged. A
    /// file HEAD doesn't have (untracked, or newly added) goes to the Trash,
    /// not oblivion.
    package func discard(_ file: ChangedFile) async {
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

    /// What a hunk's button does.
    package enum HunkAction: Sendable { case stage, unstage, discard }

    /// One hunk into the index, out of it, or out of the file (Discard,
    /// asked first by the pane): its own patch applied — to the index, or
    /// reversed (GIT-G1). The patch is written to a file of its own:
    /// `Git.run` hands no input.
    @discardableResult
    package func apply(_ hunk: DiffHunk, _ action: HunkAction) async -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-hunk-\(UUID().uuidString).patch")
        do {
            try Data(hunk.patch.utf8).write(to: file)
        } catch {
            actionError = error.localizedDescription
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return await perform(Self.applyArguments(action, patch: file.path))
    }

    /// `git apply` for a hunk's patch: Stage puts it in the index; Unstage
    /// takes it back out (a staged hunk's patch, reversed); Discard takes it
    /// out of the file (an unstaged one's, reversed). Pure.
    package nonisolated static func applyArguments(_ action: HunkAction, patch: String) -> [String] {
        switch action {
        case .stage: ["apply", "--cached", "--whitespace=nowarn", patch]
        case .unstage: ["apply", "--cached", "--reverse", "--whitespace=nowarn", patch]
        case .discard: ["apply", "--reverse", "--whitespace=nowarn", patch]
        }
    }

    /// Commits what is staged. Returns whether it worked (the panel clears
    /// its message field then).
    package func commit(message: String, amend: Bool = false) async -> Bool {
        await perform(["commit", "-m", message] + (amend ? ["--amend"] : []), timeout: nil)
    }

    /// Nothing staged: stage everything, then commit — Warp's one-button path.
    package func commitAll(message: String, amend: Bool = false) async -> Bool {
        guard await perform(["add", "--all"]) else { return false }
        return await perform(["commit", "-m", message] + (amend ? ["--amend"] : []), timeout: nil)
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
package struct FileWhy: Equatable {
    /// What Claude said making its edits, newest first.
    package let reasons: [ClaudeEdit]
    /// The branch's commits that touched it (Branch only), newest first.
    package let commits: [BranchCommit]
    /// Opened: every reason, in full; else the newest, in two lines.
    package let open: Bool

    /// A card with no strip at all — a commit's files, for one.
    package static let none = FileWhy(reasons: [], commits: [], open: false)

    /// Nothing to say: no strip at all.
    package var isEmpty: Bool { reasons.isEmpty && commits.isEmpty }
    package var shownReasons: [ClaudeEdit] { open ? reasons : Array(reasons.prefix(1)) }
    /// Reasons a click would show.
    package var hiddenReasons: Int { reasons.count - shownReasons.count }
}
