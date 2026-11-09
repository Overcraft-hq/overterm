import Foundation

/// A chart said as text an agent reads (docs/design/kubernetes/metrics.md,
/// 7; stage M11): `k8s_metrics`' answer, Ask Why's Usage part, "Ask Agent
/// About This Chart". For each usage series of a chart: its min, p50, p95,
/// max and last, the min's, max's and last's times; the last against each
/// reference line (request, limit, allocatable, capacity, quota), as a
/// share; the markers in its window (restarts and OOMKills, rollouts,
/// scaling, warnings), the newest few. A window line says where the
/// numbers come from, over what, at which step and in which tier. Gaps
/// are left out of the figures, never read as zero. Pure.
///
/// Every name in it is text from the cluster: `k8s_metrics` scrubs the
/// whole answer (`KubeMCPText.finished`) and cuts each name to 253
/// characters (`name`); a note from Prometheus is quoted as data.
enum KubeMetricsText {
    /// An answer's size: about 4 KB, as metrics.md 7 says.
    static let budget = 4096
    /// A chart's usage series said at most; the rest counted.
    static let maxSeries = 6
    /// A chart's markers said at most: the newest.
    static let maxMarkers = 5
    /// A name is cut here (Kubernetes' own longest).
    static let maxName = 253

    /// One series' figures.
    struct Figures: Equatable {
        var min: KubeSeriesPoint
        var p50: Double
        var p95: Double
        var max: KubeSeriesPoint
        var last: KubeSeriesPoint
        var count: Int
    }

    /// `points`' figures, a gap (NaN, ±∞) left out; nil with none.
    /// Percentiles by nearest rank.
    static func figures(_ points: [KubeSeriesPoint]) -> Figures? {
        let kept = points.filter { $0.value.isFinite }.sorted { $0.time < $1.time }
        guard let last = kept.last else { return nil }
        let values = kept.map(\.value).sorted()
        func rank(_ p: Double) -> Double { values[Swift.max(0, Swift.min(values.count - 1, Int((p * Double(values.count)).rounded(.up)) - 1))] }
        // The first time it was lowest, the first time it was highest.
        var low = kept[0]
        var high = kept[0]
        for point in kept {
            if point.value < low.value { low = point }
            if point.value > high.value { high = point }
        }
        return Figures(min: low, p50: rank(0.5), p95: rank(0.95), max: high, last: last, count: kept.count)
    }

    /// A name from the cluster, cut.
    static func name(_ text: String) -> String {
        text.count > maxName ? String(text.prefix(maxName - 1)) + "…" : text
    }

