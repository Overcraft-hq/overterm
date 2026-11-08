import Foundation

/// What a Prometheus query goes through: the context's metrics proxy, or
/// (a test's, the scenario's without kubectl) a connection spoken to
/// directly — either way only the Service's two query paths.
protocol KubePrometheusTransport: Sendable {
    func query(_ path: String) async throws -> HTTPResponse
}

/// The context's metrics proxy (`KubeProxies.sendPrometheus`).
struct KubePrometheusProxyConnection: KubePrometheusTransport {
    let proxies: KubeProxies
    let context: KubeContext
    let service: KubePrometheusService
    var role: KubeProxies.Role = .page

    func query(_ path: String) async throws -> HTTPResponse {
        try await proxies.sendPrometheus(context, service, role: role, path)
    }
}

/// A connection spoken to directly, as the metrics proxy would let it
/// through: any other path is refused here.
struct KubePrometheusDirect: KubePrometheusTransport {
    let connection: any KubeConnection
    let service: KubePrometheusService

    func query(_ path: String) async throws -> HTTPResponse {
        guard service.allows(path) else { throw KubePrometheusRefused(path: path) }
        return try await connection.get(path, headers: [("Accept", "application/json")])
    }
}

/// A PVC list's usage, by claim: one instant read of kubelet's volume stats.
struct KubeVolumeReading: Equatable, Sendable {
    var scope: KubeScope
    var usage: [KubeRowID: KubeVolumeUsage] = [:]
    var read: Date?
    var problem: String?
}

/// Prometheus for the context the page shows (stage 4; analysis 2.1,
/// 2.11, 2.17, Section 4, decision 16) — the model's, as
/// `KubeMetricsMonitor` is. Opt-in per context (`KubePrometheusUse`), and
/// read only while something on screen wants it: a chart (the Overview's
/// cluster, a pod's, a claim's, each over `range`) or the PVC list's
/// column. Nothing wanted, nothing is asked — not even where Prometheus
/// is — and the context's metrics proxy is closed (it runs only while a
/// chart shows).
///
/// Where Prometheus is: the context's `prometheus` setting, else found
/// once (for the context, until its setting or the kubeconfig changes) by
/// Freelens's selectors through the context's own proxy. The queries go
/// through its metrics proxy, the `query_range` of the range picked
/// (start, end, step) for a chart, `query` for totals and the column;
/// each asked again as often as the range adds a point. A failure is said
/// where the chart is; a credential failure ends the reading (no retry
/// runs the plugin again) until `retry`.
@MainActor
final class KubePrometheusMonitor: ObservableObject {
    struct Situation: Equatable {
        var context: String
        var use: KubePrometheusUse
        var scope: KubeScope
        /// Which cluster, as which user, the kubeconfig says the context
        /// is: another, and where Prometheus is is looked for again.
        var cluster = ""
    }

    /// Where Prometheus was found for a context — the use and the cluster
    /// it was looked for with. Kept while the page hides (nothing paid per
    /// show); another use or cluster and it is looked for again.
    private struct Found {
        var use: KubePrometheusUse
        var cluster: String
        var state: KubePrometheusState
    }

    enum Want: Hashable {
        case chart(KubeChart)
        /// The PVC list's column, in the scope shown.
        case volumes
        /// The Pods list's shares of request and limit (wide), in the scope
        /// shown: kube-state-metrics a namespace at a time (metrics.md 2.1).
        case shares
    }

    /// The range every chart shows (the picker's): the app's.
    @Published var range: KubeChartRange = .hour {
        didSet { if range != oldValue { restartCharts() } }
    }
    @Published private(set) var state: KubePrometheusState = .off
    @Published private(set) var charts: [KubeChart: KubeChartReading] = [:]
    @Published private(set) var volumes: KubeVolumeReading?
    @Published private(set) var shares: KubeShareReading?
    /// Instead of the range's own refresh (the scenario's, a test's).
    var interval: Duration?
    var volumeInterval: Duration = .seconds(60)
    /// The shares' requests and limits change only with a rollout: every 5 min.
    var shareInterval: Duration = .seconds(300)
    /// How many Prometheus queries were made, and lookups for it — the tests'.
    private(set) var requests = 0
    private(set) var detections = 0

