import Foundation

// The pure halves of reading apps from Argo CD's marks (docs/design/
// kubernetes/gitops.md, 14.4): what one object's GET settled, when an
// object is read (M1b's settle, M2's moves, M3b's CronJobs and `<unknown>`
// HPAs — one GET each, never a list of whole objects, 14.12's fifth
// consequence), the members and apps kept as rows come and go
// (`KubeMarkedBook`), and what the reads could say (`KubeMarkedReading`).
// `KubeMarkedAppsSession` reads.

/// What one object's read by Argo CD's rule said (a GET: M1b, M2, M3b):
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
    /// An HPA's object stands only while a target still reads `<unknown>`:
    /// every target read again, its row says Healthy.
    func describes(_ row: KubeRow, kind: KubeMarkedKind, columns: [KubeColumn], changedAt: Date?, now: Date) -> Bool {
        if let generation, let rowGeneration = row.marks?.generation, generation != rowGeneration { return false }
        if kind == .horizontalPodAutoscaler { return KubeMarkedHealth.row(kind, row, columns: columns, marks: row.marks, now: now)?.unread == true }
        guard let changedAt, changedAt > at else { return true }
        let verdict = KubeMarkedHealth.row(kind, row, columns: columns, marks: row.marks, now: now)
        return verdict?.status == .healthy || verdict?.status == nil
    }
}

/// When a marked object is read by a GET (gitops.md 14.4.1), every one
/// within the section's 60 a minute:
///
/// - **M2**, a moved generation (a spec change: a rollout, a pause, a
///   scale) of a workload settled before, or a workload new since shown —
///   first;
/// - **M1b's settle**, a workload not yet settled by Argo CD's rule, the
///   most recently changed by Argo CD first; and **M3b**, a CronJob (its
///   last run no cell shows) or an HPA whose Targets read `<unknown>`, not
///   yet read or whose row moved — with what is left of the minute;
/// - what is in progress again every 60 s at most, a Degraded one every
///   5 min (the session's tick) — never on a row event.
///
/// Never for readiness alone: a row whose cells move with its generation
/// unchanged — a pod restarting, a node drained — is said from its cells
/// (14.9.3: 2,000 readiness-only row events cause no GET). Each object at
/// most once every 15 s, at most 20 a flush and 60 a minute. Pure.
struct KubeMarkedRefetch: Equatable, Sendable {
    static let perObject: TimeInterval = 15
    static let perFlush = 20
    static let perMinute = 60
    static let inProgressEvery: TimeInterval = 60
    static let degradedEvery: TimeInterval = 300

    enum Priority: Int, Comparable, Sendable {
        /// Its generation moved, or it is new since shown (M2).
        case moved
        /// In progress (60 s) or Degraded (5 min): the tick's look.
        case periodic
        /// Not yet settled by its object, or a CronJob's or an `<unknown>`
        /// HPA's row moved (M1b, M3b): the most recently changed first.
        case settle

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private(set) var pending: [KubeMarkedMember.ID: Priority] = [:]
    /// A settle's order: when Argo CD last changed it (else its creation).
    private(set) var changed: [KubeMarkedMember.ID: Date] = [:]
    private(set) var lastAsked: [KubeMarkedMember.ID: Date] = [:]
    /// When each GET of the last minute was taken.
    private(set) var taken: [Date] = []

    var isEmpty: Bool { pending.isEmpty }

    mutating func ask(_ id: KubeMarkedMember.ID, _ priority: Priority, changed at: Date? = nil) {
        pending[id] = min(pending[id] ?? priority, priority)
        if let at { changed[id] = at }
    }

    /// How many were taken in the minute before `now`.
    func takenInLastMinute(now: Date) -> Int { taken.filter { now.timeIntervalSince($0) < 60 }.count }

    /// Up to 20 whose last GET is 15 s behind, M2 first, then the tick's,
    /// then the settle by its order — within the minute's 60.
    mutating func take(now: Date, limit: Int = perFlush) -> [KubeMarkedMember.ID] {
        taken.removeAll { now.timeIntervalSince($0) >= 60 }
        let room = min(limit, Self.perMinute - taken.count)
        guard room > 0 else { return [] }
        let due = pending.filter { id, _ in lastAsked[id].map { now.timeIntervalSince($0) >= Self.perObject } ?? true }
        let chosen = due.sorted { a, b in
            if a.value != b.value { return a.value < b.value }
            let first = changed[a.key] ?? .distantPast
            let second = changed[b.key] ?? .distantPast
            return first != second ? first > second : a.key < b.key
        }
        .prefix(room).map(\.key)
        for id in chosen {
            pending[id] = nil
            changed[id] = nil
            lastAsked[id] = now
            taken.append(now)
        }
        return chosen
    }

    mutating func forget(_ id: KubeMarkedMember.ID) {
        pending[id] = nil
        changed[id] = nil
    }

    /// Nothing waiting; what was taken in the last minute and when each
    /// object was last read still count (the section hidden and shown
    /// again, another scope: the minute's 60 aren't given again).
    mutating func forgetPending() {
        pending = [:]
        changed = [:]
    }

    /// Why a marked object is read by a GET now; nil when it isn't. `old`:
    /// its row before (nil: new, or first listed); `listing`: a first list
    /// (nothing is new in it); `settled`: its last GET.
    static func reason(old: KubeRow?, new: KubeRow, kind: KubeMarkedKind, columns: [KubeColumn], settled: KubeMarkedSettled?, listing: Bool, now: Date) -> Priority? {
        if !listing, old == new { return nil }
        switch kind {
        case .deployment, .statefulSet, .daemonSet, .rollout:
            let generation = new.marks?.generation
            guard let settled else {
                // A row new while shown is a change being made: M2's. The rest wait for the settle.
                if !listing, old == nil { return .moved }
                if !listing, let was = old?.marks?.generation, let generation, was != generation { return .moved }
                return .settle
            }
            if let generation, let was = settled.generation, generation != was { return .moved }
            return nil
        case .cronJob:
            // Its last run is in no cell: read once, and again when its row moves.
            return settled == nil || (old != nil && old != new) ? .settle : nil
        case .horizontalPodAutoscaler:
            guard KubeMarkedHealth.row(kind, new, columns: columns, marks: new.marks, now: now)?.unread == true else { return nil }
            return settled == nil || (old != nil && old != new) ? .settle : nil
        default:
            return nil
        }
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
    /// Everything else said: M3's cuts and refusals.
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
        // Each kind read, one of a kind: "no Deployment, StatefulSet, DaemonSet or Rollout".
        let one = kinds.map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        let named = one.count > 1 ? one.dropLast().joined(separator: ", ") + " or " + one.last! : one.first ?? ""
        let carriers = "no \(named) in \(scope.said) carries Argo CD's marks."
        return served ? "No Argo CD Application deploys here, and \(carriers)" : "No Argo CD Application is served by \(context), and \(carriers)"
    }

    static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
