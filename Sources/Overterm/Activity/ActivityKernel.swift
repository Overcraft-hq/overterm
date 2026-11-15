import Darwin
import Foundation
import Security

/// What the census asks the kernel (docs/design/activity/analysis.md, 7.2,
/// 10.1), as one protocol: `LiveActivityKernel` asks libproc, sysctl and
/// Mach; `FakeActivityKernel` is a whole Mac a test makes — another user's
/// processes, thousands of sockets, a clock that moves when told. Every
/// call is a plain synchronous one for the sampler's queue, never the main
/// thread — but `ProcessSignals`', a deliberate fresh read at a button
/// (7.1), each bounded. Its calls — one process read now, the audit
/// token, the signal — are here too, so a fake can say a refusal made none.
protocol ActivityKernel: Sendable {
    /// The user the census reads for: `getuid()`.
    var uid: uid_t { get }
    /// `CLOCK_UPTIME_RAW`, ns: what every rate divides by.
    func uptime() -> UInt64
    /// `KERN_PROC_ALL`: every process; nil when sysctl fails.
    func processes() -> [ActivityProcess]?
    /// The user's process's usage, read now (`ActivityUsage.time` is when);
    /// nil when refused (another user's) or gone.
    func usage(of pid: pid_t) -> ActivityUsage?
    /// `proc_name`: the name it runs as (`pbi_name`) — any user's, root's
    /// too: XNU answers `PROC_PIDT_SHORTBSDINFO` without a same-user
    /// check. A reader that trusts a name checks the uid first.
    func name(of pid: pid_t) -> String?
    /// `proc_pidpath`: any user's.
    func path(of pid: pid_t) -> String?
    /// `csops(CS_OPS_STATUS)`: any user's, ≈1.5 µs.
    func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer
    /// Security.framework's dynamic status, where `csops` can't answer:
    /// the same flags, about 900 times the cost (1.2–1.4 ms a pid, measured).
    func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning?
    /// The bytes `KERN_PROCARGS2` would give; nil when refused (another
    /// user's: EINVAL) or gone.
    func argumentsLength(of pid: pid_t) -> Int?
    /// `KERN_PROCARGS2` into `region`, never copied elsewhere: the bytes it
    /// wrote; nil when refused or gone. A region too small for the area —
    /// it grew since `argumentsLength`, or is past `kern.argmax` — comes
    /// back full with no error, holding the area's tail or zeros.
    func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int?
    /// `PROC_PIDLISTFDS`: its descriptors; nil when refused or gone.
    func descriptors(of pid: pid_t) -> [proc_fdinfo]?
    /// `PROC_PIDFDSOCKETINFO`: nil when the descriptor holds no socket now.
    func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo?
    /// `PROC_PIDVNODEPATHINFO`'s working folder: the user's; nil when
    /// refused, gone or none. It fills a `vn_stat`, so it asks the file
    /// system, and a folder on a mount that stopped answering can hold it
    /// for the mount's timeout (7.2): `ProcessFolders` calls it on a queue
    /// of its own, never a tick.
    func workingDirectory(of pid: pid_t) -> String?

    // MARK: What ProcessSignals asks (6.10), at the button

    // The two sends are `ProcessSignals`' alone: a caller of its own skips
    // its refusals and the identity check. In an isolated run or a unit
    // test the live kernel's make the isolated-run gate's check themselves,
    // before their call (`ActivitySignalGate.refusal(of:kernel:app:)`).

    /// `KERN_PROC_PID`: one process's structure, read now — any user's, a
    /// zombie's too; nil once it is gone.
    func process(_ pid: pid_t) -> ActivityProcess?
    /// `proc_listpids(PROC_PGRP_ONLY)`: the members of process group
    /// `group` now, any user's — no table read, microseconds; nil when the
    /// call fails. At most `limit`.
    func groupMembers(_ group: pid_t, limit: Int) -> [pid_t]?
    /// `task_name_for_pid`, then `task_info(TASK_AUDIT_TOKEN)`: the token
    /// of the image `pid` runs now. The user's own processes only: nil for
    /// another user's, for a setuid one the user started (KERN_FAILURE,
    /// 3.2), a zombie, or one gone.
    func auditToken(of pid: pid_t) -> ActivityAuditToken?
    /// `proc_pidpath_audittoken`: the executable of the image the token
    /// names; nil once that image is gone (the process ended or exec'd) or
    /// its file was deleted.
    func path(of token: ActivityAuditToken) -> String?
    /// Whether `proc_signal_with_audittoken` is there: its availability
    /// isn't stated (3.9), so it is looked up, never linked.
    var signalsByToken: Bool { get }
    /// `proc_signal_with_audittoken`: 0 when sent, else the errno it
    /// returns as its value — ESRCH once the token's image is gone: the
    /// process ended, or exec'd (3.9). ENOSYS without the call.
    func signal(_ signal: Int32, by token: ActivityAuditToken) -> Int32
    /// `kill(pid, signal)`: 0 when sent, else the errno. The
    /// identity-checked fallback's one call (6.10 step 6), for a single
    /// Stop; never a pid ≤ 1 — no group, no `kill(-1)` — nor this process.
    func signal(_ signal: Int32, pid: pid_t) -> Int32
}

