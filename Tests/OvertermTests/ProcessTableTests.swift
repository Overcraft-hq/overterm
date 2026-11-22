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

/// Every process from one `KERN_PROC_ALL` (docs/design/activity/analysis.md,
/// 7.2, 6.5): sized with headroom and read again when full, parents linked
/// by start time, a zombie's state from `p_stat`.
final class ProcessTableTests: XCTestCase {
    private func record(_ pid: pid_t, start: UInt64, parent: pid_t, status: Int32 = SRUN) -> ActivityProcess {
        FakeActivityKernel.record(pid: pid, start: start, parent: parent, status: status)
    }

    // MARK: Reading

    /// ENOMEM, or a buffer filled to its last byte, is read again larger; a
    /// short buffer is never taken for the whole table.
    func testAFullBufferIsReadAgainLarger() throws {
        let stride = MemoryLayout<kinfo_proc>.stride
        var sizes: [Int] = []
        let entries = try XCTUnwrap(
            ProcessTable.readEntries(
                estimate: { 10 * stride },
                fill: { buffer, written in
                    sizes.append(buffer.count / stride)
                    // 400 processes now: more than the estimate's 10.
                    guard buffer.count >= 400 * stride else { return ENOMEM }
                    for index in 0..<400 {
                        var info = kinfo_proc()
                        info.kp_proc.p_pid = pid_t(index + 1)
                        buffer.storeBytes(of: info, toByteOffset: index * stride, as: kinfo_proc.self)
                    }
                    written = 400 * stride
                    return 0
                }))
        XCTAssertEqual(entries.count, 400)
        XCTAssertEqual(entries.last?.kp_proc.p_pid, 400)
        XCTAssertGreaterThan(sizes.count, 1)
        XCTAssertEqual(sizes.first, 10 + 2 + ProcessTable.headroom, "the estimate, a quarter more, and headroom")

        var calls = 0
        let full = ProcessTable.readEntries(
            estimate: { 4 * stride },
            fill: { buffer, written in
                calls += 1
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
                // Every byte used: maybe cut, so asked again larger.
                written = calls == 1 ? buffer.count : 4 * stride
                return 0
            })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(full?.count, 4)

        XCTAssertNil(ProcessTable.readEntries(estimate: { nil }, fill: { _, _ in 0 }), "no estimate, no table")
        XCTAssertNil(
            ProcessTable.readEntries(
                estimate: { stride },
                fill: { _, written in
                    written = stride + 1
                    return 0
                }), "a part of an entry")
        XCTAssertNil(ProcessTable.readEntries(estimate: { stride }, fill: { _, _ in ENOMEM }), "never enough, at last refused")
        XCTAssertNil(ProcessTable.readEntries(estimate: { stride }, fill: { _, _ in EPERM }))
    }

