import Foundation

/// The Metrics tab's range (docs/design/kubernetes/metrics.md, 3.4): one
/// choice a page, in memory, never saved — `,` and `.` step through the
/// ones that can be picked. Without Prometheus only the sampled ones can:
/// Live (the raw samples, 15 minutes) and 6h (the minute buckets kept
/// while shown); the others say they need Prometheus. Pure.
enum KubeMetricsRange: String, CaseIterable, Identifiable, Sendable {
    case live, hour, sixHours, day, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Live"
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        }
    }

    var span: TimeInterval {
        switch self {
        case .live: TimeInterval(KubeUsageRing.rawSpan)
        case .hour: 3600
        case .sixHours: TimeInterval(KubeUsageRing.foldedSpan)
        case .day: 86400
        case .week: 7 * 86400
        }
    }

    /// The points' spacing: metrics-server's (15 s by default — the
    /// tab says what was seen, `KubePodCharts.spacing`), or the folded minute.
    var step: TimeInterval { self == .live ? 15 : TimeInterval(KubeUsageRing.bucketSeconds) }

    /// What metrics-server's samples taken while shown can draw.
    var isSampled: Bool { self == .live || self == .sixHours }

    static let sampled: [KubeMetricsRange] = allCases.filter(\.isSampled)

    /// `,` (−1) and `.` (+1): the next one of `available` that way,
    /// stopping at either end.
    func stepped(_ by: Int, among available: [KubeMetricsRange]) -> KubeMetricsRange {
        let order = Self.allCases.filter { available.contains($0) }
        guard let index = order.firstIndex(of: self) else { return order.first ?? self }
        return order[min(max(index + by, 0), order.count - 1)]
    }
}

/// A pod's Metrics tab, sampled (metrics.md 2.3, 2.4; stage M3a): its CPU
/// and memory stacked by container (P1, P2), then each container's CPU
/// and memory (C1, C2) against its request and limit — reference lines
/// from the spec the detail's one GET read, chips saying the shares —
/// with a restart or an OOMKill marked where `lastState` says it ended.
/// The numbers are `KubeUsageRing`'s: Live its raw tier, 6h its minute
/// buckets (CPU the minute's mean, memory its peak, so the spike before
/// an OOM survives). Pure.
struct KubePodCharts: Equatable, Sendable {
    /// How a container last ended, as its status says (only the last one is kept).
    struct Termination: Equatable, Sendable {
        var reason: String
        var exitCode: Int?
        var finishedAt: Date?
    }

    /// A container as its spec and status say it.
    struct Container: Equatable, Sendable {
        var name: String
        var cpuRequest: Double?
        var cpuLimit: Double?
        var memoryRequest: Double?
        var memoryLimit: Double?
        var restarts = 0
        var lastTerminated: Termination?
        /// Its GPUs, by resource (`nvidia.com/gpu`, a MIG profile's,
        /// `amd.com/gpu`): what it is given — an extended resource's
        /// request is its limit (metrics.md decision 12).
        var gpus: [String: Double] = [:]
    }

    struct Chart: Equatable, Sendable, Identifiable {
        var data: KubeChartData
        var headline: String?
        var chips: [KubeChartChip] = []
        var id: String { data.id }
    }

    /// One container's charts, under its name.
    struct Section: Equatable, Sendable, Identifiable {
        var container: String
        var charts: [Chart]
        /// Why one of its charts is left out: "No CPU limit: never throttled".
        var notes: [String] = []
        var id: String { container }
    }

    /// Beyond this many containers a picker replaces the sections.
    static let sectionsAtMost = 4
    /// At this share of its memory limit a container is near its OOMKill.
    static let oomRisk = 0.9

    var range: KubeMetricsRange
    var pod: [Chart]
    var sections: [Section]
    /// Where the numbers come from, and since when.
    var caption: String
    /// "last 15 min", for each chart's summary.
    var span: String
    /// Whether anything was sampled to draw.
    var hasSamples: Bool
    /// Why a chart is left out, what Prometheus said beside its answers.
    var notes: [String] = []

    /// More containers than sections are shown for: one picked at a time.
    var picksContainer: Bool { sections.count > Self.sectionsAtMost }

    // MARK: The spec

