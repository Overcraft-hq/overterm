import Foundation

// The pure halves of reading apps from Argo CD's marks (docs/design/
// kubernetes/gitops.md, 14.4): what one object's GET settled, when an
// object is read (M1b's settle, M2's moves, M3b's CronJobs and `<unknown>`
// HPAs — one GET each, never a list of whole objects, 14.12's fifth
// consequence) within a context's minute (`KubeMarkedMinute`), the members
// and apps kept as rows come and go (`KubeMarkedBook`), and what the reads
// could say (`KubeMarkedReading`). `KubeMarkedAppsSession` reads.

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

/// A context's GETs of the last minute, as its API server saw the marks'
/// (gitops.md 14.4.1, M2's bound): each GET's place held from when it was
/// taken until a minute after its answer — never freed while unanswered, so
/// a server slower than four in flight can keep up with builds no backlog
/// that goes out at once when it speeds up —, and when each object was
/// last asked for (15 s an object). The context's, not a section's:
/// `KubeMarkedLedger` keeps it across a hide, a drop (the page hidden or
/// closed), another context and back — none of them gives the minute's 60
/// again. Pure.
struct KubeMarkedMinute: Equatable, Sendable {
    struct Place: Equatable, Sendable {
        var id: KubeMarkedMember.ID
        /// When it was taken; once answered, when the answer came (or the
        /// GET was given up).
        var at: Date
        var answered = false
    }

    private(set) var places: [Place] = []
    private(set) var lastAsked: [KubeMarkedMember.ID: Date] = [:]

    /// Nothing held, nothing asked lately: forgotten.
    var isEmpty: Bool { places.isEmpty && lastAsked.isEmpty }

    /// The places held at `now`: every GET unanswered, and each answered in
    /// the minute before.
    func held(at now: Date) -> Int { places.count { !$0.answered || now.timeIntervalSince($0.at) < 60 } }

    /// What is spent forgotten: a place a minute past its answer, an object
    /// last asked for a minute ago or more.
    mutating func prune(now: Date) {
        places.removeAll { $0.answered && now.timeIntervalSince($0.at) >= 60 }
        lastAsked = lastAsked.filter { now.timeIntervalSince($0.value) < 60 }
    }

    /// Whether `id` may be asked for again: 15 s since it last was.
    func due(_ id: KubeMarkedMember.ID, now: Date) -> Bool {
        lastAsked[id].map { now.timeIntervalSince($0) >= KubeMarkedRefetch.perObject } ?? true
    }

    /// A GET of `id` taken at `now`: a place held.
    mutating func took(_ id: KubeMarkedMember.ID, at now: Date) {
        places.append(Place(id: id, at: now))
        lastAsked[id] = now
    }

    /// A GET of `id` answered at `at` — or given up then (hidden while in
    /// flight: it may have reached the server): its place a minute more
    /// from then, never earlier than its take.
    mutating func answered(_ id: KubeMarkedMember.ID, at: Date) {
        guard let index = places.firstIndex(where: { $0.id == id && !$0.answered }) else { return }
        places[index].answered = true
        places[index].at = max(places[index].at, at)
    }

    /// A GET of `id` taken and never sent (hidden while it waited its
    /// turn): its place given back.
    mutating func unsent(_ id: KubeMarkedMember.ID) {
        guard let index = places.lastIndex(where: { $0.id == id && !$0.answered }) else { return }
        places.remove(at: index)
    }
}

