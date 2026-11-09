import Foundation

/// The detail's Metrics tab (`m`; docs/design/kubernetes/metrics.md, 2.2,
/// stages M3a and M6): a pod's CPU and memory, by container, against what
/// the spec requests and limits — sampled from metrics-server while the
/// tab shows (the pod's own PodMetrics, polled as its Overview's usage is:
/// one GET every 15 s, nothing hidden), kept in the ring an hour after —
/// and, where the context's Prometheus is found, over 1h to 7d, a custom
/// window or a zoom, asked of it (`KubeTabQueries`), with what only it has
/// (throttling, network, restarts, earlier OOMKills) in Live too. `,` and
/// `.` step its range; a drag across a chart zooms every chart, Reset or
/// Esc pops it; Live pauses after 15 minutes without input. A restart's or
/// an OOMKill's marker opens the previous log, "Logs from Here" the log
/// from a minute before the crosshair.
extension KubernetesPageModel {
    /// The ranges a subject's tab can pick: every one where Prometheus is
    /// found, else what was sampled while shown.
    func metricsRanges(for subject: KubeMetricsSubject) -> [KubeMetricsRange] {
        chartsFromPrometheus ? KubeMetricsRange.allCases : KubeMetricsRange.sampled
    }

    /// The detail's.
    var metricsRanges: [KubeMetricsRange] { detail?.ref.metricsSubject.map(metricsRanges(for:)) ?? KubeMetricsRange.sampled }

    /// The range a subject's tab shows: the one picked, else Live where
    /// metrics-server answers (or an HPA's status), 1h where only
    /// Prometheus does (decision 7) — absent or down, never while
    /// discovery hasn't said (a context switch's first moment would ask a
    /// whole hour, then flip to Live); one it can't pick, Live.
    func shownMetricsRange(for subject: KubeMetricsSubject) -> KubeMetricsRange {
        let ranges = metricsRanges(for: subject)
        if !metricsRangePicked, metricsServerMissing, subject != .hpa, ranges.contains(.hour) { return .hour }
        return ranges.contains(metricsRange) ? metricsRange : .live
    }

    /// metrics-server known to be absent or down: not off, not yet unknown.
    private var metricsServerMissing: Bool {
        switch model.metrics.availability {
        case .absent, .down: true
        case .off, .unknown, .served: false
        }
    }

    /// The detail's.
    var shownMetricsRange: KubeMetricsRange { detail?.ref.metricsSubject.map(shownMetricsRange(for:)) ?? metricsRange }