    /// Its containers, the one its log shows first (kubectl's default
    /// container) first, then in the spec's order, then its native sidecars
    /// (init containers with `restartPolicy: Always`, running beside the
    /// others: metrics-server reports them, and the pod's total counts
    /// them — left out, the pod's usage would be measured against the
    /// others' requests and limits only); requests and limits from the
    /// spec, restarts and the last termination from the status. An init
    /// container that runs to completion first isn't one: it isn't running.
    static func containers(of pod: [String: Any]) -> [Container] {
        let spec = pod["spec"] as? [String: Any] ?? [:]
        let status = pod["status"] as? [String: Any] ?? [:]
        let statuses = ((status["containerStatuses"] as? [[String: Any]] ?? []) + (status["initContainerStatuses"] as? [[String: Any]] ?? [])).reduce(
            into: [String: [String: Any]]()
        ) {
            if let name = $1["name"] as? String, $0[name] == nil { $0[name] = $1 }
        }
        let sidecars = (spec["initContainers"] as? [[String: Any]] ?? []).filter { ($0["restartPolicy"] as? String) == "Always" }
        var out: [Container] = []
        for container in (spec["containers"] as? [[String: Any]] ?? []) + sidecars {
            guard let name = container["name"] as? String, !name.isEmpty, !out.contains(where: { $0.name == name }) else { continue }
            let resources = container["resources"] as? [String: Any] ?? [:]
            let requests = resources["requests"] as? [String: Any] ?? [:]
            let limits = resources["limits"] as? [String: Any] ?? [:]
            func quantity(_ side: [String: Any], _ key: String) -> Double? {
                (side[key] as? String).flatMap(KubeQuantity.value) ?? (side[key] as? NSNumber)?.doubleValue
            }
            let status = statuses[name] ?? [:]
            let last = ((status["lastState"] as? [String: Any])?["terminated"] as? [String: Any]).map { terminated in
                Termination(
                    reason: terminated["reason"] as? String ?? "Terminated", exitCode: KubeRollout.int(terminated["exitCode"]),
                    finishedAt: KubeMetricsReader.time(terminated["finishedAt"]))
            }
            out.append(
                Container(
                    name: name, cpuRequest: quantity(requests, "cpu"), cpuLimit: quantity(limits, "cpu"), memoryRequest: quantity(requests, "memory"),
                    memoryLimit: quantity(limits, "memory"), restarts: KubeRollout.int(status["restartCount"]) ?? 0, lastTerminated: last,
                    gpus: KubeGPU.counts(requests: requests, limits: limits)))
        }
        if let first = KubePodContainers.defaultContainer(pod), let index = out.firstIndex(where: { $0.name == first }), index > 0 {
            out.insert(out.remove(at: index), at: 0)
        }
        return out
    }

    /// A container's last termination as a marker, where its time is known.
    static func marker(_ container: Container) -> KubeChartMarker? {
        KubeChartMarkers.termination(KubePodStates.Container(name: container.name, restarts: container.restarts, last: container.lastTerminated))
    }

    // MARK: Building

