import CoreGraphics
import Foundation
import XCTest

@testable import Overterm

/// Stage M1 of docs/design/kubernetes/metrics.md (3.1, 3.6, 5.2): a chart's
/// geometry as a value — the scale rounded to nice values and including
/// every visible reference line, the 3–5 ticks, stacking in legend order,
/// min/max decimation keeping the peaks, gaps as gaps, the nearest point
/// for an x, the cache key —, the tooltip, the summary VoiceOver reads,
/// the dump, the palette in both appearances, a Prometheus reading as a
/// chart's data, and the cursor the charts share. Pure.
@MainActor
final class KubePlotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_762_500_000)
    private let size = CGSize(width: 440, height: 120)

    private func points(_ values: [Double], step: TimeInterval = 30, from start: Date? = nil) -> [KubeSeriesPoint] {
        let start = start ?? t0
        return values.enumerated().map { KubeSeriesPoint(time: start.addingTimeInterval(Double($0.offset) * step), value: $0.element) }
    }

    private func data(_ series: [KubeChartSeries], unit: KubeChartUnit = .cores, span: TimeInterval = 3600, stacked: Bool = false) -> KubeChartData {
        KubeChartData(id: "pod.cpu", title: "CPU", unit: unit, series: series, start: t0, end: t0.addingTimeInterval(span), step: 30, stacked: stacked, version: 1)
    }

    /// The subpaths a path holds: one per run of a line.
    private func runs(_ path: CGPath) -> Int {
        var moves = 0
        path.applyWithBlock { element in if element.pointee.type == .moveToPoint { moves += 1 } }
        return moves
    }

    // MARK: Scales

    func testTheAxisIsRoundedToNiceValuesWithThreeToFiveTicks() {
        let cpu = KubePlot.niceScale(0.75, unit: .cores)
        XCTAssertEqual(cpu.top, 0.8, accuracy: 1e-9)
        XCTAssertEqual(cpu.ticks.count, 5)
        XCTAssertEqual(cpu.ticks.first, 0, "usage starts at 0")
        let memory = KubePlot.niceScale(96 * 1_048_576, unit: .bytes)
        XCTAssertEqual(memory.top, 100 * 1_048_576, "bytes in steps of a binary unit")
        XCTAssertEqual(memory.ticks.map { KubeVolumeFormat.bytes($0) }, ["0B", "25Mi", "50Mi", "75Mi", "100Mi"])
        XCTAssertEqual(KubePlot.niceScale(4, unit: .cores).top, 4, "a value on a tick is the top")
        XCTAssertEqual(KubePlot.niceScale(0, unit: .cores).top, KubeChartUnit.cores.emptyTop, accuracy: 1e-9, "every value zero")
        XCTAssertEqual(KubePlot.niceScale(.nan, unit: .bytes).top, KubeChartUnit.bytes.emptyTop)
        for value in stride(from: 0.013, to: 9000, by: 7.31) {
            let scale = KubePlot.niceScale(value, unit: .cores)
            XCTAssertGreaterThanOrEqual(scale.top, value * (1 - 1e-9), "\(value)")
            XCTAssertTrue((3...5).contains(scale.ticks.count), "\(value): \(scale.ticks)")
        }
    }

    func testTheTopIncludesEveryVisibleReferenceLine() {
        let chart = data([
            KubeChartSeries(id: "cpu", name: "CPU", points: points([0.1, 0.4, 0.2])),
            KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: t0, value: 3)]),
        ])
        XCTAssertGreaterThanOrEqual(KubePlot(chart, size: size).top, 3)
        XCTAssertEqual(KubePlot(chart, size: size, hideReferences: true).top, 0.4, accuracy: 1e-9, "Lines off: the usage's own")
        XCTAssertEqual(KubePlot(chart, size: size, hidden: ["limit"]).top, 0.4, accuracy: 1e-9)
    }

    func testTimeTicksFallOnWholeLocalMinutesAndHours() {
        let zone = TimeZone(secondsFromGMT: 3 * 3600)!
        let hour = KubePlot.timeTicks(start: t0, end: t0.addingTimeInterval(3600), width: 400, timeZone: zone)
        XCTAssertFalse(hour.isEmpty)
        XCTAssertLessThanOrEqual(hour.count, 6, "70 pt apart at least")
        let interval = hour[1].timeIntervalSince(hour[0])
        XCTAssertEqual(interval, 900, "a quarter of an hour fits five to 400 pt")
        for tick in hour {
            XCTAssertEqual((tick.timeIntervalSince1970 + 3 * 3600).truncatingRemainder(dividingBy: interval), 0, "on a whole local quarter")
        }
        let week = KubePlot.timeTicks(start: t0, end: t0.addingTimeInterval(7 * 86400), width: 600, timeZone: zone)
        for tick in week { XCTAssertEqual((tick.timeIntervalSince1970 + 3 * 3600).truncatingRemainder(dividingBy: 86400), 0, "a local midnight") }
        XCTAssertEqual(KubeChartTime.tick(week[0], interval: 86400, timeZone: zone).split(separator: " ").count, 2, "a day: `Nov 8`")
    }

    // MARK: Lines

    func testAGapIsDrawnAsAGap() {
        var values = points([0.2, 0.3, 0.4])
        values += points([0.5, 0.6], from: t0.addingTimeInterval(600))
        let plot = KubePlot(data([KubeChartSeries(id: "cpu", name: "CPU", points: values)]), size: size)
        XCTAssertEqual(runs(plot.lines[0].stroke.cgPath), 2, "broken where two points are more than two steps apart")
        XCTAssertNotNil(plot.lines[0].fill, "a lone usage series is filled")
    }

    func testDecimationKeepsEachColumnsLowestAndHighest() {
        var values = (0..<10_000).map { Double($0 % 7) / 10 }
        values[4321] = 9
        values[8765] = -1
        let many = points(values, step: 0.36)
        let decimated = KubePlot.decimate(many, columns: 400, start: t0.timeIntervalSince1970, span: 3600)
        XCTAssertLessThanOrEqual(decimated.count, 2 * 401)
        XCTAssertTrue(decimated.contains { $0.value == 9 }, "the peak survives")
        XCTAssertTrue(decimated.contains { $0.value == -1 }, "and the trough")
        XCTAssertEqual(decimated.map(\.time), decimated.map(\.time).sorted(), "in time order")
        XCTAssertEqual(KubePlot.decimate(points([1, 2, 3]), columns: 400, start: t0.timeIntervalSince1970, span: 3600).count, 3, "fewer points than columns: as they are")
        let plot = KubePlot(data([KubeChartSeries(id: "cpu", name: "CPU", points: many)]), size: size)
        XCTAssertLessThanOrEqual(plot.lines[0].points, 2 * Int(plot.frame.width) + 2)
        XCTAssertEqual(plot.tracks[0].values.count, 10_000, "hover reads every point")
    }

    func testStackedBandsAreCumulativeInLegendOrder() {
        let chart = data(
            [
                KubeChartSeries(id: "app", name: "app", points: points([1, 1, 1])),
                KubeChartSeries(id: "sidecar", name: "sidecar", points: points([2, 2, 2])),
            ], stacked: true)
        let plot = KubePlot(chart, size: size)
        XCTAssertEqual(plot.top, 3, accuracy: 1e-9, "the top is the bands' sum")
        XCTAssertEqual(plot.lines.map(\.id), ["app", "sidecar"])
        XCTAssertEqual(plot.lines[1].stroke.cgPath.boundingBox.minY, plot.y(of: 3), accuracy: 0.01, "sidecar's band on top of app's")
        XCTAssertNotNil(plot.lines[1].fill)
        XCTAssertEqual(plot.lines.map(\.colour), [0, 1])
        // A series hidden keeps its colour, and the others close up.
        let hidden = KubePlot(chart, size: size, hidden: ["app"])
        XCTAssertEqual(hidden.lines.map(\.colour), [1])
        XCTAssertEqual(hidden.top, 2, accuracy: 1e-9)
    }

    func testAReferenceIsSteppedAndLabelledAtItsRightEnd() {
        let capacity = [KubeSeriesPoint(time: t0, value: 10), KubeSeriesPoint(time: t0.addingTimeInterval(1800), value: 20)]
        let plot = KubePlot(
            data(
                [
                    KubeChartSeries(id: "used", name: "Used", points: points([2, 3])),
                    KubeChartSeries(id: "capacity", name: "capacity", role: .capacity, points: capacity),
                ], unit: .bytes), size: size)
        XCTAssertEqual(plot.references.count, 1)
        XCTAssertEqual(plot.references[0].labelAt.x, plot.frame.maxX)
        XCTAssertEqual(plot.references[0].labelAt.y, plot.y(of: 20), accuracy: 0.01)
        XCTAssertEqual(KubeChartRole.request.dash, [3, 3])
        XCTAssertEqual(KubeChartRole.limit.dash, [6, 2])
        XCTAssertEqual(KubeChartRole.allocatable.dash, [1, 2])
        XCTAssertEqual(KubeChartRole.quota.dash, [6, 2, 1, 2])
        XCTAssertEqual(
            Set(KubeChartRole.allCases.filter(\.isReference).map { KubeChartPalette.reference($0, dark: false) }).count, 6,
            "request, limit, quota, guide, forecast by colour; allocatable and capacity share grey, told apart by name")
    }

    func testTheCacheKeyIsTheVersionTheSizeAndWhatIsHidden() {
        let chart = data([KubeChartSeries(id: "cpu", name: "CPU", points: points([1]))])
        XCTAssertEqual(KubePlot(chart, size: size).key, KubePlot(chart, size: size).key)
        XCTAssertNotEqual(KubePlot(chart, size: size).key, KubePlot(chart, size: CGSize(width: 441, height: 120)).key)
        XCTAssertNotEqual(KubePlot(chart, size: size).key, KubePlot(chart, size: size, hidden: ["cpu"]).key)
        XCTAssertNotEqual(KubePlot(chart, size: size).key, KubePlot(chart, size: size, hideReferences: true).key)
        var changed = chart
        changed.version = 2
        XCTAssertNotEqual(KubePlot(chart, size: size).key, KubePlot(changed, size: size).key)
    }

    // MARK: Hover

    func testTheNearestPointIsFoundByBinarySearch() {
        let times: [Double] = [0, 10, 20, 30, 40]
        XCTAssertEqual(KubePlot.nearest(times, -5), 0)
        XCTAssertEqual(KubePlot.nearest(times, 14), 1)
        XCTAssertEqual(KubePlot.nearest(times, 16), 2)
        XCTAssertEqual(KubePlot.nearest(times, 15), 1, "halfway: the earlier")
        XCTAssertEqual(KubePlot.nearest(times, 99), 4)
        XCTAssertNil(KubePlot.nearest([], 3))
        let plot = KubePlot(data([KubeChartSeries(id: "cpu", name: "CPU", points: points([0.1, 0.2, 0.3], step: 1200))]), size: size)
        let x = plot.x(of: t0.addingTimeInterval(1300))
        XCTAssertEqual(plot.nearestTime(toX: x), t0.addingTimeInterval(1200), "snapped to the nearest point")
        XCTAssertEqual(plot.time(atX: plot.frame.minX - 50), t0, "clamped to the window")
    }

    func testTheTooltipSortsTheSeriesAndGivesEachReferenceItsShare() {
        let zone = TimeZone(secondsFromGMT: 3 * 3600)!
        let plot = KubePlot(
            data([
                KubeChartSeries(id: "app", name: "app", points: points([0.05, 0.1])),
                KubeChartSeries(id: "sidecar", name: "sidecar", points: points([0.3, 0.15])),
                KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: t0, value: 0.5)]),
            ]), size: size)
        let tip = KubeChartTooltip.at(t0.addingTimeInterval(30), plot: plot, step: 30, timeZone: zone)
        XCTAssertEqual(tip.time, KubeChartTime.full(t0.addingTimeInterval(30), timeZone: zone))
        XCTAssertTrue(tip.time.hasSuffix("GMT+3"), tip.time)
        XCTAssertEqual(tip.rows.map(\.name), ["sidecar", "app", "request"], "by value, then the lines")
        XCTAssertEqual(tip.rows.map(\.value), ["150m", "100m", "500m · 50%"])
        // In a gap a series says nothing rather than a guess.
        let gap = KubeChartTooltip.at(t0.addingTimeInterval(900), plot: plot, step: 30, timeZone: zone)
        XCTAssertEqual(gap.rows.map(\.name), ["request"])
    }

    func testTimesAreLocalWithTheZone() {
        let date = Date(timeIntervalSince1970: 1_762_525_935)  // 2025-11-07 14:32:15 UTC
        XCTAssertEqual(KubeChartTime.full(date, timeZone: TimeZone(secondsFromGMT: 0)!), "Nov 7, 14:32:15 GMT")
        XCTAssertEqual(KubeChartTime.full(date, timeZone: TimeZone(secondsFromGMT: 3 * 3600)!), "Nov 7, 17:32:15 GMT+3")
        XCTAssertEqual(KubeChartTime.zone(TimeZone(secondsFromGMT: 19800)!, at: date), "GMT+5:30")
        XCTAssertEqual(KubeChartTime.zone(TimeZone(secondsFromGMT: -4 * 3600)!, at: date), "GMT-4")
        XCTAssertEqual(KubeChartTime.tick(date, interval: 600, timeZone: TimeZone(secondsFromGMT: 0)!), "14:32")
        XCTAssertEqual(KubeChartTime.tick(Date(timeIntervalSince1970: 1_762_473_600), interval: 3600, timeZone: TimeZone(secondsFromGMT: 0)!), "Nov 7", "midnight names its day")
    }

    // MARK: Said

    func testTheSummaryAndTheDumpSayTheChart() {
        let zone = TimeZone(secondsFromGMT: 0)!
        let chart = data([
            KubeChartSeries(id: "cpu", name: "CPU", points: points([0.2, 0.48, 0.12])),
            KubeChartSeries(id: "request", name: "request", role: .request, points: [KubeSeriesPoint(time: t0, value: 0.25)]),
            KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: t0, value: 1)]),
        ])
        XCTAssertEqual(
            KubeChartSummary.of(chart, span: "last 1h", timeZone: zone),
            "CPU, last 1h: 120m now, peak 480m at \(KubeChartTime.clock(t0.addingTimeInterval(30), timeZone: zone)), request 250m, limit 1000m")
        let dump = KubeChartSummary.dump(chart, plot: KubePlot(chart, size: size))
        XCTAssertTrue(dump.hasPrefix("chart kubernetes.chart.pod.cpu series=1 points=3 drawn=3 ymax=1000m"), dump)
        XCTAssertTrue(dump.contains("refs=[request=250m limit=1000m]"), dump)
        XCTAssertTrue(KubeChartSummary.of(data([KubeChartSeries(id: "cpu", name: "CPU", points: [])]), span: "last 1h").contains("no samples"))
    }

    func testThePaletteReadsOnItsCardInBothAppearances() {
        let lightCards = [KubeChartPalette.RGB(0xFFFFFF), KubeChartPalette.RGB(0xF7F7F7), KubeChartPalette.RGB(0xEDEDED)]
        let darkCards = [KubeChartPalette.RGB(0x000000), KubeChartPalette.RGB(0x202124), KubeChartPalette.RGB(0x2B2B2E)]
        XCTAssertEqual(KubeChartPalette.light.count, 10)
        XCTAssertEqual(KubeChartPalette.dark.count, 10)
        XCTAssertEqual(Set(KubeChartPalette.light.map { "\($0)" }).count, 10, "ten distinct colours")
        for colour in KubeChartPalette.light { for card in lightCards { XCTAssertGreaterThanOrEqual(colour.contrast(card), 3, "\(colour) on \(card)") } }
        for colour in KubeChartPalette.dark { for card in darkCards { XCTAssertGreaterThanOrEqual(colour.contrast(card), 3, "\(colour) on \(card)") } }
        for role in KubeChartRole.allCases where role.isReference {
            for card in lightCards { XCTAssertGreaterThanOrEqual(KubeChartPalette.reference(role, dark: false).contrast(card), 3, "\(role)") }
            for card in darkCards { XCTAssertGreaterThanOrEqual(KubeChartPalette.reference(role, dark: true).contrast(card), 3, "\(role)") }
        }
    }

    func testTheAccessibilityDescriptorCarriesEverySeries() {
        let chart = data([
            KubeChartSeries(id: "cpu", name: "CPU", points: points([0.2, 0.4])),
            KubeChartSeries(id: "limit", name: "limit", role: .limit, points: [KubeSeriesPoint(time: t0, value: 1)]),
        ])
        let descriptor = KubeChartDescriptor.make(chart)
        XCTAssertEqual(descriptor.series.map(\.name), ["CPU", "limit"])
        XCTAssertEqual(descriptor.series[0].dataPoints.count, 2)
        XCTAssertEqual(descriptor.title, "CPU")
    }

    // MARK: A Prometheus reading as a chart

    func testAReadingBecomesAChartWithItsReferenceLines() {
        var reading = KubeChartReading(range: .hour)
        reading.read = t0.addingTimeInterval(3600)
        reading.series[.cpu] = points([0.5, 0.75])
        reading.totals = [.cpuRequests: 2, .cpuLimits: 3, .cpuAllocatable: 4]
        let cpu = KubeChartData.of(reading, chart: .cluster, measure: .cpu)
        XCTAssertEqual(cpu.identifier, "kubernetes.chart.cluster.cpu")
        XCTAssertEqual(cpu.references.map(\.role), [.request, .limit, .allocatable])
        XCTAssertEqual(cpu.references.map { $0.points.last?.value }, [2, 3, 4])
        XCTAssertEqual(cpu.end.timeIntervalSince(cpu.start), 3600, "the range's window")
        XCTAssertNotEqual(
            KubeChartData.of(reading, chart: .volume(namespace: "shop", claim: "a"), measure: .volumeUsed).identifier,
            KubeChartData.of(reading, chart: .volume(namespace: "shop", claim: "b"), measure: .volumeUsed).identifier, "two claims, two charts")
        var again = reading
        again.read = reading.read?.addingTimeInterval(60)
        XCTAssertNotEqual(KubeChartData.of(again, chart: .cluster, measure: .cpu).version, cpu.version, "read again, drawn again")
        XCTAssertEqual(KubeChartData.of(reading, chart: .cluster, measure: .cpu).version, cpu.version)

        var volume = KubeChartReading(range: .hour)
        volume.read = reading.read
        volume.series[.volumeUsed] = points([1_073_741_824])
        volume.series[.volumeCapacity] = points([10_737_418_240])
        let used = KubeChartData.of(volume, chart: .volume(namespace: "shop", claim: "data"), measure: .volumeUsed)
        XCTAssertEqual(used.unit, .bytes)
        XCTAssertEqual(used.references.map(\.role), [.capacity])
        XCTAssertEqual(used.identifier, "kubernetes.chart.volume.shop.data.used")
    }

    func testOnlyUsageIsDrawnAsSeries() {
        XCTAssertEqual(KubeChartRole.allCases.filter { !$0.isReference }, [.usage, .peak], "every other role is a reference line; a peak band is neither")
        let data = KubeChartData(
            id: "t", title: "CPU", unit: .cores,
            series: [
                KubeChartSeries(id: "cpu", name: "CPU", points: []), KubeChartSeries(id: "peak", name: "peak", role: .peak, points: []),
                KubeChartSeries(id: "limit", name: "limit", role: .limit, points: []),
            ], start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 60), step: 30)
        XCTAssertEqual(data.usage.map(\.id), ["cpu"], "a peak isn't usage: never stacked or summed")
        XCTAssertEqual(data.peaks.map(\.id), ["peak"])
        XCTAssertEqual(data.references.map(\.id), ["limit"])
    }

    // MARK: The charts on screen

    func testEachChartViewIsItsOwnEntryInItsOwnWindow() {
        let registry = KubeChartRegistry()
        // Kept alive, so their identifiers stay theirs.
        let windows = (NSObject(), NSObject())
        let one = ObjectIdentifier(windows.0), other = ObjectIdentifier(windows.1)
        let cursor = KubeChartCursor()
        let cpu = data([KubeChartSeries(id: "cpu", name: "CPU", points: points([0.2]))])
        let first = UUID(), second = UUID()
        registry.show(cpu, plot: nil, token: first, window: one, cursor: cursor)
        registry.show(cpu, plot: nil, token: second, window: other, cursor: KubeChartCursor())
        XCTAssertEqual(registry.lines(in: one).count, 1, "a window's dump has its own charts")
        XCTAssertEqual(registry.lines().count, 2)
        XCTAssertTrue(registry.chart(cpu.identifier, in: one)?.cursor === cursor)
        registry.hide(first)
        XCTAssertNil(registry.chart(cpu.identifier, in: one))
        XCTAssertNotNil(registry.chart(cpu.identifier, in: other), "one window's chart going leaves the other's")
        // A detail switch: the new view shown before the old one goes.
        let next = UUID()
        registry.show(cpu, plot: nil, token: next, window: other, cursor: KubeChartCursor())
        registry.hide(second)
        XCTAssertNotNil(registry.chart(cpu.identifier, in: other), "the old view's going leaves the new one's")
    }

    func testTheDrawCounterKeepsWindowsApart() {
        let draws = KubeChartDraws()
        // Kept alive, so their identifiers stay theirs.
        let windows = (NSObject(), NSObject())
        let one = ObjectIdentifier(windows.0), other = ObjectIdentifier(windows.1)
        draws.drew("c", window: one, overlay: false)
        draws.drew("c", window: other, overlay: true, tooltip: true)
        draws.composed("holder", window: one)
        XCTAssertEqual(draws.of("c", in: one), KubeChartDraws.Counts(series: 1))
        XCTAssertEqual(draws.of("c", in: other), KubeChartDraws.Counts(overlay: 1, tooltip: 1))
        XCTAssertEqual(draws.of("c"), KubeChartDraws.Counts(series: 1, overlay: 1, tooltip: 1), "every window's, added up")
        XCTAssertEqual(draws.of("holder", in: one).container, 1)
    }

    // MARK: The cursor

    func testTheCursorIsSharedAndOnlyItsOwnerLeavesIt() {
        let cursor = KubeChartCursor()
        var published = 0
        let watching = cursor.objectWillChange.sink { published += 1 }
        defer { watching.cancel() }
        cursor.move(to: t0, owner: "a")
        cursor.move(to: t0, owner: "a")
        XCTAssertEqual(published, 1, "the same place publishes nothing")
        cursor.leave("b")
        XCTAssertEqual(cursor.hover?.owner, "a", "another chart's leaving doesn't clear it")
        cursor.move(to: t0, owner: "b")
        XCTAssertEqual(cursor.hover?.owner, "b")
        cursor.leave("b")
        XCTAssertNil(cursor.hover)
    }
}
