import Foundation

// The Metrics tab's ranges over Prometheus (docs/design/kubernetes/metrics.md,
// 3.3–3.5, 4.7, 6.1; stage M6): each range's step and refresh, a custom
// window's step, Custom's checks, a drag's zoom, and which source a tab's
// charts read. Pure.

/// What one `query_range` covers: its start, end and step, and how often
/// it is asked again — nil for a window (a zoom, Custom), which never is.
struct KubePromSpan: Hashable, Sendable {
    var start: Date
    var end: Date
    var step: TimeInterval
    var refresh: TimeInterval?

    /// The points a series of it holds at most.
    var points: Int { Int((end.timeIntervalSince(start) / step).rounded(.down)) + 1 }
}

extension KubeMetricsRange {
    /// Live over Prometheus: the last 15 minutes, as the sampled Live.
    static let prometheusLiveSpan: TimeInterval = 900

    /// The span Prometheus is asked for.
    var prometheusSpan: TimeInterval { self == .live ? Self.prometheusLiveSpan : span }

    /// The table's steps: Live and 1h at 30 s (60 s on a minute's scrape,
    /// where a 30 s step holds no new sample every other point), 6h at 2m,
    /// 24h at 5m, 7d at 30m — at most 336 points.
    func prometheusStep(scrape: TimeInterval) -> TimeInterval {
        switch self {
        case .live, .hour: scrape >= 60 ? 60 : 30
        case .sixHours: 120
        case .day: 300
        case .week: 1800
        }
    }

    /// How often it is asked again while shown, incrementally: Live at its
    /// step, 1h every minute, 6h every 2, 24h every 5, 7d every 15.
    func prometheusRefresh(step: TimeInterval) -> TimeInterval {
        switch self {
        case .live: step
        case .hour: 60
        case .sixHours: 120
        case .day: 300
        case .week: 900
        }
    }
}

enum KubeMetricsSpan {
    /// A window's steps: the smallest of these that keeps it near 250 points.
    static let niceSteps: [TimeInterval] = [15, 30, 60, 120, 300, 600, 900, 1800, 3600, 10800]
    static let windowPoints: TimeInterval = 250
    /// Prometheus' own limit on a series' points: never asked past it.
    static let hardPoints = 11_000

    static func nice(_ seconds: TimeInterval) -> TimeInterval { niceSteps.first { $0 >= seconds } ?? niceSteps[niceSteps.count - 1] }

    /// A range ending now, its end on a step: asked again within a step, the same.
    static func of(_ range: KubeMetricsRange, scrape: TimeInterval, now: Date) -> KubePromSpan {
        let step = range.prometheusStep(scrape: scrape)
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        return KubePromSpan(start: end.addingTimeInterval(-range.prometheusSpan), end: end, step: step, refresh: range.prometheusRefresh(step: step))
    }

    /// A window, at `max(scrape, nice(span / 250))`, never refreshed.
    static func of(_ window: KubeChartWindow, scrape: TimeInterval) -> KubePromSpan {
        let span = max(window.end.timeIntervalSince(window.start), 60)
        var step = max(scrape, nice(span / windowPoints))
        while span / step > Double(hardPoints) { step *= 2 }
        return KubePromSpan(start: window.start, end: window.end, step: step, refresh: nil)
    }

    /// How many steps before the last answer's end an incremental refresh
    /// asks again: a last point computed before its final scrape arrived
    /// has a short rate and maybe no gauge — `max(2, ⌈(scrape + 30 s) ÷ step⌉)`.
    static func overlap(step: TimeInterval, scrape: TimeInterval) -> Int {
        max(2, Int(((scrape + 30) / step).rounded(.up)))
    }
}

extension KubeChartWindow {
    /// Custom reaches back this far where Prometheus doesn't say how far it keeps data.
    static let customLimit: TimeInterval = 30 * 86400
    /// The narrowest window: a drag shorter than this zooms nothing.
    static let narrowest: TimeInterval = 60

    /// Custom's two dates checked: the start before the end, the end not
    /// in the future, the start within what Prometheus keeps (its probed
    /// retention, else 30 days). What is wrong, said, or the window.
    static func custom(start: Date, end: Date, now: Date, retention: Date?) -> Result<KubeChartWindow, CustomInvalid> {
        guard start < end else { return .failure(.order) }
        guard end <= now.addingTimeInterval(60) else { return .failure(.future) }
        guard end.timeIntervalSince(start) >= narrowest else { return .failure(.tooShort) }
        let oldest = retention ?? now.addingTimeInterval(-customLimit)
        guard start >= oldest else { return .failure(.tooOld(oldest, known: retention != nil)) }
        return .success(KubeChartWindow(start: start, end: min(end, now), kind: .custom))
    }

    enum CustomInvalid: Error, Equatable {
        case order, future, tooShort
        case tooOld(Date, known: Bool)

        var sentence: String {
            switch self {
            case .order: "The start must be before the end."
            case .future: "The end can't be in the future."
            case .tooShort: "Pick a minute or more."
            case .tooOld(let oldest, let known):
                known
                    ? "Prometheus keeps data from \(KubeChartEmpty.day(oldest)) \(KubeChartTime.clock(oldest)): start then or later."
                    : "At most \(Int(customLimit / 86400)) days back."
            }
        }
    }

    /// A drag across a chart from `a` to `b` (either way round), kept
    /// inside what the chart shows: the window every chart of the tab
    /// moves to, or nil when it is narrower than a minute.
    static func zoom(from a: Date, to b: Date, within start: Date, _ end: Date, sampledTier: KubeMetricsRange) -> KubeChartWindow? {
        let from = max(min(a, b), start)
        let to = min(max(a, b), end)
        guard to.timeIntervalSince(from) >= narrowest else { return nil }
        return KubeChartWindow(start: from, end: to, kind: .zoom, sampledTier: sampledTier)
    }
}

/// Where a tab's charts read their numbers (metrics.md 4.7's ladder):
/// what was sampled while shown, Prometheus, or both — the sampled form
/// where a chart has one, Prometheus for the others (Live with both). Pure.
enum KubeChartSource: String, Equatable, Sendable {
    case sampled, prometheus, mixed

    /// A namespace's charts are what was sampled while shown: their
    /// Prometheus forms (by workload, the quota) aren't drawn here.
    static func prometheusCharts(_ subject: KubeMetricsSubject) -> Bool { subject != .namespace }

    /// The source for a tab: `metricsServer`, metrics-server serves;
    /// `prometheus`, the context's Prometheus is found. Live is sampled
    /// where metrics-server serves (or an HPA's status, which needs none),
    /// its charts without a sampled form from Prometheus over 15 minutes;
    /// with only Prometheus, every chart is Prometheus'. 1h on is
    /// Prometheus'. A zoom keeps the source of what it zoomed; a marker's
    /// window or Custom is Prometheus' where Prometheus is. Nil: nothing
    /// to draw from.
    static func pick(
        subject: KubeMetricsSubject, range: KubeMetricsRange, window: KubeChartWindow?, metricsServer: Bool, prometheus: Bool
    ) -> KubeChartSource? {
        let sampled = metricsServer || subject == .hpa
        guard prometheus, prometheusCharts(subject) else { return sampled ? .sampled : nil }
        let base: KubeChartSource = range == .live && sampled ? .mixed : .prometheus
        guard let window else { return base }
        return window.kind == .zoom ? base : .prometheus
    }
}