    private var wanted: [ObjectIdentifier: Set<Want>] = [:]
    private var situation: Situation?
    private var client: () -> KubeClient? = { nil }
    private var transport: (KubePrometheusService) -> (any KubePrometheusTransport)? = { _ in nil }
    private var closeProxy: (String) -> Void = { _ in }
    private var detecting: Task<Void, Never>?
    private var polls: [Want: Task<Void, Never>] = [:]
    private var found: [String: Found] = [:]
    /// What each context's Prometheus holds (`KubePromProfile`), kept with
    /// what it was asked of: another Service, use or cluster, asked again.
    private struct Profiled {
        var key: ProfileKey
        var profile: KubePromProfile
    }
    private struct ProfileKey: Equatable {
        var service: KubePrometheusService
        var use: KubePrometheusUse
        var cluster: String
    }
    private var profiles: [String: Profiled] = [:]
    private var probing: [String: Task<Result<KubePromProfile, Error>, Never>] = [:]
    /// The context's queue (`KubePromQueue`), kept with what it asks — the
    /// Service, the use, the cluster and user: another of any, another
    /// queue, so one stopped by a credential or a 403 isn't kept when the
    /// kubeconfig changes them; a sign-in (`retry`) makes every one again.
    private var queues: [String: (key: ProfileKey, queue: KubePromQueue)] = [:]
    /// The profile of the context shown, once asked (the page's, the dump's).
    @Published private(set) var profile: KubePromProfile?
    /// How many times a profile was asked for (the tests').
    private(set) var probes = 0
    /// Whether a query has gone out since the metrics proxy was last closed.
    private var proxyUsed = false
    private var stopped = false

    /// What `owner` shows now that needs Prometheus; empty, nothing.
    func want(_ wants: Set<Want>, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        guard (wanted[id] ?? []) != wants else { return }
        wanted[id] = wants.isEmpty ? nil : wants
        reconcile()
    }

    /// Where Prometheus is read now; nil: nowhere.
    func update(
        _ situation: Situation?, client: @escaping () -> KubeClient?,
        transport: @escaping (KubePrometheusService) -> (any KubePrometheusTransport)?, close: @escaping (String) -> Void
    ) {
        self.client = client
        self.transport = transport
        guard situation != self.situation else { return }
        let old = self.situation
        if situation?.context != old?.context || situation?.use != old?.use || situation?.cluster != old?.cluster {
            endReading()
            detecting?.cancel()
            detecting = nil
            let kept = situation.flatMap(known)
            if state != kept ?? .off { state = kept ?? .off }
            stopped = false
            let shown = situation.flatMap { profiles[$0.context] }.flatMap { $0.key.use == situation?.use && $0.key.cluster == situation?.cluster ? $0.profile : nil }
            if profile != shown { profile = shown }
        } else if situation?.scope != old?.scope {
            // Another namespace's claims, its pods' shares.
            if let task = polls.removeValue(forKey: .volumes) {
                task.cancel()
                volumes = nil
            }
            if let task = polls.removeValue(forKey: .shares) {
                task.cancel()
                shares = nil
            }
        }
        self.closeProxy = close
        self.situation = situation
        reconcile()
    }

    /// Whether the use is on and wanted: what reads at all.
    var wants: Set<Want> { wanted.values.reduce(into: Set<Want>()) { $0.formUnion($1) } }

    var isPolling: Bool { !polls.isEmpty }
    /// Whether this context's Prometheus is on (charts get a range picker).
    var isOn: Bool { situation?.use.isOn == true }
    var service: KubePrometheusService? { state.service }

    /// After a sign-in: what a credential failure stopped is read again.
    func retry() {
        guard stopped || state != .off else { return }
        stopped = false
        // A queue stopped by a credential or a 403 is made again — any context's.
        queues = [:]
        if case .unavailable = state {
            state = .off
            if let context = situation?.context { found[context] = nil }
        }
        reconcile()
    }

    /// What was found for the situation's context, when it was looked for
    /// with this use and cluster; another, forgotten.
    private func known(_ situation: Situation) -> KubePrometheusState? {
        guard let kept = found[situation.context] else { return nil }
        guard kept.use == situation.use, kept.cluster == situation.cluster else {
            found[situation.context] = nil
            return nil
        }
        return kept.state
    }

