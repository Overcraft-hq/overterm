import Foundation

/// `n` and `c` on the Kubernetes page: a short list over it to pick a
/// namespace or a context from, typed into to narrow it (`FuzzyMatch`, as
/// the palette ranks). The namespace one also takes a name typed in full:
/// RBAC often refuses listing namespaces — a context that carries one
/// (`globex-*`'s) often says its user is held to it — and a name the server
/// won't list may still be one you can read. Pure.
struct KubePicker: Equatable {
    enum Kind: Equatable, Sendable {
        case namespace, context
        /// "Compare with…" (3.10): an object's other side — another
        /// context, or another namespace of the object's.
        case compare(context: String, namespace: String?)

        var title: String {
            switch self {
            case .namespace: "Namespace"
            case .context: "Context"
            case .compare: "Compare with"
            }
        }
    }

    /// What picking an item does.
    enum Choice: Hashable, Sendable {
        case scope(KubeScope)
        case context(String)
        /// The other side of a comparison.
        case compare(context: String, namespace: String?)
    }

    struct Item: Equatable, Identifiable, Sendable {
        var choice: Choice
        var title: String
        var detail: String?
        /// A namespace typed, not one listed.
        var typed = false
        /// Production: drawn in its red.
        var production = false

        var id: String {
            switch choice {
            case .scope(.all): "*all"
            case .scope(.namespace(let name)): (typed ? "+" : "ns:") + name
            case .context(let name): "ctx:" + name
            case .compare(let context, let namespace): (typed ? "+cmp:" : "cmp:") + context + "\u{0}" + (namespace ?? "")
            }
        }
    }

    let kind: Kind
    let items: [Item]
    /// Why the list is short, when it is.
    var note: String?
    var query = "" {
        didSet { index = 0 }
    }
    var index = 0

    init(kind: Kind, items: [Item], note: String? = nil, current: Choice? = nil) {
        self.kind = kind
        self.items = items
        self.note = note
        index = current.flatMap { current in items.firstIndex { $0.choice == current } } ?? 0
    }

    /// The items the query lets through, best first; for a namespace, the
    /// name typed as one more when it is a name and no item is it.
    var results: [Item] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        let ranked = items.enumerated().compactMap { offset, item -> (Item, Int, Int)? in
            guard let score = FuzzyMatch.score(query, in: item.title) else { return nil }
            return (item, score, offset)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        .map(\.0)
        if case .compare(let context, let namespace) = kind {
            guard namespace != nil, let typed = Self.typedComparison(query, context: context), !items.contains(where: { $0.choice == typed.choice })
            else { return ranked }
            return ranked + [typed]
        }
        guard kind == .namespace, let typed = Self.typedNamespace(query),
            !items.contains(where: { $0.choice == .scope(.namespace(typed)) })
        else { return ranked }
        let item = Item(choice: .scope(.namespace(typed)), title: typed, detail: "Use this namespace", typed: true)
        // Where the list is refused, what is typed is what's meant.
        return note != nil ? [item] + ranked : ranked + [item]
    }

    /// The highlighted item, or nil when nothing matches.
    var selected: Item? {
        let results = results
        return results.indices.contains(index) ? results[index] : nil
    }

    var chosen: Choice? { selected?.choice }

    mutating func move(_ offset: Int) {
        let count = results.count
        guard count > 0 else { return }
        index = ((index + offset) % count + count) % count
    }

    /// What is typed, as a namespace: lowercased, if it is a name one can
    /// have (RFC 1123: at most 63 lowercase letters, digits and `-`, a
    /// letter or digit at each end).
    static func typedNamespace(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.count <= 63,
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
            name.first?.isLetter == true || name.first?.isNumber == true,
            name.last?.isLetter == true || name.last?.isNumber == true
        else { return nil }
        return name
    }

    /// What is typed, as a comparison's other side: `namespace` (the
    /// object's context), or `namespace@context`.
    static func typedComparison(_ text: String, context: String) -> Item? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", maxSplits: 1).map(String.init)
        guard let first = parts.first, let namespace = typedNamespace(first) else { return nil }
        let other = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : context
        guard !other.isEmpty else { return nil }
        return Item(
            choice: .compare(context: other, namespace: namespace), title: namespace, detail: "Compare with namespace \(namespace) in \(other)", typed: true)
    }

    // MARK: The lists

    /// All namespaces first (`0`), then the context's favourites, its own
    /// namespace and the one showing, then the server's list (or the
    /// context's `accessibleNamespaces`); the one showing highlighted.
    static func namespaces(listed: [String], favourites: [String], own: String?, current: KubeScope, refused: String?) -> KubePicker {
        var names: [String] = []
        let showing: String? = if case .namespace(let name) = current { name } else { nil }
        for name in favourites + [own, showing].compactMap({ $0 }) + listed where !names.contains(name) {
            names.append(name)
        }
        let items =
            [Item(choice: .scope(.all), title: "All namespaces", detail: "0")]
            + names.map { name in
                Item(
                    choice: .scope(.namespace(name)), title: name,
                    detail: favourites.contains(name) ? "favourite" : name == own ? "the context's" : listed.contains(name) ? nil : "typed")
            }
        return KubePicker(kind: .namespace, items: items, note: refused, current: .scope(current))
    }

    /// Every context, as the kubeconfig lists them: its class, read-only or
    /// not, kubectl's current marked; the one showing highlighted.
    static func contexts(_ list: KubeContextList, selected: String?) -> KubePicker {
        let items = list.contexts.map { context in
            var detail = [context.contextClass.title, context.isWritable ? "writable" : "read-only"]
            if context.displayName != context.name { detail.append(context.name) }
            if context.name == list.current { detail.append("current") }
            return Item(choice: .context(context.name), title: context.displayName, detail: detail.joined(separator: " · "), production: context.isProduction)
        }
        return KubePicker(kind: .context, items: items, current: selected.map { .context($0) })
    }

    /// "Compare with…" on an object of `context` (in `namespace`): every
    /// other context, in the same namespace; then the context's other
    /// namespaces. Another one, or one in another context, is typed
    /// (`namespace@context`).
    static func compare(context: String, namespace: String?, contexts list: KubeContextList, namespaces: [String]) -> KubePicker {
        var items = list.contexts.filter { $0.name != context }.map { other in
            Item(
                choice: .compare(context: other.name, namespace: namespace), title: other.displayName,
                detail: [namespace.map { "namespace \($0)" } ?? "cluster-wide", other.contextClass.title].joined(separator: " · "), production: other.isProduction)
        }
        if let namespace {
            let production = list.context(named: context)?.isProduction ?? false
            items += namespaces.filter { $0 != namespace }.map { other in
                Item(choice: .compare(context: context, namespace: other), title: other, detail: "namespace in \(context)", production: production)
            }
        }
        return KubePicker(kind: .compare(context: context, namespace: namespace), items: items)
    }
}
