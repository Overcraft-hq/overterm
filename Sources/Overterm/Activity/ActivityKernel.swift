import AppKit
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
package protocol ActivityKernel: Sendable {
    /// The user the census reads for: `getuid()`.
    var uid: uid_t { get }
    /// `CLOCK_UPTIME_RAW`, ns: what every rate divides by.
    func uptime() -> UInt64
    /// `CLOCK_MONOTONIC_RAW`, ns: it runs while the Mac sleeps — the
    /// history's clock (6.11), where a sleep is a gap.
    func continuousTime() -> UInt64
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
    /// `PROC_PIDFDVNODEPATHINFO`: the path of the file `descriptor` holds
    /// open; nil when it holds none now, or refused. It asks the file
    /// system too: only a worktree removal's one read calls it, off the
    /// main thread, under a deadline (6.9).
    func vnodePath(of pid: pid_t, descriptor: Int32) -> String?

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
    /// `getsid`: the session `pid` is in; nil when it can't be read.
    func session(of pid: pid_t) -> pid_t?
    /// `killpg(group, signal)`: 0 when sent, else the errno. A group has no
    /// token form (6.10 step 9): `ProcessSignals.sendToGroup` lists and
    /// checks every member just before. Never a group ≤ 1 nor this
    /// process's own.
    func signal(_ signal: Int32, group: pid_t) -> Int32
    /// `setpriority`: Run in Background and back (`PRIO_DARWIN_PROCESS`),
    /// or a nice raised (`PRIO_PROCESS`) — 0 when done, else the errno. It
    /// has no token form: `ProcessSignals.setPriority` pins the process and
    /// checks it through its token just before. Never a pid ≤ 1 nor this
    /// process; in an isolated run or a unit test, the run's own only.
    func setPriority(_ change: ActivityPriorityChange, pid: pid_t) -> Int32
    /// An app asked to quit (`NSRunningApplication.terminate`), or ended
    /// without asking (`forceTerminate`), by its pid (6.10, D-23): 0 when
    /// asked; ESRCH when nothing holds `pid`; ESTALE when the app holding
    /// it now runs another executable than `executable` (what
    /// `ProcessSignals` checked through its token: a pid taken again in
    /// between is never asked); ENOENT when it is no app LaunchServices
    /// lists, or no `executable` to hold it to (nothing asked); EAGAIN
    /// when the app couldn't be asked. No token form:
    /// `ProcessSignals.quitApp` pins the process first, and falls back to
    /// a signal by its token. Never a pid ≤ 1 nor this process; in an
    /// isolated run or a unit test, the run's own only.
    func quitApp(pid: pid_t, executable: String?, force: Bool) -> Int32
    /// The system's own counters for the meters (`SystemMeterCounters`):
    /// read in the full tick; nil when they can't be read.
    func meterCounters() -> SystemMeterCounters?
    /// The process macOS holds responsible for `pid` (6.5 rule 13, D-31:
    /// `ProcessResponsibility`): nil when off, unknown, or its own.
    func responsiblePID(of pid: pid_t) -> pid_t?
    /// Whether `responsiblePID` answers at all: false when the call is
    /// missing or turned itself off, so its nil is unread, never "none".
    var readsResponsibility: Bool { get }
    /// Who holds a sleep assertion now, by pid: what it keeps awake — every
    /// user's (6.5's Preventing Sleep). Nil when it can't be read.
    func sleepAssertions() -> [pid_t: ActivitySleepHold]?
}

