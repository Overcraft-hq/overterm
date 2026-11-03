import Foundation

/// The keys a page's filter field knows: what a word's `name:` means,
/// aliases included. Each page has its own (Docker's is `DockerFilterKey`).
protocol ResourceFilterKey: Hashable, Sendable {
    /// A word with no known key: free text.
    static var text: Self { get }
    /// Every name a key goes by, lowercased (`project`, `p`, `stack`).
    static var names: [String: Self] { get }
}

/// What a page's filter field says: words that must all match, some of
/// them `key:value`, any of them negated with a leading `-`. Words split on
/// whitespace and are matched lowercased (`value`), the words as typed kept
/// for what is case-sensitive (`raw`: a selector sent to a server, as in
/// `label:app=API`); a name the page doesn't know (as in `http://x`) leaves
/// the whole word text, and a known key with no value is nothing. What a term means for a resource is the page's (`matches(by:)`).
///
///     api                    free text
///     status:running         a key's value
///     -status:exited         not that
///     restarts:>3            a value read as a number (`Term.compare`)
///
/// Pure.
struct ResourceFilter<Key: ResourceFilterKey>: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        var key: Key
        /// The value lowercased, for matching.
        var value: String
        var negated: Bool
        /// The value as typed: what a case-sensitive key reads.
        var raw: String

        init(key: Key, value: String, negated: Bool, raw: String? = nil) {
            self.key = key
            self.value = value
            self.negated = negated
            self.raw = raw ?? value
        }
    }

    var terms: [Term]

    var isEmpty: Bool { terms.isEmpty }

    init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).compactMap { word in
            var word = Substring(word)
            let negated = word.hasPrefix("-") && word.count > 1
            if negated { word = word.dropFirst() }
            if let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                let name = word[..<colon].lowercased()
                let raw = String(word[word.index(after: colon)...])
                if let key = Key.names[name] {
                    return raw.isEmpty ? nil : Term(key: key, value: raw.lowercased(), negated: negated, raw: raw)
                }
            }
            return Term(key: .text, value: word.lowercased(), negated: negated, raw: String(word))
        }
    }

    /// Every term holds for a resource — a negated one when it doesn't.
    /// `match` says whether a term, read as not negated, holds.
    func matches(by match: (Term) -> Bool) -> Bool {
        terms.allSatisfy { match($0) != $0.negated }
    }
}

extension ResourceFilter.Term {
    /// The value as a comparison with a number: `>3`, `>=3`, `<3`, `<=3`,
    /// `=3` or `3`. nil when the value is not one.
    var comparison: ResourceFilterComparison? { ResourceFilterComparison(value) }

    /// Whether `number` passes the value as a comparison; false when the
    /// value is not one.
    func compare(_ number: Int) -> Bool { comparison?.holds(for: number) ?? false }
}

/// A filter value read as a number compared: `restarts:>3`.
struct ResourceFilterComparison: Equatable, Sendable {
    enum Operator: String, Sendable { case less = "<", lessOrEqual = "<=", equal = "=", greaterOrEqual = ">=", greater = ">" }

    var op: Operator
    var number: Int

    init(op: Operator, number: Int) {
        self.op = op
        self.number = number
    }

    init?(_ text: String) {
        // Two-character operators first: `>=` is not `>` then `=3`.
        let ops: [Operator] = [.lessOrEqual, .greaterOrEqual, .less, .greater, .equal]
        let op = ops.first { text.hasPrefix($0.rawValue) } ?? .equal
        let digits = text.hasPrefix(op.rawValue) ? text.dropFirst(op.rawValue.count) : Substring(text)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { return nil }
        self.op = op
        self.number = number
    }

    func holds(for value: Int) -> Bool {
        switch op {
        case .less: value < number
        case .lessOrEqual: value <= number
        case .equal: value == number
        case .greaterOrEqual: value >= number
        case .greater: value > number
        }
    }
}
