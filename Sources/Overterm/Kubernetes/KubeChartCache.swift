import Foundation

/// A context's Prometheus answers kept between refreshes (metrics.md 6.1):
/// an LRU of at most 96 entries and 12 MB, keyed by the query, the range
/// it was asked over and the step. A refresh asks only from a few steps
/// before the last answer's end (`KubeMetricsSpan.overlap`) to now, and
/// what comes back replaces the points from there on; points before the
/// range's start are dropped. A range change is another key — the old
/// range's points are never drawn on the new axis — and the query's other
/// ranges are dropped with it. A cancelled or failed answer is never
/// merged. In memory only, dropped on a context or kubeconfig change and
/// 10 minutes after the page hides (`KubePrometheusMonitor`). Pure.
struct KubeChartCache: Sendable {
    struct Key: Hashable, Sendable {
        var query: String
        /// The range's name (`1h`), or a window's start and end.
        var range: String
        var step: TimeInterval
    }

    struct Entry: Sendable {
        var series: [KubeSeries]
        var start: Date
        /// The last answer's end: a refresh asks from a few steps before it.
        var end: Date
        var bytes: Int
        var used: UInt64
    }

    static let maxEntries = 96
    static let maxBytes = 12 << 20

    private(set) var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    var count: Int { entries.count }
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    /// What to ask for `span`: all of it with nothing kept; from `overlap`
    /// steps before the kept answer's end otherwise; nil when the kept
    /// answer already reaches the span's end (asked again within a step).
    func ask(_ key: Key, span: KubePromSpan, scrape: TimeInterval) -> (start: Date, end: Date)? {
        guard let entry = entries[key] else { return (span.start, span.end) }
        guard entry.end < span.end else { return nil }
        let back = TimeInterval(KubeMetricsSpan.overlap(step: span.step, scrape: scrape)) * span.step
        let start = max(span.start, entry.end.addingTimeInterval(-back))
        // Aligned with the step grid the kept points are on.
        let offset = start.timeIntervalSince(span.start).truncatingRemainder(dividingBy: span.step)
        return (start.addingTimeInterval(-offset), span.end)
    }

    /// An answer over `asked` merged: each series' points from the asked
    /// start replaced by the answer's (a series the answer doesn't have
    /// keeps what it had before), then everything before `start` dropped.
    mutating func merge(_ key: Key, series answer: [KubeSeries], asked: (start: Date, end: Date), start: Date) {
        clock += 1
        var merged: [KubeSeries] = []
        var byLabels: [[String: String]: Int] = [:]
        for old in entries[key]?.series ?? [] {
            let kept = old.points.filter { $0.time >= start && $0.time < asked.start }
            byLabels[old.labels] = merged.count
            merged.append(KubeSeries(labels: old.labels, points: kept))
        }
        for new in answer {
            let points = new.points.filter { $0.time >= start }
            if let index = byLabels[new.labels] {
                merged[index].points += points
            } else {
                byLabels[new.labels] = merged.count
                merged.append(KubeSeries(labels: new.labels, points: points))
            }
        }
        merged.removeAll { $0.points.isEmpty }
        // Another range of the same query isn't drawn again: gone at once.
        for other in entries.keys where other.query == key.query && other != key { entries[other] = nil }
        entries[key] = Entry(series: merged, start: start, end: asked.end, bytes: Self.size(merged), used: clock)
        evict()
    }

    func series(_ key: Key) -> [KubeSeries]? { entries[key]?.series }

    /// Marked used: the last to be evicted.
    mutating func touch(_ key: Key) {
        clock += 1
        entries[key]?.used = clock
    }

    mutating func removeAll() { entries = [:] }

    /// About what its points and labels take: 16 bytes a point.
    static func size(_ series: [KubeSeries]) -> Int {
        series.reduce(0) { total, one in total + one.points.count * 16 + one.labels.reduce(48) { $0 + $1.key.utf8.count + $1.value.utf8.count + 32 } }
    }

    private mutating func evict() {
        var total = bytes
        while entries.count > Self.maxEntries || total > Self.maxBytes, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            total -= oldest.value.bytes
            entries[oldest.key] = nil
        }
    }
}
