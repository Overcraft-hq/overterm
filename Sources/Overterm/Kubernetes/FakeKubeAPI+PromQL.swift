import Foundation

/// What the fake Prometheus answers a query with, before it evaluates
/// anything (docs/design/kubernetes/metrics.md, §8, The fake): a fixture
/// matched by a fragment the query contains, compared without whitespace
/// — never by parsing PromQL. Its lines are functions of t (nil a gap), so
/// a later stage's query (`label_replace`, `max_over_time`, a subquery…)
/// is answered without teaching `FakePromQL` its grammar. Without lines it
/// adds its warnings to what `FakePromQL` evaluates (a Thanos store's
/// partial answer); with a failure it answers that instead.
struct FakePromFixture: Sendable {
    struct Line: Sendable {
        var labels: [String: String]
        var value: @Sendable (_ time: Double) -> Double?

        init(_ labels: [String: String] = [:], value: @escaping @Sendable (_ time: Double) -> Double?) {
            self.labels = labels
            self.value = value
        }
    }

    struct Failure: Sendable, Equatable {
        var status: Int
        var errorType: String
        var error: String
    }

    var fragment: String
    var lines: [Line]?
    var warnings: [String] = []
    var failure: Failure?

    /// An empty fragment matches every query (an agent answers none).
    func matches(_ query: String) -> Bool { fragment.isEmpty || Self.normalised(query).contains(Self.normalised(fragment)) }

    static func normalised(_ text: String) -> String { text.filter { !$0.isWhitespace } }
}

/// As much PromQL as M0's queries need, evaluated over the fake
/// Prometheus's series (the tests' and the scenarios', never a real one),
/// so the de-duplication and the active-pod join are shown on data rather
/// than golden strings alone: a selector with `=`, `!=`, `=~`, `!~`
/// matchers; `rate(…[w])` (a series' value taken as its rate); `sum`,
/// `max`, `min`, `count`, with or without `by (…)`; `== n`;
/// `a * on(…) group_left() b`; and, for the Pods list's shares (M5b, so
/// their union is shown on kube-state-metrics' raw series), `a or b`,
/// `a and on(…) b`, `a == on(…) group_left() b` and `label_replace`. It
/// is not extended past that: a later query is answered by a
/// `FakePromFixture` (`setPrometheusMatrix`).
/// Anything neither reads is nil — answered `bad_data`, so a query the
/// fake can't read fails the test that sent it rather than answering
/// something made up.
enum FakePromQL {
    struct Sample: Equatable {
        var labels: [String: String]
        var value: Double
    }

    typealias Series = (metric: String, labels: [String: String], value: Double)

    static func evaluate(_ promql: String, _ series: [Series]) -> [Sample]? {
        guard let tokens = tokenize(promql) else { return nil }
        var parser = Parser(tokens: tokens, series: series)
        guard let result = parser.union(), parser.at == tokens.count else { return nil }
        return result.sorted { $0.labels.description < $1.labels.description }
    }

    enum Token: Equatable {
        case word(String)
        case text(String)
        case symbol(String)
    }

