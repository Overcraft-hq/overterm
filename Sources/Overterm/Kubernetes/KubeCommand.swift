import Foundation

/// The names a kind goes by in the `:` command bar: kubectl's (discovery's
/// plural, singular, short names, Kind, `plural.group`) and k9s's own
/// aliases on top. Pure.
enum KubeKinds {
    /// k9s's aliases that discovery doesn't give, by the full name they mean.
    static let aliases: [String: String] = [
        "dp": "deployments.apps", "sec": "secrets", "jo": "jobs.batch", "np": "networkpolicies.networking.k8s.io",
        "cr": "clusterroles.rbac.authorization.k8s.io", "crb": "clusterrolebindings.rbac.authorization.k8s.io",
        "rb": "rolebindings.rbac.authorization.k8s.io", "ro": "roles.rbac.authorization.k8s.io",
    ]

    /// The kind a name means: an alias, else kubectl's resolution
    /// (`KubeDiscovery.kind`: the core group first) — but, of two built-in
    /// kinds that are one Kind, the one the page offers (`catalog`): `ev`
    /// is events.k8s.io's Events, as the Cluster section shows them, not
    /// the core group's.
    static func resolve(_ name: String, in discovery: KubeDiscovery, catalog: KubeKindCatalog? = nil) -> KubeResourceKind? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        guard let found = aliases[wanted].flatMap(discovery.kind) ?? discovery.kind(wanted) else { return nil }
        guard let catalog, catalog.section(of: found) == nil, KubeKindCatalog.isBuiltIn(group: found.group) else { return found }
        return catalog.all.first { $0.kind == found.kind && KubeKindCatalog.isBuiltIn(group: $0.group) } ?? found
    }

    /// Every name it goes by, lowercased: plural first.
    static func names(of kind: KubeResourceKind) -> [String] {
        var names = [kind.resource, kind.singular] + kind.shortNames + [kind.kind.lowercased(), kind.fullName]
        names += aliases.filter { $0.value == kind.fullName }.map(\.key).sorted()
        var seen: Set<String> = []
        return names.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// What the `:` bar says (docs/design/kubernetes/analysis.md, Section 7):
/// `<kind>[ <namespace>][ /<filter>][ <label=value,…>][ @<context>]`.
/// `:ctx [name]` and `:ns [name]` switch the context or the namespace (or
/// open their picker); `all` or `-A` as the namespace is every one. The
/// filter starts at a word that starts with `/` and runs up to the next
/// `@context` or `label=value` word — its own words (`status:running`,
/// `label:app=web`) have a `:` — so what follows it is still read. Pure.
struct KubeCommand: Equatable, Sendable {
    /// The first word, lowercased: a kind's name, `ctx` or `ns`.
    var target: String
    /// A namespace, or nil.
    var namespace: String?
    var allNamespaces = false
    /// `app=web,tier=fe`: a word with `=`.
    var labels: String?
    /// `@fake-dev`.
    var context: String?
    /// After `/`.
    var filter: String?

    enum Action: Equatable, Sendable {
        case kind(String)
        case context(String?)
        case namespace(String?)
    }

    var action: Action {
        switch target {
        case "ctx", "context", "contexts": .context(namespace ?? context)
        case "ns": .namespace(allNamespaces ? "*" : namespace)
        default: .kind(target)
        }
    }

    static func parse(_ text: String) -> KubeCommand? {
        var line = text.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix(":") { line.removeFirst() }
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, !first.contains("="), !first.hasPrefix("@"), !first.hasPrefix("/") else { return nil }
        var command = KubeCommand(target: first.lowercased())
        /// The filter's words while it is read.
        var filter: [String]?
        func endFilter() {
            if let words = filter, !words.isEmpty { command.filter = words.joined(separator: " ") }
            filter = nil
        }
        for word in words.dropFirst() {
            if word.hasPrefix("@") {
                let name = String(word.dropFirst())
                guard !name.isEmpty, command.context == nil else { return nil }
                command.context = name
                endFilter()
            } else if isLabels(word) {
                command.labels = command.labels.map { $0 + "," + word } ?? word
                endFilter()
            } else if filter != nil {
                filter?.append(word)
            } else if word.hasPrefix("/") {
                guard command.filter == nil else { return nil }
                let rest = String(word.dropFirst())
                filter = rest.isEmpty ? [] : [rest]
            } else if word == "-A" || word.lowercased() == "all" {
                command.allNamespaces = true
            } else {
                guard command.namespace == nil else { return nil }
                command.namespace = word
            }
        }
        endFilter()
        return command
    }

    /// `app=web,tier=fe`, `env!=prod`: a selector's word. A filter's
    /// `label:app=web` is the filter's.
    static func isLabels(_ word: String) -> Bool { word.contains("=") && !word.contains(":") && !word.hasPrefix("/") }
}

/// The `:` bar over the page: what is typed, and what it completes to —
/// a kind's names while the first word is typed, then a namespace, or a
/// context after `@`. ↑↓ move, Tab completes, ↩ completes and runs, Esc
/// closes. Pure.
struct KubeCommandBar: Equatable {
    struct Completion: Equatable, Identifiable, Sendable {
        /// What the word becomes.
        var text: String
        var detail: String
        var id: String { text }
    }

    /// The kinds offered, the namespaces listed, the contexts.
    let kinds: [KubeResourceKind]
    let namespaces: [String]
    let contexts: [String]
    var text = "" {
        didSet {
            index = 0
            problem = nil
        }
    }
    var index = 0
    /// Why the last ↩ ran nothing.
    var problem: String?

    init(kinds: [KubeResourceKind], namespaces: [String], contexts: [String]) {
        self.kinds = kinds
        self.namespaces = namespaces
        self.contexts = contexts
    }

    /// The word being typed and where it starts; nil after a space, and
    /// in the filter — but an `@context` after it still completes.
    var currentWord: (word: String, start: String.Index, first: Bool)? {
        guard let last = text.last, !last.isWhitespace else {
            return text.isEmpty ? ("", text.startIndex, true) : nil
        }
        let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        let word = String(text[start...])
        if text.contains("/"), !word.hasPrefix("@") { return nil }
        let first = !text[..<start].contains { !$0.isWhitespace }
        return (word, start, first)
    }

    /// What the word being typed may become, best first.
    var results: [Completion] {
        guard let (word, _, first) = currentWord else { return [] }
        let typed = word.lowercased()
        if first { return Array(kindCompletions(typed).prefix(8)) }
        if typed.hasPrefix("@") {
            let query = String(typed.dropFirst())
            return Array(
                contexts.filter { query.isEmpty || $0.lowercased().hasPrefix(query) || $0.lowercased().contains(query) }.prefix(8)
                    .map { Completion(text: "@" + $0, detail: "Context") })
        }
        guard !typed.isEmpty, !typed.contains("="), typed != "-a" else { return [] }
        let matching = namespaces.filter { $0.hasPrefix(typed) } + namespaces.filter { !$0.hasPrefix(typed) && $0.contains(typed) }
        return Array(matching.prefix(8).map { Completion(text: $0, detail: "Namespace") })
    }

    /// Kinds by their names: one a name is exactly first, then those a
    /// name starts with, then the rest that contain it; `ctx` and `ns`.
    private func kindCompletions(_ typed: String) -> [Completion] {
        var ranked: [(Completion, Int, Int)] = []
        let commands: [(String, String)] = [("ctx", "Switch context"), ("ns", "Switch namespace")]
        for (offset, (name, detail)) in commands.enumerated() {
            let rank = typed.isEmpty ? 0 : name == typed ? 0 : name.hasPrefix(typed) ? 1 : nil
            if let rank { ranked.append((Completion(text: name, detail: detail), rank, offset)) }
        }
        // A plural two kinds share (two CRDs' `certificates`) completes to
        // each one's full name, or the second could never be picked.
        var plurals: [String: Int] = [:]
        for kind in kinds { plurals[kind.resource, default: 0] += 1 }
        for (offset, kind) in kinds.enumerated() {
            let names = KubeKinds.names(of: kind)
            let rank: Int? =
                typed.isEmpty ? 2 : names.contains(typed) ? 0 : names.contains { $0.hasPrefix(typed) } ? 1 : names.contains { $0.contains(typed) } ? 2 : nil
            guard let rank else { continue }
            let short = kind.shortNames.first.map { " · \($0)" } ?? ""
            let text = plurals[kind.resource, default: 0] > 1 ? kind.fullName : kind.resource
            ranked.append((Completion(text: text, detail: "\(KubeKindCatalog.title(of: kind))\(short) · \(kind.groupVersion)"), rank, offset + 10))
        }
        var seen: Set<String> = []
        return ranked.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.map(\.0).filter { seen.insert($0.text).inserted }
    }

    var selected: Completion? {
        let results = results
        return results.indices.contains(index) ? results[index] : nil
    }

    mutating func move(_ offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        index = ((index + offset) % count + count) % count
    }

    /// Tab: the word being typed becomes the highlighted completion.
    mutating func complete() {
        guard let completion = selected, let (_, start, _) = currentWord else { return }
        text = String(text[..<start]) + completion.text
    }

    /// ↩: the word completed when it isn't already a whole name, then read.
    mutating func command() -> KubeCommand? {
        if let (word, _, first) = currentWord, !word.isEmpty, let completion = selected, completion.text.lowercased() != word.lowercased() {
            let whole = first ? kinds.contains { KubeKinds.names(of: $0).contains(word.lowercased()) } || ["ctx", "ns"].contains(word.lowercased()) : false
            if !whole { complete() }
        }
        return KubeCommand.parse(text)
    }
}
