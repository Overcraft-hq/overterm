import Darwin
import Foundation

/// A signal Activity sends (docs/design/activity/analysis.md, 6.10's Send a
/// Signal): these nine, by name. Nothing else can be asked — no number,
/// not 0, and no name or pattern of processes (`pkill`, `killall`): a
/// send names one process, by identity.
package enum ActivitySignal: String, CaseIterable, Hashable, Sendable {
    case hup = "HUP"
    case int = "INT"
    case quit = "QUIT"
    case term = "TERM"
    case usr1 = "USR1"
    case usr2 = "USR2"
    case kill = "KILL"
    case stop = "STOP"
    case cont = "CONT"

    package var number: Int32 {
        switch self {
        case .hup: SIGHUP
        case .int: SIGINT
        case .quit: SIGQUIT
        case .term: SIGTERM
        case .usr1: SIGUSR1
        case .usr2: SIGUSR2
        case .kill: SIGKILL
        case .stop: SIGSTOP
        case .cont: SIGCONT
        }
    }

    /// The command it equals, as a sheet names it: `kill -TERM 4242`.
    package func command(for pid: pid_t) -> String { "kill -\(rawValue) \(pid)" }
}

/// A priority Activity sets (6.10, 3.9): Run in Background
/// (`PRIO_DARWIN_BG`) and Run Normally (0), or a nice raised — upward
/// only: lowering it, even back to where it was, needs an administrator.
package enum ActivityPriorityChange: Hashable, Sendable {
    case background
    case normal
    /// The nice it is given, 1…20.
    case nice(Int32)

    /// The highest nice: Lower Priority ▸ 20.
    package static let lowest: Int32 = 20

    /// The command it equals, as a sheet names it: `renice 10 -p 4242`.
    package func command(for pid: pid_t) -> String {
        switch self {
        case .background: "taskpolicy -b -p \(pid)"
        case .normal: "taskpolicy -B -p \(pid)"
        case .nice(let value): "renice \(value) -p \(pid)"
        }
    }
}

/// A process as Activity listed it (6.10 step 2): its pid and start time,
/// and the executable `proc_pidpath` gave then, which a process can't fake
/// the way it can fake argv[0]. `path` is nil when it couldn't be read —
/// the executable was deleted or replaced while it runs (an app's update,
/// `brew upgrade`, a dev server rebuilt): the identity is then the pid and
/// start alone, and the sheet says why.
package struct ActivitySignalTarget: Hashable, Sendable {
    package let identity: ActivityProcessID
    package let path: String?

    package init(_ identity: ActivityProcessID, path: String?) {
        self.identity = identity
        self.path = path
    }
}

/// What a send did (6.10 steps 4–7): what the sheet says after the button.
package enum ActivitySignalAnswer: Hashable, Sendable {
    /// Sent: by its audit token (`pinned`), or — no token to be had, a
    /// single Stop — by its pid, its start and path read once more just
    /// before ("can't be pinned to this process; checked once more").
    case sent(pinned: Bool)
    /// It had ended: gone, a zombie, or its pid another process's now —
    /// `now`, that one's name: "It ended — pid 4242 is now “x”". Nothing sent.
    case ended(now: String?)
    /// The same process — its pid and start — runs another program: it
    /// exec'd since it was listed, or between the token and the send.
    /// `path` is what it runs now (the listed one again for a re-exec of
    /// its own binary), nil when it can't be read. Nothing sent: the
    /// question is asked again ("it became “x” — ask again").
    case ranAnotherProgram(path: String?)
    /// Never sent: a structural refusal, the gate, or no token for what
    /// isn't a single Stop.
    case refused(ActivitySignalRefusal)
    /// The kernel said no: its errno.
    case failed(Int32)
}

