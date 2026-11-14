import Foundation

/// A context's saved queries (docs/design/kubernetes/metrics.md, decision
/// 11; stage M8d): the user's own application metrics — request rate,
/// latency, queue depth — which Prometheus already has for many apps,
/// written by the user into the context's `kubernetes.contexts` entry
/// (`charts: [{title, query, unit}]`) and drawn on a workload's Metrics
/// tab. Never an agent's: no tool reads or writes them, so "no free-form
/// PromQL for agents" (§7) holds.
///
/// A query is the user's, but what it may cost isn't: before it is sent,
/// every selector must carry the scope's matchers — `namespace="$ns"`
/// (that label itself) and a positive matcher whose whole value is `$pod`
/// (`=~`) or `$name` (`=` or `=~`), never a pattern around it — so it reads one
/// workload's series, never a namespace's or the cluster's; a subquery
/// is refused (Prometheus evaluates it at every step), a range longer
/// than an hour too (`$w`, the charts' own rate window, is the way to
/// say "rate over a few scrapes"); at most `atMost` a context, each at
/// most `lengthAtMost` characters. `$ns` and `$name` are filled in
/// escaped — as a literal in `=`, as a regex in `=~` (`regexLiteral`
/// first, then `literal`) — and `$pod` is the workload's pods' names as
/// a regex (`KubeTabQueries.podPattern`), so it goes in `=~` only. It is
/// then one of the Service's two paths, `query_range`, under the tab's
/// queue, its timeout, its 8 MB and its 12 series a chart. Pure.
struct KubeSavedChart: Hashable, Sendable {
    /// What a saved chart's numbers are, as `unit` names them.
    enum Unit: String, CaseIterable, Sendable {
        case count, perSecond, seconds, percent, bytes, bytesPerSecond, cores

        var chartUnit: KubeChartUnit {
            switch self {
            case .count: .count
            case .perSecond: .perSecond
            case .seconds: .seconds
            case .percent: .ratio
            case .bytes: .bytes
            case .bytesPerSecond: .bytesPerSecond
            case .cores: .cores
            }
        }

        var title: String {
            switch self {
            case .count: "a number"
            case .perSecond: "a rate, a second"
            case .seconds: "seconds (latency)"
            case .percent: "a fraction from 0 to 1, said as a percent"
            case .bytes: "bytes"
            case .bytesPerSecond: "bytes a second"
            case .cores: "CPU cores"
            }
        }

        /// Its lines add up: past the twelve, the rest are summed as "other".
        var additive: Bool { [.count, .perSecond, .bytes, .bytesPerSecond, .cores].contains(self) }
    }

    var title: String
    var query: String
    var unit: Unit = .count

    /// The entry's `charts`, as typed: those with a title and a query, in
    /// order (the schema says what is wrong with the others).
    static func of(_ records: [[String: String]]) -> [KubeSavedChart] {
        records.compactMap { record in
            let title = record["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let query = record["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !query.isEmpty else { return nil }
            return KubeSavedChart(title: title, query: query, unit: record["unit"].flatMap(Unit.init(rawValue:)) ?? .count)
        }
    }

    /// The `charts` field of a context's entry, for SettingsSchema.
    static let field = SettingField(
        name: "charts",
        kind: .records([
            SettingField(name: "title", kind: .text(placeholder: "Requests", monospaced: false), required: true),
            SettingField(name: "query", kind: .text(placeholder: "", monospaced: true), required: true),
            SettingField(name: "unit", kind: .choice(Unit.allCases.map { SettingOption(value: $0.rawValue, label: $0.title) })),
        ]),
        help:
            "Your own charts on a workload's Metrics tab, from this context's Prometheus: [{\"title\": \"Requests\", \"query\": \"sum(rate(http_requests_total{namespace=\\\"$ns\\\",pod=~\\\"$pod\\\"}[$w]))\", \"unit\": \"perSecond\"}]. $ns is the namespace, $name the workload, $pod its pods' names as a regex (=~ only), $w the charts' rate window. Every selector needs namespace=\"$ns\" and pod=~\"$pod\" or a label =\"$name\", each the placeholder alone; no subqueries, no range over 1h; at most 6. Only ever yours: agents can't read or write them."
    )
}

enum KubeSavedQueries {
    /// At most this many a context are asked; the rest are said, not asked.
    static let atMost = 6
    /// A query's length as typed: past it, refused (it goes in a URL).
    static let lengthAtMost = 2000
    /// The longest range a selector may read at each step.
    static let rangeAtMost: TimeInterval = 3600

    /// The tab's id of the `index`th saved chart's query.
    static func id(_ index: Int) -> String { "saved.\(index)" }

