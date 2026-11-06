import Foundation

/// A detail's dependency tree (docs/design/kubernetes/analysis.md, 3.7):
/// read once its Overview shows, off the object the detail read — the
/// lists its root needs (`KubeTree.reads`), then the ones they lead to
/// (`followUps`), each in the object's namespace, bounded, by a selector
/// where there is one; Secrets, ConfigMaps, PVCs and ServiceAccounts as
/// their Tables' names alone (a Table and nothing else asked for: never a
/// Secret's data) — each answer decoded, and the tree built, off the main
/// thread (`KubeBlocking`). No watch: Refresh reads again. What it read goes with the
/// detail. GETs only.
@MainActor
final class KubeTreeSession: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let ref: KubeObjectRef
    let root: KubeTree.Root
    @Published private(set) var state: State = .idle
    @Published private(set) var tree: KubeTree?
    /// What the lists read for the tree say of its root's relations (3.9):
    /// a Service selecting no pod, an Ingress to a missing Service or port.
    @Published private(set) var findings: [KubeHealth.Finding] = []

    private let client: KubeClient?
    /// Where each kind is served; nil: the built-in kinds' own places.
    private let discovery: KubeDiscovery?
    private var task: Task<Void, Never>?

    init(ref: KubeObjectRef, root: KubeTree.Root, client: KubeClient?, discovery: KubeDiscovery?) {
        self.ref = ref
        self.root = root
        self.client = client
        self.discovery = discovery
    }

    /// The object couldn't be read: neither can its tree.
    func fail(_ reason: String) {
        guard state != .loaded else { return }
        state = .failed(reason)
    }

    /// Read once (`again`: Refresh), off the object's JSON.
    func load(_ object: KubeObject, again: Bool = false) {
        guard state != .loading, again || state == .idle else { return }
        guard let client else { return state = .failed("Kubernetes is off, or the context is gone.") }
        state = .loading
        let root = self.root
        let json = object.json
        let reads = KubeTree.reads(root, object: json)
        let data = object.data
        let discovery = self.discovery
        task?.cancel()
        task = Task { [weak self] in
            var read = KubeTreeRead(root: data)
            for wanted in reads {
                guard await Self.read(wanted, into: &read, client: client, discovery: discovery) else { return }
            }
            let followUps = KubeTree.followUps(root, object: json, read: read)
            for wanted in followUps {
                guard await Self.read(wanted, into: &read, client: client, discovery: discovery) else { return }
            }
            let done = read
            let (tree, findings) = await KubeBlocking.run { (KubeTree.build(root, read: done), KubeHealth.related(root, read: done)) }
            guard let self, !Task.isCancelled else { return }
            self.tree = tree
            self.findings = findings
            self.state = .loaded
        }
    }

    /// Where a list is: as the context serves its kind, else — before
    /// discovery — a built-in kind's own place; nil when it isn't served.
    nonisolated static func kind(_ read: KubeTree.Read, in discovery: KubeDiscovery?) -> KubeResourceKind? {
        if let discovery { return discovery.kinds.first { $0.group == read.group && $0.resource == read.resource } }
        guard ["", "apps", "batch", "networking.k8s.io"].contains(read.group) else { return nil }
        return KubeResourceKind(
            group: read.group, version: "v1", resource: read.resource, kind: read.kind, singular: read.kind.lowercased(), namespaced: true, verbs: ["get", "list"])
    }

    /// The GET a list is: its namespace, its selector, its limit; a
    /// Table's rows only for names (`includeObject=None`).
    nonisolated static func path(_ read: KubeTree.Read, kind: KubeResourceKind) -> String {
        KubePath.query(
            kind.path(namespace: read.namespace),
            [("labelSelector", read.labelSelector), ("limit", String(read.limit)), ("includeObject", read.table ? "None" : nil)])
    }

    /// What a list asks to be answered as: a names-only read a Table and
    /// nothing else — with no `application/json` to fall back to, a server
    /// that can't make one answers 406 rather than every Secret's data.
    nonisolated static func accept(_ read: KubeTree.Read) -> String {
        read.table ? KubeClient.tableOnlyAccept : "application/json"
    }

    /// One list read into `read`; false when cancelled.
    private static func read(_ wanted: KubeTree.Read, into read: inout KubeTreeRead, client: KubeClient, discovery: KubeDiscovery?) async -> Bool {
        guard !Task.isCancelled else { return false }
        // A kind the context doesn't serve (Gateway API's routes, often) is no list.
        guard let kind = kind(wanted, in: discovery), kind.canList else { return true }
        do {
            let body = try await client.get(path(wanted, kind: kind), accept: accept(wanted)).body
            guard !Task.isCancelled else { return false }
            // A busy namespace's pods are megabytes of JSON: decoded on a
            // global queue, never the main thread.
            let before = read
            read = await KubeBlocking.run {
                var next = before
                next.add(wanted, body: body)
                return next
            }
        } catch is CancellationError {
            return false
        } catch {
            read.failed(wanted, KubernetesModel.said(error))
        }
        return !Task.isCancelled
    }

    /// Navigated away: whatever is being read is dropped, and what was read with it.
    func cancel() {
        task?.cancel()
        task = nil
        tree = nil
        findings = []
        if state == .loading { state = .idle }
    }
}
