import Foundation

/// A workload's History tab (docs/design/kubernetes/analysis.md, 3.6): read
/// once the tab shows — its template revisions (one list of its
/// ReplicaSets or ControllerRevisions by its selector, at most
/// `KubeTimeline.revisionLimit`, owned by its uid), its events, and, when
/// Helm's annotations name its release, that release's records' metadata
/// (no record read for the list) — and joined newest first. A change's
/// diff is made when asked: two templates already read, or two Helm
/// records read then (reading a release is reading a Secret: the page asks
/// first on production). What it holds goes with the detail. GETs only.
@MainActor
final class KubeTimelineSession: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let ref: KubeObjectRef
    let source: KubeTimeline.Source
    @Published private(set) var state: State = .idle
    @Published private(set) var entries: [KubeTimelineEntry] = []
    /// What couldn't be read, or was left out — said over the list.
    @Published private(set) var notes: [String] = []
    /// The template revisions read, oldest first — held for the diffs.
    @Published private(set) var templates: [KubeTemplateRevision] = []
    /// The Helm release the workload says it is part of, and its records.
    @Published private(set) var release: String?
    @Published private(set) var helmRecords: [KubeHelmRecord] = []
    /// The change whose diff is being made.
    @Published private(set) var diffing: KubeTimelineChange?
    /// Why the last diff couldn't be made.
    @Published var diffProblem: String?

    private let client: KubeClient?
    private var kind = ""
    private var tasks: [Task<Void, Never>] = []

    init(ref: KubeObjectRef, source: KubeTimeline.Source, client: KubeClient?) {
        self.ref = ref
        self.source = source
        self.client = client
    }

    /// The object couldn't be read: neither can its history.
    func fail(_ reason: String) {
        guard state != .loaded else { return }
        state = .failed(reason)
    }

    /// Read once (`again`: Refresh), off the workload's object: its uid,
    /// its selector, its Helm annotations.
    func load(_ object: [String: Any], again: Bool = false) {
        guard state != .loading, again || state == .idle else { return }
        guard let client, let namespace = ref.namespace else { return state = .failed("Kubernetes is off, or the context is gone.") }
        state = .loading
        let metadata = object["metadata"] as? [String: Any] ?? [:]
        let uid = metadata["uid"] as? String ?? ""
        let selector = KubeSelector.text((object["spec"] as? [String: Any])?["selector"])
        let kind = (object["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ref.kind.kind
        self.kind = kind
        let helm = KubeTimeline.helmRelease(of: object)
        let source = self.source
        let ref = self.ref
        tasks.append(
            Task { [weak self] in
                var notes: [String] = []
                var revisions: [KubeTemplateRevision] = []
                let what = source == .replicaSets ? "ReplicaSets" : "ControllerRevisions"
                do {
                    let limit = KubeTimeline.revisionLimit
                    let path = KubePath.query(source.path(namespace: namespace), [("labelSelector", selector), ("limit", String(limit))])
                    let body = try await client.get(path).body
                    let read = await KubeBlocking.run { KubeTimeline.revisions(body, source: source, owner: uid) }
                    revisions = read.revisions
                    if read.more { notes.append("More than \(limit) \(what) match its selector: only \(limit) were read.") }
                } catch is CancellationError {
                    return
                } catch {
                    notes.append("Its \(what) couldn't be read: \(KubernetesModel.said(error))")
                }
                var events: [KubeEvent] = []
                do {
                    events = try await client.events(kind: kind, name: ref.name, namespace: namespace, uid: uid.isEmpty ? nil : uid)
                } catch is CancellationError {
                    return
                } catch {
                    notes.append("Its events couldn't be read: \(KubernetesModel.said(error))")
                }
                // What broke is said on what it owns: a Deployment's
                // ReplicaSets (FailedCreate: quota, admission), its pods
                // (BackOff, FailedScheduling…). The namespace's warnings
                // about each Kind, bounded, kept for its own.
                let owned = Set(revisions.map(\.name))
                for about in source == .replicaSets ? ["ReplicaSet", "Pod"] : ["Pod"] {
                    do {
                        let limit = KubeTimeline.warningLimit
                        let read = try await client.warningEvents(about: about, namespace: namespace, limit: limit)
                        events += read.events.filter { KubeTimeline.owns($0, kind: kind, name: ref.name, replicaSets: owned) }
                        if read.more { notes.append("More than \(limit) warnings about \(about)s in \(namespace): only \(limit) were read.") }
                    } catch is CancellationError {
                        return
                    } catch {
                        notes.append("Warnings about its \(about)s couldn't be read: \(KubernetesModel.said(error))")
                    }
                }
                var records: [KubeHelmRecord] = []
                if let helm {
                    let place = helm.namespace ?? namespace
                    for storage in [KubeHelmStorage.secret, .configMap] where records.isEmpty {
                        do {
                            records = try await client.helmRecords(storage, in: .namespace(place), release: helm.name).filter { $0.release == helm.name }
                        } catch is CancellationError {
                            return
                        } catch {
                            notes.append("Helm's revisions of \(helm.name) couldn't be read from its \(storage.said) records: \(KubernetesModel.said(error))")
                        }
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.loaded(revisions: revisions, events: events, records: records, release: helm?.name, notes: notes)
            })
    }

    private func loaded(revisions: [KubeTemplateRevision], events: [KubeEvent], records: [KubeHelmRecord], release: String?, notes: [String]) {
        var notes = notes
        templates = revisions
        helmRecords = records.sorted { $0.revision < $1.revision }
        self.release = release
        let (entries, cut) = KubeTimeline.entries(revisions: revisions, helm: records, events: events, kind: kind)
        if cut > 0 { notes.append("\(cut) older change\(cut == 1 ? "" : "s") left out: the newest \(entries.count) are shown.") }
        self.entries = entries
        self.notes = notes
        state = .loaded
    }

    /// The revisions two pickers can compare: the templates', the release's.
    var templateRevisions: [Int] { templates.map(\.revision) }
    var helmRevisions: [Int] { helmRecords.map(\.revision) }

    /// A change's diff made, then handed to `show` — unless the detail
    /// went meanwhile: the task is the session's, so `cancel` ends it,
    /// and with it whatever it was reading.
    func startDiff(_ change: KubeTimelineChange, production: Bool, show: @escaping @MainActor (KubeChangeDiff) -> Void) {
        tasks.append(
            Task { [weak self] in
                guard let diff = await self?.diff(change, production: production), !Task.isCancelled else { return }
                show(diff)
            })
    }

    /// A change's diff, masked; nil, with why, when it can't be made.
    func diff(_ change: KubeTimelineChange, production: Bool) async -> KubeChangeDiff? {
        diffProblem = nil
        diffing = change
        defer { diffing = nil }
        let namespace = ref.namespace ?? ""
        let workload = "\(kind.lowercased())/\(ref.name)"
        switch change {
        case .template(let from, let to):
            guard let new = templates.first(where: { $0.revision == to }) else {
                diffProblem = "Revision \(to) isn't kept any more."
                return nil
            }
            let old = from.flatMap { number in templates.first { $0.revision == number } }
            if from != nil && old == nil {
                diffProblem = "Revision \(from ?? 0) isn't kept any more."
                return nil
            }
            let kind = self.kind
            let name = ref.name
            let item = await KubeBlocking.run { KubeTimeline.templateDiff(kind: kind, name: name, namespace: namespace, from: old, to: new) }
            let label =
                old.map {
                    "The pod template of revision \(new.revision) (\(new.name)) against revision \($0.revision) (\($0.name)) — stripped; env values that look secret masked, *** (before) and *** (after) where one changed."
                } ?? "Revision \(new.revision)'s pod template (\(new.name)): the oldest kept, so against nothing."
            return KubeChangeDiff(
                id: "\(ref.context)/\(namespace)/\(workload)/template/\(from ?? 0)-\(to)",
                title: "\(workload): revision \(from.map(String.init) ?? "–") → \(to)", context: ref.context, production: production, label: label,
                diff: KubeHelmDiff(items: [item], withheld: 0, secrets: 0))
        case .helm(let from, let to):
            guard let client, let release, let newRecord = helmRecords.first(where: { $0.revision == to }) else {
                diffProblem = "Helm revision \(to) isn't kept any more."
                return nil
            }
            let oldRecord = from.flatMap { number in helmRecords.first { $0.revision == number } }
            do {
                let new = try await Self.inputs(newRecord, client)
                var old: KubeHelm.UpgradeInputs?
                try Task.checkCancellation()
                if let oldRecord { old = try await Self.inputs(oldRecord, client) }
                guard !Task.isCancelled else { return nil }
                let place = newRecord.namespace
                let previous = old
                let diff = await KubeBlocking.run { KubeTimeline.helmDiff(release: release, namespace: place, from: previous, to: new) }
                let label =
                    oldRecord.map {
                        "Helm revision \(to) of \(release) against revision \($0.revision): the user's values, then each object of its manifest — secret values and Secrets' data masked, *** (before) and *** (after) where one changed."
                    } ?? "Helm revision \(to) of \(release): the oldest kept, so against nothing."
                return KubeChangeDiff(
                    id: "\(ref.context)/\(place)/helm/\(release)/\(from ?? 0)-\(to)", title: "Helm \(release): revision \(from.map(String.init) ?? "–") → \(to)",
                    context: ref.context, production: production, label: label, diff: diff)
            } catch is CancellationError {
                return nil
            } catch {
                diffProblem = "Couldn't read Helm's revisions: \(KubernetesModel.said(error))"
                return nil
            }
        }
    }

    /// One record's values and manifest, raw, decoded off the main thread —
    /// held only while its diff is made.
    private static func inputs(_ record: KubeHelmRecord, _ client: KubeClient) async throws -> KubeHelm.UpgradeInputs {
        let body = try await client.get(record.storage.kind.path(namespace: record.namespace, name: record.object)).body
        try Task.checkCancellation()
        let storage = record.storage
        return try await KubeBlocking.run { Swift.Result { try KubeHelm.upgradeInputs(body, storage: storage) } }.get()
    }

    /// Navigated away: whatever is being read is dropped, and what was read with it.
    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
        templates = []
        helmRecords = []
        entries = []
    }
}
