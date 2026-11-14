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

    /// The sampler's whole ticks (7.3's estimates): a light tick over one
    /// pane — the test stands for its `login`, its own sleeping children
    /// for the pane's processes — then the full level over the light
    /// tick's cache, as when the page opens while windows show, then a
    /// full census on a cache that read nothing yet. Each cold — back to
    /// back until the churn budget has read every identity — then steady,
    /// 500 ms apart, then back to back again, the core awake: wall time on
    /// `CLOCK_UPTIME_RAW` and the sampler thread's CPU time.
    func testTheSamplersTicks() throws {
        var children: [TestChild] = []
        defer { children.forEach { $0.stop() } }
        for _ in 0..<8 { children.append(try TestChild("/bin/sleep", ["120"])) }
        let start = try XCTUnwrap(ProcessInspector.kinfo(getpid())?.start)
        let tab = UUID()
        // No app: nothing is a helper.
        let pane = ActivityContext.Pane(tag: "probe", tab: tab, login: ActivityProcessID(pid: getpid(), start: start))
        let context = ActivityContext(panes: [pane], appPID: -1)
        let light = ActivityDemand(.light(tabs: [tab]))
        let full = ActivityDemand(.full)

        let sampler = ActivitySampler(kernel: kernel)
        let lightCold = cold(sampler, light, context)
        let lightSteady = steady(sampler, light, context)
        let lightAwake = awake(sampler, light, context)
        let members = sampler.tickNow(light, context: context)?.pane("probe")?.placed.count ?? 0
        report(
            "sampler light, \(members) members: cold \(lightCold.count) ticks \(summary(lightCold)); steady \(summary(lightSteady)); "
                + "back to back \(summary(lightAwake))")
        let fullCold = cold(sampler, full, context)
        let fullSteady = steady(sampler, full, context)
        let fullAwake = awake(sampler, full, context)
        let last = fullSteady.last ?? ActivityTickCost()
        report(
            "sampler full over the light cache, \(last.processes) processes (\(last.own) own): cold \(fullCold.count) ticks "
                + "\(summary(fullCold)), \(fullCold.reduce(0) { $0 + $1.commandsRead }) argv masked; steady \(summary(fullSteady)); "
                + "back to back \(summary(fullAwake))")
        let fresh = ActivitySampler(kernel: kernel)
        let freshCold = cold(fresh, full, context)
        report(
            "sampler full from nothing: cold \(freshCold.count) ticks \(summary(freshCold)), "
                + "\(freshCold.reduce(0) { $0 + $1.identitiesRead }) identities read; cache \(fresh.cachedIdentities)")
        XCTAssertFalse(fullSteady.isEmpty)
    }

    /// The light tick's term a member (7.3: "≈5 µs a member", which D-5's
    /// comparison relies on): one pane whose tree is the test's own
    /// children, each holding what an MCP server or a dev server holds — a
    /// TCP listener and a bound UDP socket on 127.0.0.1, a unix pair — at
    /// 8, 100 and 300 members, as several agent tabs with their MCP servers
    /// make. Each size on a sampler of its own, cold, then steady — 500 ms
    /// apart, the core asleep between them as at the app's 2 s — then back
    /// to back, the core awake: the work itself. The slope of the medians
    /// between 100 and 300 is the term a member.
    func testTheLightTickAMember() throws {
        let held = try heldSockets()
        defer { held.forEach { close($0) } }
        var children: [TestChild] = []
        defer { children.forEach { $0.stop() } }
        let start = try XCTUnwrap(ProcessInspector.kinfo(getpid())?.start)
        let tab = UUID()
        let pane = ActivityContext.Pane(tag: "probe", tab: tab, login: ActivityProcessID(pid: getpid(), start: start))
        let context = ActivityContext(panes: [pane], appPID: -1)
        let light = ActivityDemand(.light(tabs: [tab]))
        var steadyMedians: [Int: (wall: UInt64, cpu: UInt64)] = [:]
        var awakeMedians: [Int: (wall: UInt64, cpu: UInt64)] = [:]
        var awakeLeast: [Int: (wall: UInt64, cpu: UInt64)] = [:]
        for size in [8, 100, 300] {
            while children.count < size {
                children.append(try TestChild("/bin/sleep", ["120"], descriptors: Dictionary(uniqueKeysWithValues: held.map { ($0, $0) })))
            }
            let sampler = ActivitySampler(kernel: kernel)
            let coldTicks = cold(sampler, light, context)
            let steadyTicks = steady(sampler, light, context)
            let awakeTicks = awake(sampler, light, context)
            let snapshot = try XCTUnwrap(sampler.tickNow(light, context: context))
            let members = snapshot.pane("probe")?.placed ?? []
            let sockets = members.reduce(0) { $0 + (snapshot.facts[$1]?.sockets?.sockets ?? 0) }
            report(
                "sampler light, \(members.count) members holding \(sockets) sockets: cold \(coldTicks.count) ticks \(summary(coldTicks)); "
                    + "steady \(summary(steadyTicks)); back to back \(summary(awakeTicks))")
            XCTAssertEqual(members.count, size)
            steadyMedians[size] = (median(steadyTicks.map(\.wall)), median(steadyTicks.map(\.cpu)))
            awakeMedians[size] = (median(awakeTicks.map(\.wall)), median(awakeTicks.map(\.cpu)))
            awakeLeast[size] = (awakeTicks.map(\.wall).min() ?? 0, awakeTicks.map(\.cpu).min() ?? 0)
        }
        func perMember(_ medians: [Int: (wall: UInt64, cpu: UInt64)]) -> String {
            guard let few = medians[100], let many = medians[300] else { return "none" }
            func slope(_ low: UInt64, _ high: UInt64) -> String { String(format: "%.2f µs", (Double(high) - Double(low)) / 200 / 1_000) }
            return "wall \(slope(few.wall, many.wall)), CPU \(slope(few.cpu, many.cpu))"
        }
        report(
            "sampler light, a member (100 → 300): steady medians \(perMember(steadyMedians)); back to back medians "
                + "\(perMember(awakeMedians)), least \(perMember(awakeLeast))")
    }

    /// The signal path at a button (6.10, 3.11's spike): whether
    /// `proc_signal_with_audittoken` is there, what a token costs alone,
    /// and a whole send — its reads, the lineage up to this process, the
    /// helpers' groups, the token, the identity through it, the signal and,
    /// a test being guarded, the kernel's own gate check before it — of a
    /// CONT to the probe's own running child, which changes nothing.
    func testTheSignalPath() throws {
        let child = try TestChild("/bin/sleep", ["60"])
        defer { child.stop() }
        // The app's gate, which the real kernel's sends check too.
        XCTAssertTrue(ActivitySignalGate.shared.register(child.identity))
        defer { ActivitySignalGate.shared.unregister(child.identity) }
        let signals = ProcessSignals(kernel: kernel)
        let target = ActivitySignalTarget(child.identity, path: kernel.path(of: child.pid))
        var tokens: [UInt64] = []
        var sends: [UInt64] = []
        var answers: [ActivitySignalAnswer: Int] = [:]
        for _ in 0..<500 {
            let (token, tokenTime) = timed { kernel.auditToken(of: child.pid) }
            XCTAssertNotNil(token)
            tokens.append(tokenTime)
            let (answer, sendTime) = timed { signals.send(.cont, to: target, alone: false) }
            answers[answer, default: 0] += 1
            sends.append(sendTime)
        }
        func line(_ values: [UInt64]) -> String {
            let sorted = values.sorted()
            let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
            return String(format: "least %.1f, median %.1f, p90 %.1f µs", Double(sorted[0]) / 1e3, Double(sorted[sorted.count / 2]) / 1e3, Double(p90) / 1e3)
        }
        report(
            "signal path: proc_signal_with_audittoken \(kernel.signalsByToken ? "there" : "missing"); a token \(line(tokens)); "
                + "a whole send \(line(sends)); \(answers[.sent(pinned: true)] ?? 0) of 500 sent by token")
        XCTAssertEqual(answers[.sent(pinned: true)], 500)
    }

    /// What each child of `testTheLightTickAMember` is handed: a TCP
    /// listener and a bound UDP socket on 127.0.0.1, and a unix pair.
    private func heldSockets() throws -> [Int32] {
        func loopback(_ type: Int32) throws -> Int32 {
            let fd = Darwin.socket(AF_INET, type, 0)
            guard fd >= 0 else { throw POSIXError(.EMFILE) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) } }
            guard bound == 0, type != SOCK_STREAM || listen(fd, 16) == 0 else {
                close(fd)
                throw POSIXError(.EADDRNOTAVAIL)
            }
            return fd
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EMFILE) }
        return [try loopback(SOCK_STREAM), try loopback(SOCK_DGRAM)] + pair
    }

    private func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Ticks back to back until nothing waits for the churn budget, at most 20.
    private func cold(_ sampler: ActivitySampler, _ demand: ActivityDemand, _ context: ActivityContext) -> [ActivityTickCost] {
        var costs: [ActivityTickCost] = []
        for _ in 0..<20 {
            guard let snapshot = sampler.tickNow(demand, context: context) else { break }
            costs.append(snapshot.cost)
            if snapshot.unread == 0 { break }
        }
        return costs
    }

    /// Ten ticks 500 ms apart, after the cold ones.
    private func steady(_ sampler: ActivitySampler, _ demand: ActivityDemand, _ context: ActivityContext) -> [ActivityTickCost] {
        (0..<10).compactMap { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return sampler.tickNow(demand, context: context)?.cost
        }
    }

    /// Thirty ticks back to back, after the steady ones: the core awake and
    /// its caches warm, where a tick 500 ms after the last wakes it first.
    /// The least of them is the work alone, what else runs on the Mac
    /// only adding to it.
    private func awake(_ sampler: ActivitySampler, _ demand: ActivityDemand, _ context: ActivityContext) -> [ActivityTickCost] {
        (0..<30).compactMap { _ in sampler.tickNow(demand, context: context)?.cost }
    }

    /// Least, median, p90 and max of the wall and CPU times, in ms.
    private func summary(_ costs: [ActivityTickCost]) -> String {
        func line(_ values: [UInt64]) -> String {
            guard !values.isEmpty else { return "none" }
            let sorted = values.sorted()
            let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
            return String(
                format: "least %.2f, median %.2f, p90 %.2f, max %.2f ms", Double(sorted[0]) / 1e6, Double(sorted[sorted.count / 2]) / 1e6,
                Double(p90) / 1e6, Double(sorted.last ?? 0) / 1e6)
        }
        let reads = costs.map(\.identitiesRead).sorted()
        let churn = reads.isEmpty ? "" : "; identities read a tick: median \(reads[reads.count / 2]), max \(reads.last ?? 0)"
        return "wall \(line(costs.map(\.wall))); CPU \(line(costs.map(\.cpu)))\(churn)"
    }
}
