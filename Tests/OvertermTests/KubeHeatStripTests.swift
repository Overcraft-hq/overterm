import Foundation
import XCTest

@testable import Overterm

/// The Nodes list's heat strips (docs/design/kubernetes/metrics.md, 2.1,
/// stage M3c): 60 cells of 15 s against allocatable, from the ring's
/// samples of the node; a gap is empty, never zero. Pure.
final class KubeHeatStripTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_699_999_980)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func point(_ seconds: Double, cpu: Double, memory: Double = 0) -> KubeUsagePoint {
        KubeUsagePoint(time: at(seconds), usage: KubeUsage(cpu: cpu, memory: memory))
    }

    func testSixtyCellsEndingAtTheNewestSampleAgainstAllocatable() throws {
        // Fifteen minutes at 15 s, 0.04 cores more each time, of 4 cores.
        let points = (0..<60).map { point(Double($0) * 15, cpu: Double($0 + 1) * 0.04) }
        let strip = try XCTUnwrap(KubeHeatStrip.of([points], .cpu, allocatable: 4))
        XCTAssertEqual(strip.percents.count, KubeHeatStrip.cellCount)
        XCTAssertEqual(strip.filled, 60)
        XCTAssertEqual(strip.end, at(59 * 15), "the last cell ends at the newest sample")
        XCTAssertEqual(try XCTUnwrap(strip.now), 60, accuracy: 0.001, "2.4 of 4 cores")
        XCTAssertEqual(try XCTUnwrap(strip.percents.first ?? nil), 1, accuracy: 0.001)
        XCTAssertEqual(strip.peak?.percent ?? 0, 60, accuracy: 0.001)
    }

    func testMemoryIsItsOwnShare() throws {
        let strip = try XCTUnwrap(KubeHeatStrip.of([[point(0, cpu: 1, memory: 8 * 1_073_741_824)]], .memory, allocatable: 16 * 1_073_741_824))
        XCTAssertEqual(try XCTUnwrap(strip.now), 50, accuracy: 0.001)
        XCTAssertEqual(strip.filled, 1)
    }

    func testASixtySecondResolutionFillsTheCellsBetweenItsSamples() throws {
        let points = (0..<5).map { point(Double($0) * 60, cpu: 1) }
        let strip = try XCTUnwrap(KubeHeatStrip.of([points], .cpu, allocatable: 4))
        XCTAssertEqual(strip.filled, 17, "the first sample's own cell, then four for each after it")
        XCTAssertEqual(strip.percents.suffix(17).compactMap { $0 }.count, 17)
    }

    func testABreakIsEmptyCellsNeverZero() throws {
        let before = (0..<10).map { point(Double($0) * 15, cpu: 2) }
        let after = (30..<40).map { point(Double($0) * 15, cpu: 1) }
        let strip = try XCTUnwrap(KubeHeatStrip.of([before, after], .cpu, allocatable: 4))
        XCTAssertEqual(strip.filled, 20, "the hidden stretch between the runs isn't drawn")
        let gap = strip.percents[(60 - 30)..<(60 - 10)]
        XCTAssertTrue(gap.allSatisfy { $0 == nil }, "\(gap)")
        XCTAssertFalse(strip.percents.contains(0))
    }

    func testOlderThanFifteenMinutesIsLeftOut() throws {
        let points = (0..<100).map { point(Double($0) * 15, cpu: Double($0)) }
        let strip = try XCTUnwrap(KubeHeatStrip.of([points], .cpu, allocatable: 100))
        XCTAssertEqual(strip.filled, 60)
        XCTAssertEqual(try XCTUnwrap(strip.percents.first ?? nil), 40, accuracy: 0.001)
    }

    func testACellTakesItsLargestSample() throws {
        let strip = try XCTUnwrap(KubeHeatStrip.of([[point(0, cpu: 1), point(4, cpu: 3), point(9, cpu: 2)]], .cpu, allocatable: 4))
        XCTAssertEqual(strip.filled, 1)
        XCTAssertEqual(try XCTUnwrap(strip.now), 75, accuracy: 0.001)
    }

    func testNoAllocatableOrNoSampleIsNoStrip() {
        XCTAssertNil(KubeHeatStrip.of([[point(0, cpu: 1)]], .cpu, allocatable: nil))
        XCTAssertNil(KubeHeatStrip.of([[point(0, cpu: 1)]], .cpu, allocatable: 0))
        XCTAssertNil(KubeHeatStrip.of([], .cpu, allocatable: 4))
        XCTAssertNil(KubeHeatStrip.of([[]], .cpu, allocatable: 4))
    }

    func testLevels() {
        XCTAssertEqual(KubeHeatStrip.Level(0), .low)
        XCTAssertEqual(KubeHeatStrip.Level(49.9), .low)
        XCTAssertEqual(KubeHeatStrip.Level(50), .mid)
        XCTAssertEqual(KubeHeatStrip.Level(80), .high)
        XCTAssertEqual(KubeHeatStrip.Level(100), .over)
        XCTAssertEqual(KubeHeatStrip.Level(143), .over, "CPU can be past allocatable")
    }

    func testTheSummaryAndTheDump() throws {
        let zone = TimeZone(identifier: "Europe/Istanbul")!
        let strip = try XCTUnwrap(KubeHeatStrip.of([[point(0, cpu: 3.6), point(15, cpu: 0.88)]], .cpu, allocatable: 4))
        XCTAssertEqual(
            strip.summary(timeZone: zone),
            "CPU as a share of allocatable, the last 15 min in 15 s cells: 22% now, peak 90% at \(KubeChartTime.clock(strip.start(of: 58), timeZone: zone)) (58 of 60 cells not sampled) — sampled while shown"
        )
        XCTAssertEqual(strip.dump, "cpu filled=2/60 low=1 mid=0 high=1 over=0 peak=90%")
    }

    func testTheColoursReadOnTheCardInBothAppearances() {
        let lightCards = [KubeChartPalette.RGB(0xFFFFFF), KubeChartPalette.RGB(0xF7F7F7), KubeChartPalette.RGB(0xEDEDED)]
        let darkCards = [KubeChartPalette.RGB(0x000000), KubeChartPalette.RGB(0x202124), KubeChartPalette.RGB(0x2B2B2E)]
        for level in KubeHeatStrip.Level.allCases {
            for card in lightCards { XCTAssertGreaterThanOrEqual(KubeChartPalette.heat(level, dark: false).contrast(card), 3, "\(level)") }
            for card in darkCards { XCTAssertGreaterThanOrEqual(KubeChartPalette.heat(level, dark: true).contrast(card), 3, "\(level)") }
        }
        XCTAssertEqual(Set(KubeHeatStrip.Level.allCases.map { "\(KubeChartPalette.heat($0, dark: false))" }).count, 4)
        XCTAssertEqual(Set(KubeHeatStrip.Level.allCases.map { "\(KubeChartPalette.heat($0, dark: true))" }).count, 4)
    }

    func testANodesRowKeepsTheWholeFifteenMinutesAPodsRowAndTheClustersForty() {
        var ring = KubeUsageRing()
        let node = KubeUsageKey.node("fake-node-1")
        let pod = KubeUsageKey.pod(namespace: "shop", name: "web-1")
        for poll in 0..<100 {
            ring.record(node, KubeUsage(cpu: 1, memory: 1), at: at(Double(poll) * 15), .list, now: at(1_500))
            ring.record(pod, KubeUsage(cpu: 1, memory: 1), at: at(Double(poll) * 15), .list, now: at(1_500))
        }
        XCTAssertEqual(ring.points(node, now: at(1_500)).count, KubeUsageRing.rawPoints, "the strip's 60 cells")
        XCTAssertEqual(ring.points(pod, now: at(1_500)).count, KubeUsageRing.listPoints, "as before")
        var cluster = KubeUsageRing()
        for poll in 0..<100 { cluster.recordSum(.cluster, ["n": (at(Double(poll) * 15), KubeUsage(cpu: 1, memory: 1))], .list, now: at(1_500)) }
        XCTAssertEqual(
            cluster.points(.cluster, now: at(1_500)).count, KubeUsageRing.listPoints, "the Overview's sparkline: its 10 minutes, as before")
        var detail = KubeUsageRing()
        for poll in 0..<100 { detail.record(node, KubeUsage(cpu: 1, memory: 1), at: at(Double(poll) * 15), .detail, now: at(1_500)) }
        XCTAssertEqual(detail.points(node, .detail, now: at(1_500)).count, KubeUsageRing.rawPoints, "a detail's raw tier: 15 minutes")
    }

    func testARowReadsItsOwnSamplesItsTabItsOwn() {
        var ring = KubeUsageRing()
        let node = KubeUsageKey.node("fake-node-1")
        // The node's tab, open for a minute half an hour ago.
        for poll in 0..<4 { ring.record(node, KubeUsage(cpu: 3, memory: 1), at: at(Double(poll) * 15), .detail, now: at(Double(poll) * 15)) }
        // Its row, sampled since.
        for poll in 120..<124 { ring.record(node, KubeUsage(cpu: 1, memory: 1), at: at(Double(poll) * 15), .list, now: at(Double(poll) * 15)) }
        XCTAssertEqual(ring.points(node, .list, now: at(124 * 15)).map(\.usage.cpu), [1, 1, 1, 1], "the row's strip: never the tab's old samples")
        XCTAssertEqual(ring.points(node, .detail, now: at(124 * 15)).map(\.usage.cpu), [3, 3, 3, 3], "the tab's, kept for the hour")
        XCTAssertEqual(ring.points(node, now: at(124 * 15)).map(\.usage.cpu), [3, 3, 3, 3], "unnamed, the detail's while kept, as before")
        XCTAssertTrue(ring.points(node, .detail, now: at(124 * 15 + 3_700)).isEmpty, "past the hour, the tab's are gone")
    }

    /// A node's usage column holds its strip and its value with its share
    /// at its least width; a pod's its value, as before.
    @MainActor
    func testANodesUsageColumnIsNeverNarrowerThanItsStripAndValue() {
        for measure in [KubeUsageCell.Measure.cpu, .memory] {
            let value = measure == .cpu ? "12000m (100%)" : "65536Mi (100%)"
            let node = KubernetesPageModel.usageMinWidth(measure, node: true)
            XCTAssertGreaterThanOrEqual(node, KubernetesPageModel.usageContentWidth(value, strip: true) + 12, "\(measure)")
            XCTAssertGreaterThan(node, KubeHeatStripView.width + 6 + KubernetesPageModel.usageMinWidth(measure) - 12, "the strip counted")
        }
        XCTAssertEqual(KubernetesPageModel.usageMinWidth(.cpu), 64)
        XCTAssertEqual(KubernetesPageModel.usageMinWidth(.memory), 72)
        let nodes = KubernetesPageModel.metricsColumns(.nodes)
        XCTAssertTrue(nodes.allSatisfy { $0.width >= $0.minWidth }, "\(nodes.map { ($0.width, $0.minWidth) })")
    }
}
