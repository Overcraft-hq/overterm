import Foundation

/// The detail's and the meters' charts from `ActivityRing` (docs/design/
/// activity/analysis.md, 6.4, 6.11; D-21): `Charts/`'s time charts over the
/// last 15 minutes, a gap where nothing was read. Pure.
enum ActivityHistoryCharts {
    /// The window shown: the ring's detail span.
    static let span: TimeInterval = Double(ActivityRing.detailSpan) / 1e9

    /// One measure of a detail's points.
    struct Measure: Sendable {
        let id: String
        let title: String
        let unit: TimeChartUnit
        /// Each series: its name and how a point's value is read.
        let series: [(name: String, value: @Sendable (ActivityRing.Point) -> Float32)]
        /// Shown only when it has a value somewhere: energy where the
        /// kernel counts it, disk where anything was read or written.
        var onlyWhenAny = false
    }

    static let processMeasures: [Measure] = [
        Measure(id: "cpu", title: "CPU", unit: .ratio, series: [("CPU", { $0.cpu / 100 })]),
        Measure(id: "memory", title: "Memory", unit: .bytes, series: [("Memory", { $0.memory })]),
        Measure(id: "energy", title: "Energy (estimate)", unit: .watts, series: [("Energy", { $0.energy })], onlyWhenAny: true),
        Measure(id: "wakeups", title: "Idle wake-ups", unit: .perSecond, series: [("Idle wake-ups", { $0.idleWakeups })], onlyWhenAny: true),
        Measure(
            id: "disk", title: "Disk", unit: .bytesPerSecond, series: [("Read", { $0.diskRead }), ("Write", { $0.diskWritten })],
            onlyWhenAny: true),
    ]

    static let systemMeasures: [Measure] = [
        Measure(id: "cpu", title: "CPU, every core", unit: .ratio, series: [("CPU", { $0.cpu / 100 })]),
        Measure(id: "memory", title: "Memory used", unit: .bytes, series: [("Used", { $0.memory })]),
    ]

    /// `key`'s charts in `snapshot`'s history; `subject` the identifier's
    /// part naming it (`process.4242`, `system`). None without a detail.
    static func charts(_ key: ActivityRingKey, subject: String, measures: [Measure], in snapshot: ActivitySnapshot) -> [TimeChartData] {
        var points = snapshot.history.points(key)
        // Selected a moment ago: its strip's cells until its samples come.
        if !points.contains(where: { !$0.isBreak }) { points = snapshot.history.cellPoints(key, now: snapshot.historyNow) }
        guard points.contains(where: { !$0.isBreak }) else { return [] }
        let end = snapshot.date
        let start = end.addingTimeInterval(-span)
        var charts: [TimeChartData] = []
        for measure in measures {
            var any = false
            let series: [TimeChartSeries] = measure.series.enumerated().map { index, part in
                var made: [TimeChartPoint] = []
                var breaks = Set<Date>()
                var broken = false
                for point in points {
                    if point.isBreak {
                        broken = !made.isEmpty
                        continue
                    }
                    let value = part.value(point)
                    guard !value.isNaN else {
                        broken = !made.isEmpty
                        continue
                    }
                    let time = snapshot.date(of: point.time)
                    if broken { breaks.insert(time) }
                    broken = false
                    if value != 0 { any = true }
                    made.append(TimeChartPoint(time: time, value: Double(value)))
                }
                return TimeChartSeries(id: "\(measure.id).\(index)", name: part.name, points: made, breaks: breaks)
            }
            guard series.contains(where: { !$0.points.isEmpty }), !measure.onlyWhenAny || any else { continue }
            var data = TimeChartData(
                id: "\(subject).\(measure.id)", title: measure.title, unit: measure.unit, series: series, start: start, end: end,
                step: Double(ActivityRing.breakAfter) / 1e9)
            data.scope = "activity"
            data.breaksMarked = true
            data.source = "sampled while shown"
            data.version = snapshot.tick
            charts.append(data)
        }
        return charts
    }

