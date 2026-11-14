import Foundation

/// The GitOps section's apps read from Argo CD's marks (docs/design/
/// kubernetes/gitops.md, 14.4), where no Application here deploys them: a
/// window's, owned by its `KubeGitOpsSession`, which starts it — from
/// discovery, so with no discovery yet (a sign-in still waiting) nothing
/// is asked at all. Rows only, never a list of whole objects (14.12's
/// fifth consequence). While it shows:
///
/// - **M1**, the workloads' rows with their metadata (`KubeListOptions.
///   marks`): Deployments, StatefulSets, DaemonSets, and Argo Rollouts
///   where they are served (read for their app's health only). Followed
///   (`reads == .follow`) in the watches given (`watches`), in that order
///   — a kind left without one is listed every 5 min instead — on All
///   Namespaces or one namespace with one watch a kind; several
///   namespaces a watch each only while that fits, else one across the
///   cluster filtered to them. Refused across the cluster: paged lists
///   with no watch in the context's `accessibleNamespaces`, else the
///   scope's — on show, on Refresh and every 5 min — said. Beside
///   Applications that are read (`.periodic`, decision D-1) they are such
///   lists always, never watched.
/// - **M1b**, the settle: a GET of each marked workload not yet settled by
///   Argo CD's rule, the most recently changed first, with what M2 leaves
///   of the minute's 60 — which cells can't say (a paused Deployment, a
///   stale generation, a stuck single-replica rollout whose old pod
///   serves); until then "from its row". Beside Applications only the
///   derived apps' members (`settling`).
/// - **M2**, a GET of one workload whose generation moved, or new while
///   shown (`KubeMarkedRefetch`): first, 20 a flush, 4 in flight, 60 a
///   minute for the section — kept across a hide and a show of the same
///   context; never for readiness alone. What is in progress again every
///   60 s, a Degraded one every 5 min (`tick`).
/// - **M3**, Services, Ingresses, PVCs, Jobs (a hook Job is under its app,
///   never in its health), CronJobs and HPAs (at `autoscaling/v2`): one
///   paged rows-with-metadata list a kind, no watch — on show, Refresh and
///   every 5 min while shown; **M3b**, a GET within the same 60 a minute
///   of each marked CronJob and each HPA whose Targets read `<unknown>`.
///
/// Members are made into apps, their health made and every app ranked
/// off the main thread once a flush (`KubeMarkedBook`); the main thread
/// swaps the ranked list. What M1b, M2, M3 and M3b read is kept five
/// minutes while the page shows (`Store`), in memory only; `hide` ends
/// every read, `drop` forgets it (the page hidden, another context, a
/// credential failure). Never a Secret or a ConfigMap, never a ReplicaSet
/// or a pod across the cluster, never a list or a watch of whole objects,
/// never a write.
@MainActor
final class KubeMarkedAppsSession: ObservableObject {
    enum State: Equatable {
        case idle, loading, live
    }

    /// How M1's rows are read.
    enum Reads: Equatable, Sendable {
        /// Followed: Argo CD's Applications aren't here.
        case follow
        /// A paged list on show, Refresh and every 5 min, never watched:
        /// beside Applications that are read (decision D-1).
        case periodic
    }

    /// The bounds (gitops.md 14.4.1): constants but for the tests'.
    struct Bounds: Sendable {
        /// M3 (and M1 listed): rows a page, bytes a page, objects and bytes a kind.
        var rowsPage = 500
        var pageBytes = 16 << 20
        var rowsObjects = 5000
        var rowsBytes = 16 << 20
        /// M1b, M2, M3b: an object's GET.
        var getBytes = 4 << 20
    }

    nonisolated static let inFlight = 4
    nonisolated static let storeLife: TimeInterval = 300
    /// M3 and listed M1 again, while shown.
    nonisolated static let rereadEvery: TimeInterval = 300

    var bounds = Bounds()

