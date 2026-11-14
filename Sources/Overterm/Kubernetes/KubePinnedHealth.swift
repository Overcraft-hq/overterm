import Foundation

/// The health of the pinned contexts (`kubernetes.pinnedContexts`;
/// docs/design/kubernetes/analysis.md, 2.1 and decision 17): one card a
/// context — its pods failing, its workloads and nodes not ready — on the
/// Overview, beside the one context the page shows. Made from Table rows,
/// as the lists are. Pure.
struct KubePinnedHealth: Equatable, Sendable {
    /// What one context's rows say.
    struct Summary: Equatable, Sendable {
        var pods = 0
        /// Failing pods, `namespace/name` and why, the first `shown`.
        var failing: [String] = []
        var failingCount = 0
        var workloads = 0
        var notReady: [String] = []
        var notReadyCount = 0
        var nodes = 0
        var notReadyNodes: [String] = []
        /// The lists the server cut, said.
        var cut: [String] = []
        /// The lists that couldn't be read, and why.
        var unread: [String] = []

        var problems: Int { failingCount + notReadyCount + notReadyNodes.count }
        var isFine: Bool { problems == 0 }
    }

    enum State: Equatable, Sendable {
        case waiting
        case read(Summary, at: Date)
        /// Not read: why (the context gone, a credential, no slot).
        case notRead(String)
    }

    struct Card: Equatable, Sendable, Identifiable {
        var context: String
        var displayName: String
        var production: Bool
        /// Where its rows come from: its namespace, or every one.
        var scope: KubeScope
        var state: State

        var id: String { context }
        var place: String {
            switch scope {
            case .all: "all namespaces"
            case .namespace(let name): name
            case .namespaces: scope.title
            }
        }
    }

    static let shown = 5
    /// Each list's bound: one page, never more.
    static let limit = 500

    /// The rows of one context: pods (`KubePodSummary`: failing, or a
    /// Failed or Unknown phase's Status), Deployments, StatefulSets and
    /// DaemonSets (`KubeWorkloadState`), nodes (Ready first in Status).
    static func summary(pods: KubeTable?, workloads: [(kind: KubeResourceKind, table: KubeTable)], nodes: KubeTable?) -> Summary {
        var summary = Summary()
        if let pods {
            summary.pods = pods.rows.count
            let failing = pods.rows.compactMap { KubePodSummary(row: $0, columns: pods.columns) }
                .filter { $0.isFailing || ["Failed", "Unknown"].contains($0.status) }
                .sorted { $0.id < $1.id }
            summary.failingCount = failing.count
            summary.failing = failing.prefix(shown).map { "pod/\($0.id.description) \($0.exitReason ?? $0.status)" }
            if pods.continueToken != nil { summary.cut.append("pods") }
        }
        var notReady: [String] = []
        for (kind, table) in workloads {
            summary.workloads += table.rows.count
            for row in table.rows where KubeWorkloadState.ready(row, columns: table.columns, kind: kind.resource) == false {
                notReady.append("\(kind.kind.lowercased())/\(row.id.description)")
            }
            if table.continueToken != nil { summary.cut.append(kind.resource) }
        }
        notReady.sort()
        summary.notReadyCount = notReady.count
        summary.notReady = Array(notReady.prefix(shown))
        if let nodes {
            summary.nodes = nodes.rows.count
            summary.notReadyNodes = nodes.rows.filter { row in
                (row.cell("Status", in: nodes.columns)?.text ?? "").split(separator: ",").first.map(String.init) != "Ready"
            }
            .map(\.id.name).sorted()
            if nodes.continueToken != nil { summary.cut.append("nodes") }
        }
        return summary
    }

    /// The kinds a card reads: as the context is known to serve them, else
    /// their stable versions.
    static func kinds(_ discovery: KubeDiscovery?) -> (workloads: [KubeResourceKind], nodes: KubeResourceKind) {
        func kind(_ group: String, _ resource: String, _ name: String, namespaced: Bool) -> KubeResourceKind {
            discovery?.kinds.first { $0.group == group && $0.resource == resource }
                ?? KubeResourceKind(
                    group: group, version: "v1", resource: resource, kind: name, singular: name.lowercased(), namespaced: namespaced, verbs: ["get", "list", "watch"])
        }
        return (
            [
                kind("apps", "deployments", "Deployment", namespaced: true), kind("apps", "statefulsets", "StatefulSet", namespaced: true),
                kind("apps", "daemonsets", "DaemonSet", namespaced: true),
            ],
            kind("", "nodes", "Node", namespaced: false)
        )
    }

    /// One list's GET: one page of Table rows — the metadata across every
    /// namespace, where a row's namespace is.
    static func path(_ kind: KubeResourceKind, scope: KubeScope) -> String {
        KubePath.query(
            kind.path(namespace: scope.namespace(for: kind)),
            [("limit", String(limit)), ("includeObject", KubeClient.includeObject(kind, scope))])
    }
}

/// The pinned contexts' cards, the app's (one session, whichever windows'
/// Overviews show it), read only while an Overview shows on a page on
/// screen: each context's lists — one page of rows each, never a watch —
/// through its proxy in a spare slot (`KubernetesModel.spareClient`: never
/// a browser sign-in, and only a slot that is free as it stands — no proxy
/// is closed for a card, so no kubectl is started again and again; a card
/// that finds none says so), one context after another, again every
/// `interval`. Hidden everywhere, nothing is read and nothing kept.
@MainActor
final class KubePinnedHealthSession: ObservableObject {
    @Published private(set) var cards: [KubePinnedHealth.Card] = []

