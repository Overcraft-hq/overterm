import Foundation

/// Usage from metrics.k8s.io (docs/design/kubernetes/analysis.md, 2.11;
/// stage 2d), polled only while a column or the Overview shows it: each
/// page says what it wants on screen (`want`) — the pods list's CPU and
/// Memory, the nodes' (and the Overview's totals) — and the model says
/// where (`update`: the context shown, its namespace, the list's label
/// selector, and whether discovery says metrics-server is there). Nothing
/// wanted, or no metrics-server, nothing is asked: discovery said so, and
/// that is no error. A context's `metrics: none` skips the check entirely.
///
/// A detail asks for its own object too (`wantDetail`, metrics.md 4.1): a
/// pod's PodMetrics, a node's NodeMetrics, an HPA — at most
/// `maxDetailTargets` a context, a fourth replacing the oldest.
///
/// metrics-server samples every 15 s and keeps no history, so this asks
/// every `interval` (15 s) and keeps the last answer; the samples taken
/// while shown go to the context's `KubeUsageRing` (in memory: a list's
/// rows while sampled, a detail's for an hour after it was last polled,
/// two tiers; merged off the main thread and assigned whole; dropped on a
/// context switch and a credential failure — never because the page was
/// hidden, decision 1). A 403 is said once, in its own words, and the
/// target isn't asked again until the context's credentials change
/// (`retry`, another context) — never every 15 s, nor at each show; of a
/// pods target's several namespaces, only those refused are left out and
/// named, the others' samples standing. A node's allocatable is read with the
/// first and then every `allocatableEvery`th. A read that fails leaves the
/// last sample standing, aging — each failed read publishes, so the cells
/// look at its age again — until it is older than `staleAfter`: then it is
/// a dash, never a stale number shown as current. A credential failure
/// ends the polling (no retry runs the exec plugin again) and drops the
/// sample at once — nothing more will come to age it — keeping why; a page
/// asking again doesn't start it (hiding and showing would run the plugin
/// again), only another context, namespace, label selector or what the
/// cluster serves, or the model's `retry` after a sign-in. Reads only,
/// through the context's proxy.
@MainActor
final class KubeMetricsMonitor: ObservableObject {
    /// Where usage is read: the model's context, as it stands.
    struct Situation: Equatable {
        var context: String
        var scope: KubeScope
        var labels: String?
        var availability: KubeMetricsAvailability
        /// Which cluster, as which user, the context is
        /// (`KubePrometheusMonitor.cluster(of:)`): the same name pointed
        /// elsewhere is another context's samples.
        var cluster = ""
    }

    var interval: Duration = .seconds(15)
    /// A node's allocatable is read again every this many polls (5 minutes at 15 s).
    var allocatableEvery = 20
    /// How long a sample may stand before it is a dash: three missed reads.
    var staleAfter: TimeInterval { Double(interval.components.seconds) * 3 + 15 }
    /// When a sample's own stamp is this old, the page says its age.
    var oldAfter: TimeInterval = 60

    /// The most targets the details of one context poll at once.
    static let maxDetailTargets = 3

    @Published private(set) var availability: KubeMetricsAvailability = .unknown
    @Published private(set) var readings: [KubeMetricsTarget: KubeMetricsReading] = [:]
    /// The samples taken while shown, the context's (`last`'s, kept while
    /// nothing is shown): changed as `readings` is (which publishes), so it
    /// needn't publish itself.
    private(set) var ring = KubeUsageRing() { didSet { ringChanges &+= 1 } }
    /// The numbers objects' status gave while their tab showed (an HPA's,
    /// a workload's replicas, a node's pods, a namespace's phases): kept,
    /// dropped and changed as the ring is.
    private(set) var statuses = KubeStatusHistory()
    /// Counts the ring's changes: a merge made off the main thread over a
    /// copy is assigned only if nothing changed it meanwhile.
    private var ringChanges = 0
    /// How many metrics requests were made, for the tests.
    private(set) var requests = 0

