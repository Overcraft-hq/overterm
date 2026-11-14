import Foundation

// The pure halves of reading apps from Argo CD's marks (docs/design/
// kubernetes/gitops.md, 14.4): a page of whole objects by the allow-list,
// what one object's GET settled, when a row is read again (M2), the
// members and apps kept as rows come and go (`KubeMarkedBook`), and what
// the reads could say (`KubeMarkedReading`). `KubeMarkedAppsSession` reads.

extension KubeMarkedWorkloadWire {
    /// A list's page of whole objects (M1b), by the allow-list: no field
    /// outside it is kept; an item without its `kind` (a server's list
    /// items carry none) is the kind listed.
    static func page(_ data: Data, kind: KubeResourceKind) throws -> KubePage<KubeMarkedWorkloadWire> {
        let list = try JSONDecoder().decode(ListWire.self, from: data)
        let items = (list.items ?? []).map { item -> KubeMarkedWorkloadWire in
            var item = item
            if item.kind == nil { item.kind = kind.kind }
            if item.apiVersion == nil { item.apiVersion = kind.groupVersion }
            return item
        }
        return KubePage(items: items, next: list.metadata?.continue.flatMap { $0.isEmpty ? nil : $0 }, remaining: list.metadata?.remainingItemCount)
    }

    private struct ListWire: Decodable {
        struct Metadata: Decodable {
            var `continue`: String?
            var remainingItemCount: Int?
        }

        var metadata: Metadata?
        var items: [KubeMarkedWorkloadWire]?
    }
}

