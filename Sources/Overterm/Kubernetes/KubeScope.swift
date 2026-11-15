import Foundation

/// Where a list looks: one namespace, several, or all of them. A
/// cluster-scoped kind ignores it. Pure.
///
/// Several are always two or more — `of` makes none `.all` and one
/// `.namespace` — so a scope has one spelling: `.namespace("shop")` is the
/// one namespace however it was picked, and two equal scopes are equal.
///
/// Several namespaces are listed one request each (`reads`), merged
/// (`KubeScopeMerge`), up to `watchCap`; beyond it, as one list across
/// the cluster, kept to the picked ones here — where that is allowed
/// (`KubeScopeRefused` where it isn't).
enum KubeScope: Hashable, Sendable {
    case all
    case namespace(String)
    /// Two or more; made by `of`.
    case namespaces(Set<String>)

    /// The most namespaces watched one by one: past it, one watch across
    /// the cluster, filtered here.
    static let watchCap = 10

    /// The scope of `names`: all of them for none, the one, or the set.
    static func of(_ names: some Sequence<String>) -> KubeScope {
        let set = Set(names.filter { !$0.isEmpty })
        switch set.count {
        case 0: return .all
        case 1: return .namespace(set.first!)
        default: return .namespaces(set)
        }
    }

    /// The namespaces picked, sorted; nil for all of them.
    var names: [String]? {
        switch self {
        case .all: nil
        case .namespace(let name): [name]
        case .namespaces(let set): set.sorted()
        }
    }

    /// Whether a list in it spans more than one namespace: its rows want a
    /// Namespace column.
    var spansNamespaces: Bool { names?.count != 1 }

    /// The namespace in `kind`'s paths and its rows' — only when it is one.
    func namespace(for kind: KubeResourceKind) -> String? {
        guard kind.namespaced, case .namespace(let name) = self else { return nil }
        return name
    }

    /// Whether a row in `namespace` belongs (a cluster-scoped one's, nil, always).
    func includes(_ namespace: String?) -> Bool {
        guard let namespace else { return true }
        switch self {
        case .all: return true
        case .namespace(let name): return name == namespace
        case .namespaces(let set): return set.contains(namespace)
        }
    }

    /// The requests a list of `kind` takes: a namespace each — or one
    /// across every namespace (nil) for all of them, a cluster-scoped kind,
    /// or more than `cap` (its rows then kept to the scope's, `includes`).
    func reads(for kind: KubeResourceKind, cap: Int = watchCap) -> [String?] {
        guard kind.namespaced, let names else { return [nil] }
        return names.count > cap ? [nil] : names
    }

    /// Past the cap: listed across the cluster and filtered.
    func isFilteredAcross(for kind: KubeResourceKind, cap: Int = watchCap) -> Bool {
        guard kind.namespaced, let names else { return false }
        return names.count > cap
    }

    /// The one namespace a single-namespace thing (a template, a manifest,
    /// a tab) goes to: the one picked; of several, `preferred` when it is
    /// one of them, else the first; nil for all.
    func one(preferring preferred: String? = nil) -> String? {
        guard let names else { return nil }
        if let preferred, names.contains(preferred) { return preferred }
        return names.first
    }

    /// As the page says it: `All namespaces`, `shop`, `acme-api +2`.
    var title: String {
        guard let names else { return "All namespaces" }
        return names.count == 1 ? names[0] : "\(names[0]) +\(names.count - 1)"
    }

    /// In a sentence: `all namespaces`, `namespace shop`, `namespaces a, b`.
    var said: String {
        guard let names else { return "all namespaces" }
        return names.count == 1 ? "namespace \(names[0])" : "namespaces \(names.joined(separator: ", "))"
    }

    /// As it is kept (the defaults): the names, none for all.
    var persisted: [String] { names ?? [] }

    init(persisted names: [String]) { self = Self.of(names) }
}

/// Several namespaces past the cap, where listing across the cluster isn't
/// allowed: said, with what to do.
struct KubeScopeRefused: Error, Equatable, LocalizedError {
    var count: Int
    var reason: String
    /// How many may be watched one by one (the Overview's is less: it
    /// follows several lists in each).
    var cap = KubeScope.watchCap

    var errorDescription: String? {
        let pick = cap == 1 ? "Pick one namespace" : "Pick \(cap) or fewer"
        return "\(count) namespaces are more than \(cap) watched one by one, so they are listed across the cluster and kept to the "
            + "picked ones here — and that isn't allowed on this context (\(reason)). \(pick)."
    }
}