    private var wanted: [ObjectIdentifier: KubeMetricsWant] = [:]
    /// What each detail wants polled for it.
    private var detailWanted: [ObjectIdentifier: [KubeMetricsDetail]] = [:]
    /// The details' targets in the order they were first wanted: the last
    /// `maxDetailTargets` are polled.
    private var detailOrder: [KubeMetricsDetail] = []
    /// Targets refused with a 403 (and why): not asked again until the
    /// context's credentials change.
    private var refused: [KubeMetricsTarget: String] = [:]
    /// A pods target's reads refused while others answered (nil, across
    /// the cluster): left out, not asked again until the credentials change.
    private var partlyRefused: [KubeMetricsTarget: Set<String?>] = [:]
    private var situation: Situation?
    /// Whether the ring's samples (`last`'s, shown or not) are `context`'s:
    /// its name, and the cluster and user it points at — an agent's
    /// `k8s_metrics` reads them only for that one.
    func ringHolds(_ context: KubeContext) -> Bool {
        guard let last else { return false }
        return last.context == context.name && last.cluster == KubePrometheusMonitor.cluster(of: context)
    }
    /// The last situation that named a context: the one the ring, the
    /// refusals and the stops belong to, kept while nothing is shown.
    private var last: Situation?
    private var client: () -> KubeClient? = { nil }
    private var polls: [KubeMetricsTarget: Task<Void, Never>] = [:]
    /// Targets whose polling ended at a credential failure, and why: not
    /// started again until the situation changes (to another, not by
    /// hiding and showing) or a retry.
    private var stopped: [KubeMetricsTarget: String] = [:]

    /// What `owner` shows now that needs usage; nil, nothing.
    func want(_ want: KubeMetricsWant?, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        guard wanted[id] != want else { return }
        wanted[id] = want
        reconcile()
    }

    /// What a detail shows now that needs its own usage read (a pod's, a
    /// node's, an HPA's); empty, nothing. Its samples stay in the ring for
    /// an hour after.
    func wantDetail(_ details: [KubeMetricsDetail], for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        let details = details.isEmpty ? nil : details
        guard detailWanted[id] != details else { return }
        detailWanted[id] = details
        let all = Set(detailWanted.values.joined())
        detailOrder.removeAll { !all.contains($0) }
        for detail in details ?? [] where !detailOrder.contains(detail) { detailOrder.append(detail) }
        reconcile()
    }

    /// The details polled now: the last `maxDetailTargets` wanted.
    var details: [KubeMetricsDetail] {
        var targets: [KubeMetricsTarget] = []
        var polled: [KubeMetricsDetail] = []
        for detail in detailOrder.reversed() {
            if !targets.contains(detail.target) {
                guard targets.count < Self.maxDetailTargets else { continue }
                targets.append(detail.target)
            }
            polled.append(detail)
        }
        return polled.reversed()
    }

    /// Where usage is read now; nil: nowhere (nobody looks, Kubernetes off, no context).
    func update(_ situation: Situation?, client: @escaping () -> KubeClient?) {
        self.client = client
        guard situation != self.situation else { return }
        if let situation, situation.context != last?.context || situation.cluster != last?.cluster {
            // Another context's samples are never shown as this one's, nor
            // its refusals kept. Nowhere (the page hidden, the window
            // occluded) keeps them: coming back shows what was sampled
            // before, the time away a gap (decision 1).
            forget()
        }
        if situation?.context != self.situation?.context || situation?.cluster != self.situation?.cluster
            || situation?.availability != self.situation?.availability
        {
            // Another context's numbers are never shown as this one's.
            for task in polls.values { task.cancel() }
            polls = [:]
            if !readings.isEmpty { readings = [:] }
        }
        if let situation, situation != last {
            stopped = [:]
            last = situation
        }
        self.situation = situation
        let shown = situation?.availability ?? .unknown
        if availability != shown { availability = shown }
        reconcile()
    }

    /// The pages' targets (the lists', the Overview's), where they are read now.
    var listTargets: Set<KubeMetricsTarget> {
        guard let situation else { return [] }
        return Set(
            wanted.values.map { want in
                switch want {
                case .pods: .pods(situation.scope, labels: situation.labels)
                case .nodes: .nodes
                }
            })
    }

    /// Every target wanted: the pages' and the details' polled.
    var targets: Set<KubeMetricsTarget> {
        guard situation != nil else { return [] }
        return listTargets.union(details.map(\.target))
    }

    /// The reading behind a detail.
    func reading(_ detail: KubeMetricsDetail) -> KubeMetricsReading? { readings[detail.target] }

    /// The reading behind what `want` shows now.
    func reading(_ want: KubeMetricsWant) -> KubeMetricsReading? {
        guard let situation else { return nil }
        switch want {
        case .pods: return readings[.pods(situation.scope, labels: situation.labels)]
        case .nodes: return readings[.nodes]
        }
    }

    /// Whether what `want` shows was refused, whole or some of its
    /// namespaces: Try Again (the model's `retry`) asks again — after an
    /// RBAC grant, which changes no credentials.
    func isRefused(_ want: KubeMetricsWant) -> Bool {
        guard let reading = reading(want) else { return false }
        return reading.refused != nil || reading.sample?.refusal != nil
    }

