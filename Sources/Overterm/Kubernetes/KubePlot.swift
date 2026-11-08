import CoreGraphics
import Foundation

// A chart's data and its geometry, pure (docs/design/kubernetes/metrics.md,
// 5.1, 5.2): `KubeChartData` is what a chart shows — its series with their
// roles, the window, the unit —, `KubePlot` what it draws at a size, built
// off the main thread, cached by `(data.version, size, hidden series)`.
// `KubeChartView` draws a plot's paths in one Canvas pass; the crosshair,
// the hovered points and the tooltip are `KubeChartOverlay`'s, which alone
// redraws while the mouse moves.

/// What a series is to its chart: usage is drawn as a line (a band when
/// stacked); the others are reference lines — dashed and stepped, never
/// more series —, each fixed in colour by meaning and told apart by its
/// own dash too, colour never the only cue (metrics.md, 5.2). A peak
/// band or a projection is not usage and not a reference line: each comes
/// with the stage that draws it (C1, V1), its own handling with it.
enum KubeChartRole: String, Sendable, CaseIterable {
    case usage, request, limit, allocatable, capacity, quota, guide

    var isReference: Bool { self != .usage }

    /// The reference's dash: request [3,3], limit [6,2], allocatable and capacity [1,2], quota [6,2,1,2].
    var dash: [CGFloat] {
        switch self {
        case .request: [3, 3]
        case .limit: [6, 2]
        case .allocatable, .capacity: [1, 2]
        case .quota: [6, 2, 1, 2]
        case .guide: [2, 4]
        case .usage: []
        }
    }

    /// What the line is called at its right end and in the tooltip.
    var label: String {
        switch self {
        case .request: "request"
        case .limit: "limit"
        case .allocatable: "allocatable"
        case .capacity: "capacity"
        case .quota: "quota"
        case .guide: "guide"
        case .usage: "usage"
        }
    }
}

/// A chart's unit: how its values are said.
enum KubeChartUnit: String, Sendable {
    /// CPU cores, said in millicores as kubectl top does (`750m`).
    case cores
    case bytes
    /// A fraction, said as a percent.
    case ratio
    case count

    func format(_ value: Double) -> String {
        switch self {
        case .cores: KubeMetricsFormat.cpu(value)
        case .bytes: KubeVolumeFormat.bytes(value)
        case .ratio: "\(Int((value * 100).rounded()))%"
        case .count: value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
        }
    }

    /// The axis's top when every value is zero.
    var emptyTop: Double {
        switch self {
        case .cores: 0.1
        case .bytes: 1_048_576
        case .ratio: 1
        case .count: 1
        }
    }
}

/// A moment marked on a time chart: a tick on the plot's bottom edge with
/// a faint line the whole height, its colour by kind, hover saying what it
/// was, a click opening it (metrics.md, 3.2). A container's restart and an
/// OOMKill come from its `lastState` (M3a); rollouts, Helm revisions,
/// scaling and warnings join them with `KubeChartMarkers` (M4).
struct KubeChartMarker: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        /// A container ended and was started again: orange.
        case restart
        /// It was OOMKilled: red.
        case oom
    }

    var id: String
    var kind: Kind
    var time: Date
    /// What hover says: "OOMKilled at 14:11 (exit 137)".
    var title: String
    /// The container it is of, where it is one's: a click opens its previous log.
    var container: String?
}

/// One series: its points in time order, broken where they are more than
/// two steps apart.
struct KubeChartSeries: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var role: KubeChartRole = .usage
    var points: [KubeSeriesPoint]
    /// The points that start again after a break their source recorded
    /// (`KubeUsageRing`'s): a run ends before each, whatever the step.
    var breaks: Set<Date> = []
}

/// What one chart shows: its series over a window, in one unit.
struct KubeChartData: Equatable, Sendable {
    /// The chart's identifier part: `kubernetes.chart.<id>` (`<subject>.<measure>`,
    /// the subject naming its object: `cluster`, `pod.shop.web-8k2`, `volume.shop.data-db-0`).
    var id: String
    var title: String
    var unit: KubeChartUnit
    var series: [KubeChartSeries]
    var start: Date
    var end: Date
    /// The points' spacing: two points further apart than two steps are a gap.
    var step: TimeInterval
    /// Usage series stacked, cumulative in legend order.
    var stacked = false
    /// Where the numbers come from, as the caption and the dump say it.
    var source = ""
    var tier: String?
    /// Changed by whoever makes the data whenever it changes: what the plot cache is keyed by.
    var version = 0
    /// The moments marked on it, oldest first.
    var markers: [KubeChartMarker] = []
    /// Its series' breaks are marked (`breaks`): the step only spaces
    /// the points, it splits no run — the source's rule is the one.
    var breaksMarked = false