    /// What M1b, M2, M3 and M3b read of a context: kept five minutes while the page shows.
    struct Store {
        var context: String
        var readAt: Date
        /// Each object as its GET said it (M1b, M2, M3b).
        var settled: [KubeMarkedMember.ID: KubeMarkedSettled] = [:]
        /// M3's rows, by kind.
        var rows: [String: KubeRows] = [:]
        /// What finished: `rows:<kind>`.
        var done: Set<String> = []
        /// Each read's cut or refusal, said.
        var notes: [String: String] = [:]
    }

    @Published private(set) var state: State = .idle
    /// The derived apps, ranked: problems first.
    @Published private(set) var apps: [KubeMarkedRanked] = []
    /// Copies, garbled marks and Helm's instance labels: counted, never shown.
    @Published private(set) var tally = KubeMarkedApps.Tally()
    /// What the reads could say of what they read.
    @Published private(set) var reading = KubeMarkedReading()
    /// When M3 last read.
    @Published private(set) var readAt: Date?

    private(set) var context: String?
    private(set) var scope: KubeScope = .all
    private(set) var reads: Reads = .follow
    private var client: KubeClient?
    private var accessible: [String] = []
    private var watches = KubeScope.watchCap
    private var workloads: [KubeResourceKind] = []
    private var rowKinds: [KubeResourceKind] = []
    /// The kinds an object of is read by a GET: the workloads, CronJobs, HPAs.
    private var fetched: [KubeResourceKind] = []
    private(set) var store: Store?

    /// Beside read Applications, the derived apps whose members are read
    /// by GET (M1b, M2, M3b): only theirs; nil: every app's when followed
    /// (a spoke), none when listed beside Applications.
    var settling: Set<KubeTrackingID.AppKey>? {
        didSet { if settling != oldValue { askAgain() } }
    }
    /// Told after the apps were ranked again (once a flush), once live, and
    /// when they were dropped by a failure here: never on a row event.
    var changed: (() -> Void)?

    var flushInterval: Duration = .milliseconds(250)
    var tickInterval: Duration = .seconds(30)
    var clock: () -> Date = { Date() }

    /// Every row read with marks, by kind (M1's, M3's).
    private var rows: [String: KubeRows] = [:]
    private var rowChangedAt: [KubeMarkedMember.ID: Date] = [:]
    private var follows: [String: Task<Void, Never>] = [:]
    private var lists: [String: Task<Void, Never>] = [:]
    private var gets: [KubeMarkedMember.ID: Task<Void, Never>] = [:]
    private var refetch = KubeMarkedRefetch()
    /// The context `refetch`'s minute is for: another starts its own.
    private var refetchContext: String?
    /// M1b's settle and M3b since shown: what was asked, and what couldn't be read.
    private var settleAsked: Set<KubeMarkedMember.ID> = []
    private var unreadable: Set<KubeMarkedMember.ID> = []
    private var queue: [KubeMarkedMember.ID] = []
    private var changes: [KubeMarkedMember.ID: KubeMarkedBook.Change] = [:]
    private var removed: Set<KubeMarkedMember.ID> = []
    /// The apps as made so far; nil while a flush makes them off the main
    /// thread — handed over whole, so the main thread keeps no copy.
    private var box: Box? = Box(KubeMarkedBook())
    private var flushing: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var generation = 0
    private var rereadAt: Date?
    /// The M1 kinds read by paged lists, refused across the cluster: where.
    private var fallback: [String: [String]] = [:]

    var isReading: Bool { !follows.isEmpty || !lists.isEmpty || !gets.isEmpty }

    // MARK: Shown, hidden

