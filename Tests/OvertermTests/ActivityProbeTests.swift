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
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents

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

    /// The page's rows (6.4, 7.7) from a steady full tick of this Mac,
    /// everyone's, and the meters' read (3.8): times and counts only.
    func testThePagesRowsAndTheMeters() throws {
        let sampler = ActivitySampler(kernel: kernel)
        let context = ActivityContext(appPID: -1)
        var snapshot: ActivitySnapshot?
        // Past the cold start: the churn budget's ticks, then two more.
        for _ in 0..<12 {
            snapshot = sampler.tickNow(ActivityDemand(.full), context: context)
            if snapshot?.unread == 0, snapshot?.meters?.cores.isEmpty == false { break }
            usleep(300_000)
        }
        let full = try XCTUnwrap(snapshot)
        var times: [UInt64] = []
        var content = ActivityPageContent()
        for _ in 0..<20 {
            let (made, time) = timed { ActivityRows.content(of: full, ActivityRows.Options()) }
            content = made
            times.append(time)
        }
        times.sort()
        var meters: [UInt64] = []
        for _ in 0..<20 { meters.append(timed { kernel.meterCounters() }.1) }
        meters.sort()
        report(
            "page rows: \(content.processes.count) processes, \(content.ports.count) listening, median "
                + String(format: "%.2f ms", Double(times[times.count / 2]) / 1_000_000) + ", max "
                + String(format: "%.2f ms", Double(times.last ?? 0) / 1_000_000) + "; meters read median "
                + micros(meters[meters.count / 2], 1) + ", \(full.meters?.cores.count ?? 0) cores")
        XCTAssertEqual(content.processes.count, full.table.processes.count)
        // The owners alone (6.5): how many each place holds, and how many
        // processes another is responsible for (D-31) — counts only.
        var owners: [UInt64] = []
        var attribution = ActivityAttribution(owners: [:])
        for _ in 0..<20 {
            let (made, time) = timed { ActivityAttribution.of(full, context: context) }
            attribution = made
            owners.append(time)
        }
        owners.sort()
        var places: [String: Int] = [:]
        for owner in attribution.owners.values {
            let place: String
            switch owner.place {
            case .overterm: place = "overterm"
            case .pane: place = "pane"
            case .anotherOverterm: place = "another"
            case .engine: place = "engine"
            case .app: place = "app"
            case .macOS: place = "macOS"
            case .system: place = "system"
            case .elsewhere: place = "elsewhere"
            case .leftBehind: place = "leftBehind"
            }
            places[place, default: 0] += 1
        }
        let responsible = full.facts.values.filter { $0.responsible != nil }.count
        report(
            "owners: median " + String(format: "%.2f ms", Double(owners[owners.count / 2]) / 1_000_000) + "; "
                + places.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                + "; \(responsible) with another responsible, \(content.list.count) rows listed")
    }

    /// The old API on the census (7.8): a tab's tree answered from a
    /// snapshot a tick old at most — what the poll's panes, the overview's
    /// tabs × panes and Tab Info's ask between ticks, where each call
    /// rescanned every process (6.3–8.9 ms, 21–22 ms the first time with
    /// a tag, 2.2) — one that ticks, cold and steady, and the children of
    /// a process from one `KERN_PROC_ALL`, where the walk took a sysctl a
    /// pid (16–27 ms). The test stands for a pane's `login`, eight sleeping
    /// children of its own its processes; counts and times only.
    func testTheInspectorsLookups() throws {
        var children: [TestChild] = []
        defer { children.forEach { $0.stop() } }
        for _ in 0..<8 { children.append(try TestChild("/bin/sleep", ["120"])) }
        let census = ActivitySampler(kernel: kernel)
        let inspector = ProcessInspector(census: census)
        let (cold, coldTime) = timed { inspector.tree(root: getpid(), tag: nil) }
        let ticks = census.latest?.tick ?? 0
        var answered: [UInt64] = []
        for _ in 0..<200 { answered.append(timed { inspector.tree(root: getpid(), tag: nil) }.1) }
        XCTAssertEqual(census.latest?.tick, ticks, "answered with no new scan")
        let ticking = ProcessInspector(census: census, freshness: 0)
        var steady: [UInt64] = []
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            steady.append(timed { ticking.tree(root: getpid(), tag: nil) }.1)
        }
        var walks: [UInt64] = []
        for _ in 0..<20 { walks.append(timed { ProcessInspector.children(of: getpid()) }.1) }
        report(
            String(
                format: "inspector: cold %.2f ms (%d ticks, %d nodes); answered from a fresh snapshot median %.1f µs, max %.1f µs; "
                    + "a lookup that ticks, steady, median %.2f ms, max %.2f ms; children of a process median %.2f ms",
                Double(coldTime) / 1e6, ticks, cold.flatMap(\.flattened).count, Double(median(answered)) / 1e3, Double(answered.max() ?? 0) / 1e3,
                Double(median(steady)) / 1e6, Double(steady.max() ?? 0) / 1e6, Double(median(walks)) / 1e6))
        XCTAssertEqual(cold.flatMap(\.flattened).filter { node in children.contains { $0.identity == node.identity } }.count, 8)
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

    /// What the census relies on that a macOS may lack or change (12's
    /// support matrix), each said present or not, with counts: `rusage_info_v6`
    /// and its energy for the user's processes, `csops`, the token call,
    /// the responsibility call stage 1 groups by (D-31), and netstat's
    /// blindness under an ad hoc-signed parent (3.5) — the probe's own rows
    /// counted, never printed.
    func testTheSupportMatrix() throws {
        let own = try XCTUnwrap(ProcessTable.read(kernel)).processes.filter { $0.isOwn(by: kernel.uid) && !$0.isZombie }
        var v6 = 0
        var energy = 0
        for process in own {
            var info = rusage_info_v6()
            let answer = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(process.pid, RUSAGE_INFO_V6, $0) }
            }
            guard answer == 0 else { continue }
            v6 += 1
            if info.ri_energy_nj > 0 { energy += 1 }
        }
        report("rusage_info_v6: \(v6) of \(own.count) own answer, \(energy) with energy")
        XCTAssertGreaterThan(v6, 0)

        let csops = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") != nil
        report("csops \(csops ? "there" : "missing"); proc_signal_with_audittoken \(kernel.signalsByToken ? "there" : "missing")")

        typealias Responsible = @convention(c) (pid_t) -> pid_t
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            let responsible = unsafeBitCast(symbol, to: Responsible.self)
            var answered = 0
            var other = 0
            let (_, time) = timed {
                for process in own {
                    let pid = responsible(process.pid)
                    guard pid > 0 else { continue }
                    answered += 1
                    if pid != process.pid { other += 1 }
                }
            }
            report("responsibility: there; \(answered) of \(own.count) own answer, \(other) another process, \(micros(time, own.count)) a pid")
        } else {
            report("responsibility: missing (stage 1 groups by its fallback, D-31)")
        }

        let listeners = own.reduce(0) { count, process in
            var scan = SocketScan()
            scan.advance(keeping: [process.identity])
            return count + (scan.read(process.identity, kernel: kernel)?.listeners.filter(\.isListening).count ?? 0)
        }
        let plain = try netstatRows(parent: nil)
        let adHoc = try netstatRows(parent: adHocShell())
        report(
            "netstat -an -p tcp: \(plain) rows run from the probe, \(adHoc) from an ad hoc-signed sh; libproc finds \(listeners) TCP listeners of the user's"
                + (adHoc == 0 && listeners > 0 ? " — blind under ad hoc signing (3.5)" : "")
                + (plain == 0 && listeners > 0 ? "; the probe's own process blind too (its test bundle is signed ad hoc)" : ""))
    }

    /// Rows `netstat -an -p tcp` prints, run by `parent` (`sh -c`) or by the
    /// probe itself: a count — the rows are dropped unread.
    private func netstatRows(parent: URL?) throws -> Int {
        let process = Process()
        if let parent {
            process.executableURL = parent
            process.arguments = ["-c", "/usr/sbin/netstat -an -p tcp"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            process.arguments = ["-an", "-p", "tcp"]
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
    }

    /// A copy of `/bin/sh` signed ad hoc, as `make app` signs Overterm:
    /// what 3.5 found leaves netstat blind in every descendant.
    private func adHocShell() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("activity-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let shell = folder.appendingPathComponent("sh")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sh"), to: shell)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", shell.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0, "codesign -s -")
        return shell
    }

    /// D-8: Overterm's own energy (`ri_energy_nj`, this process's — the
    /// test stands for the app) a light and a full tick costs on a sampler
    /// at `.userInitiated` and at `.utility`. Each set of ticks 250 ms apart,
    /// the core asleep between them as at the app's cadence, less the same
    /// span idle measured beside it; then back to back, the core awake.
    /// Three rounds, the order turned each round; the medians.
    func testTheTicksEnergyAtEachQoS() throws {
        var children: [TestChild] = []
        defer { children.forEach { $0.stop() } }
        for _ in 0..<8 { children.append(try TestChild("/bin/sleep", ["300"])) }
        let start = try XCTUnwrap(ProcessInspector.kinfo(getpid())?.start)
        let tab = UUID()
        let pane = ActivityContext.Pane(tag: "probe", tab: tab, login: ActivityProcessID(pid: getpid(), start: start))
        let context = ActivityContext(panes: [pane], appPID: -1)
        let ticks = 20
        let spacing = 0.25
        func energy() -> UInt64 {
            var info = rusage_info_v6()
            _ = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) }
            }
            return info.ri_energy_nj
        }
        func idle() -> Double {
            let before = energy()
            for _ in 0..<ticks { Thread.sleep(forTimeInterval: spacing) }
            return Double(energy() &- before)
        }
        struct Config {
            let name: String
            let qos: DispatchQoS
            let demand: ActivityDemand
        }
        let configs = [
            Config(name: "light .userInitiated", qos: .userInitiated, demand: ActivityDemand(.light(tabs: [tab]))),
            Config(name: "light .utility", qos: .utility, demand: ActivityDemand(.light(tabs: [tab]))),
            Config(name: "full .userInitiated", qos: .userInitiated, demand: ActivityDemand(.full)),
            Config(name: "full .utility", qos: .utility, demand: ActivityDemand(.full)),
        ]
        let samplers = configs.map { config in
            let sampler = ActivitySampler(kernel: kernel, qos: config.qos)
            _ = cold(sampler, config.demand, context)
            return sampler
        }
        var spaced: [String: [Double]] = [:]
        var awake: [String: [Double]] = [:]
        var cpu: [String: [UInt64]] = [:]
        for round in 0..<3 {
            let order = round % 2 == 0 ? Array(configs.indices) : configs.indices.reversed()
            for index in order {
                let config = configs[index]
                let baseline = idle()
                let before = energy()
                for _ in 0..<ticks {
                    if let cost = samplers[index].tickNow(config.demand, context: context)?.cost { cpu[config.name, default: []].append(cost.cpu) }
                    Thread.sleep(forTimeInterval: spacing)
                }
                spaced[config.name, default: []].append((Double(energy() &- before) - baseline) / Double(ticks))
                let awakeBefore = energy()
                for _ in 0..<30 { _ = samplers[index].tickNow(config.demand, context: context) }
                awake[config.name, default: []].append(Double(energy() &- awakeBefore) / 30)
            }
        }
        func middle(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        for config in configs {
            report(
                String(
                    format: "energy, %@: %.1f µJ a tick 250 ms apart (rounds %@), %.1f µJ back to back; CPU median %.2f ms", config.name,
                    middle(spaced[config.name] ?? [0]) / 1e3, (spaced[config.name] ?? []).map { String(format: "%.1f", $0 / 1e3) }.joined(separator: ", "),
                    middle(awake[config.name] ?? [0]) / 1e3, Double(median(cpu[config.name] ?? [])) / 1e6))
        }
        XCTAssertGreaterThan(energy(), 0, "rusage_info_v6 carries energy here")
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

    /// nettop on this Mac (D-25): its answer parsed and checked against the
    /// census's own listeners, timed — counts, the check and times only.
    func testNettopsAnswerOnThisMac() throws {
        let snapshot = try XCTUnwrap(ActivitySampler(kernel: kernel).tickNow(ActivityDemand(.full), context: ActivityContext()))
        let expected = NettopListeners.expected(in: snapshot)
        var times: [UInt64] = []
        var reading: NettopListeners.Reading?
        for _ in 0..<5 {
            let (read, time) = timed { NettopListeners.Reader.run(NettopListeners.executable, expected: expected) }
            reading = read
            times.append(time)
        }
        let read = try XCTUnwrap(reading)
        times.sort()
        report(
            "nettop: \(read.listeners.count) listeners (\(Set(read.listeners.map(\.pid)).count) processes), the user's \(expected.count) checked: \(read.outcome); "
                + "wall median \(times[2] / 1_000_000) ms, max \(times[4] / 1_000_000) ms")
        guard case .read(let check) = read.outcome else { return XCTFail("nettop's answer wasn't read: \(read.outcome)") }
        if case .blind(let missing) = check { XCTFail("\(missing) of the user's listeners missing: read blind") }
    }

}
