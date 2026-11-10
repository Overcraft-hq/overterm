import Foundation

/// A branch, local or remote-tracking, as Overgit lists it.
struct BranchRef: Identifiable, Equatable {
    /// The short name: `main`, `feature/x`, `origin/main`.
    let name: String
    let isRemote: Bool
    let sha: String
    /// The remote branch this one follows, if any.
    let upstream: String?
    let ahead: Int
    let behind: Int
    /// Its upstream is gone — the branch was merged and deleted on the
    /// remote, usually.
    let isGone: Bool
    let date: Date
    let subject: String

    var id: String { (isRemote ? "remote:" : "local:") + name }
    /// The last component, for a tree row: `x` of `feature/x`.
    var leaf: String { name.split(separator: "/").last.map(String.init) ?? name }
}

struct TagRef: Identifiable, Equatable {
    let name: String
    let sha: String
    let date: Date
    let subject: String

    var id: String { name }
}

struct Remote: Identifiable, Equatable {
    let name: String
    /// As git says it, without the userinfo a URL can carry
    /// (`url.*.insteadOf` may add a token): the raw output is never kept.
    let url: String

    init(name: String, url: String) {
        self.name = name
        self.url = GitRemoteURL.withoutUserinfo(url)
    }

    var id: String { name }
    /// The repository it names, normalised (`GitRemoteURL`); nil for one that names none.
    var repo: GitRemoteURL? { GitRemoteURL(url) }

    /// The host, for the row's subtitle: `github.com` out of either an
    /// https URL or `git@github.com:owner/repo.git`.
    var host: String? {
        if let host = URL(string: url)?.host { return host }
        guard let at = url.firstIndex(of: "@") else { return nil }
        let rest = url[url.index(after: at)...]
        guard let colon = rest.firstIndex(of: ":") else { return String(rest) }
        return String(rest[..<colon])
    }
}

/// Branches, tags and remotes — `for-each-ref` and `remote -v`.
enum Refs {
    /// One record a line, fields NUL-separated. The subject is last and
    /// `%(contents:subject)` folds a paragraph into one line, so a newline
    /// is always a record boundary.
    private static let format =
        "--format=%(refname)%00%(objectname:short)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(contents:subject)"

    static func branchArguments(includeRemotes: Bool = true) -> [String] {
        ["for-each-ref", "--sort=-committerdate", format, "refs/heads"] + (includeRemotes ? ["refs/remotes"] : [])
    }

    static func parse(branches output: String) -> [BranchRef] {
        output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\0")
            guard f.count >= 6 else { return nil }
            let full = f[0]
            let isRemote = full.hasPrefix("refs/remotes/")
            let name = String(full.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count))
            // `origin/HEAD` is a pointer at the remote's default branch, not
            // a branch anybody works on.
            guard !name.isEmpty, !name.hasSuffix("/HEAD") else { return nil }
            let track = self.track(f[3])
            return BranchRef(
                name: name, isRemote: isRemote, sha: f[1], upstream: f[2].isEmpty ? nil : f[2],
                ahead: track.ahead, behind: track.behind, isGone: track.gone,
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0), subject: f[5])
        }
    }

    /// Parses `%(upstream:track)`: `[ahead 2, behind 1]`, `[gone]`, or
    /// nothing at all when the branch is level with its upstream.
    static func track(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        guard !text.isEmpty else { return (0, 0, false) }
        if text.contains("gone") { return (0, 0, true) }
        func number(after word: String) -> Int {
            guard let range = text.range(of: word + " ") else { return 0 }
            let digits = text[range.upperBound...].prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
        return (number(after: "ahead"), number(after: "behind"), false)
    }

    static func tagArguments(limit: Int = 200) -> [String] {
        [
            "for-each-ref", "--sort=-creatordate", "--count=\(max(1, limit))",
            "--format=%(refname:short)%00%(objectname:short)%00%(creatordate:unix)%00%(contents:subject)", "refs/tags",
        ]
    }

    static func parse(tags output: String) -> [TagRef] {
        output.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\0")
            guard f.count >= 4, !f[0].isEmpty else { return nil }
            return TagRef(name: f[0], sha: f[1], date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0), subject: f[3])
        }
    }

    static let remoteArguments = ["remote", "-v"]

    /// Parses `git remote -v`: `origin\t<url>\t(fetch)`, twice per remote.
    /// The fetch URL is the one worth showing; a push-only remote keeps its.
    /// Each URL goes straight to `Remote`, which keeps it without its
    /// userinfo — nothing raw leaves the parser.
    static func parse(remotes output: String) -> [Remote] {
        var urls: [String: String] = [:]
        var order: [String] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            let name = String(parts[0])
            let url = String(parts[1].split(separator: " ").first ?? "")
            let isFetch = parts.count < 3 || parts[2].contains("fetch")
            if urls[name] == nil || isFetch { urls[name] = url }
            if !order.contains(name) { order.append(name) }
        }
        return order.map { Remote(name: $0, url: urls[$0] ?? "") }
    }
}

/// One row of the branch list: a branch, or the folder a `/` makes.
struct BranchNode: Identifiable, Equatable {
    /// The path so far — `feature` or `feature/x`. Unique in a list.
    let id: String
    /// The last component, which is what the row shows.
    let name: String
    let depth: Int
    /// nil for a folder.
    let branch: BranchRef?
    /// A folder: how many branches are under it.
    let count: Int

    var isFolder: Bool { branch == nil }
}

/// `feature/a` and `feature/b` under `feature`, as the file tree does it:
/// flattened to rows here rather than nested in the view, so scrolling a
/// thousand branches costs what a list costs.
enum BranchTree {
    /// The branches whose name holds every word of `query` (any case,
    /// any order): `pay fix` finds `fix/payments`. Empty: all of them.
    static func matching(_ branches: [BranchRef], query: String) -> [BranchRef] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return branches }
        return branches.filter { branch in
            let name = branch.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// Every folder the branches sit in — open while a search shows them.
    static func folders(of branches: [BranchRef]) -> Set<String> {
        var folders = Set<String>()
        for branch in branches {
            let parts = branch.name.split(separator: "/").dropLast()
            var path = ""
            for part in parts {
                path = path.isEmpty ? String(part) : "\(path)/\(part)"
                folders.insert(path)
            }
        }
        return folders
    }

    static func rows(_ branches: [BranchRef], expanded: Set<String>, depth: Int = 0, prefix: String = "") -> [BranchNode] {
        var folders: [String: [BranchRef]] = [:]
        var folderOrder: [String] = []
        var leaves: [BranchRef] = []
        for branch in branches {
            let rest = prefix.isEmpty ? branch.name : String(branch.name.dropFirst(prefix.count + 1))
            guard let slash = rest.firstIndex(of: "/") else {
                leaves.append(branch)
                continue
            }
            let folder = String(rest[..<slash])
            if folders[folder] == nil { folderOrder.append(folder) }
            folders[folder, default: []].append(branch)
        }
        var rows: [BranchNode] = []
        for folder in folderOrder.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let children = folders[folder] ?? []
            let path = prefix.isEmpty ? folder : "\(prefix)/\(folder)"
            rows.append(BranchNode(id: path, name: folder, depth: depth, branch: nil, count: children.count))
            if expanded.contains(path) {
                rows += self.rows(children, expanded: expanded, depth: depth + 1, prefix: path)
            }
        }
        for branch in leaves.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            rows.append(BranchNode(id: branch.id, name: branch.leaf, depth: depth, branch: branch, count: 0))
        }
        return rows
    }
}
