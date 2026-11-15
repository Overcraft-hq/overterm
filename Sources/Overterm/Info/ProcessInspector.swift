import Darwin
import Foundation

/// One process in a tab's tree.
struct ProcessNode: Identifiable, Equatable {
    let pid: pid_t
    let parent: pid_t
    let name: String
    /// argv, space-joined, its secrets masked (`masked`): all a person or
    /// an agent reads of it — Tab Info's tooltip —, and only for a read
    /// that shows it (`ProcessInspector.tree`'s `commands`), else empty.
    /// The raw words never leave the read; what the checks decide from them
    /// is taken first (`argvAgent`, `resumes`), since masking can change a
    /// word they read.
    fileprivate(set) var command: String
    /// The agent argv's first word names by its base name (`claude`,
    /// `/opt/homebrew/bin/codex`): with `name`, which agent this is.
    let argvAgent: Agent?
    /// The session a Claude's `--resume <id>` or `-r <id>` picks back up,
    /// an id's hex and dashes only — Sessions' match. Masked, the `-r` of
    /// `--fork-session -r <id>` goes: a `session` flag's value looks secret.
    let resumes: String?
    /// Share of one core over the last sampling interval (100 = one full core).
    var cpuPercent: Double
    /// Resident memory in bytes.
    let memory: UInt64
    /// Where it runs.
    let workingDirectory: String?
    var children: [ProcessNode] = []

    /// A process from its raw argv: `command` masked (`masked`), the
    /// checks' facts read off the words as given — split at spaces, as the
    /// line always was.
    init(
        pid: pid_t, parent: pid_t, name: String, arguments: [String], cpuPercent: Double, memory: UInt64, workingDirectory: String?,
        children: [ProcessNode] = []
    ) {
        self.init(
            pid: pid, parent: parent, name: name, arguments: arguments, shown: Self.masked(arguments), cpuPercent: cpuPercent, memory: memory,
            workingDirectory: workingDirectory, children: children)
    }

    /// The same with `command` as the inspector has it: masked at an earlier
    /// read, or none yet — for a read that shows nothing, or until the read
    /// masks it. Only this file passes or sets one: never a raw argv.
    fileprivate init(
        pid: pid_t, parent: pid_t, name: String, arguments: [String], shown command: String, cpuPercent: Double, memory: UInt64,
        workingDirectory: String?, children: [ProcessNode] = []
    ) {
        // The line's first word: no word holds the space joining two.
        var first: Substring?
        for word in arguments {
            first = word.split(separator: " ").first
            if first != nil { break }
        }
        let agent = first.flatMap { Agent(rawValue: (String($0) as NSString).lastPathComponent) }
        self.pid = pid
        self.parent = parent
        self.name = name
        self.command = command
        argvAgent = agent
        // Claude as `AgentOverviewModel.agent(of:)` finds it: by name, or argv[0].
        let claude = name == Agent.claude.rawValue || agent == .claude
        resumes = claude ? Self.resumedSession(in: arguments.joined(separator: " ").split(separator: " ")) : nil
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.workingDirectory = workingDirectory
        self.children = children
    }

    /// `arguments` as `command` shows them: each word's secrets masked
    /// before the words are joined (`Secrets.maskArguments`) — joined
    /// first, a password with a space in it would split past the mask —,
    /// then every URL's password (`maskURLs`) and what looks like a
    /// credential (`scrubCredentials`: a bearer or a vendor's token,
    /// `token=`, a PEM block, and last base64 blobs, `maskBase64Blobs`).
    static func masked(_ arguments: [String]) -> String {
        Secrets.scrubCredentials(Secrets.maskURLs(in: Secrets.maskArguments(arguments).joined(separator: " ")))
    }

    /// The word after the first `--resume` or `-r`, when it is a session
    /// id (`ClaudeSession.isValidID`) — every session Sessions lists is.
    static func resumedSession(in words: [Substring]) -> String? {
        guard let flag = words.firstIndex(where: { $0 == "--resume" || $0 == "-r" }), flag + 1 < words.count else { return nil }
        let id = String(words[flag + 1])
        return ClaudeSession.isValidID(id) ? id : nil
    }

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
/// the tab's `OVERTERM_TAB_ID` that has left that tree (daemonized with
/// nohup/disown). The tag alone isn't enough: macOS hides the environment of
/// Apple-signed binaries (zsh, sh, sleep, git…) from other processes, so the
/// shell itself never shows it; node, python, claude, go builds do.
final class ProcessInspector: @unchecked Sendable {
    static let tagVariable = "OVERTERM_TAB_ID"

    private let lock = NSLock()
    /// pid → (start time, tag or nil): the environment read once per process.
    private var tags: [pid_t: (start: UInt64, tag: String?)] = [:]
    /// Each process's CPU time as last read, for the CPU% delta.
    private var cpu = CPUBaselines()
    /// pid → (start time, its argv's hash, its masked line): an argv is
    /// masked once while it stays as it is, not at every read — a
    /// compiler's thousands of words, read every second. Only the masked
    /// line is kept.
    private var shown: [pid_t: (start: UInt64, argv: Int, command: String)] = [:]