/// A process's audit token (`TASK_AUDIT_TOKEN`, 3.9): it names one
/// executable image of one process — its pid, and the pid's version, which
/// an `exec` moves on. A signal sent by it reaches that image or nothing:
/// once the process ended or exec'd, the call answers ESRCH.
package struct ActivityAuditToken: Hashable, Sendable {
    /// `audit_token_t`'s eight words, as the kernel fills them: libbsm's
    /// accessors read the same places (`audit_token_to_pid` the sixth).
    package let words: [UInt32]

    package init(_ token: audit_token_t) {
        words = withUnsafeBytes(of: token.val) { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// A fake's.
    package init(pid: pid_t, effectiveUID: uid_t, realUID: uid_t? = nil, version: UInt32) {
        words = [0, effectiveUID, 0, realUID ?? effectiveUID, 0, UInt32(bitPattern: pid), 0, version]
    }

    /// Who it was when the token was taken: its effective and real uids
    /// (libbsm's second and fourth words).
    package var effectiveUID: uid_t { words[1] }
    package var realUID: uid_t { words[3] }
    package var pid: pid_t { pid_t(bitPattern: words[5]) }
    /// The pid's version: an `exec` moves it on.
    package var version: UInt32 { words[7] }

    package var token: audit_token_t {
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token.val) { raw in
            for (index, word) in words.prefix(8).enumerated() { raw.storeBytes(of: word, toByteOffset: index * 4, as: UInt32.self) }
        }
        return token
    }
}

/// What `csops` said.
package enum CodeSigningAnswer: Hashable, Sendable {
    case flags(ActivityCodeSigning)
    /// The process is gone.
    case gone
    /// It can't answer here (no `csops`, or refused): Security.framework may.
    case unavailable
}

extension ActivityKernel {
    /// A kernel that knows no sleep: its uptime.
    package func continuousTime() -> UInt64 { uptime() }
    package func meterCounters() -> SystemMeterCounters? { nil }
    package func responsiblePID(of pid: pid_t) -> pid_t? { nil }
    package var readsResponsibility: Bool { false }
    package func sleepAssertions() -> [pid_t: ActivitySleepHold]? { nil }

    /// `pid`'s code signing: `csops`, else Security.framework's answer
    /// while `fallbacks` lasts (each over a millisecond); nil is unknown — never
    /// "macOS" (3.3).
    package func codeSigning(of pid: pid_t, fallbacks: inout Int) -> ActivityCodeSigning? {
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
package struct LiveActivityKernel: ActivityKernel {
    package let uid = getuid()

    package init() {
    }

    package func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    package func continuousTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

    package func meterCounters() -> SystemMeterCounters? { readMeterCounters() }

    package func sleepAssertions() -> [pid_t: ActivitySleepHold]? { ActivitySleepHold.read() }

    package func processes() -> [ActivityProcess]? {
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

    package func usage(of pid: pid_t) -> ActivityUsage? {
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

    package static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let (high, low) = ticks.multipliedFullWidth(by: timebase.numer)
        return timebase.denom > high ? timebase.denom.dividingFullWidth((high, low)).quotient : .max
    }

    package func groupMembers(_ group: pid_t, limit: Int) -> [pid_t]? {
        guard group > 0, limit > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: limit)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count)) }
        guard bytes >= 0 else { return nil }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }
    }

    package func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    package func responsiblePID(of pid: pid_t) -> pid_t? { ProcessResponsibility.responsible(for: pid) }
    package var readsResponsibility: Bool { ProcessResponsibility.isAvailable }

    package func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32

    /// `csops`: in libsystem_kernel, declared in no SDK header (3.3) — looked
    /// up, and Security.framework asked where it is missing.
    private static let csops: CSOps? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops").map { unsafeBitCast($0, to: CSOps.self) }

    package func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer {
        guard let csops = Self.csops else { return .unavailable }
        var flags: UInt32 = 0
        // CS_OPS_STATUS is 0.
        if csops(pid, 0, &flags, MemoryLayout<UInt32>.size) == 0 { return .flags(ActivityCodeSigning(flags: flags)) }
        return errno == ESRCH ? .gone : .unavailable
    }

    package func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning? {
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

    package func argumentsLength(of pid: pid_t) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        return size
    }

    package func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = region.count
        guard sysctl(&mib, 3, region.baseAddress, &size, nil, 0) == 0 else { return nil }
        return size
    }

    package func descriptors(of pid: pid_t) -> [proc_fdinfo]? {
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

    package func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        return proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size ? info : nil
    }

    package func vnodePath(of pid: pid_t, descriptor: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    package func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    package func process(_ pid: pid_t) -> ActivityProcess? {
        guard pid >= 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        // A pid nobody holds answers 0 bytes, no error.
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }
        return ProcessTable.record(info)
    }

    package func auditToken(of pid: pid_t) -> ActivityAuditToken? {
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

    package func path(of token: ActivityAuditToken) -> String? {
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

    package var signalsByToken: Bool { Self.signalByToken != nil }

    package func signal(_ signal: Int32, by token: ActivityAuditToken) -> Int32 {
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

    package func signal(_ signal: Int32, pid: pid_t) -> Int32 {
        guard pid > 1, pid != getpid() else { return EPERM }
        if let refused = ActivitySignalGate.shared.refusal(of: pid, kernel: self) { return refused }
        return kill(pid, signal) == 0 ? 0 : errno
    }

    package func session(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        let session = getsid(pid)
        return session > 0 ? session : nil
    }

    package func signal(_ signal: Int32, group: pid_t) -> Int32 {
        guard group > 1, group != getpgrp(), group != getpid() else { return EPERM }
        // The isolated-run gate, for every member the group has now.
        if ActivitySignalGate.shared.guards {
            guard let members = groupMembers(group, limit: ProcessSignals.groupLimit), !members.isEmpty else { return ESRCH }
            for member in members {
                if let refused = ActivitySignalGate.shared.refusal(of: member, kernel: self), refused != ESRCH { return refused }
            }
        }
        return killpg(group, signal) == 0 ? 0 : errno
    }

    package func setPriority(_ change: ActivityPriorityChange, pid: pid_t) -> Int32 {
        guard pid > 1, pid != getpid() else { return EPERM }
        // The isolated-run gate, as the sends make it (6.10 step 11).
        if let refused = ActivitySignalGate.shared.refusal(of: pid, kernel: self) { return refused }
        let answer: Int32
        switch change {
        // 3.9: another same-uid process's base priority goes to 4, and 0 puts it back.
        case .background: answer = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG)
        case .normal: answer = setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0)
        case .nice(let value): answer = setpriority(PRIO_PROCESS, id_t(pid), value)
        }
        return answer == 0 ? 0 : errno
    }

    package func quitApp(pid: pid_t, executable: String?, force: Bool) -> Int32 {
        guard pid > 1, pid != getpid() else { return EPERM }
        // The isolated-run gate, as the sends make it (6.10 step 11).
        if let refused = ActivitySignalGate.shared.refusal(of: pid, kernel: self) { return refused }
        // No executable to hold it to: never asked by a bare pid.
        guard let executable else { return process(pid) == nil ? ESRCH : ENOENT }
        // Thread safe (NSRunningApplication's own documentation): asked
        // off the main thread, as every send is.
        guard let app = NSRunningApplication(processIdentifier: pid) else { return process(pid) == nil ? ESRCH : ENOENT }
        let listed = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard app.executableURL?.resolvingSymlinksInPath().path == listed else { return ESTALE }
        return (force ? app.forceTerminate() : app.terminate()) ? 0 : EAGAIN
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
package final class FakeActivityKernel: ActivityKernel, @unchecked Sendable {
    package struct Process {
        package var record: ActivityProcess
        /// Its counters; `time` is the clock's when read.
        package var usage: ActivityUsage?
        package var name: String?
        package var path: String?
        package var codeSigning: ActivityCodeSigning?
        /// `KERN_PROCARGS2`'s bytes (`FakeActivityKernel.arguments`).
        package var arguments: [UInt8]?
        /// What an `exec` between the size query and the read put in
        /// `arguments`' place: the size asked is `arguments`', what is read
        /// these.
        package var argumentsAfterExec: [UInt8]?
        package var descriptors: [proc_fdinfo] = []
        package var sockets: [Int32: socket_fdinfo] = [:]
        /// Its working folder (`PROC_PIDVNODEPATHINFO`).
        package var folder: String?
        /// The files its descriptors hold open, by descriptor
        /// (`PROC_PIDFDVNODEPATHINFO`): list them in `descriptors` too, as
        /// vnodes (`descriptor(_:socket: false)`).
        package var files: [Int32: String] = [:]
        /// The pid's version, as an audit token carries it: each image's own,
        /// as the kernel's are — `add` gives a process one, `exec` the next.
        package var image: UInt32 = 0
        /// Its session (`getsid`); nil: unreadable.
        package var session: pid_t?
        /// The process macOS holds responsible for it (D-31); nil: its own.
        package var responsible: pid_t?

        package init(
            record: ActivityProcess, usage: ActivityUsage? = nil, name: String? = nil, path: String? = nil, codeSigning: ActivityCodeSigning? = nil, arguments: [UInt8]? = nil,
            argumentsAfterExec: [UInt8]? = nil, descriptors: [proc_fdinfo] = [], sockets: [Int32: socket_fdinfo] = [:], folder: String? = nil, files: [Int32: String] = [:], image: UInt32 = 0,
            session: pid_t? = nil, responsible: pid_t? = nil
        ) {
            self.record = record
            self.usage = usage
            self.name = name
            self.path = path
            self.codeSigning = codeSigning
            self.arguments = arguments
            self.argumentsAfterExec = argumentsAfterExec
            self.descriptors = descriptors
            self.sockets = sockets
            self.folder = folder
            self.files = files
            self.image = image
            self.session = session
            self.responsible = responsible
        }
    }

    /// A signal the fake was asked to send.
    package struct Sent: Hashable, Sendable {
        package let pid: pid_t
        package let signal: Int32
        /// By an audit token; false for the fallback's `kill(pid, …)`.
        package let pinned: Bool
        /// To the process group `pid` names (`killpg`).
        package var group = false
    }

    /// A priority the fake was asked to set.
    package struct Priority: Hashable, Sendable {
        package let pid: pid_t
        package let change: ActivityPriorityChange
    }

    /// An app the fake was asked to quit.
    package struct Quit: Hashable, Sendable {
        package let pid: pid_t
        package let force: Bool
    }

    package let uid: uid_t
    private let lock = NSLock()
    private var table: [pid_t: Process] = [:]
    private var reniced: [Priority] = []
    private var quits: [Quit] = []
    /// The pids LaunchServices lists as apps, and those that won't be asked.
    private var apps: Set<pid_t> = []
    /// An app's bundle executable where it isn't its running image.
    private var bundleExecutables: [pid_t: String] = [:]
    private var unaskable: Set<pid_t> = []
    private var clock: UInt64 = 1_000_000_000
    /// How long the fake Mac slept: the continuous clock's lead on uptime.
    private var slept: UInt64 = 0
    private var counts: [String: Int] = [:]
    private var csops = true
    private var tableRefused = false
    private var hook: (@Sendable (String) -> Void)?
    private var tokens = true
    private var tokenCall = true
    private var sends: [Sent] = []
    private var lastImage: UInt32 = 0
    private var meters: SystemMeterCounters?
    private var responsibility = true
    private var sleepHolds: [pid_t: ActivitySleepHold]? = [:]
    private var endsAtTerm = false

    package init(uid: uid_t = 501) { self.uid = uid }

    /// A TERM or a KILL ends the process at once, as a real one ends: gone
    /// from the table, its children reparented to launchd.
    package func endAtTerm(_ on: Bool) { lock.withLock { endsAtTerm = on } }

    // MARK: The test's side

    /// A process, its image a new one: a token taken of whatever held its
    /// pid before names nothing now.
    package func add(_ process: Process) {
        lock.withLock {
            var process = process
            lastImage += 1
            process.image = lastImage
            table[process.record.pid] = process
        }
    }

    package func remove(_ pid: pid_t) { _ = lock.withLock { table.removeValue(forKey: pid) } }

    package func update(_ pid: pid_t, _ change: (inout Process) -> Void) {
        lock.withLock {
            guard var process = table[pid] else { return }
            change(&process)
            table[pid] = process
        }
    }

    /// Moves the clock on.
    package func advance(_ nanoseconds: UInt64) { lock.withLock { clock += nanoseconds } }

    /// The Mac slept for `nanoseconds`: the continuous clock moves, uptime doesn't.
    package func sleep(_ nanoseconds: UInt64) { lock.withLock { slept += nanoseconds } }

    /// Without `csops`, as a system that dropped it.
    package func dropCodeSigningCall() { lock.withLock { csops = false } }

    /// `KERN_PROC_ALL` refused while set, as a failing sysctl.
    package func refuseTable(_ refused: Bool) { lock.withLock { tableRefused = refused } }

    /// No audit token for anyone while set, as the one same-uid process in
    /// 856 that gave none (6.10 step 6).
    package func refuseTokens(_ refused: Bool) { lock.withLock { tokens = !refused } }

    /// Without `proc_signal_with_audittoken`, as a system that lacks it.
    package func dropTokenSignal() { lock.withLock { tokenCall = false } }

    /// `pid` an app LaunchServices lists; `asked`: false when it can't be
    /// asked to quit (`terminate` answering false); `executable`: its
    /// bundle's, where the image it runs is another (a launcher that
    /// exec'd a runtime).
    package func app(_ pid: pid_t, asked: Bool = true, executable: String? = nil) {
        lock.withLock {
            apps.insert(pid)
            bundleExecutables[pid] = executable
            if asked { unaskable.remove(pid) } else { unaskable.insert(pid) }
        }
    }

    /// Without the responsibility call, as a system that lacks it or where
    /// it turned itself off (D-31): it answers nothing.
    package func dropResponsibilityCall() { lock.withLock { responsibility = false } }

    /// `pid` execs `path`: the same pid and start, another image — its
    /// version moved on, so a token taken before names nothing now.
    package func exec(_ pid: pid_t, path: String?, name: String) {
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
    package var sent: [Sent] { lock.withLock { sends } }

    /// The priorities it was asked to set, in order.
    package var priorities: [Priority] { lock.withLock { reniced } }

    /// The apps it was asked to quit, in order.
    package var quitsAsked: [Quit] { lock.withLock { quits } }

    /// `record` with another state, or another name.
    package static func record(_ record: ActivityProcess, status: Int32, shortName: String? = nil) -> ActivityProcess {
        ActivityProcess(
            identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: record.terminal,
            terminalGroup: record.terminalGroup, effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID,
            status: status, flags: record.flags, ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals, nice: record.nice,
            shortName: shortName ?? record.shortName)
    }

    /// How many times `call` ("processes", "usage", "socket"…) was made.
    package func count(_ call: String) -> Int { lock.withLock { counts[call] ?? 0 } }

    package func resetCounts() { lock.withLock { counts = [:] } }

    /// Runs as each call but `uptime` is made, with the call's name,
    /// outside the fake's lock: a test moves the clock as a call costs, or
    /// holds a call until it lets go (a tick in flight, a folder on a
    /// mount that doesn't answer). Nil removes it.
    package func onCall(_ hook: (@Sendable (String) -> Void)?) { lock.withLock { self.hook = hook } }

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
    package static func record(
        pid: pid_t, start: UInt64, parent: pid_t, uid: uid_t = 501, realUID: uid_t? = nil, savedUID: uid_t? = nil, group: pid_t? = nil,
        terminal: dev_t? = nil, status: Int32 = SRUN, flags: ActivityProcess.Flags = [], ignoredSignals: UInt32 = 0, name: String = "fake"
    ) -> ActivityProcess {
        ActivityProcess(
            identity: ActivityProcessID(pid: pid, start: start), parentPID: parent, group: group ?? pid, terminal: terminal,
            terminalGroup: terminal == nil ? nil : group ?? pid, effectiveUID: uid, realUID: realUID ?? uid, savedUID: savedUID ?? uid,
            status: status, flags: flags, ignoredSignals: ignoredSignals, caughtSignals: 0, nice: 0, shortName: String(name.prefix(16)))
    }

    /// Usage counters, `time` filled in when read.
    package static func usage(cpuTime: UInt64 = 0, footprint: UInt64 = 0, threads: Int32 = 1, running: Int32 = 0, energy: UInt64? = 0) -> ActivityUsage {
        ActivityUsage(
            time: 0, cpuTime: cpuTime, footprint: footprint, residentSize: footprint, threads: threads, runningThreads: running, priority: 31,
            energy: energy, idleWakeups: 0, interruptWakeups: 0, diskRead: 0, diskWritten: 0)
    }

    /// `KERN_PROCARGS2`'s layout: argc, the executable's path and NUL
    /// padding to 8 bytes, argv, the environment, an empty string, then
    /// launchd's own strings. `title`: written over argv's words in place,
    /// as libuv's `uv_set_process_title` writes it — cut to the words'
    /// area with its NUL, NULs after it to the area's end.
    package static func arguments(
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
    package static func descriptor(_ fd: Int32, socket: Bool = true) -> proc_fdinfo {
        proc_fdinfo(proc_fd: fd, proc_fdtype: UInt32(socket ? PROX_FDTYPE_SOCKET : PROX_FDTYPE_VNODE))
    }

    /// A TCP socket as `PROC_PIDFDSOCKETINFO` gives it.
    package static func tcp(
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
    package static func udp(local: String, port: UInt16, remote: String? = nil, remotePort: UInt16 = 0, handle: UInt64 = 1) -> socket_fdinfo {
        var info = internet(local: local, port: port, remote: remote, remotePort: remotePort, dualStack: false, handle: handle)
        info.psi.soi_kind = Int32(SOCKINFO_IN)
        info.psi.soi_protocol = IPPROTO_UDP
        info.psi.soi_type = SOCK_DGRAM
        return info
    }

    /// A unix socket; bound to `path` and accepting (`SO_ACCEPTCONN`) when
    /// `listening` (D-32).
    package static func unix(handle: UInt64 = 1, path: String? = nil, listening: Bool = false) -> socket_fdinfo {
        var info = socket_fdinfo()
        info.psi.soi_so = handle
        info.psi.soi_kind = Int32(SOCKINFO_UN)
        info.psi.soi_family = AF_UNIX
        info.psi.soi_type = SOCK_STREAM
        if listening { info.psi.soi_options = Int16(SO_ACCEPTCONN) }
        if let path {
            withUnsafeMutableBytes(of: &info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { raw in
                let bytes = Array(path.utf8.prefix(raw.count - 1))
                raw.copyBytes(from: bytes)
            }
        }
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

    package func uptime() -> UInt64 { lock.withLock { clock } }

    package func continuousTime() -> UInt64 { lock.withLock { clock + slept } }

    package func meterCounters() -> SystemMeterCounters? { asked("meters") { meters } }

    package func sleepAssertions() -> [pid_t: ActivitySleepHold]? { asked("sleepAssertions") { sleepHolds } }

    /// Who holds a sleep assertion next (nil: unreadable).
    package func setSleepHolds(_ holds: [pid_t: ActivitySleepHold]?) { lock.withLock { sleepHolds = holds } }

    /// What the meters read next (nil: unreadable).
    package func setMeters(_ counters: SystemMeterCounters?) { lock.withLock { meters = counters } }

    package func processes() -> [ActivityProcess]? {
        asked("processes") { tableRefused ? nil : table.values.map(\.record).sorted { $0.pid < $1.pid } }
    }

    package func usage(of pid: pid_t) -> ActivityUsage? {
        asked("usage") {
            guard let process = table[pid], process.record.effectiveUID == uid, !process.record.isZombie, let usage = process.usage else { return nil }
            return ActivityUsage(
                time: clock, cpuTime: usage.cpuTime, footprint: usage.footprint, residentSize: usage.residentSize, threads: usage.threads,
                runningThreads: usage.runningThreads, priority: usage.priority, energy: usage.energy, idleWakeups: usage.idleWakeups,
                interruptWakeups: usage.interruptWakeups, diskRead: usage.diskRead, diskWritten: usage.diskWritten)
        }
    }

    package func name(of pid: pid_t) -> String? {
        asked("name") { table[pid]?.name }
    }

    package func path(of pid: pid_t) -> String? { asked("path") { table[pid]?.path } }

    package func responsiblePID(of pid: pid_t) -> pid_t? { asked("responsible") { responsibility ? table[pid]?.responsible : nil } }

    package var readsResponsibility: Bool { lock.withLock { responsibility } }

    package func groupMembers(_ group: pid_t, limit: Int) -> [pid_t]? {
        asked("groupMembers") {
            Array(table.values.map(\.record).filter { $0.group == group && !$0.isZombie }.map(\.pid).sorted().prefix(max(limit, 0)))
        }
    }

    package func codeSigningStatus(of pid: pid_t) -> CodeSigningAnswer {
        asked("csops") {
            guard csops else { return .unavailable }
            guard let process = table[pid] else { return .gone }
            return process.codeSigning.map { .flags($0) } ?? .unavailable
        }
    }

    package func securityCodeSigning(of pid: pid_t) -> ActivityCodeSigning? { asked("security") { table[pid]?.codeSigning } }

    package func argumentsLength(of pid: pid_t) -> Int? {
        asked("argumentsLength") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.arguments?.count : nil } }
    }

    /// As XNU's `sysctl_procargsx` answers: the bytes whole when the region
    /// holds them; a region too small gets argc and the strings' last
    /// bytes — never their head — and no error.
    package func readArguments(of pid: pid_t, into region: UnsafeMutableRawBufferPointer) -> Int? {
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

    package func descriptors(of pid: pid_t) -> [proc_fdinfo]? {
        asked("descriptors") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.descriptors : nil } }
    }

    package func socket(of pid: pid_t, descriptor: Int32) -> socket_fdinfo? {
        asked("socket") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.sockets[descriptor] : nil } }
    }

    package func vnodePath(of pid: pid_t, descriptor: Int32) -> String? {
        asked("vnodePath") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.files[descriptor] : nil } }
    }

    package func workingDirectory(of pid: pid_t) -> String? {
        asked("folder") { table[pid].flatMap { $0.record.effectiveUID == uid && !$0.record.isZombie ? $0.folder : nil } }
    }

    package func process(_ pid: pid_t) -> ActivityProcess? { asked("process") { table[pid]?.record } }

    /// As the kernel answers: the user's live processes only — a setuid
    /// one's effective uid is root's, and gives no token.
    package func auditToken(of pid: pid_t) -> ActivityAuditToken? {
        asked("token") {
            guard tokens, let process = table[pid], process.record.effectiveUID == uid, !process.record.isZombie else { return nil }
            return ActivityAuditToken(pid: pid, effectiveUID: uid, realUID: process.record.realUID, version: process.image)
        }
    }

    package func path(of token: ActivityAuditToken) -> String? {
        asked("tokenPath") {
            guard let process = table[token.pid], process.image == token.version, !process.record.isZombie else { return nil }
            return process.path
        }
    }

    package var signalsByToken: Bool { lock.withLock { tokenCall } }

    package func signal(_ signal: Int32, by token: ActivityAuditToken) -> Int32 {
        asked("signal") {
            guard tokenCall else { return ENOSYS }
            guard let process = table[token.pid], process.image == token.version, !process.record.isZombie else { return ESRCH }
            deliver(signal, to: process, pinned: true)
            return 0
        }
    }

    /// As `kill(2)` answers: a zombie takes it too.
    package func signal(_ signal: Int32, pid: pid_t) -> Int32 {
        asked("kill") {
            guard pid > 1, let process = table[pid] else { return ESRCH }
            deliver(signal, to: process, pinned: false)
            return 0
        }
    }

    package func session(of pid: pid_t) -> pid_t? { asked("session") { table[pid]?.session } }

    /// As `killpg` answers: every member of the group takes it, recorded
    /// once, as the group's.
    package func signal(_ signal: Int32, group: pid_t) -> Int32 {
        asked("killpg") {
            guard group > 1 else { return EPERM }
            let members = table.values.filter { $0.record.group == group }
            guard !members.isEmpty else { return ESRCH }
            sends.append(Sent(pid: group, signal: signal, pinned: false, group: true))
            for member in members where !member.record.isZombie && (signal == SIGSTOP || signal == SIGCONT) {
                var changed = member
                changed.record = Self.record(member.record, status: signal == SIGSTOP ? SSTOP : SRUN)
                table[member.record.pid] = changed
            }
            return 0
        }
    }

    /// Recorded; a nice changes its record's, never downward (EACCES, as
    /// the kernel answers the user).
    package func setPriority(_ change: ActivityPriorityChange, pid: pid_t) -> Int32 {
        asked("priority") {
            guard pid > 1, var process = table[pid], !process.record.isZombie else { return ESRCH }
            if case .nice(let value) = change {
                guard value >= Int32(process.record.nice) else { return EACCES }
                let record = process.record
                process.record = ActivityProcess(
                    identity: record.identity, parentPID: record.parentPID, group: record.group, terminal: record.terminal,
                    terminalGroup: record.terminalGroup, effectiveUID: record.effectiveUID, realUID: record.realUID, savedUID: record.savedUID,
                    status: record.status, flags: record.flags, ignoredSignals: record.ignoredSignals, caughtSignals: record.caughtSignals,
                    nice: Int8(clamping: value), shortName: record.shortName)
                table[pid] = process
            }
            reniced.append(Priority(pid: pid, change: change))
            return 0
        }
    }

    /// Recorded for an app it lists, its executable the one named — none
    /// named, nothing asked (ENOENT); a Force Quit ends it at once.
    package func quitApp(pid: pid_t, executable: String?, force: Bool) -> Int32 {
        asked("quit") {
            guard pid > 1, let process = table[pid], !process.record.isZombie else { return ESRCH }
            guard apps.contains(pid), let executable else { return ENOENT }
            guard (bundleExecutables[pid] ?? process.path) == executable else { return ESTALE }
            guard !unaskable.contains(pid) else { return EAGAIN }
            quits.append(Quit(pid: pid, force: force))
            if force { table.removeValue(forKey: pid) }
            return 0
        }
    }

    /// Recorded; a stop and a continue change its state. Under the lock.
    private func deliver(_ signal: Int32, to process: Process, pinned: Bool) {
        sends.append(Sent(pid: process.record.pid, signal: signal, pinned: pinned))
        if endsAtTerm, signal == SIGTERM || signal == SIGKILL {
            let pid = process.record.pid
            table.removeValue(forKey: pid)
            for (child, var orphan) in table where orphan.record.parentPID == pid {
                let r = orphan.record
                orphan.record = ActivityProcess(
                    identity: r.identity, parentPID: 1, group: r.group, terminal: r.terminal, terminalGroup: r.terminalGroup,
                    effectiveUID: r.effectiveUID, realUID: r.realUID, savedUID: r.savedUID, status: r.status, flags: r.flags,
                    ignoredSignals: r.ignoredSignals, caughtSignals: r.caughtSignals, nice: r.nice, shortName: r.shortName)
                table[child] = orphan
            }
            return
        }
        guard !process.record.isZombie, signal == SIGSTOP || signal == SIGCONT else { return }
        var changed = process
        changed.record = Self.record(process.record, status: signal == SIGSTOP ? SSTOP : SRUN)
        table[process.record.pid] = changed
    }
}
