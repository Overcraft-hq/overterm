import Foundation

/// What a million tokens cost, so the pane can put a number on a day's
/// work. An estimate and labelled as one: the rates below are the list
/// prices, and what you actually pay depends on your plan.
///
/// Read off platform.claude.com/docs/en/about-claude/pricing and
/// openai.com/api/pricing on 2026-10-15. A model nobody here knows has no
/// price at all (`rate(for:) == nil`) — the pane then shows its tokens and
/// says so, rather than a confident wrong number.
enum ModelPricing {
    /// Dollars per million tokens.
    struct Rate: Equatable, Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        /// Writing into the five-minute cache, and into the hour-long one.
        let cacheWrite5m: Double
        let cacheWrite1h: Double

        func cost(_ tokens: UsageTokens) -> Double {
            (Double(tokens.input) * input + Double(tokens.output) * output + Double(tokens.cacheRead) * cacheRead
                + Double(tokens.cacheWrite5m) * cacheWrite5m + Double(tokens.cacheWrite1h) * cacheWrite1h) / 1_000_000
        }
    }

    /// Longest prefix wins, so "claude-opus-5-5" doesn't read as
    /// "claude-opus-5". Dated names ("claude-opus-5-20261001") match their
    /// family.
    private static let rates: [(prefix: String, rate: Rate)] = [
        ("claude-opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20, cacheWrite5m: 5, cacheWrite1h: 8)),
        ("claude-opus-5", Rate(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        // Opus 4.5 and later are a third of Opus 4 and 4.1: priced at those,
        // a day of Opus 4.8 read as three.
        ("claude-opus-4-8", Rate(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("claude-opus-4-7", Rate(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("claude-opus-4-6", Rate(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("claude-opus-4-5", Rate(input: 5, output: 25, cacheRead: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10)),
        ("claude-opus-4", Rate(input: 15, output: 75, cacheRead: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30)),
        ("claude-sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4)),
        ("claude-sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.20, cacheWrite5m: 2.50, cacheWrite1h: 4)),
        ("claude-sonnet-4", Rate(input: 3, output: 15, cacheRead: 0.30, cacheWrite5m: 3.75, cacheWrite1h: 6)),
        ("claude-haiku-5", Rate(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.20)),
        ("claude-haiku-4", Rate(input: 1, output: 5, cacheRead: 0.10, cacheWrite5m: 1.25, cacheWrite1h: 2)),
        // Fable 5.1 reads its cache at a quarter of Fable 5's.
        ("claude-fable-5-1", Rate(input: 10, output: 50, cacheRead: 0.25, cacheWrite5m: 12.50, cacheWrite1h: 20)),
        ("claude-fable-5", Rate(input: 10, output: 50, cacheRead: 1.00, cacheWrite5m: 12.50, cacheWrite1h: 20)),
        // Codex's models. The cache write is free there; a cached input
        // token is a tenth of a fresh one.
        ("gpt-5.6", Rate(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5.5", Rate(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("gpt-5", Rate(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite5m: 0, cacheWrite1h: 0)),
        ("o4", Rate(input: 1.10, output: 4.40, cacheRead: 0.275, cacheWrite5m: 0, cacheWrite1h: 0)),
    ]

    /// The rate for a model name as the logs write it, or nil for one this
    /// table has never heard of.
    static func rate(for model: String) -> Rate? {
        let name = model.lowercased()
        return
            rates
            .filter { name.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .rate
    }

    /// What `tokens` of `model` cost, or nil when the model has no rate.
    static func cost(_ tokens: UsageTokens, model: String) -> Double? {
        rate(for: model)?.cost(tokens)
    }

    /// The name a person reads: "opus 5", "sonnet 5", "gpt-5.6".
    static func shortName(_ model: String) -> String {
        var name = model
        for prefix in ["claude-", "anthropic/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        // "opus-5-20261001" → "opus-5"
        let parts = name.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            name = parts.dropLast().joined(separator: "-")
        }
        return name.replacingOccurrences(of: "-", with: " ")
    }
}
