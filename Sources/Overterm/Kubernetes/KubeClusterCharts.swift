import Foundation

// The Overview's usage (docs/design/kubernetes/metrics.md 2.9, X1–X4;
// stage M8): the cluster's CPU and memory against what its nodes can give
// and what its active pods request (X1, X2), its CPU by namespace — the
// top eight and the rest (X3) —, its nodes as small multiples, a row of
// two 60-cell strips each (X4); and a claim's fill forecast (V1), its
// inodes (V2). Sampled from metrics-server while shown, or from
// Prometheus over the range picked. The queries and the builders. Pure.

extension KubePromQL {
    /// The nodes' capacity, summed (X1, X2's line beside allocatable).
    static func capacity(_ resource: String, profile: KubePromProfile = .unknown) -> String {
        if profile.ksmMajor == 1 {
            return "sum(max by (node)(kube_node_status_capacity_\(resource == "cpu" ? "cpu_cores" : resource + "_bytes"){\(profile.ksmMatcher)}))"
        }
        let job = profile.ksmMatcher
        return "sum(max by (node)(kube_node_status_capacity{\(job.isEmpty ? "" : job + ",")resource=\"\(literal(resource))\"}))"
    }

    /// The claim's matchers.
    static func claim(_ namespace: String, _ claim: String) -> String { matchers([("namespace", namespace), ("persistentvolumeclaim", claim)]) }

    /// How fast it fills, in bytes a second: its available bytes' fall over
    /// six hours, `deriv`'s least-squares slope (V1) — the same line
    /// `predict_linear` would extend, so it alone is asked: the chip's ETA
    /// and the projection both follow from it.
    static func volumeFill(namespace: String, claim: String) -> String {
        "-sum(deriv(\(volumeAvailable){\(self.claim(namespace, claim))}[6h]))"
    }

    /// Its inodes used, a fraction (V2).
    static func volumeInodes(namespace: String, claim: String) -> String {
        let selector = self.claim(namespace, claim)
        return "sum(kubelet_volume_stats_inodes_used{\(selector)}) / sum(kubelet_volume_stats_inodes{\(selector)})"
    }
}

extension KubeChart {
    /// How many namespaces X3 names; the rest is "other".
    static let topNamespaces = 8

    /// X3's tier over `range`: the mixin's per-container CPU rule, else raw
    /// cAdvisor where `KubeQueryCost` allows it across the cluster (≤ 6h).
    static func namespaceTier(_ range: KubeChartRange, profile: KubePromProfile) -> KubePromTier? {
        if profile.containerCPURule != nil { return .rules }
        return KubeQueryCost.raw(.cluster, span: range.seconds, profile: profile).isAllowed ? .raw : nil
    }

    /// The namespaces picked as a matcher; none, every one.
    private static func picked(_ names: [String]) -> String { names.isEmpty ? "" : KubePromQL.namespaces(names) }