    /// Whether anything is polled now.
    var isPolling: Bool { !polls.isEmpty }

    /// After a sign-in, or a failure put right (`KubernetesModel.retry`):
    /// what a credential failure stopped is polled again, if still wanted.
    func retry() {
        guard !stopped.isEmpty || !refused.isEmpty || !partlyRefused.isEmpty else { return }
        stopped = [:]
        refused = [:]
        partlyRefused = [:]
        reconcile()
    }

    /// The context's samples and refusals: dropped.
    private func forget() {
        if !ring.isEmpty { ring.removeAll() }
        if !statuses.isEmpty { statuses.removeAll() }
        refused = [:]
        partlyRefused = [:]
    }

    private func reconcile() {
        let availability = situation?.availability ?? .unknown
        let wantedTargets = targets.filter { availability == .served || (!$0.needsMetricsServer && availability != .off) }
        for (target, task) in polls where !wantedTargets.contains(target) {
            task.cancel()
            polls[target] = nil
        }
        for target in readings.keys where !wantedTargets.contains(target) { readings[target] = nil }
        // A list no longer read: its rows' samples go (a detail's stay their hour).
        let lists = listTargets.intersection(wantedTargets)
        if !lists.contains(where: { if case .pods = $0 { true } else { false } }) {
            ring.forgetListed { if case .pod = $0 { true } else { false } }
        }
        if !lists.contains(.nodes) {
            ring.forgetListed { key in
                switch key {
                case .node, .cluster: true
                default: false
                }
            }
        }
        ring.prune(now: Date())
        statuses.prune(now: Date())
        for target in wantedTargets where polls[target] == nil {
            if let why = stopped[target] {
                // Its sign-in failed: said, not asked again until a retry.
                if readings[target]?.problem != why || readings[target]?.sample != nil {
                    var reading = KubeMetricsReading()
                    reading.problem = why
                    readings[target] = reading
                }
                continue
            }
            if let why = refused[target] {
                // Said once; not asked again until the credentials change.
                if readings[target]?.refused != why {
                    var reading = KubeMetricsReading()
                    reading.problem = why
                    reading.refused = why
                    readings[target] = reading
                }
                continue
            }
            polls[target] = poll(target)
        }
    }

    /// What `sample` adds to the ring: as a list's rows, a detail's, sums.
    /// Merged off the main thread over a copy (5,000 rows' points, the
    /// hour's and the cap's bounds — metrics.md 5.3), then assigned whole —
    /// unless the ring changed meanwhile (another target's merge, a list
    /// forgotten, a context switch), when it is merged again over the new one.
    private func record(_ sample: KubeMetricsSample, for target: KubeMetricsTarget) async {
        let details = self.details.filter { $0.target == target }
        recordStatus(sample, for: target)
        // A namespace's workloads: its Metadata rows' owners, when read.
        let owners = details.compactMap(\.ownersFrom).first.flatMap { readings[.namespacePods($0)]?.sample?.namespacePods?.owners } ?? [:]
        let merge = Merge(
            sample: sample, target: target, asList: listTargets.contains(target), asDetail: !details.isEmpty, sums: details.compactMap(\.sum),
            parts: Array(Set(details.flatMap(\.parts))), owners: owners,
            // A break is a stretch past 2.5 samples: metrics-server's own spacing, if longer than the poll's.
            interval: max(15, Double(interval.components.seconds), sample.resolution ?? 0))
        for _ in 0..<3 {
            let seen = ringChanges
            let (merged, onMain) = await Task.detached(priority: .utility) { [ring = self.ring] in
                (merge.apply(to: ring, now: Date()), pthread_main_np() != 0)
            }.value
            guard !Task.isCancelled else { return }
            if seen == ringChanges {
                ring = merged
                merges += 1
                if onMain { mergesOnMain += 1 }
                return
            }
        }
        // Changed under every try: merged here, once.
        ring = merge.apply(to: ring, now: Date())
        merges += 1
        mergesOnMain += 1
    }

    /// How many merges were assigned, and how many of them were made on
    /// the main thread, for the tests.
    private(set) var merges = 0
    private(set) var mergesOnMain = 0

    /// One sample's merge into a ring: pure, made wherever.
    private struct Merge: Sendable {
        var sample: KubeMetricsSample
        var target: KubeMetricsTarget
        var asList: Bool
        var asDetail: Bool
        var sums: [KubeUsageKey]
        var parts: [KubeUsageParts]
        var owners: [String: String]
        var interval: TimeInterval

        nonisolated func apply(to ring: KubeUsageRing, now: Date) -> KubeUsageRing {
            var ring = ring
            ring.interval = interval
            ring.record(sample, for: target, asList: asList, asDetail: asDetail, sums: sums, parts: parts, owners: owners, now: now)
            return ring
        }
    }

