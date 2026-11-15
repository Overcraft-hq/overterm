import Darwin
import Foundation

/// One process in a tab's tree.
struct ProcessNode: Identifiable, Equatable {
    /// Its pid and when it started (docs/design/activity/analysis.md, 7.5):
    /// pids come round again within hours, so a row, a fold, a selection or
    /// a menu target keyed by the pid alone would land on whatever holds it
    /// next. The pair doesn't repeat.
    let identity: ActivityProcessID
    let parent: pid_t
    let name: String
    /// argv as every screen sees it, masked as it was read (9.3,
    /// `ActivityText.command`): secret flags, `KEY=value`, the passwords
    /// programs take in places of their own, URLs' passwords, tokens. The
    /// raw words are never kept: a tooltip over a screen share showed them.
    let maskedCommand: String
    /// Share of one core over the last sampling interval (100 = one full core).
    var cpuPercent: Double
    /// What Activity Monitor calls Memory: the footprint
    /// (`ri_phys_footprint`), what the process costs the Mac — compressed
    /// and swapped pages counted, shared ones not.
    var footprint: UInt64 = 0
    /// Real memory, resident in RAM (RSS).
    let memory: UInt64
    /// Where it runs.
    let workingDirectory: String?
    var children: [ProcessNode] = []

    var pid: pid_t { identity.pid }

    /// "pid:start": a reused pid is another process, another row.
    var id: String { identity.id }

    var totalCPU: Double { cpuPercent + children.reduce(0) { $0 + $1.totalCPU } }
    var totalMemory: UInt64 { memory + children.reduce(0) { $0 + $1.totalMemory } }
    var totalFootprint: UInt64 { footprint + children.reduce(0) { $0 + $1.totalFootprint } }

    /// This node and every descendant, depth-first.
    var flattened: [ProcessNode] { [self] + children.flatMap(\.flattened) }
}

/// Finds the processes belonging to a tab and measures them.
///
/// A tab's processes are everything under the `login` libghostty spawned for
/// its surface (see SurfaceProcesses for the pairing), plus anything carrying
/// the tab's `OVERTERM_TAB_ID` that has left that tree (daemonized with
/// nohup/disown). The tag alone isn't enough: macOS hides the environment of
/// Apple-signed binaries (zsh, sh, sleep, git…) from other processes, so the
/// shell itself never shows it; node, python, claude, go builds do.
final class ProcessInspector: @unchecked Sendable {
    static let tagVariable = "OVERTERM_TAB_ID"

    private let lock = NSLock()
    /// pid → (start time, tag or nil): the environment read once per process.
    private var tags: [pid_t: (start: UInt64, tag: String?)] = [:]
    /// pid → (cpu nanoseconds, when) for the CPU% delta.
    private var lastCPU: [pid_t: (ns: UInt64, at: UInt64)] = [:]

    /// The measured tree of a tab: the descendants of `root` (not `root`
    /// itself — for a tab that is the root-owned `login`), plus processes
    /// tagged `tag`. Blocking (a few ms, more the first time); call off the
    /// main thread.
    func tree(root: pid_t?, tag: String?) -> [ProcessNode] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let uid = getuid()

        var infos: [pid_t: proc_bsdinfo] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for pid in Self.allPIDs() where pid > 0 {
            if let bsd = Self.bsdInfo(pid) {
                infos[pid] = bsd
                children[pid_t(bsd.pbi_ppid), default: []].append(pid)
            } else if let link = Self.kinfo(pid) {
                // Another user's process (root's login): only its link is needed.
                children[link.parent, default: []].append(pid)
            }
        }

        var members = Set<pid_t>()
        if let root {
            var stack = children[root] ?? []
            while let pid = stack.popLast() {
                if members.insert(pid).inserted { stack += children[pid] ?? [] }
            }
        }
        let kernel = LiveActivityKernel()
        if let tag {
            for (pid, bsd) in infos where bsd.pbi_uid == uid && !members.contains(pid) {
                let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
                if tags[pid]?.start != start {
                    // The four markers alone, scanned in place (9.2): no
                    // other entry of the environment becomes a String.
                    tags[pid] = (start, ProcessArguments.markers(pid, kernel: kernel, codeSigning: nil)?.tab)
                }
                if tags[pid]?.tag == tag {
                    // It and everything under it.
                    var stack = [pid]
                    while let next = stack.popLast() {
                        if members.insert(next).inserted { stack += children[next] ?? [] }
                    }
                }
            }
        }