    static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == ":" || c == "." }
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace {
                index += 1
            } else if c == "\"" {
                var value = ""
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                        value.append(characters[index] == "n" ? "\n" : characters[index])
                    } else {
                        value.append(characters[index])
                    }
                    index += 1
                }
                guard index < characters.count else { return nil }
                index += 1
                tokens.append(.text(value))
            } else if isWord(c) {
                var word = ""
                while index < characters.count, isWord(characters[index]) {
                    word.append(characters[index])
                    index += 1
                }
                tokens.append(.word(word))
            } else {
                let two = index + 1 < characters.count ? String([c, characters[index + 1]]) : ""
                if ["==", "=~", "!=", "!~"].contains(two) {
                    tokens.append(.symbol(two))
                    index += 2
                } else if "(){}[],=*".contains(c) {
                    tokens.append(.symbol(String(c)))
                    index += 1
                } else {
                    return nil
                }
            }
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        let series: [Series]
        var at = 0

        private var next: Token? { at < tokens.count ? tokens[at] : nil }

        private mutating func take(_ symbol: String) -> Bool {
            guard next == .symbol(symbol) else { return false }
            at += 1
            return true
        }

        private mutating func word() -> String? {
            guard case .word(let word) = next else { return nil }
            at += 1
            return word
        }

        /// `(a, b)`, possibly empty.
        private mutating func labels() -> [String]? {
            guard take("(") else { return nil }
            var names: [String] = []
            while !take(")") {
                guard let name = word() else { return nil }
                names.append(name)
                _ = take(",")
            }
            return names
        }

        /// `a or b`: a's samples, and b's whose labels a has none of.
        mutating func union() -> [Sample]? {
            guard var left = intersection() else { return nil }
            while next == .word("or") {
                at += 1
                guard let right = intersection() else { return nil }
                left += right.filter { other in !left.contains { $0.labels == other.labels } }
            }
            return left
        }

        /// `a and on(…) b`: a's samples that b has one of, matched on those labels (all, without `on`).
        mutating func intersection() -> [Sample]? {
            guard var left = compare() else { return nil }
            while next == .word("and") {
                at += 1
                guard let on = matching(), let right = compare() else { return nil }
                left = left.filter { sample in right.contains { Self.same(sample, $0, on: on.on) } }
            }
            return left
        }

        /// How two vectors' samples are matched: `on` nil, by every label.
        private struct Match {
            var on: [String]?
        }

        /// `on(…)` and `group_left(…)`, either or both.
        private mutating func matching() -> Match? {
            var on: [String]?
            if next == .word("on") {
                at += 1
                on = labels()
                guard on != nil else { return nil }
            }
            if next == .word("group_left") {
                at += 1
                guard labels() != nil else { return nil }
            }
            return Match(on: on)
        }

        private static func same(_ a: Sample, _ b: Sample, on: [String]?) -> Bool {
            guard let on else { return a.labels == b.labels }
            return on.allSatisfy { a.labels[$0] == b.labels[$0] }
        }

        mutating func compare() -> [Sample]? {
            guard var left = product() else { return nil }
            while take("==") {
                if case .word(let text)? = next, let number = Double(text) {
                    at += 1
                    left = left.filter { $0.value == number }
                    continue
                }
                // A vector: a's samples equal to their match's value, a's labels kept.
                guard let on = matching(), let right = product() else { return nil }
                left = left.filter { sample in right.contains { Self.same(sample, $0, on: on.on) && $0.value == sample.value } }
            }
            return left
        }

        mutating func product() -> [Sample]? {
            guard var left = unary() else { return nil }
            while take("*") {
                var on: [String]?
                if next == .word("on") {
                    at += 1
                    on = labels()
                    guard on != nil else { return nil }
                }
                if next == .word("group_left") {
                    at += 1
                    guard labels() != nil else { return nil }
                }
                guard let right = unary() else { return nil }
                left = left.compactMap { sample in
                    let key = on.map { names in names.map { sample.labels[$0] ?? "" } }
                    guard
                        let match = right.first(where: { other in
                            key.map { $0 == on!.map { other.labels[$0] ?? "" } } ?? (other.labels == sample.labels)
                        })
                    else { return nil }
                    return Sample(labels: sample.labels, value: sample.value * match.value)
                }
            }
            return left
        }

        mutating func unary() -> [Sample]? {
            if take("(") {
                guard let inner = union(), take(")") else { return nil }
                return inner
            }
            guard let name = word() else { return nil }
            if name == "label_replace", take("(") {
                // label_replace(v, dst, replacement, src, regex): dst set where src's value matches.
                var texts: [String] = []
                guard let inner = union() else { return nil }
                while take(",") {
                    guard case .text(let text)? = next else { return nil }
                    at += 1
                    texts.append(text)
                }
                guard take(")"), texts.count == 4,
                    let regex = try? NSRegularExpression(pattern: "^(?:" + texts[3] + ")$")
                else { return nil }
                return inner.map { sample in
                    let source = sample.labels[texts[2]] ?? ""
                    let range = NSRange(source.startIndex..., in: source)
                    guard regex.firstMatch(in: source, range: range) != nil else { return sample }
                    var labels = sample.labels
                    let value = regex.stringByReplacingMatches(in: source, range: range, withTemplate: texts[1])
                    labels[texts[0]] = value.isEmpty ? nil : value
                    return Sample(labels: labels, value: sample.value)
                }
            }
            if ["sum", "max", "min", "count"].contains(name), next == .symbol("(") || next == .word("by") {
                var by: [String]?
                if next == .word("by") {
                    at += 1
                    by = labels()
                    guard by != nil else { return nil }
                }
                guard take("("), let inner = union(), take(")") else { return nil }
                return aggregate(name, by: by, inner)
            }
            if name == "rate", take("(") {
                guard let inner = selector(word()), take("["), word() != nil, take("]"), take(")") else { return nil }
                return inner
            }
            return selector(name)
        }

        private mutating func selector(_ name: String?) -> [Sample]? {
            guard let name else { return nil }
            var matchers: [(String, String, String)] = []
            if take("{") {
                while !take("}") {
                    guard let label = word(), case .symbol(let op)? = next, ["=", "!=", "=~", "!~"].contains(op) else { return nil }
                    at += 1
                    guard case .text(let value)? = next else { return nil }
                    at += 1
                    matchers.append((label, op, value))
                    _ = take(",")
                }
            }
            return series.compactMap { item in
                guard item.metric == name else { return nil }
                for (label, op, value) in matchers {
                    let have = item.labels[label] ?? ""
                    let ok: Bool
                    switch op {
                    case "=": ok = have == value
                    case "!=": ok = have != value
                    case "=~": ok = FakePromQL.matches(have, value)
                    default: ok = !FakePromQL.matches(have, value)
                    }
                    if !ok { return nil }
                }
                return Sample(labels: item.labels, value: item.value)
            }
        }

        private func aggregate(_ operation: String, by: [String]?, _ samples: [Sample]) -> [Sample] {
            var groups: [[String: String]: [Double]] = [:]
            for sample in samples {
                let key = Dictionary(uniqueKeysWithValues: (by ?? []).compactMap { name in sample.labels[name].map { (name, $0) } })
                groups[key, default: []].append(sample.value)
            }
            return groups.map { labels, values in
                let value: Double
                switch operation {
                case "max": value = values.max() ?? 0
                case "min": value = values.min() ?? 0
                case "count": value = Double(values.count)
                default: value = values.reduce(0, +)
                }
                return Sample(labels: labels, value: value)
            }
        }
    }

    /// An anchored RE2 match, as Prometheus's.
    static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