    var identifier: String { "kubernetes.chart." + id }
    /// The markers inside the window: the ones drawn.
    var shownMarkers: [KubeChartMarker] { markers.filter { $0.time >= start && $0.time <= end } }
    var usage: [KubeChartSeries] { series.filter { !$0.role.isReference } }
    var references: [KubeChartSeries] { series.filter(\.role.isReference) }
}

/// An immutable path, handed from the queue that built it to the main thread.
struct KubePlotPath: @unchecked Sendable {
    let cgPath: CGPath
}

/// A chart's geometry at one size: the scales, the ticks, a path per series
/// and per stacked band, the reference steps and the points hover searches.
/// Pure; built off the main thread (`KubeChartState`).
struct KubePlot: Sendable {
    struct Key: Hashable, Sendable {
        var version: Int
        var width: Int
        var height: Int
        var hidden: Set<String>
        var hideReferences: Bool
    }

    struct Line: Sendable {
        var id: String
        var name: String
        var role: KubeChartRole
        /// Its place in the palette (usage series, in legend order).
        var colour: Int
        var stroke: KubePlotPath
        var fill: KubePlotPath?
        var points: Int
    }

    struct Reference: Sendable {
        var id: String
        var name: String
        var role: KubeChartRole
        var stroke: KubePlotPath
        var last: Double
        /// Where its label sits: the line's right end.
        var labelAt: CGPoint
    }

    /// A marker where it is drawn.
    struct Marker: Sendable {
        var marker: KubeChartMarker
        var x: CGFloat
    }

    /// One series' values as hover reads them, in time order.
    struct Track: Sendable {
        var id: String
        var name: String
        var role: KubeChartRole
        var colour: Int
        var times: [Double]
        var values: [Double]
    }

    static let gutter: CGFloat = 40
    static let topInset: CGFloat = 8
    static let rightInset: CGFloat = 4

    var key: Key
    var size: CGSize
    /// Where the lines are drawn, inside `size`; the gutter on its left holds the y labels.
    var frame: CGRect
    var start: Date
    var end: Date
    var unit: KubeChartUnit
    var top: Double
    var yTicks: [Double]
    var timeTicks: [Date]
    var lines: [Line]
    var references: [Reference]
    var tracks: [Track]
    var markers: [Marker]
    var stacked: Bool

    var pointCount: Int { lines.reduce(0) { $0 + $1.points } }

    // MARK: Building

