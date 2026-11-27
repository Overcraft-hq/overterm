import Foundation

/// A file's `git diff` cut into its header and its hunks, each kept exactly
/// as git wrote it — every byte, a `\r` before a newline, the `\ No newline
/// at end of file` marker — so that a hunk with the header in front of it is
/// a patch `git apply` takes: Stage, Unstage and Discard of one hunk in the
/// changes pane (GIT-G1). Pure.
package enum DiffPatch {
    /// The text before the first `@@` (`diff --git`, `index`, rename and
    /// mode lines, `---`/`+++`), then each hunk from its `@@` to the next.
    /// Nothing before a hunk — a binary file, a rename alone — no hunks.
    package static func split(_ diff: String) -> (header: String, hunks: [String]) {
        var header = ""
        var hunks: [String] = []
        var current: String?
        for line in lines(diff) {
            if line.hasPrefix("@@") {
                if let current { hunks.append(current) }
                current = line
            } else if current != nil {
                current! += line
            } else {
                header += line
            }
        }
        if let current { hunks.append(current) }
        return (header, hunks)
    }

    /// One hunk as a patch of its own: the file's header, then the hunk,
    /// ending in a newline as `git apply` wants.
    package static func patch(header: String, hunk: String) -> String {
        let text = header + hunk
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    /// Every hunk of `diff` as a patch of its own, in order.
    package static func patches(_ diff: String) -> [String] {
        let (header, hunks) = split(diff)
        guard header.contains("\n+++ ") || header.hasPrefix("+++ ") else { return [] }
        return hunks.map { patch(header: header, hunk: $0) }
    }

    /// The lines, each with its own newline; a last line without one kept
    /// without. Split on `\n` alone: a `\r` before it stays in the line,
    /// as it is in the file.
    private static func lines(_ text: String) -> [String] {
        // By scalar: as Characters, "\r\n" is one, and no "\n" is found in it.
        let scalars = text.unicodeScalars
        var out: [String] = []
        var start = scalars.startIndex
        while let newline = scalars[start...].firstIndex(of: "\n") {
            let end = scalars.index(after: newline)
            out.append(String(scalars[start..<end]))
            start = end
        }
        if start < scalars.endIndex { out.append(String(scalars[start...])) }
        return out
    }
}