    /// How often the cards are read again while shown.
    var interval: Duration = .seconds(30)

    private var task: Task<Void, Never>?
    private var shown: [String] = []
    /// Who shows the cards (each window's page): read while anyone does.
    private var viewers: Set<ObjectIdentifier> = []

    var isReading: Bool { task != nil }

    static let noSlot = "Not read: no free connection — a pinned context is read only in a slot nothing else needs (Settings ▸ Kubernetes ▸ Contexts connected at once)."
    static let off = "Not read: Kubernetes is off."
    static let gone = "Not in the kubeconfig."

    /// Shown by `viewer`: the pinned contexts' cards, read now and every
    /// `interval`. `target` gives each its client and scope; nil while
    /// Kubernetes is off.
    func show(
        by viewer: AnyObject? = nil, pinned: [String], contexts: KubeContextList, discovery: @escaping @MainActor (String) -> KubeDiscovery?,
        target: @escaping @MainActor (KubeContext) -> (client: KubeClient, scope: KubeScope)?
    ) {
        viewers.insert(ObjectIdentifier(viewer ?? self))
        // Again only when what is pinned, or what those names are, changed.
        let key = pinned.map { name in "\(name)\u{0}\(contexts.context(named: name).map { "\($0.server ?? "")\u{0}\($0.user)" } ?? "-")" }
        guard key != shown || task == nil else { return }
        stop()
        guard !pinned.isEmpty else { return }
        shown = key
        cards = pinned.map { name in
            guard let context = contexts.context(named: name) else {
                return KubePinnedHealth.Card(context: name, displayName: name, production: false, scope: .all, state: .notRead(Self.gone))
            }
            let scope = target(context)?.scope ?? .all
            return KubePinnedHealth.Card(context: name, displayName: context.displayName, production: context.isProduction, scope: scope, state: .waiting)
        }
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                for name in pinned {
                    guard !Task.isCancelled else { return }
                    guard let context = contexts.context(named: name) else { continue }
                    guard let (client, scope) = target(context) else {
                        guard let self else { return }
                        if let index = self.cards.firstIndex(where: { $0.context == name }) { self.cards[index].state = .notRead(Self.off) }
                        continue
                    }
                    let state = await Self.read(client: client, scope: scope, discovery: discovery(name))
                    guard !Task.isCancelled, let self else { return }
                    if let index = self.cards.firstIndex(where: { $0.context == name }) {
                        self.cards[index].scope = scope
                        self.cards[index].state = state
                    }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Off `viewer`'s screen; once nobody shows them, nothing read, nothing
    /// kept. No viewer: hidden everywhere.
    func hide(by viewer: AnyObject? = nil) {
        if let viewer {
            viewers.remove(ObjectIdentifier(viewer))
            guard viewers.isEmpty else { return }
        }
        viewers = []
        stop()
    }

    private func stop() {
        task?.cancel()
        task = nil
        shown = []
        if !cards.isEmpty { cards = [] }
    }

    /// One context's rows, read: pods, the workloads, the nodes. A list
    /// refused is said on the card and the rest stands; the first one that
    /// can't be read at all (no slot, a credential) is the card's.
    private static func read(client: KubeClient, scope: KubeScope, discovery: KubeDiscovery?) async -> KubePinnedHealth.State {
        let kinds = KubePinnedHealth.kinds(discovery)
        var unread: [String] = []
        func table(_ kind: KubeResourceKind, _ scope: KubeScope) async throws -> KubeTable? {
            do {
                // Several namespaces: a page each (past the cap, across the
                // cluster), kept to them.
                var whole: KubeTable?
                for namespace in scope.reads(for: kind) {
                    let one: KubeScope = namespace.map { .namespace($0) } ?? .all
                    let body = try await client.get(KubePinnedHealth.path(kind, scope: one), accept: KubeClient.tableAccept).body
                    var read = try await KubeBlocking.run { Swift.Result { try KubeTableReader.read(body, namespace: namespace, kind: kind) } }.get()
                    read.rows = read.rows.filter { scope.includes($0.id.namespace) }
                    if whole == nil { whole = read } else { whole!.rows += read.rows }
                }
                return whole
            } catch let error as KubeAPIError {
                unread.append("\(kind.resource): \(KubernetesModel.said(error))")
                return nil
            }
        }
        do {
            let pods = try await table(.pods, scope)
            var workloads: [(kind: KubeResourceKind, table: KubeTable)] = []
            for kind in kinds.workloads {
                if let read = try await table(kind, scope) { workloads.append((kind, read)) }
            }
            let nodes = try await table(kinds.nodes, .all)
            var summary = KubePinnedHealth.summary(pods: pods, workloads: workloads, nodes: nodes)
            summary.unread = unread
            if pods == nil, workloads.isEmpty, nodes == nil { return .notRead(unread.first ?? "Nothing could be listed.") }
            return .read(summary, at: Date())
        } catch is CancellationError {
            return .waiting
        } catch KubeProxyProblem.noSlot {
            return .notRead(noSlot)
        } catch {
            return .notRead(KubernetesModel.said(error))
        }
    }
}