    /// Every field of the census's from kinfo (7.2's first row).
    func testAnEntrysFields() throws {
        var info = kinfo_proc()
        info.kp_proc.p_pid = 4242
        info.kp_proc.p_un.__p_starttime = timeval(tv_sec: 1_700_000_000, tv_usec: 123_456)
        info.kp_proc.p_stat = CChar(SSTOP)
        info.kp_proc.p_flag = P_TRANSLATED | P_TRACED
        info.kp_proc.p_sigignore = 1 << UInt32(SIGHUP - 1)
        info.kp_proc.p_sigcatch = 1 << UInt32(SIGTERM - 1)
        info.kp_proc.p_nice = 5
        withUnsafeMutableBytes(of: &info.kp_proc.p_comm) { raw in
            for (index, byte) in "com.acme.backend.helper".utf8.prefix(raw.count - 1).enumerated() { raw[index] = byte }
        }
        info.kp_eproc.e_ppid = 1
        info.kp_eproc.e_pgid = 4242
        info.kp_eproc.e_tdev = 0x1000_0003
        info.kp_eproc.e_tpgid = 4300
        info.kp_eproc.e_flag = Int32(EPROC_SLEADER | EPROC_CTTY)
        info.kp_eproc.e_ucred.cr_uid = 0
        info.kp_eproc.e_pcred.p_ruid = 501
        info.kp_eproc.e_pcred.p_svuid = 0
        let process = try XCTUnwrap(ProcessTable.record(info))
        XCTAssertEqual(process.identity, ActivityProcessID(pid: 4242, start: 1_700_000_000_123_456))
        XCTAssertEqual(process.identity.id, "4242:1700000000123456")
        XCTAssertEqual(ActivityProcessID(id: process.identity.id), process.identity)
        XCTAssertEqual(process.parentPID, 1)
        XCTAssertEqual(process.group, 4242)
        XCTAssertEqual(process.terminal, 0x1000_0003)
        XCTAssertEqual(process.terminalGroup, 4300)
        XCTAssertEqual(process.flags, [.translated, .traced, .sessionLeader, .controllingTerminal])
        XCTAssertTrue(process.isStopped)
        XCTAssertTrue(process.ignoresHangup)
        XCTAssertEqual(process.caughtSignals, 1 << UInt32(SIGTERM - 1))
        XCTAssertEqual(process.nice, 5)
        XCTAssertEqual(process.shortName, "com.acme.backend", "p_comm: 16 bytes and its NUL")
        // A setuid-root process the user started: root to reads, the user to kill(2).
        XCTAssertEqual(process.effectiveUID, 0)
        XCTAssertEqual(process.realUID, 501)
        XCTAssertEqual(process.savedUID, 0)
        XCTAssertFalse(process.isOwn(by: 501))

        info.kp_eproc.e_tdev = -1
        info.kp_proc.p_sigignore = 0
        let detached = try XCTUnwrap(ProcessTable.record(info))
        XCTAssertNil(detached.terminal)
        XCTAssertNil(detached.terminalGroup)
        XCTAssertFalse(detached.ignoresHangup)
        XCTAssertNil(ActivityProcessID(id: "4242"))
        XCTAssertNil(ActivityProcessID(id: "a:1"))
    }

    func testTheStateColumn() {
        XCTAssertEqual(ActivityState(status: SSTOP, runningThreads: 3), .stopped)
        XCTAssertEqual(ActivityState(status: SZOMB, runningThreads: nil), .zombie)
        XCTAssertEqual(ActivityState(status: SRUN, runningThreads: 1), .running)
        XCTAssertEqual(ActivityState(status: SRUN, runningThreads: 0), .sleeping)
        XCTAssertEqual(ActivityState(status: SRUN, runningThreads: nil), .unknown, "another user's: SRUN says nothing")
        XCTAssertEqual(ActivityState.unknown.letter, "")
    }

    // MARK: Parents by start time

    /// A child's parent started no later than it: one that started later
    /// took a dead parent's pid, and the child is a root.
    func testParentsAreCheckedByStartTime() {
        let table = ProcessTable([
            record(1, start: 10, parent: 0),
            record(100, start: 500, parent: 1),
            record(101, start: 600, parent: 100),
            // Its parent's pid now belongs to a process younger than it.
            record(102, start: 550, parent: 200),
            record(200, start: 700, parent: 1),
            record(103, start: 800, parent: 101),
        ])
        let child = ActivityProcessID(pid: 101, start: 600)
        XCTAssertEqual(table.parent(of: child)?.pid, 100)
        XCTAssertNil(table.parent(of: ActivityProcessID(pid: 102, start: 550)), "a reused pid isn't its parent")
        XCTAssertFalse(table.children(of: ActivityProcessID(pid: 200, start: 700)).contains { $0.pid == 102 })
        XCTAssertEqual(table.children(of: ActivityProcessID(pid: 1, start: 10)).map(\.pid), [100, 200])
        XCTAssertEqual(Set(table.descendants(of: ActivityProcessID(pid: 100, start: 500)).map(\.pid)), [101, 103])
        XCTAssertTrue(table.descends(ActivityProcessID(pid: 103, start: 800), from: ActivityProcessID(pid: 1, start: 10)))
        XCTAssertFalse(table.descends(ActivityProcessID(pid: 102, start: 550), from: ActivityProcessID(pid: 1, start: 10)))
        XCTAssertNil(table.process(ActivityProcessID(pid: 101, start: 1)), "the pid, not that identity")
        XCTAssertEqual(table.process(pid: 101)?.identity, child)
        XCTAssertTrue(table.children(of: ActivityProcessID(pid: 100, start: 1)).isEmpty, "an identity that's gone has none")
        XCTAssertNil(table.parent(of: ActivityProcessID(pid: 1, start: 10)), "launchd's parent is the kernel's, pid 0, absent")
        XCTAssertEqual(ProcessTable([record(0, start: 1, parent: 0)]).children(of: ActivityProcessID(pid: 0, start: 1)).count, 0, "not its own child")
    }

