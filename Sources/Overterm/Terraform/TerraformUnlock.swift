import Combine
import Foundation

/// Force unlock (analysis 2.5, 4.10, D-10, stage 2e): a stale lock
/// cleared without a terminal. Offered only from a lock Terraform's own
/// diagnostic named in this window (`TerraformLockInfo`, never a
/// `.lock.info` file); just before it runs, the probe
/// (`TerraformCommands.lockProbe`, `state rm -dry-run -lock-timeout=0s`
/// of an address no configuration has) must fail with the **same ID** —
/// a lock that changed hands, or one released meanwhile, is never forced.
/// The sheet names the holder and its age, says that a still-running
/// apply's state write would collide with the next run, and — on the http
/// backend (GitLab's managed state too), whose force UNLOCK goes with an
/// empty body — that it removes whatever lock is there; the root's name
/// is typed on every class (5.4). The decisions here are pure.
enum TerraformUnlock {
    /// What the probe said.
    enum Probe: Equatable, Sendable {
        /// The lock parsed is still the one holding the state.
        case held(TerraformLockInfo)
        /// Another lock holds it now: never forced.
        case changedHands(TerraformLockInfo)
        /// The probe took the lock and let it go: nothing to unlock.
        case free
        /// It couldn't tell: why, in Terraform's words.
        case failed(String)
    }

    /// The probe's answer read against the lock parsed. `stderr` is
    /// `state rm`'s text (it has no `-json`): the same "Error acquiring the
    /// state lock" diagnostic a plan's stream carries, boxed or plain.
    static func probe(parsed: TerraformLockInfo, status: Int32, stderr: String) -> Probe {
        if status == 0 { return .free }
        if let now = TerraformLockInfo.parse(text: stderr) {
            return now.id == parsed.id ? .held(now) : .changedHands(now)
        }
        // State rm locks before it reads: a state with nothing in it yet
        // still had its lock taken and given back.
        if stderr.contains("No state file was found") { return .free }
        return .failed(firstError(stderr) ?? "exit \(status)")
    }

    /// The first error of a text diagnostic, its box taken off, scrubbed.
    static func firstError(_ stderr: String) -> String? {
        TerraformEditorModel.firstError(TerraformLockInfo.unboxed(stderr).joined(separator: "\n")).map(TerraformPlan.scrub)
    }

    /// Why `probe` refuses a force unlock, or nil when it may go on.
    static func refusal(_ probe: Probe, parsed: TerraformLockInfo) -> String? {
        switch probe {
        case .held: return nil
        case .changedHands(let now):
            return "The lock changed hands: \(now.said()) — ID \(now.id), not \(parsed.id). Nothing was unlocked; plan again to see who holds it now."
        case .free: return "The lock was released meanwhile: nothing to unlock. Plan again."
        case .failed(let why): return "The lock couldn't be checked (\(why)): nothing was unlocked."
        }
    }

    /// A `force-unlock` that was interrupted — its timeout, a signal, the
    /// app quitting while it ran (`stopAll`) — may or may not have unlocked:
    /// said so, never "unlocked" nor "nothing was unlocked"; nil otherwise.
    static func interrupted(status: Int32, timedOut: Bool, stoppedMeanwhile: Bool) -> String? {
        guard timedOut || stoppedMeanwhile || status >= 128 else { return nil }
        return "terraform force-unlock was interrupted: the lock may or may not have been removed. Plan again to see whether it is still held."
    }

    /// `force-unlock`'s answer: nil when it unlocked, else why not.
    static func unlockFailure(status: Int32, stderr: String) -> String? {
        guard status != 0 else { return nil }
        return "terraform force-unlock failed: " + (firstError(stderr) ?? "exit \(status)")
    }

    /// The sheet: the root and its class, the holder and its age, what
    /// forcing it risks, the http backend's empty UNLOCK, the command; the
    /// root's name to type, on every class.
    struct Sheet: Equatable, Sendable {
        var title: String
        var scope: String
        var production: Bool
        var detail: String
        var typedName: String
        var button: String
    }

    struct Root: Sendable {
        var name: String
        var rootClass: TerraformClass
        var backend: String
        var workspace: String
        var worktree: String
    }

