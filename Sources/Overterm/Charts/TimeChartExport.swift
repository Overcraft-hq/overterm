import Foundation

/// A chart as text: its PromQL, and its values as CSV (the chart's menu).
package enum TimeChartExport {
    package static func promQL(_ data: TimeChartData) -> String? { promQL(data.queries) }

    package static func promQL(_ queries: [KubeChartQuery]) -> String? {
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
    package static func csv(_ data: TimeChartData, hidden: Set<String> = [], hideReferences: Bool = false) -> String {
        let shown = data.series.filter { series in
            series.role.isReference ? !hideReferences : !hidden.contains(series.id)
        }
        let lines = shown.filter { !$0.role.isReference }
        let references = shown.filter(\.role.isReference)
        func inside(_ point: TimeChartPoint) -> Bool { point.time >= data.start && point.time <= data.end }
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
        return ListExport.csv(columns: columns, rows: rows)
    }

    /// A reference line's value at `time`: its last point at or before it, else its first.
    package static func held(_ points: [TimeChartPoint], at time: Date) -> Double? {
        var value = points.first?.value
        for point in points {
            guard point.time <= time else { break }
            value = point.value
        }
        return value
    }

    /// A value as a spreadsheet reads it: plain, in the chart's base unit.
    package static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : value > 0 ? "+Inf" : "-Inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// The unit a column's values are in (never the scaled one the chart says).
    package static func unitName(_ unit: TimeChartUnit) -> String {
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
