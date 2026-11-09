import Foundation
import XCTest

@testable import Overterm

/// The Metrics tab over Prometheus (docs/design/kubernetes/metrics.md,
/// 3.3–3.5, 4.7, 6.1; stage M6): each range's step, points and refresh,
/// the end on a step, a window's own step, Custom's checks, a drag's zoom,
/// the source ladder, the answers' cache, and the charts built from what
/// Prometheus answered. Pure.
final class KubeMetricsSpanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_017)

    // MARK: Ranges and steps

    func testEachRangesStepPointsAndRefresh() {
        let table: [(KubeMetricsRange, TimeInterval, Int, TimeInterval)] = [
            (.live, 30, 31, 30), (.hour, 30, 121, 60), (.sixHours, 120, 181, 120), (.day, 300, 289, 300), (.week, 1800, 337, 900),
        ]
        for (range, step, points, refresh) in table {
            let span = KubeMetricsSpan.of(range, scrape: 30, now: now)
            XCTAssertEqual(span.step, step, "\(range)")
            XCTAssertEqual(span.points, points, "\(range)")
            XCTAssertEqual(span.refresh, refresh, "\(range)")
            XCTAssertLessThanOrEqual(span.points, 337, "the table's 7d is the most")
            XCTAssertEqual(span.end.timeIntervalSince1970.truncatingRemainder(dividingBy: step), 0, "the end on a step")
            XCTAssertLessThanOrEqual(span.end, now)
            XCTAssertEqual(span.end.timeIntervalSince(span.start), range.prometheusSpan)
        }
        XCTAssertEqual(KubeMetricsRange.live.prometheusSpan, 900, "Live over Prometheus: 15 minutes")
        // A minute's scrape: Live and 1h at a minute, a 30 s step holding nothing new every other point.
        XCTAssertEqual(KubeMetricsSpan.of(.live, scrape: 60, now: now).step, 60)
        XCTAssertEqual(KubeMetricsSpan.of(.hour, scrape: 60, now: now).step, 60)
        XCTAssertEqual(KubeMetricsSpan.of(.sixHours, scrape: 60, now: now).step, 120)
        // Asked again within a step, the same.
        XCTAssertEqual(KubeMetricsSpan.of(.hour, scrape: 30, now: now), KubeMetricsSpan.of(.hour, scrape: 30, now: now.addingTimeInterval(10)))
        // The rate windows of the table.
        XCTAssertEqual(KubeRateWindow.of(step: 30, scrape: 30), 120)
        XCTAssertEqual(KubeRateWindow.of(step: 120, scrape: 30), 180)
        XCTAssertEqual(KubeRateWindow.of(step: 300, scrape: 30), 360)
        XCTAssertEqual(KubeRateWindow.of(step: 1800, scrape: 30), 1860)
    }

    func testAWindowsOwnStep() {
        func window(_ span: TimeInterval) -> KubeChartWindow { KubeChartWindow(start: now.addingTimeInterval(-span), end: now, kind: .zoom) }
        XCTAssertEqual(KubeMetricsSpan.of(window(7200), scrape: 30).step, 30, "2 hours: 28.8 s, a nice 30 s")
        XCTAssertEqual(KubeMetricsSpan.of(window(7200), scrape: 60).step, 60, "never under the scrape")
        XCTAssertEqual(KubeMetricsSpan.of(window(600), scrape: 15).step, 15)
        XCTAssertEqual(KubeMetricsSpan.of(window(86400), scrape: 30).step, 600)
        XCTAssertEqual(KubeMetricsSpan.of(window(30 * 86400), scrape: 30).step, 10800, "30 days at 3h")
        for span: TimeInterval in [60, 900, 7200, 86400, 7 * 86400, 30 * 86400] {
            let asked = KubeMetricsSpan.of(window(span), scrape: 30)
            XCTAssertLessThanOrEqual(asked.points, 300, "\(span)")
            XCTAssertNil(asked.refresh, "a window isn't refreshed")
            XCTAssertEqual(asked.start, window(span).start)
        }
        XCTAssertEqual(KubeMetricsSpan.overlap(step: 30, scrape: 30), 2)
        XCTAssertEqual(KubeMetricsSpan.overlap(step: 15, scrape: 60), 6, "⌈(60 + 30) ÷ 15⌉")
    }

    func testCustomsDatesAreChecked() {
        let hour = now.addingTimeInterval(-3600)
        XCTAssertEqual(try KubeChartWindow.custom(start: hour, end: now, now: now, retention: nil).get(), KubeChartWindow(start: hour, end: now, kind: .custom))
        func why(_ start: Date, _ end: Date, retention: Date? = nil) -> String? {
            if case .failure(let invalid) = KubeChartWindow.custom(start: start, end: end, now: now, retention: retention) { return invalid.sentence }
            return nil
        }
        XCTAssertEqual(why(now, hour), "The start must be before the end.")
        XCTAssertEqual(why(hour, now.addingTimeInterval(600)), "The end can't be in the future.")
        XCTAssertEqual(why(now.addingTimeInterval(-30), now), "Pick a minute or more.")
        XCTAssertEqual(why(now.addingTimeInterval(-31 * 86400), now), "At most 30 days back.")
        let kept = now.addingTimeInterval(-2 * 86400)
        XCTAssertTrue(why(now.addingTimeInterval(-3 * 86400), now, retention: kept)?.hasPrefix("Prometheus keeps data from ") == true)
        XCTAssertNil(why(now.addingTimeInterval(-86400), now, retention: kept))
        XCTAssertEqual(try KubeChartWindow.custom(start: hour, end: now.addingTimeInterval(30), now: now, retention: nil).get().end, now, "a moment ahead: now")
    }

    func testADragZoomsInsideWhatTheChartShows() {
        let start = now.addingTimeInterval(-3600)
        let zoom = KubeChartWindow.zoom(from: now.addingTimeInterval(-600), to: now.addingTimeInterval(-1800), within: start, now, sampledTier: .live)
        XCTAssertEqual(zoom, KubeChartWindow(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-600), kind: .zoom, sampledTier: .live), "either way round")
        XCTAssertEqual(zoom?.tier, .live, "inside Live: its raw samples")
        XCTAssertNil(KubeChartWindow.zoom(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(-30), within: start, now, sampledTier: .live), "under a minute")
        XCTAssertEqual(
            KubeChartWindow.zoom(from: start.addingTimeInterval(-600), to: start.addingTimeInterval(600), within: start, now, sampledTier: .sixHours)?.start, start,
            "kept inside the chart")
        XCTAssertEqual(KubeChartWindow.around(now, now: now).tier, .sixHours, "a marker's: 6h's minutes")
    }

    // MARK: The source ladder

    func testTheSourceLadder() {
        func pick(_ subject: KubeMetricsSubject, _ range: KubeMetricsRange, window: KubeChartWindow? = nil, server: Bool, prometheus: Bool) -> KubeChartSource? {
            KubeChartSource.pick(subject: subject, range: range, window: window, metricsServer: server, prometheus: prometheus)
        }
        XCTAssertEqual(pick(.pod, .live, server: true, prometheus: false), .sampled)
        XCTAssertEqual(pick(.pod, .sixHours, server: true, prometheus: false), .sampled)
        XCTAssertNil(pick(.pod, .live, server: false, prometheus: false), "nothing to draw from")
        XCTAssertEqual(pick(.hpa, .live, server: false, prometheus: false), .sampled, "an HPA's status needs no metrics-server")
        // Live with both: sampled, and what has no sampled form from Prometheus.
        XCTAssertEqual(pick(.pod, .live, server: true, prometheus: true), .mixed)
        XCTAssertEqual(pick(.pod, .live, server: false, prometheus: true), .prometheus, "only Prometheus: every chart its")
        for range in [KubeMetricsRange.hour, .sixHours, .day, .week] { XCTAssertEqual(pick(.pod, range, server: true, prometheus: true), .prometheus, "\(range)") }
        // A zoom keeps what it zoomed; a marker's window or Custom is Prometheus'.
        let zoom = KubeChartWindow(start: now.addingTimeInterval(-600), end: now, kind: .zoom, sampledTier: .live)
        XCTAssertEqual(pick(.pod, .live, window: zoom, server: true, prometheus: true), .mixed)
        XCTAssertEqual(pick(.pod, .live, window: KubeChartWindow.around(now, now: now), server: true, prometheus: true), .prometheus)
        XCTAssertEqual(pick(.pod, .live, window: KubeChartWindow.around(now, now: now), server: true, prometheus: false), .sampled)
        XCTAssertEqual(pick(.namespace, .hour, server: true, prometheus: true), .prometheus, "a namespace's too (M7)")
        XCTAssertEqual(pick(.namespace, .live, server: true, prometheus: true), .mixed)
        XCTAssertEqual(KubePromTabCharts.families(.namespace, source: .mixed), [], "a namespace's Live: what was sampled, nothing asked")
        XCTAssertEqual(KubePromTabCharts.families(.namespace, source: .prometheus), [.cpu, .memory, .phases, .quota, .idle])
        XCTAssertEqual(KubePromTabCharts.families(.pod, source: .mixed), [.throttling, .network, .restarts, .oom, .fs])
        XCTAssertEqual(KubePromTabCharts.families(.node, source: .mixed), [.disks, .nodeNetwork], "a node's disks and network have no sampled form (M8b)")
        XCTAssertEqual(KubePromTabCharts.families(.workload("Deployment"), source: .mixed), [.restarts, .oom])
        XCTAssertTrue(KubePromTabCharts.families(.pod, source: .sampled).isEmpty)
    }

    // MARK: The cache

    private func series(_ labels: [String: String], _ times: [Double], value: Double = 1) -> KubeSeries {
        KubeSeries(labels: labels, points: times.map { KubeSeriesPoint(time: Date(timeIntervalSince1970: $0), value: value) })
    }

    func testAnIncrementalRefreshAsksTheTailAndReplacesIt() throws {
        var cache = KubeChartCache()
        let key = KubeChartCache.Key(query: "q", range: "1h", step: 30)
        let first = KubePromSpan(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), step: 30, refresh: 60)
        let asked = try XCTUnwrap(cache.ask(key, span: first, scrape: 30))
        XCTAssertEqual(asked.start, first.start, "nothing kept: all of it")
        cache.merge(key, series: [series(["c": "app"], Array(stride(from: 0, through: 3600, by: 30)))], asked: asked, start: first.start)
        XCTAssertNil(cache.ask(key, span: first, scrape: 30), "asked again within a step: nothing new")
        // A minute later: from two steps before the last end, the last point asked again.
        let later = KubePromSpan(start: Date(timeIntervalSince1970: 60), end: Date(timeIntervalSince1970: 3660), step: 30, refresh: 60)
        let tail = try XCTUnwrap(cache.ask(key, span: later, scrape: 30))
        XCTAssertEqual(tail.start, Date(timeIntervalSince1970: 3540), "k = max(2, ⌈(30 + 30) ÷ 30⌉) = 2 steps back")
        XCTAssertEqual(tail.end, later.end)
        cache.merge(key, series: [series(["c": "app"], [3540, 3570, 3600, 3630, 3660], value: 2)], asked: tail, start: later.start)
        let merged = try XCTUnwrap(cache.series(key)?.first)
        XCTAssertEqual(merged.points.first?.time, Date(timeIntervalSince1970: 60), "points before the start dropped")
        XCTAssertEqual(merged.points.last?.time, Date(timeIntervalSince1970: 3660))
        XCTAssertEqual(merged.points.filter { $0.time >= Date(timeIntervalSince1970: 3540) }.map(\.value), [2, 2, 2, 2, 2], "the tail replaced, the half-scraped point too")
        XCTAssertEqual(merged.points.count, 121, "no point twice")
        // A series gone from the answer keeps what it had before the asked start.
        cache.merge(key, series: [], asked: (Date(timeIntervalSince1970: 3600), Date(timeIntervalSince1970: 3690)), start: Date(timeIntervalSince1970: 90))
        XCTAssertEqual(cache.series(key)?.first?.points.last?.time, Date(timeIntervalSince1970: 3570))
    }

    func testARangeChangeDiscardsAndTheLRUIsBounded() {
        var cache = KubeChartCache()
        let hour = KubeChartCache.Key(query: "q", range: "1h", step: 30)
        let day = KubeChartCache.Key(query: "q", range: "24h", step: 300)
        cache.merge(hour, series: [series([:], [0, 30])], asked: (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 30)), start: Date(timeIntervalSince1970: 0))
        cache.merge(day, series: [series([:], [0, 300])], asked: (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 300)), start: Date(timeIntervalSince1970: 0))
        XCTAssertNil(cache.series(hour), "another range of the same query: gone")
        XCTAssertNotNil(cache.series(day))
        for index in 0..<(KubeChartCache.maxEntries + 10) {
            let key = KubeChartCache.Key(query: "q\(index)", range: "1h", step: 30)
            cache.merge(key, series: [series([:], [0])], asked: (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 0)), start: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(cache.count, KubeChartCache.maxEntries)
        XCTAssertNil(cache.series(day), "the least recently used went first")
        var big = KubeChartCache()
        let many = (0..<200_000).map(Double.init)
        for index in 0..<6 {
            let key = KubeChartCache.Key(query: "big\(index)", range: "7d", step: 1)
            big.merge(key, series: [series([:], many)], asked: (Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 200_000)), start: Date(timeIntervalSince1970: 0))
        }
        XCTAssertLessThanOrEqual(big.bytes, KubeChartCache.maxBytes, "12 MB at most")
    }

    // MARK: Charts from Prometheus

    private func reading(_ results: [String: [KubeSeries]], span: KubePromSpan, refused: [KubeTabFamily: String] = [:]) -> KubeTabReading {
        var reading = KubeTabReading(request: KubeTabTesting.request(.hour))
        reading.service = KubePrometheusService(namespace: "monitoring", name: "prometheus-operated", port: "9090")
        reading.results = results
        reading.span = span
        reading.read = span.end
        reading.tier = .raw
        reading.refused = refused
        var profile = KubePromProfile(probed: span.end)
        profile.scrape = 30
        reading.profile = profile
        return reading
    }

    private func pod(limit: Bool) -> [String: Any] {
        let resources: [String: Any] = ["requests": ["cpu": "250m", "memory": "64Mi"], "limits": limit ? ["cpu": "1", "memory": "128Mi"] : ["memory": "128Mi"]]
        return [
            "metadata": ["name": "web-1", "namespace": "shop"],
            "spec": ["containers": [["name": "app", "resources": resources], ["name": "sidecar", "resources": [:]]]],
            "status": ["containerStatuses": [["name": "app", "restartCount": 1]]],
        ]
    }

    func testAPodsChartsFromPrometheus() throws {
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        let times = stride(from: span.start.timeIntervalSince1970, through: span.end.timeIntervalSince1970, by: 30).map { $0 }
        let oomAt = span.end.addingTimeInterval(-600).timeIntervalSince1970
        let built = KubePromTabCharts.pod(
            namespace: "shop", pod: "web-1", object: pod(limit: true),
            reading: reading(
                [
                    "cpu": [series(["container": "app"], times, value: 0.12), series(["container": "sidecar"], times, value: 0.01)],
                    "memory": [series(["container": "app"], times, value: 100 * 1_048_576)],
                    "throttling": [series(["container": "app"], times, value: 0.31)],
                    "network": [series(["overterm_s": "rx"], times, value: 1000), series(["overterm_s": "tx"], times, value: 500)],
                    "restarts": [series([:], times, value: 0)],
                    "oom": [series(["container": "app"], [oomAt, oomAt + 30])],
                ], span: span), changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(built.pod.map(\.data.id), ["pod.shop.web-1.cpu", "pod.shop.web-1.memory", "pod.shop.web-1.network", "pod.shop.web-1.restarts"])
        XCTAssertEqual(built.pod[0].data.usage.map(\.id), ["app", "sidecar"])
        XCTAssertTrue(built.pod[0].data.stacked)
        XCTAssertEqual(built.pod[0].data.source, "Prometheus")
        XCTAssertEqual(built.pod[0].data.start, span.start)
        XCTAssertEqual(built.pod[0].data.step, 30)
        XCTAssertEqual(built.sections.map(\.container), ["app", "sidecar"])
        let app = built.sections[0]
        XCTAssertEqual(app.charts.map(\.data.id), ["container.shop.web-1.app.cpu", "container.shop.web-1.app.memory", "container.shop.web-1.app.throttling"])
        XCTAssertEqual(app.charts[0].chips.map(\.text), ["48% of request", "12% of limit"])
        let throttling = app.charts[2]
        XCTAssertEqual(throttling.data.unit, .ratio)
        XCTAssertEqual(throttling.data.references.map(\.role), [.guide])
        XCTAssertEqual(throttling.chips.first, KubeChartChip(text: "31% throttled", alert: true), "past the 25% guide")
        XCTAssertEqual(built.sections[1].notes, ["No CPU limit: never throttled."])
        XCTAssertEqual(built.pod[2].headline, "rx 1000B/s · tx 500B/s")
        XCTAssertTrue(built.pod[3].data.stepped)
        // The OOMKill kube-state-metrics saw: one marker, on the step, its container's and the pod's.
        let marked = built.sections[0].charts[1].data.shownMarkers
        XCTAssertEqual(marked.map(\.kind), [.oom])
        XCTAssertEqual(marked.first?.opens, .previousLog(pod: nil, container: "app"))
        XCTAssertTrue(marked.first?.title.contains("app: OOMKilled between") == true, marked.first?.title ?? "")
        XCTAssertEqual(built.pod[1].data.shownMarkers.count, 1)
        XCTAssertTrue(built.sections[1].charts[0].data.shownMarkers.isEmpty, "not the sidecar's")
        XCTAssertTrue(built.caption.hasPrefix("Prometheus monitoring/prometheus-operated:9090 · the last 1h at 30s · raw cAdvisor · scrape 30s"), built.caption)
    }

    func testLiveAddsWhatOnlyPrometheusHas() throws {
        let sampled = KubePodCharts.build(namespace: "shop", pod: "web-1", object: pod(limit: false), ring: KubeUsageRing(), range: .live, now: now, interval: 15)
        let span = KubeMetricsSpan.of(.live, scrape: 30, now: now)
        let times = [span.start.timeIntervalSince1970, span.end.timeIntervalSince1970]
        let oomAt = span.end.addingTimeInterval(-300).timeIntervalSince1970
        let mixed = KubePromTabCharts.addOnly(
            sampled, namespace: "shop", pod: "web-1", object: pod(limit: false),
            reading: reading(
                ["network": [series(["overterm_s": "rx"], times)], "restarts": [series([:], times)], "oom": [series(["container": "app"], [oomAt])]], span: span),
            changes: KubeChartChanges())
        XCTAssertEqual(mixed.pod.count, sampled.pod.count + 2, "network and restarts")
        XCTAssertEqual(mixed.sections[0].charts.count, 2, "no CPU limit, no throttling chart")
        XCTAssertEqual(mixed.sections[0].notes, ["No CPU limit: never throttled."])
        // The earlier OOMKill Prometheus saw, on the sampled charts too (C2, P2): the pod's, app's, not the sidecar's.
        let memory = try XCTUnwrap(mixed.pod.first { $0.data.id == "pod.shop.web-1.memory" })
        XCTAssertEqual(memory.data.source, "metrics-server")
        XCTAssertEqual(memory.data.shownMarkers.map(\.kind), [.oom])
        let app = try XCTUnwrap(mixed.sections.first { $0.container == "app" }?.charts.first { $0.data.id.hasSuffix(".memory") })
        XCTAssertEqual(app.data.shownMarkers.map(\.kind), [.oom])
        XCTAssertNotEqual(app.data.version, sampled.sections[0].charts[1].data.version, "its plot drawn again")
        XCTAssertTrue(mixed.sections.first { $0.container == "sidecar" }?.charts.allSatisfy { $0.data.shownMarkers.isEmpty } == true)
        XCTAssertTrue(mixed.caption.contains("from Prometheus over 15m at 30s"), mixed.caption)
        XCTAssertFalse(mixed.caption.contains("needs Prometheus"))
    }

    /// C1's peak band (24h and 7d) behind a container's CPU, never summed
    /// into it; C2's RSS beside the working set, hidden until clicked.
    func testAPodsPeakBandAndRSS() throws {
        let span = KubeMetricsSpan.of(.day, scrape: 30, now: now)
        let times = stride(from: span.start.timeIntervalSince1970, through: span.end.timeIntervalSince1970, by: span.step).map { $0 }
        let built = KubePromTabCharts.pod(
            namespace: "shop", pod: "web-1", object: pod(limit: true),
            reading: reading(
                [
                    "cpu": [series(["container": "app"], times, value: 0.1)], "cpuPeak": [series(["container": "app"], times, value: 0.6)],
                    "memory": [series(["container": "app"], times, value: 100 * 1_048_576)], "rss": [series(["container": "app"], times, value: 60 * 1_048_576)],
                ], span: span), changes: KubeChartChanges(), window: nil)
        let app = try XCTUnwrap(built.sections.first { $0.container == "app" })
        let cpu = app.charts[0].data
        XCTAssertEqual(cpu.usage.map(\.id), ["cpu"], "the peak isn't usage")
        XCTAssertEqual(cpu.peaks.map(\.id), ["peak"])
        XCTAssertEqual(cpu.legendSeries.map(\.id), ["cpu", "peak"], "a legend item to hide it")
        XCTAssertEqual(KubeChartSummary.totals(cpu).last?.value ?? 0, 0.1, accuracy: 1e-9, "never summed into the usage")
        let plot = KubePlot(cpu, size: CGSize(width: 400, height: 140))
        XCTAssertEqual(plot.peaks.map(\.id), ["peak"])
        XCTAssertEqual(plot.lines.count, 1)
        XCTAssertGreaterThanOrEqual(plot.top, 0.6, "the axis holds the peak")
        XCTAssertNotNil(plot.lines.first?.fill, "the usage still filled: one usage line")
        XCTAssertTrue(KubePlot(cpu, size: CGSize(width: 400, height: 140), hidden: ["peak"]).peaks.isEmpty, "hidden from the legend")
        let tip = KubeChartTooltip.at(span.end, plot: plot, step: span.step)
        XCTAssertEqual(tip.rows.map(\.role), [.usage, .peak, .request, .limit])
        let memory = app.charts[1].data
        XCTAssertEqual(memory.usage.map(\.id), ["memory", "rss"])
        XCTAssertEqual(memory.hiddenByDefault, ["rss"], "RSS off by default")
        XCTAssertEqual(KubeChartSummary.totals(memory).last?.value, 100 * 1_048_576, "the working set alone")
        XCTAssertTrue(built.pod[0].data.peaks.isEmpty, "the pod's stacked CPU has none")
        XCTAssertTrue(built.sections.first { $0.container == "sidecar" }?.charts[0].data.peaks.isEmpty == true)
    }

    func testAWorkloadsChartsFromPrometheus() {
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        let times = [span.end.addingTimeInterval(-60).timeIntervalSince1970, span.end.timeIntervalSince1970]
        let names = ["web-7f9c6d-aaaaa", "web-7f9c6d-bbbbb", "web-55d4f-ccccc", "web-55d4f-ddddd", "web-55d4f-fffff", "web-55d4f-ggggg", "web-55d4f-hhhhh"]
        let value = { (name: String) in Double((names.firstIndex(of: name) ?? 0) + 1) / 10 }
        // The ranking named the five largest; the range queries asked for them alone, and the total.
        let ranked = ["web-55d4f-hhhhh", "web-55d4f-ggggg", "web-55d4f-fffff", "web-55d4f-ddddd", "web-55d4f-ccccc"]
        let tops = ranked.map { series(["pod": $0], times, value: value($0)) }
        let total = names.reduce(0) { $0 + value($1) }
        let object: [String: Any] = [
            "spec": ["template": ["spec": ["containers": [["name": "app", "resources": ["requests": ["cpu": "100m"], "limits": ["cpu": "1"]]]]]]], "status": ["replicas": 7],
        ]
        var answers = reading(
            [
                "cpu": [series([:], times, value: total)], "cpuTop": tops, "memory": [series([:], times, value: total)], "memoryTop": tops,
                "revisions": [series(["replicaset": "web-55d4f"], times, value: 2.5), series(["replicaset": "web-7f9c6d"], times, value: 0.3)],
                "replicas": [series(["overterm_s": "desired"], times, value: 7), series(["overterm_s": "available"], times, value: 6)],
            ], span: span)
        answers.ranking = KubeTabRanking(key: "k", names: ["cpu": ranked, "memory": ranked])
        answers.selection = .owner
        let charts = KubePromTabCharts.workload(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: object, ring: KubeUsageRing(), statuses: KubeStatusHistory(), pods: [], range: .hour, now: now,
                interval: 15, revisions: ["web-55d4f": "rev 14 (nginx:1.27.2)"]),
            reading: answers)
        let cpu = charts.groups[0].charts[0].data
        XCTAssertEqual(charts.view, .total, "seven replicas: Total")
        XCTAssertEqual(cpu.usage.map(\.id), ranked + ["other"], "the ranking's order, then the rest")
        XCTAssertTrue(cpu.stacked)
        XCTAssertEqual(cpu.usage.last?.points.last?.value ?? 0, 0.3, accuracy: 1e-9, "other: the total less the five")
        XCTAssertEqual(cpu.references.map { (($0.points.last?.value ?? 0) * 1000).rounded() }, [700, 7000], "the template × 7")
        XCTAssertEqual(cpu.tier, "raw cAdvisor · by owner")
        XCTAssertEqual(charts.groups[0].charts[0].headline, "total \(KubeMetricsFormat.cpu(total))", "the total, not the five")
        let revisions = charts.groups[0].charts.first { $0.data.id.hasSuffix(".revisions") }?.data
        XCTAssertEqual(revisions?.usage.map(\.name), ["rev 14 (nginx:1.27.2)", "rev 7f9c6d"], "by ReplicaSet, labelled from its History")
        let replicas = charts.groups[0].charts.first { $0.data.id.hasSuffix(".replicas") }?.data
        XCTAssertEqual(replicas?.usage.map(\.id), ["available", "unavailable"])
        XCTAssertEqual(replicas?.usage.last?.points.last?.value, 1, "desired less available")
        // Per pod: the five as lines against one pod's template; no ranking yet, the total alone.
        let perPod = KubePromTabCharts.workload(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: object, ring: KubeUsageRing(), statuses: KubeStatusHistory(), pods: [], range: .hour, now: now,
                interval: 15, view: .perPod),
            reading: answers)
        XCTAssertEqual(perPod.groups[0].charts[0].data.usage.map(\.id), ranked)
        XCTAssertFalse(perPod.groups[0].charts[0].data.stacked)
        answers.ranking = nil
        answers.results["cpuTop"] = nil
        let unranked = KubePromTabCharts.workload(
            KubeWorkloadCharts.Input(
                namespace: "shop", kind: "Deployment", name: "web", object: object, ring: KubeUsageRing(), statuses: KubeStatusHistory(), pods: [], range: .hour, now: now,
                interval: 15),
            reading: answers)
        XCTAssertEqual(unranked.groups[0].charts[0].data.usage.map(\.id), ["total"])
    }

    func testAnHPAsAndANodesChartsFromPrometheus() {
        let span = KubeMetricsSpan.of(.hour, scrape: 30, now: now)
        let times = stride(from: span.start.timeIntervalSince1970, through: span.end.timeIntervalSince1970, by: 30).map { $0 }
        let hpa = KubePromTabCharts.hpa(
            namespace: "shop", name: "web",
            reading: reading(
                [
                    "hpa": ["current", "desired", "min", "max"].map { series(["overterm_s": $0], times, value: $0 == "max" ? 10 : $0 == "min" ? 2 : 4) },
                    "hpaMetrics": [series(["overterm_s": "current", "metric_name": "cpu"], times, value: 80), series(["overterm_s": "target", "metric_name": "cpu"], times, value: 60)],
                ], span: span), changes: KubeChartChanges(), window: nil)
        XCTAssertEqual(hpa.charts.map(\.data.id), ["hpa.shop.web.replicas", "hpa.shop.web.cpu"])
        XCTAssertEqual(hpa.charts[0].headline, "4 now · 2–10")
        XCTAssertEqual(hpa.charts[1].chips.first?.text, "133% of target")
        let pressure = span.end.addingTimeInterval(-900).timeIntervalSince1970
        let node = KubePromTabCharts.node(
            node: "ip-10-0-0-1", facts: KubeNodeFacts.of(["status": ["allocatable": ["cpu": "4", "memory": "8Gi", "pods": "29"]]]),
            reading: reading(
                [
                    "cpu": [series(["overterm_s": "usage"], times, value: 1), series(["overterm_s": "request"], times, value: 3)],
                    "pods": [series([:], times, value: 12)],
                    "conditions": [series(["condition": "MemoryPressure"], [pressure, pressure + 30, pressure + 60])],
                ], span: span), changes: KubeChartChanges(), window: nil)
        let cpu = node.groups[0].charts[0]
        XCTAssertEqual(cpu.chips.map(\.text), ["25% of allocatable", "requests 75% of allocatable"])
        XCTAssertEqual(cpu.data.bands.map(\.title), ["MemoryPressure"])
        XCTAssertEqual(cpu.data.bands.first?.end, Date(timeIntervalSince1970: pressure + 90), "to the end of its last step")
        XCTAssertEqual(node.groups[0].charts[1].headline, "12 active")
    }
}