    /// A zombie is placed by its parent: its state comes from `p_stat`.
    func testAZombieIsUnderItsParent() {
        let table = ProcessTable([record(50, start: 1, parent: 1), record(51, start: 2, parent: 50, status: SZOMB)])
        let zombie = table.process(pid: 51)
        XCTAssertEqual(zombie?.isZombie, true)
        XCTAssertEqual(table.parent(of: ActivityProcessID(pid: 51, start: 2))?.pid, 50)
        XCTAssertEqual(ActivityState(status: zombie?.status ?? 0, runningThreads: nil), .zombie)
    }

    // MARK: Real children of the test's

    private var ourselves: ActivityProcessID { ActivityProcessID(pid: getpid(), start: ProcessInspector.kinfo(getpid())?.start ?? 0) }

    private func now() -> UInt64 {
        var time = timeval()
        gettimeofday(&time, nil)
        return UInt64(time.tv_sec) * 1_000_000 + UInt64(time.tv_usec)
    }

    /// The test's own child: its start between the moments around its
    /// spawn, its parent this test process by identity.
    func testARealChildsStartAndParent() throws {
        let before = now()
        let child = try TestChild("/bin/sleep", ["60"])
        defer { child.stop() }
        let after = now()
        let table = try XCTUnwrap(ProcessTable.read(LiveActivityKernel()))
        XCTAssertGreaterThan(table.processes.count, 1)
        let found = try XCTUnwrap(table.process(child.identity))
        XCTAssertGreaterThanOrEqual(found.identity.start + 1_000, before)
        XCTAssertLessThanOrEqual(found.identity.start, after + 1_000)
        XCTAssertEqual(table.parent(of: child.identity)?.identity, ourselves)
        XCTAssertTrue(table.children(of: ourselves).contains { $0.identity == child.identity })
        XCTAssertEqual(found.group, child.pid, "its own group, never the runner's")
        XCTAssertTrue(found.isOwn(by: getuid()))
        XCTAssertEqual(found.shortName, "sleep")
        XCTAssertFalse(found.isZombie)
        XCTAssertFalse(found.ignoresHangup)
    }

    /// A child that exited unreaped: Z, from `p_stat` only, under its parent.
    func testARealZombie() throws {
        let child = try TestChild("/usr/bin/true", [])
        defer { child.stop() }
        let kernel = LiveActivityKernel()
        XCTAssertTrue(TestChild.eventually { ProcessTable.read(kernel)?.process(child.identity)?.isZombie == true }, "exited, not reaped")
        let table = try XCTUnwrap(ProcessTable.read(kernel))
        XCTAssertEqual(table.parent(of: child.identity)?.identity, ourselves)
        XCTAssertNil(kernel.usage(of: child.pid), "every flavour refuses a zombie's task")
        child.stop()
        XCTAssertNil(ProcessTable.read(kernel)?.process(child.identity), "reaped, gone")
    }

    /// `nohup` ignores SIGHUP before it execs: read from `p_sigignore`.
    func testANohupChildIgnoresHangup() throws {
        let plain = try TestChild("/bin/sleep", ["60"])
        defer { plain.stop() }
        let nohup = try TestChild("/usr/bin/nohup", ["/bin/sleep", "60"])
        defer { nohup.stop() }
        let kernel = LiveActivityKernel()
        XCTAssertTrue(TestChild.eventually { ProcessTable.read(kernel)?.process(nohup.identity)?.shortName == "sleep" }, "nohup exec'd sleep")
        let table = try XCTUnwrap(ProcessTable.read(kernel))
        XCTAssertEqual(table.process(nohup.identity)?.ignoresHangup, true)
        XCTAssertEqual(table.process(plain.identity)?.ignoresHangup, false)
    }
}
