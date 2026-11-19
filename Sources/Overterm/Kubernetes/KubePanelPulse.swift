import Foundation

/// The rail's pulse: the last hour's Warning events — of the bound
/// namespace, or, with no binding, of the page's context in the namespace
/// the checkout's files name (else the context's own). What the rail had
/// room for and said nothing in. One namespace only, as everything the
/// rail reads: never the whole cluster (its nodes are the page's).
///
/// Read only while the panel shows (the panel model starts and stops it),
/// on the background slot's client as the rest of the rail: one follow,
/// Table rows only, `type=Warning` asked of the server. Events that can't
/// be listed (no right to) are said in one line; the rest of the rail goes on.
@MainActor
final class KubePanelPulse: ObservableObject {
    @Published private(set) var warnings: [KubeClusterOverview.Warning] = []
    @Published private(set) var problem: String?
    /// Where it reads: `context · namespace`.
    @Published private(set) var scope: String?

    /// Warnings the rail lists at most; the page has the rest.
    static let shown = 8

    private var tasks: [Task<Void, Never>] = []
    private var eventRows = KubeRows()
    private var key: String?

    func follow(_ client: KubeClient, context: String, namespace: String) {
        let key = "\(context)|\(namespace)"
        guard key != self.key else { return }
        stop()
        self.key = key
        scope = context + " · " + namespace
        let events = KubeResourceKind(
            group: "", version: "v1", resource: "events", kind: "Event", singular: "event", namespaced: true, verbs: ["get", "list", "watch"],
            shortNames: ["ev"])
        tasks.append(
            Task { [weak self] in
                do {
                    for try await update in client.follow(
                        events, in: .namespace(namespace), options: KubeListOptions(fieldSelector: "type=Warning"))
                    {
                        guard let self, self.key == key else { return }
                        if case .retrying = update { continue }
                        self.eventRows.apply(update)
                        let overview = KubeClusterOverview.of(.init(warnings: self.eventRows))
                        if overview.warnings != self.warnings { self.warnings = overview.warnings }
                    }
                } catch is CancellationError {
                } catch {
                    guard let self, self.key == key else { return }
                    self.problem = "Warnings: " + KubernetesModel.said(error)
                }
            })
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks = []
        key = nil
        eventRows = KubeRows()
        warnings = []
        problem = nil
        scope = nil
    }
}
