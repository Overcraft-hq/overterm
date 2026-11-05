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
/// metrics-server samples every 15 s and keeps no history, so this asks
/// every `interval` (15 s) and keeps the last answer, with a ring of the
/// samples taken while shown for the sparklines (`KubeUsageHistory`, in
/// memory, gone with the reading); a node's allocatable is read with the
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
    }

    var interval: Duration = .seconds(15)
    /// A node's allocatable is read again every this many polls (5 minutes at 15 s).
    var allocatableEvery = 20
    /// How long a sample may stand before it is a dash: three missed reads.
    var staleAfter: TimeInterval { Double(interval.components.seconds) * 3 + 15 }
    /// When a sample's own stamp is this old, the page says its age.
    var oldAfter: TimeInterval = 60

    @Published private(set) var availability: KubeMetricsAvailability = .unknown
    @Published private(set) var readings: [KubeMetricsTarget: KubeMetricsReading] = [:]
    /// How many metrics requests were made, for the tests.
    private(set) var requests = 0

    private var wanted: [ObjectIdentifier: KubeMetricsWant] = [:]
    private var situation: Situation?
    private var client: () -> KubeClient? = { nil }
    private var polls: [KubeMetricsTarget: Task<Void, Never>] = [:]
    /// Targets whose polling ended at a credential failure: not started
    /// again until the situation changes.
    private var stopped: Set<KubeMetricsTarget> = []

    /// What `owner` shows now that needs usage; nil, nothing.
    func want(_ want: KubeMetricsWant?, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        guard wanted[id] != want else { return }
        wanted[id] = want
        reconcile()
    }

    /// Where usage is read now; nil: nowhere (nobody looks, Kubernetes off, no context).
    func update(_ situation: Situation?, client: @escaping () -> KubeClient?) {
        self.client = client
        guard situation != self.situation else { return }
        if situation?.context != self.situation?.context || situation?.availability != self.situation?.availability {
            // Another context's numbers are never shown as this one's.
            for task in polls.values { task.cancel() }
            polls = [:]
            if !readings.isEmpty { readings = [:] }
        }
        stopped = []
        self.situation = situation
        let shown = situation?.availability ?? .unknown
        if availability != shown { availability = shown }
        reconcile()
    }

    /// The targets wanted, where they are read now.
    var targets: Set<KubeMetricsTarget> {
        guard let situation else { return [] }
        return Set(
            wanted.values.map { want in
                switch want {
                case .pods: .pods(situation.scope, labels: situation.labels)
                case .nodes: .nodes
                }
            })
    }

    /// The reading behind what `want` shows now.
    func reading(_ want: KubeMetricsWant) -> KubeMetricsReading? {
        guard let situation else { return nil }
        switch want {
        case .pods: return readings[.pods(situation.scope, labels: situation.labels)]
        case .nodes: return readings[.nodes]
        }
    }

    /// Whether anything is polled now.
    var isPolling: Bool { !polls.isEmpty }

    /// After a sign-in, or a failure put right (`KubernetesModel.retry`):
    /// what a credential failure stopped is polled again, if still wanted.
    func retry() {
        guard !stopped.isEmpty else { return }
        stopped = []
        reconcile()
    }

    private func reconcile() {
        let wantedTargets = situation?.availability == .served ? targets : []
        for (target, task) in polls where !wantedTargets.contains(target) {
            task.cancel()
            polls[target] = nil
            readings[target] = nil
        }
        for target in wantedTargets where polls[target] == nil && !stopped.contains(target) {
            polls[target] = poll(target)
        }
    }

    private func poll(_ target: KubeMetricsTarget) -> Task<Void, Never> {
        Task { [weak self] in
            var count = 0
            var allocatable: [String: KubeUsage] = [:]
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
                    case .pods:
                        let body = try await client.get(target.path).body
                        sample = KubeMetricsSample(pods: try KubeMetricsReader.pods(body), read: Date())
                    case .nodes:
                        let body = try await client.get(target.path).body
                        if count % max(1, self.allocatableEvery) == 0 || allocatable.isEmpty {
                            self.requests += 1
                            allocatable = (try? await Self.allocatable(client)) ?? allocatable
                        }
                        sample = KubeMetricsSample(nodes: try KubeMetricsReader.nodes(body), allocatable: allocatable, read: Date())
                    }
                    guard !Task.isCancelled, self.polls[target] != nil else { return }
                    var reading = self.readings[target] ?? KubeMetricsReading()
                    reading.sample = sample
                    reading.problem = nil
                    reading.history.record(sample)
                    self.readings[target] = reading
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.polls[target] != nil else { return }
                    var reading = self.readings[target] ?? KubeMetricsReading()
                    reading.problem = KubernetesModel.said(error)
                    if error is KubeProxyProblem {
                        // The context's sign-in failed: its list says so; nothing more
                        // is asked, so nothing would age the sample — it goes now.
                        reading.sample = nil
                        reading.history = KubeUsageHistory()
                        self.readings[target] = reading
                        self.polls[target] = nil
                        self.stopped.insert(target)
                        return
                    }
                    self.readings[target] = reading
                }
                count += 1
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Every node's allocatable: the NodeList, paged, read whole for its
    /// `status.allocatable` (the Table's rows don't carry it).
    nonisolated static func allocatable(_ client: KubeClient) async throws -> [String: KubeUsage] {
        var nodes: [String: KubeUsage] = [:]
        var token: String?
        var pages = 0
        repeat {
            let body = try await client.get(KubePath.query("/api/v1/nodes", [("limit", "500"), ("continue", token)])).body
            let page = try KubeMetricsReader.allocatable(body)
            nodes.merge(page.nodes) { $1 }
            token = page.continueToken
            pages += 1
        } while token != nil && pages < 20
        return nodes
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
        guard let sample = reading.sample else { return reading.problem.map { "Usage couldn't be read: \($0)" } }
        let age = now.timeIntervalSince(sample.read)
        if age > staleAfter { return "Usage not read for \(KubeMetricsFormat.age(age))" + (reading.problem.map { ": \($0)" } ?? "") }
        if let oldest = sample.oldest, now.timeIntervalSince(oldest) > oldAfter {
            return "Usage sampled \(KubeMetricsFormat.age(now.timeIntervalSince(oldest))) ago"
        }
        return nil
    }
}