    /// The measured tree of a tab: the descendants of `root` (not `root`
    /// itself — for a tab that is the root-owned `login`), plus processes
    /// tagged `tag`. Blocking (a few ms, more the first time); call off the
    /// main thread. `commands`: each process's `command`, masked, for a
    /// read that shows it (Tab Info) — a compiler's thousands of words take
    /// a while to mask; a read that only decides something (which agent
    /// runs, a drop, an image paste, Suspend Tab) leaves it empty.
    func tree(root: pid_t?, tag: String?, commands: Bool = false) -> [ProcessNode] {
        lock.lock()
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
                let start = Self.startTime(bsd)
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
        // The argvs this read masks, once the lock is let go.
        var unmasked: [(pid: pid_t, start: UInt64, argv: Int, arguments: [String])] = []
        for pid in members {
            guard let bsd = infos[pid] else { continue }
            let task = Self.taskInfo(pid)
            var percent = 0.0
            // A task that can't be read (it is ending) leaves its baseline as it was.
            if let task {
                let ns = Self.nanoseconds(task.pti_total_user + task.pti_total_system)
                percent = cpu.percent(pid: pid, start: Self.startTime(bsd), cpu: ns, at: now)
            }
            let arguments = Self.arguments(of: pid)
            var command = ""
            if commands {
                let start = Self.startTime(bsd)
                let argv = arguments.hashValue
                if let known = shown[pid], known.start == start, known.argv == argv {
                    command = known.command
                } else {
                    unmasked.append((pid, start, argv, arguments))
                }
            }
            nodes[pid] = ProcessNode(
                pid: pid, parent: pid_t(bsd.pbi_ppid), name: Self.name(pid, fallback: bsd),
                arguments: arguments, shown: command,
                cpuPercent: percent, memory: task?.pti_resident_size ?? 0, workingDirectory: Self.workingDirectory(of: pid))
        }
        // Forget processes that are gone (pids get reused) — only those: one
        // outside this tree is another caller's to read (the other panes of
        // a split tab, the window's agent poll).
        tags = tags.filter { infos[$0.key] != nil }
        cpu.forgetEnded { infos[$0].map(Self.startTime) }
        shown = shown.filter { infos[$0.key].map(Self.startTime) == $0.value.start }
        lock.unlock()
        // Masked outside the lock — a compiler's thousands of words take tens
        // of ms, which the agent poll, the Agent Overview and Suspend Tab
        // would wait for —, then kept for the next read.
        if !unmasked.isEmpty {
            var masked: [(pid: pid_t, entry: (start: UInt64, argv: Int, command: String))] = []
            for item in unmasked {
                let command = ProcessNode.masked(item.arguments)
                nodes[item.pid]?.command = command
                masked.append((item.pid, (item.start, item.argv, command)))
            }
            lock.lock()
            for item in masked { shown[item.pid] = item.entry }
            lock.unlock()
        }
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

extension ProcessInspector {
    /// When a process started (µs): with its pid, which process it is — a
    /// pid is reused, the pair never.
    static func startTime(_ bsd: proc_bsdinfo) -> UInt64 {
        UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
    }

    /// Each process's CPU time as last read, whoever read it. Tab Info reads
    /// a split tab pane by pane, and the window's agent poll reads with the
    /// same inspector: a reading is the rate since that process's previous
    /// sample, by any of them. (Kept only for the tree just read, each pane's
    /// read forgot the other's, and every pane read 0%.) Held with the start
    /// time, so a reused pid never borrows another process's baseline, and
    /// forgotten only when that process is gone: bounded by the live ones.
    struct CPUBaselines {
        /// A rate spans at most this long (ns). A baseline lives as long as
        /// its process, so one read again after a while — Tab Info on a tab
        /// nobody read since — would show the gap's average as its CPU now;
        /// past this, its reading starts again, as a first one does.
        static let longestInterval: UInt64 = 15_000_000_000

        private var last: [pid_t: (start: UInt64, ns: UInt64, at: UInt64)] = [:]

        /// How many processes have one.
        var count: Int { last.count }

        /// The share of one core the process used since its previous sample
        /// (100 = one full core), `ns` its CPU time at `now`; this sample is
        /// its next baseline. 0 for its first.
        mutating func percent(pid: pid_t, start: UInt64, cpu ns: UInt64, at now: UInt64) -> Double {
            defer { last[pid] = (start, ns, now) }
            guard let previous = last[pid], previous.start == start, now > previous.at, now - previous.at <= Self.longestInterval, ns >= previous.ns
            else { return 0 }
            return Double(ns - previous.ns) / Double(now - previous.at) * 100
        }

        /// Forgets the processes that ended: a pid `started` gives no start
        /// time for, or another one (the pid reused).
        mutating func forgetEnded(started: (pid_t) -> UInt64?) {
            last = last.filter { started($0.key) == $0.value.start }
        }
    }
}
