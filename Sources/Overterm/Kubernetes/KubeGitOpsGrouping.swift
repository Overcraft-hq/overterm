import CoreGraphics
import Foundation

/// What `G` groups the GitOps section by (docs/design/kubernetes/gitops.md,
/// 2.8), in the order it cycles: none, the tool, the source, the owner, the
/// destination. Remembered per page, in memory.
enum KubeGitOpsGroupBy: String, CaseIterable, Equatable, Sendable {
    case none, tool, source, owner, destination

    var title: String {
        switch self {
        case .none: "None"
        case .tool: "Tool"
        case .source: "Source"
        case .owner: "Owner"
        case .destination: "Destination"
        }
    }

    /// `G` again: the next, after the last none.
    var next: KubeGitOpsGroupBy {
        let all = Self.allCases
        let at = all.firstIndex(of: self) ?? 0
        return all[(at + 1) % all.count]
    }
}

/// One group a row belongs to: its id among the section's groups, its
/// title, and — where an object heads it (a Flux source, an
/// ApplicationSet, an app-of-apps parent, a `dependsOn` root) — that
/// object's key. Pure.
struct KubeGitOpsGroupKey: Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var head: KubeGitOpsObject.Key?
}

/// What a row is grouped by, set from its summary as the row is made
/// (the peers are at hand there), never read again. Pure.
struct KubeGitOpsGroupKeys: Equatable, Sendable {
    /// The repository it deploys from, host included, never userinfo
    /// (`git.acme.example/acme/fleet`; a chart's repository as written,
    /// its credentials dropped): what `repo:` matches.
    var repo = ""
    /// A Flux object's source (a source itself, or a HelmChart's
    /// repository); an Argo CD Application's repository. Nil: none known.
    var source: KubeGitOpsGroupKey?
    /// Its ApplicationSet; the top of its app-of-apps or Flux parents (by
    /// tracking id or Flux's labels); else its `dependsOn` root. Nil: none —
    /// it may still head a group of its own.
    var owner: KubeGitOpsGroupKey?
    var destination: KubeGitOpsGroupKey?
}

/// A group of the section's rows: its head's row when one heads it (also
/// its first member, when shown), the rows in it, and how many of each
/// problem. Pure.
struct KubeGitOpsGroup: Equatable, Sendable, Identifiable {
    var id: String
    var by: KubeGitOpsGroupBy
    var title: String
    /// The object heading it, as the section holds it — shown or not: a
    /// source "carries its own state" even with a filter on.
    var head: KubeGitOpsRow?
    var members: [KubeGitOpsRow]
    /// The catch-all ("No owner", "Not summarised"): drawn last.
    var rest = false

    /// The worst state among its members and its head: what orders the groups.
    var worst: KubeGitOpsState { (members.map(\.state) + [head?.state].compactMap { $0 }).min() ?? .unknown }

    /// `5 objects · 2 failing · 1 blocked`: its members, the head aside.
    var said: String {
        let others = members.filter { $0.key != head?.key }
        var parts = ["\(others.count) object\(others.count == 1 ? "" : "s")"]
        for (state, count) in KubeGitOpsSection.chips(others) where state.isProblem {
            parts.append(KubeGitOpsSection.chipText(state, count))
        }
        return parts.joined(separator: " · ")
    }
}

/// A row of the section's table: a group's own row (across the columns),
/// or one object's.
enum KubeGitOpsListRow: ResourceTableRow {
    case group(KubeGitOpsGroup, folded: Bool)
    case object(KubeGitOpsRow)

    var id: String {
        switch self {
        case .group(let group, _): group.id
        case .object(let row): row.id
        }
    }

    var height: CGFloat {
        switch self {
        case .group: 28
        case .object(let row): row.height
        }
    }

    var spansColumns: Bool {
        if case .group = self { return true }
        return false
    }

    var reuseKind: String {
        switch self {
        case .group: "group"
        case .object: "row"
        }
    }

    var object: KubeGitOpsRow? {
        if case .object(let row) = self { return row }
        return nil
    }
}