    /// Shown, on `context` in `scope`: M1 followed or listed, M3 read unless
    /// the store holds it fresh, each object not yet settled asked for.
    /// `discovery` nil: nothing. `watches`: how many M1 may take (the
    /// page's ten less the GitOps section's own).
    func show(
        context: String, scope: KubeScope, discovery: KubeDiscovery?, client: KubeClient?, accessible: [String] = [], reads: Reads = .follow,
        watches: Int = KubeScope.watchCap
    ) {
        guard let discovery, let client else { return hide() }
        let kinds = Self.kinds(discovery)
        if let store, store.context != context { drop() }
        if refetchContext != context {
            // Another context's minute is its own.
            refetch = KubeMarkedRefetch()
            refetchContext = context
        }
        let same =
            self.context == context && state != .idle && self.reads == reads && self.accessible == accessible
            && Self.allot(watches, reads: reads, kinds: kinds.workloads.count) == Self.allot(self.watches, reads: self.reads, kinds: workloads.count)
            && workloads.map(\.fullName) == kinds.workloads.map(\.fullName) && rowKinds.map(\.fullName) == kinds.rows.map(\.fullName)
        if same, scope == self.scope { return }
        hide()
        if scope != self.scope, var store {
            // Another scope: M3's reads are the scope's; what was settled
            // is each object's, kept.
            store.rows = [:]
            store.done = []
            self.store = store
        }
        self.context = context
        self.scope = scope
        self.client = client
        self.accessible = accessible
        self.reads = reads
        self.watches = watches
        workloads = kinds.workloads
        rowKinds = kinds.rows
        fetched = kinds.workloads + kinds.rows.filter { [.cronJob, .horizontalPodAutoscaler].contains(KubeMarkedKind($0)) }
        state = .loading
        let now = clock()
        var reading = KubeMarkedReading()
        reading.kinds = workloads.map(KubeKindCatalog.title(of:))
        reading.rolloutsServed = workloads.contains { $0.fullName == Self.rollouts }
        self.reading = reading
        if let store, store.context == context, now.timeIntervalSince(store.readAt) <= Self.storeLife {
            readAt = store.readAt
            // What the store holds, made into members again.
            for (name, kept) in store.rows {
                guard let kind = rowKinds.first(where: { $0.fullName == name }) else { continue }
                rows[name] = kept
                for row in kept.sorted { note(row, kind: kind, columns: kept.columns) }
            }
        } else {
            store = Store(context: context, readAt: now)
            readAt = nil
        }
        rereadAt = store?.readAt
        startWorkloads(client: client)
        for kind in rowKinds where store?.done.contains("rows:\(kind.fullName)") != true { listRows(kind, client: client) }
        startTick()
        publishNotes()
        scheduleFlush(now: false)
    }

    /// Refresh (⌘R): M3 and listed M1 read again; what is settled stays,
    /// read again by its rules.
    func refresh() {
        guard let client, let context, state != .idle else { return }
        store = Store(context: context, readAt: clock(), settled: store?.settled ?? [:], rows: store?.rows ?? [:])
        rereadAt = store?.readAt
        reread(client: client)
    }

    /// Off screen: every read ends; what M1b, M2, M3 and M3b read stays,
    /// and so does the minute's count of GETs.
    func hide() {
        generation += 1
        for task in follows.values { task.cancel() }
        follows = [:]
        for task in lists.values { task.cancel() }
        lists = [:]
        for task in gets.values { task.cancel() }
        gets = [:]
        flushing?.cancel()
        flushing = nil
        ticking?.cancel()
        ticking = nil
        queue = []
        // The minute's 60 are the context's: a hide and a show don't give them again.
        refetch.forgetPending()
        settleAsked = []
        unreadable = []
        changes = [:]
        removed = []
        rows = [:]
        rowChangedAt = [:]
        fallback = [:]
        box = Box(KubeMarkedBook())
        client = nil
        context = nil
        mostInFlight = 0
        mostTaken = 0
        if state != .idle { state = .idle }
        if !apps.isEmpty { apps = [] }
        if tally != KubeMarkedApps.Tally() { tally = KubeMarkedApps.Tally() }
        if reading != KubeMarkedReading() { reading = KubeMarkedReading() }
    }

    /// The page hidden, another context, a credential failure: what was read goes too.
    func drop() {
        hide()
        store = nil
        readAt = nil
        refetch = KubeMarkedRefetch()
        refetchContext = nil
    }

    /// A credential failure here: dropped, and the owner told (no flush will).
    private func dropped() {
        drop()
        changed?()
    }

    // MARK: What is read

    nonisolated static let rollouts = "rollouts.argoproj.io"

