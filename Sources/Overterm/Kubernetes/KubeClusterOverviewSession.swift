import Foundation

/// The Overview section's reading (`1`; stage 2d), a window's as its page
/// is: while the section shows on a page on screen, in the context and
/// namespace shown, it follows — rows only, as the lists do — the pods of
/// each phase (`fieldSelector=status.phase=…`, so a count is the server's
/// phase, not a guess from a Status cell), the Deployments, StatefulSets,
/// DaemonSets and Jobs (with their metadata, for the Applications'
/// labels), the nodes, and the Warning events (`type=Warning`). Hidden —
/// another section, the page or its window off screen — every follow ends
/// and what was read goes. A part that can't be read (RBAC refuses
/// events, a kind not served) says so; the rest stands. Reads only.
@MainActor
final class KubeClusterOverviewSession: ObservableObject {
    /// What the section follows, each a list kept live.
    enum Part: Hashable, Sendable {
        case pods(String)
        case workload(String)
        case nodes
        case warnings

        var title: String {
            switch self {
            case .pods(let phase): "\(phase) pods"
            case .workload(let name): KubeClusterOverviewSession.workloadTitles[name] ?? name
            case .nodes: "Nodes"
            case .warnings: "Warning events"
            }
        }
    }

    enum State: Equatable {
        case idle, loading, live
    }

    nonisolated static let workloadKinds = ["deployments.apps", "statefulsets.apps", "daemonsets.apps", "jobs.batch"]
    nonisolated static let workloadTitles = [
        "deployments.apps": "Deployments", "statefulsets.apps": "StatefulSets", "daemonsets.apps": "DaemonSets", "jobs.batch": "Jobs",
    ]

    @Published private(set) var overview = KubeClusterOverview()
    @Published private(set) var state: State = .idle
    /// The parts that couldn't be read, and why.
    @Published private(set) var problems: [Part: String] = [:]
    /// Where it reads: the context and namespace, while shown.
    private(set) var context: String?
    private(set) var scope: KubeScope?

    /// How often what came in is folded into the overview.
    var flushInterval: Duration = .milliseconds(250)
    /// Told, once a show, when a workload's row carries one of Argo CD's
    /// marks (`KubeRow.argoMarked`): what tells the context's GitOps
    /// section that there are marks to read (gitops.md 14.2.1).
    var sawMarks: ((String) -> Void)?
    private var marksTold = false

    private var follows: [Part: Task<Void, Never>] = [:]
    private var rows: [Part: KubeRows] = [:]
    private var kinds: [Part: KubeResourceKind] = [:]
    private var anchors: [KubeRowID: KubeAge.Anchor] = [:]
    private var flushing: Task<Void, Never>?
    private var generation = 0
    /// What it follows now, to follow again only when that changes.
    private struct Key: Equatable {
        var context: String
        var scope: KubeScope
        var parts: [String]
    }
    private var shown: Key?

    var isReading: Bool { !follows.isEmpty }

    /// Shown, on `context` in `scope`: everything followed there — again
    /// only when the context, the namespace or what it serves changed.
    func show(context: String, scope: KubeScope, discovery: KubeDiscovery?, client: KubeClient?) {
        let parts = Self.parts(discovery)
        let key = Key(context: context, scope: scope, parts: parts.map(\.1.fullName) + parts.map(\.0.title))
        if key == shown { return }
        hide()
        guard let client else { return }
        shown = key
        self.context = context
        self.scope = scope
        state = .loading
        let generation = self.generation
        let cap = Self.watchCap(parts.map(\.1))
        for (part, kind) in parts {
            kinds[part] = kind
            follows[part] = follow(part, kind, scope: scope, cap: cap, client: client, generation: generation)
        }
    }

    /// How many namespaces each namespaced part may watch one by one: the
    /// page's budget (`KubeScope.watchCap`) shared by the parts, so ten
    /// namespaces are never ten watches a part. Past it a part is one
    /// watch across the cluster kept to the namespaces — refused, said,
    /// where listing across the cluster isn't allowed. Pure.
    nonisolated static func watchCap(_ kinds: [KubeResourceKind]) -> Int {
        let namespaced = kinds.filter(\.namespaced).count
        return max(1, KubeScope.watchCap / max(1, namespaced))
    }

    /// Off screen: nothing followed, nothing kept.
    func hide() {
        generation += 1
        for task in follows.values { task.cancel() }
        follows = [:]
        flushing?.cancel()
        flushing = nil
        rows = [:]
        kinds = [:]
        anchors = [:]
        marksTold = false
        context = nil
        scope = nil
        shown = nil
        if state != .idle { state = .idle }
        if !problems.isEmpty { problems = [:] }
        if overview != KubeClusterOverview() { overview = KubeClusterOverview() }
    }

