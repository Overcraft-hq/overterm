import Foundation

/// What a list's filter knows besides text: `ns:` and `status:`, matched
/// on the rows, and `label:` and `field:`, which go to the server
/// (`KubeLabelSelector`, `KubeFieldSelector`) — a row is only cells, it has
/// no labels or fields to match.
enum KubeFilterKey: ResourceFilterKey {
    case text, namespace, status, label, field

    static let names: [String: KubeFilterKey] = [
        "ns": .namespace, "namespace": .namespace, "status": .status, "s": .status, "label": .label, "l": .label, "field": .field, "f": .field,
    ]

    /// Whether the server reads it, not the rows.
    var isServers: Bool { self == .label || self == .field }
}

/// What a list is asked for with: the filter's `label:` words as a
/// `labelSelector`, its `field:` words as a `fieldSelector`. Nil: none.
struct KubeListSelectors: Equatable, Sendable {
    var label: String?
    var field: String?

    init(label: String? = nil, field: String? = nil) {
        self.label = label
        self.field = field
    }

    var isEmpty: Bool { label == nil && field == nil }

    var options: KubeListOptions { KubeListOptions(labelSelector: label, fieldSelector: field) }

    /// `label app=web, field status.phase=Running`; nil for none.
    var said: String? {
        let parts = [label.map { "label \($0)" }, field.map { "field \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Both read from a filter, with the words neither could read.
    struct Reading: Equatable, Sendable {
        var selectors = KubeListSelectors()
        var refused: [String] = []
    }

    static func read(_ filter: ResourceFilter<KubeFilterKey>) -> Reading {
        let label = KubeLabelSelector.read(filter)
        let field = KubeFieldSelector.read(filter)
        return Reading(selectors: KubeListSelectors(label: label.selector, field: field.selector), refused: label.refused + field.refused)
    }

    static func read(_ text: String) -> Reading { read(ResourceFilter<KubeFilterKey>(text)) }
}

/// The filter's `field:` words as the field selector the list is asked
/// for: what the server filters by, as `kubectl get --field-selector`
/// does. Which fields a kind takes is the server's to say (every kind
/// `metadata.name` and `metadata.namespace`; pods also `spec.nodeName`,
/// `status.phase`, `status.podIP`…) — one it doesn't is its 400, said
/// over the list. Read from the words as typed. Pure.
///
///     field:status.phase=Running        status.phase=Running
///     field:spec.nodeName==node-1       spec.nodeName=node-1
///     field:status.phase!=Running       status.phase!=Running
///     -field:status.phase=Running       status.phase!=Running
///     field:a=1,b=2                     a=1,b=2
///
/// A field has no "exists" form, and "not (a and b)" is no selector: such
/// a word (`field:spec`, `-field:a=1,b=2`, `field:a=b=c`) is `refused`.
enum KubeFieldSelector {
    typealias Reading = KubeLabelSelector.Reading

    static func read(_ filter: ResourceFilter<KubeFilterKey>) -> Reading {
        var read: [String] = []
        var refused: [String] = []
        for term in filter.terms where term.key == .field {
            let parts = term.raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let requirements = term.negated && parts.count > 1 ? nil : parts.map { requirement($0, negated: term.negated) }
            if let requirements, !requirements.isEmpty, requirements.allSatisfy({ $0 != nil }) {
                read += requirements.compactMap { $0 }
            } else {
                refused.append((term.negated ? "-" : "") + "field:" + term.raw)
            }
        }
        return Reading(selector: read.isEmpty ? nil : read.joined(separator: ","), refused: refused)
    }

    static func read(_ text: String) -> Reading { read(ResourceFilter<KubeFilterKey>(text)) }

    static func requirement(_ part: String, negated: Bool) -> String? {
        let not = part.range(of: "!=")
        guard let range = not ?? part.range(of: "==") ?? part.range(of: "=") else { return nil }
        let key = String(part[..<range.lowerBound])
        let value = String(part[range.upperBound...])
        guard isPath(key), isValue(value) else { return nil }
        return "\(key)\((not != nil) != negated ? "!=" : "=")\(value)"
    }

    /// A field's path: dotted names (`spec.nodeName`, `involvedObject.kind`).
    static func isPath(_ key: String) -> Bool {
        let names = key.split(separator: ".", omittingEmptySubsequences: false)
        return !names.isEmpty
            && names.allSatisfy { name in
                !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            }
    }

    /// A value as typed: nothing the selector's grammar reads (`,` `=` `!`
    /// and its escape `\\`), at most 253 characters (a DNS subdomain).
    static func isValue(_ value: String) -> Bool {
        value.count <= 253 && !value.contains { ",=!\\".contains($0) || $0.isWhitespace }
    }
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

    static func read(_ filter: ResourceFilter<KubeFilterKey>) -> Reading {
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

    static func read(_ text: String) -> Reading { read(ResourceFilter<KubeFilterKey>(text)) }

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