/// Why `ProcessSignals` sent nothing, whatever the caller said (6.10 step 1,
/// 9.6): each decided before any call that touches the process.
package enum ActivitySignalRefusal: Hashable, Sendable {
    /// pid ≤ 1: launchd and the kernel. 0, -1 and a group's negative id —
    /// `kill(0)`, `kill(-1)`, `killpg` — can't be named here: a send names
    /// one process.
    case system
    /// This process: Overterm itself.
    case overterm
    /// One of Overterm's own children, under one, or in a process group
    /// one of them leads (6.5 rule 2): what started it ends it — a
    /// forward's Stop, a tunnel's Disconnect, a `ManagedProcess` closed by
    /// its group, an apply's own Stop.
    case helper
    /// It doesn't run as the user alone — its effective, real and saved
    /// uids not all the user's: root's, another user's, or a setuid program
    /// the user started, even one running as the user for now, which
    /// `kill(2)` would let through (3.2), so the kernel can't be the guard.
    case notYours
    /// The isolated-run gate: not this run's own (`ActivitySignalGate`).
    case gate
    /// No audit token to be had, or no call to send by one, and not a
    /// single Stop or Interrupt: a tree, a group, a Force Quit or a bulk
    /// needs every member pinned.
    case unpinned
    /// A group's send (6.10 step 9): the process doesn't lead its group,
    /// or a member of the group isn't the leader's — not the user's alone,
    /// started before it, in another session, a pane's `login`, one of
    /// Overterm's helpers or, in an isolated run, not the run's own.
    case group
    /// A group's send under Activity's policy (6.10 step 9): a member read
    /// again just before the `killpg` is what no group Stop may reach — a
    /// pane's shell, an agent, a terraform write — though the sheet's
    /// census had none: one exec'd into it, or joined, since.
    case groupHolds
    /// A group's send with the members its sheet listed: a member read
    /// just before the `killpg` isn't one of them — it joined since (a
    /// fork, a pipeline's new stage). Nobody is signalled who wasn't listed.
    case groupChanged
    /// Lower Priority to a nice no higher than it has: nice can only be
    /// raised (3.9), so nothing is asked of the kernel.
    case niceDown

    package var reason: String {
        switch self {
        case .system: "launchd and the kernel are macOS's own: Overterm never signals them."
        case .overterm: "This is Overterm itself."
        case .helper: "One of Overterm's own processes: what started it ends it."
        case .notYours:
            "It doesn't run as you alone — root's, another user's, or a setuid program's, even one running as you for now: "
                + "Overterm signals only what runs as you."
        case .gate: "This run is isolated (a scenario or a test): it changes only its own processes."
        case .unpinned: "It can't be pinned to this process: macOS gave no audit token for it, and without one Overterm sends only a single Stop or Interrupt."
        case .group: "Its process group isn't its own alone: something in it didn't start under it, or isn't yours."
        case .groupHolds: "Its process group now holds a pane's shell, an agent or a terraform write: no group Stop reaches it — nothing was sent."
        case .groupChanged: "A process joined its group since you were asked: nothing was sent — ask again to see every member it holds now."
        case .niceDown: "Its nice is already that high or higher: nice can only be raised, and lowering it needs an administrator."
        }
    }
}

/// The isolated-run gate (6.10 step 11, 9.9). In a scenario, a layout dump
/// or a unit test — `AppEnvironment.guardsSignals` — Activity changes only
/// this run's own processes: an identity the run registered, a child it
/// spawned (by the pid and start read at spawn), or a process under a
/// `login` its own panes spawned. Anything else is refused, so a bug in a
/// scenario or a test can never signal the person's real processes during
/// `make e2e` or `make test`. In the user's app it is off, and nothing can
/// be registered.
///
/// It is checked twice. `ProcessSignals` asks its gate before a token is
/// taken, so a refusal makes no call; and `LiveActivityKernel`'s two sends
/// ask `shared` themselves before their call (`refusal(of:kernel:app:)`),
/// with this process as the app — so neither a gate nor an app handed to a
/// `ProcessSignals`, nor a caller of the kernel's own, widens what the real
/// kernel changes. A test's children are registered in `shared`.
package final class ActivitySignalGate: @unchecked Sendable {
    package static let shared = ActivitySignalGate(guards: AppEnvironment.guardsSignals)

    package let guards: Bool
    private let lock = NSLock()
    private var registered: Set<ActivityProcessID> = []

    package init(guards: Bool) { self.guards = guards }

    /// Makes `identity` this run's own. False, and nothing kept, where the
    /// gate is off: there it would loosen nothing but the helper rule.
    @discardableResult
    package func register(_ identity: ActivityProcessID) -> Bool {
        guard guards else { return false }
        lock.withLock { _ = registered.insert(identity) }
        return true
    }

    package func unregister(_ identity: ActivityProcessID) { lock.withLock { _ = registered.remove(identity) } }

    /// Whether the run registered `identity`; never where the gate is off.
    package func isRegistered(_ identity: ActivityProcessID) -> Bool { guards && lock.withLock { registered.contains(identity) } }

    /// Whether `process` is the run's own: registered, or under one of
    /// `app`'s panes' `login`s.
    package func admits(_ process: ActivityProcess, kernel: any ActivityKernel, app: pid_t) -> Bool {
        isRegistered(process.identity) || ActivitySignalLineage.of(process, kernel: kernel, app: app) == .pane
    }

    /// The check a kernel's send makes before its call: nil to go on — the
    /// gate is off, or what holds `pid` now is the run's own; else the
    /// errno it answers instead, no call made: ESRCH when nothing holds
    /// `pid`, EPERM for what isn't the run's. `app`: this process —
    /// `LiveActivityKernel` names no other; a test's fake Mac its own.
    package func refusal(of pid: pid_t, kernel: any ActivityKernel, app: pid_t = getpid()) -> Int32? {
        guard guards else { return nil }
        guard let process = kernel.process(pid) else { return ESRCH }
        return admits(process, kernel: kernel, app: app) ? nil : EPERM
    }
}