extension KubeMarkedMember {
    /// A list's page of whole objects as members (M3b: CronJobs and HPAs,
    /// whose health no cell says): each one's marks from its metadata by
    /// `KubeMarkWire`'s allow-list, checked against the kind listed, and
    /// its health by Argo CD's rule from `KubeMarkedWorkloadWire` — nothing
    /// else of the object kept.
    static func objects(_ data: Data, kind: KubeResourceKind) throws -> KubePage<KubeMarkedMember> {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KubeTableReader.Malformed(detail: String(decoding: data.prefix(120), as: UTF8.self))
        }
        let marked = KubeMarkedKind(kind)
        var members: [KubeMarkedMember] = []
        for item in list["items"] as? [[String: Any]] ?? [] {
            guard let metadata = item["metadata"] as? [String: Any], let name = metadata["name"] as? String, !name.isEmpty else { continue }
            let namespace = kind.namespaced ? metadata["namespace"] as? String : nil
            let identity = KubeTrackingID.Identity(group: kind.group, kind: kind.kind, namespace: namespace, name: name)
            guard let marks = KubeMarkWire.read(metadata: metadata, self: identity) else { continue }
            var wire = try JSONDecoder().decode(KubeMarkedWorkloadWire.self, from: JSONSerialization.data(withJSONObject: item))
            if wire.kind == nil { wire.kind = kind.kind }
            if wire.apiVersion == nil { wire.apiVersion = kind.groupVersion }
            let created = (metadata["creationTimestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
            members.append(
                KubeMarkedMember(
                    id: ID(kind: marked, namespace: namespace, name: name), marks: marks, health: KubeMarkedHealth.object(wire), images: wire.images,
                    created: created))
        }
        let metadata = list["metadata"] as? [String: Any]
        let next = (metadata?["continue"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return KubePage(items: members, next: next, remaining: (metadata?["remainingItemCount"] as? NSNumber)?.intValue)
    }
}

/// What one object's read by Argo CD's rule said (M1b's list, M2's GET):
/// the allow-listed object, its generation then, when it was read.
struct KubeMarkedSettled: Equatable, Sendable {
    var wire: KubeMarkedWorkloadWire
    var generation: Int?
    var at: Date

    init(_ wire: KubeMarkedWorkloadWire, at: Date) {
        self.wire = wire
        generation = wire.metadata?.generation
        self.at = at
    }

    /// Argo CD's word for it, as read.
    var status: KubeMarkedHealth.Status? { KubeMarkedHealth.object(wire)?.status }

    /// Whether it still says what its row says now: the same generation,
    /// and — when the row reads not ready since — not older than that change.
    func describes(_ row: KubeRow, kind: KubeMarkedKind, columns: [KubeColumn], changedAt: Date?, now: Date) -> Bool {
        if let generation, let rowGeneration = row.marks?.generation, generation != rowGeneration { return false }
        guard let changedAt, changedAt > at else { return true }
        let verdict = KubeMarkedHealth.row(kind, row, columns: columns, marks: row.marks, now: now)
        return verdict?.status == .healthy || verdict?.status == nil
    }
}

/// When a marked workload's object is read again (M2, gitops.md 14.4.1):
/// on a moved generation (a spec change: a rollout, a pause, a scale),
/// when its cells now read not ready, or when it was last settled not
/// Healthy — never for a row whose generation and readiness stand, nor
/// a Ready row that didn't move (M1b settled it). Each object at most
/// once every 15 s, at most 20 a flush and 60 a minute for the section,
/// what is in progress again every 60 s at most. Pure.
struct KubeMarkedRefetch: Equatable, Sendable {
    static let perObject: TimeInterval = 15
    static let perFlush = 20
    static let perMinute = 60
    static let inProgressEvery: TimeInterval = 60

    enum Priority: Int, Comparable, Sendable {
        /// Not ready, or last settled not Healthy.
        case problem
        /// Its generation moved, or it is new since M1b.
        case moved
        /// In progress, its 60 s look.
        case periodic

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private(set) var pending: [KubeMarkedMember.ID: Priority] = [:]
    private(set) var lastAsked: [KubeMarkedMember.ID: Date] = [:]
    /// When each GET of the last minute was taken.
    private(set) var taken: [Date] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func ask(_ id: KubeMarkedMember.ID, _ priority: Priority) {
        pending[id] = min(pending[id] ?? priority, priority)
    }

    /// How many were taken in the minute before `now`.
    func takenInLastMinute(now: Date) -> Int { taken.filter { now.timeIntervalSince($0) < 60 }.count }

    /// Up to 20 whose last GET is 15 s behind, problems first, within the
    /// minute's 60.
    mutating func take(now: Date, limit: Int = perFlush) -> [KubeMarkedMember.ID] {
        taken.removeAll { now.timeIntervalSince($0) >= 60 }
        let room = min(limit, Self.perMinute - taken.count)
        guard room > 0 else { return [] }
        let due = pending.filter { id, _ in lastAsked[id].map { now.timeIntervalSince($0) >= Self.perObject } ?? true }
        let chosen = due.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }.prefix(room).map(\.key)
        for id in chosen {
            pending[id] = nil
            lastAsked[id] = now
            taken.append(now)
        }
        return chosen
    }

    mutating func forget(_ id: KubeMarkedMember.ID) { pending[id] = nil }

    /// Why a row that changed is read again; nil when it isn't. `old`: the
    /// row before (nil: new); `settled`: its last read by Argo CD's rule.
    static func reason(old: KubeRow?, new: KubeRow, kind: KubeMarkedKind, columns: [KubeColumn], settled: KubeMarkedSettled?, now: Date) -> Priority? {
        guard old != new else { return nil }
        let generation = new.marks?.generation
        if let settled {
            if let generation, let was = settled.generation, generation != was { return .moved }
        } else if old == nil || old?.marks?.generation != generation {
            return .moved
        }
        if kind == .rollout {
            // No cell says a Rollout's phase: its counts moving is all a row shows.
            return old.map { $0.cells != new.cells } == true ? .moved : nil
        }
        if let verdict = KubeMarkedHealth.row(kind, new, columns: columns, marks: new.marks, now: now), let status = verdict.status, status != .healthy {
            return .problem
        }
        if let status = settled?.status, status != .healthy { return .problem }
        return nil
    }
}

/// One derived app as the section ranks it: the app and its health.
struct KubeMarkedRanked: Equatable, Sendable, Identifiable {
    var app: KubeMarkedApp
    var health: KubeMarkedHealth.AppVerdict

    var id: String { app.id }
}

/// The members and apps read from marks, kept as rows come and go: each
/// flush's changed rows (or members read whole) and what was settled,
/// made into members, merged into the apps (only those whose members
/// changed are made again), their health made again for those alone, and
/// every app ranked — problems first, as the section shows them. Run off
/// the main thread, once a flush (gitops.md 14.4.6). Pure.
struct KubeMarkedBook: Sendable {
    /// One member to make again.
    struct Change: Sendable {
        enum Source: Sendable {
            /// A row, its health from its cells unless `settled` still says it.
            case row(KubeRow, columns: [KubeColumn])
            /// Read whole (a CronJob, an HPA): as it is.
            case member(KubeMarkedMember)
        }

        var id: KubeMarkedMember.ID
        var source: Source
        var settled: KubeMarkedSettled?
        /// When its row last changed, as the session saw it.
        var changedAt: Date?
    }

    private(set) var apps = KubeMarkedApps()
    private(set) var verdicts: [KubeTrackingID.AppKey: KubeMarkedHealth.AppVerdict] = [:]
    private(set) var ranked: [KubeMarkedRanked] = []
    /// When each member's row first read not ready: "0/3 ready for 2h".
    private(set) var notReadySince: [KubeMarkedMember.ID: Date] = [:]

    init() {}

    /// The changes and the members gone applied; whether anything shown changed.
    @discardableResult
    mutating func apply(_ changes: [Change], removed: [KubeMarkedMember.ID], now: Date) -> Bool {
        guard !changes.isEmpty || !removed.isEmpty else { return false }
        var members: [KubeMarkedMember] = []
        members.reserveCapacity(changes.count)
        for change in changes {
            switch change.source {
            case .member(let member):
                members.append(member)
            case .row(let row, let columns):
                let kind = change.id.kind
                // When it first read not ready, kept while it stays so.
                let cells = KubeMarkedHealth.row(kind, row, columns: columns, marks: row.marks, now: now)
                if let status = cells?.status, status != .healthy {
                    if notReadySince[change.id] == nil { notReadySince[change.id] = now }
                } else {
                    notReadySince[change.id] = nil
                }
                guard var member = KubeMarkedMember.row(row, kind: kind, columns: columns, notReadySince: notReadySince[change.id], now: now) else { continue }
                if let settled = change.settled, settled.describes(row, kind: kind, columns: columns, changedAt: change.changedAt, now: now) {
                    member = member.settled(by: settled.wire)
                }
                members.append(member)
            }
        }
        for id in removed { notReadySince[id] = nil }
        let changedIDs = Set(members.map(\.id))
        let dirty = apps.merge(changed: members, removed: removed.filter { !changedIDs.contains($0) })
        for key in dirty {
            if let app = apps[key] { verdicts[key] = app.health } else { verdicts[key] = nil }
        }
        // The probable apps show only while no Argo CD mark is here: every
        // app's verdict is the shown set's.
        let shown = apps.apps
        if verdicts.count != shown.count || shown.contains(where: { verdicts[$0.key] == nil }) {
            verdicts = Dictionary(uniqueKeysWithValues: shown.map { ($0.key, verdicts[$0.key] ?? $0.health) })
        }
        let new = shown.map { KubeMarkedRanked(app: $0, health: verdicts[$0.key] ?? $0.health) }.sorted(by: Self.ordered)
        guard new != ranked else { return false }
        ranked = new
        return true
    }

    /// Problems first (the state's order), then by name.
    static func ordered(_ a: KubeMarkedRanked, _ b: KubeMarkedRanked) -> Bool {
        if a.health.state != b.health.state { return a.health.state < b.health.state }
        if a.app.said != b.app.said { return a.app.said < b.app.said }
        return a.app.key < b.app.key
    }
}

/// What the marks' reads could say of what they read (gitops.md 14.2.1,
/// 14.3): which kinds' rows came, which were refused where or cut, and so
/// whether the read was whole — "no workload carries marks" is said only
/// then; a refused, cut or unfinished read says what couldn't be read.
/// Pure.
struct KubeMarkedReading: Equatable, Sendable {
    /// The workloads' kinds read for marks (M1), by title: "Deployments".
    var kinds: [String] = []
    /// Those whose rows came.
    var listed: Set<String> = []
    /// Refused where: a namespace each, or — refused across the cluster
    /// with nowhere known to read it — `acrossTheCluster`.
    var refused: [String: [String]] = [:]
    /// Refused across the cluster, read in these namespaces with no watch.
    var fallback: [String: [String]] = [:]
    /// The rows of a kind cut short: its marks a floor.
    var rowCuts: [String: String] = [:]
    /// Not read, and why.
    var failed: [String: String] = [:]
    /// Everything else said: M1b's, M3's and M3b's cuts and refusals.
    var notes: [String: String] = [:]
    /// M1b's progress: objects checked by Argo CD's rule, of how many.
    var checked: Int?
    var checking: Int?
    /// Argo Rollouts are served here, and read for their apps' health.
    var rolloutsServed = false

    static let acrossTheCluster = "across the cluster"

    /// Every kind's rows came, none refused, cut or failed.
    var isWhole: Bool { !kinds.isEmpty && listed.isSuperset(of: kinds) && refused.isEmpty && fallback.isEmpty && rowCuts.isEmpty && failed.isEmpty }

    /// Still waiting for a kind's first rows.
    var isReading: Bool { !Set(kinds).subtracting(listed).subtracting(failed.keys).subtracting(refused.keys).isEmpty }

    /// What couldn't be read, said: "Deployments refused in 3 namespaces (a, b, c)".
    var unread: [String] {
        var said: [String] = []
        for kind in kinds {
            if let places = refused[kind] {
                let named = places.filter { $0 != Self.acrossTheCluster }.sorted()
                if named.isEmpty {
                    said.append("\(kind) refused across the cluster")
                } else {
                    said.append("\(kind) refused in \(named.count) \(named.count == 1 ? "namespace" : "namespaces") (\(named.joined(separator: ", ")))")
                }
            }
            if let reason = failed[kind] { said.append("\(kind) not read: \(reason)") }
            if let cut = rowCuts[kind] { said.append(cut) }
        }
        return said
    }

    /// Every line for the header's notes: refusals and where it read
    /// instead, cuts, M1b's progress.
    var said: [String] {
        var lines = unread
        for kind in kinds {
            if let places = fallback[kind], !places.isEmpty {
                lines.append("\(kind) refused across the cluster; read in \(places.joined(separator: ", ")) every 5 min")
            }
        }
        lines += notes.sorted { $0.key < $1.key }.map(\.value)
        if let checking, let checked, checked < checking {
            lines.append("checking rollouts \(checked.formatted()) of \(checking.formatted())")
        }
        return lines
    }

    /// The count said: exact when the read was whole, a floor when it
    /// wasn't, none while the first rows come.
    func count(_ apps: Int) -> String? {
        if isReading { return nil }
        let noun = apps == 1 ? "app" : "apps"
        if isWhole { return "\(apps.formatted()) \(noun)" }
        return "At least \(apps.formatted()) \(noun), from what could be read: \(unread.joined(separator: "; "))"
    }

    /// The section's sentence when no app was found: "carries no marks"
    /// only from a whole read.
    func empty(context: String, scope: KubeScope, served: Bool) -> String {
        let workloads = kinds.isEmpty ? "Deployments, StatefulSets and DaemonSets" : Self.joined(kinds)
        if isReading { return "Reading the marks on \(workloads)…" }
        guard isWhole else { return "No Argo CD marks found in what could be read: \(unread.joined(separator: "; "))" }
        let carriers = "no Deployment, StatefulSet or DaemonSet in \(scope.said) carries Argo CD's marks."
        return served ? "No Argo CD Application deploys here, and \(carriers)" : "No Argo CD Application is served by \(context), and \(carriers)"
    }

    static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
