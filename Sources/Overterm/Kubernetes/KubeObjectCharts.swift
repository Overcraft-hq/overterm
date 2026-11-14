import Foundation

/// The Metrics tab of a workload, an HPA, a node or a namespace, sampled
/// (docs/design/kubernetes/metrics.md, 2.5–2.8; stage M3b): its groups of
/// charts — each a title and its charts —, where the numbers come from,
/// and the sentences that say why a chart is left out. Built from the
/// ring (metrics-server's samples taken while shown) and the status
/// history (the objects' own numbers read while shown). Pure.
struct KubeObjectCharts: Equatable, Sendable {
    struct Group: Equatable, Sendable, Identifiable {
        var title: String
        var charts: [KubePodCharts.Chart]
        /// Its charts are read only while it is on screen (a node's top
        /// pods over Prometheus, K3: a series a pod on the node): its view
        /// says when it shows (metrics.md 6.2).
        var readsWhenShown = false
        /// Not read yet: the view says it is asked once shown.
        var pending = false
        var id: String { title }
    }

    var range: KubeMetricsRange
    var groups: [Group]
    var caption: String
    /// "last 15 min", for each chart's summary.
    var span: String
    var hasSamples: Bool
    /// Why a chart is left out, or what a chart's numbers are not.
    var notes: [String] = []
    /// A workload's: the view drawn.
    var view: KubeWorkloadView?

    var charts: [KubePodCharts.Chart] { groups.flatMap(\.charts) }
}

/// A workload's CPU and memory as one total (stacked: its top five pods
/// and the rest) or its top five pods as lines, against the template's
/// request and limit (metrics.md 2.5, decision 13).
enum KubeWorkloadView: String, CaseIterable, Sendable {
    case total, perPod

    var title: String { self == .total ? "Total" : "Per pod" }
}

/// What the builders share: a key's samples at a range, a chart's data
/// with its version, series lined up on another's times. Pure.
enum KubeChartBuild {
    struct Usage {
        var cpu: [KubeSeriesPoint]
        var memory: [KubeSeriesPoint]
        var breaks: Set<Date> = []
    }

    /// A ring key's CPU and memory over the range: Live its raw samples
    /// (its breaks kept), 6h its minute buckets — CPU the mean, memory the peak.
    static func usage(_ ring: KubeUsageRing, _ key: KubeUsageKey, range: KubeMetricsRange, start: Date, now: Date) -> Usage {
        if range == .live {
            let segments = ring.segments(key, now: now).map { $0.filter { $0.time >= start && $0.time <= now } }.filter { !$0.isEmpty }
            let kept = segments.flatMap { $0 }
            return Usage(
                cpu: kept.map { KubeSeriesPoint(time: $0.time, value: $0.usage.cpu) }, memory: kept.map { KubeSeriesPoint(time: $0.time, value: $0.usage.memory) },
                breaks: Set(segments.dropFirst().compactMap { $0.first?.time }))
        }
        let buckets = ring.folded(key, now: now).filter { $0.start >= start && $0.start <= now }
        return Usage(
            cpu: buckets.map { KubeSeriesPoint(time: $0.start, value: $0.avg.cpu) }, memory: buckets.map { KubeSeriesPoint(time: $0.start, value: $0.max.memory) })
    }

    /// A chart's data, its version hashed from what it draws.
    static func data(
        id: String, title: String, unit: KubeChartUnit, series: [KubeChartSeries], start: Date, end: Date, step: TimeInterval, stacked: Bool = false,
        source: String, tier: String?, breaksMarked: Bool, bands: [KubeChartBand] = [], stepped: Bool = false
    ) -> KubeChartData {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(start)
        hasher.combine(end)
        hasher.combine(step)
        hasher.combine(stacked)
        for line in series {
            hasher.combine(line.id)
            hasher.combine(line.name)
            hasher.combine(line.breaks.count)
            hasher.combine(line.points.count)
            hasher.combine(line.points.first?.time)
            hasher.combine(line.points.last?.time)
            hasher.combine(line.points.last?.value)
            hasher.combine(line.points.reduce(0) { $0 + $1.value })
        }
        for band in bands { hasher.combine(band.id) }
        return KubeChartData(
            id: id, title: title, unit: unit, series: series, start: start, end: end, step: step, stacked: stacked, source: source, tier: tier,
            version: hasher.finalize(), breaksMarked: breaksMarked, bands: bands, stepped: stepped)
    }

    /// A reference line at one value.
    static func reference(_ id: String, _ name: String, _ role: KubeChartRole, _ value: Double?, at now: Date) -> KubeChartSeries? {
        value.map { KubeChartSeries(id: id, name: name, role: role, points: [KubeSeriesPoint(time: now, value: $0)]) }
    }

