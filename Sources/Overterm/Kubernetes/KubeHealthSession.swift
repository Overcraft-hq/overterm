import Foundation

/// The Overview's health checks (`1`; docs/design/kubernetes/analysis.md,
/// 3.9), a window's as its page is: read once the section shows on a page
/// on screen, in the context and namespace shown (every namespace too, each
/// list bounded) — the lists `KubeHealth.reads` names that the context
/// serves and lets be listed, one GET each of whole objects (decision 33:
/// the one read 3.9 adds), never a Secret or a ConfigMap, no watch; each
/// answer decoded, what may carry a secret dropped (`KubeHealth.kept`),
/// and the checks run, off the main thread.
/// Refresh reads again. Hidden — another section, the page or its window
/// off screen — what was read goes. Reads only.
@MainActor
final class KubeHealthSession: ObservableObject {
    enum State: Equatable {
        case idle, loading, loaded
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var report = KubeHealth.Report()
    private(set) var context: String?
    private(set) var scope: KubeScope?

    private var task: Task<Void, Never>?
    private var generation = 0
    /// How many of its lists are asked at once (the scale scenario's 1 is
    /// the one-after-the-other it was).
    static var readWidth = 4
    /// What it read for, to read again only when that changes.
    private struct Key: Equatable {
        var context: String
        var scope: KubeScope
        var kinds: [String]
    }
    private var shown: Key?

    /// Shown on `context` in `scope`: read once there — again only when
    /// the context, the namespace or what it serves changed (or `again`).
    func show(context: String, scope: KubeScope, discovery: KubeDiscovery?, client: KubeClient?, again: Bool = false) {
        let kinds = Self.kinds(discovery)
        let key = Key(context: context, scope: scope, kinds: kinds.map(\.1.fullName))
        if key == shown, !again { return }
        hide()
        guard let client else { return }
        shown = key
        self.context = context
        self.scope = scope
        state = .loading
        let generation = self.generation
        let width = Self.readWidth
        task = Task { [weak self] in
            let place = scope.namespace(for: .pods).map { "namespace \($0)" } ?? "every namespace"
            // The lists at once (bounded), then decoded in their order:
            // a namespace's pods are megabytes of JSON, decoded off the
            // main thread.
            let answers = await client.getAll(kinds.map { read, kind in (Self.path(read, kind: kind, scope: scope), "application/json") }, width: width)
            guard !Task.isCancelled else { return }
            if answers.contains(where: { if case .failure(let error) = $0 { error is CancellationError } else { false } }) { return }
            let report = await KubeBlocking.run {
                var lists = KubeHealth.Lists()
                for ((read, kind), answer) in zip(kinds, answers) {
                    switch answer {
                    case .success(let body): lists.add(read, kind: kind.kind, apiVersion: kind.groupVersion, body: body, place: place)
                    case .failure(let error): lists.failed(read, KubernetesModel.said(error), place: place)
                    }
                }
                return KubeHealth.report(lists)
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.report = report
            self.state = .loaded
        }
    }

    /// Refresh: the same place read again.
    func refresh(discovery: KubeDiscovery?, client: KubeClient?) {
        guard let context, let scope else { return }
        show(context: context, scope: scope, discovery: discovery, client: client, again: true)
    }

    /// Off screen: nothing read, nothing kept.
    func hide() {
        generation += 1
        task?.cancel()
        task = nil
        shown = nil
        context = nil
        scope = nil
        if state != .idle { state = .idle }
        if report != KubeHealth.Report() { report = KubeHealth.Report() }
    }

    /// What it reads of a cluster that serves `discovery`: each of
    /// `KubeHealth.reads` it serves and lets be listed, at its version;
    /// before discovery, pods alone.
    nonisolated static func kinds(_ discovery: KubeDiscovery?) -> [(KubeHealth.Read, KubeResourceKind)] {
        guard let discovery else { return [(KubeHealth.reads[0], .pods)] }
        return KubeHealth.reads.compactMap { read in
            discovery.kinds.first { $0.group == read.group && $0.resource == read.resource && $0.canList }.map { (read, $0) }
        }
    }

    /// One bounded list's GET, its objects whole (the checks read their specs).
    nonisolated static func path(_ read: KubeHealth.Read, kind: KubeResourceKind, scope: KubeScope) -> String {
        KubePath.query(kind.path(namespace: scope.namespace(for: kind)), [("limit", String(read.limit))])
    }
}
