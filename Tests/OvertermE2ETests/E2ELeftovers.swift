import Darwin
import Foundation

/// The harness's leftover check from outside (docs/design/activity/
/// analysis.md, 10.5), once the scenario's app has quit: the app checks
/// itself at its end (`E2ERunner.checkNothingLeftRunning`); this looks
/// again after it is gone, by the same rules — this target doesn't link
/// the app, so they are spelt here once more (`RunLeftovers`, `ArgvSign`).
///
/// **Never a pid alone**: a relaunched Overterm can get the app's pid. A
/// process is the run's only when it started no earlier than the run, its
/// parents lead to the run or launchd without passing anything older than
/// the run (`descends`), and its environment holds the run's `OVERTERM_RUN` — matched exactly, at an
/// entry's start, as bytes — or its argv names the run's pid and start (a
/// kubectl socket folder, Docker's ssh socket, the tunnel's ControlPath)
/// or its scratch folder. Only this user's processes are read; nothing of
/// one that isn't the run's becomes a string, is kept or is said. The
/// region read is cleared before it is freed.
struct E2ERunIdentity {
    let pid: pid_t
    /// µs since 1970.
    let start: UInt64
    let marker: String
    /// `overterm-e2e-<UUID>`'s UUID, from the app's `E2E RUN` line.
    let scratchID: String?

    var start36: String { String(start, radix: 36) }

    /// From the app's `E2E RUN <marker> <scratch>` line, when it names the
    /// app the harness started; else the harness's own read of it.
    static func make(pid: pid_t, start: UInt64, printed: String) -> E2ERunIdentity {
        for line in printed.split(separator: "\n") where line.hasPrefix("E2E RUN ") {
            let words = line.dropFirst("E2E RUN ".count).split(separator: " ")
            guard words.count == 2 else { continue }
            let parts = words[0].split(separator: ".")
            guard parts.count == 3, pid_t(parts[1]) == pid, let named = UInt64(parts[2]), named == start || start == 0 else { continue }
            let folder = (String(words[1]) as NSString).lastPathComponent
            let id = folder.hasPrefix("overterm-e2e-") ? String(folder.dropFirst("overterm-e2e-".count)) : nil
            return E2ERunIdentity(pid: pid, start: named, marker: String(words[0]), scratchID: id)
        }
        return E2ERunIdentity(pid: pid, start: start, marker: "isolated.\(pid).\(start)", scratchID: nil)
    }

    /// The argv signs that name this run (`ArgvSign`'s spellings).
    var signs: [String] {
        var signs = ["/ot-kube-\(getuid())-\(pid)-\(start36)/", "ot-docker-\(pid)-\(start36)-", "/ot-run-\(pid)-\(start36)/db-"]
        if let scratchID { signs.append("/overterm-e2e-\(scratchID)/") }
        return signs
    }
}

enum E2ELeftovers {
    struct Found {
        let pid: pid_t
        let start: UInt64
        let name: String
        let why: String
    }

