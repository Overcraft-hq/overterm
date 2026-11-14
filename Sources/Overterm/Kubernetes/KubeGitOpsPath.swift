import Foundation

/// A path the cluster wrote — a Kustomization's `spec.path`, an
/// Application's `source.path`, a `manifest-generate-paths` entry, a
/// `kustomization.yaml`'s — checked against a checkout before anything
/// uses it (docs/design/kubernetes/gitops.md, 4.2 and 5.4): a leading `./`
/// and a trailing `/` dropped (`""` and `.` are the root); an absolute
/// path or one with a NUL byte refused; resolved against the checkout's
/// root with its symlinks, and compared with the root resolved the same
/// way **by path components**, never by a string prefix — so `..` or a
/// symlink out of the checkout is refused. One `fileExists` per path,
/// never a walk up the tree. Pure but for that one look at the disk.
enum KubeGitOpsPath {
    enum Resolved: Equatable, Sendable {
        /// In the checkout: its path from the root, `""` for the root itself.
        case inCheckout(String)
        /// Inside the checkout's tree, but not on this branch.
        case missing(String)
        /// Not a path in the checkout: why.
        case refused(String)

        /// What a pathspec is made of: only a path that is there.
        var relative: String? {
            if case .inCheckout(let path) = self { return path }
            return nil
        }
    }

    /// `path` against the checkout at `root`. `fromRoot`: a leading `/`
    /// means the repository's root (as Argo CD reads `manifest-generate-paths`).
    static func resolve(_ path: String, in root: URL, fromRoot: Bool = false) -> Resolved {
        guard !path.contains("\u{0}") else { return .refused("a path with a NUL byte") }
        var relative = path.trimmingCharacters(in: .whitespaces)
        if relative.hasPrefix("/") {
            guard fromRoot else { return .refused("an absolute path (\(path))") }
            while relative.hasPrefix("/") { relative.removeFirst() }
        }
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        while relative.hasSuffix("/") { relative.removeLast() }
        if relative == "." { relative = "" }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = (relative.isEmpty ? base : base.appendingPathComponent(relative)).resolvingSymlinksInPath().standardizedFileURL
        let baseParts = base.pathComponents
        let parts = candidate.pathComponents
        guard parts.count >= baseParts.count, Array(parts.prefix(baseParts.count)) == baseParts else {
            return .refused("\(path) is outside the checkout")
        }
        let inside = parts.dropFirst(baseParts.count).joined(separator: "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return .missing(inside) }
        return .inCheckout(inside)
    }

    /// A `manifest-generate-paths` entry: relative to the Application's own
    /// path, or — with a leading `/` — to the repository's root.
    static func resolve(generatePath entry: String, appPath: String?, in root: URL) -> Resolved {
        if entry.hasPrefix("/") { return resolve(entry, in: root, fromRoot: true) }
        let base = (appPath ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.contains("\u{0}"), !(appPath ?? "").hasPrefix("/") else { return .refused("an absolute path (\(appPath ?? ""))") }
        return resolve(base.isEmpty ? entry : "\(base)/\(entry)", in: root)
    }

    /// "path apps/web is not on this branch".
    static func said(_ resolved: Resolved) -> String {
        switch resolved {
        case .inCheckout(let path): path.isEmpty ? "the repository's root" : path
        case .missing(let path): "path \(path) is not on this branch"
        case .refused(let why): why
        }
    }
}
