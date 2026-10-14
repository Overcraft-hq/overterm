import Foundation
import TreeSitterKit

/// A compiled tree-sitter query and what its patterns ask beyond structure:
/// text predicates (`#eq?`, `#match?`, `#any-of?`) and settings (`#set!
/// injection.language "bash"`). Immutable once built — shared by every
/// document of the language, on the syntax queue.
final class SyntaxQuery: @unchecked Sendable {
    let query: OpaquePointer
    let captureNames: [String]
    private let patterns: [Pattern]

    struct Pattern {
        var predicates: [Predicate] = []
        var settings: [String: String] = [:]
    }

    enum Operand {
        case capture(UInt32)
        case string(String)
    }

    enum Predicate {
        case eq(UInt32, Operand, negated: Bool)
        case match(UInt32, NSRegularExpression?, negated: Bool)
        case anyOf(UInt32, Set<String>, negated: Bool)
    }

    /// Nil when the query doesn't compile against the grammar — a query
    /// written for another revision of it. The language then stays plain.
    init?(source: String, language: OpaquePointer, name: String) {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        guard
            let query = utf8.withUnsafeBufferPointer({ buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                    ts_query_new(language, $0, UInt32(buffer.count), &errorOffset, &errorType)
                }
            })
        else {
            let at = String(decoding: utf8.dropFirst(Int(errorOffset)).prefix(60), as: UTF8.self)
            NSLog("Overterm: query %@ doesn't compile (error %d) at: %@", name, errorType.rawValue, at)
            return nil
        }
        self.query = query
        captureNames = (0..<ts_query_capture_count(query)).map { id in
            var length: UInt32 = 0
            return String(cString: ts_query_capture_name_for_id(query, id, &length))
        }
        patterns = (0..<ts_query_pattern_count(query)).map { Self.pattern(query, $0) }
    }

    deinit { ts_query_delete(query) }

    func settings(of pattern: UInt32) -> [String: String] { patterns[Int(pattern)].settings }

    /// Whether a match's text predicates hold. `text` reads a node's text.
    func accepts(pattern: UInt32, captures: UnsafePointer<TSQueryCapture>, count: Int, text: (TSNode) -> String) -> Bool {
        let predicates = patterns[Int(pattern)].predicates
        if predicates.isEmpty { return true }
        func nodes(_ id: UInt32) -> [TSNode] {
            (0..<count).compactMap { captures[$0].index == id ? captures[$0].node : nil }
        }
        for predicate in predicates {
            switch predicate {
            case .eq(let id, let other, let negated):
                let expected: String
                switch other {
                case .string(let value): expected = value
                case .capture(let otherID):
                    guard let node = nodes(otherID).first else { continue }
                    expected = text(node)
                }
                for node in nodes(id) where (text(node) == expected) == negated { return false }
            case .match(let id, let regex, let negated):
                guard let regex else { return false }
                for node in nodes(id) {
                    let value = text(node)
                    let found = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
                    if found == negated { return false }
                }
            case .anyOf(let id, let values, let negated):
                for node in nodes(id) where values.contains(text(node)) == negated { return false }
            }
        }
        return true
    }

    private static func pattern(_ query: OpaquePointer, _ index: UInt32) -> Pattern {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, index, &count), count > 0 else { return Pattern() }
        func string(_ id: UInt32) -> String {
            var length: UInt32 = 0
            return String(cString: ts_query_string_value_for_id(query, id, &length))
        }
        var pattern = Pattern()
        var i = 0
        while i < Int(count) {
            // One predicate: a name, its arguments, then Done.
            var args: [TSQueryPredicateStep] = []
            let head = steps[i]
            i += 1
            while i < Int(count), steps[i].type != TSQueryPredicateStepTypeDone {
                args.append(steps[i])
                i += 1
            }
            i += 1
            guard head.type == TSQueryPredicateStepTypeString else { continue }
            let name = string(head.value_id)
            let negated = name.hasPrefix("not-")
            let operator_ = negated ? String(name.dropFirst(4)) : name
            switch operator_ {
            case "eq?":
                guard args.count == 2, args[0].type == TSQueryPredicateStepTypeCapture else { continue }
                let other: Operand =
                    args[1].type == TSQueryPredicateStepTypeCapture ? .capture(args[1].value_id) : .string(string(args[1].value_id))
                pattern.predicates.append(.eq(args[0].value_id, other, negated: negated))
            case "match?":
                guard args.count == 2, args[0].type == TSQueryPredicateStepTypeCapture else { continue }
                // Helix's are Rust regexes; ICU reads all those the queries use.
                pattern.predicates.append(
                    .match(args[0].value_id, try? NSRegularExpression(pattern: string(args[1].value_id)), negated: negated))
            case "any-of?":
                guard let first = args.first, first.type == TSQueryPredicateStepTypeCapture else { continue }
                pattern.predicates.append(
                    .anyOf(first.value_id, Set(args.dropFirst().map { string($0.value_id) }), negated: negated))
            case "set!":
                let values = args.filter { $0.type == TSQueryPredicateStepTypeString }.map { string($0.value_id) }
                if let key = values.first { pattern.settings[key] = values.count > 1 ? values[1] : "" }
            default:
                // `#is-not? local` and the like: scope tracking this
                // highlighter doesn't do; the pattern applies.
                continue
            }
        }
        return pattern
    }
}
