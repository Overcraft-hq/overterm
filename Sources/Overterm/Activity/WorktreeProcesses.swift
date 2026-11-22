import Darwin
import Foundation

/// What runs inside a worktree about to be removed (docs/design/activity/
/// analysis.md, 6.9, Removing a worktree): the user's processes whose
/// working folder is inside it, or that hold a file open inside it — a
/// database started elsewhere with `-D ./data`, a file watcher —, which
/// would otherwise keep running in a deleted folder. One read at the event,
/// off the main thread, under a deadline: each process's folder, then its
/// descriptors' paths (sweep B, 3.7). Overterm's own helpers aren't listed;
/// what a bulk Stop never takes is listed with why, and left unstopped.
package struct WorktreeProcess: Hashable, Sendable {
    package enum Via: Hashable, Sendable {
        /// Its working folder is inside.
        case folder
        /// It holds a file open inside.
        case file
    }

    package let identity: ActivityProcessID
    package let name: String
    package let path: String?
    package let via: Via
    /// Why "Stop Them and Remove" leaves it running; nil when it stops it.
    package var excluded: String?

    /// "acme-db (pid 4242) — a file open inside".
    package var line: String {
        var words = "\(name) (pid \(identity.pid)) — " + (via == .folder ? "runs in it" : "a file open inside")
        if let excluded { words += "; not stopped: \(excluded)" }
        return words
    }
}

package enum WorktreeProcesses {
    /// Descriptors read a process, at most.
    package static let descriptorLimit = 4_096

    /// `folder`'s processes as `snapshot` lists them, read now through
    /// `kernel`. `deadline`: the kernel's clock (`uptime`) past which the
    /// read stops — `complete` false then.
    package static func read(
        _ folder: String, in snapshot: ActivitySnapshot, kernel: some ActivityKernel, app: pid_t, deadline: UInt64,
        kept: Set<ActivityProcessID> = [], only: Set<ActivityProcessID>? = nil
    ) -> (found: [WorktreeProcess], complete: Bool) {
        read([folder], in: snapshot, kernel: kernel, app: app, deadline: deadline, kept: kept, only: only)
    }

    /// The same, inside any of `folders` (the worktree's path as given and
    /// resolved) in one sweep of each process's folder and descriptors.
    /// `kept`: what the person kept, never stopped here; `only`: a test
    /// run's own processes (`runsOwn`), the rest never read nor listed.
    package static func read(
        _ folders: [String], in snapshot: ActivitySnapshot, kernel: some ActivityKernel, app: pid_t, deadline: UInt64,
        kept: Set<ActivityProcessID> = [], only: Set<ActivityProcessID>? = nil
    ) -> (found: [WorktreeProcess], complete: Bool) {
        var found: [WorktreeProcess] = []
        let helpers = Set(snapshot.helpers)
        let appIdentity = snapshot.table.process(pid: app)?.identity
        func inside(_ path: String) -> Bool { folders.contains { ActivityPaneSet.isInside(path, $0) } }
        for process in snapshot.table.processes {
            guard process.pid > 1, process.pid != app, process.isOwn(by: snapshot.uid), !process.isZombie, !helpers.contains(process.identity),
                only?.contains(process.identity) ?? true,
                !(appIdentity.map { snapshot.table.descends(process.identity, from: $0) } ?? false)
            else { continue }
            if kernel.uptime() > deadline { return (found, false) }
            var via: WorktreeProcess.Via?
            if let cwd = kernel.workingDirectory(of: process.pid), inside(cwd) {
                via = .folder
            } else if let descriptors = kernel.descriptors(of: process.pid) {
                for descriptor in descriptors.prefix(descriptorLimit) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    if let path = kernel.vnodePath(of: process.pid, descriptor: descriptor.proc_fd), inside(path) {
                        via = .file
                        break
                    }
                }
            }
            guard let via, kernel.process(process.pid)?.identity == process.identity else { continue }
            let facts = snapshot.facts[process.identity]
            found.append(
                WorktreeProcess(
                    identity: process.identity, name: snapshot.name(of: process.identity) ?? process.shortName, path: facts?.path, via: via,
                    excluded: exclusion(process, facts: facts, snapshot: snapshot, kept: kept)))
        }
        return (found, true)
    }

    /// Why a bulk Stop leaves it (6.9's exclusions): the person kept it (or
    /// what started it), a terraform tool — Interrupt only, never SIGTERM —,
    /// it ignores SIGHUP, is detached on purpose, an app, in another
    /// terminal, another Overterm's.
    package static func exclusion(
        _ process: ActivityProcess, facts: ActivityFacts?, snapshot: ActivitySnapshot, kept: Set<ActivityProcessID> = []
    ) -> String? {
        if LeftBehind.isKept(process.identity, kept: kept, table: snapshot.table) { return "you kept it" }
        if TerraformCommandLine.tools.contains(ActivityPaneSet.executableName(process, facts: facts)) {
            return "terraform: Interrupt it alone, from Activity"
        }
        if process.ignoresHangup { return "it ignores SIGHUP" }
        if ActivityPaneSet.isDetachedOnPurpose(process, facts: facts) { return "detached on purpose" }
        if let path = facts?.path, ActivityPaneSet.appBundle(of: path) != nil { return "an app" }
        if process.terminal != nil { return "in a terminal" }
        if let marker = facts?.markers?.run, let run = OvertermRun(marker: marker), run.identity != OvertermRun.current.identity,
            LeftBehind.isLive(run.identity, in: snapshot.table)
        {
            return "another Overterm's"
        }
        return nil
    }

    /// A test run's own processes in `snapshot` (9.9's floor: an isolated
    /// run lists only what it spawned): registered with the signal gate,
    /// carrying the run's marker, in one of its panes' trees or carrying
    /// one of their tags — live or closed. Pure but for the gate's register.
    package static func runsOwn(
        in snapshot: ActivitySnapshot, tags: Set<String>, run: String?, gate: ActivitySignalGate = .shared
    ) -> Set<ActivityProcessID> {
        // Its panes' trees, and what carries their tags.
        var own = Set(snapshot.panes.filter { tags.contains($0.tag) }.flatMap { $0.tree + $0.tagged })
        for process in snapshot.table.processes {
            let markers = snapshot.facts[process.identity]?.markers
            if gate.isRegistered(process.identity) || (run != nil && markers?.run == run) || markers?.tab.map(tags.contains) == true {
                own.insert(process.identity)
            }
        }
        return own
    }
}