    /// `points` at each of `times`: the last one at or before it, no more
    /// than `within` before — none in a gap (never a guess). Pods on
    /// different nodes are stamped apart: stacked over a total, each is
    /// read at the total's times.
    static func align(_ points: [KubeSeriesPoint], to times: [Date], within: TimeInterval) -> [KubeSeriesPoint] {
        var out: [KubeSeriesPoint] = []
        out.reserveCapacity(times.count)
        var index = 0
        for time in times {
            while index + 1 < points.count, points[index + 1].time <= time { index += 1 }
            guard index < points.count, points[index].time <= time, time.timeIntervalSince(points[index].time) <= within else { continue }
            out.append(KubeSeriesPoint(time: time, value: points[index].value))
        }
        return out
    }

    /// What a key is ranked by: its raw samples' mean CPU since `start`
    /// (the last 15 minutes), else the range's points'.
    static func rank(_ ring: KubeUsageRing, _ key: KubeUsageKey, usage: Usage, since start: Date, now: Date) -> Double {
        let raw = ring.points(key, now: now).map { KubeSeriesPoint(time: $0.time, value: $0.usage.cpu) }
        return mean(raw.isEmpty ? usage.cpu : raw, since: start)
    }

    /// The mean of `points` since `start` (0 with none).
    static func mean(_ points: [KubeSeriesPoint], since start: Date) -> Double {
        let kept = points.filter { $0.time >= start }
        return kept.isEmpty ? 0 : kept.reduce(0) { $0 + $1.value } / Double(kept.count)
    }

    /// `total` less the parts at each of its times, never below zero: "other".
    static func rest(_ total: [KubeSeriesPoint], minus parts: [[KubeSeriesPoint]]) -> [KubeSeriesPoint] {
        var taken: [Date: Double] = [:]
        for part in parts { for point in part { taken[point.time, default: 0] += point.value } }
        return total.map { KubeSeriesPoint(time: $0.time, value: max(0, $0.value - (taken[$0.time] ?? 0))) }
    }

    /// Live's step: the samples' own spacing, never under the poll's.
    static func step(_ range: KubeMetricsRange, interval: TimeInterval, points: [KubeSeriesPoint]) -> TimeInterval {
        guard range == .live else { return range.step }
        var gaps: [TimeInterval] = []
        for (a, b) in zip(points, points.dropFirst()) { gaps.append(b.time.timeIntervalSince(a.time)) }
        let spacing = gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2]
        return max(interval, spacing, 1)
    }

    static func caption(first: Date?, range: KubeMetricsRange, interval: TimeInterval, of what: String) -> String {
        guard let first else { return "Waiting for metrics-server's first sample of \(what)…" }
        return "Sampled from metrics-server while shown since \(KubeChartTime.clock(first)), "
            + (range == .live ? "every \(KubePodCharts.seconds(interval))" : "in 1-minute buckets: CPU the minute's mean, memory its peak")
    }

    static func tier(_ range: KubeMetricsRange, interval: TimeInterval) -> String {
        range == .live ? "sampled every \(KubePodCharts.seconds(interval))" : "1-minute buckets (CPU the mean, memory the peak)"
    }

    static func span(_ range: KubeMetricsRange) -> String { range == .live ? "last 15 min" : "last 6h" }
}

// MARK: Workloads

/// A workload's tab (W1–W4, and its HPA's H1 and H2 when one targets it).
enum KubeWorkloadCharts {
    static let top = 5

    struct Input {
        var namespace: String
        var kind: String
        var name: String
        /// The workload's object (its template's requests and limits, its replicas).
        var object: [String: Any]
        var ring: KubeUsageRing
        var statuses: KubeStatusHistory
        /// The last sample's pods: who they are, and their revisions.
        var pods: [KubePodMetrics]
        var range: KubeMetricsRange
        var now: Date
        var interval: TimeInterval
        var view: KubeWorkloadView?
        /// Each ReplicaSet's or ControllerRevision's name, and how its line is labelled: "rev 14 (nginx:1.27.2)".
        var revisions: [String: String] = [:]
        /// The HPA that targets it, and what it said last.
        var hpa: (name: String, status: KubeHPAStatus?)?
        /// What its markers are joined from: its History, its pods' states.
        var changes = KubeChartChanges()
        var window: KubeChartWindow?

        init(
            namespace: String, kind: String, name: String, object: [String: Any], ring: KubeUsageRing, statuses: KubeStatusHistory, pods: [KubePodMetrics],
            range: KubeMetricsRange, now: Date, interval: TimeInterval, view: KubeWorkloadView? = nil, revisions: [String: String] = [:],
            hpa: (name: String, status: KubeHPAStatus?)? = nil, changes: KubeChartChanges = KubeChartChanges(), window: KubeChartWindow? = nil
        ) {
            self.namespace = namespace
            self.kind = kind
            self.name = name
            self.object = object
            self.ring = ring
            self.statuses = statuses
            self.pods = pods
            self.range = range
            self.now = now
            self.interval = interval
            self.view = view
            self.revisions = revisions
            self.hpa = hpa
            self.changes = changes
            self.window = window
        }
    }

