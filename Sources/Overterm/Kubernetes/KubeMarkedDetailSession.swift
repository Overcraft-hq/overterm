import Foundation

/// One app read from Argo CD's marks, what its detail reads of it (docs/
/// design/kubernetes/gitops.md, 14.2.3, M4) — only while that detail shows,
/// through the page's client:
///
/// - a GET of each member whose rule reads its object (a workload, a
///   CronJob, an HPA — a Service's, an Ingress's and a claim's cells say
///   theirs), at most 50, 4 in flight, 4 MB each, decoded off the main
///   thread by `KubeMarkedWorkloadWire`'s allow-list; one the section
///   settled in the last 15 s is used as it is, and each one read is told
///   back (`settled`), so the section keeps it as its own settle's and
///   reads it no more (14.4.2);
/// - then a list of each workload's children by its own selector in its
///   own namespace — a Deployment's or a Rollout's ReplicaSets and pods
///   (pods up to 200), a StatefulSet's, a DaemonSet's or a Job's pods, a
///   CronJob's namespace's Jobs — as Table rows with their metadata, a
///   Table or nothing (`tableOnlyAccept`: never whole objects), 8 MB each,
///   decoded off the main thread to what `KubeMarkedAppDetail.children`
///   keeps; an object two overlapping selectors both found, kept once.
///
/// No watch, no timer: read once as it shows — again when its members
/// change, or shown again past 30 s —; Read Again (the header's ↻, or ⌘R
/// with the section's own) reads every one of them again — this
/// cluster's objects, never Argo CD's Refresh, which is the
/// Application's. Never a Secret, a ConfigMap, a list across the cluster,
/// or a write.
@MainActor
final class KubeMarkedDetailSession: ObservableObject {
    enum State: Equatable {
        case idle, loading, loaded
    }

    nonisolated static let inFlight = 4
    /// What was read is shown again within this long.
    nonisolated static let keptFor: TimeInterval = 30
    /// The section's own read of a member, this young, stands.
    nonisolated static let freshFor: TimeInterval = KubeMarkedRefetch.perObject

    @Published private(set) var state: State = .idle
    @Published private(set) var read = KubeMarkedAppDetail.Read()
    /// Whose read it is.
    private(set) var ref: KubeMarkedDetailRef?
    private var members: [KubeMarkedMember.ID] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Shown since it was last read: what it read stands until Refresh,
    /// or its members change — never read again on a timer.
    private var showing = false

    var bounds = KubeMarkedAppDetail.Bounds()
    var getBytes = 4 << 20
    var listBytes = 8 << 20
    var clock: () -> Date = { Date() }
    /// Each object it read: the section keeps it as its own settle's.
    var settled: ((KubeMarkedMember.ID, KubeMarkedWorkloadWire, Date) -> Void)?