/// Where a process sits, by start-checked parent links (6.5 rules 2–4).
package enum ActivitySignalLineage: Hashable, Sendable {
    /// Under a pane's `login`: a child of this process's running setuid, as
    /// the `/usr/bin/login` libghostty spawns for every surface does.
    case pane
    /// Under one of this process's other children: what it spawned to work
    /// with (git, kubectl, ssh, a language server, terraform) — or what it
    /// is, a child of its own.
    case helper
    case elsewhere

    /// How far up a lineage is followed: process trees aren't this deep,
    /// and a table read mid-change shouldn't be trusted to end.
    package static let maximumDepth = 256

    /// Where `process` sits relative to `app`: followed up its parents
    /// while each started no later than its child (a parent that started
    /// later took a dead parent's pid), to `app` — whose pid is no one
    /// else's while it runs — or no further.
    package static func of(_ process: ActivityProcess, kernel: any ActivityKernel, app: pid_t) -> ActivitySignalLineage {
        var child = process
        for _ in 0..<maximumDepth {
            guard child.parentPID > 1, child.parentPID != child.pid, let parent = kernel.process(child.parentPID),
                parent.identity.start <= child.identity.start
            else { return .elsewhere }
            if parent.pid == app { return ProcessSignals.isPaneLogin(child, uid: kernel.uid) ? .pane : .helper }
            child = parent
        }
        return .elsewhere
    }
}