    /// How far apart a series' samples came: the median spacing inside its
    /// segments (a break isn't spacing), nil with fewer than two in one.
    static func spacing(_ segments: [[KubeUsagePoint]]) -> TimeInterval? {
        var gaps: [TimeInterval] = []
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) { gaps.append(b.time.timeIntervalSince(a.time)) }
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// The tab's charts for `range`, from the ring's samples of the pod
    /// and its containers, at `now` (the last poll's time, so the window
    /// stands still between polls); `interval`, how far apart samples are
    /// expected (the poll's, or metrics-server's `window` when longer).
    /// Live keeps the ring's breaks (`breaksMarked`), its step what the
    /// samples' spacing was — metrics-server at `--metric-resolution=60s`
    /// samples a minute apart however often it is asked.
    /// Every chart is marked (`KubeChartMarkers.mark`): the pod's
    /// terminations and restarts — `changes`' read of its states, else its
    /// object's —, its events; `window`, narrowed to it from the tier that holds it.
    static func build(
        namespace: String, pod name: String, object: [String: Any], ring: KubeUsageRing, range: KubeMetricsRange, now: Date, interval: TimeInterval,
        changes: KubeChartChanges = KubeChartChanges(), window: KubeChartWindow? = nil
    ) -> KubePodCharts {
        let range = window?.tier ?? (range.isSampled ? range : .live)
        let start = now.addingTimeInterval(-range.span)
        let containers = containers(of: object)
        let podKey = KubeUsageKey.pod(namespace: namespace, name: name)
        struct Points {
            var cpu: [KubeSeriesPoint]
            var memory: [KubeSeriesPoint]
            var breaks: Set<Date> = []
        }
        func segments(_ key: KubeUsageKey) -> [[KubeUsagePoint]] {
            ring.segments(key, now: now).map { $0.filter { $0.time >= start && $0.time <= now } }.filter { !$0.isEmpty }
        }
        func points(_ key: KubeUsageKey) -> Points {
            if range == .live {
                let segments = segments(key)
                let kept = segments.flatMap { $0 }
                return Points(
                    cpu: kept.map { KubeSeriesPoint(time: $0.time, value: $0.usage.cpu) }, memory: kept.map { KubeSeriesPoint(time: $0.time, value: $0.usage.memory) },
                    breaks: Set(segments.dropFirst().compactMap { $0.first?.time }))
            }
            let buckets = ring.folded(key, now: now).filter { $0.start >= start && $0.start <= now }
            return Points(
                cpu: buckets.map { KubeSeriesPoint(time: $0.start, value: $0.avg.cpu) }, memory: buckets.map { KubeSeriesPoint(time: $0.start, value: $0.max.memory) })
        }
        // Live's step: the samples' own spacing, never under what was expected.
        let step = range == .live ? max(interval, spacing(segments(podKey)) ?? 0, 1) : range.step
        let interval = range == .live ? step : interval
        let subject = "\(namespace).\(name)"
        let source = "metrics-server"
        let tier = range == .live ? "sampled every \(seconds(interval))" : "1-minute buckets (CPU the mean, memory the peak)"
        func chart(
            id: String, title: String, unit: KubeChartUnit, series: [KubeChartSeries], stacked: Bool, markers: [KubeChartMarker]
        ) -> KubeChartData {
            var hasher = Hasher()
            hasher.combine(id)
            hasher.combine(range)
            hasher.combine(start)
            hasher.combine(now)
            hasher.combine(step)
            for line in series {
                hasher.combine(line.id)
                hasher.combine(line.breaks.count)
                hasher.combine(line.points.count)
                hasher.combine(line.points.first?.time)
                hasher.combine(line.points.last?.time)
                hasher.combine(line.points.last?.value)
            }
            for marker in markers { hasher.combine(marker.id) }
            return KubeChartData(
                id: id, title: title, unit: unit, series: series, start: start, end: now, step: step, stacked: stacked, source: source, tier: tier,
                version: hasher.finalize(), markers: markers, breaksMarked: range == .live)
        }
        func references(_ request: Double?, _ limit: Double?) -> [KubeChartSeries] {
            var out: [KubeChartSeries] = []
            if let request { out.append(KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: now, value: request)])) }
            if let limit { out.append(KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: now, value: limit)])) }
            return out
        }
        /// Every container's own figure added up, or nil when one has none: a partial sum would mislead.
        func total(_ value: (Container) -> Double?) -> Double? {
            guard !containers.isEmpty else { return nil }
            var sum = 0.0
            for container in containers {
                guard let one = value(container) else { return nil }
                sum += one
            }
            return sum
        }

        let own = points(podKey)
        let perContainer = containers.map { points(.container(namespace: namespace, pod: name, container: $0.name)) }

        // P1, P2: stacked by container.
        let cpuRequest = total(\.cpuRequest)
        let cpuLimit = total(\.cpuLimit)
        let memoryRequest = total(\.memoryRequest)
        let memoryLimit = total(\.memoryLimit)
        let cpuStack = zip(containers, perContainer).map { KubeChartSeries(id: $0.name, name: $0.name, points: $1.cpu, breaks: $1.breaks) }
        let memoryStack = zip(containers, perContainer).map { KubeChartSeries(id: $0.name, name: $0.name, points: $1.memory, breaks: $1.breaks) }
        let podCPU = chart(
            id: "pod.\(subject).cpu", title: "CPU", unit: .cores,
            series: (cpuStack.isEmpty ? [KubeChartSeries(id: "cpu", name: "CPU", points: own.cpu, breaks: own.breaks)] : cpuStack) + references(cpuRequest, cpuLimit),
            stacked: cpuStack.count > 1, markers: [])
        let podMemory = chart(
            id: "pod.\(subject).memory", title: "Memory", unit: .bytes,
            series: (memoryStack.isEmpty ? [KubeChartSeries(id: "memory", name: "Memory", points: own.memory, breaks: own.breaks)] : memoryStack)
                + references(memoryRequest, memoryLimit),
            stacked: memoryStack.count > 1, markers: [])
        let podLatest = own.cpu.last.map(\.value)
        let podMemoryLatest = own.memory.last.map(\.value)
        let pod = [
            Chart(data: podCPU, headline: podLatest.map { "\(KubeMetricsFormat.cpu($0)) now" }, chips: cpuChips(podLatest, request: cpuRequest, limit: cpuLimit)),
            Chart(
                data: podMemory, headline: podMemoryLatest.map { "\(KubeMetricsFormat.memory($0)) now" },
                chips: memoryChips(podMemoryLatest, request: memoryRequest, limit: memoryLimit)),
        ]

        // C1, C2: each container against its own request and limit.
        let sections = zip(containers, perContainer).map { container, series -> Section in
            let id = "container.\(subject).\(container.name)"
            let cpu = chart(
                id: id + ".cpu", title: "CPU", unit: .cores,
                series: [KubeChartSeries(id: "cpu", name: "CPU", points: series.cpu, breaks: series.breaks)] + references(container.cpuRequest, container.cpuLimit), stacked: false,
                markers: [])
            let memory = chart(
                id: id + ".memory", title: "Memory", unit: .bytes,
                series: [KubeChartSeries(id: "memory", name: "Working set", points: series.memory, breaks: series.breaks)]
                    + references(container.memoryRequest, container.memoryLimit), stacked: false, markers: [])
            let cpuNow = series.cpu.last.map(\.value)
            let memoryNow = series.memory.last.map(\.value)
            return Section(
                container: container.name,
                charts: [
                    Chart(
                        data: cpu, headline: cpuNow.map { "\(KubeMetricsFormat.cpu($0)) now" },
                        chips: cpuChips(cpuNow, request: container.cpuRequest, limit: container.cpuLimit)),
                    Chart(
                        data: memory, headline: memoryNow.map { "\(KubeMetricsFormat.memory($0)) now" },
                        chips: memoryChips(memoryNow, request: container.memoryRequest, limit: container.memoryLimit)),
                ])
        }

        let first = own.cpu.first?.time ?? perContainer.compactMap { $0.cpu.first?.time }.min()
        let caption: String
        if let first {
            caption =
                "Sampled from metrics-server while shown since \(KubeChartTime.clock(first)), "
                + (range == .live ? "every \(seconds(interval))" : "in 1-minute buckets: CPU the minute's mean, memory its peak")
        } else {
            caption = "Waiting for metrics-server's first sample of this pod…"
        }
        let charts = KubePodCharts(
            range: range, pod: pod, sections: sections, caption: caption, span: range == .live ? "last 15 min" : "last 6h", hasSamples: first != nil)
        var changes = changes
        if changes.restarts.states == nil {
            let states = containers.map { KubePodStates.Container(name: $0.name, restarts: $0.restarts, last: $0.lastTerminated) }
            changes.restarts = KubeRestartLog(KubePodStates(pods: [KubePodStates.Pod(name: name, containers: states)], read: now))
        }
        return KubeChartMarkers.mark(charts, pod: name, changes: changes, window: window, now: now)
    }

    /// `15 s`, `0.5 s`.
    static func seconds(_ interval: TimeInterval) -> String {
        interval >= 1 ? "\(Int(interval.rounded())) s" : String(format: "%.1f s", interval)
    }

    /// CPU's chips: its share of the request and of the limit.
    static func cpuChips(_ used: Double?, request: Double?, limit: Double?) -> [KubeChartChip] {
        guard let used else { return [] }
        var chips: [KubeChartChip] = []
        if let percent = KubeMetricsFormat.percent(used, of: request) { chips.append(KubeChartChip(text: "\(percent)% of request")) }
        if let percent = KubeMetricsFormat.percent(used, of: limit) { chips.append(KubeChartChip(text: "\(percent)% of limit")) }
        if limit == nil { chips.append(KubeChartChip(text: "no limit")) }
        return chips
    }

    /// Memory's chips: the working set's share of the request, and of the
    /// limit — red past nine tenths of it, where the OOMKill is near.
    static func memoryChips(_ used: Double?, request: Double?, limit: Double?) -> [KubeChartChip] {
        guard let used else { return [] }
        var chips: [KubeChartChip] = []
        if let percent = KubeMetricsFormat.percent(used, of: request) { chips.append(KubeChartChip(text: "\(percent)% of request")) }
        if let limit, limit > 0, let percent = KubeMetricsFormat.percent(used, of: limit) {
            let risk = used >= limit * oomRisk
            chips.append(KubeChartChip(text: "working set \(percent)% of limit" + (risk ? " · OOM risk" : ""), alert: risk))
        }
        return chips
    }
}