/// When a marked object is read by a GET (gitops.md 14.4.1), every one
/// within the context's 60 a minute (`KubeMarkedMinute`):
///
/// - **M2**, a moved generation (a spec change: a rollout, a pause, a
///   scale) of a workload settled before, or a workload new since shown —
///   first;
/// - **M1b's settle**, a workload not yet settled by Argo CD's rule; and
///   **M3b**, a CronJob (its last run no cell shows) or an HPA whose
///   Targets read `<unknown>`, not yet read or whose row moved — with what
///   is left of the minute, once every first list they are ordered across
///   has come (`through`, the session's): what may be a problem first
///   (`doubtful`: not Healthy by its cells; what no cell says — a
///   Rollout's phase, a CronJob's last run, an `<unknown>` HPA's metrics —;
///   or a workload Argo CD changed in the last hour, whose rollout may be
///   stuck behind its old pod or paused under cells that read ready), then
///   the rest; each the most recently changed by Argo CD first. On the
///   surveyed spoke ≈1,150 wait at 60 a minute (gitops.md 14.9.3): what was
///   just synced, its ≈45 Deployments not ready by their rows and the
///   Rollouts whose apps say Unknown come in the first minutes, not after
///   twenty;
/// - what is in progress again every 60 s at most, a Degraded one every
///   5 min (the session's tick) — never on a row event.
///
/// Never for readiness alone: a row whose cells move with its generation
/// unchanged — a pod restarting, a node drained — is said from its cells
/// (14.9.3: 2,000 readiness-only row events cause no GET). Each object at
/// most once every 15 s, never twice at once (`busy`), at most 20 a flush
/// and 60 a minute — a GET's place held until a minute after its answer.
/// Pure.
struct KubeMarkedRefetch: Equatable, Sendable {
    static let perObject: TimeInterval = 15
    static let perFlush = 20
    static let perMinute = 60
    static let inProgressEvery: TimeInterval = 60
    static let degradedEvery: TimeInterval = 300
    /// A workload Argo CD changed (else made) this recently may hide what
    /// its cells can't say: a sync's rollout stuck behind its old pod, or
    /// paused (D-4).
    static let recentlyChanged: TimeInterval = 3_600

    enum Priority: Int, Comparable, Sendable {
        /// Its generation moved, or it is new since shown (M2).
        case moved
        /// In progress (60 s) or Degraded (5 min): the tick's look.
        case periodic
        /// Not yet settled by its object, or a CronJob's or an `<unknown>`
        /// HPA's row moved (M1b, M3b): what may be a problem first, each
        /// the most recently changed first.
        case settle

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private(set) var pending: [KubeMarkedMember.ID: Priority] = [:]
    /// A settle's order: when Argo CD last changed it (else its creation).
    private(set) var changed: [KubeMarkedMember.ID: Date] = [:]
    /// Those waiting whose rows may hide a problem (`doubtful(_:kind:…)`):
    /// taken before the rest of their priority.
    private(set) var doubts: Set<KubeMarkedMember.ID> = []
    /// How many of each priority were taken since made: the tests' count
    /// (M2's moves among them), never a clock's.
    private(set) var takenBy: [Priority: Int] = [:]

    var isEmpty: Bool { pending.isEmpty }

    /// `doubtful`: what its row says now (`doubtful(_:kind:columns:changed:now:)`)
    /// — asked again, the newest row decides.
    mutating func ask(_ id: KubeMarkedMember.ID, _ priority: Priority, changed at: Date? = nil, doubtful: Bool = false) {
        pending[id] = min(pending[id] ?? priority, priority)
        if let at { changed[id] = at }
        if doubtful { doubts.insert(id) } else { doubts.remove(id) }
    }

    /// Whether a row may hide a problem its object would say: not Healthy
    /// by its cells — in progress, or what no cell says (a Rollout's phase,
    /// a CronJob's last run, an `<unknown>` HPA's metrics) —, or a workload
    /// Argo CD changed (else made: `changed`) in the last hour — a single
    /// replica stuck behind its old pod reads `1/1`, a paused rollout its
    /// last counts. A Deployment scaled to 0 long ago is Healthy by its
    /// cells: never one.
    static func doubtful(_ row: KubeRow, kind: KubeMarkedKind, columns: [KubeColumn], changed: Date?, now: Date) -> Bool {
        if KubeMarkedHealth.row(kind, row, columns: columns, marks: row.marks, now: now)?.status != .healthy { return true }
        guard kind.cellsMayHide, let changed else { return false }
        return now.timeIntervalSince(changed) < recentlyChanged
    }