    /// An object's numbers, into the status history: an HPA's, a
    /// workload's replicas, a node's pods, a namespace's phases.
    private func recordStatus(_ sample: KubeMetricsSample, for target: KubeMetricsTarget) {
        let expected = Double(interval.components.seconds) * Double(target.every) + Double(interval.components.attoseconds) / 1e18 * Double(target.every)
        let now = Date()
        switch target {
        case .hpa(let namespace, let name):
            if let hpa = sample.hpa { statuses.record(.hpa(namespace: namespace, name: name), hpa.numbers, at: sample.read, expected: expected, now: now) }
        case .replicas(let namespace, let kind, let name, _):
            if let replicas = sample.replicas {
                statuses.record(.replicas(namespace: namespace, kind: kind, name: name), replicas.numbers, at: sample.read, expected: expected, now: now)
            }
        case .nodePods(let node):
            if let pods = sample.nodePods {
                var values: [String: Double] = ["pods": Double(pods.active.count)]
                if !pods.more {
                    values["cpu"] = pods.requested.cpu
                    values["memory"] = pods.requested.memory
                }
                statuses.record(.nodePods(node), values, at: sample.read, expected: expected, now: now)
            }
        case .namespacePods(let namespace):
            if let pods = sample.namespacePods {
                var values = pods.phases
                for phase in KubePodPhase.order where values[phase] == nil { values[phase] = 0 }
                statuses.record(.phases(namespace), values, at: sample.read, expected: expected, now: now)
            }
        case .pods, .nodes, .pod, .node, .podsOn:
            break
        }
    }

