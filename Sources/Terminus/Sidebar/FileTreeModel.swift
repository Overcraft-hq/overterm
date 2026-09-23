import Foundation

struct FileEntry: Hashable {
    let url: URL
    let isDirectory: Bool
    var name: String { url.lastPathComponent }
}

/// One visible line of the tree: the outline flattened, so the view is a
/// plain list and expanding a folder is an array splice, not a view rebuild.
struct FileRow: Identifiable, Hashable {
    let entry: FileEntry
    let depth: Int
    let isExpanded: Bool
    var id: URL { entry.url }
}

/// The file tree for one root directory. Folders are listed lazily, when
/// first expanded, and cached until `reload()`.
@MainActor
final class FileTreeModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var rows: [FileRow] = []
    @Published var selection: URL?

    private var expanded: Set<URL> = []
    private var listings: [URL: [FileEntry]] = [:]
    /// Expanded folders per root, so hopping between tabs in different repos
    /// comes back to the tree as you left it.
    private var expandedByRoot: [URL: Set<URL>] = [:]

    /// Noise that is never what you are looking for in a tree.
    private static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    func setRoot(_ url: URL?) {
        guard url != root else { return }
        if let root { expandedByRoot[root] = expanded }
        root = url
        expanded = url.flatMap { expandedByRoot[$0] } ?? []
        listings = [:]
        selection = nil
        rebuild()
    }

    func toggle(_ row: FileRow) {
        guard row.entry.isDirectory else { return }
        if expanded.contains(row.entry.url) {
            expanded.remove(row.entry.url)
        } else {
            expanded.insert(row.entry.url)
        }
        rebuild()
    }

    func collapseAll() {
        expanded = []
        rebuild()
    }

    /// Re-reads every listed folder (keeping what is expanded).
    func reload() {
        listings = [:]
        rebuild()
    }

    private func rebuild() {
        guard let root else {
            rows = []
            return
        }
        var result: [FileRow] = []
        func walk(_ dir: URL, depth: Int) {
            for entry in listing(of: dir) {
                let open = entry.isDirectory && expanded.contains(entry.url)
                result.append(FileRow(entry: entry, depth: depth, isExpanded: open))
                if open { walk(entry.url, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        rows = result
    }

    private func listing(of dir: URL) -> [FileEntry] {
        if let cached = listings[dir] { return cached }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        let entries =
            urls
            .filter { !Self.hiddenNames.contains($0.lastPathComponent) }
            .map { FileEntry(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .sorted {
                // Folders first, then a case-insensitive, number-aware name order.
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        listings[dir] = entries
        return entries
    }

    /// The directory a tree should show for a shell's cwd: the enclosing git
    /// checkout's top level (a worktree's `.git` is a file, which counts), or
    /// the cwd itself outside of one. Home is never promoted to a root — a
    /// dotfiles repo in ~ would otherwise capture every tab.
    nonisolated static func treeRoot(for cwd: String) -> URL {
        let start = URL(fileURLWithPath: cwd).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var dir = start
        while dir.path != "/" && dir != home {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return start
    }
}