    /// Up to 20 whose last GET is 15 s behind and that aren't being read
    /// (`busy`: taken, waiting their turn or in flight), M2 first, then the
    /// tick's, then — `through` the settle — the settle by its order (what
    /// may be a problem before the rest, each the most recently changed
    /// first), within the places the context's minute has free.
    mutating func take(
        now: Date, limit: Int = perFlush, busy: Set<KubeMarkedMember.ID> = [], through: Priority = .settle, minute: inout KubeMarkedMinute
    ) -> [KubeMarkedMember.ID] {
        minute.prune(now: now)
        let room = min(limit, Self.perMinute - minute.held(at: now))
        guard room > 0 else { return [] }
        let due = pending.filter { id, priority in priority <= through && !busy.contains(id) && minute.due(id, now: now) }
        let chosen = due.sorted { a, b in
            if a.value != b.value { return a.value < b.value }
            let doubted = doubts.contains(a.key)
            if doubted != doubts.contains(b.key) { return doubted }
            let first = changed[a.key] ?? .distantPast
            let second = changed[b.key] ?? .distantPast
            return first != second ? first > second : a.key < b.key
        }
        .prefix(room)
        for (id, priority) in chosen {
            takenBy[priority, default: 0] += 1
            pending[id] = nil
            changed[id] = nil
            doubts.remove(id)
            minute.took(id, at: now)
        }
        return chosen.map(\.key)
    }

    mutating func forget(_ id: KubeMarkedMember.ID) {
        pending[id] = nil
        changed[id] = nil
        doubts.remove(id)
    }

    /// Nothing waiting; the minute is the context's (`KubeMarkedMinute`):
    /// what was taken in it and when each object was last read still count
    /// (the section hidden and shown again, another scope: its 60 aren't
    /// given again).
    mutating func forgetPending() {
        pending = [:]
        changed = [:]
        doubts = []
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
/// changed are made again), their health and their section rows made
/// again for those alone, and every app ranked — problems first, as the
/// section shows them. Run off the main thread, once a flush (gitops.md
/// 14.4.6): the main thread only swaps what it made.
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
        /// When its row was first read or last changed, as the session saw it.
        var changedAt: Date?
    }

    private(set) var apps = KubeMarkedApps()
    private(set) var verdicts: [KubeTrackingID.AppKey: KubeMarkedHealth.AppVerdict] = [:]
    private(set) var ranked: [KubeMarkedRanked] = []
    /// Each app's section row, as `KubeMarkedSection.base` makes it.
    private(set) var rows: [KubeTrackingID.AppKey: KubeGitOpsRow] = [:]
    /// Those rows in the section's order (`KubeGitOpsSection.ordered`):
    /// what the main thread lays among the rest, sorted already.
    private(set) var shownRows: [KubeGitOpsRow] = []
    /// The apps' keys: what the mode is decided from.
    private(set) var keys: Set<KubeTrackingID.AppKey> = []
    /// When each member's row was first read not ready, kept while it
    /// stays so: its state's `since` — "0/3 ready", the Age column 2h.
    private(set) var notReadySince: [KubeMarkedMember.ID: Date] = [:]
    /// How many rows every apply made: what a flush costs, counted (the
    /// tests' bound on it, never a clock's).
    private(set) var rowsMade = 0

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
                    member = member.settled(by: settled.wire, changedAt: change.changedAt)
                }
                members.append(member)
            }
        }
        for id in removed { notReadySince[id] = nil }
        let changedIDs = Set(members.map(\.id))
        let dirty = apps.merge(changed: members, removed: removed.filter { !changedIDs.contains($0) })
        var remade = dirty
        for key in dirty {
            if let app = apps[key] { verdicts[key] = app.health } else { verdicts[key] = nil }
        }
        // The probable apps show only while no Argo CD mark is here: every
        // app's verdict is the shown set's — and every row made again.
        let shown = apps.apps
        if verdicts.count != shown.count || shown.contains(where: { verdicts[$0.key] == nil }) {
            verdicts = Dictionary(uniqueKeysWithValues: shown.map { ($0.key, verdicts[$0.key] ?? $0.health) })
            remade = Set(shown.map(\.key))
        }
        let new = shown.map { KubeMarkedRanked(app: $0, health: verdicts[$0.key] ?? $0.health) }.sorted(by: Self.ordered)
        guard new != ranked else { return false }
        ranked = new
        // The section's rows: only the apps made again, the rest as they were.
        var made: [KubeTrackingID.AppKey: KubeGitOpsRow] = [:]
        made.reserveCapacity(new.count)
        for app in new {
            let key = app.app.key
            if !remade.contains(key), let kept = rows[key] {
                made[key] = kept
            } else {
                made[key] = KubeMarkedSection.base(app)
                rowsMade += 1
            }
        }
        rows = made
        keys = Set(made.keys)
        shownRows = new.compactMap { made[$0.app.key] }.sorted(by: KubeGitOpsSection.ordered)
        return true
    }

    /// Problems first (the state's order), then by name.
    static func ordered(_ a: KubeMarkedRanked, _ b: KubeMarkedRanked) -> Bool {
        if a.health.state != b.health.state { return a.health.state < b.health.state }
        if a.app.said != b.app.said { return a.app.said < b.app.said }
        return a.app.key < b.app.key
    }
}

