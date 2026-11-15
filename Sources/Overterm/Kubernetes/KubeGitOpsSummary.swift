import Foundation

/// Argo CD's and Flux's objects summarised (docs/design/kubernetes/
/// gitops.md, 2.1–2.5): which of their kinds a cluster serves, an answer's
/// bytes into summaries (`KubeGitOpsWire`, then `KubeGitOpsObject`), the
/// ladder run over them all at once — a Flux object's Blocked is its
/// peers' — and again on every tick with no read, the scope rule, the
/// order and the counts. Pure.
enum KubeGitOpsSummary {
    /// A kind by its group and plural.
    struct Kind: Hashable, Sendable {
        var group: String
        var resource: String

        var fullName: String { "\(resource).\(group)" }
    }

    /// What is followed live, as rows (R1, decision 5).
    static let followed: [Kind] = [
        Kind(group: "argoproj.io", resource: "applications"), Kind(group: "kustomize.toolkit.fluxcd.io", resource: "kustomizations"),
        Kind(group: "helm.toolkit.fluxcd.io", resource: "helmreleases"), Kind(group: "source.toolkit.fluxcd.io", resource: "gitrepositories"),
        Kind(group: "source.toolkit.fluxcd.io", resource: "ocirepositories"),
    ]

    /// Every kind summarised (R2): the followed ones, ApplicationSets (no
    /// columns to follow) and the other three sources.
    static let summarised: [Kind] =
        followed + [
            Kind(group: "argoproj.io", resource: "applicationsets"), Kind(group: "source.toolkit.fluxcd.io", resource: "helmrepositories"),
            Kind(group: "source.toolkit.fluxcd.io", resource: "helmcharts"), Kind(group: "source.toolkit.fluxcd.io", resource: "buckets"),
        ]

    /// Whether the section has anything to show here: Argo CD's
    /// Applications or any Flux kind served.
    static func served(_ discovery: KubeDiscovery?) -> Bool {
        discovery?.kinds.contains { ($0.group == "argoproj.io" && $0.resource == "applications") || $0.group.hasSuffix(".toolkit.fluxcd.io") } ?? false
    }

    /// Which tools are served: Argo CD's kinds and Flux's, counted.
    static func tools(_ discovery: KubeDiscovery?) -> (argo: Int, flux: Int) {
        let kinds = discovery?.kinds ?? []
        let argo = Set(kinds.filter { $0.group == "argoproj.io" && ["applications", "applicationsets"].contains($0.resource) }.map(\.resource)).count
        let flux = Set(kinds.filter { $0.group.hasSuffix(".toolkit.fluxcd.io") && summarised.contains(Kind(group: $0.group, resource: $0.resource)) }.map(\.fullName)).count
        return (argo, flux)
    }

    /// The summarised kinds `discovery` serves and lets be listed, at their versions.
    static func kinds(_ discovery: KubeDiscovery?) -> [KubeResourceKind] {
        let wanted = Set(summarised)
        return (discovery?.kinds ?? []).filter { wanted.contains(Kind(group: $0.group, resource: $0.resource)) && $0.canList }
    }

    // MARK: Reading

    /// One object as a GET answers it; nil for a kind that isn't Argo CD's or Flux's.
    static func object(_ data: Data, readAt: Date) throws -> KubeGitOpsObject? {
        KubeGitOpsObject(try KubeGitOpsWire.object(data), readAt: readAt)
    }

    /// One already-decoded object (the Overview's, `KubeHealth.kept`):
    /// encoded again and read through the same allow-list.
    static func object(_ object: [String: Any], readAt: Date) -> KubeGitOpsObject? {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? Self.object(data, readAt: readAt)
    }

    /// A page of a list: its summaries (each given `kind`, which a list's
    /// items may not say), and where the next page starts.
    static func page(_ data: Data, kind: KubeResourceKind, readAt: Date) throws -> (objects: [KubeGitOpsObject], next: String?, remaining: Int?) {
        let list = try KubeGitOpsWire.list(data)
        let objects = (list.items ?? []).compactMap { item -> KubeGitOpsObject? in
            var item = item
            if item.kind == nil { item.kind = kind.kind }
            if item.apiVersion == nil { item.apiVersion = kind.groupVersion }
            return KubeGitOpsObject(item, readAt: readAt)
        }
        let next = list.metadata?.continue.flatMap { $0.isEmpty ? nil : $0 }
        return (objects, next, list.metadata?.remainingItemCount)
    }

