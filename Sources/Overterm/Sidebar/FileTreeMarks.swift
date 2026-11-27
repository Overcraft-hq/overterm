import Foundation

/// What git says of a row in the file tree, from the changes the window's
/// `DiffModel` already has — never a git call of its own. Pure.
package enum FileMark: Int, Comparable, Sendable {
    // In the order a folder shows the worst of what is under it.
    case untracked, added, modified, conflicted

    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// A changed file's mark; nil for one that is gone (deleted), which has
    /// no row — its folders are still marked.
    package init?(_ kind: ChangedFile.Kind) {
        switch kind {
        case .modified, .typeChanged, .renamed: self = .modified
        case .added: self = .added
        case .untracked: self = .untracked
        case .conflicted: self = .conflicted
        case .deleted: return nil
        }
    }
}

/// The tree's marks: each changed file by its path relative to the
/// checkout, and each folder above one with the worst mark under it.
package struct FileTreeMarks: Equatable, Sendable {
    package private(set) var files: [String: FileMark] = [:]
    package private(set) var folders: [String: FileMark] = [:]
    /// The checkout the paths are relative to (its path, standardized).
    package private(set) var root: String?

    package init() {}

    package static let empty = FileTreeMarks()

    package init(root: URL?, changed: [ChangedFile]) {
        guard let root else { return }
        self.root = root.standardizedFileURL.path
        for file in changed {
            let path = file.path.hasSuffix("/") ? String(file.path.dropLast()) : file.path
            guard !path.isEmpty else { continue }
            let mark = FileMark(file.kind)
            if let mark { files[path] = max(files[path] ?? mark, mark) }
            // A deleted file's folders say something changed in there.
            let folderMark = mark ?? .modified
            var components = path.split(separator: "/").dropLast()
            // Bounded by the path's own components: never walks up past it.
            while !components.isEmpty {
                let folder = components.joined(separator: "/")
                folders[folder] = max(folders[folder] ?? folderMark, folderMark)
                components = components.dropLast()
            }
        }
    }

    package var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    /// A row's mark: a file's own, a folder's the worst under it.
    package func mark(for url: URL, isDirectory: Bool) -> FileMark? {
        guard let path = relative(url) else { return nil }
        return isDirectory ? folders[path] : files[path]
    }

    /// `url`'s path under the checkout, nil outside it. `/var` and `/tmp`
    /// are `/private/var` and `/private/tmp`: either spelling matches.
    package func relative(_ url: URL) -> String? {
        guard let root else { return nil }
        return Self.relative(url.standardizedFileURL.path, to: root)
    }

    package static func relative(_ path: String, to root: String) -> String? {
        for (p, r) in [(path, root), (unprivate(path), unprivate(root))] {
            let prefix = r.hasSuffix("/") ? r : r + "/"
            if p.hasPrefix(prefix) { return String(p.dropFirst(prefix.count)) }
        }
        return nil
    }

    private static func unprivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// "Changed only": every changed file that has a row, under its folders,
    /// all open — whether or not the tree has listed them. Folders first,
    /// then names, as the tree orders them. Paths relative to the checkout.
    package func changedRows() -> [(path: String, depth: Int, isDirectory: Bool)] {
        // Only what leads to a file with a row: a folder holding nothing
        // but deletions has nothing to open.
        var shown = Set(files.keys)
        for path in files.keys {
            var components = path.split(separator: "/").dropLast()
            while !components.isEmpty {
                guard shown.insert(components.joined(separator: "/")).inserted else { break }
                components = components.dropLast()
            }
        }
        var children: [String: [String]] = [:]
        for path in shown {
            let parent = (path as NSString).deletingLastPathComponent
            children[parent, default: []].append(path)
        }
        var result: [(String, Int, Bool)] = []
        func walk(_ parent: String, depth: Int) {
            let sorted = (children[parent] ?? []).sorted { a, b in
                let aDir = files[a] == nil, bDir = files[b] == nil
                if aDir != bDir { return aDir }
                return (a as NSString).lastPathComponent.localizedStandardCompare((b as NSString).lastPathComponent) == .orderedAscending
            }
            for path in sorted {
                let isDirectory = files[path] == nil
                result.append((path, depth, isDirectory))
                // Depth is bounded by the paths themselves.
                if isDirectory { walk(path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        return result
    }
}
