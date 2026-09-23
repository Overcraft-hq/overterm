import Foundation

/// One entry of `git worktree list --porcelain`.
struct Worktree: Identifiable, Hashable {
    let path: URL
    let head: String?
    /// Short branch name (`main`), nil when detached or bare.
    let branch: String?
    let isBare: Bool
    let isDetached: Bool
    let isLocked: Bool
    /// The first entry: the repository's main working tree.
    let isMain: Bool

    var id: URL { path }

    /// What to call it in the UI.
    var displayName: String {
        if let branch { return branch }
        if isBare { return "(bare)" }
        return head.map { "(\($0.prefix(7)))" } ?? path.lastPathComponent
    }

    /// Parses porcelain output: blank-line separated records of
    /// `key value` lines, the first record being the main worktree.
    static func parse(porcelain: String) -> [Worktree] {
        var result: [Worktree] = []
        let records = porcelain.components(separatedBy: "\n\n")
        for record in records {
            var path: String?
            var head: String?
            var branch: String?
            var bare = false, detached = false, locked = false
            for line in record.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                let key = parts.first.map(String.init) ?? ""
                let value = parts.count > 1 ? String(parts[1]) : ""
                switch key {
                case "worktree": path = value
                case "HEAD": head = value
                case "branch": branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
                case "bare": bare = true
                case "detached": detached = true
                case "locked": locked = true
                default: break
                }
            }
            guard let path else { continue }
            result.append(
                Worktree(
                    path: URL(fileURLWithPath: path), head: head, branch: branch, isBare: bare,
                    isDetached: detached, isLocked: locked, isMain: result.isEmpty))
        }
        return result
    }

    /// The worktree containing `directory` — the deepest match, since a
    /// worktree may live inside another's directory.
    static func containing(_ directory: String, in worktrees: [Worktree]) -> Worktree? {
        let dir = URL(fileURLWithPath: directory).standardizedFileURL.path
        return
            worktrees
            .filter { dir == $0.path.standardizedFileURL.path || dir.hasPrefix($0.path.standardizedFileURL.path + "/") }
            .max { $0.path.path.count < $1.path.path.count }
    }
}
