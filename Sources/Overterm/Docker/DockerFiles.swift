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
    /// out, so a path typed as `/../../x` stays inside that folder.
    static func localCopy(of path: String, in container: String, under root: URL) -> URL {
        let safe = container.replacingOccurrences(of: "/", with: "_")
        let parts = path.split(separator: "/").filter { $0 != "." && $0 != ".." }.joined(separator: "/")
        return root.appendingPathComponent("Containers", isDirectory: true).appendingPathComponent(safe == ".." ? "_" : safe, isDirectory: true)
            .appendingPathComponent(parts.isEmpty ? "untitled" : parts)
    }
}

/// A container's file the editor has a copy of: where it came from, and
/// what it was when read — to tell a save that would overwrite a change
/// made in the container since.
struct DockerFileCopy: Equatable, Sendable {
    var container: String
    var name: String
    var path: String
    var stat: DockerTar.PathStat
}
