import Foundation

/// Where a link's `#Heading` or `#^block` is in a note's text — the line
/// the editor goes to when a link is followed in Live Preview, matched as
/// the reading view matches it (headings by their text, case and the
/// spaces around it aside; a block by the `^id` its line ends with). Pure.
package enum NoteAnchor {
    /// The line (from 0), or nil when the note has no such heading or block.
    package static func line(of anchor: String, in text: String) -> Int? {
        // `Note#Section#Sub`: Obsidian's path of headings ends at the one meant.
        let last = anchor.split(separator: "#", omittingEmptySubsequences: true).last.map(String.init) ?? anchor
        let wanted = last.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let document = NoteParser.parse(text)
        if wanted.hasPrefix("^") {
            let id = String(wanted.dropFirst())
            guard !id.isEmpty else { return nil }
            let code = NoteParser.codeRanges(in: text as NSString)
            var location = 0
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                defer { location += (line as NSString).length + 1 }
                guard !NoteParser.contains(code, location) else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "^" + id || trimmed.hasSuffix(" ^" + id) { return number }
            }
            return nil
        }
        let key = wanted.lowercased()
        return document.headings.first { $0.text.trimmingCharacters(in: .whitespaces).lowercased() == key }?.line
    }
}