/// The section's grouping (gitops.md 2.8): by tool, Argo CD then Flux; by
/// source, a Flux source heading its group with its own state, Argo CD's
/// Applications by repository, a source nothing uses alone; by owner, an
/// ApplicationSet with its Applications, an app-of-apps parent with those
/// it manages, else a Kustomization's `dependsOn` root; by destination,
/// the namespace it deploys into, another cluster said. Groups with a
/// problem first, then by title; the catch-all last. Reads nothing. Pure.
enum KubeGitOpsGrouping {
    /// Hops followed up an owner or `dependsOn` chain, as the ladder does.
    static let hops = 5

    static let groupPrefix = "group:"

    static func isGroup(_ id: String) -> Bool { id.hasPrefix(groupPrefix) }

    // MARK: A row's keys

    /// What a summary's row is grouped by, its peers (the summaries held)
    /// at hand: its source's object, its owner's, where it deploys.
    static func keys(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers) -> KubeGitOpsGroupKeys {
        var keys = KubeGitOpsGroupKeys()
        keys.repo = repo(object, peers: peers)
        keys.source = source(object, peers: peers)
        keys.owner = owner(object, peers: peers)
        keys.destination = destination(object)
        return keys
    }

    /// Host included, never userinfo: `git.acme.example/acme/fleet`.
    static func repo(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers) -> String {
        func said(_ source: KubeGitOpsSource?) -> String? {
            guard let source, !source.repoURL.isEmpty else { return nil }
            return GitRemoteURL(source.repoURL)?.description ?? GitRemoteURL.withoutUserinfo(source.repoURL)
        }
        switch object.role {
        case .application:
            return said(object.sources.first { !$0.isValuesRef }) ?? said(object.sources.first) ?? ""
        case .applicationSet:
            return ""
        case .source:
            if let own = said(object.sources.first) { return own }
            guard let reference = object.sourceRef else { return "" }
            return said(peers[key(reference)]?.sources.first) ?? ""
        case .kustomization, .helmRelease:
            guard let reference = object.chartRef ?? object.sourceRef, let peer = peers[key(reference)] else { return "" }
            if let own = said(peer.sources.first) { return own }
            // A HelmChart's own source.
            return peer.sourceRef.flatMap { said(peers[key($0)]?.sources.first) } ?? ""
        }
    }

    /// A Flux object's source object (a source is its own; a HelmChart its
    /// repository's); an Argo CD Application's repository.
    static func source(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers) -> KubeGitOpsGroupKey? {
        switch object.role {
        case .application:
            guard let source = object.sources.first(where: { !$0.isValuesRef }) ?? object.sources.first, !source.repoURL.isEmpty else { return nil }
            let shown = source.repo?.description ?? GitRemoteURL.withoutUserinfo(source.repoURL)
            return KubeGitOpsGroupKey(id: "\(groupPrefix)source:repo:\(source.repo?.key ?? shown)", title: shown, head: nil)
        case .applicationSet:
            return nil
        case .source(let kind):
            if kind == "HelmChart", let reference = object.sourceRef { return sourceKey(key(reference)) }
            return sourceKey(object.key)
        case .kustomization, .helmRelease:
            guard let reference = object.chartRef ?? object.sourceRef else { return nil }
            let referenced = key(reference)
            // A HelmChart stands for its repository, as its own row does.
            if referenced.kind == "HelmChart", let chart = peers[referenced], let repository = chart.sourceRef { return sourceKey(key(repository)) }
            return sourceKey(referenced)
        }
    }

    static func sourceKey(_ key: KubeGitOpsObject.Key) -> KubeGitOpsGroupKey {
        KubeGitOpsGroupKey(id: "\(groupPrefix)source:\(key.description)", title: key.description, head: key)
    }