/// A process's audit token (`TASK_AUDIT_TOKEN`, 3.9): it names one
/// executable image of one process — its pid, and the pid's version, which
/// an `exec` moves on. A signal sent by it reaches that image or nothing:
/// once the process ended or exec'd, the call answers ESRCH.
struct ActivityAuditToken: Hashable, Sendable {
    /// `audit_token_t`'s eight words, as the kernel fills them: libbsm's
    /// accessors read the same places (`audit_token_to_pid` the sixth).
    let words: [UInt32]

    init(_ token: audit_token_t) {
        words = withUnsafeBytes(of: token.val) { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// A fake's.
    init(pid: pid_t, effectiveUID: uid_t, realUID: uid_t? = nil, version: UInt32) {
        words = [0, effectiveUID, 0, realUID ?? effectiveUID, 0, UInt32(bitPattern: pid), 0, version]
    }

    /// Who it was when the token was taken: its effective and real uids
    /// (libbsm's second and fourth words).
    var effectiveUID: uid_t { words[1] }
    var realUID: uid_t { words[3] }
    var pid: pid_t { pid_t(bitPattern: words[5]) }
    /// The pid's version: an `exec` moves it on.
    var version: UInt32 { words[7] }

    var token: audit_token_t {
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token.val) { raw in
            for (index, word) in words.prefix(8).enumerated() { raw.storeBytes(of: word, toByteOffset: index * 4, as: UInt32.self) }
        }
        return token
    }
}

/// What `csops` said.
enum CodeSigningAnswer: Hashable, Sendable {
    case flags(ActivityCodeSigning)
    /// The process is gone.
    case gone
    /// It can't answer here (no `csops`, or refused): Security.framework may.
    case unavailable
}

extension ActivityKernel {
    /// `pid`'s code signing: `csops`, else Security.framework's answer
    /// while `fallbacks` lasts (each over a millisecond); nil is unknown — never
    /// "macOS" (3.3).
    func codeSigning(of pid: pid_t, fallbacks: inout Int) -> ActivityCodeSigning? {
        switch codeSigningStatus(of: pid) {
        case .flags(let signing): return signing
        case .gone: return nil
        case .unavailable:
            guard fallbacks > 0 else { return nil }
            fallbacks -= 1
            return securityCodeSigning(of: pid)
        }
    }
}

/// The kernel itself: libproc, sysctl, Mach.
struct LiveActivityKernel: ActivityKernel {
    let uid = getuid()

    func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    func processes() -> [ActivityProcess]? {
        func call(_ buffer: UnsafeMutableRawPointer?, _ size: inout Int) -> Int32 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
            return sysctl(&mib, 3, buffer, &size, nil, 0) == 0 ? 0 : errno
        }
        let entries = ProcessTable.readEntries(
            estimate: {
                var size = 0
                return call(nil, &size) == 0 ? size : nil
            },
            fill: { buffer, written in call(buffer.baseAddress, &written) })
        return entries?.compactMap(ProcessTable.record)
    }