    /// `query` with `$ns`, `$name`, `$pod` and `$w` filled in for a
    /// workload — or why it isn't sent.
    static func fill(_ query: String, namespace: String, kind: String, name: String, window: TimeInterval) -> Result<String, KubeCommands.Refused> {
        func refused(_ why: String) -> Result<String, KubeCommands.Refused> { .failure(KubeCommands.Refused(reason: why)) }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return refused("it is empty.") }
        guard text.count <= lengthAtMost else { return refused("it is longer than \(lengthAtMost) characters.") }
        let tokens: [Token]
        do {
            tokens = try lex(Array(text))
        } catch let error as KubeCommands.Refused {
            return .failure(error)
        } catch {
            return refused("it isn't PromQL Overterm can read.")
        }
        let chars = Array(text)
        var replacements: [(Range<Int>, String)] = []
        var index = 0
        func next(_ at: Int) -> Token? { at < tokens.count ? tokens[at] : nil }
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .ident(let word):
                let lower = word.lowercased()
                // PromQL takes every keyword as a metric's name too, so a
                // keyword is one only where the grammar puts it; anywhere
                // else it is a selector, checked like any other.
                let before = index > 0 ? tokens[index - 1].kind : nil
                if labelLists.contains(lower), next(index + 1)?.kind == .punct("(") {
                    // by (…), on (…): label names, never selectors.
                    index = skip(tokens, from: index + 1)
                    continue
                }
                if ["group_left", "group_right"].contains(lower), before == .punct(")") {
                    // `on (…) group_left`, without a list of its own.
                    index += 1
                    continue
                }
                if numbers.contains(lower) || next(index + 1)?.kind == .punct("(") {
                    index += 1
                    continue
                }
                if aggregations.contains(lower), case .ident(let after)? = next(index + 1)?.kind, ["by", "without"].contains(after.lowercased()) {
                    index += 1
                    continue
                }
                if binaryOperators.contains(lower), let before, endsOperand(before) {
                    index += 1
                    continue
                }
                if lower == "bool", case .punct(let op)? = before, ["==", "!=", "<", ">", "<=", ">="].contains(op) {
                    index += 1
                    continue
                }
                if lower == "offset", let before, endsOperand(before) {
                    var at = index + 1
                    if next(at)?.kind == .punct("-") { at += 1 }
                    if case .number(let duration)? = next(at)?.kind, Self.seconds(duration) != nil {
                        index = at + 1
                        continue
                    }
                }
                if next(index + 1)?.kind == .punct("{") {
                    switch selector(tokens, from: index + 1, chars: chars, metric: word, namespace: namespace, kind: kind, name: name) {
                    case .failure(let why): return .failure(why)
                    case .success(let (end, filled)):
                        replacements += filled
                        index = end
                    }
                    continue
                }
                return refused("\(word) has no label matchers: every selector needs namespace=\"$ns\" and a matcher on $pod or $name.")
            case .punct("{"):
                switch selector(tokens, from: index, chars: chars, metric: nil, namespace: namespace, kind: kind, name: name) {
                case .failure(let why): return .failure(why)
                case .success(let (end, filled)):
                    replacements += filled
                    index = end
                }
                continue
            case .punct("["):
                var seconds: TimeInterval = 0
                var at = index + 1
                while let inside = next(at), inside.kind != .punct("]") {
                    switch inside.kind {
                    case .punct(":"):
                        return refused("it has a subquery ([…:…]): Prometheus would evaluate it at every step.")
                    case .placeholder("w"):
                        seconds += window
                        replacements.append((inside.range, KubePromQL.duration(window)))
                    case .number(let duration):
                        guard let length = Self.seconds(duration) else { return refused("\(duration) isn't a duration.") }
                        seconds += length
                    case .placeholder(let other):
                        return refused("$\(other) isn't filled in inside a range: only $w is.")
                    default:
                        return refused("its range […] isn't a duration.")
                    }
                    at += 1
                }
                guard next(at) != nil else { return refused("a range […] isn't closed.") }
                if seconds > rangeAtMost {
                    return refused("it reads a range longer than \(KubePromQL.duration(rangeAtMost)) at every step: use $w, or a recording rule.")
                }
                index = at + 1
                continue
            case .placeholder(let word):
                return refused(
                    word == "w"
                        ? "$w is filled in only inside a range's brackets: rate(…[$w])."
                        : "$\(word) is filled in only in a label matcher's value, like namespace=\"$ns\".")
            case .string(let raw, _):
                if placeholders(in: raw) {
                    return refused("$ns, $pod and $name are filled in only in a label matcher's value, not in other strings.")
                }
            default:
                break
            }
            index += 1
        }
        var out = ""
        var at = 0
        for (range, text) in replacements.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            out += String(chars[at..<range.lowerBound])
            out += text
            at = range.upperBound
        }
        out += String(chars[at...])
        return .success(out)
    }

    // MARK: Selectors

    /// A selector's matcher block from its `{`: each matcher checked and
    /// filled; the scope's matchers required. The token after its `}`, and
    /// what to put where.
    private static func selector(
        _ tokens: [Token], from start: Int, chars: [Character], metric: String?, namespace: String, kind: String, name: String
    ) -> Result<(Int, [(Range<Int>, String)]), KubeCommands.Refused> {
        func refused(_ why: String) -> Result<(Int, [(Range<Int>, String)]), KubeCommands.Refused> { .failure(KubeCommands.Refused(reason: why)) }
        var at = start + 1
        var inNamespace = false
        var ofWorkload = false
        var filled: [(Range<Int>, String)] = []
        var named = metric
        while at < tokens.count {
            if tokens[at].kind == .punct("}") { break }
            if tokens[at].kind == .punct(",") {
                at += 1
                continue
            }
            // A label (or, quoted alone, the metric's name: PromQL 3).
            let label: String
            switch tokens[at].kind {
            case .ident(let word): label = word
            case .string(let raw, let quote):
                guard let text = unquote(raw, quote: quote) else { return refused("\(raw) isn't a string Prometheus reads.") }
                if at + 1 < tokens.count, [Token.Kind.punct(","), .punct("}")].contains(tokens[at + 1].kind) {
                    named = text
                    at += 1
                    continue
                }
                label = text
            default:
                return refused("a selector's {…} holds something other than label matchers.")
            }
            guard at + 2 < tokens.count, case .punct(let op) = tokens[at + 1].kind, ["=", "!=", "=~", "!~"].contains(op),
                case .string(let raw, let quote) = tokens[at + 2].kind
            else { return refused("a selector's {…} holds something other than label matchers.") }
            guard let value = unquote(raw, quote: quote) else { return refused("\(raw) isn't a string Prometheus reads.") }
            let regex = op == "=~" || op == "!~"
            // The scope's matchers are exact: `namespace` itself (not
            // `exported_namespace`, which leaves the real one open), and a
            // value that is the placeholder alone — `pod=~"$pod|.*"` or
            // `app=~"$name.*"` mentions it and still reads the namespace.
            if label == "namespace", op == "=", value == "$ns" { inNamespace = true }
            if label != "namespace", label != "__name__", (op == "=~" && (value == "$pod" || value == "$name")) || (op == "=" && value == "$name") { ofWorkload = true }
            if placeholders(in: value) {
                if !regex, mentions(value, "pod") {
                    return refused("$pod is a pattern of the workload's pods' names: use it in a regex matcher, pod=~\"$pod\".")
                }
                var text = ""
                var rest = Substring(value)
                while let dollar = rest.firstIndex(of: "$") {
                    text += rest[..<dollar]
                    let after = rest[rest.index(after: dollar)...]
                    let word = String(after.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                    switch word {
                    case "ns": text += regex ? KubePromQL.regexLiteral(namespace) : namespace
                    case "name": text += regex ? KubePromQL.regexLiteral(name) : name
                    case "pod": text += KubeTabQueries.podPattern(kind: kind, name: name)
                    default: text += "$" + word
                    }
                    rest = after.dropFirst(word.count)
                }
                text += rest
                filled.append((tokens[at + 2].range, "\"" + KubePromQL.literal(text) + "\""))
            }
            at += 3
        }
        guard at < tokens.count else { return refused("a selector's {…} isn't closed.") }
        let what = named.map { "\($0){…}" } ?? "{…}"
        if !inNamespace || !ofWorkload {
            return refused("\(what) needs namespace=\"$ns\" and pod=~\"$pod\" or a label =\"$name\", each the placeholder alone, so it reads this workload's series alone.")
        }
        return .success((at + 1, filled))
    }

    /// Whether `value` holds `$ns`, `$pod` or `$name`.
    private static func placeholders(in value: String) -> Bool { ["ns", "pod", "name"].contains { mentions(value, $0) } }

    /// Whether `value` holds `$word`, a whole word.
    private static func mentions(_ value: String, _ word: String) -> Bool {
        var rest = Substring(value)
        while let range = rest.range(of: "$" + word) {
            let after = rest[range.upperBound...]
            if !(after.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false) { return true }
            rest = after
        }
        return false
    }

    /// The token after the `)` that closes the `(` at `start`.
    private static func skip(_ tokens: [Token], from start: Int) -> Int {
        var depth = 0
        var at = start
        while at < tokens.count {
            if tokens[at].kind == .punct("(") { depth += 1 }
            if tokens[at].kind == .punct(")") {
                depth -= 1
                if depth == 0 { return at + 1 }
            }
            at += 1
        }
        return at
    }

    /// Words that are never a metric's name: a label list follows these…
    private static let labelLists: Set<String> = ["by", "without", "on", "ignoring", "group_left", "group_right"]
    /// …these are numbers, always…
    private static let numbers: Set<String> = ["inf", "nan"]
    /// …these aggregations, followed by `(` or by `by`/`without`…
    private static let aggregations: Set<String> = [
        "sum", "min", "max", "avg", "group", "stddev", "stdvar", "count", "count_values", "bottomk", "topk", "quantile", "limitk", "limit_ratio",
    ]
    /// …and these operators, after an operand.
    private static let binaryOperators: Set<String> = ["and", "or", "unless", "atan2"]

    /// Whether `kind` can end an operand: an operator may follow it.
    private static func endsOperand(_ kind: Token.Kind) -> Bool {
        switch kind {
        case .punct(let mark): [")", "}", "]"].contains(mark)
        case .ident, .number, .string: true
        case .placeholder: false
        }
    }

    /// `5m`, `1h30m`, `90s`, `1.5` (seconds) in seconds; nil, not a duration.
    static func seconds(_ text: String) -> TimeInterval? {
        if let plain = Double(text) { return plain }
        let units: [(String, TimeInterval)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600), ("d", 86400), ("w", 604_800), ("y", 31_536_000)]
        var total: TimeInterval = 0
        var rest = Substring(text)
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isNumber }
            guard !digits.isEmpty, let number = Double(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            guard let unit = units.first(where: { rest.hasPrefix($0.0) }) else { return nil }
            total += number * unit.1
            rest = rest.dropFirst(unit.0.count)
        }
        return total
    }

    /// A PromQL string's text: backquoted raw, else Go's escapes; nil, one it doesn't know.
    static func unquote(_ raw: String, quote: Character) -> String? {
        let inside = Array(raw.dropFirst().dropLast())
        if quote == "`" { return String(inside) }
        var out = ""
        var at = 0
        while at < inside.count {
            let character = inside[at]
            guard character == "\\" else {
                out.append(character)
                at += 1
                continue
            }
            guard at + 1 < inside.count else { return nil }
            let escaped = inside[at + 1]
            switch escaped {
            case "\\", "\"", "'": out.append(escaped)
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "x", "u", "U":
                let count = escaped == "x" ? 2 : escaped == "u" ? 4 : 8
                guard at + 2 + count <= inside.count, let code = UInt32(String(inside[(at + 2)..<(at + 2 + count)]), radix: 16),
                    let scalar = Unicode.Scalar(code)
                else { return nil }
                out.append(Character(scalar))
                at += 2 + count
                continue
            default:
                return nil
            }
            at += 2
        }
        return out
    }

    // MARK: Tokens

    struct Token: Equatable {
        enum Kind: Equatable {
            case ident(String)
            /// Its text as typed, quotes included, and its quote.
            case string(String, Character)
            case number(String)
            /// `$name`, its name.
            case placeholder(String)
            case punct(String)
        }

        var kind: Kind
        var range: Range<Int>
    }

    /// PromQL's tokens, as far as a check needs them; comments dropped.
    static func lex(_ chars: [Character]) throws -> [Token] {
        var tokens: [Token] = []
        var at = 0
        func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }
        while at < chars.count {
            let character = chars[at]
            if character.isWhitespace {
                at += 1
            } else if character == "#" {
                while at < chars.count, chars[at] != "\n" { at += 1 }
            } else if character == "\"" || character == "'" || character == "`" {
                let start = at
                at += 1
                while at < chars.count, chars[at] != character {
                    if character != "`", chars[at] == "\\" { at += 1 }
                    at += 1
                }
                guard at < chars.count else { throw KubeCommands.Refused(reason: "a string isn't closed.") }
                at += 1
                tokens.append(Token(kind: .string(String(chars[start..<at]), character), range: start..<at))
            } else if character.isLetter || character == "_" {
                let start = at
                while at < chars.count, isWord(chars[at]) || chars[at] == ":" { at += 1 }
                tokens.append(Token(kind: .ident(String(chars[start..<at])), range: start..<at))
            } else if character.isNumber || (character == "." && at + 1 < chars.count && chars[at + 1].isNumber) {
                let start = at
                while at < chars.count, isWord(chars[at]) || chars[at] == "." { at += 1 }
                tokens.append(Token(kind: .number(String(chars[start..<at])), range: start..<at))
            } else if character == "$" {
                let start = at
                at += 1
                while at < chars.count, isWord(chars[at]) { at += 1 }
                tokens.append(Token(kind: .placeholder(String(chars[(start + 1)..<at])), range: start..<at))
            } else {
                let pair = at + 1 < chars.count ? String([character, chars[at + 1]]) : ""
                if ["=~", "!~", "!=", "==", "<=", ">="].contains(pair) {
                    tokens.append(Token(kind: .punct(pair), range: at..<(at + 2)))
                    at += 2
                } else {
                    tokens.append(Token(kind: .punct(String(character)), range: at..<(at + 1)))
                    at += 1
                }
            }
        }
        return tokens
    }
}
