import Foundation

/// What a workload's, an HPA's, a node's or a namespace's Metrics tab looked
/// up once as it opened (docs/design/kubernetes/metrics.md 2.6, 2.7): the
/// HPA that targets a workload — one HPA Table read in its namespace,
/// matched on its Reference, never repeated while the tab shows — and a
/// namespace's ResourceQuota. Only the detail shown's are kept.
struct KubeChartLookups: Equatable, Sendable {
    /// A workload's HPA: its name, or nil when none targets it.
    var hpa: [KubeObjectRef: String?] = [:]
    var quotas: [KubeObjectRef: KubeQuota] = [:]
    var asked: Set<KubeObjectRef> = []
    /// Changed with each answer: what the charts' cache is keyed by.
    var version = 0

    /// The HPA whose Reference cell names `kind/name` (`Deployment/web`), among a namespace's rows.
    static func hpa(targeting kind: String, _ name: String, in table: KubeTable) -> String? {
        guard let column = table.column(named: "Reference") else { return nil }
        return table.rows.sorted { $0.id < $1.id }.first { row in
            column < row.cells.count && row.cells[column].text == "\(kind)/\(name)"
        }?.id.name
    }
}

/// "Sample top pods" on a node's tab (metrics.md 2.8, decision 8): its
/// largest pods' namespaces read every 30 s for 15 minutes, then "Sample again".
struct KubeTopPodsSampling: Equatable, Sendable {
    var node: String
    var since: Date
    var stopped = false
}

/// What a workload's, HPA's, node's or namespace's Metrics tab charts were built from. Pure.
struct KubeObjectChartsKey: Equatable, Sendable {
    var ref: KubeObjectRef
    var resourceVersion: String?
    var bytes: Int
    var now: Date
    var range: KubeMetricsRange
    var view: KubeWorkloadView?
    var lookups: Int
    var revisions: Int
    var topPods: KubeTopPodsSampling?
    var reads: [Date]
    var changes: Int
    var window: KubeChartWindow?
    var source: KubeChartSource = .sampled
    /// Prometheus' answers' version (`KubeTabReading.version`).
    var prometheus: Int?
}

/// The Metrics tab beyond pods (stage M3b): a workload's CPU and memory as
/// a total or by pod against its template, by revision and its replicas;
/// an HPA's replicas and metrics; a node's usage against its pods'
/// requests, its allocatable and capacity, its pods, its pressure; a
/// namespace's usage by workload against its quota and its pods by phase.
/// Each reads only while its tab shows (`metricsDetailsOnScreen`), its
/// samples kept in the ring and its objects' numbers in the status
/// history, an hour after.
extension KubernetesPageModel {
    /// A node's tab samples its largest pods' namespaces for this long ("Sample top pods").
    static let topPodsNamespaces = 4

    /// What a tab other than a pod's reads now: nothing until the object is
    /// read where its selector is needed.
    func objectMetricsDetails(_ session: KubeDetailSession) -> [KubeMetricsDetail] {
        let ref = session.ref
        // Without metrics-server only an HPA's tab charts anything (its
        // status): the others read nothing they wouldn't draw.
        if ref.metricsSubject != .hpa, model.metrics.availability != .served { return [] }
        switch ref.metricsSubject {
        case .workload(let kind):
            guard let namespace = ref.namespace else { return [] }
            var details: [KubeMetricsDetail] = [.replicas(namespace: namespace, kind: kind, name: ref.name, path: ref.kind.path(namespace: namespace, name: ref.name))]
            if let pods = session.overview?.pods, !pods.selector.isEmpty {
                details.insert(.workload(namespace: namespace, kind: kind, name: ref.name, labels: pods.selector), at: 0)
            }
            if let hpa = chartLookups.hpa[ref] ?? nil { details.append(.hpa(namespace: namespace, name: hpa)) }
            return details
        case .hpa:
            guard let namespace = ref.namespace else { return [] }
            return [.hpa(namespace: namespace, name: ref.name)]
        case .node:
            var details: [KubeMetricsDetail] = [.node(ref.name), .nodePods(ref.name)]
            if let top = topPodsDetail(node: ref.name) { details.append(top) }
            return details
        case .namespace:
            return [.namespace(ref.name), .namespacePods(ref.name)]
        case .pod, nil:
            return []
        }
    }