    /// The hour's CPU folded: "last hour: 2.0–98.1%, mean 40.2%".
    static func hour(_ key: ActivityRingKey, in snapshot: ActivitySnapshot) -> String? {
        guard let hour = snapshot.history.hourCPU(key) else { return nil }
        let span = hour.minutes >= 60 ? "last hour" : "last \(hour.minutes) min"
        return "\(span): \(ActivityRows.percent(hour.low))–\(ActivityRows.percent(hour.high))%, mean \(ActivityRows.percent(hour.mean))%"
    }
}

/// The selection's history (6.11), made off the main thread with the rows
/// (`ActivityRows.Options.historyOf`) or on its own queue for a row just
/// selected — never on the main actor a tick: its charts, its subtree's
/// for an agent, the hour folded, and what Ask an Agent says of it (8.6:
/// CPU over its history, min, mean and max, the footprint's trend). Pure.
struct ActivityDetailHistory: Equatable, Sendable {
    /// The least, the mean and the most of a span.
    struct Span: Equatable, Sendable {
        var low: Double
        var mean: Double
        var high: Double
        /// Samples, or minutes for the hour.
        var count: Int
    }

    /// The footprint over the hour: its first minute's mean, its last's, its peak.
    struct Trend: Equatable, Sendable {
        var first: Double
        var last: Double
        var high: Double
        var minutes: Int
    }

    let identity: ActivityProcessID
    var charts: [TimeChartData] = []
    var subtreeCharts: [TimeChartData] = []
    /// "last hour: 2.0–98.1%, mean 40.2%".
    var hour: String?
    /// CPU over its 15 minutes of samples, and over the folded hour.
    var recentCPU: Span?
    var hourCPU: Span?
    var memory: Trend?
    /// An agent's: the same of it and everything under it.
    var subtreeRecentCPU: Span?
    var subtreeHourCPU: Span?

    /// `identity`'s history in `snapshot` — one of the user's.
    static func make(_ identity: ActivityProcessID, in snapshot: ActivitySnapshot) -> ActivityDetailHistory {
        var made = ActivityDetailHistory(identity: identity)
        let key = ActivityRingKey.process(identity)
        let ring = snapshot.history
        made.charts = ActivityHistoryCharts.charts(key, subject: "process.\(identity.pid)", measures: ActivityHistoryCharts.processMeasures, in: snapshot)
        made.hour = ActivityHistoryCharts.hour(key, in: snapshot)
        made.recentCPU = ring.spanCPU(key).map { Span(low: $0.low, mean: $0.mean, high: $0.high, count: $0.samples) }
        made.hourCPU = ring.hourCPU(key).map { Span(low: $0.low, mean: $0.mean, high: $0.high, count: $0.minutes) }
        made.memory = ring.hourMemory(key).map { Trend(first: $0.first, last: $0.last, high: $0.high, minutes: $0.minutes) }
        let agent = ActivityRingKey.agent(identity)
        if ring.hasDetail(agent) {
            made.subtreeCharts = ActivityHistoryCharts.charts(
                agent, subject: "agent.\(identity.pid)", measures: Array(ActivityHistoryCharts.processMeasures.prefix(2)), in: snapshot)
            made.subtreeRecentCPU = ring.spanCPU(agent).map { Span(low: $0.low, mean: $0.mean, high: $0.high, count: $0.samples) }
            made.subtreeHourCPU = ring.hourCPU(agent).map { Span(low: $0.low, mean: $0.mean, high: $0.high, count: $0.minutes) }
        }
        return made
    }

    /// Made off the main thread, on a queue of its own.
    static func read(_ identity: ActivityProcessID, in snapshot: ActivitySnapshot) async -> ActivityDetailHistory {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: make(identity, in: snapshot)) }
        }
    }
}
