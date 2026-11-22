import Darwin
import Foundation

/// A process an Overterm run left running, and how it is known to be the
/// run's (docs/design/activity/analysis.md, 10.5).
package struct RunLeftover: Hashable, Sendable {
    package enum Why: Hashable, Sendable {
        /// It carries the run's `OVERTERM_RUN`.
        case marker
        /// The run recorded it at spawn: a stand-in wrote its pid in the
        /// run's scratch folder, and its start is no later than that.
        case recorded
        /// Its argv names the run (`ArgvSign`).
        case sign(ArgvSign)
        /// One of the run's helpers' registries holds it
        /// (`ActivityHelperGroups`: a `TerraformRun`, a `ManagedProcess`…).
        case registered
        /// Still under the run, the app alive: a child of it, or a child's
        /// — known by its parents alone (6.9), a platform binary too,
        /// whose environment no one can read and whose argv has no sign.
        case descendant
    }

    package let identity: ActivityProcessID
    /// `p_comm`: the run's own process's name — never another's.
    package let name: String
    package let why: Why
    /// Its argv, masked (`ActivityText.command`), said by its last 160 characters:
    /// the run's own process's, so a failure says which one it was.
    package var command: String? = nil

    /// One line for a check's failure: pid, name and why.
    package var said: String {
        let how: String =
            switch why {
            case .marker: "carries the run's OVERTERM_RUN"
            case .recorded: "recorded at spawn"
            case .sign(.kubectl): "its kubectl socket folder names the run"
            case .sign(.dockerSSH): "its ssh socket names the run"
            case .sign(.databaseTunnel): "its ControlPath names the run"
            case .sign(.testScratch): "its script is in the run's scratch folder"
            case .registered: "one of the run's helpers' registries holds it"
            case .descendant: "still a child of the run"
            }
        // Its end: a script's name and its arguments, past an interpreter's long path.
        let what = command.map { " — \($0.count > 160 ? "…" + $0.suffix(160) : $0)" } ?? ""
        return "\(name) (pid \(identity.pid)): \(how)\(what)"
    }
}