    private func poll(_ target: KubeMetricsTarget) -> Task<Void, Never> {
        Task { [weak self] in
            var count = 0
            var allocatable: [String: KubeUsage] = [:]
            var capacity: [String: KubeUsage] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                guard let client = self.client() else {
                    // No connection now (the proxy between starts): asked again
                    // next time, the sample aging meanwhile.
                    guard self.polls[target] != nil else { return }
                    var reading = self.readings[target] ?? KubeMetricsReading()
                    reading.problem = "The context isn't connected."
                    self.readings[target] = reading
                    try? await Task.sleep(for: self.interval)
                    continue
                }
                self.requests += 1
                do {
                    let sample: KubeMetricsSample
                    switch target {
                    case .pods, .podsOn:
                        let read = try await target.pods(client, skipping: self.partlyRefused[target] ?? [])
                        guard !Task.isCancelled, self.polls[target] != nil else { return }
                        // A namespace refused: left out and named, the others' standing.
                        if !read.refused.isEmpty { self.partlyRefused[target, default: []].formUnion(read.refused) }
                        var pods = KubeMetricsSample(pods: read.pods, read: Date())
                        pods.refusedReads = Array(self.partlyRefused[target] ?? [])
                        sample = pods
                    case .pod:
                        sample = KubeMetricsSample(pods: [try KubeMetricsReader.pod(try await client.get(target.path).body)], read: Date())
                    case .node:
                        sample = KubeMetricsSample(nodes: [try KubeMetricsReader.node(try await client.get(target.path).body)], allocatable: [:], read: Date())
                    case .hpa:
                        sample = KubeMetricsSample(hpa: try KubeMetricsReader.hpa(try await client.get(target.path).body), read: Date())
                    case .replicas(_, let kind, _, _):
                        var read = KubeMetricsSample(read: Date())
                        read.replicas = try KubeReplicaStatus.read(try await client.get(target.path).body, kind: kind)
                        sample = read
                    case .nodePods:
                        let body = try await client.get(target.path).body
                        // Decoded off the main thread: up to 250 pods' objects, dropped as read.
                        let pods = try await Task.detached(priority: .utility) { try KubeNodePods.read(body) }.value
                        var read = KubeMetricsSample(read: Date())
                        read.nodePods = pods
                        sample = read
                    case .namespacePods:
                        var read = KubeMetricsSample(read: Date())
                        read.namespacePods = try await Self.namespacePods(client, path: target.path)
                        sample = read
                    case .nodes:
                        let body = try await client.get(target.path).body
                        if count % max(1, self.allocatableEvery) == 0 || allocatable.isEmpty {
                            self.requests += 1
                            if let read = try? await Self.nodeResources(client) {
                                allocatable = read.allocatable
                                capacity = read.capacity
                            }
                        }
                        var nodes = KubeMetricsSample(nodes: try KubeMetricsReader.nodes(body), allocatable: allocatable, read: Date())
                        nodes.capacity = capacity
                        sample = nodes
                    }
                    guard !Task.isCancelled, self.polls[target] != nil else { return }
                    await self.record(sample, for: target)
                    guard !Task.isCancelled, self.polls[target] != nil else { return }
                    var reading = self.readings[target] ?? KubeMetricsReading()
                    reading.sample = sample
                    reading.problem = nil
                    reading.refused = nil
                    self.readings[target] = reading
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.polls[target] != nil else { return }
                    var reading = self.readings[target] ?? KubeMetricsReading()
                    reading.problem = KubernetesModel.said(error)
                    if error is KubeProxyProblem {
                        // The context's sign-in failed: its list says so; nothing more
                        // is asked, so nothing would age the sample — it goes now,
                        // and every sample taken of the context with it.
                        reading.sample = nil
                        self.forget()
                        self.readings[target] = reading
                        self.polls[target] = nil
                        self.stopped[target] = reading.problem ?? KubernetesModel.said(error)
                        return
                    }
                    if let refusal = error as? KubeAPIError, refusal.isForbidden {
                        // RBAC said no: said once, and not asked again every 15 s.
                        let why = target.refusal
                        reading.sample = nil
                        reading.problem = why
                        reading.refused = why
                        self.readings[target] = reading
                        self.refused[target] = why
                        self.polls[target] = nil
                        return
                    }
                    self.readings[target] = reading
                }
                count += 1
                try? await Task.sleep(for: self.interval * target.every)
            }
        }
    }

    /// A namespace's pods as Metadata rows, paged (`KubeNamespacePods.pages` at most).
    nonisolated static func namespacePods(_ client: KubeClient, path: String) async throws -> KubeNamespacePods {
        var pods: [KubeNamespacePods.Pod] = []
        var token: String?
        var pages = 0
        repeat {
            let page = token.map { path + (path.contains("?") ? "&" : "?") + "continue=" + KubePath.segment($0) } ?? path
            let read = try KubeNamespacePods.read(try await client.get(page, accept: KubeClient.tableAccept).body)
            pods += read.pods
            token = read.continueToken
            pages += 1
        } while token != nil && pages < KubeNamespacePods.pages
        return KubeNamespacePods(pods: pods, more: token != nil)
    }

    /// Every node's allocatable: the NodeList, paged, read whole for its
    /// `status.allocatable` (the Table's rows don't carry it).
    nonisolated static func allocatable(_ client: KubeClient) async throws -> [String: KubeUsage] {
        try await nodeResources(client).allocatable
    }

    /// Every node's allocatable and capacity, from the same pages.
    nonisolated static func nodeResources(_ client: KubeClient) async throws -> (allocatable: [String: KubeUsage], capacity: [String: KubeUsage]) {
        var nodes: [String: KubeUsage] = [:]
        var capacity: [String: KubeUsage] = [:]
        var token: String?
        var pages = 0
        repeat {
            let body = try await client.get(KubePath.query("/api/v1/nodes", [("limit", "500"), ("continue", token)])).body
            let page = try KubeMetricsReader.nodeResources(body)
            nodes.merge(page.allocatable) { $1 }
            capacity.merge(page.capacity) { $1 }
            token = page.continueToken
            pages += 1
        } while token != nil && pages < 20
        return (nodes, capacity)
    }

    /// The cell a row's column shows now.
    func cell(_ measure: KubeUsageCell.Measure, row id: KubeRowID, want: KubeMetricsWant, now: Date = Date()) -> KubeUsageCell {
        KubeUsageCell.of(
            measure, row: id, isNode: want == .nodes, availability: availability, reading: reading(want), now: now, staleAfter: staleAfter)
    }

    /// What the page says of the usage shown: why there is none, or how
    /// old it is when it is old; nil while it is fresh.
    func note(_ want: KubeMetricsWant, now: Date = Date()) -> String? {
        if let reason = availability.reason, availability != .unknown { return reason }
        guard let reading = reading(want) else { return nil }
        if let refused = reading.refused { return refused }
        guard let sample = reading.sample else { return reading.problem.map { "Usage couldn't be read: \($0)" } }
        let age = now.timeIntervalSince(sample.read)
        if age > staleAfter { return "Usage not read for \(KubeMetricsFormat.age(age))" + (reading.problem.map { ": \($0)" } ?? "") }
        // Some namespaces refused: named, the others' numbers shown.
        if let refusal = sample.refusal { return refusal }
        if let oldest = sample.oldest, now.timeIntervalSince(oldest) > oldAfter {
            return "Usage sampled \(KubeMetricsFormat.age(now.timeIntervalSince(oldest))) ago"
        }
        return nil
    }
}