    /// What it follows of a cluster that serves `discovery`: pods and
    /// nodes always (every cluster has them), the workloads and events
    /// that are served as lists kept live.
    nonisolated static func parts(_ discovery: KubeDiscovery?) -> [(Part, KubeResourceKind)] {
        var parts: [(Part, KubeResourceKind)] = KubeClusterOverview.phases.map { (.pods($0), .pods) }
        guard let discovery else { return parts }
        func served(_ name: String) -> KubeResourceKind? { discovery.kinds.first { $0.fullName == name && KubeKindCatalog.isOffered($0) } }
        for name in workloadKinds { if let kind = served(name) { parts.append((.workload(name), kind)) } }
        if let nodes = served("nodes") { parts.append((.nodes, nodes)) }
        if let events = served("events") { parts.append((.warnings, events)) }
        return parts
    }

    /// What a part asks the server for.
    nonisolated static func options(_ part: Part) -> KubeListOptions {
        switch part {
        case .pods(let phase): KubeListOptions(fieldSelector: "status.phase=\(phase)")
        case .workload: KubeListOptions(metadata: true)
        case .nodes: KubeListOptions()
        case .warnings: KubeListOptions(fieldSelector: "type=Warning")
        }
    }

    private func follow(_ part: Part, _ kind: KubeResourceKind, scope: KubeScope, cap: Int, client: KubeClient, generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await update in client.follow(kind, in: scope, options: Self.options(part), cap: cap) {
                    guard let self, self.generation == generation else { return }
                    self.received(update, for: part)
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.problems[part] = KubernetesModel.said(error)
                self.rows[part] = nil
                self.follows[part] = nil
                self.scheduleFlush(now: true)
            }
        }
    }

    private func received(_ update: KubeFollowUpdate, for part: Part) {
        // A namespace of several that refuses is left out of the counts.
        switch update {
        case .retrying, .unlisted: return
        case .listed, .changed, .bookmark: break
        }
        var rows = self.rows[part] ?? KubeRows()
        rows.apply(update)
        self.rows[part] = rows
        if case .workload = part, !marksTold, let context, Self.marked(update) {
            marksTold = true
            sawMarks?(context)
        }
        if part == .warnings {
            let now = Date()
            switch update {
            case .listed(let table):
                for row in table.rows { anchors[row.id] = Self.lastSeen(row, columns: table.columns, received: now) }
            case .changed(let changes, _):
                for change in changes {
                    switch change {
                    case .added(let row), .modified(let row): anchors[row.id] = Self.lastSeen(row, columns: rows.columns, received: now)
                    case .deleted(let id): anchors[id] = nil
                    }
                }
            case .bookmark, .retrying, .unlisted: break
            }
        }
        if problems[part] != nil { problems[part] = nil }
        // The first lists at once (once every part has one); changes in batches.
        scheduleFlush(now: state == .loading && self.rows.count == follows.count)
    }

    /// Whether an update's rows carry one of Argo CD's marks.
    nonisolated static func marked(_ update: KubeFollowUpdate) -> Bool {
        switch update {
        case .listed(let table): return table.rows.contains(where: \.argoMarked)
        case .changed(let changes, _):
            return changes.contains { change in
                switch change {
                case .added(let row), .modified(let row): row.argoMarked
                case .deleted: false
                }
            }
        case .bookmark, .retrying, .unlisted: return false
        }
    }

    /// An event's Last Seen, counted on from when it came.
    nonisolated static func lastSeen(_ row: KubeRow, columns: [KubeColumn], received: Date) -> KubeAge.Anchor {
        KubeAge.Anchor(created: nil, said: row.cell("Last Seen", in: columns).flatMap { KubeAge.seconds($0.text) }, received: received)
    }

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
        var input = KubeClusterOverview.Input()
        for (part, rows) in rows {
            switch part {
            case .pods(let phase): input.pods[phase] = rows
            case .workload: if let kind = kinds[part] { input.workloads.append((kind, rows)) }
            case .nodes: input.nodes = rows
            case .warnings: input.warnings = rows
            }
        }
        input.workloads.sort { a, b in
            (Self.workloadKinds.firstIndex(of: a.kind.fullName) ?? 99) < (Self.workloadKinds.firstIndex(of: b.kind.fullName) ?? 99)
        }
        input.anchors = anchors
        let new = KubeClusterOverview.of(input)
        if new != overview { overview = new }
        if state == .loading, rows.count + problems.count >= kinds.count { state = .live }
    }
}
