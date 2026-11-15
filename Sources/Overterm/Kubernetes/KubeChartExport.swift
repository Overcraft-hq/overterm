import Foundation

/// One query a chart was drawn from, as it was sent: its id among the
/// tab's (`KubeTabQuery.id`) and its PromQL — what "Copy PromQL" gives.
struct KubeChartQuery: Equatable, Sendable {
    var id: String
    var promql: String
    var instant = false
}

/// What a chart's context menu copies (docs/design/kubernetes/metrics.md
/// 3.9; stage M9): "Copy PromQL", the exact queries a Prometheus chart was
/// drawn from — to paste into Grafana —, and "Copy Values as CSV", the
/// window it shows, a row a time and a column a series, every cell inert
/// as the list's export makes it (`KubeListExport.inert`): a series' name
/// is anybody's (a pod's, a saved query's labels). Only ever to the
/// clipboard: nothing is written to disk. Pure.
enum KubeChartExport {
    // MARK: PromQL

    /// The query ids a tab's chart is drawn from, by its id's last parts
    /// (`<subject>.<measure>`): its usage, the peaks and the RSS beside it,
    /// a workload's or a namespace's top N, the reference lines Prometheus
    /// gave (a namespace's quota, a node's conditions), a saved query's own.
    static func queryIDs(forChart id: String) -> [String] {
        let parts = id.split(separator: ".").map(String.init)
        guard let last = parts.last else { return [] }
        if parts.count >= 2, parts[parts.count - 2] == "saved" { return [KubeSavedQueries.id(Int(last) ?? 0)] }
        if parts.count >= 2, parts[parts.count - 2] == "top" { return last == "cpu" ? ["topCPU"] : ["topMemory"] }
        if parts.count >= 2, parts[parts.count - 2] == "gpu" { return ["gpu"] }
        if parts.dropLast().contains("disk") { return ["disks"] }
        switch last {
        case "cpu": return ["cpu", "cpuTop", "cpuPeak", "quota", "idle", "conditions"]
        case "memory": return ["memory", "memoryTop", "rss", "quota", "idle", "conditions"]
        case "throttling": return ["throttling"]
        case "fs": return ["fs"]
        case "network": return ["network", "nodeNetwork"]
        case "restarts": return ["restarts"]
        case "revisions": return ["revisions"]
        case "replicas": return ["replicas", "hpa"]
        case "pods": return ["pods"]
        case "phases": return ["phases"]
        // An HPA's metric, by its slug: every metric is the one query's.
        default: return ["hpaMetrics"]
        }
    }

    /// `data` with the queries it was drawn from, those `sent` holds: a
    /// Prometheus chart only — a sampled one has none.
    static func attach(_ data: KubeChartData, sent: [KubeTabQuery]) -> KubeChartData {
        guard data.source == "Prometheus", !sent.isEmpty else { return data }
        var out = data
        out.queries = queryIDs(forChart: data.id).compactMap { id in
            sent.first { $0.id == id }.map { KubeChartQuery(id: $0.id, promql: $0.promql, instant: $0.instant) }
        }
        return out
    }

    static func attach(_ charts: KubePodCharts, sent: [KubeTabQuery]) -> KubePodCharts {
        guard !sent.isEmpty else { return charts }
        var out = charts
        out.pod = charts.pod.map { attach($0, sent: sent) }
        out.sections = charts.sections.map { section in
            var section = section
            section.charts = section.charts.map { attach($0, sent: sent) }
            return section
        }
        return out
    }

    static func attach(_ charts: KubeObjectCharts, sent: [KubeTabQuery]) -> KubeObjectCharts {
        guard !sent.isEmpty else { return charts }
        var out = charts
        out.groups = charts.groups.map { group in
            var group = group
            group.charts = group.charts.map { attach($0, sent: sent) }
            return group
        }
        return out
    }

    private static func attach(_ chart: KubePodCharts.Chart, sent: [KubeTabQuery]) -> KubePodCharts.Chart {
        var out = chart
        out.data = attach(chart.data, sent: sent)
        return out
    }