    private func reconcile() {
        guard let situation, situation.use.isOn, !wants.isEmpty, !stopped else {
            endReading()
            return
        }
        guard let service = state.service else {
            detect(situation)
            return
        }
        let wanted = wants
        for (want, task) in polls where !wanted.contains(want) {
            task.cancel()
            polls[want] = nil
            switch want {
            case .chart(let chart): charts[chart] = nil
            case .volumes: volumes = nil
            case .shares: shares = nil
            }
        }
        for want in wanted where polls[want] == nil {
            polls[want] = poll(want, service: service, context: situation.context)
        }
    }

    /// Every reading ended, what was read dropped, the metrics proxy closed
    /// — once the readings have stopped: a query already on its way could
    /// open it again after a close sent at once, and nothing would close
    /// it then. Unless reading began again meanwhile (its proxy then).
    private func endReading() {
        let ended = Array(polls.values) + probing.values.map { probe in Task { _ = await probe.value } }
        for task in polls.values { task.cancel() }
        for probe in probing.values { probe.cancel() }
        probing = [:]
        polls = [:]
        if !charts.isEmpty { charts = [:] }
        if volumes != nil { volumes = nil }
        if shares != nil { shares = nil }
        if proxyUsed, let context = situation?.context {
            proxyUsed = false
            let close = closeProxy
            closing += 1
            Task { [weak self] in
                for task in ended { await task.value }
                if let self {
                    self.closing -= 1
                    guard !self.proxyUsed || self.situation?.context != context else { return }
                }
                close(context)
            }
        }
    }

    /// Closes waiting for their readings to stop (the tests').
    private(set) var closing = 0

    private func restartCharts() {
        for (want, task) in polls {
            guard case .chart = want else { continue }
            task.cancel()
            polls[want] = nil
        }
        reconcile()
    }

    // MARK: Where it is

    private func detect(_ situation: Situation) {
        switch situation.use {
        case .off: return
        case .invalid(let why):
            state = .unavailable(why)
            return
        case .configured(let service):
            state = .found(service, nil)
            reconcile()
            return
        case .detect: break
        }
        guard detecting == nil, state == .off else { return }
        guard let client = client() else {
            state = .unavailable("The context isn't connected.")
            return
        }
        state = .detecting
        detections += 1
        let context = situation.context
        detecting = Task { [weak self] in
            let (found, lasting) = await Self.look(client)
            guard !Task.isCancelled, let self, let now = self.situation, now.context == context else { return }
            self.detecting = nil
            self.state = found
            // Kept for the next show — not a failure to ask, which is asked again.
            if lasting { self.found[context] = Found(use: now.use, cluster: now.cluster, state: found) }
            if case .unavailable = found { return }
            self.reconcile()
        }
    }

    /// Freelens's providers in order, each one GET through the context's
    /// own proxy: the first Service found. A refusal is said with the
    /// rest; a credential failure ends the search.
    nonisolated static func find(_ client: KubeClient) async -> KubePrometheusState { await look(client).state }

    /// `find`, and whether its answer lasts (found, not found, refused) or
    /// was a failure to ask — the proxy's, the network's.
    nonisolated static func look(_ client: KubeClient) async -> (state: KubePrometheusState, lasting: Bool) {
        var refused: [String] = []
        for provider in KubePrometheusProvider.allCases {
            do {
                let response = try await client.get(provider.path)
                if let service = provider.service(in: response.body) { return (.found(service, provider), true) }
            } catch let api as KubeAPIError where api.status == 404 {
                continue
            } catch let api as KubeAPIError where api.isForbidden {
                let what = provider == .lens ? "lens-metrics' Services" : "Services across namespaces"
                if !refused.contains(what) { refused.append(what) }
            } catch let problem as KubeProxyProblem {
                return (.unavailable(problem.reason), false)
            } catch {
                return (.unavailable("Prometheus couldn't be looked for: \(KubernetesModel.said(error))"), false)
            }
        }
        if !refused.isEmpty {
            return (
                .unavailable(
                    "No Prometheus found, and the cluster refused listing \(refused.joined(separator: " and ")). Name it in the context's prometheus setting (namespace/service:port)."
                ), true
            )
        }
        return (.unavailable(KubePrometheusState.notFound), true)
    }

    // MARK: Reading

