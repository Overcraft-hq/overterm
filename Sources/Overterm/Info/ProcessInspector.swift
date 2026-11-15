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
    /// Share of one core over the last sampling interval (100 = one full
    /// core); nil for a first sample: "—", never 0 (7.5).
    var cpuPercent: Double?
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

    /// The CPU of it and every descendant that has a rate; nil when none has.
    var totalCPU: Double? {
        let rates = flattened.compactMap(\.cpuPercent)
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }
    var totalMemory: UInt64 { memory + children.reduce(0) { $0 + $1.totalMemory } }
    var totalFootprint: UInt64 { footprint + children.reduce(0) { $0 + $1.totalFootprint } }

    /// This node and every descendant, depth-first.
    var flattened: [ProcessNode] { [self] + children.flatMap(\.flattened) }
}

/// Finds the processes belonging to a tab and measures them — a lookup in
/// the app's census (docs/design/activity/analysis.md, 7.8), the API its
/// callers had kept.
///
/// A tab's processes are everything under the `login` libghostty spawned for
/// its surface (see SurfaceProcesses for the pairing), plus anything carrying
/// the tab's `OVERTERM_TAB_ID` that has left that tree (daemonized with
/// nohup/disown). The tag alone isn't enough: macOS hides the environment of
/// Apple-signed binaries (zsh, sh, sleep, git…) from other processes, so the
/// shell itself never shows it; node, python, claude, go builds do.
///
/// The census reads them: one tick answers every pane's tree until it is a
/// tick old, where each call rescanned all 1,300 processes, and every
/// pane's CPU baselines live with their processes, where each call kept
/// only its own tree's — a split tab read pane by pane read 0% (2.4 item
/// 1). Its numbers are the census's: CPU since the last sample (none for
/// a first one), the footprint, real memory; argv masked as it was read.
final class ProcessInspector: @unchecked Sendable {
    static let tagVariable = "OVERTERM_TAB_ID"

    /// A tick at the census's default cadence: a snapshot younger than
    /// this answers a lookup with no new scan.
    static let freshness: UInt64 = 2_000_000_000

    /// The census it looks in: the app's.
    let census: ActivitySampler
    /// How old a snapshot may answer: one tick.
    let freshness: UInt64

    init(census: ActivitySampler = .app, freshness: UInt64 = ProcessInspector.freshness) {
        self.census = census
        self.freshness = freshness
    }

    /// The measured tree of a tab: the descendants of `root` (not `root`
    /// itself — for a tab that is the root-owned `login`), plus processes
    /// tagged `tag` and what they started — of those, what runs as the
    /// user and hasn't ended (`running`). Blocking — a lookup, a tick when
    /// the latest snapshot is older than `freshness` or doesn't have this
    /// pane: call off the main thread.
    ///
    /// The pane is the app context's whose `login` is `root` and whose tag
    /// is `tag`; any other (a root no pane has, a tag alone) is read as a
    /// pane of its own beside the app's, by the same tick.
    func tree(root: pid_t?, tag: String?) -> [ProcessNode] {
        guard root != nil || tag != nil else { return [] }
        func matches(_ login: ActivityProcessID?, _ paneTag: String) -> Bool {
            (root == nil || login?.pid == root) && (tag == nil || paneTag == tag)
        }
        var context = census.appContext
        if !context.panes.contains(where: { matches($0.login, $0.tag) }) {
            var login: ActivityProcessID?
            if let root {
                // Its start: what the census names it by.
                guard let process = census.kernel.process(root), !process.isZombie else { return [] }
                login = process.identity
            }
            // A tag no process carries, when none is asked for.
            context.panes.append(ActivityContext.Pane(tag: tag ?? "lookup-\(UUID().uuidString)", tab: UUID(), login: login))
        }
        func slice(in snapshot: ActivitySnapshot) -> ActivityPaneSlice? { snapshot.panes.first { matches($0.login, $0.tag) } }
        guard let snapshot = census.lookup(within: freshness, demand: ActivityDemand(.light(tabs: nil)), context: context, answers: { slice(in: $0) != nil }),
            let pane = slice(in: snapshot)
        else { return [] }
        return nodes(Self.running(tag == nil ? pane.tree : pane.placed, in: snapshot), in: snapshot)
    }

