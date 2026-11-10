import Foundation

/// A paged read of whole objects of one kind (R2, gitops.md 3.1): `limit`
/// objects a page, each page at most `maxBytes` — past it the limit is
/// halved and the same `continue` asked again, down to one; one object
/// alone past it stops the kind there, said. An expired `continue` (410)
/// lists again from the start. At most `stopAfter` objects or `totalBytes`
/// read a kind, the rest said. Each page decoded off the main thread
/// through the allow-list (`KubeGitOpsWire`), its bytes dropped at once.
struct KubeGitOpsPaged: Sendable {
    var objects: [KubeGitOpsObject] = []
    /// Why it stopped short, said: "500 of 1,240 Applications summarised…".
    var cut: String?
    /// How many bytes were read.
    var bytes = 0
    /// How many pages were asked (the halving's asks included).
    var pages = 0
}

extension KubeClient {
    func pagedObjects(
        _ kind: KubeResourceKind, in namespace: String?, pageLimit: Int = KubeGitOpsSession.pageLimit, maxBytes: Int = KubeGitOpsSession.pageBytes,
        stopAfter: Int = KubeGitOpsSession.kindObjects, totalBytes: Int = KubeGitOpsSession.kindBytes, readAt: Date = Date()
    ) async throws -> KubeGitOpsPaged {
        let title = KubeKindCatalog.title(of: kind)
        var restarts = 0
        restart: while true {
            var paged = KubeGitOpsPaged()
            var token: String?
            var limit = max(1, pageLimit)
            // `while true`: a halved page asks the same `continue` again.
            while true {
                try Task.checkCancellation()
                // Never more than is left of `stopAfter`: a page past it is not asked.
                limit = max(1, min(limit, stopAfter - paged.objects.count))
                let path = KubePath.query(kind.path(namespace: namespace), [("limit", String(limit)), ("continue", token)])
                paged.pages += 1
                let data: Data
                do {
                    data = try await get(path, maxBytes: maxBytes)
                } catch is KubeBodyTooLarge {
                    guard limit > 1 else {
                        paged.cut = "stopped at an object over \(maxBytes >> 20) MB; \(paged.objects.count) summarised"
                        return paged
                    }
                    limit = max(1, limit / 2)
                    continue
                } catch let error as KubeAPIError where error.isGone && token != nil && restarts < 3 {
                    restarts += 1
                    continue restart
                }
                paged.bytes += data.count
                let decoded = await KubeBlocking.run { Result { try KubeGitOpsSummary.page(data, kind: kind, readAt: readAt) } }
                let page = try decoded.get()
                paged.objects += page.objects
                token = page.next
                if token != nil, paged.objects.count >= stopAfter || paged.bytes >= totalBytes {
                    let total = page.remaining.map { paged.objects.count + $0 }
                    let of = total.map { "\(paged.objects.count) of \($0.formatted())" } ?? "\(paged.objects.count) of more"
                    paged.cut = "\(of) \(title) summarised; the rest show their state only"
                    return paged
                }
                if token == nil { return paged }
            }
        }
    }
}

/// The page's GitOps section (`g`; gitops.md 2, 3), a window's as its page
/// is. While the section shows on a page on screen it follows, rows only,
/// the five kinds across the cluster (R1: Applications, Kustomizations,
/// HelmReleases, GitRepositories, OCIRepositories) and Argo CD's and
/// Flux's controllers in their namespaces (R1c); it summarises every
/// served kind by one paged, byte-bounded list of whole objects each,
/// decoded straight into the allow-list (R2); and it reads one object
/// again when its row's cells move, when a row that isn't healthy changes,
/// or every 60 s while it is in progress (R3, `KubeGitOpsRefetch`).
///
/// The summaries are kept five minutes, in memory, while the page shows
/// (`Store`): ↩ to a detail and back reads no list again. Leaving the
/// section ends every follow and cancels every GET (`hide`); the page
/// hiding drops the summaries too (`drop`), as do another context and a
/// credential failure. A kind refused across the cluster is read in the
/// namespaces it lives in — the context's `accessibleNamespaces`, else
/// `argocd` and those Applications were seen in, or `flux-system`, plus
/// the scope's — never by reading a ConfigMap; that is said. At most ten
/// watches, allotted: the five kinds, the three controllers, two more for
/// a refused kind's namespaces. Never a Secret, never a ConfigMap, never
/// a whole-object watch. Reads only.
@MainActor
final class KubeGitOpsSession: ObservableObject {
    enum State: Equatable {
        case idle, loading, live
    }