    /// The template's per-pod request and limit (its containers' added up;
    /// nil where one container sets none), and how many pods it runs now.
    static func template(_ object: [String: Any], kind: String) -> (perPod: KubePodCharts.Container, replicas: Int) {
        let template = ((object["spec"] as? [String: Any])?["template"] as? [String: Any]) ?? [:]
        let containers = KubePodCharts.containers(of: ["spec": template["spec"] ?? [:]])
        func total(_ value: (KubePodCharts.Container) -> Double?) -> Double? {
            guard !containers.isEmpty else { return nil }
            var sum = 0.0
            for container in containers {
                guard let one = value(container) else { return nil }
                sum += one
            }
            return sum
        }
        let status = object["status"] as? [String: Any] ?? [:]
        let replicas =
            kind == "Job"
            ? KubeRollout.int(status["active"]) ?? 0 : kind == "DaemonSet" ? KubeRollout.int(status["currentNumberScheduled"]) ?? 0 : KubeRollout.int(status["replicas"]) ?? 0
        return (
            KubePodCharts.Container(
                name: "pod", cpuRequest: total(\.cpuRequest), cpuLimit: total(\.cpuLimit), memoryRequest: total(\.memoryRequest), memoryLimit: total(\.memoryLimit)),
            replicas
        )
    }

    /// The default view: Per pod with five pods or fewer, else Total (decision 13).
    static func defaultView(pods: Int) -> KubeWorkloadView { pods <= top ? .perPod : .total }

    /// A revision's line's name: its timeline label, else `rev <hash>`.
    static func revisionName(_ hash: String, kind: String, workload: String, revisions: [String: String]) -> String {
        revisions[workload + "-" + hash] ?? revisions[hash] ?? "rev \(hash)"
    }