/// The harness's leftover check, inside the app (10.5): at a scenario's end,
/// after `AppDelegate.endRun`, what of this run's still runs. **Never a pid
/// alone**: a process is the run's only when it started no earlier than the
/// run, its lineage passes (`lineage`: under the run, or an orphan — never
/// under anything that started before the run, as a person's own shell
/// did), and one of these holds — the run's `OVERTERM_RUN` in its
/// environment, a stand-in's own record of its pid in the scratch folder,
/// an argv sign naming the run's pid and start or its scratch folder, a
/// helper registry holding it, or, while the app lives, being under it.
/// The test harness (`Tests/OvertermE2ETests`) looks again once the app has
/// quit, by the same rules, from outside.
///
/// Only the user's own processes are read, argv masked inside the read and
/// the environment scanned for the four names alone (`ProcessArguments`);
/// nothing of a process that isn't the run's is kept or said.
package enum RunLeftovers {
    /// Why `identity` is `run`'s, from what was read of it; nil when it
    /// isn't — pure.
    package static func why(
        _ identity: ActivityProcessID, run: OvertermRun, scratch: String?, marker: String?, command: String?, recordedBy: UInt64?
    ) -> RunLeftover.Why? {
        guard identity.pid != run.pid, identity.start >= run.start else { return nil }
        if marker == run.marker { return .marker }
        if let recordedBy, identity.start <= recordedBy { return .recorded }
        for sign in ArgvSign.signs(in: command ?? "") {
            if let named = sign.run, named == run.identity { return .sign(sign) }
            if case .testScratch(let id) = sign, id == scratch { return .sign(sign) }
        }
        return nil
    }

    /// Where a process sits relative to `run`, by start-checked parent
    /// links in `table`.
    package enum Lineage: Hashable, Sendable {
        /// Its parents lead to the run itself.
        case underRun
        /// Its parents lead to launchd, each started since the run: what an
        /// exited parent left.
        case orphaned
    }

    /// `process`'s lineage, or nil when a parent on the way started before
    /// the run — a person's own shell, a terminal app — or later than its
    /// child (its pid taken again), or the walk can't be followed: then it
    /// is never the run's, whatever its argv names. Pure, bounded.
    package static func lineage(of process: ActivityProcess, run: OvertermRun, table: [pid_t: ActivityProcess]) -> Lineage? {
        var child = process
        for _ in 0..<ActivitySignalLineage.maximumDepth {
            let parentPID = child.parentPID
            if parentPID <= 1 { return .orphaned }
            guard parentPID != child.pid, let parent = table[parentPID] else { return nil }
            if parent.identity == run.identity { return .underRun }
            guard parent.identity.start >= run.start, parent.identity.start <= child.identity.start else { return nil }
            child = parent
        }
        return nil
    }

    /// The scratch folder's id: `overterm-e2e-<UUID>`'s UUID.
    package static func scratchID(of folder: URL) -> String? {
        let name = folder.lastPathComponent
        guard name.hasPrefix(ArgvSign.scratchPrefix) else { return nil }
        return String(name.dropFirst(ArgvSign.scratchPrefix.count))
    }

    /// Where a stand-in records its pid at spawn: `<scratch>/spawned/<pid>`,
    /// written by the process itself before it `exec`s.
    package static func recordFolder(in scratch: URL) -> URL { scratch.appendingPathComponent("spawned", isDirectory: true) }

    /// The shell line a stand-in runs first to record itself.
    package static func recordLine(in scratch: URL) -> String {
        let folder = recordFolder(in: scratch).path
        return "mkdir -p '\(folder)' && : > '\(folder)'/$$"
    }

    /// The pids recorded in `scratch`, each with the latest start it may
    /// have — its record's time: a pid taken again later starts after it.
    package static func recorded(in scratch: URL) -> [pid_t: UInt64] {
        let folder = recordFolder(in: scratch)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: [pid_t: UInt64] = [:]
        for name in names.prefix(10_000) {
            guard let pid = pid_t(name), pid > 1 else { continue }
            var info = stat()
            guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else { continue }
            let made = UInt64(max(info.st_mtimespec.tv_sec, 0)) * 1_000_000 + UInt64(max(info.st_mtimespec.tv_nsec, 0)) / 1_000
            found[pid] = made
        }
        return found
    }

    /// The run's processes still running, read now — the user's own only,
    /// started since the run, their lineage passing; zombies are already
    /// gone. `registered`: the pids the run's helper registries hold now
    /// (`ActivityHelperGroups`). `descendants`: the run is this app, alive,
    /// so whatever is still under it is its own (6.9) — what has neither
    /// a readable environment nor a sign, a `/bin/sleep` a pane left, is
    /// known that way.
    package static func find(
        run: OvertermRun, scratch: URL?, kernel: some ActivityKernel = LiveActivityKernel(), registered: Set<pid_t> = [], descendants: Bool = false
    ) -> [RunLeftover] {
        let scratchID = scratch.flatMap(scratchID(of:))
        let recorded = scratch.map(recorded(in:)) ?? [:]
        let processes = kernel.processes() ?? []
        var table: [pid_t: ActivityProcess] = [:]
        for process in processes { table[process.pid] = process }
        var found: [RunLeftover] = []
        for process in processes {
            guard process.isOwn(by: kernel.uid), !process.isZombie, process.pid != run.pid, process.pid != getpid(),
                process.identity.start >= run.start, let lineage = lineage(of: process, run: run, table: table)
            else { continue }
            let read = ProcessArguments.read(process.pid, kernel: kernel, markers: true, codeSigning: nil)
            let named = why(
                process.identity, run: run, scratch: scratchID, marker: read?.markers?.run, command: read?.command,
                recordedBy: recorded[process.pid])
            let because: RunLeftover.Why? =
                named ?? (registered.contains(process.pid) ? .registered : (descendants && lineage == .underRun ? .descendant : nil))
            guard let because else { continue }
            found.append(RunLeftover(identity: process.identity, name: process.shortName, why: because, command: read?.command))
        }
        return found.sorted { $0.identity < $1.identity }
    }
}