    /// The kinds read here, as discovery serves them: M1's workloads (and
    /// Argo Rollouts), in the order they get a watch; M3's rows, CronJobs
    /// and HPAs among them. Never a Secret, a ConfigMap, a ReplicaSet or a pod.
    nonisolated static func kinds(_ discovery: KubeDiscovery) -> (workloads: [KubeResourceKind], rows: [KubeResourceKind]) {
        func served(_ name: String) -> KubeResourceKind? {
            discovery.kinds.first { $0.fullName == name && $0.canList }
        }
        let workloads = ["deployments.apps", "statefulsets.apps", "daemonsets.apps", rollouts].compactMap(served)
        var rows = ["services", "ingresses.networking.k8s.io", "persistentvolumeclaims", "jobs.batch", "cronjobs.batch"].compactMap(served)
        if var hpa = served("horizontalpodautoscalers.autoscaling") {
            // v2's conditions: v1 keeps them in an annotation.
            hpa.version = "v2"
            rows.append(hpa)
        }
        return (workloads, rows)
    }

    /// M1's watches, a kind each in order: `watches` shared evenly when
    /// every kind has one; else the first kinds one each, the rest (0)
    /// listed every 5 min. Listed beside Applications: none.
    nonisolated static func allot(_ watches: Int, reads: Reads, kinds: Int) -> [Int] {
        guard reads == .follow, kinds > 0 else { return Array(repeating: 0, count: kinds) }
        if watches >= kinds { return Array(repeating: watches / kinds, count: kinds) }
        return (0..<kinds).map { $0 < watches ? 1 : 0 }
    }

    /// Where a kind refused across the cluster is read: the context's
    /// `accessibleNamespaces`, else the scope's.
    private var fallbackNamespaces: [String] { accessible.isEmpty ? (scope.names ?? []) : accessible }

    /// Where a list reads: across the cluster, the one namespace, or each
    /// of several up to ten (past them across the cluster, kept to them).
    private func places(_ kind: KubeResourceKind) -> [String?] {
        if let places = fallback[kind.fullName] { return places }
        return scope.reads(for: kind)
    }

    private func memberID(_ kind: KubeResourceKind, _ row: KubeRowID) -> KubeMarkedMember.ID {
        KubeMarkedMember.ID(kind: KubeMarkedKind(kind), namespace: kind.namespaced ? row.namespace : nil, name: row.name)
    }

    // MARK: M1: the workloads' rows

    private func startWorkloads(client: KubeClient) {
        let caps = Self.allot(watches, reads: reads, kinds: workloads.count)
        for (kind, cap) in zip(workloads, caps) {
            // No watch left for it: listed, and again every 5 min (`reread`).
            if cap < 1 { listRows(kind, client: client) } else { follow(kind, cap: cap, client: client) }
        }
    }