    /// Its ApplicationSet; else the top of its parents (an Application's
    /// tracking id or instance label, Flux's labels) while each is among
    /// the summaries, at most five hops; else the root of its `dependsOn`
    /// chain. A parent not summarised still names the group when its mark
    /// is certain; Helm's instance label alone names nobody.
    static func owner(_ object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers) -> KubeGitOpsGroupKey? {
        if let set = object.ownerAppSet {
            return ownerKey(KubeGitOpsObject.Key(kind: "ApplicationSet", namespace: set.namespace, name: set.name))
        }
        var seen: Set<KubeGitOpsObject.Key> = [object.key]
        var current = object
        var root: KubeGitOpsObject.Key?
        for _ in 0..<hops {
            guard let parent = parent(of: current, peers: peers), !seen.contains(parent) else { break }
            seen.insert(parent)
            root = parent
            guard let next = peers[parent] else { break }
            current = next
        }
        // The top of an app-of-apps may itself come from an ApplicationSet.
        if let root, let top = peers[root], let set = top.ownerAppSet {
            return ownerKey(KubeGitOpsObject.Key(kind: "ApplicationSet", namespace: set.namespace, name: set.name))
        }
        if let root { return ownerKey(root) }
        current = object
        for _ in 0..<hops {
            guard let dependency = current.dependsOn.first, !seen.contains(dependency) else { break }
            seen.insert(dependency)
            root = dependency
            guard let next = peers[dependency] else { break }
            current = next
        }
        return root.map(ownerKey)
    }

    static func ownerKey(_ key: KubeGitOpsObject.Key) -> KubeGitOpsGroupKey {
        KubeGitOpsGroupKey(id: "\(groupPrefix)owner:\(key.description)", title: key.description, head: key)
    }

    /// The object an object's marks name as deploying it, as the summaries
    /// hold it: in the namespace the mark says, else its own, else Argo
    /// CD's. Not found, a certain mark still names it (in the namespace it
    /// says, else the object's own); "probably" names nobody.
    static func parent(of object: KubeGitOpsObject, peers: KubeGitOpsLadder.Peers) -> KubeGitOpsObject.Key? {
        guard let owner = object.parentOwner else { return nil }
        let kind = owner.tool.kind
        var places = [owner.namespace, object.ref.namespace]
        if owner.tool == .argoCD { places.append(KubeGitOps.argoDefaultNamespace) }
        for place in places {
            let candidate = KubeGitOpsObject.Key(kind: kind, namespace: place, name: owner.name)
            if candidate != object.key, peers[candidate] != nil { return candidate }
        }
        guard owner.isCertain else { return nil }
        let named = KubeGitOpsObject.Key(kind: kind, namespace: owner.namespace ?? object.ref.namespace, name: owner.name)
        return named == object.key ? nil : named
    }

    /// A source's destination: it deploys nothing — the same group whether
    /// its summary has come or only its live row (`KubeGitOpsSection.row`).
    static let sourcesDestination = KubeGitOpsGroupKey(
        id: "\(groupPrefix)destination:-sources", title: "Sources — deploy nothing themselves", head: nil)

    /// Where it deploys: another cluster, said; its destination's
    /// namespace; the one namespace it manages, or the several; a source
    /// deploys nothing.
    static func destination(_ object: KubeGitOpsObject) -> KubeGitOpsGroupKey {
        func key(_ id: String, _ title: String) -> KubeGitOpsGroupKey {
            KubeGitOpsGroupKey(id: "\(groupPrefix)destination:\(id)", title: title, head: nil)
        }
        if case .source = object.role { return sourcesDestination }
        if let remote = object.remote {
            let server = GitRemoteURL.withoutUserinfo(remote)
            return key("remote:\(server)", "⇢ \(server) — another cluster")
        }
        if let namespace = object.destination?.namespace { return key("ns:\(namespace)", namespace) }
        let managed = object.managedNamespaces.sorted()
        switch managed.count {
        case 0: return key("-none", "Nothing applied yet")
        case 1: return key("ns:\(managed[0])", managed[0])
        default:
            let shown = managed.prefix(3).joined(separator: ", ") + (managed.count > 3 ? " +\(managed.count - 3)" : "")
            return key("several:\(managed.joined(separator: ","))", shown)
        }
    }

    private static func key(_ reference: KubeGitOps.FluxSource) -> KubeGitOpsObject.Key {
        KubeGitOpsObject.Key(kind: reference.kind, namespace: reference.namespace, name: reference.name)
    }

    // MARK: Groups