/// A sentence the marks' reads keep with its counts as numbers (gitops.md
/// 14.2.6): said with the person's grouping on the page (`2,000`), plainly
/// to an agent (`2000`) — the owner's Turkish writes two thousand `2.000`,
/// which an agent reading English takes for two. Written as a string, a
/// count interpolated as `\(count: n)`; two are the same when they read
/// the same plainly, however they were written. Pure.
struct KubeCountedText: Equatable, Hashable, Sendable, ExpressibleByStringInterpolation {
    fileprivate enum Piece: Equatable, Hashable, Sendable {
        case text(String)
        case count(Int)
    }

    /// Text and counts in turn, two texts never side by side.
    fileprivate var pieces: [Piece]

    static func == (a: KubeCountedText, b: KubeCountedText) -> Bool { a.said(plain: true) == b.said(plain: true) }
    func hash(into hasher: inout Hasher) { hasher.combine(said(plain: true)) }

    init(_ text: String) { pieces = text.isEmpty ? [] : [.text(text)] }
    init(stringLiteral text: String) { self.init(text) }
    init(stringInterpolation: StringInterpolation) { pieces = stringInterpolation.pieces }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var pieces: [Piece] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { KubeCountedText.append(literal, to: &pieces) }
        /// A count: grouped as the person's locale writes it on the page, plain to an agent.
        mutating func appendInterpolation(count: Int) { pieces.append(.count(count)) }
        mutating func appendInterpolation(_ text: some CustomStringConvertible) { KubeCountedText.append(text.description, to: &pieces) }
    }

    fileprivate static func append(_ text: String, to pieces: inout [Piece]) {
        guard !text.isEmpty else { return }
        if case .text(let before)? = pieces.last {
            pieces[pieces.count - 1] = .text(before + text)
        } else {
            pieces.append(.text(text))
        }
    }

    /// As the page says it, or (`plain`) as an agent reads it.
    func said(plain: Bool = false) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .count(let count): KubeCountedText.number(count, plain: plain)
            }
        }.joined()
    }

    /// A count as the page writes it (`2,000`), or plainly (`2000`).
    static func number(_ count: Int, plain: Bool) -> String { plain ? String(count) : count.formatted() }

    /// The parts one after the other, `separator` between them.
    static func joined(_ parts: [KubeCountedText], separator: String) -> KubeCountedText {
        var joined = KubeCountedText("")
        for (index, part) in parts.enumerated() {
            if index > 0 { append(separator, to: &joined.pieces) }
            for piece in part.pieces {
                switch piece {
                case .text(let text): append(text, to: &joined.pieces)
                case .count: joined.pieces.append(piece)
                }
            }
        }
        return joined
    }
}