    init(_ data: KubeChartData, size: CGSize, hidden: Set<String> = [], hideReferences: Bool = false, timeZone: TimeZone = .current) {
        key = Key(version: data.version, width: Int(size.width.rounded()), height: Int(size.height.rounded()), hidden: hidden, hideReferences: hideReferences)
        self.size = size
        frame = CGRect(
            x: Self.gutter, y: Self.topInset, width: max(1, size.width - Self.gutter - Self.rightInset),
            height: max(1, size.height - Self.topInset))
        start = data.start
        end = max(data.end, data.start.addingTimeInterval(1))
        unit = data.unit
        stacked = data.stacked
        let usage = data.usage
        let colours = Dictionary(uniqueKeysWithValues: usage.enumerated().map { ($1.id, $0) })
        let shown = usage.filter { !hidden.contains($0.id) }
        let references = hideReferences ? [] : data.references.filter { !hidden.contains($0.id) }
        let columns = max(2, Int(frame.width.rounded()))
        let startTime = start.timeIntervalSince1970
        let span = end.timeIntervalSince1970 - startTime

        // The values drawn: each series' own, or stacked — each band's top is the sum of those under it.
        var drawn: [(series: KubeChartSeries, lower: [Double]?, upper: [KubeSeriesPoint])] = []
        if data.stacked {
            var below: [Double: Double] = [:]
            for series in shown {
                var lower: [Double] = []
                var upper: [KubeSeriesPoint] = []
                for point in series.points {
                    let t = point.time.timeIntervalSince1970
                    let base = below[t] ?? 0
                    lower.append(base)
                    upper.append(KubeSeriesPoint(time: point.time, value: base + point.value))
                    below[t] = base + point.value
                }
                drawn.append((series, lower, upper))
            }
        } else {
            drawn = shown.map { ($0, nil, $0.points) }
        }
        let highest = drawn.flatMap { $0.upper.map(\.value) }.max() ?? 0
        let referenceHighest = references.compactMap { $0.points.map(\.value).max() }.max() ?? 0
        (top, yTicks) = Self.niceScale(max(highest, referenceHighest), unit: data.unit)
        timeTicks = Self.timeTicks(start: start, end: end, width: frame.width, timeZone: timeZone)

        let frame = self.frame
        let top = self.top
        func x(_ time: Double) -> CGFloat { frame.minX + frame.width * CGFloat(span > 0 ? (time - startTime) / span : 0) }
        func y(_ value: Double) -> CGFloat { frame.maxY - frame.height * CGFloat(top > 0 ? min(max(value, 0), top) / top : 0) }

        var lines: [Line] = []
        for (series, lower, upper) in drawn {
            let stroke = CGMutablePath()
            let fill = CGMutablePath()
            var count = 0
            let runs = Self.runs(upper, lower: lower, step: data.breaksMarked ? 0 : data.step, breaks: series.breaks)
            for run in runs {
                let points = Self.decimate(run.upper, columns: columns, start: startTime, span: span)
                count += points.count
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: x(point.time.timeIntervalSince1970), y: y(point.value))
                    if index == 0 { stroke.move(to: p) } else { stroke.addLine(to: p) }
                }
                // The area under it (a single series), or the band between it and those below (stacked).
                guard let first = points.first, let last = points.last, points.count >= 2 else { continue }
                fill.move(to: CGPoint(x: x(first.time.timeIntervalSince1970), y: y(0)))
                if let base = run.lower {
                    for point in points { fill.addLine(to: CGPoint(x: x(point.time.timeIntervalSince1970), y: y(point.value))) }
                    let bottom = Self.decimate(base, columns: columns, start: startTime, span: span)
                    for point in bottom.reversed() { fill.addLine(to: CGPoint(x: x(point.time.timeIntervalSince1970), y: y(point.value))) }
                } else {
                    for point in points { fill.addLine(to: CGPoint(x: x(point.time.timeIntervalSince1970), y: y(point.value))) }
                    fill.addLine(to: CGPoint(x: x(last.time.timeIntervalSince1970), y: y(0)))
                }
                fill.closeSubpath()
            }
            let filled = data.stacked || shown.count == 1
            lines.append(
                Line(
                    id: series.id, name: series.name, role: series.role, colour: colours[series.id] ?? 0, stroke: KubePlotPath(cgPath: stroke.copy() ?? stroke),
                    fill: filled ? KubePlotPath(cgPath: fill.copy() ?? fill) : nil, points: count))
        }
        self.lines = lines

        // References: stepped across the window — a value holds until the next one; one value, flat across.
        self.references = references.compactMap { series in
            guard let lastPoint = series.points.last else { return nil }
            let path = CGMutablePath()
            let points = series.points.count == 1 ? [KubeSeriesPoint(time: data.start, value: lastPoint.value)] : series.points
            for (index, point) in points.enumerated() {
                let px = index == 0 ? frame.minX : x(point.time.timeIntervalSince1970)
                let py = y(point.value)
                if index == 0 {
                    path.move(to: CGPoint(x: px, y: py))
                } else {
                    path.addLine(to: CGPoint(x: px, y: y(points[index - 1].value)))
                    path.addLine(to: CGPoint(x: px, y: py))
                }
            }
            let endY = y(lastPoint.value)
            path.addLine(to: CGPoint(x: frame.maxX, y: endY))
            return Reference(
                id: series.id, name: series.name, role: series.role, stroke: KubePlotPath(cgPath: path.copy() ?? path), last: lastPoint.value,
                labelAt: CGPoint(x: frame.maxX, y: endY))
        }

        markers = data.shownMarkers.map { Marker(marker: $0, x: x($0.time.timeIntervalSince1970)) }

        tracks =
            drawn.map { series, _, _ in
                Track(
                    id: series.id, name: series.name, role: series.role, colour: colours[series.id] ?? 0,
                    times: series.points.map { $0.time.timeIntervalSince1970 }, values: series.points.map(\.value))
            }
            + references.map { series in
                Track(
                    id: series.id, name: series.name, role: series.role, colour: 0, times: series.points.map { $0.time.timeIntervalSince1970 },
                    values: series.points.map(\.value))
            }
    }

    /// A series' runs, broken where two points are more than two steps
    /// apart (no step: never) and before each of `breaks`, with the band's base beside each.
    static func runs(
        _ upper: [KubeSeriesPoint], lower: [Double]?, step: TimeInterval, breaks: Set<Date> = []
    ) -> [(upper: [KubeSeriesPoint], lower: [KubeSeriesPoint]?)] {
        var out: [(upper: [KubeSeriesPoint], lower: [KubeSeriesPoint]?)] = []
        for (index, point) in upper.enumerated() {
            let base = lower.map { KubeSeriesPoint(time: point.time, value: $0[index]) }
            if let last = out.last?.upper.last, !breaks.contains(point.time), step <= 0 || point.time.timeIntervalSince(last.time) <= 2 * step {
                out[out.count - 1].upper.append(point)
                if let base { out[out.count - 1].lower?.append(base) }
            } else {
                out.append(([point], base.map { [$0] }))
            }
        }
        return out
    }

    // MARK: Pure parts

    /// Min/max decimation: past one point a pixel column, each column keeps
    /// its lowest and its highest in time order — two a column, peaks kept.
    static func decimate(_ points: [KubeSeriesPoint], columns: Int, start: Double, span: Double) -> [KubeSeriesPoint] {
        guard columns > 0, points.count > columns, span > 0 else { return points }
        var out: [KubeSeriesPoint] = []
        out.reserveCapacity(2 * columns + 2)
        var column = -1
        var low: KubeSeriesPoint?
        var high: KubeSeriesPoint?
        var lowIndex = 0
        var highIndex = 0
        func flush() {
            guard let low, let high else { return }
            if lowIndex == highIndex {
                out.append(low)
            } else if lowIndex < highIndex {
                out.append(low)
                out.append(high)
            } else {
                out.append(high)
                out.append(low)
            }
        }
        for (index, point) in points.enumerated() {
            let at = Int(((point.time.timeIntervalSince1970 - start) / span * Double(columns)).rounded(.down))
            if at != column {
                flush()
                column = at
                low = point
                high = point
                lowIndex = index
                highIndex = index
                continue
            }
            if point.value < (low?.value ?? .infinity) {
                low = point
                lowIndex = index
            }
            if point.value > (high?.value ?? -.infinity) {
                high = point
                highIndex = index
            }
        }
        flush()
        return out
    }

    /// The axis's top rounded up to a nice value and its 3–5 ticks from 0;
    /// bytes in steps of a binary unit (Ki, Mi, Gi, Ti).
    static func niceScale(_ highest: Double, unit: KubeChartUnit) -> (top: Double, ticks: [Double]) {
        let highest = highest.isFinite && highest > 0 ? highest : unit.emptyTop
        var scale = 1.0
        if unit == .bytes {
            while scale * 1024 <= highest, scale < 1_099_511_627_776 { scale *= 1024 }
        }
        let value = highest / scale
        let raw = value / 4
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw * (1 - 1e-9) } ?? 10 * magnitude
        let top = (value / step * (1 - 1e-9)).rounded(.up) * step
        let count = Int((top / step).rounded())
        return (top * scale, (0...count).map { Double($0) * step * scale })
    }

    /// The time ticks: the smallest interval that keeps them 70 pt apart, on whole local minutes, hours or days.
    static func timeTicks(start: Date, end: Date, width: CGFloat, timeZone: TimeZone) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span > 0, width > 0 else { return [] }
        let most = max(1, Int(width / 70))
        let intervals: [TimeInterval] = [15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172_800, 604_800]
        let interval = intervals.first { span / $0 <= Double(most) } ?? 604_800
        let offset = Double(timeZone.secondsFromGMT(for: start))
        let first = ((start.timeIntervalSince1970 + offset) / interval).rounded(.up) * interval - offset
        var ticks: [Date] = []
        var t = first
        while t <= end.timeIntervalSince1970, ticks.count < 50 {
            ticks.append(Date(timeIntervalSince1970: t))
            t += interval
        }
        return ticks
    }

    // MARK: Reading it back

    func x(of time: Date) -> CGFloat {
        let span = end.timeIntervalSince(start)
        return frame.minX + frame.width * CGFloat(span > 0 ? time.timeIntervalSince(start) / span : 0)
    }

    func y(of value: Double) -> CGFloat { frame.maxY - frame.height * CGFloat(top > 0 ? min(max(value, 0), top) / top : 0) }

    func time(atX x: CGFloat) -> Date {
        let fraction = Double(min(max((x - frame.minX) / max(frame.width, 1), 0), 1))
        return start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
    }

    /// The point of a usage series nearest to `x`, by binary search in each one's times: the time hover snaps to.
    func nearestTime(toX x: CGFloat) -> Date? {
        let target = time(atX: x).timeIntervalSince1970
        var best: Double?
        for track in tracks where !track.role.isReference {
            guard let index = Self.nearest(track.times, target) else { continue }
            let t = track.times[index]
            if best.map({ abs(t - target) < abs($0 - target) }) ?? true { best = t }
        }
        return best.map { Date(timeIntervalSince1970: $0) }
    }

    /// The index of the time nearest `target` in sorted `times`.
    static func nearest(_ times: [Double], _ target: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        var low = 0
        var high = times.count - 1
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < target { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(times[low - 1] - target) <= abs(times[low] - target) { return low - 1 }
        return low
    }

    /// Each series' value at `time`: the point there, or within a step of
    /// it — none in a gap. A reference holds its last value before `time`.
    func values(at time: Date, step: TimeInterval) -> [(track: Track, value: Double)] {
        let target = time.timeIntervalSince1970
        return tracks.compactMap { track in
            if track.role.isReference {
                guard let first = track.values.first else { return nil }
                var value = first
                for (t, v) in zip(track.times, track.values) where t <= target { value = v }
                return (track, value)
            }
            guard let index = Self.nearest(track.times, target), abs(track.times[index] - target) <= max(step, 1) else { return nil }
            return (track, track.values[index])
        }
    }
}

