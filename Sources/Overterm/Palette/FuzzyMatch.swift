import Foundation

/// Subsequence matching with a score, for the palette. "ncl" finds "New
/// Claude Tab". Higher is better; nil means no match.
enum FuzzyMatch {
    static func score(_ query: String, in candidate: String) -> Int? {
        let query = query.lowercased().filter { !$0.isWhitespace }
        guard !query.isEmpty else { return 0 }
        let text = Array(candidate.lowercased())
        var score = 0
        var ti = 0
        var previousMatch = -2
        for q in query {
            var found = false
            while ti < text.count {
                if text[ti] == q {
                    // Consecutive letters, and letters starting a word, count most.
                    if ti == previousMatch + 1 { score += 5 }
                    if ti == 0 || !text[ti - 1].isLetter { score += 8 }
                    score += 1
                    previousMatch = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        // Prefer shorter candidates among equal matches.
        return score * 100 - text.count
    }
}
