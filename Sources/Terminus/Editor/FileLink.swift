import Foundation

/// A file path ⌘-clicked in the terminal: libghostty's link matcher sends
/// what it matched (`src/main.swift:12`, `./a.go:3:7`, `~/x.md`, an absolute
/// path it already resolved), and this decides whether it is a file to open
/// in the editor, and at which line.
struct FileLink: Equatable {
    let url: URL
    let line: Int?

    /// `text` as a file under one of `directories` (tried in order: the
    /// shell's directory, then the checkout — compilers and `git grep` print
    /// repo-relative paths). Nil when it isn't an existing regular file, so
    /// URLs, directories and binaries keep going to the system opener.
    static func resolve(_ text: String, in directories: [String]) -> FileLink? {
        var text = text.trimmingCharacters(in: .whitespaces)
        // Only `scheme://…` is a URL: `main.swift:3` parses as one too.
        if text.contains("://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        }
        // The whole text first: a file may really be named `a:1`.
        for (path, line) in [(text, nil), split(text)] {
            guard let path, let file = existingFile(path, in: directories) else { continue }
            // An image or a PDF opens better in its own app than as "Binary file.".
            return isBinary(file) ? nil : FileLink(url: file, line: line)
        }
        return nil
    }

    /// `path:12`, `path:12:5` and `path(12,5)` → the path and the line.
    static func split(_ text: String) -> (String?, Int?) {
        if let match = text.firstMatch(of: /^(.+?):(\d+)(?::\d+)?$/) {
            return (String(match.1), Int(match.2))
        }
        if let match = text.firstMatch(of: /^(.+?)\((\d+)(?:,\s*\d+)?\)$/) {
            return (String(match.1), Int(match.2))
        }
        return (nil, nil)
    }

    /// A NUL in the first 8 KB, as `EditorDocument` (and git) decide it.
    private static func isBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8192))?.contains(0) ?? false
    }

    private static func existingFile(_ path: String, in directories: [String]) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates =
            expanded.hasPrefix("/")
            ? [URL(fileURLWithPath: expanded)]
            : directories.map { URL(fileURLWithPath: $0).appendingPathComponent(expanded) }
        return candidates.lazy.map(\.standardizedFileURL).first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }
}
