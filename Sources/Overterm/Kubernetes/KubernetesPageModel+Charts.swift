import Foundation

/// The detail's Metrics tab (`m`; docs/design/kubernetes/metrics.md, 2.2,
/// stage M3a): a pod's CPU and memory, by container, against what the spec
/// requests and limits — sampled from metrics-server while the tab shows
/// (the pod's own PodMetrics, polled as its Overview's usage is: one GET
/// every 15 s, nothing hidden), kept in the ring an hour after. `,` and `.`
/// step its range; a restart's or an OOMKill's marker opens the previous
/// log, "Logs from Here" the log from a minute before the crosshair.
extension KubernetesPageModel {
    /// The ranges the tab can pick: what was sampled while shown.
    /// Prometheus's own ranges are its Overview chart's until M6.
    var metricsRanges: [KubeMetricsRange] { KubeMetricsRange.sampled }

    /// Why a range can't be picked here.
    func metricsRangeHelp(_ range: KubeMetricsRange) -> String {
        if metricsRanges.contains(range) {
            switch range {
            case .live: return "The last 15 minutes, as metrics-server sampled them"
            default: return "What was sampled while shown, up to 6 hours, in 1-minute buckets"
            }
        }
        return chartsFromPrometheus
            ? "From Prometheus: on the Overview tab's chart"
            : "Needs Prometheus: metrics-server keeps no history, only what Overterm sampled while shown"
    }

    /// Whether the Metrics tab is what shows.
    var metricsTabShows: Bool { detailTab == .metrics && detail?.ref.hasMetrics == true }

    /// `m`: the selected pod's Metrics tab.
    @discardableResult
    func openMetrics() -> Bool {
        if let detail, detail.ref.hasMetrics, selection.isEmpty || ref(for: selection.first ?? "") == detail.ref {
            showTab(.metrics)
            return true
        }
        guard let row = rows.first(where: { selection.contains($0.id) }), let ref = ref(for: row.id), ref.hasMetrics else { return false }
        detailTab = .metrics
        open(ref, from: .list)
        updateLogsReading()
        return true
    }

    /// `,` and `.`: the range before or after, while the Metrics tab shows.
    @discardableResult
    func stepMetricsRange(_ by: Int) -> Bool {
        guard metricsTabShows else { return false }
        let next = metricsRange.stepped(by, among: metricsRanges)
        if next != metricsRange { metricsRange = next }
        return true
    }

    /// A range picked; one that can't be, ignored.
    func pickMetricsRange(_ range: KubeMetricsRange) {
        guard metricsRanges.contains(range), range != metricsRange else { return }
        metricsRange = range
    }

    /// The pod's charts at the range picked: from the ring, at the last
    /// poll's time (the window stands still between polls). Nil without
    /// the object or with metrics-server absent. Built only when what they
    /// are built from changes — the pod's reading's time, the object's
    /// resourceVersion, the range (`KubePodChartsKey`) — never for a row
    /// event or a list's poll that redraws the tab: the object's JSON
    /// parsed and the ring folded for 2 + 2N charts, on the main thread.
    func podCharts(of ref: KubeObjectRef, object: KubeObject?) -> KubePodCharts? {
        guard ref.isPod, let namespace = ref.namespace, let object, model.metrics.availability == .served else { return nil }
        let reading = model.metrics.reading(.pod(namespace: namespace, name: ref.name))
        let now = reading?.sample?.read ?? Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 15).rounded(.down) * 15)
        let poll = Double(model.metrics.interval.components.seconds) + Double(model.metrics.interval.components.attoseconds) / 1e18
        // How far apart samples come: the poll's, or metrics-server's own window when longer.
        let interval = max(15, poll, reading?.sample?.resolution ?? 0)
        let range = metricsRanges.contains(metricsRange) ? metricsRange : .live
        let (charts, built) = KubePodChartsKey.charts(
            ref: ref, object: object, ring: model.metrics.ring, range: range, now: now, interval: interval, cache: &podChartsCache)
        if built { podChartsBuilds += 1 }
        return charts
    }

    /// Why the tab has no charts: metrics-server absent, refused, failing.
    /// Absent with Prometheus on, the pod's Prometheus chart is the
    /// Overview's (until M6): said, with a way there (`metricsTabOffersOverview`).
    func metricsTabProblem(of ref: KubeObjectRef) -> String? {
        if let reason = model.metrics.availability.reason {
            return model.metrics.availability == .absent ? Self.metricsServerAbsent(prometheus: chartsFromPrometheus) : reason
        }
        guard let namespace = ref.namespace, let reading = model.metrics.reading(.pod(namespace: namespace, name: ref.name)) else { return nil }
        return reading.refused ?? reading.problem.map { "Usage couldn't be read: \($0)" }
    }

    /// The tab's words for a cluster without metrics-server: with
    /// Prometheus on, where its chart is instead. Pure.
    nonisolated static func metricsServerAbsent(prometheus: Bool) -> String {
        prometheus
            ? "No metrics-server in this cluster: the Metrics tab's sampled charts need it. The pod's Prometheus chart is on the Overview tab."
            : "No metrics-server in this cluster: there are no usage numbers without it or Prometheus."
    }

    /// The tab offers the Overview: metrics-server absent, Prometheus on.
    var metricsTabOffersOverview: Bool { model.metrics.availability == .absent && chartsFromPrometheus }

    /// A marker clicked: a restart's or an OOMKill's container, its
    /// previous instance's log (the one kubelet keeps).
    func openMarker(_ marker: KubeChartMarker) {
        guard let logs = detail?.logs else { return }
        if let container = marker.container { logs.pick(container: container, previous: true) }
        showTab(.logs)
    }

    /// "Logs from Here": the container's log from a minute before `time`
    /// (`sinceTime`) — a spike's first question is what it logged then.
    func logsFromHere(container: String?, at time: Date) {
        guard let logs = detail?.logs else { return }
        logs.read(from: time.addingTimeInterval(-60), container: container)
        showTab(.logs)
    }
}

/// What a pod's Metrics tab's charts were built from: the same, the same charts. Pure.
struct KubePodChartsKey: Equatable, Sendable {
    var ref: KubeObjectRef
    var resourceVersion: String?
    /// The object's size: a fake or an API server without resourceVersions still changes it.
    var bytes: Int
    var now: Date
    var range: KubeMetricsRange
    var interval: TimeInterval

    /// A pod's charts from `cache` when built from the same, else built —
    /// the object's JSON parsed then, and only then — and kept there.
    @MainActor
    static func charts(
        ref: KubeObjectRef, object: KubeObject, ring: KubeUsageRing, range: KubeMetricsRange, now: Date, interval: TimeInterval,
        cache: inout (key: KubePodChartsKey, charts: KubePodCharts?)?
    ) -> (charts: KubePodCharts?, built: Bool) {
        guard let namespace = ref.namespace else { return (nil, false) }
        let key = KubePodChartsKey(ref: ref, resourceVersion: object.resourceVersion, bytes: object.data.count, now: now, range: range, interval: interval)
        if let cached = cache, cached.key == key { return (cached.charts, false) }
        let charts = KubePodCharts.build(namespace: namespace, pod: ref.name, object: object.json, ring: ring, range: range, now: now, interval: interval)
        cache = (key, charts)
        return (charts, true)
    }
}
