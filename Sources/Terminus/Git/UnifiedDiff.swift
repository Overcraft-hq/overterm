import Foundation

/// A unified diff split into lines the panel can colour and number.
struct DiffLine: Identifiable, Hashable {
    enum Kind: Hashable { case meta, hunk, context, added, removed }

    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

enum UnifiedDiff {
    /// Classifies each line and numbers it from the hunk headers. Lines
    /// before the first hunk (diff --git, index, ---/+++) are meta.
    static func parse(_ diff: String, limit: Int = 20_000) -> (lines: [DiffLine], truncated: Bool) {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        let raw = diff.split(separator: "\n", omittingEmptySubsequences: false)
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
    static func hunkStarts(_ header: String) -> (Int, Int) {
        func start(after marker: Character) -> Int {
            guard let range = header.firstIndex(of: marker) else { return 1 }
            let digits = header[header.index(after: range)...].prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (start(after: "-"), start(after: "+"))
    }
}
