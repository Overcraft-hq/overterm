import Foundation

/// One review: what a branch, some commits or a pull request changed, a
/// file at a time — the list read at once, each file's diff when it is
/// looked at (and the next one ahead of that), so a review of hundreds of
/// files opens as fast as one of three.
///
/// git's sources are read with git; a pull request with `gh pr diff`, the
/// whole patch at once (GitHub's own cut), so it needs nothing of the
/// branch here.
@MainActor
final class ReviewModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
    }

    enum Layout: String {
        case split, unified
    }

    /// Lines of one file's diff shown at most: a review is for reading, so
    /// more than the changes pane's — still a bound for a generated file.
    static let maxLines = 20_000
    static let layoutKey = "reviewLayout"

    let id = UUID()
    let root: URL
    let source: ReviewSource

    @Published private(set) var phase: Phase = .loading
    /// In the order the list shows them: by folder, then name.
    @Published private(set) var files: [ChangedFile] = []
    @Published private(set) var diffs: [String: DiffModel.FileDiff] = [:]
    /// Each file's diff side by side, laid out once.
    private(set) var rows: [String: [SplitDiff.Row]] = [:]
    /// A file's diff that couldn't be read, and why.
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var selected: String?
    /// Marked as read — this review's alone, as GitHub's "Viewed".
    @Published private(set) var viewed: Set<String> = []
    @Published var layout: Layout {
        didSet { defaults.set(layout.rawValue, forKey: Self.layoutKey) }
    }
    /// The pull request, for the header (title, author, branches, checks).
    @Published private(set) var pullRequest: PullRequestDetail?
    /// The change (`n`/`p`) to bring into view: its first line's id. The
    /// view scrolls when it changes.
    @Published private(set) var scrollTarget: Int?

    /// Each file's patch, for a pull request: `gh pr diff` gives them all.
    private var patches: [String: String] = [:]
    private var loading: Set<String> = []
    private let defaults: UserDefaults
    /// The commit `.commits` is compared with: `from`'s first parent.
    private var commitsBase: String?

    init(root: URL, source: ReviewSource, defaults: UserDefaults = AppEnvironment.defaults) {
        self.root = root
        self.source = source
        self.defaults = defaults
        layout = Layout(rawValue: defaults.string(forKey: Self.layoutKey) ?? "") ?? .split
    }

    var title: String {
        if let pullRequest { return "#\(pullRequest.summary.number) \(pullRequest.summary.title)" }
        return source.title
    }

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
    var selectedFile: ChangedFile? { files.first { $0.path == selected } }

    // MARK: Loading

    /// Reads the list again (the Reload button too): every diff is read
    /// afresh; what was picked and viewed stays where it still applies.
    func load() async {
        phase = .loading
        diffs = [:]
        rows = [:]
        failures = [:]
        patches = [:]
        do {
            var list: [ChangedFile]
            switch source {
            case .pullRequest(let number):
                let text = String(decoding: try await GitHub.run(["pr", "diff", "\(number)", "--color=never"], in: root, timeout: 120), as: UTF8.self)
                let split = ReviewPatch.split(text)
                patches = Dictionary(split.map { ($0.file.path, $0.patch) }, uniquingKeysWith: { first, _ in first })
                list = split.map(\.file)
                // The header's: not worth failing the review for.
                if let data = try? await GitHub.run(["pr", "view", "\(number)", "--json", PullRequestDetail.viewFields], in: root) {
                    pullRequest = try? PullRequestDetail.parse(data)
                }
            case .branch(let mergeBase, _, _):
                list = try await changedFiles(against: [mergeBase])
                let untracked = try await Git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
                for path in untracked.split(separator: "\0").map(String.init) where !list.contains(where: { $0.path == path }) {
                    list.append(ChangedFile(path: path, originalPath: nil, kind: .untracked, isStaged: false, hasUnstaged: true))
                }
            case .range(let base, let head):
                list = try await changedFiles(against: ["\(base)...\(head)"])
            case .commits(let from, let to):
                let parent = try? await Git.run(["rev-parse", "--verify", "--quiet", "\(from)^1"], in: root)
                let base = parent.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? DiffModel.emptyTree
                commitsBase = base
                list = try await changedFiles(against: [base, to])
            }
            files = Self.ordered(list)
            viewed.formIntersection(files.map(\.path))
            phase = .loaded
            if let selected, files.contains(where: { $0.path == selected }) {
                select(selected)
            } else if let first = files.first {
                select(first.path)
            } else {
                selected = nil
            }
        } catch let error as GitError {
            phase = .failed(error.stderr.split(separator: "\n").first.map(String.init) ?? "git couldn’t read it.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// `git diff --name-status` with `--numstat`'s counts.
    private func changedFiles(against revisions: [String]) async throws -> [ChangedFile] {
        var list = GitStatus.parse(nameStatusZ: try await Git.run(["diff", "--name-status", "-z", "-M"] + revisions + ["--"], in: root))
        let numbers = GitStatus.parse(numstatZ: try await Git.run(["diff", "--numstat", "-z", "-M"] + revisions + ["--"], in: root))
        for index in list.indices {
            list[index].added = numbers[list[index].path]?.added
            list[index].removed = numbers[list[index].path]?.removed
        }
        return list
    }

    /// By folder, then by name: a folder's files together, as the list groups them.
    nonisolated static func ordered(_ files: [ChangedFile]) -> [ChangedFile] {
        files.sorted {
            let a = ($0.path as NSString).deletingLastPathComponent
            let b = ($1.path as NSString).deletingLastPathComponent
            if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// The file's diff, read once.
    private func loadDiff(_ path: String) async {
        guard diffs[path] == nil, !loading.contains(path), let file = files.first(where: { $0.path == path }) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        let text: String
        do {
            text = try await patch(for: file)
        } catch let error as GitError {
            failures[path] = error.stderr.split(separator: "\n").first.map(String.init) ?? "git couldn’t read it."
            return
        } catch {
            failures[path] = error.localizedDescription
            return
        }
        let parsed = await DiffModel.fileDiff(parsing: text, path: path, limit: Self.maxLines)
        rows[path] = SplitDiff.rows(parsed.lines)
        diffs[path] = parsed
        // An untracked file has no numstat: count its lines now.
        if let index = files.firstIndex(where: { $0.path == path }), files[index].added == nil, file.kind == .untracked {
            files[index].added = parsed.lines.filter { $0.kind == .added }.count
            files[index].removed = 0
        }
    }

    private func patch(for file: ChangedFile) async throws -> String {
        let paths = [file.kind == .renamed ? file.originalPath : nil, file.path].compactMap { $0 }
        let limit = 16 << 20
        switch source {
        case .pullRequest:
            return patches[file.path] ?? ""
        case .branch(let mergeBase, _, _):
            if file.kind == .untracked {
                return try await Git.run(
                    ["diff", "--no-color", "--no-index", "--", "/dev/null", file.path], in: root, success: [0, 1], outputLimit: limit)
            }
            return try await Git.run(["diff", "--no-color", "-M", mergeBase, "--"] + paths, in: root, outputLimit: limit)
        case .range(let base, let head):
            return try await Git.run(["diff", "--no-color", "-M", "\(base)...\(head)", "--"] + paths, in: root, outputLimit: limit)
        case .commits(_, let to):
            return try await Git.run(["diff", "--no-color", "-M", commitsBase ?? DiffModel.emptyTree, to, "--"] + paths, in: root, outputLimit: limit)
        }
    }

    // MARK: Reading it

    func select(_ path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        selected = path
        scrollTarget = nil
        Task {
            await loadDiff(path)
            // The next one, so moving on doesn't wait.
            if let next = neighbour(of: path, by: 1) { await loadDiff(next) }
        }
    }

    private func neighbour(of path: String, by step: Int) -> String? {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return nil }
        let next = index + step
        return files.indices.contains(next) ? files[next].path : nil
    }

    /// `j`/`k`: the next or previous file.
    func selectFile(by step: Int) {
        guard let selected else {
            if let first = files.first { select(first.path) }
            return
        }
        if let next = neighbour(of: selected, by: step) { select(next) }
    }

    /// `v`: viewed, or not; marking one moves on to the next not viewed, as
    /// GitHub folds it away.
    func toggleViewed(_ path: String? = nil) {
        guard let path = path ?? selected else { return }
        if viewed.contains(path) {
            viewed.remove(path)
            return
        }
        viewed.insert(path)
        guard path == selected, let index = files.firstIndex(where: { $0.path == path }) else { return }
        let after = files[(index + 1)...] + files[..<index]
        if let next = after.first(where: { !viewed.contains($0.path) }) { select(next.path) }
    }

    /// Where each change in the shown file starts: a run of added or removed
    /// lines, by its first line's id.
    var changes: [Int] {
        guard let selected, let diff = diffs[selected] else { return [] }
        var starts: [Int] = []
        var inChange = false
        for line in diff.lines {
            let changed = line.kind == .added || line.kind == .removed
            if changed, !inChange { starts.append(line.id) }
            inChange = changed
        }
        return starts
    }

    /// `n`/`p`: the next or previous change in the file; past the last, the
    /// next file's first.
    func moveToChange(by step: Int) {
        let starts = changes
        let current = scrollTarget.flatMap { starts.firstIndex(of: $0) }
        let next = current.map { $0 + step } ?? (step > 0 ? 0 : starts.count - 1)
        if starts.indices.contains(next) {
            scrollTarget = starts[next]
        } else if step > 0, current != nil || starts.isEmpty {
            selectFile(by: 1)
        }
    }
}
