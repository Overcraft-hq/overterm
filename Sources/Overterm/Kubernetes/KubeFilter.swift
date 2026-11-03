import Foundation

/// What the Pods filter knows besides text: `ns:` and `status:`, matched
/// on the rows, and `label:`, which goes to the server (`KubeLabelSelector`)
/// — a row is only cells, it has no labels to match.
enum KubePodFilterKey: ResourceFilterKey {
    case text, namespace, status, label

    static let names: [String: KubePodFilterKey] = [
        "ns": .namespace, "namespace": .namespace, "status": .status, "s": .status, "label": .label, "l": .label,
    ]
}

/// The filter's `label:` words as the label selector the list is asked
/// for: what the server filters by, so a namespace of thousands of pods
/// sends only the matching ones. Read from the words as typed (labels are
/// case-sensitive), each word one requirement or several joined by commas;
/// a leading `-` turns one around. Pure.
///
///     label:app=web          app=web
///     label:app!=web         app!=web
///     -label:app=web         app!=web
///     label:app              app        (has the label)
///     -label:app             !app       (hasn't)
///     label:app=web,tier=fe  app=web,tier=fe
///
/// A word that isn't a requirement the server would take (`label:a b`,
/// `label:=x`, `-label:a=1,b=2`, which would mean "not both") is
/// `refused`, and asks nothing.
enum KubeLabelSelector {
    struct Reading: Equatable, Sendable {
        /// What the list asks for; nil without a `label:` word that holds.
        var selector: String?
        /// The `label:` words that couldn't be read, as typed.
        var refused: [String] = []
    }

    static func read(_ filter: ResourceFilter<KubePodFilterKey>) -> Reading {
        var read: [String] = []
        var refused: [String] = []
        for term in filter.terms where term.key == .label {
            if let requirements = requirements(term.raw, negated: term.negated) {
                read += requirements
            } else {
                refused.append((term.negated ? "-" : "") + "label:" + term.raw)
            }
        }
        return Reading(selector: read.isEmpty ? nil : read.joined(separator: ","), refused: refused)
    }

    static func read(_ text: String) -> Reading { read(ResourceFilter<KubePodFilterKey>(text)) }

    /// One word's requirements; nil when one of them isn't one.
    static func requirements(_ raw: String, negated: Bool) -> [String]? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // "Not (a and b)" is no selector: refused rather than guessed.
        guard !parts.isEmpty, !(negated && parts.count > 1) else { return nil }
        var read: [String] = []
        for part in parts {
            guard let requirement = requirement(part, negated: negated) else { return nil }
            read.append(requirement)
        }
        return read
    }

    static func requirement(_ part: String, negated: Bool) -> String? {
        if let range = part.range(of: "!=") {
            let key = String(part[..<range.lowerBound])
            let value = String(part[range.upperBound...])
            guard isKey(key), isValue(value) else { return nil }
            return negated ? "\(key)=\(value)" : "\(key)!=\(value)"
        }
        if let range = part.range(of: "==") ?? part.range(of: "=") {
            let key = String(part[..<range.lowerBound])
            let value = String(part[range.upperBound...])
            guard isKey(key), isValue(value) else { return nil }
            return negated ? "\(key)!=\(value)" : "\(key)=\(value)"
        }
        if part.hasPrefix("!") {
            let key = String(part.dropFirst())
            guard isKey(key) else { return nil }
            return negated ? key : "!\(key)"
        }
        guard isKey(part) else { return nil }
        return negated ? "!\(part)" : part
    }

    /// A label's key: an optional DNS subdomain prefix and `/`, then a name
    /// of at most 63 characters.
    static func isKey(_ key: String) -> Bool {
        let pieces = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let name = pieces.last, isName(name) else { return false }
        guard pieces.count == 2 else { return true }
        let prefix = pieces[0]
        return !prefix.isEmpty && prefix.count <= 253
            && prefix.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == ".") }
            && prefix.first.map { $0.isLetter || $0.isNumber } == true && prefix.last.map { $0.isLetter || $0.isNumber } == true
    }

    /// A label's value: empty, or a name.
    static func isValue(_ value: String) -> Bool { value.isEmpty || isName(value) }

    /// At most 63 of letters, digits, `-`, `_` and `.`, a letter or digit at each end.
    static func isName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 63 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            && name.first.map { $0.isLetter || $0.isNumber } == true && name.last.map { $0.isLetter || $0.isNumber } == true
    }
}