    /// The detail of `ref` shows: read, unless it shows already, or what
    /// was read of the same members is younger than `keptFor` (`again`:
    /// Read Again, read anyway). `store`: what the section settled, by member.
    func show(
        _ ref: KubeMarkedDetailRef, app: KubeMarkedApp, discovery: KubeDiscovery?, client: KubeClient?, store: [KubeMarkedMember.ID: KubeMarkedSettled] = [:],
        again: Bool = false
    ) {
        let ids = app.members.map(\.id)
        let now = clock()
        if !again, self.ref == ref, members == ids {
            if state == .loading || (state == .loaded && showing) { return }
            if state == .loaded, let at = read.at, now.timeIntervalSince(at) < Self.keptFor {
                showing = true
                return
            }
        }
        guard let discovery, let client else { return hide() }
        showing = true
        task?.cancel()
        generation += 1
        if self.ref != ref { read = KubeMarkedAppDetail.Read() }
        self.ref = ref
        members = ids
        state = .loading
        asked = []
        let generation = self.generation
        let bounds = self.bounds
        let plan = KubeMarkedAppDetail.fetched(app, limit: bounds.members)
        let kinds = KubeMarkedAppsSession.kinds(discovery)
        let objectKinds = kinds.workloads + kinds.rows
        // Two objects of one name in two namespaces: each note says which.
        let namespaced = app.namespaces.count > 1
        task = Task { [weak self] in
            guard let self else { return }
            var read = KubeMarkedAppDetail.Read(past: plan.past)
            // The members' objects: the section's when fresh, else a GET each.
            var wanted: [(id: KubeMarkedMember.ID, path: String)] = []
            for id in plan.read {
                // Read Again reads whatever the section read.
                if !again, let kept = store[id], now.timeIntervalSince(kept.at) < Self.freshFor {
                    read.objects[id] = kept
                } else if let kind = objectKinds.first(where: { KubeMarkedKind($0) == id.kind }) {
                    wanted.append((id, kind.path(namespace: id.namespace, name: id.name)))
                } else {
                    read.unread[id] = "\(id.kind.kind)s aren't listed here"
                }
            }
            let readAt = self.clock()
            let answers = await self.objects(wanted, client: client)
            guard self.generation == generation, !Task.isCancelled else { return }
            for (id, answer) in answers {
                switch answer {
                case .success(var wire):
                    if wire.kind == nil { wire.kind = id.kind.kind }
                    read.objects[id] = KubeMarkedSettled(wire, at: readAt)
                    self.settled?(id, wire, readAt)
                case .failure(let error as KubeAPIError) where error.isNotFound:
                    read.unread[id] = "gone since its row was read"
                case .failure(let error):
                    read.unread[id] = KubernetesModel.said(error)
                }
            }
            read.at = self.clock()
            self.read = read
            // Then what is under its workloads, by their own selectors.
            let lists = KubeMarkedAppDetail.lists(app, objects: read.objects, bounds: bounds)
            let found = await self.children(lists, discovery: discovery, client: client, namespaced: namespaced)
            guard self.generation == generation, !Task.isCancelled else { return }
            read.children = found.children
            read.notes = found.notes
            read.at = self.clock()
            self.read = read
            self.state = .loaded
        }
    }

    /// The detail closed, or the section left: what is being read stops;
    /// what was read stays, to be shown again within `keptFor`.
    func hide() {
        task?.cancel()
        task = nil
        generation += 1
        showing = false
        if state == .loading { state = .idle }
    }

    /// Another context, the page hidden: what was read goes too.
    func drop() {
        hide()
        ref = nil
        members = []
        state = .idle
        read = KubeMarkedAppDetail.Read()
    }

    // MARK: Reads

    /// A GET each, at most `inFlight` at once.
    private func objects(_ wanted: [(id: KubeMarkedMember.ID, path: String)], client: KubeClient) async -> [(KubeMarkedMember.ID, Result<KubeMarkedWorkloadWire, Error>)] {
        guard !wanted.isEmpty else { return [] }
        let maxBytes = getBytes
        var answers: [(KubeMarkedMember.ID, Result<KubeMarkedWorkloadWire, Error>)] = []
        await withTaskGroup(of: (KubeMarkedMember.ID, Result<KubeMarkedWorkloadWire, Error>).self) { group in
            var next = 0
            var inFlight = 0
            while next < wanted.count || inFlight > 0 {
                while next < wanted.count, inFlight < Self.inFlight, !Task.isCancelled {
                    let (id, path) = wanted[next]
                    next += 1
                    inFlight += 1
                    getsAsked += 1
                    asked.append(path)
                    mostInFlight = max(mostInFlight, inFlight)
                    group.addTask { (id, await Self.object(path, client: client, maxBytes: maxBytes)) }
                }
                guard inFlight > 0, let answer = await group.next() else { break }
                inFlight -= 1
                answers.append(answer)
            }
        }
        return answers
    }

    private nonisolated static func object(_ path: String, client: KubeClient, maxBytes: Int) async -> Result<KubeMarkedWorkloadWire, Error> {
        do {
            let data = try await client.get(path, maxBytes: maxBytes)
            return await KubeBlocking.run { Result { try KubeMarkedWorkloadWire.decode(data) } }
        } catch {
            return .failure(error)
        }
    }