/// The process groups Overterm's helpers lead (6.5 rule 2), read now from
/// the registries that keep them — every child `ProcessGroup.spawn` makes
/// leads one (2.2): an open `ManagedProcess` (Docker's ssh forward, a
/// kubectl proxy or port-forward), a `KubeProcessRun`, a terraform
/// `TerraformRun` or plan, a detached apply this app follows. What is in
/// one is a helper's whatever its parent is now: a kubectl exec plugin
/// reparented once kubectl exited, an apply found again after a relaunch,
/// its launcher launchd's child. Each registry is read under its own lock,
/// from any thread.
package enum ActivityHelperGroups {
    package static func now() -> Set<pid_t> {
        var groups = Set(ManagedProcess.openGroups).union(KubeProcessRun.livePIDs)
        for source in lock.withLock({ sources }) { groups.formUnion(source()) }
        return groups
    }

    /// A feature's own registry of the groups it leads, read with the rest
    /// (Terraform's runs and applies): added once, as the registry is made.
    package static func register(_ source: @escaping @Sendable () -> Set<pid_t>) {
        lock.withLock { sources.append(source) }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var sources: [@Sendable () -> Set<pid_t>] = []
}

/// The one signal path (6.10, 9.6): every change Activity makes to a
/// process it didn't spawn goes here. A send names one process by the
/// identity it was listed with, and is made in this order, so that the
/// signal can only reach that process:
/// 1. refusals no call can change, before anything is read: pid ≤ 1, this
///    process;
/// 2. its structure, read now: gone, a zombie or another process's pid is
///    "ended"; one that doesn't run as the user alone — its effective,
///    real and saved uids — is refused: a setuid program the user started
///    passes `kill(2)`'s own check (3.2), as root or as the user for now;
/// 3. where it sits: one of Overterm's helpers is refused — under one of
///    its children that isn't a pane's `login`, or in a group a helper's
///    registry holds (`ActivityHelperGroups`) —, and in an isolated run
///    anything that isn't the run's own (the gate);
/// 4. the audit token, taken first; then the identity checked through it —
///    its start read after the token, the token's executable the listed
///    one — so a pid reused before the token can't be the one signalled;
/// 5. the signal, by the token. ESRCH is told apart from an exec: the same
///    start with the image's version moved on "ran another program";
/// 6. a stopped target sent TERM or INT is continued right after, so it
///    can act on it — never a traced one (6.10 step 7).
///
/// No token (a setuid process gives none, refused at step 2 anyway; a
/// same-uid one rarely fails), or no `proc_signal_with_audittoken` on this
/// macOS: only a single Stop — `kill(pid, SIGTERM)` — or a single Interrupt
/// — SIGINT, the terraform close guard's to terraform alone — falls back
/// to the pid, after one more read of its start and path (6.10 step 6).
///
/// The kernel is `ActivityKernel`: a test's fake records every call, so a
/// refusal can say it made none. Its reads are the deliberate fresh ones
/// at a button (7.1): a few sysctls and a Mach call, microseconds.
package struct ProcessSignals: Sendable {
    package let kernel: any ActivityKernel
    package let gate: ActivitySignalGate
    /// This process — Overterm, or a test process: never signalled; what
    /// descends from its children that aren't panes' `login`s is its helpers'.
    package let app: ActivityProcessID
    /// The groups Overterm's helpers lead now (`ActivityHelperGroups.now`;
    /// a test's fake Mac its own), read at each send.
    package let helperGroups: @Sendable () -> Set<pid_t>

    package init(
        kernel: any ActivityKernel = LiveActivityKernel(), gate: ActivitySignalGate = .shared, app: ActivityProcessID? = nil,
        helperGroups: @escaping @Sendable () -> Set<pid_t> = ActivityHelperGroups.now
    ) {
        self.kernel = kernel
        self.gate = gate
        self.app = app ?? kernel.process(getpid())?.identity ?? ActivityProcessID(pid: getpid(), start: 0)
        self.helperGroups = helperGroups
    }

    /// Sends `signal` to `target`. `alone`: the person asked about this one
    /// process by itself — a single Stop or Interrupt may then fall back to
    /// its pid when no token can be had; a member of a tree, a group or a
    /// bulk never does.
    package func send(_ signal: ActivitySignal, to target: ActivitySignalTarget, alone: Bool) -> ActivitySignalAnswer {
        admission(of: target.identity) ?? deliver(signal, to: target, alone: alone)
    }

    /// What refuses `identity` before its token is taken — the refusals
    /// before anything is read, its owner, Overterm's helpers and the gate
    /// —, or that it ended: nil when a send may go on.
    private func admission(of identity: ActivityProcessID) -> ActivitySignalAnswer? {
        if let refusal = Self.refusal(before: identity, app: app) { return .refused(refusal) }
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process):
            guard process.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
            if let refusal = refusal(for: process) { return .refused(refusal) }
        }
        return nil
    }

    /// `send` once `target` is admitted: by its token, its identity
    /// checked through it.
    private func deliver(_ signal: ActivitySignal, to target: ActivitySignalTarget, alone: Bool) -> ActivitySignalAnswer {
        let identity = target.identity
        // The token first: from here on, whatever holds the pid, the
        // signal can only reach the image the token names.
        guard kernel.signalsByToken, let token = kernel.auditToken(of: identity.pid) else {
            return unpinned(signal, to: target, alone: alone)
        }
        guard token.pid == identity.pid, token.effectiveUID == kernel.uid, token.realUID == kernel.uid else { return .refused(.notYours) }
        // The identity through it: the start read after the token…
        let checked: ActivityProcess
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): checked = process
        }
        guard checked.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
        // …and the token's executable the listed one.
        if let changed = changedImage(target, token: token) { return changed }
        let answer = kernel.signal(signal.number, by: token)
        guard answer == 0 else {
            // The image went between the check and the send: ended, or exec'd.
            if answer == ESRCH { return whatBecame(of: target, token: token) ?? .ended(now: nil) }
            return .failed(answer)
        }
        if Self.continues(after: signal, checked) { _ = kernel.signal(SIGCONT, by: token) }
        return .sent(pinned: true)
    }

    /// Sets `change` on `target` (6.10's Run in Background, Run Normally,
    /// Lower Priority), checked as `send` checks a signal: the refusals
    /// before anything is read, its structure read now, Overterm's helpers
    /// and the gate, the token taken first and the identity checked through
    /// it — the start read after it, its executable the listed one. Then
    /// `setpriority` by its pid, which has no token form: a pid reused in
    /// the microseconds since the check is the one race left, and the token
    /// is asked once more after the call to say so. A nice is raised only
    /// (`.niceDown` otherwise, nothing asked of the kernel). Without a token
    /// nothing is set: only a single Stop or Interrupt goes by the pid.
    package func setPriority(_ change: ActivityPriorityChange, of target: ActivitySignalTarget) -> ActivitySignalAnswer {
        let identity = target.identity
        if let refusal = Self.refusal(before: identity, app: app) { return .refused(refusal) }
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process):
            guard process.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
            if let refusal = refusal(for: process) { return .refused(refusal) }
        }
        guard let token = kernel.auditToken(of: identity.pid) else {
            switch read(identity) {
            case .ended(let now): return .ended(now: now)
            case .live: return .refused(.unpinned)
            }
        }
        guard token.pid == identity.pid, token.effectiveUID == kernel.uid, token.realUID == kernel.uid else { return .refused(.notYours) }
        let checked: ActivityProcess
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): checked = process
        }
        guard checked.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
        if let changed = changedImage(target, token: token) { return changed }
        if case .nice(let value) = change, value <= Int32(checked.nice) { return .refused(.niceDown) }
        let answer = kernel.setPriority(change, pid: identity.pid)
        guard answer == 0 else { return answer == ESRCH ? .ended(now: nil) : .failed(answer) }
        // Still the image the token names: else it ended or exec'd in between.
        guard kernel.path(of: token) != nil || target.path == nil else { return whatBecame(of: target, token: token) ?? .sent(pinned: true) }
        return .sent(pinned: true)
    }

    /// Quit… or Force Quit… for an app (6.10's apps row, D-23): checked
    /// as `send` checks a signal — the refusals before anything is read,
    /// its structure read now, Overterm's helpers and the gate, the token
    /// taken first and the identity checked through it —, then the app is
    /// asked by its pid (`NSRunningApplication.terminate`, or
    /// `forceTerminate`), which has no token form: the kernel asks only
    /// the app whose executable is the one the token named, so a pid taken
    /// again in between is never asked. One LaunchServices doesn't list,
    /// that can't be asked, whose running image isn't its bundle's
    /// executable, or whose executable can't be read is sent SIGTERM
    /// (Force Quit: SIGKILL) by its token instead — D-23's fallback. A
    /// stopped app asked to Quit is continued after, as a TERM is. No token: a Quit is a single Stop,
    /// which may go by its pid (`unpinned`); a Force Quit never does.
    package func quitApp(_ target: ActivitySignalTarget, force: Bool) -> ActivitySignalAnswer {
        let identity = target.identity
        let signal: ActivitySignal = force ? .kill : .term
        if let refusal = Self.refusal(before: identity, app: app) { return .refused(refusal) }
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process):
            guard process.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
            if let refusal = refusal(for: process) { return .refused(refusal) }
        }
        guard let token = kernel.auditToken(of: identity.pid) else { return unpinned(signal, to: target, alone: !force) }
        guard token.pid == identity.pid, token.effectiveUID == kernel.uid, token.realUID == kernel.uid else { return .refused(.notYours) }
        let checked: ActivityProcess
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): checked = process
        }
        guard checked.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
        if let changed = changedImage(target, token: token) { return changed }
        // The executable the token names now: the app asked must run it.
        // None readable, LaunchServices isn't asked by a bare pid: the
        // signal its verb equals goes by the token instead.
        guard let executable = kernel.path(of: token) ?? target.path else { return bySignal(signal, token: token, target, checked) }
        switch kernel.quitApp(pid: identity.pid, executable: executable, force: force) {
        case 0:
            // A stopped app gets its Apple Event only once it runs again.
            if Self.continues(after: signal, checked) { _ = kernel.signal(SIGCONT, by: token) }
            return .sent(pinned: true)
        case ESRCH:
            return whatBecame(of: target, token: token) ?? .ended(now: nil)
        case ESTALE:
            // LaunchServices' executable at the pid isn't the token's:
            // ended or exec'd since, or the app runs an image that isn't
            // its bundle's executable (a launcher that exec'd a runtime) —
            // the token still names the listed image, so its signal by it.
            if let became = whatBecame(of: target, token: token) { return became }
            return bySignal(signal, token: token, target, checked)
        case ENOENT, EAGAIN:
            // Not an app LaunchServices lists, or it couldn't be asked:
            // the signal its verb equals, by its token.
            return bySignal(signal, token: token, target, checked)
        case let answer:
            return .failed(answer)
        }
    }

    /// D-23's fallback: a Quit's SIGTERM or a Force Quit's SIGKILL by the
    /// token `quitApp` checked, a stopped app continued after the TERM.
    private func bySignal(
        _ signal: ActivitySignal, token: ActivityAuditToken, _ target: ActivitySignalTarget, _ checked: ActivityProcess
    ) -> ActivitySignalAnswer {
        guard kernel.signalsByToken else { return unpinned(signal, to: target, alone: signal != .kill) }
        let answer = kernel.signal(signal.number, by: token)
        guard answer == 0 else { return answer == ESRCH ? whatBecame(of: target, token: token) ?? .ended(now: nil) : .failed(answer) }
        if Self.continues(after: signal, checked) { _ = kernel.signal(SIGCONT, by: token) }
        return .sent(pinned: true)
    }

    /// How many members a group's send lists: process groups aren't this
    /// big, and one that is is refused rather than half checked.
    package static let groupLimit = 256

    /// Sends `signal` to the process group `leader` leads (6.10 step 9):
    /// a shell's job, as ⌃C would reach it. Groups have no token form, so
    /// the leader is pinned and checked as `send` checks a process, then
    /// every member is listed again (`proc_listpids(PROC_PGRP_ONLY)`) and
    /// checked right before the `killpg`: each runs as the user alone,
    /// started no earlier than the leader and in its session — what a
    /// reused group id fails —, isn't a pane's `login` nor one of
    /// Overterm's helpers, and passes the isolated-run gate. Any that
    /// doesn't refuses the whole send (`.refused(.group)`), nothing sent.
    /// `policy`: Activity's Stop Its Group — each member is also read
    /// again for what no group Stop may reach (`holdsWhatNoGroupReaches`),
    /// whatever the sheet's census said: one that exec'd into it or joined
    /// since refuses the send (`.refused(.groupHolds)`). Terraform's close
    /// guard, whose group is terraform's own and its providers', sends
    /// without it. `listed`: the members the sheet listed — a live member
    /// that isn't one of them joined since, and refuses the send
    /// (`.refused(.groupChanged)`): `killpg` reaches only who was asked about.
    package func sendToGroup(
        _ signal: ActivitySignal, leader target: ActivitySignalTarget, listed: Set<ActivityProcessID>? = nil, policy: Bool = false
    ) -> ActivitySignalAnswer {
        let identity = target.identity
        if let refusal = Self.refusal(before: identity, app: app) { return .refused(refusal) }
        let leader: ActivityProcess
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): leader = process
        }
        guard leader.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
        if let refusal = refusal(for: leader) { return .refused(refusal) }
        let group = leader.group
        guard group == leader.pid else { return .refused(.group) }
        if group == getpgrp() || kernel.process(app.pid)?.group == group { return .refused(.overterm) }
        // The leader pinned, its identity checked through its token.
        guard kernel.signalsByToken, let token = kernel.auditToken(of: identity.pid) else { return .refused(.unpinned) }
        guard token.pid == identity.pid, token.effectiveUID == kernel.uid, token.realUID == kernel.uid else { return .refused(.notYours) }
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): guard process.isWhollyOwn(by: kernel.uid), process.group == group else { return .refused(.group) }
        }
        if let changed = changedImage(target, token: token) { return changed }
        // Every member, listed again now.
        guard let members = kernel.groupMembers(group, limit: Self.groupLimit + 1) else { return .failed(EAGAIN) }
        guard members.count <= Self.groupLimit else { return .refused(.group) }
        let session = kernel.session(of: identity.pid)
        for pid in members where pid != identity.pid {
            // Gone since the list: nothing of it to signal.
            guard let member = kernel.process(pid), !member.isZombie else { continue }
            guard member.group == group, member.isWhollyOwn(by: kernel.uid), member.identity.start >= identity.start,
                !Self.isPaneLogin(member, uid: kernel.uid), refusal(for: member) == nil
            else { return .refused(.group) }
            if let session, let theirs = kernel.session(of: pid), theirs != session { return .refused(.group) }
            if let listed, !listed.contains(member.identity) { return .refused(.groupChanged) }
            if policy, holdsWhatNoGroupReaches(member) { return .refused(.groupHolds) }
        }
        let answer = kernel.signal(signal.number, group: group)
        guard answer == 0 else { return answer == ESRCH ? .ended(now: nil) : .failed(answer) }
        return .sent(pinned: true)
    }

    /// Sends `signal` to a tree's members as its sheet listed them (6.10
    /// step 8), `members` parents first: each by its own token taken now,
    /// never by its pid — a member is never `alone` —, and checked as
    /// `send` checks one. TERM, STOP and the rest go parents first, so a
    /// supervisor can't start again what follows; CONT children first. A
    /// member's answer is its own: one that ended or exec'd since the sheet
    /// is said, the rest still sent. The caller leaves out what the policy
    /// keeps out of a bulk (`ActivitySignalCheck.bulkRefusal`).
    ///
    /// Every member is admitted before any is sent to: where a member sits
    /// is read while the tree is whole. A parent's TERM reparents its
    /// children to launchd as it ends, and read after that a child was no
    /// pane's any more — the isolated runs' gate refused it, and on a slow
    /// Mac (CI's) the shell ended and both its sleeps were left running.
    /// The token is still taken at each member's own send.
    package func sendTree(_ signal: ActivitySignal, to members: [ActivitySignalTarget]) -> [(target: ActivitySignalTarget, answer: ActivitySignalAnswer)] {
        let ordered = signal == .cont ? Array(members.reversed()) : members
        let admitted = ordered.map { admission(of: $0.identity) }
        return zip(ordered, admitted).map { target, refused in (target, refused ?? deliver(signal, to: target, alone: false)) }
    }

    /// Whether `member`, read now, is what no group Stop may reach (6.10
    /// step 9): a pane's shell — a shell whose parent is a pane's `login`
    /// —, an agent by its executable's, `p_comm`'s or argv[0]'s name, or a
    /// terraform, tofu or terragrunt whose argv is a write or can't be
    /// read — the sheet's own rule (`ActivityVerbSubject`'s target).
    package func holdsWhatNoGroupReaches(_ member: ActivityProcess) -> Bool {
        let file = kernel.path(of: member.pid).map { ($0 as NSString).lastPathComponent }
        let names = Set([file, member.shortName, ProcessArguments.executableName(of: member.pid, kernel: kernel)].compactMap { $0 })
        if names.contains(where: { Agent.of(processName: $0) != nil }) { return true }
        // An agent run by an interpreter (Gemini CLI under `node`): by its argv.
        if names.contains(where: { Agent.interpreters.contains($0) || $0.hasPrefix("node") }) {
            guard let arguments = ProcessArguments.read(member.pid, kernel: kernel, markers: false, codeSigning: nil) else { return true }
            if arguments.agent != nil { return true }
        }
        if !names.isDisjoint(with: TerraformCommandLine.tools) {
            guard let command = ProcessArguments.read(member.pid, kernel: kernel, markers: false, codeSigning: nil)?.command else { return true }
            return TerraformCommandLine.parse(command, probable: false)?.isWrite == true
        }
        if !names.isDisjoint(with: ProcessRole.shells), let parent = kernel.process(member.parentPID), parent.identity.start <= member.identity.start {
            return Self.isPaneLogin(parent, uid: kernel.uid)
        }
        return false
    }

    /// The refusals made before anything is read (step 1).
    package static func refusal(before identity: ActivityProcessID, app: ActivityProcessID) -> ActivitySignalRefusal? {
        if identity.pid <= 1 { return .system }
        if identity.pid == app.pid || identity.pid == getpid() { return .overterm }
        return nil
    }

    /// Overterm's helpers, and the gate (step 3).
    private func refusal(for process: ActivityProcess) -> ActivitySignalRefusal? {
        // A test's own child is its process's child too: what the run
        // registered is its own, never a helper — and only an isolated run
        // registers anything.
        if gate.isRegistered(process.identity) { return nil }
        // In a group a helper leads, whatever its parent is now.
        if helperGroups().contains(process.group) { return .helper }
        let place = lineage(of: process)
        if place == .helper { return .helper }
        if gate.guards, place != .pane { return .gate }
        return nil
    }

    /// Where `process` sits relative to this process (`ActivitySignalLineage.of`).
    package func lineage(of process: ActivityProcess) -> ActivitySignalLineage {
        ActivitySignalLineage.of(process, kernel: kernel, app: app.pid)
    }

    /// One of this process's children that is a pane's `login`: named so,
    /// and running setuid — Overterm itself starts nothing that does.
    package static func isPaneLogin(_ process: ActivityProcess, uid: uid_t) -> Bool {
        process.shortName == "login" && !process.isOwn(by: uid)
    }

    /// A stopped process sent TERM or INT can't act on it until continued
    /// (6.10 step 7); a traced one is left to its debugger.
    package static func continues(after signal: ActivitySignal, _ process: ActivityProcess) -> Bool {
        (signal == .term || signal == .int) && process.isStopped && !process.flags.contains(.traced)
    }

    private enum Reading {
        case live(ActivityProcess)
        case ended(now: String?)
    }

    /// `identity` read now: the listed process alive, or ended — gone, a
    /// zombie, or its pid another process's, named for the sheet.
    private func read(_ identity: ActivityProcessID) -> Reading {
        guard let process = kernel.process(identity.pid) else { return .ended(now: nil) }
        guard process.identity == identity else { return .ended(now: name(of: process)) }
        return process.isZombie ? .ended(now: nil) : .live(process)
    }

    /// The name a sheet shows: its executable's, never the 16 bytes of
    /// `p_comm` but when that is all there is (3.3).
    private func name(of process: ActivityProcess) -> String {
        if let path = kernel.path(of: process.pid), let name = path.split(separator: "/").last { return String(name) }
        return process.shortName
    }

    /// The token's image against the listed one: nil when it is that one,
    /// or its executable can't be read now, nor could then.
    private func changedImage(_ target: ActivitySignalTarget, token: ActivityAuditToken) -> ActivitySignalAnswer? {
        if let path = kernel.path(of: token) {
            guard let listed = target.path, path != listed else { return nil }
            return .ranAnotherProgram(path: path)
        }
        // None through the token: its image went since it was taken, or
        // its executable was deleted.
        return whatBecame(of: target, token: token)
    }

    /// Once the token stopped naming its image — the send answered ESRCH,
    /// or no path comes through it: ended (gone, a zombie, the pid
    /// another's), or the same process running another program — its
    /// image's version moved on, an exec, or its executable isn't the
    /// listed one. Nil when it is the same image still.
    private func whatBecame(of target: ActivitySignalTarget, token: ActivityAuditToken) -> ActivitySignalAnswer? {
        let identity = target.identity
        let process: ActivityProcess
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let live): process = live
        }
        let path = kernel.path(of: identity.pid)
        // An exec into a setuid program: not the user's now, and no token.
        guard process.isWhollyOwn(by: kernel.uid) else { return .ranAnotherProgram(path: path) }
        // None for a process of the user's that lives: it is ending.
        guard let fresh = kernel.auditToken(of: identity.pid) else { return .ended(now: nil) }
        if fresh.version != token.version { return .ranAnotherProgram(path: path) }
        if let path, let listed = target.path, path != listed { return .ranAnotherProgram(path: path) }
        return nil
    }

    /// No token to be had, or no call to send by one (step 6). Only a
    /// single Stop (TERM) or Interrupt (INT) goes, by its pid, after one
    /// more read of its path and start just before; the rest is refused,
    /// saying why.
    private func unpinned(_ signal: ActivitySignal, to target: ActivitySignalTarget, alone: Bool) -> ActivitySignalAnswer {
        let identity = target.identity
        // Why there was none: it ended, or isn't the user's now.
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): guard process.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
        }
        guard alone, signal == .term || signal == .int else { return .refused(.unpinned) }
        if let listed = target.path, let path = kernel.path(of: identity.pid), path != listed { return .ranAnotherProgram(path: path) }
        // Its start once more, after the path: a pid taken again since is
        // another process's, never sent a kill(2) meant for this one.
        let last: ActivityProcess
        switch read(identity) {
        case .ended(let now): return .ended(now: now)
        case .live(let process): last = process
        }
        guard last.isWhollyOwn(by: kernel.uid) else { return .refused(.notYours) }
        let answer = kernel.signal(signal.number, pid: identity.pid)
        guard answer == 0 else { return answer == ESRCH ? .ended(now: nil) : .failed(answer) }
        if Self.continues(after: signal, last) { _ = kernel.signal(SIGCONT, pid: identity.pid) }
        return .sent(pinned: false)
    }
}
