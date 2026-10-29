import Foundation

/// A container's folders, listed through `exec` — the `archive` endpoint
/// hands a folder over as its whole tree, `/` and all. A plain `sh` script,
/// so busybox and coreutils both answer it; an image without a shell
/// (distroless) can't be listed, though a file in it can still be read by
/// its path. Pure.
enum DockerFiles {
    struct Entry: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case folder = "d", file = "f", link = "l", other = "o" }

        var name: String
        var kind: Kind
        /// Bytes, for a file whose size could be read.
        var size: Int?

        var id: String { name }
    }

    /// One line an entry: kind, size (or `-`), name, tab-separated.
    static let script = #"""
        cd -- "$1" 2>/dev/null || { echo "No such folder: $1" >&2; exit 2; }
        for f in .* *; do
          case "$f" in .|..) continue;; esac
          [ -e "$f" ] || [ -L "$f" ] || continue
          if [ -L "$f" ]; then t=l; elif [ -d "$f" ]; then t=d; elif [ -f "$f" ]; then t=f; else t=o; fi
          s=-
          [ "$t" = f ] && s=$(stat -c %s -- "$f" 2>/dev/null || echo -)
          printf '%s\t%s\t%s\n' "$t" "$s" "$f"
        done
        """#

    /// What `exec` runs to list `folder`: the script, its `$0`, the folder.
    static func command(listing folder: String) -> [String] { ["sh", "-c", script, "overterm-ls", folder] }

    /// Folders first, then by name as Finder sorts.
    static func parse(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line -> Entry? in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let kind = Entry.Kind(rawValue: String(parts[0])), !parts[2].isEmpty else { return nil }
            return Entry(name: String(parts[2]), kind: kind, size: Int(parts[1]))
        }
        .sorted { a, b in
            if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// A path's own folder: computed once, never walked (CLAUDE.md, `/`).
    static func parent(_ path: String) -> String {
        guard path.count > 1, let slash = path.dropLast().lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }

    /// `/etc/nginx` → `/`, `/etc`, `/etc/nginx`: the path bar's parts.
    static func crumbs(_ path: String) -> [(name: String, path: String)] {
        var result = [(name: "/", path: "/")]
        var walked = ""
        for part in path.split(separator: "/") {
            walked += "/" + part
            result.append((String(part), walked))
        }
        return result
    }

    /// Where a container's file is kept while the editor has it: under
    /// Overterm's own folder, by container and path — `.` and `..` left
    /// out, so a path typed as `/../../x` stays inside that folder. A
    /// volume's go under `Volumes` (`localCopy(of:from:under:)`).
    static func localCopy(of path: String, in container: String, under root: URL, folder: String = "Containers") -> URL {
        let safe = container.replacingOccurrences(of: "/", with: "_")
        let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }.joined(separator: "/")
        return root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(safe == ".." ? "_" : safe, isDirectory: true)
            .appendingPathComponent(parts.isEmpty ? "untitled" : parts)
    }

    /// A container's or a volume's file, kept by where it came from.
    static func localCopy(of path: String, from source: DockerFileSource, under root: URL) -> URL {
        localCopy(of: path, in: source.copiesName, under: root, folder: source.copiesFolder)
    }
}

/// Whose files a Files tab shows: a container's, or a volume's — read
/// through a helper that mounts it (`DockerEngine.reaching`).
enum DockerFileSource: Hashable, Sendable {
    case container(id: String, name: String)
    case volume(String)

    static func of(_ container: ContainerSummary) -> DockerFileSource { .container(id: container.Id, name: container.name) }

    /// As a sentence says it: `web`, `the volume pgdata`.
    var title: String {
        switch self {
        case .container(_, let name): name
        case .volume(let name): "the volume \(name)"
        }
    }

    /// Where its copies go in Overterm's folder, and under what name.
    var copiesFolder: String {
        switch self {
        case .container: "Containers"
        case .volume: "Volumes"
        }
    }

    var copiesName: String {
        switch self {
        case .container(_, let name): name
        case .volume(let name): name
        }
    }
}

/// A container's or a volume's file the editor has a copy of: where it
/// came from, and what it was when read — to tell a save that would
/// overwrite a change made there since, and to give the file back its
/// owner (a database won't read a config root now owns).
struct DockerFileCopy: Equatable, Sendable {
    var source: DockerFileSource
    var path: String
    var stat: DockerTar.PathStat
    var uid: Int
    var gid: Int
    /// The engine it was read from: a volume's name is on every engine,
    /// and the context may have changed since.
    var endpoint: DockerEndpoint

    /// Why it isn't saved through `now`: another engine than the one it
    /// came from, where the same name is another volume (or nothing, and
    /// a helper would make it). Nil for the same one. Pure.
    func refusal(through now: DockerEndpoint) -> String? {
        guard now.address != endpoint.address else { return nil }
        return "It was opened from \(Self.name(of: endpoint)), and Docker is now \(Self.name(of: now)): switch back to save it there."
    }

    /// `the context colima`, else its host.
    static func name(of endpoint: DockerEndpoint) -> String { endpoint.context.map { "the context \($0)" } ?? endpoint.host }
}