    /// One kind's rows followed in the scope; refused across the cluster,
    /// listed where it may be.
    private func follow(_ kind: KubeResourceKind, cap: Int, client: KubeClient) {
        let generation = self.generation
        let name = kind.fullName
        let scope = self.scope
        follows[name] = Task { [weak self] in
            do {
                for try await update in client.follow(kind, in: scope, options: KubeListOptions(marks: true), cap: cap) {
                    guard let self, self.generation == generation else { return }
                    self.received(update, kind: kind)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.follows[name] = nil
                self.followFailed(kind, error, client: client)
            }
        }
    }

    private func followFailed(_ kind: KubeResourceKind, _ error: Error, client: KubeClient) {
        let title = KubeKindCatalog.title(of: kind)
        let refusedAcross = ((error as? KubeAPIError)?.isForbidden == true && scope.namespace(for: kind) == nil) || error is KubeScopeRefused
        if refusedAcross {
            // Paged lists where it may be, no watch: 3 kinds × N namespaces of watches don't fit.
            let places = fallbackNamespaces
            guard !places.isEmpty else {
                reading.refused[title] = [KubeMarkedReading.acrossTheCluster]
                publishNotes()
                return settle()
            }
            fallback[kind.fullName] = places
            reading.fallback[title] = places
            listRows(kind, client: client)
            return publishNotes()
        }
        if let api = error as? KubeAPIError, api.isForbidden {
            reading.refused[title] = scope.names ?? [KubeMarkedReading.acrossTheCluster]
        } else {
            reading.failed[title] = KubernetesModel.said(error)
        }
        if error is KubeProxyProblem { return dropped() }
        publishNotes()
        settle()
    }

    private func received(_ update: KubeFollowUpdate, kind: KubeResourceKind) {
        let name = kind.fullName
        let title = KubeKindCatalog.title(of: kind)
        switch update {
        case .retrying, .bookmark: return
        case .unlisted(let namespace, _):
            var refused = reading.refused[title] ?? []
            if !refused.contains(namespace) { refused.append(namespace) }
            reading.refused[title] = refused
            publishNotes()
            return
        case .listed(let table):
            took(KubeRows(table), kind: kind)
        case .changed(let list, _):
            var kept = rows[name] ?? KubeRows()
            let before = kept
            kept.apply(update)
            rows[name] = kept
            rowsChanged += list.count
            for change in list {
                switch change {
                case .added(let row), .modified(let row): note(row, kind: kind, columns: kept.columns, old: before[row.id], listing: false)
                case .deleted(let id): gone(memberID(kind, id))
                }
            }
        }
        scheduleFlush(now: false)
        settle()
    }

    /// A kind's rows whole (a follow's list, a paged list): those gone
    /// dropped, each row noted against what it was.
    private func took(_ new: KubeRows, kind: KubeResourceKind) {
        let name = kind.fullName
        let before = rows[name]
        rows[name] = new
        for row in before?.sorted ?? [] where new[row.id] == nil { gone(memberID(kind, row.id)) }
        for row in new.sorted { note(row, kind: kind, columns: new.columns, old: before?[row.id], listing: before == nil) }
        if workloads.contains(where: { $0.fullName == name }) { reading.listed.insert(KubeKindCatalog.title(of: kind)) }
    }

    /// A row seen: its member made again at the next flush; its object
    /// asked for by `KubeMarkedRefetch`'s rules.
    private func note(_ row: KubeRow, kind: KubeResourceKind, columns: [KubeColumn], old: KubeRow? = nil, listing: Bool = true) {
        let id = memberID(kind, row.id)
        let now = clock()
        if old != row { rowChangedAt[id] = now }
        let settled = store?.settled[id]
        changes[id] = .init(id: id, source: .row(row, columns: columns), settled: settled, changedAt: rowChangedAt[id])
        removed.remove(id)
        ask(row, id: id, kind: kind, columns: columns, old: old, listing: listing, settled: settled, now: now)
    }

    /// Its object asked for, when it is one of a derived app's (`reads`)
    /// and its rules say so.
    private func ask(
        _ row: KubeRow, id: KubeMarkedMember.ID, kind: KubeResourceKind, columns: [KubeColumn], old: KubeRow?, listing: Bool, settled: KubeMarkedSettled?,
        now: Date
    ) {
        guard fetched.contains(where: { $0.fullName == kind.fullName }), isRead(row.marks),
            let priority = KubeMarkedRefetch.reason(old: old, new: row, kind: id.kind, columns: columns, settled: settled, listing: listing, now: now)
        else { return }
        if priority == .settle { settleAsked.insert(id) }
        refetch.ask(id, priority, changed: row.marks?.argoChanged ?? row.created)
    }

    /// Whether a row's object is read by GET: its own Argo CD mark names
    /// an app, a derived one — every app's on a spoke, beside Applications
    /// only those `settling` names (14.4.5).
    private func isRead(_ marks: KubeMarkWire?) -> Bool {
        guard let marks, marks.hasArgoMark, case .app(let key) = KubeMarkedApps.place(marks) else { return false }
        if let settling { return settling.contains(key) }
        return reads == .follow
    }

    /// The derived apps changed (`settling`): every row's object asked for
    /// again under the new rule, nothing waiting for an app no longer
    /// derived.
    private func askAgain() {
        guard state != .idle else { return }
        refetch.forgetPending()
        let now = clock()
        for kind in fetched {
            guard let kept = rows[kind.fullName] else { continue }
            for row in kept.sorted {
                let id = memberID(kind, row.id)
                ask(row, id: id, kind: kind, columns: kept.columns, old: nil, listing: true, settled: store?.settled[id], now: now)
            }
        }
        publishNotes()
        scheduleFlush(now: false)
    }

    private func gone(_ id: KubeMarkedMember.ID) {
        changes[id] = nil
        removed.insert(id)
        rowChangedAt[id] = nil
        refetch.forget(id)
        settleAsked.remove(id)
    }

    // MARK: Paged rows (M3; M1 listed)

    /// One kind's rows with their metadata, paged, no watch: where it is
    /// read; refused across the cluster, where it may be.
    private func listRows(_ kind: KubeResourceKind, client: KubeClient) {
        let name = kind.fullName
        let generation = self.generation
        let places = places(kind)
        let workload = workloads.contains { $0.fullName == name }
        let bounds = self.bounds
        lists["rows:\(name)"]?.cancel()
        lists["rows:\(name)"] = Task { [weak self] in
            let read = await Self.readRows(kind, places: places, client: client, bounds: bounds)
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.lists["rows:\(name)"] = nil
            if case .refusedAcross = read, self.fallback[name] == nil, !self.fallbackNamespaces.isEmpty {
                // Refused across the cluster: where it may be, no watch.
                self.fallback[name] = self.fallbackNamespaces
                if workload { self.reading.fallback[KubeKindCatalog.title(of: kind)] = self.fallbackNamespaces }
                return self.listRows(kind, client: client)
            }
            self.tookRows(kind, read)
        }
    }

    private enum RowsRead: Sendable {
        case read(KubeRows, refused: [String], cut: Bool)
        case refusedAcross
        case failed(Error)
    }

    private nonisolated static func readRows(_ kind: KubeResourceKind, places: [String?], client: KubeClient, bounds: Bounds) async -> RowsRead {
        var columns: [KubeColumn] = []
        var all: [KubeRow] = []
        var bytes = 0
        var refused: [String] = []
        var cut = false
        for place in places {
            guard !Task.isCancelled else { break }
            let left = bounds.rowsObjects - all.count
            guard left > 0, bytes < bounds.rowsBytes else {
                cut = true
                break
            }
            do {
                let list = try await client.pagedList(
                    kind, in: place, accept: KubeClient.tableAccept, query: [("includeObject", "Metadata")], pageLimit: bounds.rowsPage,
                    maxBytes: bounds.pageBytes, stopAfter: left, totalBytes: bounds.rowsBytes - bytes
                ) { data in
                    let table = try KubeTableReader.read(data, namespace: place, kind: kind, marks: true)
                    return KubePage(items: table.rows, next: table.continueToken, remaining: table.remainingItemCount, columns: table.columns)
                }
                if columns.isEmpty, let read = list.columns { columns = read }
                all += list.items
                bytes += list.bytes
                if list.stopped != nil { cut = true }
            } catch let error as KubeAPIError where error.isForbidden {
                if place == nil { return .refusedAcross }
                refused.append(place!)
            } catch {
                return .failed(error)
            }
        }
        return .read(KubeRows(KubeTable(columns: columns, rows: all)), refused: refused, cut: cut)
    }

    private func tookRows(_ kind: KubeResourceKind, _ read: RowsRead) {
        let name = kind.fullName
        let title = KubeKindCatalog.title(of: kind)
        let workload = workloads.contains { $0.fullName == name }
        switch read {
        case .read(let kept, let refused, let cut):
            took(kept, kind: kind)
            let cutSaid = cut ? "\(title): the list stopped at \(kept.count.formatted()); the rest not read" : nil
            if workload {
                reading.rowCuts[title] = cutSaid
                if !refused.isEmpty { reading.refused[title] = refused } else { reading.refused[title] = nil }
            } else {
                store?.rows[name] = kept
                store?.done.insert("rows:\(name)")
                var said = cutSaid
                if !refused.isEmpty { said = [said, "\(title) refused in \(refused.joined(separator: ", "))"].compactMap { $0 }.joined(separator: "; ") }
                store?.notes["rows:\(name)"] = said
            }
        case .refusedAcross:
            if workload {
                reading.refused[title] = [KubeMarkedReading.acrossTheCluster]
            } else {
                store?.notes["rows:\(name)"] = "\(title): refused across the cluster"
                store?.done.insert("rows:\(name)")
            }
        case .failed(let error):
            if error is KubeProxyProblem { return dropped() }
            if workload { reading.failed[title] = KubernetesModel.said(error) } else { store?.notes["rows:\(name)"] = "\(title): not read — \(KubernetesModel.said(error))" }
        }
        publishNotes()
        scheduleFlush(now: false)
        settle()
    }

    // MARK: M1b, M2, M3b: one object's GET

    private func pump() {
        guard let client else { return }
        while gets.count < Self.inFlight, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let kind = fetched.first(where: { KubeMarkedKind($0) == id.kind }) else { continue }
            let generation = self.generation
            let path = kind.path(namespace: id.namespace, name: id.name)
            let readAt = clock()
            let getBytes = bounds.getBytes
            gets[id] = Task { [weak self] in
                let result: Result<KubeMarkedWorkloadWire, Error>
                do {
                    let data = try await client.get(path, maxBytes: getBytes)
                    result = await KubeBlocking.run { Result { try KubeMarkedWorkloadWire.decode(data) } }
                } catch {
                    result = .failure(error)
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.gets[id] = nil
                self.got(id, kind: kind, result, at: readAt)
                self.pump()
            }
            getsAsked += 1
            mostInFlight = max(mostInFlight, gets.count)
        }
    }

    private func got(_ id: KubeMarkedMember.ID, kind: KubeResourceKind, _ result: Result<KubeMarkedWorkloadWire, Error>, at readAt: Date) {
        switch result {
        case .success(var wire):
            if wire.kind == nil { wire.kind = kind.kind }
            if wire.apiVersion == nil { wire.apiVersion = kind.groupVersion }
            let settled = KubeMarkedSettled(wire, at: readAt)
            store?.settled[id] = settled
            if let kept = rows[kind.fullName], let row = kept[KubeRowID(namespace: id.namespace, name: id.name)] {
                changes[id] = .init(id: id, source: .row(row, columns: kept.columns), settled: settled, changedAt: rowChangedAt[id])
            }
        case .failure(let error as KubeAPIError) where error.isNotFound:
            store?.settled[id] = nil
        case .failure(let error) where error is KubeProxyProblem:
            return dropped()
        case .failure:
            // Refused or too large: from its row, as before.
            unreadable.insert(id)
        }
        publishNotes()
        scheduleFlush(now: false)
    }

    // MARK: The flush, the tick

    private func scheduleFlush(now: Bool) {
        if now {
            flushing?.cancel()
            flushing = nil
            return flush()
        }
        guard flushing == nil else { return }
        let interval = flushInterval
        flushing = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            self.flushing = nil
            self.flush()
        }
    }

