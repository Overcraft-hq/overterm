import XCTest

@testable import Overterm

/// A chart said as text for an agent (docs/design/kubernetes/metrics.md 7;
/// stage M11, `KubeMetricsText`): the figures by nearest rank, gaps left
/// out rather than read as zero, the last against each reference line,
/// a stacked chart's total first, the markers newest few, names cut, and
/// an answer bounded to whole lines. Pure: a fixed zone and clock.
final class KubeMetricsTextTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Istanbul")!
    /// 2026-11-09 14:32 in Istanbul (GMT+3).
    private let now = Date(timeIntervalSince1970: 1_794_223_920)
    private let mi = 1_048_576.0

    private func points(_ values: [Double?], step: TimeInterval = 30) -> [KubeSeriesPoint] {
        values.enumerated().map { index, value in
            KubeSeriesPoint(time: now.addingTimeInterval(-step * Double(values.count - 1 - index)), value: value ?? .nan)
        }
    }

    private func memory(_ values: [Double?], limit: Double? = 512, request: Double? = nil) -> KubeChartData {
        var series = [KubeChartSeries(id: "memory", name: "Working set", points: points(values.map { $0.map { $0 * mi } }))]
        if let request { series.append(KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: now, value: request * mi)])) }
        if let limit { series.append(KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: now, value: limit * mi)])) }
        return KubeChartData(
            id: "container.shop.api-1.app.memory", title: "Memory", unit: .bytes, series: series, start: now.addingTimeInterval(-3600), end: now, step: 30,
            source: "Prometheus", tier: "raw cAdvisor")
    }

    func testFiguresByNearestRankWithGapsLeftOut() throws {
        let figures = try XCTUnwrap(KubeMetricsText.figures(points([3, nil, 1, 4, 1, 5, 9, 2, 6, .infinity])))
        XCTAssertEqual(figures.count, 8, "a NaN and an ∞ are gaps, not points")
        XCTAssertEqual(figures.min.value, 1)
        XCTAssertEqual(figures.min.time, now.addingTimeInterval(-30 * 7), "the first time it was lowest")
        XCTAssertEqual(figures.max.value, 9)
        XCTAssertEqual(figures.p50, 3)
        XCTAssertEqual(figures.p95, 9)
        XCTAssertEqual(figures.last.value, 6, "the last point that is a number")
        XCTAssertNil(KubeMetricsText.figures(points([nil, nil])), "nothing but gaps: no figures")
        XCTAssertNil(KubeMetricsText.figures([]))
    }

    func testTheLastAgainstEachReferenceLine() {
        let lines = KubeMetricsText.chart(memory([400, 412, 509, 415], request: 256), label: "app · Memory", now: now, timeZone: zone)
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertEqual(
            lines[0],
            "app · Memory: last 415Mi at 14:32 (162% of request 256Mi, 81% of limit 512Mi), min 400Mi at 14:30, p50 412Mi, p95 509Mi, max 509Mi at 14:31")
        let one = KubeMetricsText.chart(memory([100]), label: "Memory", now: now, timeZone: zone)
        XCTAssertEqual(one, ["Memory: last 100Mi at 14:32 (20% of limit 512Mi); one point only"])
        let empty = KubeMetricsText.chart(memory([nil, nil]), label: "Memory", now: now, timeZone: zone)
        XCTAssertEqual(empty, ["Memory: nothing in the window (a gap, not zero)."])
    }

    func testAStackedChartSaysItsTotalAgainstTheLinesThenEachSeries() {
        let data = KubeChartData(
            id: "pod.shop.api-1.cpu", title: "CPU", unit: .cores,
            series: [
                KubeChartSeries(id: "app", name: "app", points: points([0.1, 0.2])),
                KubeChartSeries(id: "sidecar", name: "sidecar", points: points([0.01, 0.05])),
                KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: now, value: 1)]),
            ], start: now.addingTimeInterval(-60), end: now, step: 30, stacked: true)
        let lines = KubeMetricsText.chart(data, label: "pod · CPU", now: now, timeZone: zone)
        XCTAssertEqual(lines.count, 3, "\(lines)")
        XCTAssertTrue(lines[0].hasPrefix("pod · CPU, total: last 250m at 14:32 (25% of limit 1000m)"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("  app: last 200m at 14:32, min 100m"), "the largest first, no share: \(lines[1])")
        XCTAssertTrue(lines[2].hasPrefix("  sidecar: last 50m"), lines[2])
    }

    func testMarkersTheNewestFewAndHowManyEarlier() {
        var data = memory([100, 200])
        data.markers = (0..<8).map { index in
            KubeChartMarker(id: "m\(index)", kind: .restart, time: now.addingTimeInterval(-Double(8 - index) * 60), title: "app: restart \(index)")
        }
        data.earlierMarkers = 2
        data.start = now.addingTimeInterval(-3600)
        data.markerNote = KubeChartMarkers.eventsNote
        let said = KubeMetricsText.markers(data, now: now, timeZone: zone)
        XCTAssertEqual(said, "+5 earlier; app: restart 3; app: restart 4; app: restart 5; app: restart 6; app: restart 7 (events: last hour)")
        let lines = KubeMetricsText.chart(data, label: "Memory", now: now, timeZone: zone)
        XCTAssertEqual(lines.last, "  marked: " + (said ?? ""))
    }

    func testTheWindowSaysWhereFromOverWhatAndTheZone() {
        let window = KubeMetricsText.window(memory([1, 2]), now: now, timeZone: zone)
        XCTAssertEqual(window, "last 1h at 30s (13:32–14:32 GMT+3) · Prometheus · raw cAdvisor")
        let yesterday = now.addingTimeInterval(-86400)
        XCTAssertEqual(KubeMetricsText.time(yesterday, now: now, timeZone: zone), "Nov 8 14:32", "another day says its day")
    }

    func testNamesAreCutAndAnswersBoundedToWholeLines() {
        let long = String(repeating: "a", count: 400)
        XCTAssertEqual(KubeMetricsText.name(long).count, KubeMetricsText.maxName)
        XCTAssertTrue(KubeMetricsText.name(long).hasSuffix("…"))
        XCTAssertEqual(KubeMetricsText.name("app"), "app")
        let lines = (0..<200).map { "line \($0) " + String(repeating: "x", count: 60) }
        let bounded = KubeMetricsText.bounded(lines)
        XCTAssertLessThanOrEqual(bounded.count, KubeMetricsText.budget)
        XCTAssertTrue(bounded.hasSuffix("more lines left out: name fewer measures, or a container."), String(bounded.suffix(120)))
        XCTAssertTrue(bounded.components(separatedBy: "\n").dropLast().allSatisfy { $0.hasPrefix("line ") && $0.hasSuffix("x") }, "whole lines")
        XCTAssertEqual(KubeMetricsText.bounded(["a", "b"]), "a\nb")
        XCTAssertEqual(KubeMetricsText.note("partial response"), "Note: “partial response”")
    }

    func testAChartAskedAboutSaysWhoseItIsItsWindowFiguresAndChips() {
        let text = KubeMetricsText.about(
            memory([400, 415]), label: "app · Memory", whose: "pod shop/api-1 on context fake-dev", caption: "Prometheus monitoring/prometheus-k8s:9090",
            chips: [KubeChartChip(text: "working set 81% of limit")], now: now, timeZone: zone)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "pod shop/api-1 on context fake-dev: Prometheus monitoring/prometheus-k8s:9090")
        XCTAssertEqual(lines[1], "last 1h at 30s (13:32–14:32 GMT+3) · Prometheus · raw cAdvisor")
        XCTAssertTrue(lines[2].hasPrefix("app · Memory: last 415Mi at 14:32 (81% of limit 512Mi)"), lines[2])
        XCTAssertEqual(lines.last, "  shown: working set 81% of limit")
    }
}