    /// Its charts marked with its History; W1 and W2 with every pod's
    /// OOMKills and restarts too, from the bounded read of its pods' states.
    static func build(_ input: Input) -> KubeObjectCharts {
        let range = input.window?.tier ?? (input.range.isSampled ? input.range : .live)
        let now = input.now
        let start = now.addingTimeInterval(-range.span)
        let whole = KubeUsageKey.workload(namespace: input.namespace, kind: input.kind, name: input.name)
        let total = KubeChartBuild.usage(input.ring, whole, range: range, start: start, now: now)
        let step = KubeChartBuild.step(range, interval: input.interval, points: total.cpu)
        let breaksMarked = range == .live
        let source = "metrics-server"
        let tier = KubeChartBuild.tier(range, interval: step)
        let subject = "workload.\(input.namespace).\(input.kind.lowercased()).\(input.name)"
        let (perPod, replicas) = template(input.object, kind: input.kind)
        var notes: [String] = []

        // The pods, each its own: ranked by their last 15 minutes' mean CPU.
        let rankFrom = now.addingTimeInterval(-TimeInterval(KubeUsageRing.rawSpan))
        let pods = input.pods.map(\.id).sorted()
        let tooMany = pods.count > KubeUsageRing.podPartsAtMost
        var ranked: [(id: KubeRowID, usage: KubeChartBuild.Usage, rank: Double)] = []
        for id in tooMany ? [] : pods {
            let usage = KubeChartBuild.usage(input.ring, .pod(id), range: range, start: start, now: now)
            ranked.append((id, usage, KubeChartBuild.rank(input.ring, .pod(id), usage: usage, since: rankFrom, now: now)))
        }
        ranked.sort { $0.rank == $1.rank ? $0.id < $1.id : $0.rank > $1.rank }
        let shown = Array(ranked.prefix(top))
        let view = tooMany ? .total : input.view ?? defaultView(pods: pods.count)
        if tooMany { notes.append("More than \(KubeUsageRing.podPartsAtMost) pods: the total only, no pod's own line.") }

        func references(_ cpu: Bool) -> [KubeChartSeries] {
            let request = cpu ? perPod.cpuRequest : perPod.memoryRequest
            let limit = cpu ? perPod.cpuLimit : perPod.memoryLimit
            let times = view == .total ? Double(replicas) : 1
            let suffix = view == .total ? " × \(replicas)" : " a pod"
            guard view == .perPod || replicas > 0 else { return [] }
            return [
                KubeChartBuild.reference("request", "request\(suffix) (template)", .request, request.map { $0 * times }, at: now),
                KubeChartBuild.reference("limit", "limit\(suffix) (template)", .limit, limit.map { $0 * times }, at: now),
            ].compactMap { $0 }
        }
        func usageChart(_ cpu: Bool) -> KubePodCharts.Chart {
            let unit: KubeChartUnit = cpu ? .cores : .bytes
            let totalPoints = cpu ? total.cpu : total.memory
            var series: [KubeChartSeries]
            var stacked = false
            if view == .perPod, !shown.isEmpty {
                series = shown.map { KubeChartSeries(id: $0.id.name, name: $0.id.name, points: cpu ? $0.usage.cpu : $0.usage.memory, breaks: $0.usage.breaks) }
            } else if shown.isEmpty {
                series = [KubeChartSeries(id: "total", name: "total", points: totalPoints, breaks: total.breaks)]
            } else {
                // Total: the top five stacked at the total's times, the rest as "other".
                let times = totalPoints.map(\.time)
                let within = range == .live ? step * 2.5 : 59
                let parts = shown.map { KubeChartBuild.align(cpu ? $0.usage.cpu : $0.usage.memory, to: times, within: within) }
                series = zip(shown, parts).map { KubeChartSeries(id: $0.id.name, name: $0.id.name, points: $1, breaks: total.breaks) }
                if ranked.count > shown.count {
                    series.append(KubeChartSeries(id: "other", name: "other", points: KubeChartBuild.rest(totalPoints, minus: parts), breaks: total.breaks))
                }
                stacked = true
            }
            let latest = totalPoints.last?.value
            let request = (cpu ? perPod.cpuRequest : perPod.memoryRequest).map { $0 * Double(replicas) }
            let limit = (cpu ? perPod.cpuLimit : perPod.memoryLimit).map { $0 * Double(replicas) }
            let data = KubeChartBuild.data(
                id: "\(subject).\(cpu ? "cpu" : "memory")", title: cpu ? "CPU" : "Memory", unit: unit, series: series + references(cpu), start: start, end: now,
                step: step, stacked: stacked, source: source, tier: tier, breaksMarked: breaksMarked)
            let chips = cpu ? KubePodCharts.cpuChips(latest, request: request, limit: limit) : KubePodCharts.memoryChips(latest, request: request, limit: limit)
            return KubePodCharts.Chart(data: data, headline: latest.map { "total \(unit.format($0))" }, chips: chips)
        }
        var charts = [usageChart(true), usageChart(false)]

        // W3: by revision — a Deployment's ReplicaSets, a StatefulSet's or DaemonSet's ControllerRevisions.
        let revisionWhole = input.kind + "/" + input.name
        let revisions = input.ring.parts(of: revisionWhole, in: input.namespace, now: now)
        if ["Deployment", "StatefulSet", "DaemonSet"].contains(input.kind) {
            if revisions.isEmpty {
                if !input.pods.isEmpty { notes.append("By revision: its pods' samples carry no revision label.") }
            } else {
                let series = revisions.map { part -> KubeChartSeries in
                    let hash = String(part.dropFirst("rev:".count))
                    let usage = KubeChartBuild.usage(
                        input.ring, .part(namespace: input.namespace, whole: revisionWhole, part: part), range: range, start: start, now: now)
                    return KubeChartSeries(
                        id: part, name: revisionName(hash, kind: input.kind, workload: input.name, revisions: input.revisions), points: usage.cpu, breaks: usage.breaks)
                }
                let data = KubeChartBuild.data(
                    id: "\(subject).revisions", title: "CPU by revision", unit: .cores, series: series, start: start, end: now, step: step, source: source, tier: tier,
                    breaksMarked: breaksMarked)
                charts.append(KubePodCharts.Chart(data: data, headline: "\(series.count) revision\(series.count == 1 ? "" : "s")"))
            }
        }

        // W4: replicas, as the workload's status said them while shown.
        let replicasKey = KubeStatusKey.replicas(namespace: input.namespace, kind: input.kind, name: input.name)
        let names = input.kind == "Job" ? ["active", "succeeded", "failed"] : ["available", "unavailable"]
        var replicaSeries = names.map { name -> KubeChartSeries in
            let (points, breaks) = input.statuses.points(replicasKey, name, from: start, now: now)
            return KubeChartSeries(id: name, name: name, points: points, breaks: breaks)
        }
        if input.kind != "Job" {
            let (desired, _) = input.statuses.points(replicasKey, "desired", from: start, now: now)
            if !desired.isEmpty { replicaSeries.append(KubeChartSeries(id: "desired", name: "desired", role: .guide, points: desired)) }
        }
        if let hpa = input.hpa?.status {
            replicaSeries.append(KubeChartSeries(id: "hpa.min", name: "HPA min", role: .allocatable, points: [KubeSeriesPoint(time: now, value: Double(hpa.min))]))
            replicaSeries.append(KubeChartSeries(id: "hpa.max", name: "HPA max", role: .limit, points: [KubeSeriesPoint(time: now, value: Double(hpa.max))]))
        }
        if replicaSeries.contains(where: { !$0.role.isReference && !$0.points.isEmpty }) {
            let data = KubeChartBuild.data(
                id: "\(subject).replicas", title: input.kind == "Job" ? "Pods" : "Replicas", unit: .count, series: replicaSeries, start: start, end: now,
                step: step, source: "the \(input.kind)'s status", tier: "read every minute while shown", breaksMarked: true, stepped: true)
            charts.append(KubePodCharts.Chart(data: data))
        }

        var groups = [KubeObjectCharts.Group(title: input.kind, charts: charts)]
        if let hpa = input.hpa {
            let hpaCharts = KubeHPACharts.charts(
                namespace: input.namespace, name: hpa.name, status: hpa.status, statuses: input.statuses, start: start, now: now, step: step)
            if !hpaCharts.isEmpty { groups.append(KubeObjectCharts.Group(title: "Autoscaler \(hpa.name)", charts: hpaCharts)) }
        }
        let first = total.cpu.first?.time
        if replicas > 0, perPod.cpuRequest == nil || perPod.memoryRequest == nil {
            notes.append("A container of the template sets no request: the request line is left out where it would be a partial sum.")
        }
        let built = KubeObjectCharts(
            range: range, groups: groups, caption: KubeChartBuild.caption(first: first, range: range, interval: step, of: "its pods"),
            span: KubeChartBuild.span(range), hasSamples: first != nil, notes: notes, view: view)
        return KubeChartMarkers.mark(built, changes: input.changes, window: input.window, now: now)
    }
}