/// The tooltip at a time: the time with its zone, each series by value,
/// then the reference lines with the usage's share of each (metrics.md, 3.1).
struct KubeChartTooltip: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        var name: String
        var value: String
        var colour: Int?
        var role: KubeChartRole
    }

    var time: String
    var rows: [Row]

    var text: String { ([time] + rows.map { "\($0.name) \($0.value)" }).joined(separator: "\n") }

    static func at(_ time: Date, plot: KubePlot, step: TimeInterval, timeZone: TimeZone = .current) -> KubeChartTooltip {
        let values = plot.values(at: time, step: step)
        let usage = values.filter { !$0.track.role.isReference }.sorted { $0.value > $1.value }
        // Stacked, a band's own value is what it adds, not the sum under it.
        let total = usage.reduce(0) { $0 + $1.value }
        var rows = usage.map { Row(name: $0.track.name, value: plot.unit.format($0.value), colour: $0.track.colour, role: .usage) }
        for (track, value) in values where track.role.isReference {
            let share = KubeMetricsFormat.percent(total, of: value).map { " · \($0)%" } ?? ""
            rows.append(Row(name: track.name, value: plot.unit.format(value) + share, colour: nil, role: track.role))
        }
        return KubeChartTooltip(time: KubeChartTime.full(time, timeZone: timeZone), rows: rows)
    }
}

