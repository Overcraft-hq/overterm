import Darwin
import Foundation
import Security

/// What the census asks the kernel (docs/design/activity/analysis.md, 7.2,
/// 10.1), as one protocol: `LiveActivityKernel` asks libproc, sysctl and
/// Mach; `FakeActivityKernel` is a whole Mac a test makes — another user's
/// processes, thousands of sockets, a clock that moves when told. Every
/// call is a plain synchronous one for the sampler's queue, never the main
/// thread. ProcessSignals' calls (the audit token, the signal, the
/// priority) join it, so a fake can say a refusal made none.
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
    /// `proc_name`: the name it runs as (`pbi_name`); the user's only.
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
}

/// A Mac a test makes (10.1): processes of any user — another user's,
/// which a unit test can't start for real — with their usage, names,
/// paths, code signing, `KERN_PROCARGS2` bytes, descriptors and sockets,
/// and a clock that moves only when told. What it was asked is counted, so
/// a test can say a read was skipped or bounded.
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
    }

    let uid: uid_t
    private let lock = NSLock()
    private var table: [pid_t: Process] = [:]
    private var clock: UInt64 = 1_000_000_000
    private var counts: [String: Int] = [:]
    private var csops = true

    init(uid: uid_t = 501) { self.uid = uid }

    // MARK: The test's side

    func add(_ process: Process) { lock.withLock { table[process.record.pid] = process } }

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

    /// How many times `call` ("processes", "usage", "socket"…) was made.
    func count(_ call: String) -> Int { lock.withLock { counts[call] ?? 0 } }

    func resetCounts() { lock.withLock { counts = [:] } }

    private func asked<T>(_ call: String, _ body: () -> T) -> T {
        lock.withLock {
            counts[call, default: 0] += 1
            return body()
        }
    }

    /// A process record, as `KERN_PROC_ALL` would give it.
    static func record(
        pid: pid_t, start: UInt64, parent: pid_t, uid: uid_t = 501, realUID: uid_t? = nil, group: pid_t? = nil, terminal: dev_t? = nil,
        status: Int32 = SRUN, flags: ActivityProcess.Flags = [], ignoredSignals: UInt32 = 0, name: String = "fake"
    ) -> ActivityProcess {
        ActivityProcess(
            identity: ActivityProcessID(pid: pid, start: start), parentPID: parent, group: group ?? pid, terminal: terminal,
            terminalGroup: terminal == nil ? nil : group ?? pid, effectiveUID: uid, realUID: realUID ?? uid, savedUID: uid, status: status,
            flags: flags, ignoredSignals: ignoredSignals, caughtSignals: 0, nice: 0, shortName: String(name.prefix(16)))
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

    func processes() -> [ActivityProcess]? { asked("processes") { table.values.map(\.record).sorted { $0.pid < $1.pid } } }

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
        asked("name") { table[pid].flatMap { $0.record.effectiveUID == uid ? $0.name : nil } }
    }

    func path(of pid: pid_t) -> String? { asked("path") { table[pid]?.path } }

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
}
