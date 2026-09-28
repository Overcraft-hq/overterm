import Foundation

/// A line in a file that matched a content search.
struct ContentMatch: Hashable {
    let path: String
    let line: Int
    let text: String
}

/// Searches a checkout: file names (fuzzy) and file contents (git grep).
/// Both respect .gitignore — node_modules and build output never show up —
/// and include untracked files.
enum CheckoutSearch {
    /// Tracked plus untracked-but-not-ignored files, relative to `root`.
    static func files(in root: URL) async -> [String] {
        let output = (try? await Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)) ?? ""
        return Array(Set(output.split(separator: "\0").map(String.init))).sorted()
    }

    /// Best name matches for `query`: the file name counts more than the
    /// folders above it.
    static func rank(_ files: [String], query: String, limit: Int = 12) -> [String] {
        guard !query.isEmpty else { return [] }
        return
            files
            .compactMap { path -> (String, Int)? in
                let name = (path as NSString).lastPathComponent
                let byName = FuzzyMatch.score(query, in: name).map { $0 + 1_000_000 }
                let byPath = FuzzyMatch.score(query, in: path)
                guard let best = [byName, byPath].compactMap({ $0 }).max() else { return nil }
                return (path, best)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Lines containing `query` (literal, case-insensitive), a few per file.
    /// git grep has no overall limit: a two-letter query in a big repo
    /// printed a few lines of nearly every file (~0.8 s, megabytes) to show
    /// 50. Past this much output it is stopped.
    static let grepOutputLimit = 256 * 1024

    static func grep(_ query: String, in root: URL, perFile: Int = 3, limit: Int = 50) async -> [ContentMatch] {
        guard query.count >= 2 else { return [] }
        // -z: NUL between path, line and text, so any file name survives;
        // exit 1 means no matches. Cancelling the task stops git.
        var output =
            (try? await Git.run(
                ["grep", "-z", "-n", "-I", "-F", "-i", "--no-color", "--untracked", "--max-count=\(perFile)", "-e", query],
                in: root, success: [0, 1], outputLimit: grepOutputLimit)) ?? ""
        // Stopped mid-line: the last record may be cut.
        if output.utf8.count >= grepOutputLimit, let end = output.lastIndex(of: "\n") { output = String(output[...end]) }
        return Array(parse(grep: output).prefix(limit))
    }

    /// `git grep -z -n` output: path NUL line NUL text NEWLINE.
    static func parse(grep output: String) -> [ContentMatch] {
        output.split(separator: "\n").compactMap { record in
            let parts = record.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let line = Int(parts[1]) else { return nil }
            return ContentMatch(path: String(parts[0]), line: line, text: parts[2].trimmingCharacters(in: .whitespaces))
        }
    }
}
