import Foundation
import XCTest

@testable import Overterm

/// The meters' arithmetic (docs/design/activity/analysis.md, 3.8, 6.4): CPU
/// a core between two reads — none for a first one, the counters' wrap at
/// 2³² taken —, memory in Activity Monitor's terms, the pressure and thermal
/// words; and the full tick carrying them, the light one not.
final class SystemMetersTests: XCTestCase {
    private func counters(
        cores: [[UInt32]], anonymous: UInt64 = 1_000, purgeable: UInt64 = 100, external: UInt64 = 500, wired: UInt64 = 300,
        compressed: UInt64 = 200, pressure: Int32? = 1, thermal: Int = 0
    ) -> SystemMeterCounters {
        SystemMeterCounters(
            cores: cores, performanceCores: 8, efficiencyCores: 2, memory: 64 << 30, pageSize: 16_384, wired: wired, compressed: compressed,
            internalPages: anonymous, externalPages: external, purgeable: purgeable, free: 10, pressureLevel: pressure, swapUsed: 0,
            swapTotal: 1 << 30, load: [4.1, 3.2, 2.5], uptime: 3_600, thermal: thermal, lowPower: false)
    }

    func testAFirstReadHasNoCPUNeverZero() {
        let meters = SystemMeters.from(counters(cores: [[10, 10, 80, 0]]), previous: nil)
        XCTAssertTrue(meters.cores.isEmpty)
        XCTAssertNil(meters.cpu)
    }

    func testEachCoresBusyShareSinceTheLastRead() {
        let first = counters(cores: [[100, 50, 850, 0], [0, 0, 1_000, 0]])
        let second = counters(cores: [[150, 100, 950, 0], [10, 0, 1_090, 0]])
        let meters = SystemMeters.from(second, previous: first)
        XCTAssertEqual(meters.cores.count, 2)
        XCTAssertEqual(meters.cores[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(meters.cores[1], 0.1, accuracy: 1e-9)
        XCTAssertEqual(meters.cpu ?? -1, 0.3, accuracy: 1e-9)
    }

    func testTheCountersWrapAtTwoToTheThirtyTwo() {
        let first = counters(cores: [[UInt32.max - 9, 0, UInt32.max - 9, 0]])
        let second = counters(cores: [[10, 0, 10, 0]])
        let meters = SystemMeters.from(second, previous: first)
        XCTAssertEqual(meters.cores.first ?? -1, 0.5, accuracy: 1e-9)
    }

    func testAChangedCoreCountHasNoRate() {
        let meters = SystemMeters.from(counters(cores: [[1, 1, 1, 0], [1, 1, 1, 0]]), previous: counters(cores: [[0, 0, 0, 0]]))
        XCTAssertTrue(meters.cores.isEmpty)
    }

    func testACoreWhoseCountersDidNotMoveHasNoRateNeverZero() {
        let first = counters(cores: [[100, 50, 850, 0], [0, 0, 1_000, 0]])
        let second = counters(cores: [[150, 100, 950, 0], [0, 0, 1_000, 0]])
        let meters = SystemMeters.from(second, previous: first)
        XCTAssertTrue(meters.cores.isEmpty)
        XCTAssertNil(meters.cpu)
    }

    /// A full tick after a gap longer than a rate may span begins again:
    /// no CPU averaged over the gap as if it were now (6.11).
    func testAFullTickAfterALongGapHasNoCPU() throws {
        let kernel = FakeActivityKernel(uid: 501)
        kernel.add(FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1, start: 1, parent: 0, uid: 0, name: "launchd")))
        kernel.setMeters(counters(cores: [[0, 0, 100, 0]]))
        let sampler = ActivitySampler(kernel: kernel)
        _ = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        kernel.setMeters(counters(cores: [[25, 25, 150, 0]]))
        kernel.advance(20_000_000_000)
        let late = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        XCTAssertEqual(late.meters?.cores, [])
        kernel.setMeters(counters(cores: [[50, 50, 200, 0]]))
        kernel.advance(1_000_000_000)
        let next = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        XCTAssertEqual(next.meters?.cores.first ?? -1, 0.5, accuracy: 1e-9)
    }

    func testMemoryAsActivityMonitorCountsIt() {
        let meters = SystemMeters.from(counters(cores: []), previous: nil)
        let page: UInt64 = 16_384
        XCTAssertEqual(meters.app, 900 * page, "anonymous pages less the purgeable ones")
        XCTAssertEqual(meters.used, (900 + 300 + 200) * page, "app, wired and compressed")
        XCTAssertEqual(meters.cached, (500 + 100) * page, "file-backed and purgeable")
        XCTAssertEqual(meters.performanceCores, 8)
        XCTAssertEqual(meters.efficiencyCores, 2)
    }

    func testPressureAndThermalWords() {
        XCTAssertEqual(SystemMeters.from(counters(cores: [], pressure: 1), previous: nil).pressure, .normal)
        XCTAssertEqual(SystemMeters.from(counters(cores: [], pressure: 2), previous: nil).pressure, .warning)
        XCTAssertEqual(SystemMeters.from(counters(cores: [], pressure: 4), previous: nil).pressure, .critical)
        XCTAssertEqual(SystemMeters.from(counters(cores: [], pressure: nil), previous: nil).pressure, .unknown)
        XCTAssertEqual(SystemMeters.from(counters(cores: [], thermal: 2), previous: nil).thermal, .serious)
    }

    /// The full tick reads the meters, CPU from its second read; the light
    /// one never asks.
    func testTheFullTickCarriesTheMeters() throws {
        let kernel = FakeActivityKernel(uid: 501)
        kernel.add(FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1, start: 1, parent: 0, uid: 0, name: "launchd")))
        kernel.setMeters(counters(cores: [[0, 0, 100, 0]]))
        let sampler = ActivitySampler(kernel: kernel)
        let light = try XCTUnwrap(sampler.tickNow(ActivityDemand(.light(tabs: [])), context: ActivityContext()))
        XCTAssertNil(light.meters)
        XCTAssertEqual(kernel.count("meters"), 0)
        let first = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        XCTAssertEqual(first.meters?.cores, [])
        kernel.setMeters(counters(cores: [[25, 25, 150, 0]]))
        kernel.advance(1_000_000_000)
        let second = try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext()))
        XCTAssertEqual(second.meters?.cores.first ?? -1, 0.5, accuracy: 1e-9)
        kernel.setMeters(nil)
        kernel.advance(1_000_000_000)
        XCTAssertNil(try XCTUnwrap(sampler.tickNow(ActivityDemand(.full), context: ActivityContext())).meters)
    }

    /// The real kernel answers: counts only.
    func testTheLiveKernelReadsItsCounters() throws {
        let counters = try XCTUnwrap(LiveActivityKernel().meterCounters())
        XCTAssertEqual(counters.cores.count, ProcessInfo.processInfo.processorCount)
        XCTAssertGreaterThan(counters.memory, 0)
        XCTAssertGreaterThan(counters.pageSize, 0)
    }
}