/// Times as the charts say them: local, the zone in the tooltip (decision 14).
enum KubeChartTime {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func parts(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)
    }

    private static func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }

    /// `Nov 7, 14:32:15 GMT+3`.
    static func full(_ date: Date, timeZone: TimeZone = .current) -> String {
        let p = parts(date, timeZone)
        return "\(months[((p.month ?? 1) - 1) % 12]) \(p.day ?? 1), \(two(p.hour)):\(two(p.minute)):\(two(p.second)) \(zone(timeZone, at: date))"
    }

    /// An axis tick: `14:30`, a day's start `Nov 8`; ticks a day or more apart are days.
    static func tick(_ date: Date, interval: TimeInterval, timeZone: TimeZone = .current) -> String {
        let p = parts(date, timeZone)
        let day = "\(months[((p.month ?? 1) - 1) % 12]) \(p.day ?? 1)"
        if interval >= 86400 || (p.hour == 0 && p.minute == 0) { return day }
        return "\(two(p.hour)):\(two(p.minute))"
    }

    /// `14:32`, for the summary.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let p = parts(date, timeZone)
        return "\(two(p.hour)):\(two(p.minute))"
    }

    /// `GMT+3`, `GMT+5:30`, `GMT-4`, `GMT`.
    static func zone(_ timeZone: TimeZone, at date: Date) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        guard seconds != 0 else { return "GMT" }
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        return "GMT\(sign)\(hours)" + (minutes > 0 ? ":" + two(minutes) : "")
    }
}

