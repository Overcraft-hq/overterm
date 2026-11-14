import Foundation
import os

/// A context's Prometheus answers kept between refreshes (metrics.md 6.1):
/// an LRU of at most 96 entries and 12 MB, keyed by the query, the range
/// it was asked over and the step. A refresh asks only from a few steps
/// before the last answer's end (`KubeMetricsSpan.overlap`) to now, and
/// what comes back replaces the points from there on; points before the
/// range's start are dropped. A range change is another key — the old
/// range's points are never drawn on the new axis — and the query's other
/// ranges are dropped with it. A cancelled or failed answer is never
/// merged. In memory only, dropped on a context or kubeconfig change and
/// 10 minutes after the page hides (`KubePrometheusMonitor`). Pure, but
/// for the counts below: a version no cache repeats, and where merges ran.
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
    /// Each query's last change — a put, an eviction, a drop — from a
    /// count no cache ever repeats: a query untouched since `version` was
    /// read is as it was then, in this cache or a new one.
    private var versions: [String: UInt64] = [:]

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

    /// What changed `query` last (0: nothing since this cache was made).
    func version(_ query: String) -> UInt64 { versions[query] ?? 0 }

    /// What an entry merged off the main thread from what `key` held at
    /// `version` is now: kept as it is (nothing of the query changed
    /// meanwhile); merged again over `Entry` (another answer was kept for
    /// the key meanwhile); or not to be kept at all — the key gone since
    /// (another range of the query kept, the cache dropped or the entry
    /// evicted), where a tail asked from the old entry's end would be
    /// kept as if it covered the whole span, or put over the new range.
    enum Keeping: Sendable {
        case keep
        case again(Entry)
        case gone
    }

    func keeping(_ key: Key, since version: UInt64) -> Keeping {
        guard self.version(key.query) != version else { return .keep }
        guard let entry = entries[key] else { return .gone }
        return .again(entry)
    }

    /// An answer over `asked` merged: each series' points from the asked
    /// start replaced by the answer's (a series the answer doesn't have
    /// keeps what it had before), then everything before `start` dropped.
    mutating func merge(_ key: Key, series answer: [KubeSeries], asked: (start: Date, end: Date), start: Date) {
        put(key, Self.merged(entries[key], series: answer, asked: asked, start: start))
    }

    /// What `merge` keeps for a key that held `old`: pure, so the monitor
    /// makes it off the main thread — a thousand series of 300 points is
    /// tens of milliseconds — and only `put`s it there (metrics.md 5.3).
    static func merged(_ old: Entry?, series answer: [KubeSeries], asked: (start: Date, end: Date), start: Date) -> Entry {
        mergeThreads.count(onMain: pthread_main_np() != 0)
        var merged: [KubeSeries] = []
        var byLabels: [[String: String]: Int] = [:]
        for old in old?.series ?? [] {
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
        return Entry(series: merged, start: start, end: asked.end, bytes: size(merged), used: 0)
    }

    /// A merged entry kept: the most recently used, the query's other
    /// ranges gone at once (never drawn again), then the bounds.
    mutating func put(_ key: Key, _ entry: Entry) {
        clock += 1
        changed(key.query)
        var entry = entry
        entry.used = clock
        for other in entries.keys where other.query == key.query && other != key { entries[other] = nil }
        entries[key] = entry
        evict()
    }

    func entry(_ key: Key) -> Entry? { entries[key] }

    func series(_ key: Key) -> [KubeSeries]? { entries[key]?.series }

    /// Marked used: the last to be evicted.
    mutating func touch(_ key: Key) {
        clock += 1
        entries[key]?.used = clock
    }

    mutating func removeAll() {
        for query in Set(entries.keys.map(\.query)) { changed(query) }
        entries = [:]
    }

    private mutating func changed(_ query: String) { versions[query] = Self.changes.next() }

    /// About what its points and labels take: 16 bytes a point.
    static func size(_ series: [KubeSeries]) -> Int {
        series.reduce(0) { total, one in total + one.points.count * 16 + one.labels.reduce(48) { $0 + $1.key.utf8.count + $1.value.utf8.count + 32 } }
    }

    private mutating func evict() {
        var total = bytes
        while entries.count > Self.maxEntries || total > Self.maxBytes, let oldest = entries.min(by: { $0.value.used < $1.value.used }) {
            total -= oldest.value.bytes
            entries[oldest.key] = nil
            changed(oldest.key.query)
        }
    }
}

extension KubeChartCache {
    /// The changes' count, every cache's: a dropped cache's successor
    /// never gives a query a version it had before.
    fileprivate static let changes = Counter()

    fileprivate final class Counter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: UInt64(0))
        func next() -> UInt64 {
            value.withLock {
                $0 += 1
                return $0
            }
        }
    }

    /// Where `merged` ran, every call: the scenarios check none ran on
    /// the main thread (metrics.md 5.3) — where it runs, not where a
    /// caller meant it to.
    static let mergeThreads = MergeThreads()

    final class MergeThreads: Sendable {
        private let counts = OSAllocatedUnfairLock(initialState: (all: 0, onMain: 0))
        fileprivate func count(onMain: Bool) {
            counts.withLock {
                $0.all += 1
                if onMain { $0.onMain += 1 }
            }
        }
        /// How many merges ran, and how many of them on the main thread.
        var counted: (all: Int, onMain: Int) { counts.withLock { $0 } }
    }
}
