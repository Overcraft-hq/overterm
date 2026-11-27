import Combine
import Foundation

/// What Overgit knows about the checkout you are in: its history, its
/// branches, its stashes, its tags, its remotes.
///
/// Laziness is the whole design. The panel is one of five in the sidebar
/// and most of the time it is not the one on screen, so nothing is read
/// unless the panel is showing **and** the section asking is open — the
/// inbox's rule ("the column is only polled while it is open"), applied a
/// section at a time. Opening a section reads just that section; closing
/// one keeps what it had, because reopening it should not blink.
///
/// Pull requests are not read here at all: `WorktreeModel` already asks
/// `gh` once a minute for the whole repository, and a second asker would
/// double the rate limit for the same answer.
@MainActor
package final class OvergitModel: ObservableObject {
    /// The panel's collapsible parts, in the order they are drawn. The
    /// overview above them is not one: it is always there.
    package enum Section: String, CaseIterable, Identifiable {
        case changes, commits, branches, pullRequests, worktrees, stashes, tags, remotes

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .changes: "Changes"
            case .commits: "Commits"
            case .branches: "Branches"
            case .pullRequests: "Pull Requests"
            case .worktrees: "Worktrees"
            case .stashes: "Stashes"
            case .tags: "Tags"
            case .remotes: "Remotes"
            }
        }

        package var symbol: String {
            switch self {
            case .changes: "plusminus.circle"
            case .commits: "clock.arrow.circlepath"
            case .branches: "arrow.triangle.branch"
            case .pullRequests: "arrow.triangle.pull"
            case .worktrees: "square.split.2x1"
            case .stashes: "tray.full"
            case .tags: "tag"
            case .remotes: "cloud"
            }
        }

        /// Asked of git, rather than of something the window already has.
        /// The changes are DiffModel's, the pull requests and worktrees WorktreeModel's.
        package var isRead: Bool { self != .pullRequests && self != .worktrees && self != .changes }
    }

    private static let sectionsKey = "overgitSections"
    private static let defaultSections: Set<Section> = [.changes, .commits, .branches, .pullRequests, .worktrees]

    @Published package private(set) var commits: [Commit] = []
    @Published package private(set) var graph: [GraphRow] = []
    @Published package private(set) var branches: [BranchRef] = []
    @Published package private(set) var stashes: [Stash] = []
    @Published package private(set) var tags: [TagRef] = []
    @Published package private(set) var remotes: [Remote] = []
    /// The folder is not in a repository: the panel says so instead of
    /// showing seven empty sections.
    @Published package private(set) var isRepository = false
    /// What git said when it refused, in its own words.
    @Published package private(set) var error: String?
    @Published package private(set) var isReading = false
    /// The checked-out branch against its upstream, for Pull and Push —
    /// read every refresh, whichever sections are open.
    @Published package private(set) var tracking = BranchTracking()
    /// A merge, rebase, cherry-pick or revert stopped half way.
    @Published package private(set) var inProgress: GitInProgress?
    /// What a command of the panel's is doing ("Pulling…"), while it runs.
    @Published package var running: String?
    /// Which sections are open, remembered between launches.
    @Published package private(set) var expanded: Set<Section>
    /// Which folders of the branch tree are open (`feature`, `origin`).
    @Published package var expandedBranchFolders: Set<String> = []
    /// The Branches section's filter: the names holding its words.
    @Published package var branchQuery = ""
    /// The commit whose detail the right-hand pane is showing.
    @Published package var selected: String?

    /// The Commits section's search (CommitSearch): the commits already read
    /// filter at once, and `git log` searches the whole history after a pause.
    @Published package var commitQuery = "" {
        didSet { if commitQuery != oldValue { searchCommits() } }
    }
    /// A branch, tag or commit picked with "Select for Compare".
    @Published package var compareBase: String?
    /// A commit picked as one end of a run to review (Review from Here…).
    @Published package var reviewStart: Commit?
    /// What the search found — nil while there is no query.
    @Published package private(set) var searchResults: [Commit]?
    @Published package private(set) var isSearching = false
    private var search: Task<Void, Never>?

    /// Set while the panel is the one on screen and the sidebar is open.
    package var visible = false {
        didSet {
            guard visible != oldValue, visible else { return }
            Task { await refresh() }
        }
    }

    package private(set) var root: URL?
    /// Guards against two reads at once, and remembers that another was
    /// asked for while one ran — `UsageModel` and `DiffModel` both do this.
    private var reading = false
    private var again: Set<Section> = []

    package init() {
        let saved = AppEnvironment.defaults.stringArray(forKey: Self.sectionsKey)
        expanded = saved.map { Set($0.compactMap(Section.init(rawValue:))) } ?? Self.defaultSections
    }

    /// The checkout the panel is about — the same one the sidebar's file
    /// tree and the changes pane follow.
    package func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        commits = []
        graph = []
        branches = []
        stashes = []
        tags = []
        remotes = []
        error = nil
        isRepository = false
        selected = nil
        commitQuery = ""
        searchResults = nil
        guard visible else { return }
        Task { await refresh() }
    }

    package func isExpanded(_ section: Section) -> Bool { expanded.contains(section) }

    // MARK: The keyboard (A11Y-U2)

    /// What the keyboard can stand on: each section's title, and the
    /// commits under an open Commits — the search's when one is shown.
    package enum KeyItem: Hashable {
        case section(Section)
        case commit(String)
    }

    /// Where the keyboard is, while the panel has it.
    @Published package var keyFocus: KeyItem?

    package var keyItems: [KeyItem] {
        Section.allCases.flatMap { section -> [KeyItem] in
            guard section == .commits, isExpanded(.commits) else { return [.section(section)] }
            return [.section(section)] + (searchResults ?? commits).map { .commit($0.sha) }
        }
    }

    /// ↓/↑ (j/k): the next or previous item; a commit stood on is selected.
    package func moveKeyFocus(by step: Int) {
        let items = keyItems
        guard !items.isEmpty else { return }
        let at = keyFocus.flatMap { items.firstIndex(of: $0) }
        let next = at.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
        keyFocus = items[next]
        if case .commit(let sha) = items[next] { selected = sha }
    }

    /// → opens the section stood on, ← closes it — or, on a commit, closes
    /// its section and stands on its title.
    package func setKeySectionOpen(_ open: Bool) {
        switch keyFocus {
        case .section(let section) where isExpanded(section) != open: toggle(section)
        case .commit where !open:
            keyFocus = .section(.commits)
            if isExpanded(.commits) { toggle(.commits) }
        default: break
        }
    }

    /// The commit the keyboard stands on.
    package var keyCommit: Commit? {
        guard case .commit(let sha) = keyFocus else { return nil }
        return (searchResults ?? commits).first { $0.sha == sha }
    }

    /// Opening a section reads it; closing one keeps what it read.
    package func toggle(_ section: Section) {
        if expanded.contains(section) {
            expanded.remove(section)
        } else {
            expanded.insert(section)
            if visible { Task { await refresh([section]) } }
        }
        AppEnvironment.defaults.set(expanded.map(\.rawValue).sorted(), forKey: Self.sectionsKey)
    }

    /// `sections` nil means every open one.
    package func refresh(_ sections: Set<Section>? = nil) async {
        guard let root, visible else { return }
        let wanted = (sections ?? Set(Section.allCases)).intersection(expanded).filter(\.isRead)
        guard !wanted.isEmpty || sections == nil else { return }
        guard !reading else {
            again.formUnion(wanted)
            return
        }
        reading = true
        isReading = true
        defer {
            reading = false
            isReading = false
            // A section opened while this read ran is read next — however
            // this one ended: an early return used to drop it, and the
            // section stayed empty.
            let pending = again
            again = []
            if !pending.isEmpty { Task { await refresh(pending) } }
        }

        let inside =
            (try? await Git.run(["rev-parse", "--is-inside-work-tree"], in: root))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard root.standardizedFileURL == self.root?.standardizedFileURL else { return }
        isRepository = inside
        guard inside else {
            error = nil
            return
        }

        // Cheap, and what the overview's buttons and banner stand on.
        let upstream = try? await Git.run(BranchTracking.arguments, in: root)
        let counts = upstream == nil ? nil : try? await Git.run(BranchTracking.countArguments, in: root)
        let gitDir = (try? await Git.run(["rev-parse", "--absolute-git-dir"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root.standardizedFileURL == self.root?.standardizedFileURL else { return }
        let nowTracking = BranchTracking.parse(upstream: upstream, counts: counts)
        if tracking != nowTracking { tracking = nowTracking }
        let state = gitDir.flatMap { GitInProgress.read(gitDir: URL(fileURLWithPath: $0)) }
        if inProgress != state { inProgress = state }

        var failure: String?
        func run(_ arguments: [String]) async -> String? {
            do {
                return try await Git.run(arguments, in: root, outputLimit: 8 << 20)
            } catch let error as GitError {
                failure = failure ?? error.stderr.split(separator: "\n").first.map(String.init)
                return nil
            } catch {
                return nil
            }
        }

        let limit = Settings.shared.overgitCommits
        let allRefs = Settings.shared.overgitAllRefs
        var read: [Section: String] = [:]
        for section in Section.allCases where wanted.contains(section) {
            switch section {
            case .commits: read[.commits] = await run(CommitLog.arguments(limit: limit, allRefs: allRefs))
            case .branches: read[.branches] = await run(Refs.branchArguments())
            case .stashes: read[.stashes] = await run(Stashes.arguments)
            case .tags: read[.tags] = await run(Refs.tagArguments())
            case .remotes: read[.remotes] = await run(Refs.remoteArguments)
            case .pullRequests, .worktrees, .changes: break
            }
        }
        // A tab switch may have moved the root while git ran.
        guard root.standardizedFileURL == self.root?.standardizedFileURL else { return }

        if let output = read[.commits] {
            commits = CommitLog.parse(output)
            graph = GraphLayout.rows(for: commits)
        }
        if let output = read[.branches] { branches = Refs.parse(branches: output) }
        if let output = read[.stashes] { stashes = Stashes.parse(output) }
        if let output = read[.tags] { tags = Refs.parse(tags: output) }
        if let output = read[.remotes] { remotes = Refs.parse(remotes: output) }
        error = failure
    }

    // MARK: Searching the history

    private func searchCommits() {
        search?.cancel()
        let query = CommitSearch(commitQuery)
        guard !query.isEmpty, let root else {
            searchResults = nil
            isSearching = false
            return
        }
        // At once, from what is read; git's answer replaces it.
        searchResults = commits.filter(query.matches)
        isSearching = true
        let allRefs = Settings.shared.overgitAllRefs
        let limit = max(200, Settings.shared.overgitCommits)
        search = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            var found = CommitLog.parse((try? await Git.run(query.arguments(limit: limit, allRefs: allRefs), in: root, outputLimit: 8 << 20)) ?? "")
            // A hash, from anywhere in the repository.
            if let sha = query.possibleSHA, !found.contains(where: { $0.sha.hasPrefix(sha) }),
                let output = try? await Git.run(CommitShow.headerArguments(sha), in: root)
            {
                found = CommitLog.parse(output) + found
            }
            guard let self, !Task.isCancelled, root == self.root else { return }
            self.searchResults = found
            self.isSearching = false
        }
    }

    /// The branch's own row, for the overview card's ahead/behind.
    package func branch(named name: String?) -> BranchRef? {
        guard let name else { return nil }
        return branches.first { !$0.isRemote && $0.name == name }
    }

    /// The commit a row shows, with the graph row beside it. Both lists are
    /// built from the same read, so they are the same length — but a view
    /// must not crash if a refresh lands between two draws.
    package func graphRow(at index: Int) -> GraphRow? {
        index < graph.count ? graph[index] : nil
    }

    package var gutterLanes: Int { GraphLayout.width(of: graph) }
}