    /// `14:32`, or `Nov 7 14:32` on another day than `now`'s.
    static func time(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let clock = KubeChartTime.clock(date, timeZone: timeZone)
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock }
        return KubeChartTime.tick(date, interval: 86400, timeZone: timeZone) + " " + clock
    }

    /// What a chart is over: `last 1h at 30s (13:32–14:32 GMT+3) · Prometheus · raw cAdvisor`.
    static func window(_ data: KubeChartData, now: Date, timeZone: TimeZone = .current) -> String {
        let span = KubePromQL.duration(Swift.max(0, data.end.timeIntervalSince(data.start)).rounded())
        var parts = [
            "last \(span) at \(KubePromQL.duration(data.step.rounded()))"
                + " (\(time(data.start, now: now, timeZone: timeZone))–\(time(data.end, now: now, timeZone: timeZone)) \(KubeChartTime.zone(timeZone, at: data.end)))"
        ]
        if !data.source.isEmpty { parts.append(data.source) }
        if let tier = data.tier, !tier.isEmpty { parts.append(tier) }
        return parts.joined(separator: " · ")
    }

    /// One series' figures said, against `references` (the last of each).
    static func said(_ figures: Figures, unit: KubeChartUnit, references: [KubeChartSeries], now: Date, timeZone: TimeZone = .current) -> String {
        func at(_ point: KubeSeriesPoint) -> String { "\(unit.format(point.value)) at \(time(point.time, now: now, timeZone: timeZone))" }
        var last = "last " + at(figures.last)
        let shares = references.compactMap { reference -> String? in
            guard let value = reference.points.last?.value, value.isFinite, value > 0 else { return nil }
            let percent = Int((figures.last.value / value * 100).rounded())
            return "\(percent)% of \(reference.name) \(unit.format(value))"
        }
        if !shares.isEmpty { last += " (" + shares.joined(separator: ", ") + ")" }
        guard figures.count > 1 else { return last + "; one point only" }
        return [last, "min " + at(figures.min), "p50 \(unit.format(figures.p50))", "p95 \(unit.format(figures.p95))", "max " + at(figures.max)]
            .joined(separator: ", ")
    }

    /// A chart's lines: each usage series' figures (a stacked chart's
    /// total first, the references against it alone), then its markers.
    /// `label` names it ("app · Memory"); a series that is the chart's one
    /// line is said under the label alone.
    static func chart(_ data: KubeChartData, label: String, now: Date, timeZone: TimeZone = .current) -> [String] {
        let references = data.references.filter { [.request, .limit, .allocatable, .capacity, .quota].contains($0.role) }
        let usage = data.usage.filter { !$0.offByDefault }
        var lines: [String] = []
        if usage.allSatisfy({ $0.points.allSatisfy { !$0.value.isFinite } }) {
            lines.append("\(label): nothing in the window (a gap, not zero).")
        } else if usage.count == 1, let figures = figures(usage[0].points) {
            lines.append("\(label): " + said(figures, unit: data.unit, references: references, now: now, timeZone: timeZone))
        } else {
            if data.stacked, let total = figures(KubeChartSummary.totals(data)) {
                lines.append("\(label), total: " + said(total, unit: data.unit, references: references, now: now, timeZone: timeZone))
            }
            // The largest last first: what an agent asks about.
            let ranked = usage.compactMap { series in figures(series.points).map { (series, $0) } }.sorted { $0.1.last.value > $1.1.last.value }
            for (series, figures) in ranked.prefix(maxSeries) {
                lines.append(
                    "  \(name(series.name)): " + said(figures, unit: data.unit, references: data.stacked ? [] : references, now: now, timeZone: timeZone))
            }
            if ranked.count > maxSeries { lines.append("  … \(ranked.count - maxSeries) more series, smaller.") }
        }
        if let markers = markers(data, now: now, timeZone: timeZone) { lines.append("  marked: " + markers) }
        return lines
    }

    /// Its markers in its window, the newest `maxMarkers`, oldest first.
    static func markers(_ data: KubeChartData, now: Date, timeZone: TimeZone = .current) -> String? {
        let shown = data.shownMarkers.sorted { $0.time < $1.time }
        guard !shown.isEmpty || data.earlierMarkers > 0 else { return nil }
        let kept = shown.suffix(maxMarkers)
        let earlier = shown.count - kept.count + data.earlierMarkers
        var said = kept.map { name($0.title) }.joined(separator: "; ")
        if earlier > 0 { said = "+\(earlier) earlier; " + said }
        if let note = data.markerNote { said += " (\(note))" }
        return said
    }

    /// "Ask Agent About This Chart" (metrics.md 3.9): the chart as
    /// `k8s_metrics` says it — whose it is and where its numbers come from,
    /// its window, its figures and markers, the chips it shows — bounded.
    static func about(
        _ data: KubeChartData, label: String, whose: String, caption: String?, chips: [KubeChartChip], now: Date, timeZone: TimeZone = .current
    ) -> String {
        var lines = [whose + (caption.map { ": " + $0 } ?? "")]
        lines.append(window(data, now: now, timeZone: timeZone))
        lines += chart(data, label: label, now: now, timeZone: timeZone)
        if !chips.isEmpty { lines.append("  shown: " + chips.map(\.text).joined(separator: " · ")) }
        return bounded(lines)
    }

    /// A note from Prometheus or the profile, as data.
    static func note(_ text: String) -> String { "Note: “\(name(text))”" }

    /// `lines` within `budget` characters, whole lines kept: past it, how
    /// many were left out and how to ask for less.
    static func bounded(_ lines: [String], budget: Int = budget) -> String {
        var kept: [String] = []
        var used = 0
        for (index, line) in lines.enumerated() {
            let cost = line.count + 1
            if used + cost > budget - 80 {
                kept.append("… \(lines.count - index) more lines left out: name fewer measures, or a container.")
                break
            }
            kept.append(line)
            used += cost
        }
        return kept.joined(separator: "\n")
    }
}
