import Foundation

/// A question an agent is holding the terminal open for, read off the
/// screen.
///
/// Claude Code, Codex and Gemini CLI ask the same shape of question — a
/// sentence, then numbered choices, one of them marked (`❯`, Codex's `›`,
/// Gemini's `●`, inside its round box: `│ ● 1. Allow once │`) — and take
/// the number: Claude Code and Codex then Return, Gemini CLI on the digit
/// alone (its list selects as soon as no longer number could follow —
/// `confirmsOnKey`). opencode's dialog has no numbers and pi asks nothing:
/// no buttons for them (`AgentScreenCheck` still sees opencode's).
/// The inbox needs that shape so it can offer the real choices rather than
/// guessing: it only ever sends a number it actually read, so a prompt it
/// cannot parse gets no buttons instead of the wrong one.
package struct AgentPrompt: Equatable {
    package struct Choice: Equatable {
        /// What to type: "1", "2", …
        package let key: String
        package let label: String
        /// The one the agent has highlighted, which Return would take.
        package let isDefault: Bool
        /// Typing the key alone answers (Gemini CLI): no Return after it,
        /// which would go to its prompt.
        package var confirmsOnKey = false

        package init(key: String, label: String, isDefault: Bool, confirmsOnKey: Bool = false) {
            self.key = key
            self.label = label
            self.isDefault = isDefault
            self.confirmsOnKey = confirmsOnKey
        }
    }

    /// "Do you want to make this edit?"
    package let question: String
    package let choices: [Choice]
    /// The few lines above the question — the diff, or the command.
    package let preview: [String]

    /// The choice Return takes: the marked one, else the first.
    package var `default`: Choice? { choices.first(where: \.isDefault) ?? choices.first }

    /// The one that means no. Both agents put it last, and both word it
    /// with "no" — matching the word rather than the position, because
    /// "don't ask again" is also not a yes.
    package var deny: Choice? {
        choices.last { $0.label.lowercased().hasPrefix("no") }
    }

    /// "…and don't ask again": worth its own button, and never one we
    /// press by guessing at a position.
    package var always: Choice? {
        choices.first {
            let label = $0.label.lowercased()
            return label.contains("don't ask again") || label.contains("dont ask again") || label.contains("for all future sessions")
        }
    }

    /// An approval being asked: a question, one choice marked, and one
    /// that says no — what the screen check (`AgentScreenCheck`) takes for
    /// an agent waiting, and an answer's numbered list never is.
    package var isApproval: Bool {
        question.hasSuffix("?") && choices.contains(where: \.isDefault) && deny != nil
    }

    /// `❯ 1. Yes` — the marker is optional, the number and the label are
    /// not. Built per call: a `Regex` is not Sendable, so it cannot be a
    /// static on a type this is parsed from.
    private static func option() -> Regex<(Substring, marker: Substring, key: Substring, label: Substring)> {
        /^\s*(?<marker>[❯›●>*]?)\s*(?<key>\d{1,2})[.)]\s+(?<label>\S.*)$/
    }

    /// A box's sides (`│ … │`, nested too) and their padding taken off.
    package static func unboxed(_ line: String) -> String {
        var text = Substring(line.replacingOccurrences(of: "\u{00a0}", with: " "))
        let sides: Set<Character> = ["│", "┃", "║"]
        while true {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return "" }
            var inner = Substring(trimmed)
            var cut = false
            if sides.contains(first) {
                inner = inner.dropFirst()
                cut = true
            }
            if let last = inner.last, sides.contains(last) {
                inner = inner.dropLast()
                cut = true
            }
            guard cut else { return String(text) }
            text = inner
        }
    }

    /// Reads the end of a pane's visible text. Only the last run of
    /// numbered lines counts: earlier ones are output that happens to be
    /// a list, and the question is always the newest thing on screen.
    package static func parse(_ text: String) -> AgentPrompt? {
        let lines = text.components(separatedBy: "\n").map(unboxed)
        // Walk back to the last numbered line, then up while they continue.
        let option = option()
        guard let last = lines.lastIndex(where: { $0.wholeMatch(of: option) != nil }) else { return nil }
        var first = last
        while first > 0, lines[first - 1].wholeMatch(of: option) != nil { first -= 1 }

        var choices: [Choice] = []
        var markers: Set<Substring> = []
        for line in lines[first...last] {
            guard let match = line.wholeMatch(of: option) else { continue }
            markers.insert(match.output.marker)
            choices.append(
                Choice(
                    key: String(match.output.key),
                    label: String(match.output.label).trimmingCharacters(in: .whitespaces),
                    isDefault: !match.output.marker.isEmpty))
        }
        // One choice is a list, not a question.
        guard choices.count >= 2 else { return nil }
        // Gemini CLI's `●`: its list takes a digit with no Return (no
        // longer number fits under ten choices).
        if markers.contains("●"), choices.count < 10 {
            choices = choices.map { Choice(key: $0.key, label: $0.label, isDefault: $0.isDefault, confirmsOnKey: true) }
        }

        let above = Array(lines[..<first].reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let nearest = above.first?.trimmingCharacters(in: .whitespaces), !nearest.isEmpty else { return nil }
        // Codex and Gemini CLI put the command between the question and
        // the choices (`$ terraform apply`, `Reason: …`): the question is
        // the nearest line above ending in "?", a few lines up at most.
        if !nearest.hasSuffix("?"),
            let at = above.prefix(8).firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasSuffix("?") })
        {
            let between = above[..<at].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed().map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return AgentPrompt(question: above[at].trimmingCharacters(in: .whitespaces), choices: choices, preview: Array(between))
        }
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
        return AgentPrompt(question: nearest, choices: choices, preview: Array(preview))
    }

    /// A one-line summary for the card's title: "wants to make this edit".
    package var summary: String {
        var text = question
        for prefix in ["Do you want to ", "Would you like to ", "Do you want "] where text.hasPrefix(prefix) {
            text = "wants to " + text.dropFirst(prefix.count)
        }
        // Gemini CLI's "Allow execution of [terraform]?".
        if text.hasPrefix("Allow execution of ") { text = "wants to run " + text.dropFirst("Allow execution of ".count) }
        if text.hasSuffix("?") { text.removeLast() }
        return text
    }
}
