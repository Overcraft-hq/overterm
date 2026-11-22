import Darwin
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes

/// The user's processes' usage and its rates (docs/design/activity/
/// analysis.md, 7.5): by the interval measured, over at least 250 ms and
/// at most 15 s, the first sample "—", baselines kept for every live
/// identity.
final class ProcessUsageTests: XCTestCase {
    private func sample(at time: UInt64, cpu: UInt64, energy: UInt64? = 0, wakeups: UInt64 = 0, read: UInt64 = 0) -> ActivityUsage {
        ActivityUsage(
            time: time, cpuTime: cpu, footprint: 1 << 20, residentSize: 1 << 20, threads: 2, runningThreads: 1, priority: 31, energy: energy,
            idleWakeups: wakeups, interruptWakeups: wakeups / 2, diskRead: read, diskWritten: read / 4)
    }

    func testRatesByTheMeasuredInterval() throws {
        let second: UInt64 = 1_000_000_000
        XCTAssertNil(ProcessUsage.rates(from: nil, to: sample(at: second, cpu: 0)), "a first sample has no rate")
        let then = sample(at: second, cpu: 0, energy: 1_000_000_000, wakeups: 100, read: 4_096)
        // 2 s measured, whatever the nominal interval was (App Nap).
        let now = sample(at: 3 * second, cpu: 3 * second, energy: 4_000_000_000, wakeups: 300, read: 8_192)
        let rates = try XCTUnwrap(ProcessUsage.rates(from: then, to: now))
        XCTAssertEqual(rates.interval, 2 * second)
        XCTAssertEqual(rates.cpuPercent, 150, accuracy: 1e-9, "100 is one core")
        XCTAssertEqual(try XCTUnwrap(rates.energy), 1.5, accuracy: 1e-9, "3 J over 2 s")
        XCTAssertEqual(rates.idleWakeupsPerSecond, 100, accuracy: 1e-9)
        XCTAssertEqual(rates.interruptWakeupsPerSecond, 50, accuracy: 1e-9)
        XCTAssertEqual(rates.diskReadPerSecond, 2_048, accuracy: 1e-9)
        XCTAssertEqual(rates.diskWrittenPerSecond, 512, accuracy: 1e-9)
        XCTAssertNil(ProcessUsage.rates(from: then, to: sample(at: second + 249_999_999, cpu: 1)), "under 250 ms: noise")
        XCTAssertNotNil(ProcessUsage.rates(from: then, to: sample(at: second + 250_000_000, cpu: 1, energy: 1_000_000_000, wakeups: 100, read: 4_096)))
        XCTAssertNil(ProcessUsage.rates(from: now, to: sample(at: 4 * second, cpu: second)), "a counter went back: not the same process's")
        XCTAssertNil(try XCTUnwrap(ProcessUsage.rates(from: then, to: sample(at: 3 * second, cpu: 0, energy: nil, wakeups: 100, read: 4_096))).energy)
    }