    static let warning = "If that run is still going, its state write will collide with the next run: force only a lock you know is stale."
    static let httpWarning =
        "An http backend (GitLab's managed state too): the unlock goes with an empty body, so it removes whatever lock is there when it arrives — even one taken after this check."

    static func sheet(root: Root, lock: TerraformLockInfo, now: Date = Date(), timeZone: TimeZone = .current, note: String? = nil) -> Sheet {
        var lines = [lock.said(now: now, timeZone: timeZone) + "."]
        lines.append("Lock ID \(TerraformPlanText.escaped(lock.id))" + (lock.age(now: now).map { " · held \($0)" } ?? ""))
        if let note { lines.append(note) }
        lines.append("Checked just now: the same lock still holds the state (state rm -dry-run of an address that doesn't exist, which changes nothing).")
        lines.append(warning)
        if lock.http { lines.append(httpWarning) }
        lines.append("Worktree \(root.worktree)")
        lines.append("terraform force-unlock -force \(TerraformPlanText.escaped(lock.id))")
        return Sheet(
            title: "Force unlock \(root.name)'s state?",
            scope: "\(root.rootClass.title.uppercased()) · \(root.name) · workspace \(root.workspace) · \(root.backend)",
            production: root.rootClass == .production, detail: lines.joined(separator: "\n"),
            typedName: TerraformApplySheet.typedName(root: root.name, workspace: root.workspace), button: "Force Unlock")
    }
}

// MARK: Who may hold it (4.10: a live terraform in that root, every pane — and every worktree)

extension TerraformUnlock {
    /// Why a force unlock is refused before anything runs, or nil: only a
    /// lock a plan shown in this window was refused by, not while one is
    /// going already, never the local backend's OS lock or HCP's, never
    /// while Overterm's own run holds the state's turn (`busy`: its lock
    /// is Overterm's own). Pure.
    static func refusalBefore(
        hasLock: Bool, shown: Bool, going: Bool, backendType: String, rootClass: TerraformClass, busy: String?
    ) -> String? {
        guard hasLock, shown, !going else { return "Force unlock is offered only for a lock a plan in this window was refused by." }
        if let why = TerraformProcessCheck.refused(.forceUnlock, backendType: backendType)
            ?? TerraformProcessCheck.refused(.forceUnlock, rootClass: rootClass)
        {
            return why
        }
        if let busy { return busy + " Its lock is Overterm's own: let it finish, or stop it — never force it." }
        return nil
    }

    /// A terraform running on this Mac when the unlock looks: its folder
    /// and the state it works on, resolved as a plan's would be (its
    /// `TF_WORKSPACE`, else the folder's `.terraform/environment`).
    struct Live: Equatable, Sendable {
        var pid: pid_t
        var folder: String?
        var identity: TerraformStateIdentity?
        var operation: String?
        var inPane: Bool
    }

    /// The live terraform that may hold this state's lock, or nil: one on
    /// the same state identity, in the root's own folder, or in the same
    /// root of another checkout (`<worktree>/<path>`: another worktree's
    /// checkout of a state whose identity couldn't be read). Pure.
    static func holder(among live: [Live], identity: TerraformStateIdentity?, root: String, path: String) -> Live? {
        let suffix = path.isEmpty || path == "." ? nil : "/" + path
        return live.first { process in
            if let identity, process.identity == identity { return true }
            guard let folder = process.folder else { return false }
            return folder == root || suffix.map { folder.hasSuffix($0) } == true
        }
    }

    static func liveRefusal(_ live: Live, name: String) -> String {
        let what = "terraform" + (live.operation.map { " " + $0 } ?? "")
        let place = live.inPane ? "in a pane" : "on this Mac (pid \(live.pid))"
        return "A \(what) is running \(place) on \(name)'s state or in a checkout of it: it may be the holder. Let it finish or stop it there — nothing was unlocked."
    }

    /// What the sheet says when the lock is this Mac's user's and no
    /// terraform of theirs was found on that state: what was looked at,
    /// and what can't be seen.
    static func note(isThisMac: Bool, name: String) -> String? {
        guard isThisMac else { return nil }
        return "No terraform of yours runs on this Mac on \(name)'s state (every process looked at just now, every worktree): one under another user, in a container or a VM isn't seen."
    }

