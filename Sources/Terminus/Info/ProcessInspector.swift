import Darwin
import Foundation

/// One process in a tab's tree.
struct ProcessNode: Identifiable, Equatable {
    let pid: pid_t
    let parent: pid_t
    let name: String
    /// argv, space-joined.
    let command: String
    /// Share of one core over the last sampling interval (100 = one full core).
    var cpuPercent: Double
    /// Resident memory in bytes.
    let memory: UInt64
    /// Where it runs.
    let workingDirectory: String?
    var children: [ProcessNode] = []

    var id: pid_t { pid }

    var totalCPU: Double { cpuPercent + children.reduce(0) { $0 + $1.totalCPU } }
    var totalMemory: UInt64 { memory + children.reduce(0) { $0 + $1.totalMemory } }

    /// This node and every descendant, depth-first.
    var flattened: [ProcessNode] { [self] + children.flatMap(\.flattened) }
}

/// Finds the processes belonging to a tab and measures them.
///
/// A tab's processes are everything under the `login` libghostty spawned for
/// its surface (see SurfaceProcesses for the pairing), plus anything carrying
/// the tab's `TERMINUS_TAB_ID` that has left that tree (daemonized with
/// nohup/disown). The tag alone isn't enough: macOS hides the environment of
/// Apple-signed binaries (zsh, sh, sleep, git…) from other processes, so the
/// shell itself never shows it; node, python, claude, go builds do.
final class ProcessInspector: @unchecked Sendable {
    static let tagVariable = "TERMINUS_TAB_ID"

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
        if let tag {
            for (pid, bsd) in infos where bsd.pbi_uid == uid && !members.contains(pid) {
                let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
                if tags[pid]?.start != start {
                    tags[pid] = (start, Self.environment(of: pid)?[Self.tagVariable])
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
            let task = Self.taskInfo(pid)
            let cpuNS = task.map { Self.nanoseconds($0.pti_total_user + $0.pti_total_system) } ?? 0
            var percent = 0.0
            if let last = lastCPU[pid], now > last.at, cpuNS >= last.ns {
                percent = Double(cpuNS - last.ns) / Double(now - last.at) * 100
            }
            lastCPU[pid] = (cpuNS, now)
            nodes[pid] = ProcessNode(
                pid: pid, parent: pid_t(bsd.pbi_ppid), name: Self.name(pid, fallback: bsd),
                command: Self.arguments(of: pid).joined(separator: " "),
                cpuPercent: percent, memory: task?.pti_resident_size ?? 0, workingDirectory: Self.workingDirectory(of: pid))
        }
        // Forget processes that are gone (pids get reused).
        tags = tags.filter { infos[$0.key] != nil }
        lastCPU = lastCPU.filter { nodes[$0.key] != nil }
        return Self.assemble(nodes)
    }

    /// This process's direct children with their start times (µs), oldest
    /// first — libghostty's `login` per surface.
    static func children(of parent: pid_t) -> [(pid: pid_t, start: UInt64)] {
        allPIDs().compactMap { pid -> (pid_t, UInt64)? in
            guard let info = kinfo(pid), info.parent == parent else { return nil }
            return (pid, info.start)
        }
        .sorted { $0.1 < $1.1 }
    }

    /// Parent and start time (µs) of any process, root-owned ones included —
    /// what `ps` uses. proc_pidinfo refuses those (libghostty's `login` is
    /// root's), so the tree's links come from here.
    static func kinfo(_ pid: pid_t) -> (parent: pid_t, start: UInt64)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return (info.kp_eproc.e_ppid, UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
    }

    /// Children under their parents; roots are nodes whose parent isn't tagged
    /// (the tab's shell, or something re-parented to launchd).
    static func assemble(_ nodes: [pid_t: ProcessNode]) -> [ProcessNode] {
        var children: [pid_t: [ProcessNode]] = [:]
        for node in nodes.values where nodes[node.parent] != nil {
            children[node.parent, default: []].append(node)
        }
        func build(_ node: ProcessNode) -> ProcessNode {
            var node = node
            node.children = (children[node.pid] ?? []).sorted { $0.pid < $1.pid }.map(build)
            return node
        }
        return nodes.values.filter { nodes[$0.parent] == nil }.sorted { $0.pid < $1.pid }.map(build)
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

    /// KERN_PROCARGS2: argc, the exec path, padding, argv[argc], then the
    /// environment, each NUL-terminated.
    static func procArgs(_ pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        // Exec path, then NUL padding.
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        var strings: [String] = []
        var start = i
        while i < bytes.count {
            if bytes[i] == 0 {
                if i > start { strings.append(String(decoding: bytes[start..<i], as: UTF8.self)) }
                if i == start, strings.count >= argc { break }  // the empty string ending the environment
                start = i + 1
            }
            i += 1
        }
        let arguments = Array(strings.prefix(argc))
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(argc) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (arguments, environment)
    }

    static func environment(of pid: pid_t) -> [String: String]? { procArgs(pid)?.environment }
    static func arguments(of pid: pid_t) -> [String] { procArgs(pid)?.arguments ?? [] }
}
