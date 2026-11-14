import Darwin
import XCTest

@testable import Overterm

/// What the census relies on, checked on the Mac it runs on (docs/design/
/// activity/analysis.md, 12: measured on one macOS): the structures' sizes,
/// who answers each call, and what it costs. Opt-in —
///
///     OVERTERM_ACTIVITY_PROBES=1 swift test --filter ActivityProbeTests
///
/// — run on each new macOS and on the oldest supported one. It reads the
/// real process table, read only, and prints counts, errnos and timings:
/// never a name, an argv, a path or an address of a process not its own.
final class ActivityProbeTests: XCTestCase {
    private let kernel = LiveActivityKernel()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERTERM_ACTIVITY_PROBES"] == "1", "OVERTERM_ACTIVITY_PROBES=1 runs it")
    }

    private func report(_ line: String) { print("activity-probe: \(line)") }

    /// µs per call, the mean.
    private func micros(_ nanoseconds: UInt64, _ calls: Int) -> String {
        String(format: "%.2f µs", Double(nanoseconds) / Double(max(calls, 1)) / 1_000)
    }

    private func timed<T>(_ body: () -> T) -> (T, UInt64) {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let value = body()
        return (value, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
    }

    /// The sizes the census reads with (12: 648, 792, 232, 464 on 27.2).
    func testStructureSizes() {
        report(
            "sizes kinfo_proc \(MemoryLayout<kinfo_proc>.size), socket_fdinfo \(MemoryLayout<socket_fdinfo>.size), "
                + "proc_taskallinfo \(MemoryLayout<proc_taskallinfo>.size), rusage_info_v6 \(MemoryLayout<rusage_info_v6>.size)")
        XCTAssertEqual(MemoryLayout<kinfo_proc>.size, 648)
        XCTAssertEqual(MemoryLayout<socket_fdinfo>.size, 792)
        XCTAssertEqual(MemoryLayout<proc_taskallinfo>.size, 232)
        XCTAssertEqual(MemoryLayout<rusage_info_v6>.size, 464)
    }

    /// One `KERN_PROC_ALL`, and who is whose.
    func testTheProcessTable() throws {
        var times: [UInt64] = []
        var sysctls: [UInt64] = []
        var table: ProcessTable?
        for _ in 0..<20 {
            let (read, time) = timed { ProcessTable.read(kernel) }
            table = read
            times.append(time)
            let (_, sysctl) = timed {
                ProcessTable.readEntries(
                    estimate: {
                        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
                        var size = 0
                        return Darwin.sysctl(&mib, 3, nil, &size, nil, 0) == 0 ? size : nil
                    },
                    fill: { buffer, written in
                        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
                        return Darwin.sysctl(&mib, 3, buffer.baseAddress, &written, nil, 0) == 0 ? 0 : errno
                    })
            }
            sysctls.append(sysctl)
        }
        let processes = try XCTUnwrap(table).processes
        let own = processes.filter { $0.isOwn(by: kernel.uid) }.count
        let root = processes.filter { $0.effectiveUID == 0 }.count
        let setuid = processes.filter { $0.effectiveUID == 0 && $0.realUID == kernel.uid }.count
        let zombies = processes.filter(\.isZombie).count
        report(
            "KERN_PROC_ALL \(processes.count) processes: \(own) own, \(root) root's (\(setuid) setuid ones the user started), "
                + "\(processes.count - own - root) other users', \(zombies) zombies; median \(micros(sysctls.sorted()[sysctls.count / 2], 1)) "
                + "the sysctls, \(micros(times.sorted()[times.count / 2], 1)) with the parse and the links")
        XCTAssertGreaterThan(own, 0)
        XCTAssertGreaterThan(root, 0)
    }

    /// `csops` against Security.framework's dynamic status: who answers,
    /// whether they agree on `CS_RESTRICT` and `CS_PLATFORM_BINARY`, and the
    /// cost of each per pid (3.11's spike).
    func testCodeSigningAndItsFallback() throws {
        let processes = try XCTUnwrap(ProcessTable.read(kernel)).processes.filter { $0.pid > 0 }
        for (label, group) in [
            ("own", processes.filter { $0.isOwn(by: kernel.uid) }), ("root's", processes.filter { $0.effectiveUID == 0 }),
            ("other users'", processes.filter { $0.effectiveUID != 0 && !$0.isOwn(by: kernel.uid) }),
        ] {
            var csops = 0
            var security = 0
            var agree = 0
            var both = 0
            var csopsTime: UInt64 = 0
            var securityTime: UInt64 = 0
            var restricted = 0
            for process in group {
                let (answer, first) = timed { kernel.codeSigningStatus(of: process.pid) }
                let (fallback, second) = timed { kernel.securityCodeSigning(of: process.pid) }
                csopsTime += first
                securityTime += second
                let mask = ActivityCodeSigning.restrict | ActivityCodeSigning.platformBinary
                if case .flags(let signing) = answer {
                    csops += 1
                    if signing.isRestricted { restricted += 1 }
                    if let fallback {
                        both += 1
                        if fallback.flags & mask == signing.flags & mask { agree += 1 }
                    }
                }
                if fallback != nil { security += 1 }
            }
            report(
                "code signing, \(label) \(group.count): csops \(csops) at \(micros(csopsTime, group.count)) a pid (\(restricted) CS_RESTRICT); "
                    + "Security.framework \(security) at \(micros(securityTime, group.count)) a pid, \(agree) agreeing")
            XCTAssertEqual(agree, both, "\(label): the fallback reads the same flags")
        }
    }

    /// The user's processes' usage, argv and sockets, as a full tick reads
    /// them (3.7's sweep A and C).
    func testTheUsersUsageArgvAndSockets() throws {
        let own = try XCTUnwrap(ProcessTable.read(kernel)).processes.filter { $0.isOwn(by: kernel.uid) && !$0.isZombie }
        let (usages, usageTime) = timed { own.compactMap { kernel.usage(of: $0.pid) } }
        report("usage: \(usages.count) of \(own.count) own at \(micros(usageTime, own.count)) a pid")

        var fallbacks = 0
        var scanned = 0
        var tagged = 0
        let (reads, argumentsTime) = timed {
            own.compactMap { process -> ProcessArguments? in
                let signing = kernel.codeSigning(of: process.pid, fallbacks: &fallbacks)
                if signing?.isRestricted != true { scanned += 1 }
                let read = ProcessArguments.read(process.pid, kernel: kernel, markers: true, codeSigning: signing)
                if read?.markers?.isEmpty == false { tagged += 1 }
                return read
            }
        }
        let cut = reads.filter(\.isCut).count
        let titles = reads.filter(\.isTitle).count
        report(
            "argv: \(reads.count) of \(own.count) own, masked, at \(micros(argumentsTime, own.count)) a pid with csops; "
                + "\(scanned) environments scanned, \(tagged) with a marker, \(cut) cut at 64 KB, \(titles) titles written over argv")

        var scan = SocketScan()
        scan.advance(keeping: Set(own.map(\.identity)))
        let (sockets, socketTime) = timed { own.compactMap { scan.read($0.identity, kernel: kernel) } }
        let total = sockets.reduce(0) { $0 + $1.sockets }
        let listeners = sockets.reduce(0) { $0 + $1.listeners.count }
        let bounded = sockets.filter { $0.bound != nil }.count
        report(
            "sockets: \(sockets.count) processes, \(sockets.reduce(0) { $0 + $1.descriptors }) descriptors, \(total) sockets, "
                + "\(listeners) listeners, \(bounded) bounded; \(micros(socketTime, 1)) the walk")
        scan.advance(keeping: Set(own.map(\.identity)))
        let (_, again) = timed { own.forEach { _ = scan.read($0.identity, kernel: kernel) } }
        report("sockets again, nothing changed: \(micros(again, 1)) the walk")
        XCTAssertGreaterThan(usages.count, 0)
    }
}