    func usage(of pid: pid_t) -> ActivityUsage? {
        var task = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &task, size) == size else { return nil }
        let time = uptime()
        guard let (rusage, hasEnergy) = Self.rusage(of: pid) else { return nil }
        let info = task.ptinfo
        return ActivityUsage(
            time: time, cpuTime: Self.nanoseconds(info.pti_total_user &+ info.pti_total_system), footprint: rusage.ri_phys_footprint,
            residentSize: info.pti_resident_size, threads: info.pti_threadnum, runningThreads: info.pti_numrunning,
            priority: info.pti_priority, energy: hasEnergy ? rusage.ri_energy_nj : nil, idleWakeups: rusage.ri_pkg_idle_wkups,
            interruptWakeups: rusage.ri_interrupt_wkups, diskRead: rusage.ri_diskio_bytesread, diskWritten: rusage.ri_diskio_byteswritten)
    }

    /// `rusage_info_v6`, else v4 on a kernel without v6 (its prefix: no
    /// energy). Only fields both SDKs the app is built with declare.
    private static func rusage(of pid: pid_t) -> (rusage_info_v6, Bool)? {
        var info = rusage_info_v6()
        func call(_ flavor: Int32) -> Int32 {
            withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, flavor, $0) }
            }
        }
        if call(RUSAGE_INFO_V6) == 0 { return (info, true) }
        guard errno == EINVAL, call(RUSAGE_INFO_V4) == 0 else { return nil }
        return (info, false)
    }

    /// Task times are Mach ticks (125/3 ns on Apple silicon, 1 on Intel).
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let (high, low) = ticks.multipliedFullWidth(by: timebase.numer)
        return timebase.denom > high ? timebase.denom.dividingFullWidth((high, low)).quotient : .max
    }

    func groupMembers(_ group: pid_t, limit: Int) -> [pid_t]? {
        guard group > 0, limit > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: limit)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count)) }
        guard bytes >= 0 else { return nil }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32

    /// `csops`: in libsystem_kernel, declared in no SDK header (3.3) — looked
    /// up, and Security.framework asked where it is missing.
    private static let csops: CSOps? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops").map { unsafeBitCast($0, to: CSOps.self) }

    func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer {
        guard let csops = Self.csops else { return .unavailable }
        var flags: UInt32 = 0
        // CS_OPS_STATUS is 0.
        if csops(pid, 0, &flags, MemoryLayout<UInt32>.size) == 0 { return .flags(ActivityCodeSigning(flags: flags)) }
        return errno == ESRCH ? .gone : .unavailable
    }

    func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        // A running process's code is a static code to this call; the
        // dynamic information is its status, the `CS_*` flags.
        let flags = SecCSFlags(rawValue: kSecCSDynamicInformation)
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), flags, &information) == errSecSuccess,
            let status = (information as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber
        else { return nil }
        return ActivityCodeSigning(flags: status.uint32Value)
    }

    func argumentsLength(of pid: pid_t) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        return size
    }

    func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = region.count
        guard sysctl(&mib, 3, region.baseAddress, &size, nil, 0) == 0 else { return nil }
        return size
    }

    func descriptors(of pid: pid_t) -> [proc_fdinfo]? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        errno = 0
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return errno == 0 ? [] : nil }
        // The kernel's estimate, with room for what opens in between; a
        // full buffer may have been cut, so it is read again larger.
        var capacity = Int(needed) / stride + 32
        for _ in 0..<4 {
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            errno = 0
            let bytes = buffer.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
            guard bytes > 0 else { return errno == 0 ? [] : nil }
            let count = Int(bytes) / stride
            if count < capacity {
                buffer.removeLast(capacity - count)
                return buffer
            }
            capacity *= 2
        }
        return nil
    }

    func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        return proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size ? info : nil
    }

    func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    func process(_ pid: pid_t) -> ActivityProcess? {
        guard pid >= 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // A pid nobody holds answers 0 bytes, no error.
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }
        return ProcessTable.record(info)
    }

    func auditToken(of pid: pid_t) -> ActivityAuditToken? {
        var name: mach_port_name_t = 0
        guard pid > 0, task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, name) }
        var token = audit_token_t()
        // TASK_AUDIT_TOKEN_COUNT, a macro Swift doesn't import.
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let answer = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        return answer == KERN_SUCCESS ? ActivityAuditToken(token) : nil
    }

    func path(of token: ActivityAuditToken) -> String? {
        var audit = token.token
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath_audittoken(&audit, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private typealias SignalByToken = @convention(c) (UnsafeMutablePointer<audit_token_t>, Int32) -> Int32

    /// `proc_signal_with_audittoken`: in libproc, declared with no
    /// availability (3.9) — looked up, so a system without it still starts,
    /// and `ProcessSignals` takes the identity-checked path instead.
    private static let signalByToken: SignalByToken? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_signal_with_audittoken").map {
        unsafeBitCast($0, to: SignalByToken.self)
    }

    var signalsByToken: Bool { Self.signalByToken != nil }

    func signal(_ signal: Int32, by token: ActivityAuditToken) -> Int32 {
        // Never this process nor launchd, whoever asks.
        guard token.pid > 1, token.pid != getpid() else { return EPERM }
        // The isolated-run gate, whoever holds this kernel (6.10 step 11):
        // the process holding the pid now must be the run's own.
        if let refused = ActivitySignalGate.shared.refusal(of: token.pid, kernel: self) { return refused }
        guard let call = Self.signalByToken else { return ENOSYS }
        var audit = token.token
        // It returns the errno itself — ESRCH as 3, not -1 (3.9).
        let answer = call(&audit, signal)
        return answer == -1 ? errno : answer
    }

    func signal(_ signal: Int32, pid: pid_t) -> Int32 {
        guard pid > 1, pid != getpid() else { return EPERM }
        if let refused = ActivitySignalGate.shared.refusal(of: pid, kernel: self) { return refused }
        return kill(pid, signal) == 0 ? 0 : errno
    }
}