// MARK: HPAs

/// An HPA's tab (H1, H2): its replicas against its bounds, and each of its
/// metrics against its target — from its status, read every 15 s while
/// shown (the controller's own sync period).
enum KubeHPACharts {
    /// More scales than this in an hour is flapping.
    static let flapping = 4

    static func build(
        namespace: String, name: String, status: KubeHPAStatus?, statuses: KubeStatusHistory, range: KubeMetricsRange, now: Date, interval: TimeInterval,
        changes: KubeChartChanges = KubeChartChanges(), window: KubeChartWindow? = nil
    ) -> KubeObjectCharts {
        let range = window?.tier ?? (range.isSampled ? range : .live)
        let start = now.addingTimeInterval(-range.span)
        let charts = charts(namespace: namespace, name: name, status: status, statuses: statuses, start: start, now: now, step: max(15, interval))
        let first = statuses.of(.hpa(namespace: namespace, name: name), now: now)?.points.first?.time
        let caption =
            first.map { "Read from the HPA's status while shown since \(KubeChartTime.clock($0)), every \(KubePodCharts.seconds(max(15, interval)))" }
            ?? "Waiting for the HPA's first reading…"
        let built = KubeObjectCharts(
            range: range, groups: [KubeObjectCharts.Group(title: "HorizontalPodAutoscaler", charts: charts)], caption: caption, span: KubeChartBuild.span(range),
            hasSamples: first != nil)
        return KubeChartMarkers.mark(built, changes: changes, window: window, now: now)
    }

    /// How many times its current replicas changed in the hour before `now`.
    static func scales(_ points: [KubeSeriesPoint], now: Date) -> Int {
        let hour = points.filter { $0.time >= now.addingTimeInterval(-3600) }
        return zip(hour, hour.dropFirst()).filter { $0.value != $1.value }.count
    }

    /// The stretches its status said ScalingLimited.
    static func limitedBands(_ statuses: KubeStatusHistory, _ key: KubeStatusKey, now: Date) -> [KubeChartBand] {
        guard let kept = statuses.of(key, now: now) else { return [] }
        var bands: [KubeChartBand] = []
        var since: Date?
        for point in kept.points {
            let limited = point.values["limited"] == 1
            if limited, since == nil { since = point.time }
            if !limited, let from = since {
                bands.append(KubeChartBand(id: "limited.\(Int(from.timeIntervalSince1970))", title: "ScalingLimited", start: from, end: point.time))
                since = nil
            }
        }
        if let from = since { bands.append(KubeChartBand(id: "limited.\(Int(from.timeIntervalSince1970))", title: "ScalingLimited", start: from, end: kept.seen)) }
        return bands
    }