        var nodes: [pid_t: ProcessNode] = [:]
        for pid in members {
            guard let bsd = infos[pid] else { continue }
            // The task's times, its footprint and its real memory, read together.
            let usage = kernel.usage(of: pid)
            let cpuNS = usage?.cpuTime ?? 0
            var percent = 0.0
            if let last = lastCPU[pid], now > last.at, cpuNS >= last.ns {
                percent = Double(cpuNS - last.ns) / Double(now - last.at) * 100
            }
            lastCPU[pid] = (cpuNS, now)
            let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            nodes[pid] = ProcessNode(
                identity: ActivityProcessID(pid: pid, start: start), parent: pid_t(bsd.pbi_ppid), name: Self.name(pid, fallback: bsd),
                // argv masked inside the read (ProcessArguments): the raw
                // words never leave it.
                maskedCommand: ProcessArguments.read(pid, kernel: kernel, markers: false, codeSigning: nil)?.command ?? "", cpuPercent: percent,
                footprint: usage?.footprint ?? 0,
                memory: usage?.residentSize ?? 0, workingDirectory: Self.workingDirectory(of: pid))
        }
        // Forget processes that are gone (pids get reused).
        tags = tags.filter { infos[$0.key] != nil }
        lastCPU = lastCPU.filter { nodes[$0.key] != nil }
        return Self.assemble(nodes)
    }

    /// This process's direct children with their start times (µs) and
    /// command names, oldest first — libghostty's `login` per surface, and
    /// whatever else the app runs (git, gh).
    static func children(of parent: pid_t) -> [(pid: pid_t, start: UInt64, name: String)] {
        allPIDs().compactMap { pid -> (pid_t, UInt64, String)? in
            guard let proc = kinfoProc(pid), proc.kp_eproc.e_ppid == parent else { return nil }
            let start = proc.kp_proc.p_starttime
            // p_comm, from sysctl: readable for root's processes too (login).
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return (pid, UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec), name)
        }
        .sorted { $0.1 < $1.1 }
    }

    /// Parent and start time (µs) of any process, root-owned ones included —
    /// what `ps` uses. proc_pidinfo refuses those (libghostty's `login` is
    /// root's), so the tree's links come from here.
    static func kinfo(_ pid: pid_t) -> (parent: pid_t, start: UInt64)? {
        guard let info = kinfoProc(pid) else { return nil }
        let start = info.kp_proc.p_starttime
        return (info.kp_eproc.e_ppid, UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
    }

    /// The process group of `pid`'s controlling terminal that has the
    /// terminal — for a pane's `login`, whatever has the pane's keyboard.
    static func foregroundGroup(of pid: pid_t) -> pid_t? {
        guard let group = kinfoProc(pid)?.kp_eproc.e_tpgid, group > 0 else { return nil }
        return group
    }

    /// The process group `pid` is in.
    static func processGroup(of pid: pid_t) -> pid_t? {
        kinfoProc(pid)?.kp_eproc.e_pgid
    }

    private static func kinfoProc(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Children under their parents, oldest first; roots are nodes whose
    /// parent isn't among them (the tab's shell, or something re-parented to
    /// launchd). A child hangs under the node holding its parent's pid only
    /// when that one started no later (6.5): one that started later took a
    /// dead parent's pid, and the child is a root of its own.
    static func assemble(_ nodes: [pid_t: ProcessNode]) -> [ProcessNode] {
        func linked(_ node: ProcessNode) -> Bool {
            guard node.parent != node.pid, let parent = nodes[node.parent] else { return false }
            return parent.identity.start <= node.identity.start
        }
        var children: [pid_t: [ProcessNode]] = [:]
        for node in nodes.values where linked(node) {
            children[node.parent, default: []].append(node)
        }
        func build(_ node: ProcessNode) -> ProcessNode {
            var node = node
            node.children = (children[node.pid] ?? []).sorted { $0.identity < $1.identity }.map(build)
            return node
        }
        return nodes.values.filter { !linked($0) }.sorted { $0.identity < $1.identity }.map(build)
    }

    // MARK: libproc / sysctl

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(n, 0))))
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info : nil
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private static func name(_ pid: pid_t, fallback bsd: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return withUnsafeBytes(of: bsd.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// Task times are Mach absolute ticks on Apple Silicon (1 ns on Intel).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }
}