/// A Mac a test makes (10.1): processes of any user — another user's,
/// which a unit test can't start for real — with their usage, names,
/// paths, code signing, `KERN_PROCARGS2` bytes, descriptors, sockets and
/// working folders, and a clock that moves only when told. What it was
/// asked is counted, so a test can say a read was skipped or bounded; a
/// hook runs as each call is made (`onCall`), so a test can make a call
/// cost time or hold it. Its signals reach nothing real: each is recorded
/// (`sent`), a stop and a continue change the record's state, and a
/// token answers ESRCH once its process is gone or exec'd (`exec`).
final class FakeActivityKernel: ActivityKernel, @unchecked Sendable {
    struct Process {
        var record: ActivityProcess
        /// Its counters; `time` is the clock's when read.
        var usage: ActivityUsage?
        var name: String?
        var path: String?
        var codeSigning: ActivityCodeSigning?
        /// `KERN_PROCARGS2`'s bytes (`FakeActivityKernel.arguments`).
        var arguments: [UInt8]?
        /// What an `exec` between the size query and the read put in
        /// `arguments`' place: the size asked is `arguments`', what is read
        /// these.
        var argumentsAfterExec: [UInt8]?
        var descriptors: [proc_fdinfo] = []
        var sockets: [Int32: socket_fdinfo] = [:]
        /// Its working folder (`PROC_PIDVNODEPATHINFO`).
        var folder: String?
        /// The pid's version, as an audit token carries it: each image's own,
        /// as the kernel's are — `add` gives a process one, `exec` the next.
        var image: UInt32 = 0
    }

    /// A signal the fake was asked to send.
    struct Sent: Hashable, Sendable {
        let pid: pid_t
        let signal: Int32
        /// By an audit token; false for the fallback's `kill(pid, …)`.
        let pinned: Bool
    }

    let uid: uid_t
    private let lock = NSLock()
    private var table: [pid_t: Process] = [:]
    private var clock: UInt64 = 1_000_000_000
    private var counts: [String: Int] = [:]
    private var csops = true
    private var tableRefused = false
    private var hook: (@Sendable (String) -> Void)?
    private var tokens = true
    private var tokenCall = true
    private var sends: [Sent] = []
    private var lastImage: UInt32 = 0

    init(uid: uid_t = 501) { self.uid = uid }

    // MARK: The test's side

    /// A process, its image a new one: a token taken of whatever held its
    /// pid before names nothing now.
    func add(_ process: Process) {
        lock.withLock {
            var process = process
            lastImage += 1
            process.image = lastImage
            table[process.record.pid] = process
        }
    }

    func remove(_ pid: pid_t) { _ = lock.withLock { table.removeValue(forKey: pid) } }

    func update(_ pid: pid_t, _ change: (inout Process) -> Void) {
        lock.withLock {
            guard var process = table[pid] else { return }
            change(&process)
            table[pid] = process
        }
    }

    /// Moves the clock on.
    func advance(_ nanoseconds: UInt64) { lock.withLock { clock += nanoseconds } }

    /// Without `csops`, as a system that dropped it.
    func dropCodeSigningCall() { lock.withLock { csops = false } }

    /// `KERN_PROC_ALL` refused while set, as a failing sysctl.
    func refuseTable(_ refused: Bool) { lock.withLock { tableRefused = refused } }