    static func charts(
        namespace: String, name: String, status: KubeHPAStatus?, statuses: KubeStatusHistory, start: Date, now: Date, step: TimeInterval
    ) -> [KubePodCharts.Chart] {
        let key = KubeStatusKey.hpa(namespace: namespace, name: name)
        let subject = "hpa.\(namespace).\(name)"
        let source = "the HPA's status"
        let tier = "read every 15 s while shown"
        func line(_ id: String, _ title: String, role: KubeChartRole = .usage) -> KubeChartSeries {
            let (points, breaks) = statuses.points(key, id, from: start, now: now)
            return KubeChartSeries(id: id, name: title, role: role, points: points, breaks: breaks)
        }
        let current = line("current", "current")
        guard !current.points.isEmpty else { return [] }
        var series = [current, line("desired", "desired")]
        series += [line("min", "min", role: .allocatable), line("max", "max", role: .limit)].filter { !$0.points.isEmpty }
        let scaled = scales(current.points, now: now)
        var chips: [KubeChartChip] = []
        if scaled > flapping { chips.append(KubeChartChip(text: "flapping: \(scaled) scales in 1h", alert: true)) }
        if status?.scalingLimited == true { chips.append(KubeChartChip(text: "ScalingLimited")) }
        var out = [
            KubePodCharts.Chart(
                data: KubeChartBuild.data(
                    id: "\(subject).replicas", title: "Replicas", unit: .count, series: series, start: start, end: now, step: step, source: source, tier: tier,
                    breaksMarked: true, bands: limitedBands(statuses, key, now: now), stepped: true),
                headline: status.map { "\($0.current) now · \($0.min)–\($0.max)" }, chips: chips)
        ]
        // H2: each metric against its target.
        for metric in status?.metrics ?? [] {
            let numbers = metric.numbers
            let id = "metric.\(metric.name)"
            let currentLine = line(id + ".current", "current")
            guard !currentLine.points.isEmpty else { continue }
            let target = line(id + ".target", "target", role: .request)
            let data = KubeChartBuild.data(
                id: "\(subject).\(Self.slug(metric.name))", title: metric.name, unit: numbers.unit, series: [currentLine] + (target.points.isEmpty ? [] : [target]),
                start: start, end: now, step: step, source: source, tier: tier, breaksMarked: true, stepped: true)
            let share = numbers.current.flatMap { current in numbers.target.flatMap { KubeMetricsFormat.percent(current, of: $0) } }
            out.append(
                KubePodCharts.Chart(
                    data: data, headline: metric.current.map { "\($0) now" }, chips: share.map { [KubeChartChip(text: "\($0)% of target", alert: $0 > 100)] } ?? []))
        }
        return out
    }

    /// A metric's name as an identifier part.
    static func slug(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}

// MARK: Nodes

/// A node's tab (K1–K5): its CPU and memory against what its active pods
/// request (its pods read as objects every 5 minutes), its allocatable and
/// capacity; its pods against `allocatable.pods`; pressure and cordon as
/// bands; and its largest pods, stacked, once "Sample top pods" is pressed.
enum KubeNodeCharts {
    static let topPods = 8

    struct Input {
        var node: String
        var facts: KubeNodeFacts
        var ring: KubeUsageRing
        var statuses: KubeStatusHistory
        /// Its pods as read last (requests, phase): nil until read.
        var pods: KubeNodePods?
        /// The pods whose samples are shown stacked: nil, not sampled.
        var top: [KubeRowID]?
        var range: KubeMetricsRange
        var now: Date
        var interval: TimeInterval
        /// Its events: its warnings marked.
        var changes = KubeChartChanges()
        var window: KubeChartWindow?
    }

