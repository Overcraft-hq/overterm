import Darwin

/// Every process on the Mac, from one `KERN_PROC_ALL` (docs/design/activity/
/// analysis.md, 7.2): 0.4–0.9 ms for about 1,300, where walking pid by pid
/// (`children(of:)`) took 1,300 sysctls. Every reader's tree is a lookup in
/// its child map. The read is a plain synchronous call for the sampler's
/// queue, never the main thread.
///
/// Parents are linked by start time (6.5): a child's parent is the process
/// with its `ppid` that started no later than it. One that started later
/// took a dead parent's pid, and the child is a root — keyed by the pid
/// alone, it would hang under a stranger.
struct ProcessTable: Sendable {
    let processes: [ActivityProcess]
    private let byPID: [pid_t: Int]
    private let childIndexes: [pid_t: [Int]]

    init(_ processes: [ActivityProcess]) {
        var byPID: [pid_t: Int] = [:]
        byPID.reserveCapacity(processes.count)
        for (index, process) in processes.enumerated() { byPID[process.pid] = index }
        var children: [pid_t: [Int]] = [:]
        for (index, process) in processes.enumerated() {
            guard process.parentPID != process.pid, let parent = byPID[process.parentPID],
                processes[parent].identity.start <= process.identity.start
            else { continue }
            children[process.parentPID, default: []].append(index)
        }
        self.processes = processes
        self.byPID = byPID
        self.childIndexes = children
    }

    /// The live process with this pid, whoever it is now.
    func process(pid: pid_t) -> ActivityProcess? { byPID[pid].map { processes[$0] } }

    /// The process with this identity, if the table still has it (a
    /// zombie until it is reaped).
    func process(_ identity: ActivityProcessID) -> ActivityProcess? {
        guard let process = process(pid: identity.pid), process.identity == identity else { return nil }
        return process
    }

    /// Its parent, checked by start time; nil for a root.
    func parent(of identity: ActivityProcessID) -> ActivityProcess? {
        guard let child = process(identity), let parent = process(pid: child.parentPID), parent.pid != child.pid,
            parent.identity.start <= child.identity.start
        else { return nil }
        return parent
    }

    /// Its children, oldest first.
    func children(of identity: ActivityProcessID) -> [ActivityProcess] {
        guard process(identity) != nil else { return [] }
        return (childIndexes[identity.pid] ?? []).map { processes[$0] }.sorted { $0.identity < $1.identity }
    }

    /// The children of whatever holds `pid` now, oldest first, as the
    /// pairing reads them (7.7): pid, start and `p_comm`, a zombie left out.
    func liveChildren(of pid: pid_t) -> [(pid: pid_t, start: UInt64, name: String)] {
        guard let parent = process(pid: pid) else { return [] }
        return children(of: parent.identity).filter { !$0.isZombie }.map { ($0.pid, $0.identity.start, $0.shortName) }
    }

    /// Everything below it, breadth first, at most `limit`.
    func descendants(of identity: ActivityProcessID, limit: Int = 10_000) -> [ActivityProcess] {
        guard process(identity) != nil else { return [] }
        var found: [ActivityProcess] = []
        var next = 0
        var parents = [identity.pid]
        while next < parents.count, found.count < limit {
            for index in childIndexes[parents[next]] ?? [] where found.count < limit {
                found.append(processes[index])
                parents.append(processes[index].pid)
            }
            next += 1
        }
        return found
    }

    /// Whether `child` sits anywhere below `ancestor`.
    func descends(_ child: ActivityProcessID, from ancestor: ActivityProcessID) -> Bool {
        var current = child
        // Bounded: a link is checked by start time, so it can't loop, but a
        // table read mid-change shouldn't be trusted to end.
        for _ in 0..<4_096 {
            guard let parent = parent(of: current) else { return false }
            if parent.identity == ancestor { return true }
            current = parent.identity
        }
        return false
    }
}

// MARK: Reading

extension ProcessTable {
    /// The table now; nil when the kernel won't give it.
    static func read(_ kernel: some ActivityKernel) -> ProcessTable? {
        kernel.processes().map(ProcessTable.init)
    }

    /// How many entries a read allows beyond the kernel's estimate: what
    /// starts between the two calls.
    static let headroom = 64

    /// `KERN_PROC_ALL`'s entries: sized by the kernel's estimate with
    /// headroom, and read again larger when the buffer came back full —
    /// ENOMEM, or every byte used, which can hide a cut. A short buffer is
    /// never trusted. `estimate` gives the bytes the kernel would need;
    /// `fill` fills a buffer, sets the bytes it wrote and gives the errno
    /// (0 for none). Pure apart from those two.
    static func readEntries(
        estimate: () -> Int?, fill: (UnsafeMutableRawBufferPointer, inout Int) -> Int32, attempts: Int = 5
    ) -> [kinfo_proc]? {
        let stride = MemoryLayout<kinfo_proc>.stride
        guard let estimated = estimate(), estimated >= 0 else { return nil }
        var capacity = estimated / stride + estimated / stride / 4 + headroom
        for _ in 0..<attempts {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity * stride, alignment: MemoryLayout<kinfo_proc>.alignment)
            defer { buffer.deallocate() }
            var written = buffer.count
            let failure = fill(buffer, &written)
            if failure == ENOMEM || (failure == 0 && written >= buffer.count) {
                capacity *= 2
                continue
            }
            guard failure == 0, written >= 0, written % stride == 0 else { return nil }
            let entries = buffer.bindMemory(to: kinfo_proc.self).prefix(written / stride)
            return Array(entries)
        }
        return nil
    }

    /// One entry as the census keeps it; nil for an empty slot.
    static func record(_ info: kinfo_proc) -> ActivityProcess? {
        let proc = info.kp_proc
        let eproc = info.kp_eproc
        guard proc.p_pid >= 0 else { return nil }
        var flags: ActivityProcess.Flags = []
        if proc.p_flag & P_TRANSLATED != 0 { flags.insert(.translated) }
        if proc.p_flag & P_TRACED != 0 { flags.insert(.traced) }
        if eproc.e_flag & Int32(EPROC_SLEADER) != 0 { flags.insert(.sessionLeader) }
        if eproc.e_flag & Int32(EPROC_CTTY) != 0 { flags.insert(.controllingTerminal) }
        // NODEV, (dev_t)-1: a macro Swift doesn't import.
        let terminal = eproc.e_tdev == -1 ? nil : eproc.e_tdev
        let name = withUnsafeBytes(of: proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ActivityProcess(
            identity: ActivityProcessID(pid: proc.p_pid, start: proc.p_starttime), parentPID: eproc.e_ppid, group: eproc.e_pgid,
            terminal: terminal, terminalGroup: terminal == nil || eproc.e_tpgid <= 0 ? nil : eproc.e_tpgid,
            effectiveUID: eproc.e_ucred.cr_uid, realUID: eproc.e_pcred.p_ruid, savedUID: eproc.e_pcred.p_svuid, status: Int32(proc.p_stat),
            flags: flags, ignoredSignals: proc.p_sigignore, caughtSignals: proc.p_sigcatch, nice: proc.p_nice, shortName: name)
    }
}