    /// No audit token for anyone while set, as the one same-uid process in
    /// 856 that gave none (6.10 step 6).
    func refuseTokens(_ refused: Bool) { lock.withLock { tokens = !refused } }

    /// Without `proc_signal_with_audittoken`, as a system that lacks it.
    func dropTokenSignal() { lock.withLock { tokenCall = false } }

    /// `pid` execs `path`: the same pid and start, another image — its
    /// version moved on, so a token taken before names nothing now.
    func exec(_ pid: pid_t, path: String?, name: String) {
        lock.withLock {
            guard var process = table[pid] else { return }
            lastImage += 1
            process.image = lastImage
            process.path = path
            process.name = name
            process.record = Self.record(process.record, status: process.record.status, shortName: String(name.prefix(16)))
            table[pid] = process
        }
    }

    /// The signals it was asked to send, in order.
    var sent: [Sent] { lock.withLock { sends } }

    /// `record` with another state, or another name.
    static func record(_ record: ActivityProcess, status: Int32, shortName: String? = nil) -> ActivityProcess {
        ActivityProcess(
            identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: record.terminal,
            terminalGroup: record.terminalGroup, effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID,
            status: status, flags: record.flags, ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals, nice: record.nice,
            shortName: shortName ?? record.shortName)
    }

    /// How many times `call` ("processes", "usage", "socket"…) was made.
    func count(_ call: String) -> Int { lock.withLock { counts[call] ?? 0 } }

    func resetCounts() { lock.withLock { counts = [:] } }

    /// Runs as each call but `uptime` is made, with the call's name,
    /// outside the fake's lock: a test moves the clock as a call costs, or
    /// holds a call until it lets go (a tick in flight, a folder on a
    /// mount that doesn't answer). Nil removes it.
    func onCall(_ hook: (@Sendable (String) -> Void)?) { lock.withLock { self.hook = hook } }

    private func asked<T>(_ call: String, _ body: () -> T) -> T {
        let hook = lock.withLock { () -> (@Sendable (String) -> Void)? in
            counts[call, default: 0] += 1
            return self.hook
        }
        hook?(call)
        return lock.withLock(body)
    }

    /// A process record, as `KERN_PROC_ALL` would give it. `uid` is its
    /// effective uid; its real and saved ones are `uid` unless given.
    static func record(
        pid: pid_t, start: UInt64, parent: pid_t, uid: uid_t = 501, realUID: uid_t? = nil, savedUID: uid_t? = nil, group: pid_t? = nil,
        terminal: dev_t? = nil, status: Int32 = SRUN, flags: ActivityProcess.Flags = [], ignoredSignals: UInt32 = 0, name: String = "fake"
    ) -> ActivityProcess {
        ActivityProcess(
            identity: ActivityProcessID(pid: pid, start: start), parentPID: parent, group: group ?? pid, terminal: terminal,
            terminalGroup: terminal == nil ? nil : group ?? pid, effectiveUID: uid, realUID: realUID ?? uid, savedUID: savedUID ?? uid,
            status: status, flags: flags, ignoredSignals: ignoredSignals, caughtSignals: 0, nice: 0, shortName: String(name.prefix(16)))
    }

    /// Usage counters, `time` filled in when read.
    static func usage(cpuTime: UInt64 = 0, footprint: UInt64 = 0, threads: Int32 = 1, running: Int32 = 0, energy: UInt64? = 0) -> ActivityUsage {
        ActivityUsage(
            time: 0, cpuTime: cpuTime, footprint: footprint, residentSize: footprint, threads: threads, runningThreads: running, priority: 31,
            energy: energy, idleWakeups: 0, interruptWakeups: 0, diskRead: 0, diskWritten: 0)
    }