    // The bounds (gitops.md 7): constants, as KubeHealth's are.
    nonisolated static let pageLimit = 20
    nonisolated static let pageBytes = 16 << 20
    nonisolated static let kindObjects = 500
    nonisolated static let kindBytes = 64 << 20
    nonisolated static let listWidth = 2
    nonisolated static let getBytes = 4 << 20
    nonisolated static let inFlight = 4
    nonisolated static let storeLife: TimeInterval = 300
    /// The page's watches, allotted: the five kinds, the three
    /// controllers, then two for a refused kind's namespaces.
    nonisolated static let spareWatches = 2

    /// What was summarised of a context: kept five minutes while the page shows.
    struct Store {
        var context: String
        var objects: [KubeGitOpsObject.Key: KubeGitOpsObject] = [:]
        var readAt: Date
        /// The kinds summarised, and each one's cut or refusal, said.
        var cuts: [String: String] = [:]
        /// Kinds refused across the cluster: read in these namespaces.
        var fallback: [String: [String]] = [:]
        /// The kinds whose read finished: a store is fresh only for these —
        /// a section left mid-read reads the rest when shown again.
        var done: Set<String> = []
    }

    @Published private(set) var state: State = .idle
    /// Every summary, ranked (the ladder over all of them, at `now`).
    @Published private(set) var objects: [KubeGitOpsObject] = []
    /// What the section draws, for the scope shown.
    @Published private(set) var rows = KubeGitOpsSection.Rows()
    @Published private(set) var controllers: [KubeGitOpsControllers.Controller] = []
    /// The header's notes: a kind refused or cut, a namespace not watched.
    @Published private(set) var notes: [String] = []
    @Published private(set) var summarisedAt: Date?
    @Published private(set) var summarising = false
    /// The ladder's clock: moved by the tick, with no read.
    @Published private(set) var now = Date()
    /// Objects whose GET was refused or too large: said once each.
    @Published private(set) var unreadable: Set<KubeGitOpsObject.Key> = []

    private(set) var context: String?
    private(set) var scope: KubeScope = .all
    private var client: KubeClient?
    private var served: [KubeResourceKind] = []
    private var accessible: [String] = []
    private(set) var store: Store?

    /// How often what came in is folded in, and GETs taken.
    var flushInterval: Duration = .milliseconds(250)
    /// The ladder re-run with no read.
    var tickInterval: Duration = .seconds(30)
    /// What a test's clock says.
    var clock: () -> Date = { Date() }

    private var live: [String: KubeRows] = [:]
    private var listed: Set<String> = []
    private var follows: [String: Task<Void, Never>] = [:]
    private var controllerRows: [String: (rows: KubeRows, kind: String, namespace: String, tool: KubeGitOpsObject.Tool)] = [:]
    private var summarisingTask: Task<Void, Never>?
    /// The kinds the summarising task has yet to finish: kept when another
    /// read starts over it, so nothing it was reading is lost.
    private var pending: [KubeResourceKind] = []
    private var flushing: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var gets: [KubeGitOpsObject.Key: Task<Void, Never>] = [:]
    private var refetch = KubeGitOpsRefetch()
    private var queue: [KubeGitOpsObject.Key] = []
    private var followNotes: [String: String] = [:]
    private var argoNamespace = KubeGitOps.argoDefaultNamespace
    private var generation = 0
    /// The spare watches open now, for the allotment, and each refused
    /// kind's — given back when its follow ends.
    private var spareUsed = 0
    private var spareByKind: [String: Int] = [:]
    /// A refused kind's follow: the namespaces it was planned over.
    private var fallbackFollows: [String: [String]] = [:]

    var isReading: Bool { !follows.isEmpty || summarisingTask != nil || !gets.isEmpty }

    // MARK: Shown, hidden