    private func poll(_ want: Want, service: KubePrometheusService, context: String) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let transport = self.transport(service) else {
                    // Kubernetes off, the context missing while the kubeconfig is read again: tried again.
                    try? await Task.sleep(for: self.interval ?? .seconds(5))
                    continue
                }
                self.proxyUsed = true
                let pause: Duration
                switch want {
                case .chart(let chart):
                    let range = self.range
                    let reading = await self.read(chart, range: range, transport, service: service, context: context)
                    guard !Task.isCancelled, self.polls[want] != nil, self.situation?.context == context else { return }
                    self.charts[chart] = reading
                    pause = self.interval ?? range.refresh
                case .volumes:
                    let scope = self.situation?.scope ?? .all
                    let reading = await self.readVolumes(scope, transport, service: service)
                    guard !Task.isCancelled, self.polls[want] != nil, self.situation?.context == context else { return }
                    self.volumes = reading
                    pause = self.interval ?? self.volumeInterval
                case .shares:
                    let scope = self.situation?.scope ?? .all
                    let reading = await self.readShares(scope, transport, service: service, context: context)
                    guard !Task.isCancelled, self.polls[want] != nil, self.situation?.context == context else { return }
                    self.shares = reading
                    pause = self.interval ?? self.shareInterval
                }
                if self.stopped {
                    self.polls[want] = nil
                    return
                }
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// One query, through the context's queue: none once its reading was
    /// cancelled (the chart hidden), its answer read off the main thread.
    private func ask(
        _ transport: any KubePrometheusTransport, _ path: String, context: String, service: KubePrometheusService, order: Int = 0
    ) async throws -> KubePrometheusReader.Answer {
        try Task.checkCancellation()
        requests += 1
        let answer = try await queue(context, service).ask(path, via: transport, priority: .visible, order: order, deadline: deadline)
        try Task.checkCancellation()
        return answer
    }

    /// The context's queue for `service`, as the situation now reads it:
    /// another Service, use, cluster or user, another queue.
    func queue(_ context: String, _ service: KubePrometheusService) -> KubePromQueue {
        let shown = situation?.context == context ? situation : nil
        return queue(context, ProfileKey(service: service, use: shown?.use ?? .off, cluster: shown?.cluster ?? ""))
    }

    private func queue(_ context: String, _ key: ProfileKey) -> KubePromQueue {
        let service = key.service
        if let kept = queues[context], kept.key == key { return kept.queue }
        let queue = KubePromQueue(service: service)
        queues[context] = (key, queue)
        return queue
    }

    /// What the context's Prometheus holds: kept, or asked once — every
    /// chart that wants it meanwhile waits for the one probe (metrics.md, 4.4).
    private func profile(
        _ context: String, _ service: KubePrometheusService, _ transport: any KubePrometheusTransport
    ) async -> Result<KubePromProfile, Error> {
        guard let situation, situation.context == context else { return .failure(CancellationError()) }
        let key = ProfileKey(service: service, use: situation.use, cluster: situation.cluster)
        if let kept = profiles[context], kept.key == key, !kept.profile.isStale(at: Date()) { return .success(kept.profile) }
        if let probe = probing[context] { return await probe.value }
        probes += 1
        let probe = Task { () -> Result<KubePromProfile, Error> in
            do {
                let profile = try await KubePromProfile.probe(at: Date()) { query in
                    try await self.ask(transport, KubePromQL.instantPath(service, query), context: context, service: service, order: -1)
                }
                return .success(profile)
            } catch {
                return .failure(error)
            }
        }
        probing[context] = probe
        let result = await probe.value
        if probing[context] == probe { probing[context] = nil }
        if case .success(let profile) = result, let now = self.situation, now.context == context, now.use == key.use, now.cluster == key.cluster {
            profiles[context] = Profiled(key: key, profile: profile)
            if self.profile != profile { self.profile = profile }
        }
        return result
    }

    /// The profile forgotten, as an hour passing would (the scenario's, a test's): asked again by the next chart.
    func forgetProfile() {
        guard let context = situation?.context else { return }
        profiles[context] = nil
    }

    /// How long an answer is waited for: Prometheus' own `timeout` and a
    /// few seconds more (a test's shorter).
    var deadline: Duration = KubePromQL.deadline