    /// `KERN_PROCARGS2`'s layout: argc, the executable's path and NUL
    /// padding to 8 bytes, argv, the environment, an empty string, then
    /// launchd's own strings. `title`: written over argv's words in place,
    /// as libuv's `uv_set_process_title` writes it — cut to the words'
    /// area with its NUL, NULs after it to the area's end.
    static func arguments(
        executable: String, _ words: [String], environment: [String] = [], apple: [String] = ["ptr_munge="], title: String? = nil
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(words.count)) { bytes += $0 }
        bytes += Array(executable.utf8) + [0]
        while (bytes.count - 4) % 8 != 0 { bytes.append(0) }
        let wordsStart = bytes.count
        for word in words { bytes += Array(word.utf8) + [0] }
        if let title {
            let area = bytes.count - wordsStart
            let written = Array(title.utf8.prefix(max(area - 1, 0)))
            bytes.replaceSubrange(wordsStart..., with: written + [UInt8](repeating: 0, count: area - written.count))
        }
        for entry in environment { bytes += Array(entry.utf8) + [0] }
        bytes.append(0)
        for string in apple { bytes += Array(string.utf8) + [0] }
        return bytes
    }

    /// A socket descriptor of `PROC_PIDLISTFDS`'s.
    static func descriptor(_ fd: Int32, socket: Bool = true) -> proc_fdinfo {
        proc_fdinfo(proc_fd: fd, proc_fdtype: UInt32(socket ? PROX_FDTYPE_SOCKET : PROX_FDTYPE_VNODE))
    }

    /// A TCP socket as `PROC_PIDFDSOCKETINFO` gives it.
    static func tcp(
        local: String, port: UInt16, remote: String? = nil, remotePort: UInt16 = 0, state: TCPState = .listen, dualStack: Bool = false,
        handle: UInt64 = 1, backlog: Int16 = 0, backlogLimit: Int16 = 128
    ) -> socket_fdinfo {
        var info = internet(local: local, port: port, remote: remote, remotePort: remotePort, dualStack: dualStack, handle: handle)
        info.psi.soi_kind = Int32(SOCKINFO_TCP)
        info.psi.soi_protocol = IPPROTO_TCP
        info.psi.soi_type = SOCK_STREAM
        info.psi.soi_qlen = backlog
        info.psi.soi_qlimit = backlogLimit
        let ini = info.psi.soi_proto.pri_in
        info.psi.soi_proto.pri_tcp.tcpsi_ini = ini
        info.psi.soi_proto.pri_tcp.tcpsi_state = state.rawValue
        return info
    }

    /// A UDP socket.
    static func udp(local: String, port: UInt16, remote: String? = nil, remotePort: UInt16 = 0, handle: UInt64 = 1) -> socket_fdinfo {
        var info = internet(local: local, port: port, remote: remote, remotePort: remotePort, dualStack: false, handle: handle)
        info.psi.soi_kind = Int32(SOCKINFO_IN)
        info.psi.soi_protocol = IPPROTO_UDP
        info.psi.soi_type = SOCK_DGRAM
        return info
    }

    /// A unix socket.
    static func unix(handle: UInt64 = 1) -> socket_fdinfo {
        var info = socket_fdinfo()
        info.psi.soi_so = handle
        info.psi.soi_kind = Int32(SOCKINFO_UN)
        info.psi.soi_family = AF_UNIX
        info.psi.soi_type = SOCK_STREAM
        return info
    }

    /// An internet socket's common part: an IPv4 address in the v4 slot,
    /// anything with a colon in the v6 one.
    private static func internet(local: String, port: UInt16, remote: String?, remotePort: UInt16, dualStack: Bool, handle: UInt64)
        -> socket_fdinfo
    {
        var info = socket_fdinfo()
        info.psi.soi_so = handle
        let v6 = local.contains(":")
        info.psi.soi_family = v6 ? AF_INET6 : AF_INET
        var internet = in_sockinfo()
        internet.insi_vflag = UInt8(v6 ? (dualStack ? 0x3 : 0x2) : 0x1)
        internet.insi_lport = Int32(port.bigEndian)
        internet.insi_fport = Int32(remotePort.bigEndian)
        if v6 {
            inet_pton(AF_INET6, local, &internet.insi_laddr.ina_6)
            if let remote { inet_pton(AF_INET6, remote, &internet.insi_faddr.ina_6) }
        } else {
            inet_pton(AF_INET, local, &internet.insi_laddr.ina_46.i46a_addr4)
            if let remote { inet_pton(AF_INET, remote, &internet.insi_faddr.ina_46.i46a_addr4) }
        }
        info.psi.soi_proto.pri_in = internet
        return info
    }

    // MARK: ActivityKernel

    func uptime() -> UInt64 { lock.withLock { clock } }

    func processes() -> [ActivityProcess]? {
        asked("processes") { tableRefused ? nil : table.values.map(\.record).sorted { $0.pid < $1.pid } }
    }

    func usage(of pid: pid_t) -> ActivityUsage? {
        asked("usage") {
            guard let process = table[pid], process.record.effectiveUID == uid, !process.record.isZombie, let usage = process.usage else { return nil }
            return ActivityUsage(
                time: clock, cpuTime: usage.cpuTime, footprint: usage.footprint, residentSize: usage.residentSize, threads: usage.threads,
                runningThreads: usage.runningThreads, priority: usage.priority, energy: usage.energy, idleWakeups: usage.idleWakeups,
                interruptWakeups: usage.interruptWakeups, diskRead: usage.diskRead, diskWritten: usage.diskWritten)
        }
    }

    func name(of pid: pid_t) -> String? {
        asked("name") { table[pid]?.name }
    }

    func path(of pid: pid_t) -> String? { asked("path") { table[pid]?.path } }

    func groupMembers(_ group: pid_t, limit: Int) -> [pid_t]? {
        asked("groupMembers") {
            Array(table.values.map(\.record).filter { $0.group == group && !$0.isZombie }.map(\.pid).sorted().prefix(max(limit, 0)))
        }
    }

    func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer {
        asked("csops") {
            guard csops else { return .unavailable }
            guard let process = table[pid] else { return .gone }
            return process.codeSigning.map { .flags($0) } ?? .unavailable
        }
    }

    func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning? { asked("security") { table[pid]?.codeSigning } }

    func argumentsLength(of pid: pid_t) -> Int? {
        asked("argumentsLength") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.arguments?.count : nil } }
    }

    /// As XNU's `sysctl_procargsx` answers: the bytes whole when the region
    /// holds them; a region too small gets argc and the strings' last
    /// bytes — never their head — and no error.
    func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int? {
        asked("arguments") {
            guard let process = table[pid], process.record.effectiveUID == uid,
                let bytes = process.argumentsAfterExec ?? process.arguments, region.count > 4
            else { return nil }
            guard bytes.count > region.count else {
                region.copyBytes(from: bytes)
                return bytes.count
            }
            region.copyBytes(from: bytes.prefix(4))
            UnsafeMutableRawBufferPointer(rebasing: region[4...]).copyBytes(from: bytes.suffix(region.count - 4))
            return region.count
        }
    }

    func descriptors(of pid: pid_t) -> [proc_fdinfo]? {
        asked("descriptors") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.descriptors : nil } }
    }

    func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo? {
        asked("socket") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.sockets[descriptor] : nil } }
    }

    func workingDirectory(of pid: pid_t) -> String? {
        asked("folder") { table[pid].flatMap { $0.record.effectiveUID == uid && !$0.record.isZombie ? $0.folder : nil } }
    }

    func process(_ pid: pid_t) -> ActivityProcess? { asked("process") { table[pid]?.record } }

    /// As the kernel answers: the user's live processes only — a setuid
    /// one's effective uid is root's, and gives no token.
    func auditToken(of pid: pid_t) -> ActivityAuditToken? {
        asked("token") {
            guard tokens, let process = table[pid], process.record.effectiveUID == uid, !process.record.isZombie else { return nil }
            return ActivityAuditToken(pid: pid, effectiveUID: uid, realUID: process.record.realUID, version: process.image)
        }
    }

    func path(of token: ActivityAuditToken) -> String? {
        asked("tokenPath") {
            guard let process = table[token.pid], process.image == token.version, !process.record.isZombie else { return nil }
            return process.path
        }
    }

    var signalsByToken: Bool { lock.withLock { tokenCall } }

    func signal(_ signal: Int32, by token: ActivityAuditToken) -> Int32 {
        asked("signal") {
            guard tokenCall else { return ENOSYS }
            guard let process = table[token.pid], process.image == token.version, !process.record.isZombie else { return ESRCH }
            deliver(signal, to: process, pinned: true)
            return 0
        }
    }

    /// As `kill(2)` answers: a zombie takes it too.
    func signal(_ signal: Int32, pid: pid_t) -> Int32 {
        asked("kill") {
            guard pid > 1, let process = table[pid] else { return ESRCH }
            deliver(signal, to: process, pinned: false)
            return 0
        }
    }

    /// Recorded; a stop and a continue change its state. Under the lock.
    private func deliver(_ signal: Int32, to process: Process, pinned: Bool) {
        sends.append(Sent(pid: process.record.pid, signal: signal, pinned: pinned))
        guard !process.record.isZombie, signal == SIGSTOP || signal == SIGCONT else { return }
        var changed = process
        changed.record = Self.record(process.record, status: signal == SIGSTOP ? SSTOP : SRUN)
        table[process.record.pid] = changed
    }
}