    static func build(_ input: Input) -> KubeObjectCharts {
        let range = input.window?.tier ?? (input.range.isSampled ? input.range : .live)
        let now = input.now
        let start = now.addingTimeInterval(-range.span)
        let usage = KubeChartBuild.usage(input.ring, .node(input.node), range: range, start: start, now: now)
        let step = KubeChartBuild.step(range, interval: input.interval, points: usage.cpu)
        let tier = KubeChartBuild.tier(range, interval: step)
        let subject = "node.\(input.node)"
        let podsKey = KubeStatusKey.nodePods(input.node)
        var notes: [String] = []
        let bands = input.facts.spells.map { spell in
            KubeChartBand(id: spell.title, title: spell.title, start: spell.since ?? start, end: now)
        }
        func chart(_ cpu: Bool) -> KubePodCharts.Chart {
            let unit: KubeChartUnit = cpu ? .cores : .bytes
            let points = cpu ? usage.cpu : usage.memory
            var series = [KubeChartSeries(id: cpu ? "cpu" : "memory", name: cpu ? "CPU" : "Memory", points: points, breaks: usage.breaks)]
            let (requested, _) = input.statuses.points(podsKey, cpu ? "cpu" : "memory", from: start, now: now)
            if !requested.isEmpty { series.append(KubeChartSeries(id: "requested", name: "requested", role: .request, points: requested)) }
            if let value = cpu ? input.facts.allocatable?.cpu : input.facts.allocatable?.memory, value > 0 {
                series.append(KubeChartSeries(id: "allocatable", name: "allocatable", role: .allocatable, points: [KubeSeriesPoint(time: now, value: value)]))
            }
            if let value = cpu ? input.facts.capacity?.cpu : input.facts.capacity?.memory, value > 0 {
                series.append(KubeChartSeries(id: "capacity", name: "capacity", role: .capacity, points: [KubeSeriesPoint(time: now, value: value)]))
            }
            let latest = points.last?.value
            var chips: [KubeChartChip] = []
            let allocatable = cpu ? input.facts.allocatable?.cpu : input.facts.allocatable?.memory
            if let latest, let percent = KubeMetricsFormat.percent(latest, of: allocatable) {
                chips.append(KubeChartChip(text: "\(percent)% of allocatable", alert: percent >= 90))
            }
            if let requested = requested.last?.value, let percent = KubeMetricsFormat.percent(requested, of: allocatable) {
                chips.append(KubeChartChip(text: "requests \(percent)% of allocatable", alert: percent > 100))
            }
            let data = KubeChartBuild.data(
                id: "\(subject).\(cpu ? "cpu" : "memory")", title: cpu ? "CPU" : "Memory", unit: unit, series: series, start: start, end: now, step: step,
                source: "metrics-server", tier: tier, breaksMarked: range == .live, bands: bands)
            return KubePodCharts.Chart(data: data, headline: latest.map { "\(unit.format($0)) now" }, chips: chips)
        }
        var charts = [chart(true), chart(false)]

        // K4: its active pods against allocatable.pods.
        let (count, breaks) = input.statuses.points(podsKey, "pods", from: start, now: now)
        if !count.isEmpty {
            var series = [KubeChartSeries(id: "pods", name: "pods", points: count, breaks: breaks)]
            if let most = input.facts.allocatablePods {
                series.append(KubeChartSeries(id: "allocatable", name: "allocatable", role: .allocatable, points: [KubeSeriesPoint(time: now, value: Double(most))]))
            }
            let latest = count.last?.value
            let percent = latest.flatMap { KubeMetricsFormat.percent($0, of: input.facts.allocatablePods.map(Double.init)) }
            charts.append(
                KubePodCharts.Chart(
                    data: KubeChartBuild.data(
                        id: "\(subject).pods", title: "Pods", unit: .count, series: series, start: start, end: now, step: step, source: "its pods, as objects",
                        tier: "read every 5 min while shown", breaksMarked: true, stepped: true),
                    headline: latest.map { "\(Int($0)) active" }, chips: percent.map { [KubeChartChip(text: "\($0)% of allocatable", alert: $0 >= 90)] } ?? []))
        }
        if input.pods?.more == true {
            notes.append("This node runs more than \(KubeNodePods.limit) pods: what they request is left out, and its pods are counted up to \(KubeNodePods.limit).")
        }

        var groups = [KubeObjectCharts.Group(title: "Node", charts: charts)]
        // K3: its largest pods, stacked at the node's sample times (one kubelet stamps them all).
        if let top = input.top {
            let times = (usage.cpu.isEmpty ? [] : usage.cpu).map(\.time)
            let within = range == .live ? step * 2.5 : 59
            func stack(_ cpu: Bool) -> KubePodCharts.Chart {
                let series = top.map { id -> KubeChartSeries in
                    let own = KubeChartBuild.usage(input.ring, .pod(id), range: range, start: start, now: now)
                    let points = KubeChartBuild.align(cpu ? own.cpu : own.memory, to: times, within: within)
                    return KubeChartSeries(id: id.description, name: id.name, points: points, breaks: usage.breaks)
                }
                return KubePodCharts.Chart(
                    data: KubeChartBuild.data(
                        id: "\(subject).top.\(cpu ? "cpu" : "memory")", title: cpu ? "Top pods' CPU" : "Top pods' memory", unit: cpu ? .cores : .bytes,
                        series: series, start: start, end: now, step: step, stacked: true, source: "metrics-server", tier: tier, breaksMarked: range == .live))
            }
            groups.append(KubeObjectCharts.Group(title: "Top pods (by request)", charts: [stack(true), stack(false)]))
        }
        let first = usage.cpu.first?.time
        let built = KubeObjectCharts(
            range: range, groups: groups, caption: KubeChartBuild.caption(first: first, range: range, interval: step, of: "this node"),
            span: KubeChartBuild.span(range), hasSamples: first != nil, notes: notes)
        return KubeChartMarkers.mark(built, changes: input.changes, window: input.window, now: now)
    }
}

// MARK: Namespaces

/// A namespace's tab (N1, N2, N4): its CPU and memory stacked by workload
/// — the top eight and "other" — against its ResourceQuota, and its pods
/// by phase; each pod's workload from the namespace's Metadata rows, else
/// read off its name ("grouped by name").
enum KubeNamespaceCharts {
    static let top = 8

    struct Input {
        var namespace: String
        var ring: KubeUsageRing
        var statuses: KubeStatusHistory
        var quota: KubeQuota?
        /// Whether the workloads came from the rows' owners (else from the names).
        var byOwner: Bool
        var range: KubeMetricsRange
        var now: Date
        var interval: TimeInterval
        /// Its own events: its warnings marked.
        var changes = KubeChartChanges()
        var window: KubeChartWindow?
    }