    /// "Sample top pods", while on: its largest pods' namespaces (at most
    /// four), unless the page's list already samples every namespace's pods.
    private func topPodsDetail(node: String) -> KubeMetricsDetail? {
        guard let sampling = topPodsSampling, sampling.node == node, !sampling.stopped, !topPodsFromList,
            let pods = model.metrics.reading(.nodePods(node))?.sample?.nodePods
        else { return nil }
        let picked = Self.topPodsPicked(pods)
        let namespaces = Set(picked.compactMap(\.namespace))
        guard !namespaces.isEmpty else { return nil }
        return .nodeTopPods(node: node, namespaces: namespaces.sorted(), pods: picked.map(\.name).sorted())
    }

    /// The largest pods "Sample top pods" reads: those of the first four
    /// namespaces among them — a pod of a fifth isn't sampled, so isn't drawn. Pure.
    static func topPodsPicked(_ pods: KubeNodePods) -> [KubeRowID] {
        var namespaces: [String] = []
        var picked: [KubeRowID] = []
        for pod in pods.largest(KubeNodeCharts.topPods) {
            guard let namespace = pod.id.namespace else { continue }
            if !namespaces.contains(namespace) {
                guard namespaces.count < topPodsNamespaces else { continue }
                namespaces.append(namespace)
            }
            picked.append(pod.id)
        }
        return picked
    }

    /// The page's own list samples every namespace's pods already: the top pods are read from it.
    var topPodsFromList: Bool { model.metrics.listTargets.contains(.pods(.all, labels: nil)) }