/// A chart said in a sentence, for VoiceOver and the dump:
/// "CPU, last 1h: 120m now, peak 480m at 14:10, request 250m, limit 1000m".
enum KubeChartSummary {
    static func of(_ data: KubeChartData, span: String, timeZone: TimeZone = .current) -> String {
        let total = totals(data)
        var parts: [String] = []
        if let last = total.last { parts.append("\(data.unit.format(last.value)) now") }
        if let peak = total.max(by: { $0.value < $1.value }) {
            parts.append("peak \(data.unit.format(peak.value)) at \(KubeChartTime.clock(peak.time, timeZone: timeZone))")
        }
        if total.isEmpty { parts.append("no samples") }
        for reference in data.references {
            if let value = reference.points.last?.value { parts.append("\(reference.name) \(data.unit.format(value))") }
        }
        return "\(data.title), \(span): " + parts.joined(separator: ", ")
    }

    /// The usage series summed at each time they share (one series: itself).
    static func totals(_ data: KubeChartData) -> [KubeSeriesPoint] {
        let usage = data.usage
        guard usage.count > 1 else { return usage.first?.points ?? [] }
        var sums: [Double: Double] = [:]
        for series in usage { for point in series.points { sums[point.time.timeIntervalSince1970, default: 0] += point.value } }
        return sums.keys.sorted().map { KubeSeriesPoint(time: Date(timeIntervalSince1970: $0), value: sums[$0] ?? 0) }
    }

    /// What `OVERTERM_DUMP_LAYOUT` and the scenarios read of a chart: its
    /// series and points, the axis's top, the references, the markers, the source and the tier.
    static func dump(_ data: KubeChartData, plot: KubePlot?) -> String {
        let references = data.references.map { "\($0.role.label)=\(data.unit.format($0.points.last?.value ?? 0))" }
        let points = data.usage.reduce(0) { $0 + $1.points.count }
        return "chart \(data.identifier) series=\(data.usage.count) points=\(points)"
            + " drawn=\(plot?.pointCount ?? 0) ymax=\(plot.map { data.unit.format($0.top) } ?? "-") refs=[\(references.joined(separator: " "))] markers=\(data.shownMarkers.count)"
            + " source=\(data.source.isEmpty ? "-" : data.source) tier=\(data.tier ?? "-")"
    }
}

/// The charts' categorical colours, ten a theme, each at least 3:1
/// against its card (WCAG's non-text contrast), checked in both
/// appearances (`KubePlotTests`); and the reference lines' fixed ones.
enum KubeChartPalette {
    struct RGB: Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ hex: UInt32) {
            red = Double(hex >> 16 & 0xFF) / 255
            green = Double(hex >> 8 & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        /// WCAG's relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        func contrast(_ other: RGB) -> Double {
            let a = luminance
            let b = other.luminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    static let light: [RGB] = [0x2167C9, 0xC2570C, 0x0E8A7E, 0xB8327A, 0x6B4FD0, 0x8C5A2B, 0x6F7F12, 0x0F7FA8, 0xC23B4E, 0x59657A].map(RGB.init)
    static let dark: [RGB] = [0x5AA3FF, 0xFF9A4D, 0x3DD6C3, 0xFF79C1, 0xA893FF, 0xD9A066, 0xB8CC4A, 0x4FC7EE, 0xFF7A8A, 0xA3B1C7].map(RGB.init)

    /// A marker's colour by kind: an OOMKill red, as a limit is; a restart orange.
    static func marker(_ kind: KubeChartMarker.Kind, dark: Bool) -> RGB {
        switch kind {
        case .oom: reference(.limit, dark: dark)
        case .restart: RGB(dark ? 0xFF9A4D : 0xC2570C)
        }
    }

    /// A reference line's colour by meaning: request green, limit red, allocatable and capacity grey, quota purple.
    static func reference(_ role: KubeChartRole, dark: Bool) -> RGB {
        switch role {
        case .request: RGB(dark ? 0x4CC774 : 0x1C7F3C)
        case .limit: RGB(dark ? 0xFF6B6B : 0xC62828)
        case .quota: RGB(dark ? 0xC08CFF : 0x7B3FC4)
        case .guide: RGB(dark ? 0xFFB347 : 0xA35A00)
        default: RGB(dark ? 0x9AA0A6 : 0x6B7075)
        }
    }
}