    /// Of `members`, what the old scan made a node of — the user's
    /// processes, never a zombie: `PROC_PIDTBSDINFO` refused the rest —
    /// and of the user's only what runs as the user alone, its effective,
    /// real and saved uids all theirs, as `ProcessSignals` asks (6.10).
    /// What `tree` gives is what Suspend Tab stops, by pid until its own
    /// step (7.8), and what the agent readers look in: a setuid program the
    /// pane runs (sudo, top, su) is root's, though `kill(2)` would let a
    /// SIGSTOP through by its real uid (3.2), and a zombie has ended — an
    /// agent's isn't running, and a pid recorded as stopped would wait for
    /// a bare SIGCONT. What a setuid program started as the user stays.
    /// Tab Info, which signals nothing, calls `nodes` itself and names the
    /// others too.
    static func running(_ members: [ActivityProcessID], in snapshot: ActivitySnapshot) -> [ActivityProcessID] {
        members.filter { identity in
            guard let process = snapshot.table.process(identity) else { return false }
            return process.isWhollyOwn(by: snapshot.uid) && !process.isZombie
        }
    }

    /// `members` as nodes from `snapshot`, assembled. An agent's folder is
    /// waited for when the census hasn't read it yet: the poll, Sessions and
    /// a drop read it at once (`ProcessFolders.folder(waitingFor:now:)`).
    func nodes(_ members: [ActivityProcessID], in snapshot: ActivitySnapshot) -> [ProcessNode] {
        Self.nodes(members, in: snapshot) { identity, isAgent in
            guard isAgent, case .path(let path)? = census.folders.folder(waitingFor: identity, now: census.kernel.uptime()) else { return nil }
            return path
        }
    }

    /// `members` as nodes from what `snapshot` read of them, assembled: a
    /// folder the snapshot didn't read asked of `folder` (with whether the
    /// process is an agent), never waited for by default. Pure.
    nonisolated static func nodes(
        _ members: [ActivityProcessID], in snapshot: ActivitySnapshot, folder: (ActivityProcessID, Bool) -> String? = { _, _ in nil }
    ) -> [ProcessNode] {
        var nodes: [pid_t: ProcessNode] = [:]
        for identity in members {
            guard let process = snapshot.table.process(identity) else { continue }
            let facts = snapshot.facts[identity]
            let name = snapshot.name(of: identity) ?? process.shortName
            let command = facts?.command ?? ""
            var directory: String?
            if case .path(let path)? = facts?.folder {
                directory = path
            } else {
                directory = folder(identity, Agent.of(name: name, command: command) != nil)
            }
            nodes[identity.pid] = ProcessNode(
                identity: identity, parent: process.parentPID, name: name, maskedCommand: command, cpuPercent: facts?.rates?.cpuPercent,
                footprint: facts?.usage?.footprint ?? 0, memory: facts?.usage?.residentSize ?? 0, workingDirectory: directory)
        }
        return assemble(nodes)
    }

    /// `parent`'s direct children with their start times (µs) and command
    /// names (`p_comm`), oldest first — libghostty's `login` per surface,
    /// and whatever else the app runs (git, gh). The census's child map
    /// (7.8, `ProcessTable`), of a table read now: one `KERN_PROC_ALL`
    /// (0.2–0.3 ms), where this walked every pid with a sysctl each, 16–27
    /// ms. Now, not a tick old: the pairing and a helper's close count on
    /// what has just started. A child is one whose parent started no later
    /// (6.5); a zombie is left out, so a `login` that ended before it was
    /// paired never pairs (7.10).
    static func children(of parent: pid_t, kernel: some ActivityKernel = LiveActivityKernel()) -> [(pid: pid_t, start: UInt64, name: String)] {
        ProcessTable.read(kernel)?.liveChildren(of: parent) ?? []
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
}
