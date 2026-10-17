import Foundation

/// A ref riding a commit: what `%D` decorates it with.
struct CommitRef: Identifiable, Equatable {
    enum Kind: String {
        case head, branch, remote, tag
    }

    let kind: Kind
    /// The short name: `main`, `origin/main`, `v1.2.0`.
    let name: String
    /// Whether HEAD points here — the row people are standing on.
    let isHead: Bool

    var id: String { "\(kind.rawValue):\(name)" }
}

/// One commit of a repository's history, as Overgit lists it.
///
/// `BranchLog.BranchCommit` is the changes pane's and stays: it is bounded
/// by the merge base and carries the file lists that "why this file
/// changed" needs. This one goes back as far as it is asked to, and carries
/// what a graph needs — the parents — and what a row shows.
struct Commit: Identifiable, Equatable {
    let sha: String
    let shortSHA: String
    /// Oldest-named first, as git prints them: a merge has two or more.
    let parents: [String]
    let author: String
    let authorEmail: String
    let date: Date
    /// git's own relative date ("2 hours ago") — the phrasing people
    /// already read on the command line, and free to ask for.
    let relative: String
    let subject: String
    /// The message after the subject; empty when there is none.
    let body: String
    let refs: [CommitRef]

    var id: String { sha }
    var isMerge: Bool { parents.count > 1 }
}

/// A repository's commits, from `git log`.
enum CommitLog {
    /// The fields, NUL-separated as git's own `-z` output is: a message can
    /// hold newlines and tabs, never a NUL. Each commit is led by an empty
    /// field, so a body's newlines can't be mistaken for a record boundary.
    private static let format = "--format=%x00%H%x00%h%x00%P%x00%an%x00%ae%x00%at%x00%ar%x00%D%x00%s%x00%b"

    /// The newest `limit` commits. `allRefs` walks every branch and tag,
    /// not just the one that is checked out — the graph's "show everything".
    ///
    /// `--decorate=full` is not decoration for its own sake: short names
    /// can't be told apart (`feature/x` is a local branch, `origin/x` is
    /// not), and the full refname says which is which without guessing.
    static func arguments(limit: Int, allRefs: Bool = false) -> [String] {
        var arguments = [
            "log", "-z", "--no-show-signature", "--date-order", "--decorate=full",
            "--max-count=\(max(1, limit))", format,
        ]
        arguments.append(allRefs ? "--all" : "HEAD")
        return arguments
    }

    /// Parses what `arguments` prints: per commit an empty field, then the
    /// ten fields of the format, in order.
    static func parse(_ output: String) -> [Commit] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var commits: [Commit] = []
        var i = 0
        while i + 10 < fields.count {
            guard fields[i].isEmpty else {
                i += 1
                continue
            }
            let f = Array(fields[(i + 1)...(i + 10)])
            i += 11
            guard !f[0].isEmpty else { continue }
            commits.append(
                Commit(
                    sha: f[0], shortSHA: f[1],
                    parents: f[2].split(separator: " ").map(String.init),
                    author: f[3], authorEmail: f[4],
                    date: Date(timeIntervalSince1970: TimeInterval(f[5]) ?? 0),
                    relative: f[6],
                    subject: f[8],
                    body: f[9].trimmingCharacters(in: .whitespacesAndNewlines),
                    refs: refs(f[7])))
        }
        return commits
    }

    /// Parses `%D` under `--decorate=full`:
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1`.
    static func refs(_ decoration: String) -> [CommitRef] {
        decoration.split(separator: ",").compactMap { item in
            var name = item.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            var isHead = false
            if name == "HEAD" { return CommitRef(kind: .head, name: "HEAD", isHead: true) }
            if name.hasPrefix("HEAD -> ") {
                isHead = true
                name = String(name.dropFirst("HEAD -> ".count))
            }
            // git writes `tag: ` in front of a tag even with the full name.
            if name.hasPrefix("tag: ") { name = String(name.dropFirst("tag: ".count)) }
            if name.hasPrefix("refs/heads/") {
                return CommitRef(kind: .branch, name: String(name.dropFirst("refs/heads/".count)), isHead: isHead)
            }
            if name.hasPrefix("refs/remotes/") {
                return CommitRef(kind: .remote, name: String(name.dropFirst("refs/remotes/".count)), isHead: isHead)
            }
            if name.hasPrefix("refs/tags/") {
                return CommitRef(kind: .tag, name: String(name.dropFirst("refs/tags/".count)), isHead: false)
            }
            return CommitRef(kind: .branch, name: name, isHead: isHead)
        }
    }
}