    /// Shown, on `context` in `scope`: the follows started, the summaries
    /// read unless the store holds them fresh — again for another context
    /// or what it serves; another scope only filters again (a refused
    /// kind's namespaces aside).
    func show(context: String, scope: KubeScope, discovery: KubeDiscovery?, client: KubeClient?, accessible: [String] = []) {
        let kinds = KubeGitOpsSummary.kinds(discovery)
        if let store, store.context != context { drop() }
        let same = self.context == context && served.map(\.fullName) == kinds.map(\.fullName) && state != .idle && self.accessible == accessible
        if same {
            scopeChanged(scope)
            return
        }
        hide()
        guard let client else { return }
        self.context = context
        self.scope = scope
        self.client = client
        self.served = kinds
        self.accessible = accessible
        state = .loading
        now = clock()
        if let store, store.context == context, now.timeIntervalSince(store.readAt) <= Self.storeLife {
            summarisedAt = store.readAt
            // Fresh only for the kinds it finished: a section left mid-read reads the rest.
            let missing = kinds.filter { !store.done.contains($0.fullName) }
            if !missing.isEmpty { summarise(missing, client: client) }
        } else {
            store = Store(context: context, readAt: now)
            summarise(kinds, client: client)
        }
        argoNamespace = KubeGitOpsControllers.argoNamespace(applications: store?.objects.values.filter { $0.role == .application }.map(\.ref.namespace) ?? [])
        startFollows(client: client)
        startControllers(client: client)
        startTick()
        publish()
    }

    /// Another scope: filtered again — read again only for a kind refused
    /// across the cluster whose namespaces it changes.
    func scopeChanged(_ scope: KubeScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        guard state != .idle, let client, var store else { return publish() }
        var again: [KubeResourceKind] = []
        for (name, namespaces) in store.fallback.sorted(by: { $0.key < $1.key }) {
            guard let kind = served.first(where: { $0.fullName == name }) else { continue }
            if fallbackNamespaces(kind) != namespaces { again.append(kind) }
        }
        if !again.isEmpty {
            // Still refused across the cluster: read again where it lives
            // now, the kinds still being read kept (`summarise`).
            for kind in again { store.done.remove(kind.fullName) }
            self.store = store
            summarise(again, client: client)
        }
        for (name, namespaces) in fallbackFollows.sorted(by: { $0.key < $1.key }) {
            guard let kind = served.first(where: { $0.fullName == name }), fallbackNamespaces(kind) != namespaces else { continue }
            endFollow(name)
            live[name] = nil
            listed.remove(name)
            follow(kind, fallback: true, client: client)
        }
        publish()
    }

    /// Refresh (⌘R): every kind summarised again.
    func refresh() {
        guard let client, let context, state != .idle else { return }
        // The summaries held until each kind's new ones replace them (`took`):
        // no row loses its summary for the length of the refresh.
        store = Store(context: context, objects: store?.objects ?? [:], readAt: clock(), fallback: store?.fallback ?? [:])
        unreadable = []
        refetch.forget()
        summarise(served, client: client)
        publish()
    }

    /// The section left: every follow ends, every GET is cancelled; the summaries stay.
    func hide() {
        generation += 1
        for task in follows.values { task.cancel() }
        follows = [:]
        for task in gets.values { task.cancel() }
        gets = [:]
        summarisingTask?.cancel()
        summarisingTask = nil
        pending = []
        if summarising { summarising = false }
        flushing?.cancel()
        flushing = nil
        ticking?.cancel()
        ticking = nil
        queue = []
        refetch = KubeGitOpsRefetch()
        live = [:]
        listed = []
        controllerRows = [:]
        followNotes = [:]
        spareUsed = 0
        spareByKind = [:]
        fallbackFollows = [:]
        client = nil
        served = []
        context = nil
        if state != .idle { state = .idle }
        if !controllers.isEmpty { controllers = [] }
        if rows != KubeGitOpsSection.Rows() { rows = KubeGitOpsSection.Rows() }
        if !notes.isEmpty { notes = [] }
    }

    /// The page hidden, another context, a credential failure: the summaries go too.
    func drop() {
        hide()
        store = nil
        if !objects.isEmpty { objects = [] }
        summarisedAt = nil
        if !unreadable.isEmpty { unreadable = [] }
    }

    // MARK: R2: the summaries

