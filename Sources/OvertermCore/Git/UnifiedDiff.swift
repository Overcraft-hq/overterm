import Foundation

/// A unified diff split into lines the panel can colour and number.
package struct DiffLine: Identifiable, Hashable {
    package enum Kind: Hashable { case meta, hunk, context, added, removed }

    package let id: Int
    package let kind: Kind
    package let text: String
    package let oldNumber: Int?
    package let newNumber: Int?
}

package enum UnifiedDiff {
    /// Classifies each line and numbers it from the hunk headers. Lines
    /// before the first hunk (diff --git, index, ---/+++) are meta.
    package static func parse(_ diff: String, limit: Int = 20_000) -> (lines: [DiffLine], truncated: Bool) {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        // "\r\n" is one Character: split on it too, or a CRLF file's whole
        // diff was one line.
        let raw = diff.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        for (i, sub) in raw.enumerated() {
            if lines.count >= limit { return (lines, true) }
            let text = String(sub)
            if i == raw.count - 1 && text.isEmpty { break }
            if text.hasPrefix("@@") {
                inHunk = true
                (oldLine, newLine) = hunkStarts(text)
                lines.append(DiffLine(id: i, kind: .hunk, text: text, oldNumber: nil, newNumber: nil))
            } else if !inHunk || text.hasPrefix("diff --git") {
                inHunk = false
                lines.append(DiffLine(id: i, kind: .meta, text: text, oldNumber: nil, newNumber: nil))
            } else if text.hasPrefix("+") {
                lines.append(DiffLine(id: i, kind: .added, text: String(text.dropFirst()), oldNumber: nil, newNumber: newLine))
                newLine += 1
            } else if text.hasPrefix("-") {
                lines.append(DiffLine(id: i, kind: .removed, text: String(text.dropFirst()), oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            } else if text.hasPrefix("\\") {
                // "\ No newline at end of file"
                lines.append(DiffLine(id: i, kind: .meta, text: text, oldNumber: nil, newNumber: nil))
            } else {
                lines.append(DiffLine(id: i, kind: .context, text: String(text.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return (lines, false)
    }

    /// `@@ -12,7 +12,9 @@ func x()` → (12, 12).
    package static func hunkStarts(_ header: String) -> (Int, Int) {
        func start(after marker: Character) -> Int {
            guard let range = header.firstIndex(of: marker) else { return 1 }
            let digits = header[header.index(after: range)...].prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (start(after: "-"), start(after: "+"))
    }
}
