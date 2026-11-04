import Foundation

/// One object's detail, while the page shows it: one GET of the object
/// when it opens (never a Secret's, rule 9), its Overview and YAML read
/// from that answer, its events asked for once the Events tab shows, the
/// pods its selector picks once the Overview shows. Nothing is watched;
/// navigating away drops the session and all it read.
@MainActor
final class KubeDetailSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case loading
        case loaded
        case failed(String)
        /// A Secret: not read here — one GET would be every value at once.
        case withheld
    }

    /// What was asked for, and how it went.
    enum Part<Value: Equatable>: Equatable {
        case idle
        case loading
        case loaded(Value)
        case failed(String)

        var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    let ref: KubeObjectRef
    nonisolated var id: String { ref.description }
    @Published private(set) var state: State
    @Published private(set) var object: KubeObject?
    @Published private(set) var overview: KubeOverview?
    /// The YAML shows `managedFields` and the last-applied annotation.
    @Published var showsHidden = false {
        didSet { if showsHidden != oldValue { yaml = makeYAML() } }
    }
    @Published private(set) var yaml = ""
    @Published private(set) var events: Part<[KubeEvent]> = .idle
    /// The pods the object's selector picks, as rows of the pod list.
    @Published private(set) var pods: Part<[KubeListRow]> = .idle

    private let client: KubeClient?
    private var tasks: [Task<Void, Never>] = []
    private var asked = false
    /// The Events tab showed before the object was read: asked for once it
    /// is, by its uid.
    private var eventsWanted = false

    init(ref: KubeObjectRef, client: KubeClient?) {
        self.ref = ref
        self.client = client
        state = ref.isSecret ? .withheld : .loading
    }

    /// The one GET, once.
    func load() {
        guard state == .loading, !asked else { return }
        asked = true
        guard let client else { return state = .failed("Kubernetes is off, or the context is gone.") }
        let ref = self.ref
        tasks.append(
            Task { [weak self] in
                do {
                    let object = try await client.object(ref.kind, namespace: ref.namespace, name: ref.name)
                    guard let self, !Task.isCancelled else { return }
                    self.loaded(object)
                } catch is CancellationError {
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.state = .failed(KubernetesModel.said(error))
                    self.askEventsIfWanted()
                }
            })
    }

    private func loaded(_ object: KubeObject) {
        // A Secret is never asked for, whatever comes: a kind discovery
        // named otherwise answering one is dropped, not kept.
        guard !KubeObjectStrip.isSecret(object.json) else {
            state = .withheld
            return
        }
        self.object = object
        overview = KubeOverview.of(object.json)
        yaml = makeYAML()
        state = .loaded
        askEventsIfWanted()
    }

    private func askEventsIfWanted() {
        guard eventsWanted else { return }
        eventsWanted = false
        loadEvents()
    }

    private func makeYAML() -> String {
        guard let object else { return "" }
        return KubeYAML.text(KubeObjectStrip.shown(object.json, full: showsHidden))
    }

    /// Whether the YAML's toggle would show anything.
    var hasHidden: Bool { object.map { KubeObjectStrip.hasHidden($0.json) } ?? false }

    /// The Events tab: its object's events, asked for once (`reload` again).
    func loadEvents(again: Bool = false) {
        guard let client, again || events == .idle, events != .loading else { return }
        // Not read yet: asked once it is, so by its uid — never by its name
        // alone while the uid is on its way (a deleted namesake's events).
        if state == .loading {
            eventsWanted = true
            return
        }
        // The object's own kind and uid, once read; its name alone when it
        // couldn't be read, or is a Secret, withheld.
        let kind = object?.kind ?? ref.kind.kind
        let uid = object?.uid
        let ref = self.ref
        events = .loading
        tasks.append(
            Task { [weak self] in
                do {
                    let events = try await client.events(kind: kind, name: ref.name, namespace: ref.namespace, uid: uid)
                    guard let self, !Task.isCancelled else { return }
                    self.events = .loaded(events)
                } catch is CancellationError {
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.events = .failed(KubernetesModel.said(error))
                }
            })
    }

    /// The pods the Overview's selector picks: one list, rows only.
    func loadPods() {
        guard let client, pods == .idle, let selection = overview?.pods else { return }
        pods = .loading
        tasks.append(
            Task { [weak self] in
                do {
                    let table = try await client.list(
                        .pods, in: .namespace(selection.namespace), options: KubeListOptions(labelSelector: selection.selector))
                    guard let self, !Task.isCancelled else { return }
                    let rows = table.rows.sorted { $0.id < $1.id }.map { KubeListRow(row: $0, summary: KubePodSummary(row: $0, columns: table.columns)) }
                    self.pods = .loaded(rows)
                } catch is CancellationError {
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.pods = .failed(KubernetesModel.said(error))
                }
            })
    }

    /// Navigated away: whatever is still being read is dropped.
    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
    }
}