    /// M2's GETs taken; what changed made into apps off the main thread.
    private func flush() {
        guard state != .idle else { return }
        let taken = refetch.take(now: clock()).filter { !queue.contains($0) && gets[$0] == nil }
        mostTaken = max(mostTaken, taken.count)
        queue += taken
        pump()
        if !refetch.isEmpty { scheduleFlush(now: false) }
        guard let box, !changes.isEmpty || !removed.isEmpty else { return settle() }
        let batch = Array(changes.values)
        let gone = Array(removed)
        changes = [:]
        removed = []
        // Handed over whole: the main thread keeps no copy while it is made.
        self.box = nil
        let now = clock()
        let generation = self.generation
        Task { [weak self] in
            let changed = await KubeBlocking.run { box.book.apply(batch, removed: gone, now: now) }
            guard let self, self.generation == generation else { return }
            self.box = box
            if changed { self.apps = box.book.ranked }
            let tally = box.book.apps.tally
            if tally != self.tally { self.tally = tally }
            self.settle()
            if changed { self.changed?() }
            if !self.changes.isEmpty || !self.removed.isEmpty { self.scheduleFlush(now: false) }
        }
    }

    /// Live once every workload kind's rows came (or couldn't): the owner
    /// told once, as after a flush.
    private func settle() {
        guard state == .loading, !reading.isReading else { return }
        state = .live
        changed?()
    }