    /// The query and its answer read, given up past `deadline` (the query
    /// cancelled, said as Prometheus' own timeout is).
    nonisolated static func fetch(_ transport: any KubePrometheusTransport, _ path: String, deadline: Duration) async throws
        -> KubePrometheusReader.Answer
    {
        try await withThrowingTaskGroup(of: KubePrometheusReader.Answer?.self) { group in
            group.addTask { @Sendable in
                let response = try await transport.query(path)
                return try KubePrometheusReader.answer(response)
            }
            group.addTask { @Sendable in
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else {
                try Task.checkCancellation()
                throw KubePrometheusReader.Failure(message: KubePrometheusReader.tookTooLong)
            }
            return answer
        }
    }

    private func said(_ error: Error, service: KubePrometheusService? = nil) -> String {
        let (sentence, stops) = Self.sentence(error, service: service)
        if stops { stopped = true }
        return sentence
    }

    /// A failure said, and whether it stops the reading (a credential, the queue stopped, a `services/proxy` 403).
    private nonisolated static func sentence(_ error: Error, service: KubePrometheusService?) -> (String, stops: Bool) {
        if let problem = error as? KubeProxyProblem, problem.stopsRequests {
            return (KubeChartEmpty.credential(problem.reason).sentence, true)
        }
        if let stop = error as? KubePromQueue.Stopped {
            return (stop.reason, true)
        }
        if let failure = error as? KubePrometheusReader.Failure, failure.kind == .serviceProxyForbidden {
            return (service.map { KubeChartEmpty.serviceProxyForbidden($0).sentence } ?? failure.message, true)
        }
        return (KubernetesModel.said(error), false)
    }

    private func read(
        _ chart: KubeChart, range: KubeChartRange, _ transport: any KubePrometheusTransport, service: KubePrometheusService, context: String
    ) async -> KubeChartReading {
        var reading = charts[chart].flatMap { $0.range == range ? $0 : nil } ?? KubeChartReading(range: range)
        // What the context's Prometheus holds decides the tier, the pins and the rate window.
        var profile = KubePromProfile.unknown
        if chart.needsProfile {
            switch await self.profile(context, service, transport) {
            case .success(let probed): profile = probed
            case .failure(let error):
                if error is CancellationError || Task.isCancelled { return reading }
                reading.notes = []
                reading.problem = said(error, service: service)
                return reading
            }
            if profile.agentOnly {
                reading.series = [:]
                reading.totals = [:]
                reading.notes = []
                reading.problem = nil
                reading.unavailable = KubeChartEmpty.agentMode(service).sentence
                reading.read = Date()
                return reading
            }
        }
        reading.unavailable = nil
        let queries = chart.queries(range: range, profile: profile)
        let order = chart.order
        let now = Date()
        var notes: [String] = queries.notes
        if chart.needsProfile, let kept = profile.retention, kept > range.window(now: now).start { notes.append(KubeChartEmpty.retention(kept).sentence) }
        do {
            for (measure, query) in queries.series {
                let answer = try await ask(transport, KubePromQL.rangePath(service, query, range, now: now), context: context, service: service, order: order)
                reading.series[measure] = KubePrometheusReader.points(answer.series)
                notes += answer.notes
            }
            for (measure, query) in queries.totals {
                let answer = try await ask(transport, KubePromQL.instantPath(service, query), context: context, service: service, order: order)
                reading.totals[measure] = KubePrometheusReader.value(answer.series)
                notes += answer.notes
            }
            if queries.totals.isEmpty { reading.totals = [:] }
            reading.refused = queries.refused
            if queries.refused != nil { reading.series = [:] }
            reading.tier = queries.tier
            reading.caption = KubeChartReading.caption(queries.tier, chart: chart, profile: profile)
            reading.retention = chart.needsProfile ? profile.retention : nil
            // Three at most for the chart, however many of its queries spoke.
            var seen = Set<String>()
            reading.notes = Array(notes.filter { seen.insert($0).inserted }.prefix(KubePrometheusReader.maxNotes))
            reading.read = now
            reading.problem = nil
        } catch is CancellationError {
        } catch {
            // A 404 or a 422: what the server holds may have changed — asked again.
            if let failure = error as? KubePrometheusReader.Failure, failure.kind == .notFound || failure.kind == .unprocessable {
                profiles[context] = nil
            }
            // The last good read's notes don't belong beside a new problem.
            reading.notes = []
            reading.problem = said(error, service: service)
        }
        return reading
    }

    private func readVolumes(_ scope: KubeScope, _ transport: any KubePrometheusTransport, service: KubePrometheusService) async -> KubeVolumeReading {
        var reading = volumes.flatMap { $0.scope == scope ? $0 : nil } ?? KubeVolumeReading(scope: scope)
        // The namespaces picked: one, several (a regex of them), or every one.
        let names = scope.names
        do {
            let context = situation?.context ?? ""
            let used = try await ask(
                transport, KubePromQL.instantPath(service, KubePromQL.volumes(KubePromQL.volumeUsed, namespaces: names)), context: context, service: service,
                order: 9)
            let capacity = try await ask(
                transport, KubePromQL.instantPath(service, KubePromQL.volumes(KubePromQL.volumeCapacity, namespaces: names)), context: context,
                service: service, order: 9)
            reading.usage = KubeVolumeUsage.by(used: used.series, capacity: capacity.series)
            reading.read = Date()
            reading.problem = nil
        } catch is CancellationError {
        } catch {
            reading.problem = said(error, service: service)
        }
        return reading
    }

    /// The Pods list's shares: for each namespace picked, one instant
    /// query of kube-state-metrics (`KubePodShares.query`), after the
    /// profile (its job pin, its version) — none across every namespace,
    /// which is said instead. A namespace that fails keeps its last answer.
    private func readShares(
        _ scope: KubeScope, _ transport: any KubePrometheusTransport, service: KubePrometheusService, context: String
    ) async -> KubeShareReading {
        var reading = shares.flatMap { $0.scope == scope ? $0 : nil } ?? KubeShareReading(scope: scope)
        guard let names = scope.names, names.count <= KubeScope.watchCap else {
            reading.unavailable = KubeChartEmpty.sharesNeedNamespaces.sentence
            return reading
        }
        let profile: KubePromProfile
        switch await self.profile(context, service, transport) {
        case .success(let probed): profile = probed
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { return reading }
            reading.unavailable = said(error, service: service)
            return reading
        }
        if profile.agentOnly {
            reading.unavailable = KubeChartEmpty.agentMode(service).sentence
            return reading
        }
        if profile.ksmMissing {
            reading.unavailable = KubeChartEmpty.sharesNeedKSM.sentence
            return reading
        }
        reading.unavailable = nil
        for (index, namespace) in names.enumerated() {
            do {
                let answer = try await ask(
                    transport, KubePromQL.instantPath(service, KubePodShares.query(namespace: namespace, profile: profile)), context: context,
                    service: service, order: 10 + index)
                reading.take(answer.series, namespace: namespace)
            } catch is CancellationError {
                return reading
            } catch {
                reading.problems[namespace] = said(error, service: service)
                if stopped { break }
            }
        }
        reading.read = Date()
        return reading
    }

    // MARK: An agent's

    /// What `agentShares` found.
    enum AgentShares: Equatable {
        /// The context's Prometheus isn't opted in: nothing asked.
        case off
        case unavailable(String)
        case read(KubeShareReading)
    }

    /// Which cluster, as which user, a context is (`Situation.cluster`).
    nonisolated static func cluster(of context: KubeContext) -> String {
        [context.server ?? "", context.cluster, context.user].joined(separator: "\n")
    }

    /// `k8s_top`'s shares across namespaces (metrics.md 7): the list's
    /// kube-state-metrics query (`KubePodShares.query`) for each of
    /// `namespaces` (at most `KubeScope.watchCap`), once, for the call —
    /// whether or not the page shows the context. Only where its
    /// Prometheus is opted in (`.off` otherwise, nothing asked); where it
    /// is, as the page found it or found now through `client` (GETs);
    /// asked through `transport` — the context's metrics proxy in a
    /// background slot (§6.4's exception for an agent's explicit read) —
    /// and the context's queue as an agent: below the page, at most two
    /// of its places. Kept: where Prometheus is and its profile, as the
    /// page's are; the answer is the caller's. A failure here never stops
    /// the page's reading.
    func agentShares(
        _ context: KubeContext, namespaces: [String], client: KubeClient, transport: (KubePrometheusService) -> (any KubePrometheusTransport)?
    ) async -> AgentShares {
        let use = KubePrometheusUse.of(context.settings)
        let name = context.name
        let cluster = Self.cluster(of: context)
        let service: KubePrometheusService
        switch use {
        case .off: return .off
        case .invalid(let why): return .unavailable(why)
        case .configured(let configured): service = configured
        case .detect:
            let shown = situation.map { $0.context == name && $0.use == use && $0.cluster == cluster } == true ? state.service : nil
            let kept = known(Situation(context: name, use: use, scope: .all, cluster: cluster))
            if let found = shown ?? kept?.service {
                service = found
            } else if case .unavailable(let why)? = kept {
                return .unavailable(why)
            } else {
                detections += 1
                let (looked, lasting) = await Self.look(client)
                if lasting { found[name] = Found(use: use, cluster: cluster, state: looked) }
                guard let found = looked.service else {
                    if case .unavailable(let why) = looked { return .unavailable(why) }
                    return .unavailable(KubePrometheusState.notFound)
                }
                service = found
            }
        }
        guard let transport = transport(service) else { return .unavailable("The context isn't connected.") }
        let key = ProfileKey(service: service, use: use, cluster: cluster)
        let profile: KubePromProfile
        if let kept = profiles[name], kept.key == key, !kept.profile.isStale(at: Date()) {
            profile = kept.profile
        } else {
            probes += 1
            do {
                profile = try await KubePromProfile.probe(at: Date()) { query in
                    try await self.agentAsk(transport, KubePromQL.instantPath(service, query), context: name, key: key)
                }
            } catch {
                return .unavailable(Self.sentence(error, service: service).0)
            }
            profiles[name] = Profiled(key: key, profile: profile)
            if let now = situation, now.context == name, now.use == use, now.cluster == cluster, self.profile != profile { self.profile = profile }
        }
        if profile.agentOnly { return .unavailable(KubeChartEmpty.agentMode(service).sentence) }
        if profile.ksmMissing { return .unavailable(KubeChartEmpty.sharesNeedKSM.sentence) }
        let asked = Array(namespaces.prefix(KubeScope.watchCap))
        var reading = KubeShareReading(scope: KubeScope.of(asked))
        for namespace in asked {
            do {
                let answer = try await agentAsk(
                    transport, KubePromQL.instantPath(service, KubePodShares.query(namespace: namespace, profile: profile)), context: name, key: key)
                reading.take(answer.series, namespace: namespace)
            } catch {
                let (sentence, stops) = Self.sentence(error, service: service)
                reading.problems[namespace] = sentence
                if stops || error is CancellationError { break }
            }
        }
        reading.read = Date()
        return .read(reading)
    }

    /// One query of an agent's, through the context's queue as an agent's.
    private func agentAsk(
        _ transport: any KubePrometheusTransport, _ path: String, context: String, key: ProfileKey
    ) async throws -> KubePrometheusReader.Answer {
        try Task.checkCancellation()
        requests += 1
        return try await queue(context, key).ask(path, via: transport, priority: .visible, asker: .agent, deadline: deadline)
    }

    // MARK: What the page says

    /// The Pods list's shares as last read, where `context` is the one shown (an agent's `k8s_top`).
    func shares(for context: String) -> KubeShareReading? {
        situation?.context == context ? shares : nil
    }

    /// A pod's share cell, its usage given: the namespace's answer, or a dash and why.
    func shareCell(_ column: KubePodShares.Column, _ id: KubeRowID, used: KubeUsage, sampled: Int? = nil) -> KubeUsageCell {
        if case .unavailable(let why) = state { return .dash(why) }
        guard let shares else { return .waiting }
        return shares.cell(column, id, used: used, sampled: sampled)
    }

    /// A claim's column cell: its usage, or a dash and why.
    func volumeCell(_ id: KubeRowID) -> KubeUsageCell {
        if case .unavailable(let why) = state { return .dash(why) }
        guard let reading = volumes else { return .waiting }
        if let usage = reading.usage[id] {
            return .value(usage.text, sort: usage.capacity.map { usage.used / max($0, 1) } ?? usage.used, percent: nil)
        }
        if let problem = reading.problem { return .dash("Volume usage couldn't be read: \(problem)") }
        if reading.read == nil { return .waiting }
        return .dash("Prometheus has no kubelet_volume_stats for this claim (it is unbound, or no running pod mounts it).")
    }
}
