import Foundation

/// Two branches, tags or commits side by side in the right-hand pane —
/// GitLens's Compare: what `head` has that `base` doesn't (its commits, and
/// every file it changed since they parted, with its diff), and how many
/// `base` has that `head` doesn't. Three dots, as a pull request reads:
/// against the merge base, so `base` moving on doesn't show as removals.
@MainActor
final class CompareModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    static let maxFiles = DiffModel.maxDiffedFiles
    static let maxCommits = 300

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var base: String?
    @Published private(set) var head: String?
    /// Commits `head` has and `base` doesn't, newest first; and the other way.
    @Published private(set) var ahead: [Commit] = []
    @Published private(set) var behind: [Commit] = []
    @Published private(set) var aheadCount = 0
    @Published private(set) var behindCount = 0
    @Published private(set) var files: [ChangedFile] = []
    @Published private(set) var diffs: [String: DiffModel.FileDiff] = [:]
    @Published private(set) var folded: Set<String> = []
    private(set) var root: URL?
    private var ticket = 0

    /// Read only while the pane shows it, as the commit's is.
    var visible = false {
        didSet {
            guard visible != oldValue, visible, phase == .idle || phase == .loading else { return }
            Task { await load() }
        }
    }

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }

    func show(root: URL?, base: String, head: String) {
        self.root = root
        self.base = base
        self.head = head
        ahead = []
        behind = []
        aheadCount = 0
        behindCount = 0
        files = []
        diffs = [:]
        folded = []
        phase = .loading
        ticket += 1
        if visible { Task { await load() } }
    }

    /// The other way round.
    func swap() {
        guard let base, let head else { return }
        show(root: root, base: head, head: base)
    }

    func toggleFold(_ path: String) {
        if folded.contains(path) { folded.remove(path) } else { folded.insert(path) }
    }

    func isFolded(_ path: String) -> Bool { folded.contains(path) }

    /// `git rev-list --left-right --count base...head`: "behind\tahead".
    nonisolated static func counts(_ output: String) -> (behind: Int, ahead: Int) {
        let parts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
    }

    private func load() async {
        guard visible, let root, let base, let head else { return }
        let ticket = self.ticket
        func current() -> Bool { ticket == self.ticket }
        phase = .loading
        do {
            let range = "\(base)...\(head)"
            let counted = Self.counts(try await Git.run(["rev-list", "--left-right", "--count", range, "--"], in: root))
            let log = CommitLog.arguments(limit: Self.maxCommits).dropLast()
            let ahead = CommitLog.parse(try await Git.run(Array(log) + ["\(base)..\(head)", "--"], in: root, outputLimit: 8 << 20))
            let behind = CommitLog.parse(try await Git.run(Array(log) + ["\(head)..\(base)", "--"], in: root, outputLimit: 8 << 20))
            var files = GitStatus.parse(nameStatusZ: try await Git.run(["diff", "--name-status", "-z", "-M", range, "--"], in: root))
            let numbers = GitStatus.parse(numstatZ: try await Git.run(["diff", "--numstat", "-z", "-M", range, "--"], in: root))
            for index in files.indices {
                files[index].added = numbers[files[index].path]?.added
                files[index].removed = numbers[files[index].path]?.removed
            }
            guard current() else { return }
            (behindCount, aheadCount) = counted
            self.ahead = ahead
            self.behind = behind
            self.files = files
            // Many files: folded, as the changes pane starts them.
            if files.count > 12 { folded = Set(files.map(\.path)) }
            phase = .loaded
            for file in files.prefix(Self.maxFiles) {
                guard current() else { return }
                let paths = [file.kind == .renamed ? file.originalPath : nil, file.path].compactMap { $0 }
                guard let text = try? await Git.run(["diff", "--no-color", "-M", range, "--"] + paths, in: root, outputLimit: 8 << 20)
                else { continue }
                let parsed = await DiffModel.fileDiff(parsing: text, path: file.path)
                guard current() else { return }
                diffs[file.path] = parsed
            }
        } catch let error as GitError {
            guard current() else { return }
            phase = .failed(error.stderr.split(separator: "\n").first.map(String.init) ?? "git could not compare \(base) and \(head).")
        } catch {
            guard current() else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}