    /// The book, moved to the thread that makes it and back.
    private final class Box: @unchecked Sendable {
        var book: KubeMarkedBook
        init(_ book: KubeMarkedBook) { self.book = book }
    }

    private func startTick() {
        ticking?.cancel()
        let interval = tickInterval
        let generation = self.generation
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.tick()
            }
        }
    }

    /// What is in progress asked again every 60 s, what is Degraded every
    /// 5 min; M3 and every M1 kind not followed read again every 5 min.
    func tick() {
        guard state != .idle, let client else { return }
        let now = clock()
        for (id, settled) in store?.settled ?? [:] {
            let every: TimeInterval
            switch settled.status {
            case .progressing, .unknown: every = KubeMarkedRefetch.inProgressEvery
            case .degraded: every = KubeMarkedRefetch.degradedEvery
            default: continue
            }
            guard now.timeIntervalSince(settled.at) >= every, isReadWorkload(id) else { continue }
            refetch.ask(id, .periodic)
        }
        if let at = rereadAt, now.timeIntervalSince(at) >= Self.rereadEvery {
            rereadAt = now
            store?.readAt = now
            reread(client: client)
        }
        if !refetch.isEmpty { scheduleFlush(now: false) }
    }

    /// M3, and every M1 kind with no follow — listed beside Applications,
    /// left without a watch, refused across the cluster, or whose follow
    /// failed — read again.
    private func reread(client: KubeClient) {
        for kind in rowKinds { listRows(kind, client: client) }
        for kind in workloads where follows[kind.fullName] == nil { listRows(kind, client: client) }
        publishNotes()
    }

    /// Whether a workload's row is one of a derived app's: only those are read again.
    private func isReadWorkload(_ id: KubeMarkedMember.ID) -> Bool {
        guard let kind = workloads.first(where: { KubeMarkedKind($0) == id.kind }) else { return false }
        return isRead(rows[kind.fullName]?[KubeRowID(namespace: id.namespace, name: id.name)]?.marks)
    }

    private func publishNotes() {
        var reading = self.reading
        reading.notes = store?.notes ?? [:]
        // The settle's progress: what it asked for, as many as are read.
        let checked = settleAsked.count { store?.settled[$0] != nil || unreadable.contains($0) }
        reading.checking = checked < settleAsked.count ? settleAsked.count : nil
        reading.checked = reading.checking == nil ? nil : checked
        if reading != self.reading { self.reading = reading }
        if readAt != store?.readAt, store?.done.isEmpty == false { readAt = store?.readAt }
    }

    // MARK: For the tests

    /// How many follows are open now.
    var openFollows: Int { follows.count }
    /// The most GETs in flight at once, and taken in one flush, since shown.
    private(set) var mostInFlight = 0
    private(set) var mostTaken = 0
    /// Every GET asked since made.
    private(set) var getsAsked = 0
    /// Every row change a follow brought since made.
    private(set) var rowsChanged = 0
    /// Whether M2 has nothing waiting, taken or in flight.
    var refetchIdle: Bool { refetch.isEmpty && queue.isEmpty && gets.isEmpty }
    /// Every change made into the apps: none waiting, none being made.
    var isMerged: Bool { box != nil && changes.isEmpty && removed.isEmpty }
    /// M2's GETs taken and not yet answered.
    var getsQueued: Int { queue.count + gets.count }
    /// M2's GETs taken in the minute before the session's clock.
    var takenLastMinute: Int { refetch.takenInLastMinute(now: clock()) }
}