    /// "Sample top pods" pressed (or "Sample again"): read for 15 minutes, then stopped.
    func sampleTopPods() {
        guard let ref = detail?.ref, ref.metricsSubject == .node else { return }
        topPodsSampling = KubeTopPodsSampling(node: ref.name, since: Date())
        topPodsStop?.cancel()
        let duration = topPodsDuration
        topPodsStop = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.topPodsSampling?.stopped = true
            self.updateMetricsWanted()
        }
        updateMetricsWanted()
    }

    /// What the tab's button says.
    var topPodsTitle: String {
        guard let sampling = topPodsSampling, sampling.node == detail?.ref.name else { return "Sample Top Pods" }
        if sampling.stopped { return "Sample Again" }
        return "Sampling top pods until \(KubeChartTime.clock(sampling.since.addingTimeInterval(Double(topPodsDuration.components.seconds))))"
    }

    /// Picked Total or Per pod on a workload's charts: for the page, in memory.
    func pickWorkloadView(_ view: KubeWorkloadView) {
        if workloadChartView != view { workloadChartView = view }
    }

    /// What the tab looks up once as it opens: a workload's HPA, its
    /// revisions (the History tab's reads, once), a namespace's quota —
    /// only where the tab charts them (metrics on, metrics-server serving),
    /// and marked asked only once the read is started (else asked again).
    func askChartLookups() {
        guard visible, windowVisible, section.listsKinds, model.selected?.settings.metrics != KubeMetricsSource.none, metricsTabShows,
            model.metrics.availability == .served || chartsFromPrometheus, let session = detail, !chartLookups.asked.contains(session.ref)
        else { return }
        let ref = session.ref
        guard let subject = ref.metricsSubject, let client = model.client(for: ref.context) else { return }
        switch subject {
        case .workload(let kind):
            // Discovery not read yet: asked again once it is.
            guard let namespace = ref.namespace, let discovery = model.knownDiscovery(of: ref.context) else { return }
            keepChartLookups(of: ref)
            if ["Deployment", "StatefulSet", "DaemonSet"].contains(kind) { session.showHistory() }
            guard let hpaKind = discovery.kind(apiVersion: "autoscaling/v2", kind: "HorizontalPodAutoscaler") else {
                chartLookups.hpa[ref] = .some(nil)
                return
            }
            Task { [weak self] in
                let table = try? await client.list(hpaKind, in: .namespace(namespace))
                guard let self else { return }
                self.chartLookups.hpa[ref] = table.flatMap { KubeChartLookups.hpa(targeting: kind, ref.name, in: $0) }
                self.chartLookups.version += 1
                self.updateMetricsWanted()
            }
        case .namespace:
            keepChartLookups(of: ref)
            Task { [weak self] in
                let body = try? await client.get("/api/v1/namespaces/\(KubePath.segment(ref.name))/resourcequotas").body
                guard let self else { return }
                self.chartLookups.quotas[ref] = body.map(KubeQuota.read) ?? KubeQuota()
                self.chartLookups.version += 1
            }
        default:
            break
        }
    }

    /// Only the detail shown's lookups are kept; `ref`'s marked asked.
    private func keepChartLookups(of ref: KubeObjectRef) {
        chartLookups.asked = chartLookups.asked.filter { $0 == ref }
        chartLookups.hpa = chartLookups.hpa.filter { $0.key == ref }
        chartLookups.quotas = chartLookups.quotas.filter { $0.key == ref }
        chartLookups.asked.insert(ref)
    }

    /// The tab's charts for a workload, an HPA, a node, a namespace: built
    /// only when what they are built from changes (`KubeObjectChartsKey`).
    func objectCharts(of session: KubeDetailSession) -> KubeObjectCharts? {
        let ref = session.ref
        guard let subject = ref.metricsSubject, subject != .pod, let object = session.object, let source = metricsSource(of: ref) else { return nil }
        let details = source == .prometheus ? [] : objectMetricsDetails(session)
        let reads = details.map { model.metrics.reading($0)?.sample?.read ?? .distantPast }
        let now = reads.filter { $0 != .distantPast }.max() ?? Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 15).rounded(.down) * 15)
        let range = shownMetricsRange(for: subject)
        let templates = session.timeline?.templates ?? []
        let changes = chartChanges(of: session)
        let window = metricsWindow
        let reading = source == .sampled ? nil : tabReading(of: session)
        let key = KubeObjectChartsKey(
            ref: ref, resourceVersion: object.resourceVersion, bytes: object.data.count, now: source == .prometheus ? .distantPast : now, range: range,
            view: workloadChartView, lookups: chartLookups.version, revisions: templates.count, topPods: topPodsSampling, reads: reads, changes: changes.version,
            window: window, source: source, prometheus: reading?.version)
        if let cached = objectChartsCache, cached.key == key { return cached.charts }
        let built = buildObjectCharts(session, subject: subject, object: object, source: source, reading: reading, details: details, now: now, range: range)
        objectChartsCache = (key, built)
        objectChartsBuilds += 1
        return built
    }

    /// What `objectCharts` builds: from Prometheus, sampled, or both.
    private func buildObjectCharts(
        _ session: KubeDetailSession, subject: KubeMetricsSubject, object: KubeObject, source: KubeChartSource, reading: KubeTabReading?,
        details: [KubeMetricsDetail], now: Date, range: KubeMetricsRange
    ) -> KubeObjectCharts? {
        let ref = session.ref
        let templates = session.timeline?.templates ?? []
        let changes = chartChanges(of: session)
        let window = metricsWindow
        if source == .prometheus {
            guard let reading else { return nil }
            switch subject {
            case .workload(let kind):
                guard let namespace = ref.namespace else { return nil }
                var revisions: [String: String] = [:]
                for template in templates { revisions[template.name] = "rev \(template.revision)" + (template.images.first.map { " (\($0.image))" } ?? "") }
                let hpa = (chartLookups.hpa[ref] ?? nil).map { (name: $0, status: KubeHPAStatus?.none) }
                return KubePromTabCharts.workload(
                    KubeWorkloadCharts.Input(
                        namespace: namespace, kind: kind, name: ref.name, object: object.json, ring: model.metrics.ring, statuses: model.metrics.statuses, pods: [],
                        range: range, now: now, interval: 15, view: workloadChartView, revisions: revisions, hpa: hpa, changes: changes, window: window),
                    reading: reading)
            case .hpa:
                return ref.namespace.map { KubePromTabCharts.hpa(namespace: $0, name: ref.name, reading: reading, changes: changes, window: window) }
            case .node:
                return KubePromTabCharts.node(node: ref.name, facts: KubeNodeFacts.of(object.json), reading: reading, changes: changes, window: window)
            case .namespace, .pod:
                return nil
            }
        }
        let poll = Double(model.metrics.interval.components.seconds) + Double(model.metrics.interval.components.attoseconds) / 1e18
        let resolution = details.compactMap { model.metrics.reading($0)?.sample?.resolution }.max() ?? 0
        let interval = max(15, poll, resolution)
        let metrics = model.metrics
        let charts: KubeObjectCharts?
        switch subject {
        case .workload(let kind):
            guard let namespace = ref.namespace else { return nil }
            let pods = details.first { if case .workload = $0 { true } else { false } }.flatMap { metrics.reading($0)?.sample?.pods.values }.map(Array.init) ?? []
            let hpa = (chartLookups.hpa[ref] ?? nil).map { name in (name: name, status: metrics.reading(.hpa(namespace: namespace, name: name))?.sample?.hpa) }
            var revisions: [String: String] = [:]
            for template in templates {
                let image = template.images.first.map { " (\($0.image))" } ?? ""
                revisions[template.name] = "rev \(template.revision)\(image)"
            }
            charts = KubeWorkloadCharts.build(
                KubeWorkloadCharts.Input(
                    namespace: namespace, kind: kind, name: ref.name, object: object.json, ring: metrics.ring, statuses: metrics.statuses, pods: pods, range: range,
                    now: now, interval: interval, view: workloadChartView, revisions: revisions, hpa: hpa, changes: changes, window: window))
        case .hpa:
            guard let namespace = ref.namespace else { return nil }
            charts = KubeHPACharts.build(
                namespace: namespace, name: ref.name, status: metrics.reading(.hpa(namespace: namespace, name: ref.name))?.sample?.hpa, statuses: metrics.statuses,
                range: range, now: now, interval: interval, changes: changes, window: window)
        case .node:
            let pods = metrics.reading(.nodePods(ref.name))?.sample?.nodePods
            let sampling = topPodsSampling?.node == ref.name ? topPodsSampling : nil
            charts = KubeNodeCharts.build(
                KubeNodeCharts.Input(
                    node: ref.name, facts: KubeNodeFacts.of(object.json), ring: metrics.ring, statuses: metrics.statuses, pods: pods,
                    top: sampling == nil ? nil : pods.map { topPodsFromList ? $0.largest(KubeNodeCharts.topPods).map(\.id) : Self.topPodsPicked($0) },
                    range: range, now: now, interval: interval, changes: changes, window: window))
        case .namespace:
            charts = KubeNamespaceCharts.build(
                KubeNamespaceCharts.Input(
                    namespace: ref.name, ring: metrics.ring, statuses: metrics.statuses, quota: chartLookups.quotas[ref],
                    byOwner: metrics.reading(.namespacePods(ref.name))?.sample?.namespacePods != nil, range: range, now: now, interval: interval,
                    changes: changes, window: window))
        case .pod:
            charts = nil
        }
        if source == .mixed, let built = charts, case .workload(let kind) = subject, let namespace = ref.namespace {
            return KubePromTabCharts.addOnly(
                built, subject: "workload.\(namespace).\(kind.lowercased()).\(ref.name)", reading: reading, changes: changes, namesPods: true)
        }
        return charts
    }

    /// Why a tab other than a pod's has nothing: metrics-server absent (an
    /// HPA's needs none), or its reads refused or failing.
    func objectMetricsProblem(of session: KubeDetailSession) -> String? {
        if let source = metricsSource(of: session.ref), source != .sampled, let reading = tabReading(of: session) {
            if let unavailable = reading.unavailable { return unavailable }
            if source == .prometheus, reading.read == nil, let problem = reading.problem { return "Prometheus couldn't be read: \(problem)" }
        }
        if metricsSource(of: session.ref) == .prometheus { return nil }
        if session.ref.metricsSubject != .hpa, let reason = model.metrics.availability.reason {
            guard model.metrics.availability == .absent else { return reason }
            let prometheus = prometheusOn && KubeChartSource.prometheusCharts(session.ref.metricsSubject ?? .namespace)
            if prometheus, case .unavailable(let why) = model.prometheus.state { return Self.metricsServerAbsent(prometheus: true) + " " + why }
            return Self.metricsServerAbsent(prometheus: prometheus)
        }
        for detail in objectMetricsDetails(session) {
            guard let reading = model.metrics.reading(detail), reading.sample == nil else { continue }
            if let said = reading.refused ?? reading.problem.map({ "Usage couldn't be read: \($0)" }) { return said }
        }
        return nil
    }
}