/// What the marks' reads could say of what they read (gitops.md 14.2.1,
/// 14.3): which kinds' rows came, which were refused where or cut, and so
/// whether the read was whole — "no workload carries marks" is said only
/// then; a refused, cut or unfinished read says what couldn't be read.
/// Its counts are kept as numbers: the page groups them as the person's
/// locale does, an agent reads them plain (`plain`). Pure.
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
    var rowCuts: [String: KubeCountedText] = [:]
    /// Not read, and why.
    var failed: [String: String] = [:]
    /// Everything else said: M3's cuts and refusals.
    var notes: [String: KubeCountedText] = [:]
    /// M1b's progress: objects checked by Argo CD's rule, of how many.
    var checked: Int?
    var checking: Int?
    /// Argo Rollouts are served here, and read for their apps' health.
    var rolloutsServed = false
    /// A kind refused across the cluster is read again where it may be
    /// every 5 min (the section's); an agent's read is once.
    var rereads = true

    static let acrossTheCluster = "across the cluster"

    /// Every kind's rows came, none refused, cut or failed.
    var isWhole: Bool { !kinds.isEmpty && listed.isSuperset(of: kinds) && refused.isEmpty && fallback.isEmpty && rowCuts.isEmpty && failed.isEmpty }

    /// Still waiting for a kind's first rows.
    var isReading: Bool { !Set(kinds).subtracting(listed).subtracting(failed.keys).subtracting(refused.keys).isEmpty }

    /// What couldn't be read, said: "Deployments refused in 3 namespaces
    /// (a, b, c)"; a kind refused across the cluster and read where it may
    /// be, where — what a count "at least" and an empty sentence name.
    var unread: [String] { unread(plain: false) }

    /// The same, its counts plain (`plain`: an agent's) or grouped as the page writes them.
    func unread(plain: Bool) -> [String] {
        var said: [String] = []
        for kind in kinds {
            if let places = fallback[kind], !places.isEmpty {
                said.append("\(kind) refused across the cluster; read in \(places.joined(separator: ", "))\(rereads ? " every 5 min" : "")")
            }
            if let places = refused[kind] {
                let named = places.filter { $0 != Self.acrossTheCluster }.sorted()
                if named.isEmpty {
                    said.append("\(kind) refused across the cluster")
                } else {
                    said.append("\(kind) refused in \(named.count) \(named.count == 1 ? "namespace" : "namespaces") (\(named.joined(separator: ", ")))")
                }
            }
            if let reason = failed[kind] { said.append("\(kind) not read: \(reason)") }
            if let cut = rowCuts[kind] { said.append(cut.said(plain: plain)) }
        }
        return said
    }

    /// Every line for the header's notes: refusals and where it read
    /// instead, cuts, M1b's progress.
    var said: [String] { said(plain: false) }

    /// The same, its counts plain (`plain`: an agent's) or grouped as the page writes them.
    func said(plain: Bool) -> [String] {
        var lines = unread(plain: plain)
        lines += notes.sorted { $0.key < $1.key }.map { $0.value.said(plain: plain) }
        if let checking, let checked, checked < checking {
            lines.append("checking rollouts \(KubeCountedText.number(checked, plain: plain)) of \(KubeCountedText.number(checking, plain: plain))")
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
    /// only from a whole read (`plain`: an agent's counts).
    func empty(context: String, scope: KubeScope, served: Bool, plain: Bool = false) -> String {
        let workloads = kinds.isEmpty ? "Deployments, StatefulSets and DaemonSets" : Self.joined(kinds)
        if isReading { return "Reading the marks on \(workloads)…" }
        guard isWhole else { return "No Argo CD marks found in what could be read: \(unread(plain: plain).joined(separator: "; "))" }
        let carriers = carriers(scope: scope)
        return served ? "No Argo CD Application deploys here, and \(carriers)" : "No Argo CD Application is served by \(context), and \(carriers)"
    }

    /// Each kind read, one of a kind: "no Deployment, StatefulSet,
    /// DaemonSet or Rollout in all namespaces carries Argo CD's marks." —
    /// said only of a whole read.
    func carriers(scope: KubeScope) -> String {
        let one = (kinds.isEmpty ? ["Deployments", "StatefulSets", "DaemonSets"] : kinds).map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        let named = one.count > 1 ? one.dropLast().joined(separator: ", ") + " or " + one.last! : one.first ?? ""
        return "no \(named) in \(scope.said) carries Argo CD's marks."
    }

    static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
