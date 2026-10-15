import Foundation

/// A question an agent is holding the terminal open for, read off the
/// screen.
///
/// Both agents ask the same shape of question — a sentence, then numbered
/// choices, one of them marked — and answer it by the number plus Return.
/// The inbox needs that shape so it can offer the real choices rather than
/// guessing: it only ever sends a number it actually read, so a prompt it
/// cannot parse gets no buttons instead of the wrong one.
struct AgentPrompt: Equatable {
    struct Choice: Equatable {
        /// What to type: "1", "2", …
        let key: String
        let label: String
        /// The one the agent has highlighted, which Return would take.
        let isDefault: Bool
    }

    /// "Do you want to make this edit?"
    let question: String
    let choices: [Choice]
    /// The few lines above the question — the diff, or the command.
    let preview: [String]

    /// The choice Return takes: the marked one, else the first.
    var `default`: Choice? { choices.first(where: \.isDefault) ?? choices.first }

    /// The one that means no. Both agents put it last, and both word it
    /// with "no" — matching the word rather than the position, because
    /// "don't ask again" is also not a yes.
    var deny: Choice? {
        choices.last { $0.label.lowercased().hasPrefix("no") }
    }

    /// "…and don't ask again": worth its own button, and never one we
    /// press by guessing at a position.
    var always: Choice? {
        choices.first { $0.label.lowercased().contains("don't ask again") || $0.label.lowercased().contains("dont ask again") }
    }

    /// `❯ 1. Yes` — the marker is optional, the number and the label are
    /// not. Built per call: a `Regex` is not Sendable, so it cannot be a
    /// static on a type this is parsed from.
    private static func option() -> Regex<(Substring, marker: Substring, key: Substring, label: Substring)> {
        /^\s*(?<marker>[❯>*]?)\s*(?<key>\d{1,2})[.)]\s+(?<label>\S.*)$/
    }

    /// Reads the end of a pane's visible text. Only the last run of
    /// numbered lines counts: earlier ones are output that happens to be
    /// a list, and the question is always the newest thing on screen.
    static func parse(_ text: String) -> AgentPrompt? {
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\u{00a0}", with: " ") }
        // Walk back to the last numbered line, then up while they continue.
        let option = option()
        guard let last = lines.lastIndex(where: { $0.wholeMatch(of: option) != nil }) else { return nil }
        var first = last
        while first > 0, lines[first - 1].wholeMatch(of: option) != nil { first -= 1 }

        var choices: [Choice] = []
        for line in lines[first...last] {
            guard let match = line.wholeMatch(of: option) else { continue }
            choices.append(
                Choice(
                    key: String(match.output.key),
                    label: String(match.output.label).trimmingCharacters(in: .whitespaces),
                    isDefault: !match.output.marker.isEmpty))
        }
        // One choice is a list, not a question.
        guard choices.count >= 2 else { return nil }

        let above = lines[..<first].reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let question = above.first?.trimmingCharacters(in: .whitespaces), !question.isEmpty else { return nil }
        // The block above it, skipping the blank line that usually
        // separates the two: the diff, or the command being asked about.
        let preview =
            above
            .dropFirst()
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(8)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return AgentPrompt(question: question, choices: choices, preview: Array(preview))
    }

    /// A one-line summary for the card's title: "wants to make this edit".
    var summary: String {
        var text = question
        for prefix in ["Do you want to ", "Would you like to ", "Do you want "] where text.hasPrefix(prefix) {
            text = "wants to " + text.dropFirst(prefix.count)
        }
        if text.hasSuffix("?") { text.removeLast() }
        return text
    }
}