    static func build(_ input: Input) -> KubeObjectCharts {
        let range = input.window?.tier ?? (input.range.isSampled ? input.range : .live)
        let now = input.now
        let start = now.addingTimeInterval(-range.span)
        let total = KubeChartBuild.usage(input.ring, .namespace(input.namespace), range: range, start: start, now: now)
        let step = KubeChartBuild.step(range, interval: input.interval, points: total.cpu)
        let tier = KubeChartBuild.tier(range, interval: step)
        let subject = "namespace.\(input.namespace)"
        let rankFrom = now.addingTimeInterval(-TimeInterval(KubeUsageRing.rawSpan))
        var workloads: [(part: String, usage: KubeChartBuild.Usage, rank: Double)] = []
        for part in input.ring.parts(of: "", in: input.namespace, now: now) {
            let key = KubeUsageKey.part(namespace: input.namespace, whole: "", part: part)
            let usage = KubeChartBuild.usage(input.ring, key, range: range, start: start, now: now)
            workloads.append((part, usage, KubeChartBuild.rank(input.ring, key, usage: usage, since: rankFrom, now: now)))
        }
        workloads.sort { $0.rank == $1.rank ? $0.part < $1.part : $0.rank > $1.rank }
        let shown = Array(workloads.prefix(top))
        func name(_ part: String) -> String { part.split(separator: "/", maxSplits: 1).last.map(String.init) ?? part }

        func chart(_ cpu: Bool) -> KubePodCharts.Chart {
            let unit: KubeChartUnit = cpu ? .cores : .bytes
            let totalPoints = cpu ? total.cpu : total.memory
            let times = totalPoints.map(\.time)
            let within = range == .live ? step * 2.5 : 59
            let parts = shown.map { KubeChartBuild.align(cpu ? $0.usage.cpu : $0.usage.memory, to: times, within: within) }
            var series = zip(shown, parts).map { KubeChartSeries(id: $0.part, name: name($0.part), points: $1, breaks: total.breaks) }
            if series.isEmpty {
                series = [KubeChartSeries(id: "total", name: "total", points: totalPoints, breaks: total.breaks)]
            } else if workloads.count > shown.count {
                series.append(KubeChartSeries(id: "other", name: "other", points: KubeChartBuild.rest(totalPoints, minus: parts), breaks: total.breaks))
            }
            let hard = cpu ? input.quota?.cpuHard : input.quota?.memoryHard
            let used = cpu ? input.quota?.cpuUsed : input.quota?.memoryUsed
            series += [
                KubeChartBuild.reference("quota", "quota (requests)", .quota, hard, at: now), KubeChartBuild.reference("quota.used", "quota used", .guide, used, at: now),
            ].compactMap { $0 }
            let latest = totalPoints.last?.value
            var chips: [KubeChartChip] = []
            if let used, let hard, let percent = KubeMetricsFormat.percent(used, of: hard) {
                chips.append(KubeChartChip(text: "requests \(percent)% of quota", alert: percent >= 90))
            }
            let data = KubeChartBuild.data(
                id: "\(subject).\(cpu ? "cpu" : "memory")", title: cpu ? "CPU" : "Memory", unit: unit, series: series, start: start, end: now, step: step,
                stacked: series.filter { !$0.role.isReference }.count > 1, source: "metrics-server",
                tier: tier + (input.byOwner ? " · by owner" : " · grouped by name"), breaksMarked: range == .live)
            return KubePodCharts.Chart(data: data, headline: latest.map { "total \(unit.format($0))" }, chips: chips)
        }
        var charts = [chart(true), chart(false)]

        // N4: pods by phase, stacked, as the rows said them.
        let key = KubeStatusKey.phases(input.namespace)
        let phases = KubePodPhase.order.map { phase -> KubeChartSeries in
            let (points, breaks) = input.statuses.points(key, phase, from: start, now: now)
            return KubeChartSeries(id: phase, name: phase, points: points, breaks: breaks)
        }.filter { $0.points.contains { $0.value > 0 } }
        if !phases.isEmpty {
            charts.append(
                KubePodCharts.Chart(
                    data: KubeChartBuild.data(
                        id: "\(subject).phases", title: "Pods by phase", unit: .count, series: phases, start: start, end: now, step: step, stacked: true,
                        source: "its pods' rows", tier: "read every minute while shown", breaksMarked: true, stepped: true)))
        }
        var notes: [String] = []
        if !input.byOwner, !workloads.isEmpty { notes.append("Grouped by the pods' names: the namespace's rows weren't read yet.") }
        if input.quota?.isEmpty ?? true { notes.append("No ResourceQuota on requests here: no quota line.") }
        let first = total.cpu.first?.time
        let built = KubeObjectCharts(
            range: range, groups: [KubeObjectCharts.Group(title: "Namespace", charts: charts)],
            caption: KubeChartBuild.caption(first: first, range: range, interval: step, of: "its pods"), span: KubeChartBuild.span(range),
            hasSamples: first != nil, notes: notes)
        return KubeChartMarkers.mark(built, changes: input.changes, window: input.window, now: now)
    }
}