/// Several namespaces' follows as one (`KubeClient.follow` over a set):
/// nothing until every namespace has been heard from, then the whole of
/// those that listed as one `.listed`; a namespace's changes as they come;
/// a namespace listed again (a 410) as what changed in it. A namespace
/// refused (a 403) is left out, said (`.unlisted`); one waiting for the
/// server again (a 429, a 5xx) keeps the list `.retrying` — said again
/// after anything else — until it lists, and then something is always
/// said, so the list is live again. Bookmarks stay each namespace's own —
/// the merged rows have no one resourceVersion. Pure.
struct KubeScopeMerge: Sendable {
    let namespaces: [String]
    private var rows: [String: KubeRows] = [:]
    /// Not heard from yet: neither listed, retrying nor refused.
    private var waiting: Set<String>
    /// Waiting for the server again, and why.
    private var retrying: [String: KubeAPIError] = [:]
    /// The namespaces that may not be listed, and why: left out.
    private(set) var refused: [String: KubeAPIError] = [:]
    /// Whether the merged `.listed` has been given.
    private(set) var listed = false

    init(namespaces: [String]) {
        self.namespaces = namespaces
        waiting = Set(namespaces)
    }

    /// Whether every namespace refused: nothing to show.
    var allRefused: Bool { !namespaces.isEmpty && Set(refused.keys) == Set(namespaces) }

    /// What `update` of `namespace`'s follow means for the merged rows, in
    /// order; empty when nothing to say yet.
    mutating func take(_ update: KubeFollowUpdate, from namespace: String) -> [KubeFollowUpdate] {
        var out: [KubeFollowUpdate] = []
        let wasRetrying = !retrying.isEmpty
        switch update {
        case .listed(let table):
            let old = rows[namespace]
            rows[namespace] = KubeRows(table)
            waiting.remove(namespace)
            retrying[namespace] = nil
            if listed {
                // Listed again: what differs from what it had.
                var changes: [KubeRowChange] = []
                let new = rows[namespace]!
                for row in old?.sorted ?? [] where new[row.id] == nil { changes.append(.deleted(row.id)) }
                for row in new.sorted where old?[row.id] != row { changes.append(old?[row.id] == nil ? .added(row) : .modified(row)) }
                if !changes.isEmpty { out.append(.changed(changes, resourceVersion: nil)) }
            }
        case .changed(let changes, _):
            rows[namespace, default: KubeRows()].apply(.changed(changes, resourceVersion: nil))
            retrying[namespace] = nil
            if listed && !changes.isEmpty { out.append(.changed(changes, resourceVersion: nil)) }
        case .bookmark:
            retrying[namespace] = nil
        case .retrying(let error):
            waiting.remove(namespace)
            retrying[namespace] = error
        case .unlisted(_, let error):
            waiting.remove(namespace)
            retrying[namespace] = nil
            refused[namespace] = error
            if let old = rows.removeValue(forKey: namespace), listed, old.count > 0 {
                out.append(.changed(old.sorted.map { .deleted($0.id) }, resourceVersion: nil))
            }
            out.append(.unlisted(namespace, error))
        }
        // Every namespace heard from, one at least listed: those that did.
        if !listed, waiting.isEmpty, !rows.isEmpty {
            listed = true
            out.append(.listed(merged))
        }
        if let error = retrying.sorted(by: { $0.key < $1.key }).first?.value {
            // Whatever else came, the list isn't all current.
            out.append(.retrying(error))
        } else if wasRetrying, listed, !out.contains(where: \.isRows) {
            // The last one back: said, so the list is live again.
            out.append(.changed([], resourceVersion: nil))
        }
        return out
    }

    /// Every namespace's rows as one table, the first's columns.
    var merged: KubeTable {
        let tables = namespaces.compactMap { rows[$0] }
        let columns = tables.first { !$0.columns.isEmpty }?.columns ?? []
        return KubeTable(columns: columns, rows: tables.flatMap(\.sorted), resourceVersion: nil)
    }

    /// A follow across the cluster kept to `scope`'s rows (past the cap). Pure.
    static func filtered(_ update: KubeFollowUpdate, to scope: KubeScope) -> KubeFollowUpdate? {
        switch update {
        case .listed(var table):
            table.rows = table.rows.filter { scope.includes($0.id.namespace) }
            return .listed(table)
        case .changed(let changes, let version):
            let kept = changes.filter { scope.includes($0.id.namespace) }
            return kept.isEmpty ? (version.map { .bookmark($0) }) : .changed(kept, resourceVersion: version)
        case .bookmark, .retrying, .unlisted:
            return update
        }
    }
}

extension KubeFollowUpdate {
    /// A list or rows that changed: what a page applies, and is live after.
    var isRows: Bool {
        switch self {
        case .listed, .changed: true
        case .bookmark, .retrying, .unlisted: false
        }
    }
}