    /// The split-tab regression (2.4, item 1): two processes read in turn,
    /// as two panes of one tab are, both keep their baselines and both
    /// read busy. A reused pid is a new identity: "—" first.
    func testBaselinesSurviveReadersThatAskForOthers() throws {
        let kernel = FakeActivityKernel()
        let left = ActivityProcessID(pid: 100, start: 1)
        let right = ActivityProcessID(pid: 200, start: 1)
        for identity in [left, right] {
            var process = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: identity.pid, start: identity.start, parent: 1))
            process.usage = FakeActivityKernel.usage(cpuTime: 0)
            kernel.add(process)
        }
        var baselines = UsageBaselines()
        XCTAssertNil(baselines.record(try XCTUnwrap(kernel.usage(of: 100)), for: left), "—, never 0")
        XCTAssertNil(baselines.record(try XCTUnwrap(kernel.usage(of: 200)), for: right))
        for round in 1...3 {
            kernel.advance(1_000_000_000)
            for pid: pid_t in [100, 200] {
                kernel.update(pid) { $0.usage = FakeActivityKernel.usage(cpuTime: UInt64(round) * 1_000_000_000) }
            }
            // Pane by pane, each reader asking only for its own.
            let leftRates = baselines.record(try XCTUnwrap(kernel.usage(of: 100)), for: left)
            let rightRates = baselines.record(try XCTUnwrap(kernel.usage(of: 200)), for: right)
            XCTAssertEqual(try XCTUnwrap(leftRates).cpuPercent, 100, accuracy: 1e-6, "round \(round)")
            XCTAssertEqual(try XCTUnwrap(rightRates).cpuPercent, 100, accuracy: 1e-6, "round \(round)")
        }
        // A one-shot read 10 ms later: the rates last published, the
        // baseline left where it was.
        kernel.advance(10_000_000)
        XCTAssertEqual(try XCTUnwrap(baselines.record(try XCTUnwrap(kernel.usage(of: 100)), for: left)).cpuPercent, 100, accuracy: 1e-6)
        kernel.advance(990_000_000)
        kernel.update(100) { $0.usage = FakeActivityKernel.usage(cpuTime: 3_500_000_000) }
        XCTAssertEqual(try XCTUnwrap(baselines.record(try XCTUnwrap(kernel.usage(of: 100)), for: left)).cpuPercent, 50, accuracy: 1e-6, "over the whole second")

        // Pruned only of identities gone from the table.
        baselines.prune(keeping: [left, right])
        XCTAssertEqual(baselines.count, 2)
        baselines.prune(keeping: [left])
        XCTAssertEqual(baselines.count, 1)
        XCTAssertNil(baselines.rates(of: right))
        let reused = ActivityProcessID(pid: 100, start: 2)
        XCTAssertNil(baselines.record(try XCTUnwrap(kernel.usage(of: 100)), for: reused), "the same pid, a later start: another process")
    }

    /// A baseline nobody asked about for a while (6.11): a sample further
    /// than `maximumAge` from it begins again, "—", and what was published
    /// goes with it; the next has its rate from there.
    func testARateNeverSpansAGap() throws {
        let second: UInt64 = 1_000_000_000
        let identity = ActivityProcessID(pid: 100, start: 1)
        var baselines = UsageBaselines()
        XCTAssertEqual(baselines.maximumAge, 15 * second)
        XCTAssertNil(baselines.record(sample(at: second, cpu: 0), for: identity))
        XCTAssertEqual(try XCTUnwrap(baselines.record(sample(at: 16 * second, cpu: 15 * second), for: identity)).cpuPercent, 100, accuracy: 1e-9, "15 s: a rate")
        XCTAssertNil(baselines.record(sample(at: 76 * second, cpu: 60 * second), for: identity), "a minute on: —")
        XCTAssertNil(baselines.record(sample(at: 76 * second + 10_000_000, cpu: 60 * second), for: identity), "nothing published since")
        let rates = try XCTUnwrap(baselines.record(sample(at: 78 * second, cpu: 61 * second), for: identity))
        XCTAssertEqual(rates.cpuPercent, 50, accuracy: 1e-9, "from the new baseline")
        XCTAssertEqual(rates.interval, 2 * second)
        var short = UsageBaselines(maximumAge: 2 * second)
        XCTAssertNil(short.record(sample(at: second, cpu: 0), for: identity))
        XCTAssertNil(short.record(sample(at: 3 * second + 1, cpu: 0), for: identity), "its own bound")
    }

    func testAnotherUsersUsageIsRefused() {
        let kernel = FakeActivityKernel(uid: 501)
        var root = FakeActivityKernel.Process(record: FakeActivityKernel.record(pid: 1, start: 1, parent: 0, uid: 0))
        root.usage = FakeActivityKernel.usage(cpuTime: 1)
        kernel.add(root)
        XCTAssertNil(ProcessUsage.read(1, kernel: kernel))
        XCTAssertNil(ProcessUsage.read(1, kernel: LiveActivityKernel()), "launchd's: EPERM")
    }

    /// A busy child of the test's (10.2): its first sample "—", its rate
    /// from two samples over the interval measured between them. Bounded
    /// by itself — the kernel ends it after 20 s of CPU — so a runner
    /// stopped by ⌃C (the terminal's SIGINT never reaches the child's own
    /// group) or a crash leaves no loop burning a core under launchd.
    func testARealBusyChildsRate() throws {
        let child = try TestChild("/bin/sh", ["-c", "ulimit -c 0; ulimit -t 20; while :; do :; done"])
        defer { child.stop() }
        let kernel = LiveActivityKernel()
        var baselines = UsageBaselines()
        let first = try XCTUnwrap(ProcessUsage.read(child.pid, kernel: kernel))
        XCTAssertNil(baselines.record(first, for: child.identity), "—")
        XCTAssertGreaterThan(first.footprint, 0)
        XCTAssertGreaterThanOrEqual(first.threads, 1)
        var second: ActivityUsage?
        // Wait for work, not for a moment: 50 ms of CPU, 250 ms apart.
        XCTAssertTrue(
            TestChild.eventually(30) {
                second = ProcessUsage.read(child.pid, kernel: kernel)
                guard let second else { return false }
                return second.time >= first.time + ProcessUsage.minimumInterval && second.cpuTime >= first.cpuTime + 50_000_000
            })
        let now = try XCTUnwrap(second)
        let rates = try XCTUnwrap(baselines.record(now, for: child.identity))
        XCTAssertEqual(rates.interval, now.time - first.time)
        XCTAssertEqual(rates.cpuPercent, Double(now.cpuTime - first.cpuTime) / Double(now.time - first.time) * 100, accuracy: 1e-9)
        XCTAssertGreaterThan(rates.cpuPercent, 0)
        XCTAssertNotNil(rates.energy, "rusage v6's energy")
    }
}
