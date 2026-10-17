import Foundation

/// One commit, opened in the right-hand pane: its message, who made it,
/// and every file it touched with its diff.
///
/// The diffs are the changes pane's own: `DiffModel.FileDiff` takes a
/// unified diff as a string and `FileCard` draws it, so `git show` lands
/// in the same card `git diff` does. Nothing here stages or discards —
/// what it shows has already happened.
@MainActor
final class CommitDetailModel: ObservableObject {
    /// As many files as the changes pane diffs, for the same reason: a
    /// commit that moved a vendored tree would otherwise run git a
    /// thousand times.
    static let maxFiles = DiffModel.maxDiffedFiles

    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detail: CommitDetail?
    @Published private(set) var diffs: [String: DiffModel.FileDiff] = [:]
    @Published private(set) var folded: Set<String> = []
    /// The sha asked for, whether or not it has arrived.
    @Published private(set) var sha: String?
    private var root: URL?

    /// Shown only while the pane is on it: a commit's files are a dozen
    /// `git show` calls, and nobody should pay them for a pane behind
    /// another tab.
    var visible = false {
        didSet {
            guard visible != oldValue, visible else { return }
            Task { await load() }
        }
    }

    var shortSHA: String? { detail?.commit.shortSHA ?? sha.map { String($0.prefix(7)) } }

    /// Picks the commit to show. Reading waits until the pane is visible.
    func show(root: URL?, sha: String?) {
        guard root != self.root || sha != self.sha else { return }
        self.root = root
        self.sha = sha
        detail = nil
        diffs = [:]
        folded = []
        phase = sha == nil ? .idle : .loading
        Task { await load() }
    }

    func toggleFold(_ path: String) {
        if folded.contains(path) { folded.remove(path) } else { folded.insert(path) }
    }

    func isFolded(_ path: String) -> Bool { folded.contains(path) }

    private func load() async {
        guard visible, let root, let sha, detail == nil else { return }
        phase = .loading
        do {
            let header = CommitLog.parse(try await Git.run(CommitShow.headerArguments(sha), in: root))
            guard let commit = header.first else {
                phase = .failed("No commit \(sha).")
                return
            }
            var files = GitStatus.parse(nameStatusZ: try await Git.run(CommitShow.filesArguments(sha), in: root))
            let numbers = GitStatus.parse(numstatZ: try await Git.run(CommitShow.numstatArguments(sha), in: root))
            for index in files.indices {
                files[index].added = numbers[files[index].path]?.added
                files[index].removed = numbers[files[index].path]?.removed
            }
            // The root (or the commit) may have moved while git ran.
            guard sha == self.sha, root == self.root else { return }
            detail = CommitDetail(commit: commit, files: files)
            phase = .loaded
            await loadDiffs(sha: sha, root: root, files: Array(files.prefix(Self.maxFiles)))
        } catch let error as GitError {
            guard sha == self.sha else { return }
            phase = .failed(error.stderr.split(separator: "\n").first.map(String.init) ?? "git could not read \(sha).")
        } catch {
            guard sha == self.sha else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadDiffs(sha: String, root: URL, files: [ChangedFile]) async {
        for file in files {
            guard sha == self.sha, root == self.root else { return }
            let arguments = CommitShow.diffArguments(
                sha, path: file.path, originalPath: file.kind == .renamed ? file.originalPath : nil)
            guard let text = try? await Git.run(arguments, in: root, outputLimit: 8 << 20) else { continue }
            // Parsing and highlighting go off the main thread — the
            // changes pane's own call does that hop for us.
            let parsed = await DiffModel.fileDiff(parsing: text, path: file.path)
            guard sha == self.sha, root == self.root else { return }
            diffs[file.path] = parsed
        }
    }
}