    // MARK: The ladder over all of them

    /// Each object's state, why, since and tags from the ladder, with the
    /// others as its peers; `stale`, the tools whose controller isn't ready
    /// (each of its rows "may be stale"). The tick: run again at `now`.
    static func ranked(_ objects: [KubeGitOpsObject], now: Date, stale: Set<KubeGitOpsObject.Tool> = []) -> [KubeGitOpsObject] {
        var peers: KubeGitOpsLadder.Peers = [:]
        for object in objects { peers[object.key] = object }
        return objects.map { evaluated($0, now: now, peers: peers, stale: stale) }.sorted(by: ordered)
    }

    /// One object put on the ladder against `peers` (its source, chart, dependencies).
    static func evaluated(_ object: KubeGitOpsObject, now: Date, peers: KubeGitOpsLadder.Peers, stale: Set<KubeGitOpsObject.Tool> = []) -> KubeGitOpsObject {
        var object = object
        let verdict = KubeGitOpsLadder.evaluate(object, now: now, peers: peers)
        object.state = verdict.state
        object.why = verdict.why
        object.stateSince = verdict.since
        object.tags = verdict.tags + object.ownTags
        if stale.contains(object.tool) { object.tags.append(.mayBeStale) }
        return object
    }

    /// State in display order, then the oldest problem first, then by name.
    static func ordered(_ a: KubeGitOpsObject, _ b: KubeGitOpsObject) -> Bool {
        if a.state != b.state { return a.state < b.state }
        let at = a.stateSince ?? a.created ?? .distantFuture
        let bt = b.stateSince ?? b.created ?? .distantFuture
        if at != bt { return at < bt }
        return a.ref < b.ref
    }

    /// How many in each state.
    static func counts(_ objects: [KubeGitOpsObject]) -> [KubeGitOpsState: Int] {
        var counts: [KubeGitOpsState: Int] = [:]
        for object in objects { counts[object.state, default: 0] += 1 }
        return counts
    }

    // MARK: Scope (2.5)

    /// Kept by itself: its own namespace in scope, or one it manages, or —
    /// nothing applied yet — its destination in this cluster. One that
    /// deploys to another cluster only by its own namespace.
    static func inScope(_ object: KubeGitOpsObject, _ scope: KubeScope) -> Bool {
        if scope.includes(object.ref.namespace) { return true }
        if object.remote != nil || object.destination?.inCluster == false { return false }
        if object.managedNamespaces.contains(where: { scope.includes($0) }) { return true }
        if object.managedNamespaces.isEmpty, let destination = object.destination, destination.inCluster, let namespace = destination.namespace {
            return scope.includes(namespace)
        }
        return false
    }

    /// What lives in or deploys into `scope`: each object kept by itself,
    /// then the ApplicationSets whose Applications are kept, then the
    /// sources (and charts, and their sources) a kept one takes from.
    static func kept(_ objects: [KubeGitOpsObject], scope: KubeScope) -> [KubeGitOpsObject] {
        guard scope != .all else { return objects }
        var keep = Set(objects.filter { inScope($0, scope) }.map(\.key))
        let sets = Set(objects.filter { keep.contains($0.key) }.compactMap(\.ownerAppSet))
        for object in objects where object.role == .applicationSet && sets.contains(object.ref) { keep.insert(object.key) }
        // A HelmRelease's chart, then the chart's source: twice.
        let byKey = Dictionary(objects.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for _ in 0..<2 {
            for key in keep {
                guard let object = byKey[key] else { continue }
                for upstream in KubeGitOpsLadder.upstream(object) where byKey[upstream] != nil { keep.insert(upstream) }
            }
        }
        return objects.filter { keep.contains($0.key) }
    }
}