    /// The visible rows grouped: each group's members in the order they
    /// came (the section's, or the header's sort), its head first; `all`,
    /// every row the section holds, to find a head the filter hides.
    static func groups(_ rows: [KubeGitOpsRow], by: KubeGitOpsGroupBy, all: [KubeGitOpsRow]) -> [KubeGitOpsGroup] {
        guard by != .none else { return [] }
        if by == .tool {
            return [KubeGitOpsObject.Tool.argo, .flux].compactMap { tool in
                let members = rows.filter { $0.tool == tool }
                guard !members.isEmpty else { return nil }
                return KubeGitOpsGroup(id: "\(groupPrefix)tool:\(tool.rawValue)", by: by, title: tool.said, members: members)
            }
        }
        var byKey: [KubeGitOpsObject.Key: KubeGitOpsRow] = [:]
        for row in all { byKey[row.key] = row }
        // An object others name as their owner heads its own group.
        let heads = by == .owner ? Set(all.compactMap { $0.grouping.owner?.head }) : []
        var order: [String] = []
        var found: [String: KubeGitOpsGroup] = [:]
        for row in rows {
            let key: KubeGitOpsGroupKey?
            var rest: (id: String, title: String)?
            switch by {
            case .source:
                key = row.grouping.source
                if key == nil { rest = row.summarised ? ("none", "No source") : ("unsummarised", "Not summarised") }
            case .owner:
                if let owner = row.grouping.owner {
                    key = owner
                } else if heads.contains(row.key) {
                    key = ownerKey(row.key)
                } else {
                    key = nil
                    rest = row.summarised ? ("none", "No owner") : ("unsummarised", "Not summarised")
                }
            case .destination:
                key = row.grouping.destination
                if key == nil { rest = ("unsummarised", "Not summarised") }
            case .none, .tool:
                key = nil
            }
            let id = key?.id ?? "\(groupPrefix)\(by.rawValue):-\(rest?.id ?? "none")"
            if found[id] == nil {
                order.append(id)
                let head = key?.head.flatMap { byKey[$0] }
                found[id] = KubeGitOpsGroup(id: id, by: by, title: key?.title ?? rest?.title ?? "", head: head, members: [], rest: key == nil)
            }
            found[id]?.members.append(row)
        }
        var groups = order.compactMap { found[$0] }
        for index in groups.indices {
            // Its head first, when shown.
            if let head = groups[index].head, let at = groups[index].members.firstIndex(where: { $0.key == head.key }), at > 0 {
                let row = groups[index].members.remove(at: at)
                groups[index].members.insert(row, at: 0)
            }
        }
        return groups.sorted { a, b in
            if a.rest != b.rest { return !a.rest }
            if a.worst != b.worst { return a.worst < b.worst }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The table's rows: each group's own, then — unless folded — its members.
    static func rows(_ groups: [KubeGitOpsGroup], folded: Set<String>) -> [KubeGitOpsListRow] {
        ResourceGrouping.rows(
            groups, collapsed: folded, id: \.id, header: { .group($0, folded: folded.contains($0.id)) }, members: { $0.members.map { .object($0) } })
    }
}

/// The GitOps section's filter (gitops.md 2.8): `is:`, `kind:`, `tool:`
/// and `repo:` words, each with values joined by commas (any of them),
/// each turned around by a leading `-`; the rest the text matched over
/// name, why and source, as the section always matched it. A word with
/// another key (`label:`, `ns:` — the kinds' lists') is no text here. A
/// value it doesn't know is `refused`, said, and matches anything. Pure.
struct KubeGitOpsFilter: Equatable, Sendable {
    enum Key: ResourceFilterKey {
        case text, state, kind, tool, repo

        static let names: [String: Key] = ["is": .state, "state": .state, "kind": .kind, "tool": .tool, "repo": .repo]
    }

    /// What `kind:` takes.
    enum Kind: String, CaseIterable, Sendable {
        case app, appset, ks, hr, source, git, oci, helmrepo, chart, bucket

        static let aliases: [String: Kind] = [
            "application": .app, "applications": .app, "apps": .app, "applicationset": .appset, "kustomization": .ks, "kustomizations": .ks,
            "helmrelease": .hr, "helmreleases": .hr, "sources": .source, "gitrepository": .git, "ocirepository": .oci, "helmrepository": .helmrepo,
            "helmchart": .chart,
        ]

        func holds(_ role: KubeGitOpsObject.Role) -> Bool {
            switch (self, role) {
            case (.app, .application), (.appset, .applicationSet), (.ks, .kustomization), (.hr, .helmRelease), (.source, .source): true
            case (.git, .source("GitRepository")), (.oci, .source("OCIRepository")), (.helmrepo, .source("HelmRepository")),
                (.chart, .source("HelmChart")), (.bucket, .source("Bucket")):
                true
            default: false
            }
        }
    }

    struct Term: Equatable, Sendable {
        var key: Key
        /// Any of these, lowercased.
        var values: [String]
        var negated: Bool
    }

    private(set) var terms: [Term] = []
    /// The words it couldn't read, said: `is:nope`.
    private(set) var refused: [String] = []

    init(_ text: String) {
        for term in ResourceFilter<Key>(text).terms {
            switch term.key {
            case .text:
                // Another list's key (`label:`, `ns:`) is nothing here.
                if term.value.contains(":") { continue }
                terms.append(Term(key: .text, values: [term.value], negated: term.negated))
            case .state, .kind, .tool, .repo:
                let values = term.value.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                let known = values.allSatisfy { Self.knows(term.key, $0) }
                guard !values.isEmpty, known else {
                    refused.append((term.negated ? "-" : "") + Self.name(term.key) + ":" + term.raw)
                    continue
                }
                terms.append(Term(key: term.key, values: values, negated: term.negated))
            }
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Whether an `is:` word asks for a state (not turned around): Hide
    /// Ready then hides nothing it asked for.
    var asksState: Bool { terms.contains { $0.key == .state && !$0.negated } }

    /// `is:nope isn't a state` — said beside the chips.
    var refusal: String? {
        guard let first = refused.first else { return nil }
        let words = refused.joined(separator: " ")
        let name = first.drop { $0 == "-" }.prefix { $0 != ":" }
        let known: String =
            switch Key.names[String(name)] {
            case .state: "is: failed, blocked, stuck, drift, progressing, paused, ready, unknown"
            case .kind: "kind: app, appset, ks, hr, source, git, oci, helmrepo, chart, bucket"
            case .tool: "tool: argo, flux"
            default: "repo: some text"
            }
        return "Not read: \(words) — \(known)"
    }

    func matches(_ row: KubeGitOpsRow) -> Bool {
        terms.allSatisfy { term in Self.holds(term, row) != term.negated }
    }

    private static func holds(_ term: Term, _ row: KubeGitOpsRow) -> Bool {
        switch term.key {
        case .text:
            let haystack = "\(row.ref.description) \(row.why) \(row.source) \(row.role.short)".lowercased()
            return term.values.allSatisfy { haystack.contains($0) }
        case .state:
            return term.values.contains { state($0) == row.state }
        case .kind:
            return term.values.contains { kind($0)?.holds(row.role) == true }
        case .tool:
            return term.values.contains { tool($0) == row.tool }
        case .repo:
            let haystack = "\(row.grouping.repo) \(row.source)".lowercased()
            return term.values.contains { haystack.contains($0) }
        }
    }

    private static func knows(_ key: Key, _ value: String) -> Bool {
        switch key {
        case .state: state(value) != nil
        case .kind: kind(value) != nil
        case .tool: tool(value) != nil
        case .repo, .text: true
        }
    }

    static func state(_ value: String) -> KubeGitOpsState? {
        if value == "failing" { return .failed }
        return KubeGitOpsState.allCases.first { $0.word.lowercased() == value }
    }

    static func kind(_ value: String) -> Kind? { Kind(rawValue: value) ?? Kind.aliases[value] }

    static func tool(_ value: String) -> KubeGitOpsObject.Tool? {
        switch value {
        case "argo", "argocd": .argo
        case "flux": .flux
        default: nil
        }
    }

    private static func name(_ key: Key) -> String {
        switch key {
        case .state: "is"
        case .kind: "kind"
        case .tool: "tool"
        case .repo: "repo"
        case .text: ""
        }
    }
}