    /// Where a kind refused across the cluster is read: the context's
    /// `accessibleNamespaces`, else Argo CD's or Flux's own and (Argo CD)
    /// those Applications were seen in — plus the scope's. No ConfigMap.
    func fallbackNamespaces(_ kind: KubeResourceKind) -> [String] {
        var names: [String]
        if !accessible.isEmpty {
            names = accessible
        } else if kind.group == "argoproj.io" {
            let seen = (store?.objects.values ?? [:].values).filter { $0.tool == .argo }.compactMap(\.ref.namespace)
            names = [KubeGitOps.argoDefaultNamespace] + seen.sorted()
        } else {
            names = [KubeGitOpsControllers.fluxNamespace]
        }
        names += scope.names ?? []
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private func summarise(_ kinds: [KubeResourceKind], client: KubeClient) {
        // A read under way: what it hasn't finished is read too, never dropped.
        var kinds = kinds
        if summarisingTask != nil {
            for kind in pending where !kinds.contains(where: { $0.fullName == kind.fullName }) { kinds.append(kind) }
        }
        summarisingTask?.cancel()
        pending = kinds
        let generation = self.generation
        let readAt = clock()
        summarising = true
        // Where each kind is read, decided here: a kind already refused across
        // the cluster in its namespaces, else across it first.
        let plans: [(kind: KubeResourceKind, refused: Bool, namespaces: [String])] = kinds.map { kind in
            (kind, store?.fallback[kind.fullName] != nil, fallbackNamespaces(kind))
        }
        summarisingTask = Task { [weak self] in
            await withTaskGroup(of: (KubeResourceKind, Read).self) { group in
                var next = 0
                while next < min(Self.listWidth, plans.count) {
                    let plan = plans[next]
                    next += 1
                    group.addTask { (plan.kind, await Self.read(plan.kind, client: client, refused: plan.refused, namespaces: plan.namespaces, readAt: readAt)) }
                }
                while let (kind, read) = await group.next() {
                    if let self, self.generation == generation, !Task.isCancelled { self.took(kind, read) }
                    guard next < plans.count, !Task.isCancelled else { continue }
                    let plan = plans[next]
                    next += 1
                    group.addTask { (plan.kind, await Self.read(plan.kind, client: client, refused: plan.refused, namespaces: plan.namespaces, readAt: readAt)) }
                }
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.summarisingTask = nil
            self.pending = []
            self.summarising = false
            self.summarisedAt = self.store?.readAt
            if self.state == .loading { self.state = .live }
            self.publish()
        }
    }

    /// A kind's read: across the cluster, else — refused — namespace by namespace.
    private enum Read: Sendable {
        case across(KubeGitOpsPaged)
        case fallback(KubeGitOpsPaged, namespaces: [String], refused: [String])
        case failed(Error)
    }

    private nonisolated static func read(
        _ kind: KubeResourceKind, client: KubeClient, refused: Bool, namespaces: [String], readAt: Date
    ) async -> Read {
        if !refused {
            do {
                return .across(try await client.pagedObjects(kind, in: nil, readAt: readAt))
            } catch let error as KubeAPIError where error.isForbidden {
                // Refused across the cluster: where it lives.
            } catch {
                return .failed(error)
            }
        }
        var whole = KubeGitOpsPaged()
        var forbidden: [String] = []
        for namespace in namespaces {
            guard !Task.isCancelled else { break }
            let left = kindObjects - whole.objects.count
            guard left > 0 else { break }
            do {
                let page = try await client.pagedObjects(kind, in: namespace, stopAfter: left, totalBytes: max(1, kindBytes - whole.bytes), readAt: readAt)
                whole.objects += page.objects
                whole.bytes += page.bytes
                whole.pages += page.pages
                if let cut = page.cut { whole.cut = cut }
            } catch let error as KubeAPIError where error.isForbidden {
                forbidden.append(namespace)
            } catch {
                return .failed(error)
            }
        }
        return .fallback(whole, namespaces: namespaces, refused: forbidden)
    }

    private func took(_ kind: KubeResourceKind, _ read: Read) {
        pending.removeAll { $0.fullName == kind.fullName }
        guard var store else { return }
        let title = KubeKindCatalog.title(of: kind)
        let paged: KubeGitOpsPaged
        switch read {
        case .across(let result):
            paged = result
            store.cuts[kind.fullName] = result.cut.map { "\(title): \($0)" }
        case .fallback(let result, let namespaces, let refused):
            paged = result
            store.fallback[kind.fullName] = namespaces
            let readIn = namespaces.filter { !refused.contains($0) }
            var said = "\(title): forbidden across the cluster; read in \(Self.joined(readIn.isEmpty ? ["none"] : readIn))"
            if !refused.isEmpty { said += "; refused in \(Self.joined(refused))" }
            if let cut = result.cut { said += "; \(cut)" }
            store.cuts[kind.fullName] = said
        case .failed(let error):
            let reason = KubernetesModel.said(error)
            if error is KubeProxyProblem {
                drop()
                notes = ["\(title): \(reason)"]
                return
            }
            store.cuts[kind.fullName] = "\(title): not summarised — \(reason)"
            self.store = store
            publish()
            return
        }
        store.done.insert(kind.fullName)
        // This kind's summaries replaced; each keeps the cells it was compared with.
        let rows = live[kind.fullName]
        for (key, object) in store.objects where object.resource == kind.fullName { store.objects[key] = nil }
        for var object in paged.objects {
            if let row = rows?[object.ref], let columns = rows?.columns { object.cells = KubeGitOpsSection.cellsKey(row, columns: columns) }
            store.objects[object.key] = object
        }
        // Where Applications live: where the rail lists them too (gitops.md 4.4).
        if KubeGitOps.isArgoApplication(kind) {
            KubeGitOpsMatchCache.shared.saw(applicationsIn: Set(paged.objects.compactMap(\.ref.namespace)), context: store.context)
        }
        self.store = store
        rank()
        publish()
    }

    private static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: R1: the rows

    private func startFollows(client: KubeClient) {
        for kind in served where KubeGitOpsSummary.followed.contains(.init(group: kind.group, resource: kind.resource)) && KubeKindCatalog.isOffered(kind) {
            follow(kind, fallback: store?.fallback[kind.fullName] != nil, client: client)
        }
    }

    /// One kind's rows across the cluster (`includeObject=Metadata`, as
    /// every list across the cluster); refused, in its namespaces — as many
    /// as the spare watches allow, Applications first.
    private func follow(_ kind: KubeResourceKind, fallback: Bool, client: KubeClient) {
        let generation = self.generation
        var scope = KubeScope.all
        var cap = KubeScope.watchCap
        let name = kind.fullName
        if fallback {
            let namespaces = fallbackNamespaces(kind)
            fallbackFollows[name] = namespaces
            let allowed = max(0, Self.spareWatches - spareUsed)
            let watched = Array(namespaces.prefix(allowed))
            let left = namespaces.dropFirst(allowed)
            let title = KubeKindCatalog.title(of: kind)
            followNotes[name] = left.isEmpty ? nil : "\(title) in \(Self.joined(Array(left))): not watched; Refresh reads them"
            guard !watched.isEmpty else { return }
            spareUsed += watched.count
            spareByKind[name, default: 0] += watched.count
            scope = .of(watched)
            cap = watched.count
        }
        follows[name] = Task { [weak self] in
            do {
                for try await update in client.follow(kind, in: scope, options: KubeListOptions(), cap: cap) {
                    guard let self, self.generation == generation else { return }
                    self.received(update, kind: kind)
                }
            } catch is CancellationError {
            } catch let error as KubeAPIError where error.isForbidden && !fallback {
                guard let self, self.generation == generation else { return }
                self.follows[name] = nil
                self.follow(kind, fallback: true, client: client)
            } catch {
                guard let self, self.generation == generation else { return }
                self.endFollow(name)
                self.followNotes[name] = "\(KubeKindCatalog.title(of: kind)): not followed — \(KubernetesModel.said(error))"
                if error is KubeProxyProblem { self.drop() }
                self.scheduleFlush(now: true)
            }
        }
    }

    /// A kind's follow ended: its spare watches given back.
    private func endFollow(_ name: String) {
        follows[name]?.cancel()
        follows[name] = nil
        spareUsed = max(0, spareUsed - (spareByKind.removeValue(forKey: name) ?? 0))
    }

    private func received(_ update: KubeFollowUpdate, kind: KubeResourceKind) {
        let name = kind.fullName
        switch update {
        case .retrying: return
        case .unlisted(let namespace, _):
            followNotes[name] = "\(KubeKindCatalog.title(of: kind)) in \(namespace): forbidden"
            return
        case .listed, .changed, .bookmark: break
        }
        var rows = live[name] ?? KubeRows()
        let before = rows
        rows.apply(update)
        live[name] = rows
        switch update {
        case .listed:
            listed.insert(name)
            // Compared with the summaries: a moved cell is read again; an
            // unread baseline is taken from the row.
            for row in rows.sorted { note(row, kind: kind, columns: rows.columns, added: false, listing: true) }
            if name == "applications.argoproj.io" { followArgoControllers(rows) }
        case .changed(let changes, _):
            for change in changes {
                switch change {
                case .added(let row): note(row, kind: kind, columns: rows.columns, added: before[row.id] == nil, listing: false)
                case .modified(let row): note(row, kind: kind, columns: rows.columns, added: false, listing: false)
                case .deleted: break
                }
            }
        default: break
        }
        scheduleFlush(now: state == .loading)
    }

    /// A row seen: its summary's baseline set if it has none; else asked again by R3's rules.
    private func note(_ row: KubeRow, kind: KubeResourceKind, columns: [KubeColumn], added: Bool, listing: Bool) {
        let key = KubeGitOpsObject.Key(kind: kind.kind, namespace: row.id.namespace, name: row.id.name)
        let summary = store?.objects[key]
        if let summary, summary.cells.isEmpty {
            store?.objects[key]?.cells = KubeGitOpsSection.cellsKey(row, columns: columns)
            return
        }
        // A row listed with no summary waits for the summaries (or was cut): no GET.
        if summary == nil, listing || summarising { return }
        if listing, summary != nil {
            if summary!.cells != KubeGitOpsSection.cellsKey(row, columns: columns) { refetch.ask(key, summary!.state.isProblem ? .problem : .other) }
            return
        }
        if let priority = KubeGitOpsRefetch.reason(added: added, resource: kind.fullName, row: row, columns: columns, summary: summary) {
            refetch.ask(key, priority)
        }
    }

    // MARK: R1c: the controllers

    private func startControllers(client: KubeClient) {
        let tools = KubeGitOpsSummary.tools(KubeDiscovery(kinds: served))
        if tools.argo > 0 { followControllers(namespace: argoNamespace, tool: .argo, statefulSets: true, client: client) }
        if tools.flux > 0 { followControllers(namespace: KubeGitOpsControllers.fluxNamespace, tool: .flux, statefulSets: false, client: client) }
    }

    /// Argo CD's namespace, once Applications are listed: its controllers
    /// followed there when it isn't the one they were.
    private func followArgoControllers(_ applications: KubeRows) {
        let namespace = KubeGitOpsControllers.argoNamespace(applications: applications.sorted.map(\.id.namespace))
        guard namespace != argoNamespace, let client else { return }
        for key in controllerRows.keys where key.hasPrefix("argo/") { controllerRows[key] = nil }
        for name in ["argo/deployments", "argo/statefulsets"] {
            follows[name]?.cancel()
            follows[name] = nil
        }
        argoNamespace = namespace
        followControllers(namespace: namespace, tool: .argo, statefulSets: true, client: client)
    }

    /// Deployments (and StatefulSets) in one namespace: rows only, `includeObject=None`.
    private func followControllers(namespace: String, tool: KubeGitOpsObject.Tool, statefulSets: Bool, client: KubeClient) {
        let kinds: [(String, KubeResourceKind)] =
            [("deployments", Self.deployments)] + (statefulSets ? [("statefulsets", Self.statefulSets)] : [])
        let generation = self.generation
        for (word, kind) in kinds {
            let name = "\(tool.rawValue)/\(word)"
            follows[name] = Task { [weak self] in
                do {
                    for try await update in client.follow(kind, in: .namespace(namespace), options: KubeListOptions()) {
                        guard let self, self.generation == generation else { return }
                        var rows = self.controllerRows[name]?.rows ?? KubeRows()
                        rows.apply(update)
                        self.controllerRows[name] = (rows, word, namespace, tool)
                        self.scheduleFlush(now: false)
                    }
                } catch {
                    // A controllers' namespace not readable: no banner, nothing else lost.
                }
            }
        }
    }

    nonisolated static let deployments = KubeResourceKind(
        group: "apps", version: "v1", resource: "deployments", kind: "Deployment", singular: "deployment", namespaced: true, verbs: ["get", "list", "watch"])
    nonisolated static let statefulSets = KubeResourceKind(
        group: "apps", version: "v1", resource: "statefulsets", kind: "StatefulSet", singular: "statefulset", namespaced: true,
        verbs: ["get", "list", "watch"])

    // MARK: R3: one object again

    private func scheduleFlush(now: Bool) {
        if now {
            flushing?.cancel()
            flushing = nil
            flush()
            return
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

    private func flush() {
        var found: [KubeGitOpsControllers.Controller] = []
        for name in controllerRows.keys.sorted() {
            guard let entry = controllerRows[name] else { continue }
            found += KubeGitOpsControllers.controllers(entry.rows, kind: entry.kind, namespace: entry.namespace, tool: entry.tool)
        }
        let staleBefore = KubeGitOpsControllers.stale(controllers)
        if found != controllers { controllers = found }
        if state == .loading, !listed.isEmpty || summarisingTask == nil { state = .live }
        // At most 20 a flush; the rest wait for the next.
        queue += refetch.take(now: clock()).filter { !queue.contains($0) && gets[$0] == nil }
        pump()
        if KubeGitOpsControllers.stale(found) != staleBefore { rank() }
        publish()
        if !refetch.isEmpty, flushing == nil { scheduleFlush(now: false) }
    }

    /// At most four GETs in flight.
    private func pump() {
        guard let client else { return }
        while gets.count < Self.inFlight, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let kind = served.first(where: { $0.kind == key.kind }) else { continue }
            let generation = self.generation
            let readAt = clock()
            let path = kind.path(namespace: key.namespace, name: key.name)
            gets[key] = Task { [weak self] in
                let result: Result<KubeGitOpsObject?, Error>
                do {
                    let data = try await client.get(path, maxBytes: Self.getBytes)
                    result = await KubeBlocking.run { Result { try KubeGitOpsSummary.object(data, readAt: readAt) } }
                } catch {
                    result = .failure(error)
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.gets[key] = nil
                self.got(key, kind: kind, result)
                self.pump()
            }
        }
    }

    private func got(_ key: KubeGitOpsObject.Key, kind: KubeResourceKind, _ result: Result<KubeGitOpsObject?, Error>) {
        switch result {
        case .success(var object?):
            if let rows = live[kind.fullName], let row = rows[object.ref] { object.cells = KubeGitOpsSection.cellsKey(row, columns: rows.columns) }
            store?.objects[key] = object
            unreadable.remove(key)
        case .success(nil):
            break
        case .failure(let error as KubeAPIError) where error.status == 404:
            store?.objects[key] = nil
        case .failure(let error) where error is KubeBodyTooLarge || (error as? KubeAPIError)?.isForbidden == true:
            unreadable.insert(key)
        case .failure:
            break
        }
        rank()
        publish()
    }

    // MARK: The tick

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

    /// The ladder again at the new time, with no read; what is in progress asked again every 60 s.
    func tick() {
        now = clock()
        for object in store?.objects.values ?? [:].values where KubeGitOpsRefetch.inProgress(object, now: now) {
            refetch.ask(object.key, .periodic)
        }
        rank()
        publish()
        if !refetch.isEmpty { scheduleFlush(now: false) }
    }

    // MARK: What is drawn

    private func rank() {
        let ranked = KubeGitOpsSummary.ranked(Array(store?.objects.values ?? [:].values), now: now, stale: KubeGitOpsControllers.stale(controllers))
        if ranked != objects { objects = ranked }
    }

    private func publish() {
        var said = (store?.cuts ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        said += followNotes.sorted { $0.key < $1.key }.map(\.value)
        if said != notes { notes = said }
        guard state != .idle else { return }
        let new = KubeGitOpsSection.rows(summaries: objects, live: live, listed: listed, scope: scope, now: now, unreadable: unreadable)
        if new != rows { rows = new }
    }

    // MARK: The detail's peers

    /// The summaries held of `context`, by key — the store's own
    /// dictionary, nothing rebuilt: what the detail's GitOps header and Ask
    /// Why take a chain's states from (the ladder evaluates each again) —
    /// nothing read for them (gitops.md 2.9). Empty when the page holds
    /// none of it.
    func peers(context: String) -> KubeGitOpsLadder.Peers {
        guard let store, store.context == context else { return [:] }
        return store.objects
    }

    // MARK: For the tests

    /// How many follows are open now (the kinds', the controllers').
    var openFollows: Int { follows.count }
}