    /// Why a range can't be picked here, or what it shows.
    func metricsRangeHelp(_ range: KubeMetricsRange) -> String {
        if metricsRanges.contains(range) {
            let prometheus = metricsRanges.count > KubeMetricsRange.sampled.count
            switch range {
            case .live:
                return prometheus
                    ? "The last 15 minutes: sampled from metrics-server where it answers, the rest from Prometheus"
                    : "The last 15 minutes, as metrics-server sampled them"
            case .sixHours where !prometheus: return "What was sampled while shown, up to 6 hours, in 1-minute buckets"
            default: return "The last \(range.title) from Prometheus, at \(KubePromQL.duration(range.prometheusStep(scrape: model.prometheus.profile?.scrapeInterval ?? 30)))"
            }
        }
        return "Needs Prometheus: metrics-server keeps no history, only what Overterm sampled while shown"
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

    /// `,` and `.`: the range before or after, while the Metrics tab shows;
    /// `.` past 7d opens Custom.
    @discardableResult
    func stepMetricsRange(_ by: Int) -> Bool {
        guard metricsTabShows else { return false }
        let shown = shownMetricsRange
        // From a window: the range it was over, then the step.
        if !metricsZoom.isEmpty { metricsZoom = [] }
        let ranges = metricsRanges
        if by > 0, shown == ranges.last, ranges.count > KubeMetricsRange.sampled.count {
            customRangeShown = true
            return true
        }
        pick(shown.stepped(by, among: ranges), shown: shown)
        return true
    }

    /// A range picked; one that can't be, ignored.
    func pickMetricsRange(_ range: KubeMetricsRange) {
        guard metricsRanges.contains(range) else { return }
        let shown = shownMetricsRange
        if !metricsZoom.isEmpty { metricsZoom = [] }
        pick(range, shown: shown)
    }

    /// `range` picked over `shown`: the default (1h without metrics-server)
    /// was shown while `metricsRange` already said it, so picking it changes
    /// nothing published — what is read is told anyway.
    private func pick(_ range: KubeMetricsRange, shown: KubeMetricsRange) {
        metricsRangePicked = true
        if range != metricsRange {
            metricsRange = range
        } else if range != shown {
            updateMetricsWanted()
            objectWillChange.send()
        }
    }

    /// A drag across a chart released: every chart of the tab moves to that
    /// window, one level more on the zoom stack — asked again at its own
    /// step from Prometheus, narrowed where the numbers were sampled.
    func zoomMetrics(_ window: KubeChartWindow) {
        guard metricsTabShows else { return }
        metricsZoom.append(window)
    }

    /// A drag from `a` to `b` across a chart showing `data`: kept inside
    /// what it shows; sampled numbers narrowed from the tier they were
    /// drawn from (Live's raw samples inside Live). Narrower than a minute, nothing.
    func zoomMetrics(from a: Date, to b: Date, of data: KubeChartData) {
        let tier = metricsWindow?.sampledTier ?? (shownMetricsRange == .live ? .live : .sixHours)
        guard let window = KubeChartWindow.zoom(from: a, to: b, within: data.start, data.end, sampledTier: tier) else { return }
        zoomMetrics(window)
    }

    /// Custom's dates applied: the window, or what is wrong with them.
    @discardableResult
    func applyCustomRange(start: Date, end: Date, now: Date = Date()) -> String? {
        switch KubeChartWindow.custom(start: start, end: end, now: now, retention: model.prometheus.profile?.retention) {
        case .failure(let invalid): return invalid.sentence
        case .success(let window):
            metricsZoom = [window]
            customRangeShown = false
            return nil
        }
    }

    /// Whether Custom can be picked: only over Prometheus.
    var offersCustomRange: Bool { metricsRanges.count > KubeMetricsRange.sampled.count }

    // MARK: Where the numbers come from

    /// The tab's source for `ref` (`KubeChartSource.pick`): nil, nothing to draw from.
    func metricsSource(of ref: KubeObjectRef) -> KubeChartSource? {
        guard let subject = ref.metricsSubject, model.selected?.settings.metrics != KubeMetricsSource.none else { return nil }
        return KubeChartSource.pick(
            subject: subject, range: shownMetricsRange(for: subject), window: metricsWindow, metricsServer: model.metrics.availability == .served,
            prometheus: chartsFromPrometheus)
    }

    /// Whose charts the detail's queries are: its object's facts, read once
    /// a version (a pod's CPU limits and network, a workload's HPA).
    func tabSubject(of session: KubeDetailSession) -> KubeTabSubject? {
        let ref = session.ref
        guard let object = session.object, let subject = ref.metricsSubject else { return nil }
        let hpa = chartLookups.hpa[ref] ?? nil
        let key = [ref.context, ref.kind.fullName, ref.namespace ?? "", ref.name, object.resourceVersion ?? "", String(object.data.count), hpa ?? ""]
            .joined(separator: "\n")
        if let cached = tabFactsCache, cached.key == key { return cached.subject }
        let made: KubeTabSubject?
        switch subject {
        case .pod:
            let json = object.json
            let host = ((json["spec"] as? [String: Any])?["hostNetwork"] as? Bool) ?? false
            made = ref.namespace.map {
                .pod(namespace: $0, name: ref.name, cpuLimited: KubePodCharts.containers(of: json).contains { $0.cpuLimit != nil }, hostNetwork: host)
            }
        case .workload(let kind):
            made = ref.namespace.map { .workload(namespace: $0, kind: kind, name: ref.name, hpa: hpa) }
        case .hpa:
            made = ref.namespace.map { .hpa(namespace: $0, name: ref.name) }
        case .node:
            made = .node(ref.name)
        case .namespace:
            made = .namespace(ref.name)
        }
        tabFactsCache = (key, made)
        return made
    }

    /// What the detail's tab asks Prometheus now: nil, nothing.
    func tabRequest(of session: KubeDetailSession) -> KubeTabRequest? {
        guard let subject = session.ref.metricsSubject, let source = metricsSource(of: session.ref) else { return nil }
        var families = KubePromTabCharts.families(subject, source: source)
        // A node's top pods, its disks and network, only while their group is on screen (metrics.md 6.2).
        for (group, read) in KubePromTabCharts.readWhenShown where !metricsGroupsShown.contains(group) { families.subtract(read) }
        guard !families.isEmpty, let whose = tabSubject(of: session) else { return nil }
        let span: KubeTabRequest.Span = metricsWindow.map { .window($0) } ?? .range(shownMetricsRange(for: subject))
        return KubeTabRequest(subject: whose, span: span, families: families)
    }

    /// A group read only while on screen (a node's top pods, its disks and
    /// network — by its title) appeared or went: what the tab asks follows.
    func metricsGroupShown(_ group: String, _ shown: Bool) {
        guard metricsGroupsShown.contains(group) != shown else { return }
        if shown { metricsGroupsShown.insert(group) } else { metricsGroupsShown.remove(group) }
        updatePrometheusWanted()
    }

    /// The detail's tab's Prometheus answers, as last read.
    func tabReading(of session: KubeDetailSession) -> KubeTabReading? {
        tabRequest(of: session).flatMap { model.prometheus.tabs[$0] }
    }

    /// The detail's tab reads Prometheus now: on a page on screen, its Metrics tab, Live not paused.
    var metricsTabWant: KubeTabRequest? {
        guard visible, windowVisible, section.listsKinds, metricsTabShows, !metricsLivePaused, let detail else { return nil }
        return tabRequest(of: detail)
    }

    // MARK: Live's pause

    /// Live runs: its tab shows on a page on screen, no window over it.
    var metricsLiveRuns: Bool { visible && windowVisible && section.listsKinds && metricsTabShows && metricsWindow == nil && shownMetricsRange == .live }

    /// Live paused: nothing it reads is read until Resume.
    var metricsLivePaused: Bool { metricsPaused && metricsLiveRuns }

    /// A key or a mouse move over the page: Live runs on.
    func noteMetricsInput() { metricsLastInput = Date() }

    /// Live counts its idle time while it runs; anything else ends the pause.
    func updateMetricsPause() {
        guard metricsLiveRuns else {
            metricsIdleTask?.cancel()
            metricsIdleTask = nil
            if metricsPaused { metricsPaused = false }
            return
        }
        guard !metricsPaused, metricsIdleTask == nil else { return }
        // Live starts running again (shown, its tab opened, the page back):
        // its idle time from now, not from the last input before it hid.
        metricsLastInput = Date()
        metricsIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = self.metricsLastInput.addingTimeInterval(self.metricsIdleLimit).timeIntervalSinceNow
                if left <= 0 {
                    self.metricsIdleTask = nil
                    if self.metricsLiveRuns { self.metricsPaused = true }
                    return
                }
                try? await Task.sleep(for: .milliseconds(Int(left * 1000) + 50))
            }
        }
    }

    /// "Resume": Live reads again, its idle time from now.
    func resumeMetrics() {
        noteMetricsInput()
        if metricsPaused { metricsPaused = false }
        updateMetricsPause()
    }

    // MARK: The pod's charts

    /// The pod's charts at the range picked: sampled from the ring, at the
    /// last poll's time (the window stands still between polls), and what
    /// Prometheus answered — every chart from it, or (Live) what only it
    /// has. Nil without the object or with nothing to draw from. Built only
    /// when what they are built from changes (`KubePodChartsKey`) — never
    /// for a row event or a list's poll that redraws the tab.
    func podCharts(of ref: KubeObjectRef, object: KubeObject?) -> KubePodCharts? {
        guard ref.isPod, ref.namespace != nil, let object, let source = metricsSource(of: ref) else { return nil }
        let reading = detail.flatMap { $0.ref == ref ? tabReading(of: $0) : nil }
        let metricsReading = ref.namespace.flatMap { model.metrics.reading(.pod(namespace: $0, name: ref.name)) }
        let now = metricsReading?.sample?.read ?? Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 15).rounded(.down) * 15)
        let poll = Double(model.metrics.interval.components.seconds) + Double(model.metrics.interval.components.attoseconds) / 1e18
        // How far apart samples come: the poll's, or metrics-server's own window when longer.
        let interval = max(15, poll, metricsReading?.sample?.resolution ?? 0)
        let changes = detail.map { chartChanges(of: $0) } ?? KubeChartChanges()
        let (charts, built) = KubePodChartsKey.charts(
            ref: ref, object: object, ring: model.metrics.ring, range: shownMetricsRange(for: .pod), now: now, interval: interval, changes: changes,
            window: metricsWindow, source: source, reading: reading, cache: &podChartsCache)
        if built { podChartsBuilds += 1 }
        return charts
    }

    /// Why the tab has no charts: metrics-server absent, refused, failing;
    /// Prometheus not found, refused, in agent mode.
    func metricsTabProblem(of ref: KubeObjectRef) -> String? {
        if let session = detail, session.ref == ref, let source = metricsSource(of: ref), source != .sampled {
            if let reading = tabReading(of: session) {
                if let unavailable = reading.unavailable { return unavailable }
                if source == .prometheus, reading.read == nil, let problem = reading.problem { return "Prometheus couldn't be read: \(problem)" }
            }
            if source == .prometheus { return nil }
        }
        if let reason = model.metrics.availability.reason {
            guard model.metrics.availability == .absent else { return reason }
            if prometheusOn, case .unavailable(let why) = model.prometheus.state { return Self.metricsServerAbsent(prometheus: true) + " " + why }
            return Self.metricsServerAbsent(prometheus: prometheusOn)
        }
        guard let namespace = ref.namespace, let reading = model.metrics.reading(.pod(namespace: namespace, name: ref.name)) else { return nil }
        return reading.refused ?? reading.problem.map { "Usage couldn't be read: \($0)" }
    }

    /// The tab's words for a cluster without metrics-server: with
    /// Prometheus on, the charts are its, once it is found. Pure.
    nonisolated static func metricsServerAbsent(prometheus: Bool) -> String {
        (prometheus ? KubeChartEmpty.noMetricsServerPrometheus : .noMetricsServer).sentence
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
    /// What its markers were joined from.
    var changes: Int
    var window: KubeChartWindow?
    var source: KubeChartSource = .sampled
    /// Prometheus' answers' version (`KubeTabReading.version`).
    var prometheus: Int?

    /// A pod's charts from `cache` when built from the same, else built —
    /// the object's JSON parsed then, and only then — and kept there.
    @MainActor
    static func charts(
        ref: KubeObjectRef, object: KubeObject, ring: KubeUsageRing, range: KubeMetricsRange, now: Date, interval: TimeInterval,
        changes: KubeChartChanges = KubeChartChanges(), window: KubeChartWindow? = nil, source: KubeChartSource = .sampled, reading: KubeTabReading? = nil,
        cache: inout (key: KubePodChartsKey, charts: KubePodCharts?)?
    ) -> (charts: KubePodCharts?, built: Bool) {
        guard let namespace = ref.namespace else { return (nil, false) }
        let key = KubePodChartsKey(
            ref: ref, resourceVersion: object.resourceVersion, bytes: object.data.count, now: source == .prometheus ? .distantPast : now, range: range,
            interval: interval, changes: changes.version, window: window, source: source, prometheus: source == .sampled ? nil : reading?.version)
        if let cached = cache, cached.key == key { return (cached.charts, false) }
        let charts: KubePodCharts?
        switch source {
        case .prometheus:
            charts = reading.map { KubePromTabCharts.pod(namespace: namespace, pod: ref.name, object: object.json, reading: $0, changes: changes, window: window) }
        case .sampled, .mixed:
            let json = object.json
            let sampled = KubePodCharts.build(
                namespace: namespace, pod: ref.name, object: json, ring: ring, range: range, now: now, interval: interval, changes: changes, window: window)
            charts =
                source == .mixed
                ? KubePromTabCharts.addOnly(sampled, namespace: namespace, pod: ref.name, object: json, reading: reading, changes: changes) : sampled
        }
        cache = (key, charts)
        return (charts, true)
    }
}