    /// Each list, at most `inFlight` at once: its children — each object
    /// once, however many lists found it —, and what couldn't be read or
    /// was cut, said (the workload in its namespace when `namespaced`).
    private func children(
        _ lists: [KubeMarkedAppDetail.List], discovery: KubeDiscovery, client: KubeClient, namespaced: Bool
    ) async -> (children: [KubeMarkedAppDetail.Child], notes: [String]) {
        var wanted: [(list: KubeMarkedAppDetail.List, kind: KubeResourceKind, path: String)] = []
        var notes: [String] = []
        for list in lists {
            guard let kind = discovery.kinds.first(where: { $0.fullName == list.what.resource && $0.canList }) else {
                notes.append("\(list.what.plural) of \(list.of.said(namespaced: namespaced)): not listed here")
                continue
            }
            let path = KubePath.query(
                kind.path(namespace: list.namespace), [("labelSelector", list.selector), ("limit", String(list.limit)), ("includeObject", "Metadata")])
            wanted.append((list, kind, path))
        }
        guard !wanted.isEmpty else { return ([], notes) }
        let maxBytes = listBytes
        let now = clock()
        var answers: [Int: Result<(children: [KubeMarkedAppDetail.Child], more: Int?), Error>] = [:]
        await withTaskGroup(of: (Int, Result<(children: [KubeMarkedAppDetail.Child], more: Int?), Error>).self) { group in
            var next = 0
            var inFlight = 0
            while next < wanted.count || inFlight > 0 {
                while next < wanted.count, inFlight < Self.inFlight, !Task.isCancelled {
                    let index = next
                    let (list, kind, path) = wanted[index]
                    next += 1
                    inFlight += 1
                    listsAsked += 1
                    asked.append(path)
                    mostInFlight = max(mostInFlight, inFlight)
                    group.addTask { (index, await Self.list(path, list: list, kind: kind, client: client, maxBytes: maxBytes, now: now)) }
                }
                guard inFlight > 0, let (index, answer) = await group.next() else { break }
                inFlight -= 1
                answers[index] = answer
            }
        }
        var children: [KubeMarkedAppDetail.Child] = []
        for (index, item) in wanted.enumerated() {
            let what = "\(item.list.what.plural) of \(item.list.of.said(namespaced: namespaced))"
            switch answers[index] {
            case .success(let found)?:
                children += found.children
                if let more = found.more {
                    notes.append(more > 0 ? "\(what): the first \(item.list.limit) read, \(more) more not" : "\(what): the first \(item.list.limit) read, more not")
                }
            case .failure(let error)?:
                if let api = error as? KubeAPIError, api.isForbidden {
                    notes.append("\(what): refused")
                } else {
                    notes.append("\(what): not read — \(KubernetesModel.said(error))")
                }
            case nil:
                notes.append("\(what): not read")
            }
        }
        // `app=web`'s list holds `app=web,track=canary`'s objects too: kept once.
        return (KubeMarkedAppDetail.unique(children), notes)
    }

    private nonisolated static func list(
        _ path: String, list: KubeMarkedAppDetail.List, kind: KubeResourceKind, client: KubeClient, maxBytes: Int, now: Date
    ) async -> Result<(children: [KubeMarkedAppDetail.Child], more: Int?), Error> {
        do {
            let data = try await client.get(path, accept: KubeClient.tableOnlyAccept, maxBytes: maxBytes)
            return await KubeBlocking.run { Result { try KubeMarkedAppDetail.children(data, list: list, kind: kind, now: now) } }
        } catch {
            return .failure(error)
        }
    }

    // MARK: For the tests

    /// The most GETs in flight at once, objects and lists, since made.
    private(set) var mostInFlight = 0
    /// Objects' GETs and lists asked since made.
    private(set) var getsAsked = 0
    private(set) var listsAsked = 0
    /// The paths the last read asked for, objects' and lists', in order:
    /// what a scenario tells apart from the section's reads beside it.
    private(set) var asked: [String] = []
}