    /// An Overview's or a claim's chart (X1–X3, V1, V2; metrics.md 2.1:
    /// "as the Metrics tab") with the queries its reading sent for the
    /// measure it draws: its line's (a union carrying its totals), its
    /// totals asked alone, its parts'; a volume's capacity and fill with
    /// its use. Its measure is its id's last part (`KubeChartData.of`).
    static func attach(_ data: KubeChartData, reading: KubeChartReading) -> KubeChartData {
        guard data.source == "Prometheus", !reading.queries.isEmpty, let last = data.id.split(separator: ".").last else { return data }
        let drawn = last == "used" ? KubeChartMeasure.volumeUsed : KubeChartMeasure(rawValue: String(last))
        guard let drawn else { return data }
        func line(_ measure: KubeChartMeasure) -> KubeChartMeasure {
            switch measure {
            case .volumeCapacity, .volumeAvailable, .volumeFill: .volumeUsed
            default: measure.resource
            }
        }
        var out = data
        out.queries = reading.queries.filter { query in
            guard let word = query.id.split(separator: " ").first, let measure = KubeChartMeasure(rawValue: String(word)) else { return false }
            return line(measure) == line(drawn)
        }
        return out
    }

    /// What "Copy PromQL" puts on the clipboard: the one query as it was
    /// sent, or each after a `#` line naming it (a comment Grafana's editor
    /// keeps); nil for a chart with none (sampled).
    static func promQL(_ data: KubeChartData) -> String? { promQL(data.queries) }

    static func promQL(_ queries: [KubeChartQuery]) -> String? {
        guard !queries.isEmpty else { return nil }
        if queries.count == 1 { return queries[0].promql }
        return queries.map { "# \($0.id)\($0.instant ? " (instant)" : "")\n\($0.promql)" }.joined(separator: "\n\n")
    }

    // MARK: CSV

    /// The chart's values over the window it shows: `time` (ISO 8601, UTC),
    /// then a column a series drawn — those hidden in its legend left out,
    /// the reference lines too when they are — named with its unit. A row
    /// for each time a line has a point; a line without one there is
    /// empty (a gap stays a gap); a reference line holds its last value
    /// (before its first, the first: it is drawn across).
    static func csv(_ data: KubeChartData, hidden: Set<String> = [], hideReferences: Bool = false) -> String {
        let shown = data.series.filter { series in
            series.role.isReference ? !hideReferences : !hidden.contains(series.id)
        }
        let lines = shown.filter { !$0.role.isReference }
        let references = shown.filter(\.role.isReference)
        func inside(_ point: KubeSeriesPoint) -> Bool { point.time >= data.start && point.time <= data.end }
        var times = Set(lines.flatMap { $0.points.filter(inside).map(\.time) })
        if times.isEmpty { times = Set(references.flatMap { $0.points.filter(inside).map(\.time) }) }
        let sorted = times.sorted()
        let unit = unitName(data.unit)
        let columns = ["time"] + shown.map { "\($0.name) (\(unit))" }
        let byTime = lines.map { line in Dictionary(line.points.map { ($0.time, $0.value) }, uniquingKeysWith: { _, last in last }) }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let rows = sorted.map { time -> [String] in
            var row = [formatter.string(from: time)]
            for values in byTime { row.append(values[time].map(number) ?? "") }
            for reference in references { row.append(held(reference.points, at: time).map(number) ?? "") }
            return row
        }
        return KubeListExport.csv(columns: columns, rows: rows)
    }

    /// A reference line's value at `time`: its last point at or before it, else its first.
    static func held(_ points: [KubeSeriesPoint], at time: Date) -> Double? {
        var value = points.first?.value
        for point in points {
            guard point.time <= time else { break }
            value = point.value
        }
        return value
    }

    /// A value as a spreadsheet reads it: plain, in the chart's base unit.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : value > 0 ? "+Inf" : "-Inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// The unit a column's values are in (never the scaled one the chart says).
    static func unitName(_ unit: KubeChartUnit) -> String {
        switch unit {
        case .cores: "cores"
        case .bytes: "bytes"
        case .bytesPerSecond: "bytes/s"
        case .ratio: "ratio"
        case .count: "count"
        case .watts: "W"
        case .celsius: "°C"
        case .perSecond: "per second"
        case .seconds: "seconds"
        }
    }
}