    /// Whether the sheet says the http backend's empty UNLOCK: the root's
    /// backend says it, or the lock's text does.
    static func isHTTP(holder: TerraformLockInfo, parsed: TerraformLockInfo, backendType: String) -> Bool {
        backendType == "http" || holder.http || parsed.http
    }
}

/// The terraform processes of this user on this Mac, found for a force
/// unlock (4.10): every pid by name — terraform, tofu, terragrunt, or a
/// shell running a script of that name (the recording wrapper) — its argv,
/// folder and the names `TerraformProcess` keeps of its environment, then
/// the state its folder says. Never `pkill -f`, nothing signalled.
/// Blocking: a GCD thread's.
enum TerraformLiveProcesses {
    static func scan(limit: Int = 64) -> [TerraformProcess] {
        let uid = getuid()
        var found: [TerraformProcess] = []
        for pid in ProcessInspector.allPIDs() where pid > 0 && pid != getpid() && found.count < limit {
            guard let name = TerraformProcesses.name(of: pid),
                TerraformCommandLine.tools.contains(name) || TerraformProcesses.scriptShells.contains(name),
                ProcessInspector.bsdInfo(pid)?.pbi_uid == uid,
                let process = TerraformProcesses.inspect(pid, name: name, children: [])
            else { continue }
            found.append(process)
        }
        return found
    }

    /// `process` with the state it works on, read now from its folder.
    static func resolve(_ process: TerraformProcess, inPane: Bool) -> TerraformUnlock.Live {
        var live = TerraformUnlock.Live(
            pid: process.pid, folder: process.folder?.standardizedFileURL.path, identity: nil, operation: process.line.operation, inPane: inPane)
        if let folder = process.folder, TerraformProcesses.hasConfiguration(folder) {
            let checkout = TerraformProcesses.checkout(of: folder) ?? folder
            let facts = TerraformRootFacts.read(root: folder, checkout: checkout)
            let workspace = process.line.workspace ?? process.workspaceVariable ?? facts.workspace
            live.identity = TerraformStateIdentity.of(backend: facts.backend, workspace: workspace, root: folder)
        }
        return live
    }

    /// Every live terraform, the panes' marked, with the panes' own
    /// resolved identities (`TerraformPaneMonitor.warnings`) added.
    static func live(panePIDs: Set<pid_t>, paneIdentities: [TerraformStateIdentity]) -> [TerraformUnlock.Live] {
        scan().map { resolve($0, inPane: panePIDs.contains($0.pid)) }
            + paneIdentities.map { TerraformUnlock.Live(pid: 0, folder: nil, identity: $0, operation: nil, inPane: true) }
    }
}

extension TerraformLockInfo {
    /// The lock a text diagnostic names (`state rm`'s, `force-unlock`'s:
    /// no `-json`), boxed (`│ Error: …`) or plain; nil when none.
    static func parse(text: String) -> TerraformLockInfo? {
        let lines = unboxed(text)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Error: " + summary) }) else { return nil }
        let head = lines[start].trimmingCharacters(in: .whitespaces).dropFirst("Error: ".count)
        let detail = lines[(start + 1)...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Error: ") }.joined(separator: "\n")
        return parse(summary: String(head), detail: detail)
    }

    /// A text diagnostic's lines (the first 200), its box (`╷ │ ╵`) taken off.
    static func unboxed(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200).map { raw -> String in
            var line = String(raw)
            for prefix in ["│ ", "│", "╷", "╵"] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
                break
            }
            return line
        }
    }
}

/// What this session's force unlocks said, by plan run: going, done, or
/// refused — the slot's line under the lock. Memory only.
@MainActor
final class TerraformUnlockModel: ObservableObject {
    static let shared = TerraformUnlockModel()

    struct Note: Equatable {
        var text: String
        var unlocked: Bool
    }

    @Published private(set) var going: Set<String> = []
    @Published private(set) var notes: [String: Note] = [:]

    func began(_ run: String) {
        going.insert(run)
        notes[run] = nil
    }

    func ended(_ run: String, _ note: Note?) {
        going.remove(run)
        notes[run] = note
    }
}