    /// A process's identity and name, from the kernel.
    static func kinfo(_ pid: pid_t) -> (start: UInt64, uid: uid_t, zombie: Bool, name: String)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return describe(info)
    }

    private static func describe(_ info: kinfo_proc) -> (start: UInt64, uid: uid_t, zombie: Bool, name: String) {
        let start = UInt64(max(info.kp_proc.p_starttime.tv_sec, 0)) * 1_000_000 + UInt64(max(info.kp_proc.p_starttime.tv_usec, 0))
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (start, info.kp_eproc.e_ucred.cr_uid, Int32(info.kp_proc.p_stat) == SZOMB, name)
    }

    /// Every process now, as the kernel lists them.
    private static func all() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            size += size / 4
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            var length = table.count * MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, 4, &table, &length, nil, 0) == 0 else { continue }
            // Full: it may have grown since; read again, larger.
            if length >= table.count * MemoryLayout<kinfo_proc>.stride { continue }
            return Array(table.prefix(length / MemoryLayout<kinfo_proc>.stride))
        }
        return []
    }

    /// Whether `pid`'s parents, each started since the run and no later
    /// than its child, lead to the run itself or to launchd (an orphan's):
    /// never through what started before the run — a person's own shell,
    /// whose `grep` or `tail` may name the scratch folder. `RunLeftovers.lineage`'s rule.
    static func descends(_ pid: pid_t, run: E2ERunIdentity, table: [pid_t: (parent: pid_t, start: UInt64)]) -> Bool {
        var child = pid
        for _ in 0..<256 {
            guard let this = table[child] else { return false }
            if this.parent <= 1 { return true }
            guard this.parent != child, let parent = table[this.parent] else { return false }
            if this.parent == run.pid, parent.start == run.start { return true }
            guard parent.start >= run.start, parent.start <= this.start else { return false }
            child = this.parent
        }
        return false
    }

    /// The run's processes still running.
    static func find(_ run: E2ERunIdentity) -> [Found] {
        let uid = getuid()
        let marker = Array("OVERTERM_RUN=\(run.marker)".utf8)
        let signs = run.signs.map { Array($0.utf8) }
        let processes = all()
        var table: [pid_t: (parent: pid_t, start: UInt64)] = [:]
        for info in processes { table[info.kp_proc.p_pid] = (info.kp_eproc.e_ppid, describe(info).start) }
        var found: [Found] = []
        for info in processes {
            let pid = info.kp_proc.p_pid
            let described = describe(info)
            guard pid > 1, pid != getpid(), pid != run.pid, described.uid == uid, !described.zombie, described.start >= run.start,
                descends(pid, run: run, table: table)
            else { continue }
            guard let why = matches(pid, marker: marker, signs: signs) else { continue }
            found.append(Found(pid: pid, start: described.start, name: described.name, why: why))
        }
        return found
    }

    /// Why `pid`'s arguments and environment say it is the run's; nil
    /// when they don't, or can't be read.
    private static func matches(_ pid: pid_t, marker: [UInt8], signs: [[UInt8]]) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        let capacity = Int(argmax)
        let region = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 8)
        defer {
            memset_s(region.baseAddress, capacity, 0, capacity)
            region.deallocate()
        }
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = capacity
        guard sysctl(&mib, 3, region.baseAddress, &length, nil, 0) == 0, length > 4, length < capacity else { return nil }
        let bytes = UnsafeRawBufferPointer(rebasing: region[0..<length])
        let argc = Int(bytes.loadUnaligned(as: Int32.self))
        var index = 4
        // The executable's path, then the NULs after it.
        while index < length, bytes[index] != 0 { index += 1 }
        while index < length, bytes[index] == 0 { index += 1 }
        let argvStart = index
        var words = 0
        while index < length, words < argc {
            while index < length, bytes[index] != 0 { index += 1 }
            index += 1
            words += 1
        }
        let argv = UnsafeRawBufferPointer(rebasing: bytes[argvStart..<min(index, length)])
        for sign in signs where contains(argv, sign) { return "its argv names the run" }
        // The environment: entries from here, each matched at its start.
        while index < length {
            let entry = index
            while index < length, bytes[index] != 0 { index += 1 }
            if index - entry == marker.count, bytes[entry..<index].elementsEqual(marker) { return "carries the run's OVERTERM_RUN" }
            index += 1
        }
        return nil
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    /// Ends each by its exact identity — still that pid and start, read
    /// just before — TERM, then KILL after 5 s. These are the run's own:
    /// the app's children, or theirs.
    static func stop(_ found: [Found]) {
        func same(_ one: Found) -> Bool { kinfo(one.pid).map { $0.start == one.start && !$0.zombie } == true }
        for one in found where same(one) { kill(one.pid, SIGTERM) }
        for _ in 0..<50 where found.contains(where: same) { usleep(100_000) }
        for one in found where same(one) { kill(one.pid, SIGKILL) }
    }
}
