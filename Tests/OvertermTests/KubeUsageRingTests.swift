import Foundation
import XCTest

@testable import Overterm

/// The samples taken while shown (docs/design/kubernetes/metrics.md, 4.1):
/// keyed by metrics-server's stamp, gaps kept as breaks, folded into
/// minutes, the two populations, an hour for a detail's, the 6 MB cap.
/// Pure.
final class KubeUsageRingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_699_999_980)  // on a minute
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func usage(_ cpu: Double, _ memory: Double = 1) -> KubeUsage { KubeUsage(cpu: cpu, memory: memory) }
    private let web = KubeUsageKey.pod(namespace: "shop", name: "web-1")

    func testASampleWhoseStampDidNotMoveIsDropped() {
        var ring = KubeUsageRing()
        XCTAssertTrue(ring.record(web, usage(1), at: at(0), .detail, now: at(1)))
        XCTAssertFalse(ring.record(web, usage(2), at: at(0), .detail, now: at(2)), "polled again, the same sample")
        XCTAssertFalse(ring.record(web, usage(3), at: at(-15), .detail, now: at(3)), "an older one")
        XCTAssertTrue(ring.record(web, usage(4), at: at(15), .detail, now: at(16)))
        XCTAssertEqual(ring.points(web, now: at(16)).map(\.usage.cpu), [1, 4])
        XCTAssertEqual(ring.points(web, now: at(16)).map(\.time), [at(0), at(15)], "keyed by metrics-server's stamp, not the arrival")
    }

    func testAStretchPastTwoAndAHalfIntervalsIsABreak() {
        var ring = KubeUsageRing(interval: 15)
        for (time, cpu) in [(0.0, 1.0), (15, 2), (30, 3), (67, 4), (110, 5)] { ring.record(web, usage(cpu), at: at(time), .detail, now: at(time)) }
        let segments = ring.segments(web, now: at(110))
        XCTAssertEqual(segments.map { $0.map(\.usage.cpu) }, [[1, 2, 3, 4], [5]], "37 s is no gap; 43 s is: drawn as one, not a line")
        XCTAssertEqual(ring.points(web, now: at(110)).count, 5, "a sparkline's points leave the break out")
    }

    func testSamplesFoldIntoMinutesOfMinMeanAndMax() {
        var ring = KubeUsageRing()
        for (index, cpu) in [1.0, 2, 3, 6].enumerated() { ring.record(web, usage(cpu, cpu * 10), at: at(Double(index) * 15), .detail, now: at(0)) }
        ring.record(web, usage(8), at: at(60), .detail, now: at(60))
        let folded = ring.folded(web, now: at(60))
        XCTAssertEqual(folded.count, 2)
        XCTAssertEqual(folded[0].start, at(0), "a minute's bucket")
        XCTAssertEqual(folded[0].count, 4)
        XCTAssertEqual(folded[0].min, usage(1, 10))
        XCTAssertEqual(folded[0].avg.cpu, 3, accuracy: 0.0001)
        XCTAssertEqual(folded[0].avg.memory, 30, accuracy: 0.001)
        XCTAssertEqual(folded[0].max, usage(6, 60))
        XCTAssertEqual(folded[1].min, usage(8))

        var list = KubeUsageRing()
        list.record(web, usage(1), at: at(0), .list, now: at(0))
        XCTAssertEqual(list.folded(web, now: at(0)), [], "a list's rows keep the raw tier only")
        XCTAssertEqual(list.points(web, now: at(0)).count, 1)
    }

    func testTheRawTierKeepsFifteenMinutesAndTheFoldedSixHours() {
        var ring = KubeUsageRing()
        // Seven hours at 15 s.
        for index in 0..<(7 * 240) { ring.record(web, usage(Double(index)), at: at(Double(index) * 15), .detail, now: at(Double(index) * 15)) }
        let now = at(Double(7 * 240 - 1) * 15)
        let raw = ring.points(web, now: now)
        XCTAssertEqual(raw.count, KubeUsageRing.rawPoints, "15 minutes at 15 s is 60")
        XCTAssertGreaterThanOrEqual(raw.first!.time, now.addingTimeInterval(-15 * 60))
        let folded = ring.folded(web, now: now)
        XCTAssertLessThanOrEqual(folded.count, KubeUsageRing.foldedBuckets)
        XCTAssertGreaterThanOrEqual(folded.first!.start, now.addingTimeInterval(-6 * 3600 - 60), "six hours")
        XCTAssertEqual(folded.last!.max.cpu, Double(7 * 240 - 1))

        var list = KubeUsageRing()
        for index in 0..<100 { list.record(web, usage(Double(index)), at: at(Double(index) * 15), .list, now: at(0)) }
        XCTAssertEqual(list.points(web, now: at(0)).count, KubeUsageRing.listPoints, "a list's row: the last 40, as before")
        XCTAssertEqual(list.points(web, now: at(0)).last?.usage.cpu, 99)
    }

    func testAListsRowsNeverEvictADetailsKey() {
        var ring = KubeUsageRing()
        ring.record(web, usage(1), at: at(0), .detail, now: at(0))
        for poll in 0..<3 {
            for pod in 0..<5_000 {
                ring.record(.pod(namespace: "shop", name: "p-\(pod)"), usage(1), at: at(Double(poll) * 15), .list, now: at(Double(poll) * 15))
            }
            ring.enforceCap()
        }
        XCTAssertEqual(ring.listKeys, 5_000)
        XCTAssertTrue(ring.holds(web, .detail), "5,000 rows don't push out the pod being looked at")
    }

    func testDetailKeysAreBoundedLeastRecentlyFedFirst() {
        var ring = KubeUsageRing()
        for index in 0..<KubeUsageRing.detailKeys {
            ring.record(.pod(namespace: "shop", name: "p-\(index)"), usage(1), at: at(0), .detail, now: at(Double(index)))
        }
        // p-0 fed again: p-1 is now the least recently fed.
        ring.record(.pod(namespace: "shop", name: "p-0"), usage(1), at: at(15), .detail, now: at(500))
        ring.record(.pod(namespace: "shop", name: "new"), usage(1), at: at(15), .detail, now: at(501))
        XCTAssertEqual(ring.detailKeyCount, KubeUsageRing.detailKeys)
        XCTAssertTrue(ring.holds(.pod(namespace: "shop", name: "p-0"), .detail))
        XCTAssertFalse(ring.holds(.pod(namespace: "shop", name: "p-1"), .detail), "the least recently fed goes")
        XCTAssertTrue(ring.holds(.pod(namespace: "shop", name: "new"), .detail))
    }

    func testADetailsSamplesAreForgottenAnHourAfterItWasLastFed() {
        var ring = KubeUsageRing()
        ring.record(web, usage(1), at: at(0), .detail, now: at(0))
        ring.record(web, usage(2), at: at(15), .detail, now: at(15))
        XCTAssertEqual(ring.points(web, now: at(15 + 59 * 60)).count, 2, "back within the hour: what was sampled before")
        XCTAssertEqual(ring.folded(web, now: at(15 + 59 * 60)).count, 1)
        XCTAssertEqual(ring.points(web, now: at(15 + 61 * 60)), [], "an hour after: gone, even unpruned")
        XCTAssertEqual(ring.folded(web, now: at(15 + 61 * 60)), [])
        ring.prune(now: at(15 + 61 * 60))
        XCTAssertFalse(ring.holds(web, .detail))

        // Fed again after a while away: the time away is a gap.
        var back = KubeUsageRing()
        back.record(web, usage(1), at: at(0), .detail, now: at(0))
        back.record(web, usage(2), at: at(10 * 60), .detail, now: at(10 * 60))
        XCTAssertEqual(back.segments(web, now: at(10 * 60)).count, 2)
    }

    func testAListsRowNoLongerSampledIsForgotten() {
        var ring = KubeUsageRing()
        let gone = KubeRowID(namespace: "shop", name: "gone-1")
        let id = KubeRowID(namespace: "shop", name: "web-1")
        func pod(_ id: KubeRowID, _ time: Double) -> KubePodMetrics {
            KubePodMetrics(id: id, timestamp: at(time), window: "15s", containers: ["app": usage(1)])
        }
        let target = KubeMetricsTarget.pods(.namespace("shop"), labels: nil)
        ring.record(KubeMetricsSample(pods: [pod(id, 0), pod(gone, 0)], read: at(1)), for: target, asList: true, asDetail: false, sums: [], now: at(1))
        XCTAssertTrue(ring.holds(.pod(gone), .list))
        ring.record(KubeMetricsSample(pods: [pod(id, 15)], read: at(16)), for: target, asList: true, asDetail: false, sums: [], now: at(16))
        XCTAssertFalse(ring.holds(.pod(gone), .list), "a pod no longer sampled is forgotten")
        XCTAssertEqual(ring.points(.pod(id), now: at(16)).count, 2)
        XCTAssertEqual(ring.points(.cluster, now: at(16)), [], "pods add nothing to the cluster's")

        let nodes = KubeMetricsSample(
            nodes: [
                KubeNodeMetrics(name: "fake-node-1", timestamp: at(0), window: nil, usage: usage(1, 2)),
                KubeNodeMetrics(name: "fake-node-2", timestamp: at(2), window: nil, usage: usage(0.5, 1)),
            ], allocatable: [:], read: at(3))
        ring.record(nodes, for: .nodes, asList: true, asDetail: false, sums: [], now: at(3))
        XCTAssertEqual(ring.points(.cluster, now: at(3)).map(\.usage), [usage(1.5, 3)], "every node's, added up")
        XCTAssertEqual(ring.points(.cluster, now: at(3)).map(\.time), [at(2)], "stamped with the newest")
        XCTAssertEqual(ring.points(.node("fake-node-2"), now: at(3)).map(\.usage), [usage(0.5, 1)])
        ring.forgetListed { key in
            switch key {
            case .node, .cluster: true
            default: false
            }
        }
        XCTAssertEqual(ring.points(.cluster, now: at(3)), [], "the list hidden: gone")
        XCTAssertEqual(ring.points(.pod(id), now: at(3)).count, 2, "the pods' list still read")
    }

    func testSumsAcrossPodsWithDifferentStampsAndAPodMissingFromAPoll() {
        var ring = KubeUsageRing()
        let key = KubeUsageKey.workload(namespace: "shop", kind: "Deployment", name: "web")
        func poll(_ members: [String: (Double, Double)], now: Double) -> Bool {
            ring.recordSum(key, members.mapValues { (time: at($0.0), usage: usage($0.1)) }, .detail, now: at(now))
        }
        XCTAssertTrue(poll(["web-a": (0, 1), "web-b": (7, 2)], now: 10))
        XCTAssertFalse(poll(["web-a": (0, 1), "web-b": (7, 2)], now: 11), "no pod's stamp moved: nothing new")
        XCTAssertTrue(poll(["web-a": (15, 3), "web-b": (7, 2)], now: 16), "one moved")
        XCTAssertTrue(poll(["web-a": (30, 4)], now: 31), "web-b missing: its part ends")
        let points = ring.points(key, now: at(31))
        XCTAssertEqual(points.map(\.usage.cpu), [3, 5, 4], "summed per poll; a missing pod isn't carried forward")
        XCTAssertEqual(points.map(\.time), [at(7), at(15), at(30)], "each stamped with the newest stamp in it")
        XCTAssertTrue(poll(["web-a": (30, 4), "web-c": (20, 1)], now: 32), "a pod joining with an older stamp still moves the sum")
        XCTAssertEqual(ring.points(key, now: at(32)).last?.usage.cpu, 5)
        XCTAssertEqual(ring.points(key, now: at(32)).last?.time, at(31))
        XCTAssertEqual(ring.folded(key, now: at(32)).isEmpty, false, "a detail's sum has both tiers")
    }

    /// What malloc holds now, every zone's.
    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// The ring the cap test fills: 200 detail keys full, the list's 5,000
    /// rows at 40 points and a namespace's sum across them.
    private func fullRing() -> (ring: KubeUsageRing, detailBytes: Int) {
        var ring = KubeUsageRing()
        // 200 detail keys, full: 60 raw points and 360 minutes each.
        for index in 0..<KubeUsageRing.detailKeys {
            let key = KubeUsageKey.pod(namespace: "shop", name: "detail-\(index)")
            for minute in 0..<360 {
                for sample in [0.0, 15, 30, 45] {
                    let time = Double(minute) * 60 + sample
                    ring.record(key, usage(1), at: at(time), .detail, now: at(21_600))
                }
            }
        }
        let detailBytes = ring.bytes
        // The list's 5,000 rows at 40 points (names past a String's inline
        // 15 bytes), and a namespace's sum across them — its members' names too.
        let names = (0..<5_000).map { String(format: "checkout-api-%05d", $0) }
        for poll in 0..<45 {
            var members: [String: (time: Date, usage: KubeUsage)] = [:]
            for name in names {
                ring.record(.pod(namespace: "acme-shop", name: name), usage(1), at: at(Double(poll) * 15), .list, now: at(21_600))
                members["acme-shop/\(name)"] = (at(Double(poll) * 15), usage(1))
            }
            ring.recordSum(.namespace("acme-shop"), members, .detail, now: at(21_600))
        }
        ring.enforceCap()
        return (ring, detailBytes)
    }

    func testTheWholeRingStaysUnderSixMegabytes() {
        // malloc's count is the whole process's: whatever another test left
        // running allocates into it too. The ring is built the same each time,
        // so the least of three reads is the ring's own.
        var held = Int.max
        var built: (ring: KubeUsageRing, detailBytes: Int)?
        for _ in 0..<3 {
            built = nil
            let before = Self.heapInUse()
            let attempt = fullRing()
            held = min(held, Self.heapInUse() - before)
            built = attempt
        }
        guard var ring = built?.ring, let detailBytes = built?.detailBytes else { return XCTFail("never built") }
        XCTAssertLessThan(detailBytes, Int(2.6 * 1_048_576), "about 2.5 MB: \(detailBytes)")
        XCTAssertLessThanOrEqual(ring.bytes, KubeUsageRing.defaultByteCap, "\(ring.bytes)")
        // What it says it takes is what it takes: malloc's own count, within a tenth.
        XCTAssertGreaterThanOrEqual(Double(ring.bytes), Double(held) * 0.9, "says \(ring.bytes), holds \(held)")
        XCTAssertLessThanOrEqual(held, Int(Double(KubeUsageRing.defaultByteCap) * 1.1), "the cap holds for what malloc holds: \(held)")
        XCTAssertEqual(ring.detailKeyCount, KubeUsageRing.detailKeys, "the details' keys kept, the sum among them")
        XCTAssertTrue(ring.holds(.namespace("acme-shop"), .detail))
        XCTAssertGreaterThan(ring.listKeys, 0)

        // Past the cap: list rows given up first, every detail key kept.
        let rows = ring.listKeys
        ring.byteCap = ring.bytes - (ring.bytes - detailBytes) / 2
        ring.enforceCap()
        XCTAssertLessThanOrEqual(ring.bytes, ring.byteCap)
        XCTAssertEqual(ring.detailKeyCount, KubeUsageRing.detailKeys, "the details' keys kept")
        XCTAssertLessThan(ring.listKeys, rows)
        XCTAssertGreaterThan(ring.listKeys, 0)
        // A row given up comes back at the next poll with one point: it goes
        // again, not a row holding its history.
        let kept = ring.listKeys
        ring.byteCap = ring.bytes
        ring.record(.pod(namespace: "acme-shop", name: "checkout-api-new"), usage(1), at: at(45 * 15), .list, now: at(21_600))
        ring.enforceCap()
        XCTAssertFalse(ring.holds(.pod(namespace: "acme-shop", name: "checkout-api-new"), .list), "the shortest row goes first")
        XCTAssertEqual(ring.listKeys, kept)
        ring.byteCap = detailBytes / 2
        ring.enforceCap()
        XCTAssertEqual(ring.listKeys, 0)
        XCTAssertLessThanOrEqual(ring.bytes, ring.byteCap, "then the least recently fed details")
    }

    func testAListRowsPointsStayInTheirCapacity() {
        // Appended past forty and trimmed: never grown to the next power of two.
        var ring = KubeUsageRing()
        let key = KubeUsageKey.pod(namespace: "shop", name: "web-1")
        for poll in 0..<200 { ring.record(key, usage(1), at: at(Double(poll) * 15), .list, now: at(3_000)) }
        let one = ring.bytes
        XCTAssertLessThan(one, 1_000, "one row: \(one) bytes")
        XCTAssertEqual(ring.points(key, now: at(3_000)).count, KubeUsageRing.listPoints)
    }

    func testAPodsOwnSampleFeedsThePodAndEachContainer() {
        var ring = KubeUsageRing()
        let pod = KubePodMetrics(
            id: KubeRowID(namespace: "shop", name: "web-1"), timestamp: at(0), window: "15s", containers: ["app": usage(0.25, 64), "sidecar": usage(0.01, 8)])
        let target = KubeMetricsTarget.pod(namespace: "shop", name: "web-1")
        ring.record(KubeMetricsSample(pods: [pod], read: at(1)), for: target, asList: false, asDetail: true, sums: [], now: at(1))
        XCTAssertEqual(ring.points(web, now: at(1)).map(\.usage.cpu).map { ($0 * 100).rounded() }, [26])
        XCTAssertTrue(ring.holds(web, .detail))
        XCTAssertFalse(ring.holds(web, .list))
        XCTAssertEqual(ring.points(.container(namespace: "shop", pod: "web-1", container: "sidecar"), now: at(1)).map(\.usage.memory), [8])
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
    }

    func testTheSpanSaysOverHowLong() {
        let points = (0..<40).map { KubeUsagePoint(time: at(Double($0) * 15), usage: usage(1)) }
        XCTAssertEqual(KubeUsageRing.span(points), "the last 9m45s, sampled while shown")
        XCTAssertNil(KubeUsageRing.span(Array(points.prefix(1))), "one sample is no line")
    }
}