    /// X3's ranking (metrics.md 4.5, 4.6): one instant `topk` at the range's
    /// end over the whole range — the rule's average, or the raw counter's
    /// rate over the range (no subquery), either ranked over the last 24h
    /// past the samples cap, said; nil where neither tier reads.
    static func namespaceRanking(range: KubeChartRange, profile: KubePromProfile, picked names: [String]) -> (query: String, note: String?)? {
        let picked = picked(names)
        switch namespaceTier(range, profile: profile) {
        case .rules:
            guard let rule = profile.containerCPURule else { return nil }
            // The rule's average reads every sample over the range: a
            // rule every scrape, by its own count (else cAdvisor's).
            let series = profile.count(rule) ?? profile.count(KubePromProfile.cpuMetric) ?? 0
            let (span, note) = KubeQueryCost.rankingSpan(series: series, span: range.seconds, scrape: profile.scrapeInterval)
            let selector = KubeTabQueries.joined([picked, #"container!="""#, #"container!="POD""#])
            return (
                "topk(\(topNamespaces), sum by (namespace)(max by (namespace,pod,container)(avg_over_time(\(rule){\(selector)}[\(KubePromQL.duration(span))]))))",
                note
            )
        case .raw:
            let (span, note) = KubeQueryCost.rankingSpan(series: profile.count(KubePromProfile.cpuMetric) ?? 0, span: range.seconds, scrape: profile.scrapeInterval)
            let window = KubePromQL.duration(max(span, 4 * profile.scrapeInterval))
            let selector = KubeTabQueries.joined([profile.cadvisorMatchers, picked])
            return ("topk(\(topNamespaces), sum by (namespace)(rate(\(KubePromProfile.cpuMetric){\(selector)}[\(window)])))", note)
        default:
            return nil
        }
    }

    /// X3's lines: the total of the namespaces picked, and the top ones by
    /// namespace (`top`, as ranked; none yet, the total alone).
    static func namespaceQueries(range: KubeChartRange, profile: KubePromProfile, picked names: [String], top: [String]) -> KubeChartQueries {
        let picked = picked(names)
        let window = KubePromQL.duration(KubeRateWindow.of(step: range.step, scrape: profile.scrapeInterval))
        let tier = namespaceTier(range, profile: profile)
        var queries = KubeChartQueries(series: [], totals: [], tier: tier)
        queries.partLabel = "namespace"
        switch tier {
        case .rules:
            guard let rule = profile.containerCPURule else { break }
            let selector = KubeTabQueries.joined([picked, #"container!="""#, #"container!="POD""#])
            queries.series = [(.cpu, "sum(max by (namespace,pod,container)(\(rule){\(selector)}))")]
            if !top.isEmpty {
                let named = KubeTabQueries.joined([KubePromQL.namespaces(top), #"container!="""#, #"container!="POD""#])
                queries.parts = [(.cpu, "sum by (namespace)(max by (namespace,pod,container)(\(rule){\(named)}))")]
            }
        case .raw:
            queries.series = [(.cpu, "sum(" + KubePromQL.containerRate(KubePromProfile.cpuMetric, picked, window: window, profile: profile) + ")")]
            if !top.isEmpty {
                queries.parts = [
                    (.cpu, "sum by (namespace)(" + KubePromQL.containerRate(KubePromProfile.cpuMetric, KubePromQL.namespaces(top), window: window, profile: profile) + ")")
                ]
            }
        default:
            let refused = profile.known ? KubeQueryCost.raw(.cluster, span: range.seconds, profile: profile).sentence : nil
            queries.refused = refused ?? rawRefusal(range)
        }
        return queries
    }

    /// X4's step: the range as 60 cells.
    static func nodeStep(_ range: KubeChartRange) -> TimeInterval { range.seconds / Double(KubeHeatStrip.cellCount) }

    /// X4: each node's CPU and memory over the range at a sixtieth of it —
    /// the mixin's per-container rules (they carry `node`), else raw
    /// cAdvisor by the profile's node label where it may be read across the
    /// cluster; each cell's highest kept past 5-minute steps. Each node's
    /// allocatable from kube-state-metrics, by node.
    static func nodeQueries(range: KubeChartRange, profile: KubePromProfile) -> KubeChartQueries {
        let step = nodeStep(range)
        let stepText = KubePromQL.duration(step)
        let peaks = step >= 300
        func gauge(_ selector: String) -> String { peaks ? "max_over_time(\(selector)[\(stepText)])" : selector }
        var queries = KubeChartQueries(series: [], totals: [])
        queries.step = step
        // Each measure's allocatable rides with its usage: a query a measure (metrics.md 6.5).
        queries.unioned = true
        let containers = KubeTabQueries.joined([#"container!="""#, #"container!="POD""#])
        if profile.hasContainerRules, let rule = profile.containerCPURule {
            queries.tier = .rules
            queries.partLabel = "node"
            queries.parts = [
                (.cpu, "sum by (node)(max by (node,namespace,pod,container)(\(gauge("\(rule){\(containers)}"))))"),
                (.memory, "sum by (node)(max by (node,namespace,pod,container)(\(gauge("\(KubePromProfile.containerMemoryRule){\(containers)}"))))"),
            ]
        } else if KubeQueryCost.raw(.cluster, span: range.seconds, profile: profile).isAllowed {
            guard let label = profile.known ? profile.nodeLabel : .node else {
                queries.refused = "cAdvisor's series here name no node (neither node nor instance): the nodes' usage can't be told apart."
                return queries
            }
            let window = KubePromQL.duration(KubeRateWindow.of(step: step, scrape: profile.scrapeInterval))
            let by = "\(label.rawValue),namespace,pod,container"
            queries.tier = .raw
            queries.partLabel = label.rawValue
            queries.parts = [
                (.cpu, "sum by (\(label.rawValue))(sum by (\(by))(rate(\(KubePromProfile.cpuMetric){\(profile.cadvisorMatchers)}[\(window)])))"),
                (.memory, "sum by (\(label.rawValue))(max by (\(by))(\(gauge("\(KubePromProfile.memoryMetric){\(profile.cadvisorMatchers)}"))))"),
            ]
        } else {
            let refused = profile.known ? KubeQueryCost.raw(.cluster, span: range.seconds, profile: profile).sentence : nil
            queries.refused = refused ?? rawRefusal(range)
            return queries
        }
        if !profile.ksmMissing {
            func allocatable(_ resource: String) -> String {
                if profile.ksmMajor == 1 {
                    return "max by (node)(kube_node_status_allocatable_\(resource == "cpu" ? "cpu_cores" : "memory_bytes"){\(profile.ksmMatcher)})"
                }
                return "max by (node)(kube_node_status_allocatable{\(KubeTabQueries.joined([profile.ksmMatcher, "resource=\"\(resource)\""]))})"
            }
            queries.partTotals = [(.cpuAllocatable, allocatable("cpu")), (.memoryAllocatable, allocatable("memory"))]
        }
        return queries
    }
}

/// A node's row of X4: its CPU's and memory's strips, as a share of its allocatable.
struct KubeNodeStripRow: Equatable, Sendable, Identifiable {
    var node: String
    var cpu: KubeHeatStrip?
    var memory: KubeHeatStrip?
    var id: String { node }

    /// What it is ranked by: the larger of its two shares now (else at their peak).
    var hottest: Double {
        [cpu, memory].compactMap { $0.flatMap { $0.now ?? $0.peak?.percent } }.max() ?? -1
    }
}

/// The Overview's charts, built from what was read. Pure.
enum KubeClusterCharts {
    /// X4 names this many nodes at most: the hottest.
    static let nodesAtMost = 50

    /// X1 and X2 from Prometheus: the cluster's CPU and memory against its
    /// active pods' requests and limits, its allocatable and capacity, with
    /// the requests' and limits' shares of allocatable as chips — red past
    /// all of it, overcommitted.
    static func prometheus(_ reading: KubeChartReading) -> [KubePodCharts.Chart] {
        [true, false].map { isCPU in
            KubePodCharts.Chart(data: KubeChartData.of(reading, chart: .cluster, measure: isCPU ? .cpu : .memory), chips: chips(reading, cpu: isCPU))
        }
    }

    static func chips(_ reading: KubeChartReading, cpu: Bool) -> [KubeChartChip] {
        let (requests, limits, allocatable): (KubeChartMeasure, KubeChartMeasure, KubeChartMeasure) =
            cpu ? (.cpuRequests, .cpuLimits, .cpuAllocatable) : (.memoryRequests, .memoryLimits, .memoryAllocatable)
        return [("requests", requests), ("limits", limits)].compactMap { name, measure in
            reading.share(measure, of: allocatable)?.percent.map { share(name, $0) }
        }
    }

    /// `requests 71% of allocatable`; past 100%, red and said overcommitted.
    static func share(_ what: String, _ percent: Int) -> KubeChartChip {
        KubeChartChip(text: "\(what) \(percent)% of allocatable" + (percent > 100 ? " · overcommitted" : ""), alert: percent > 100)
    }

    /// The chip a sampled X1 or X2 carries in place of the requests' share.
    static let requestsNeedPrometheus = "requests need Prometheus (kube-state-metrics)"

    /// X1 and X2 sampled: the cluster's samples taken while the Overview
    /// showed, against the nodes' allocatable and capacity (the `/nodes`
    /// read it already makes) — no requests line: the Pods section's rows
    /// carry no spec, and a cluster-wide list of pod objects is never read
    /// for it (metrics.md 2.9).
    static func sampled(_ points: [KubeUsagePoint], allocatable: KubeUsage?, capacity: KubeUsage?, interval: TimeInterval, now: Date) -> [KubePodCharts.Chart] {
        let start = min(points.first?.time ?? now, now.addingTimeInterval(-600))
        let end = max(points.last?.time ?? now, start.addingTimeInterval(1))
        return [true, false].map { isCPU in
            let unit: KubeChartUnit = isCPU ? .cores : .bytes
            let usage = points.map { KubeSeriesPoint(time: $0.time, value: isCPU ? $0.usage.cpu : $0.usage.memory) }
            let allocated = allocatable.map { isCPU ? $0.cpu : $0.memory }
            var series = [KubeChartSeries(id: isCPU ? "cpu" : "memory", name: isCPU ? "CPU" : "Memory", points: usage)]
            if let line = KubeChartBuild.reference("allocatable", "allocatable", .allocatable, allocated, at: end) { series.append(line) }
            if let line = KubeChartBuild.reference("capacity", "capacity", .capacity, capacity.map { isCPU ? $0.cpu : $0.memory }, at: end) { series.append(line) }
            var chips: [KubeChartChip] = []
            if let last = usage.last?.value, let percent = KubeMetricsFormat.percent(last, of: allocated) {
                chips.append(KubeChartChip(text: "\(percent)% of allocatable", alert: percent >= 90))
            }
            chips.append(KubeChartChip(text: requestsNeedPrometheus))
            let data = KubeChartBuild.data(
                id: isCPU ? "cluster.cpu" : "cluster.memory", title: isCPU ? "CPU" : "Memory", unit: unit, series: series, start: start, end: end,
                step: KubeChartBuild.step(.live, interval: interval, points: usage), source: "metrics-server",
                tier: KubeChartBuild.tier(.live, interval: interval), breaksMarked: false)
            return KubePodCharts.Chart(data: data, headline: usage.last.map { unit.format($0.value) + " now" }, chips: chips)
        }
    }

    /// X3 from Prometheus: the top namespaces by CPU, as ranked, stacked,
    /// and "other" — the total less them; nil where its lines weren't asked.
    static func namespaces(_ reading: KubeChartReading) -> KubePodCharts.Chart? {
        guard reading.refused == nil, let total = reading.series[.cpu] else { return nil }
        let window = reading.range.window(now: reading.read ?? Date())
        let parts = reading.parts[.cpu] ?? [:]
        var series = (reading.ranked ?? []).compactMap { name in parts[name].map { KubeChartSeries(id: name, name: name, points: $0) } }
        let rest = KubeChartBuild.rest(total, minus: series.map(\.points))
        if series.isEmpty || rest.contains(where: { $0.value > 0 }) {
            series.append(KubeChartSeries(id: "other", name: series.isEmpty ? "all namespaces" : "other", points: rest))
        }
        let data = KubeChartBuild.data(
            id: "cluster.namespaces.cpu", title: "CPU by namespace", unit: .cores, series: series, start: window.start, end: window.end, step: reading.range.step,
            stacked: true, source: "Prometheus", tier: (reading.tier ?? .raw).title, breaksMarked: false)
        let top = series.first { $0.id != "other" }
        return KubePodCharts.Chart(
            data: data, headline: total.last.map { "\(KubeMetricsFormat.cpu($0.value)) now" },
            chips: top.flatMap { line in line.points.last.map { [KubeChartChip(text: "most: \(line.name) \(KubeMetricsFormat.cpu($0.value))")] } } ?? [])
    }

    /// X4 sampled: each node's strips from the ring's list keys (the last
    /// 15 minutes the Overview's `/nodes` read sampled), against its allocatable.
    static func nodeRows(_ ring: KubeUsageRing, allocatable: [String: KubeUsage], now: Date) -> (rows: [KubeNodeStripRow], more: Int) {
        let rows = allocatable.keys.map { name -> KubeNodeStripRow in
            let segments = ring.segments(.node(name), .list, now: now)
            let node = allocatable[name]
            return KubeNodeStripRow(
                node: name, cpu: KubeHeatStrip.of(segments, .cpu, allocatable: node?.cpu), memory: KubeHeatStrip.of(segments, .memory, allocatable: node?.memory))
        }
        return top(rows.filter { $0.cpu != nil || $0.memory != nil })
    }

    /// X4 from Prometheus: each node's lines as 60 cells over the range,
    /// against its allocatable — kube-state-metrics', else the `/nodes` read's.
    static func nodeRows(_ reading: KubeChartReading, allocatable fallback: [String: KubeUsage]) -> (rows: [KubeNodeStripRow], more: Int) {
        guard reading.refused == nil, let read = reading.read else { return ([], 0) }
        let window = reading.range.window(now: read)
        let cpu = reading.parts[.cpu] ?? [:]
        let memory = reading.parts[.memory] ?? [:]
        let rows = Set(cpu.keys).union(memory.keys).filter { !$0.isEmpty }.map { name -> KubeNodeStripRow in
            let cpuAllocatable = reading.partTotals[.cpuAllocatable]?[name] ?? fallback[name]?.cpu
            let memoryAllocatable = reading.partTotals[.memoryAllocatable]?[name] ?? fallback[name]?.memory
            return KubeNodeStripRow(
                node: name, cpu: KubeHeatStrip.of(cpu[name] ?? [], .cpu, allocatable: cpuAllocatable, start: window.start, end: window.end),
                memory: KubeHeatStrip.of(memory[name] ?? [], .memory, allocatable: memoryAllocatable, start: window.start, end: window.end))
        }
        // A node with no allocatable read has no share to draw.
        return top(rows.filter { $0.cpu != nil || $0.memory != nil })
    }

    /// The hottest `nodesAtMost`, by name; how many more there are.
    static func top(_ rows: [KubeNodeStripRow]) -> (rows: [KubeNodeStripRow], more: Int) {
        let kept = rows.sorted { $0.hottest != $1.hottest ? $0.hottest > $1.hottest : $0.node < $1.node }.prefix(nodesAtMost)
        return (kept.sorted { $0.node < $1.node }, max(0, rows.count - nodesAtMost))
    }

    /// A row's strip identifier: `kubernetes.overview.heat.<node>.cpu`.
    static func stripIdentifier(_ node: String, _ measure: KubeUsageCell.Measure) -> String {
        "kubernetes.overview.heat.\(node).\(measure == .cpu ? "cpu" : "memory")"
    }
}

/// A claim's fill forecast (V1): how fast it fills by the last six hours'
/// trend, when it will be full, and the dotted projection to the chart's
/// right edge. None for a volume with no fixed size (EFS). Pure.
enum KubeVolumeForecast {
    /// A fill past this is said "not filling": a year.
    static let farthest: TimeInterval = 365 * 86400
    /// The chart reaches this share of its range past now, for the projection.
    static let ahead = 0.25

    /// Bytes a second it fills, `deriv`'s; nil, not read.
    static func rate(_ reading: KubeChartReading) -> Double? { reading.totals[.volumeFill] }

    /// "full in ~3 d", "full in ~5 h" (red under a day), or "not filling"; nil, nothing read.
    static func chip(available: Double?, rate: Double?) -> KubeChartChip? {
        guard let rate else { return nil }
        guard rate > 0, let available else { return KubeChartChip(text: "not filling") }
        let eta = max(0, available) / rate
        guard eta < farthest else { return KubeChartChip(text: "not filling") }
        return KubeChartChip(text: "full in ~\(spoken(eta))", alert: eta < 86400)
    }

    /// `40 min`, `5 h`, `3 d`.
    static func spoken(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded()))) min" }
        if seconds < 48 * 3600 { return "\(Int((seconds / 3600).rounded())) h" }
        return "\(Int((seconds / 86400).rounded())) d"
    }

    /// The projection from the last point used, at `rate`, to `end` — or to
    /// the capacity, where it gets there first. Nil where it doesn't fill.
    static func projection(from last: KubeSeriesPoint, rate: Double, capacity: Double, until end: Date) -> KubeChartSeries? {
        guard rate > 0, end > last.time, capacity > last.value else { return nil }
        let full = last.time.addingTimeInterval((capacity - last.value) / rate)
        let stop = min(end, full)
        let value = min(capacity, last.value + rate * stop.timeIntervalSince(last.time))
        return KubeChartSeries(id: "forecast", name: "forecast", role: .projection, points: [last, KubeSeriesPoint(time: stop, value: value)])
    }

    /// What a volume with no fixed size says in place of its share and forecast.
    static func unbounded(_ capacity: Double) -> String {
        "The volume reports \(KubeVolumeFormat.bytes(capacity)) of capacity, as EFS does: it has no fixed size, so there is no share of it and no forecast."
    }
}
