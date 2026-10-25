import Foundation

/// The vault's notes searched by what they say: every word of the query on
/// a line, case and accents ignored — a few lines a note, the notes whose
/// names match first. Reads the files; run off the main thread.
enum NotesSearch {
    nonisolated static func lines(
        _ query: String, in vault: NotesVault, paths: [String], perNote: Int = 2, limit: Int = 30
    ) -> [ContentMatch] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, query.count >= 2 else { return [] }
        var found: [ContentMatch] = []
        for path in paths {
            if Task.isCancelled || found.count >= limit { break }
            let url = vault.root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A note's text as a whole first: most don't hold every word.
            guard words.allSatisfy({ text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
            var inNote = 0
            var number = 0
            text.enumerateLines { line, stop in
                number += 1
                if words.allSatisfy({ line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                    found.append(ContentMatch(path: path, line: number, text: String(line.trimmingCharacters(in: .whitespaces).prefix(200))))
                    inNote += 1
                    if inNote >= perNote || found.count >= limit { stop = true }
                }
            }
        }
        return found
    }
}
