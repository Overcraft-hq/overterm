import Foundation

/// What the pairing asks of a terminal: whether its surface lives — a
/// `login` comes with one. `TerminalView`'s; the tests' stand-ins, since a
/// unit test has no surface (it never calls `ghostty_init`).
@MainActor
protocol PairedSurface: AnyObject {
    var hasSurface: Bool { get }
}

extension TerminalView: PairedSurface {
    var hasSurface: Bool { surface != nil }
}

/// Which `login` process belongs to which terminal.
///
/// libghostty spawns `/usr/bin/login … <shell>` as a direct child of this
/// app for every surface but doesn't expose the pid. Surfaces are created
/// one at a time on the main thread and each spawns its child right away,
/// so the n-th unclaimed child (by start time) belongs to the n-th
/// unclaimed surface (by creation). A pairing, once made, is kept — by the
/// `login`'s identity, pid and start, which the census's context names
/// each pane's tree by (docs/design/activity/analysis.md, 7.1). A surface
/// coming or going, and a pairing made or over, rebuild that context.
@MainActor
final class SurfaceProcesses {
    static let shared = SurfaceProcesses(monitor: .shared)

    private final class Entry {
        weak var terminal: (any PairedSurface)?
        /// When the surface was made: `CLOCK_UPTIME_RAW`, ns, as a list's
        /// time is.
        let created: UInt64
        var login: ActivityProcessID?
        init(_ terminal: any PairedSurface, created: UInt64) {
            self.terminal = terminal
            self.created = created
        }
    }

    private var entries: [Entry] = []
    /// The census told when a pane comes or goes or a pairing changes: the
    /// app's; none for the tests' own.
    private let monitor: ActivityMonitor?

    init(monitor: ActivityMonitor? = nil) {
        self.monitor = monitor
    }

    /// Call right after the terminal's surface is created.
    func register(_ terminal: some PairedSurface, at created: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
        entries.append(Entry(terminal, created: created))
        monitor?.contextChanged()
    }

    /// Its surface was freed: the pane is gone from the census's context.
    func closed(_ terminal: some PairedSurface) {
        let count = entries.count
        entries.removeAll { $0.terminal == nil || $0.terminal === terminal }
        if entries.count != count { monitor?.contextChanged() }
    }

    /// The terminal's `login` pid, pairing any unpaired ones first — which
    /// lists the app's children, the census's child map.
    func loginPID(of terminal: some PairedSurface) -> pid_t? {
        if let pid = pairedLoginPID(of: terminal) { return pid }
        let listedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return loginPID(of: terminal, children: ProcessInspector.children(of: getpid()), listedAt: listedAt)
    }

    /// The terminal's `login` pid if it is paired already: no scan.
    func pairedLoginPID(of terminal: some PairedSurface) -> pid_t? { login(of: terminal)?.pid }

    /// The terminal's `login` as the census names it, pid and start, if it
    /// is paired already: no scan.
    func login(of terminal: some PairedSurface) -> ActivityProcessID? {
        entries.removeAll { $0.terminal == nil }
        return entries.first { $0.terminal === terminal }?.login
    }

    /// The same, pairing with `children` — ProcessInspector.children(of:
    /// getpid()), listed off the main thread at `listedAt`
    /// (`CLOCK_UPTIME_RAW`, ns, read before the list).
    func loginPID(of terminal: some PairedSurface, children: [(pid: pid_t, start: UInt64, name: String)], listedAt: UInt64) -> pid_t? {
        if let pid = pairedLoginPID(of: terminal) { return pid }
        if pair(children, listedAt: listedAt) { monitor?.contextChanged() }
        return pairedLoginPID(of: terminal)
    }

    /// Whether a surface waits for its `login`.
    var hasWaiting: Bool { entries.contains { $0.login == nil && $0.terminal?.hasSurface == true } }

    /// Pairs the surfaces still waiting from the app's children listed now
    /// — off the main thread: a read of the whole table never runs on it
    /// (docs/design/activity/analysis.md, 7.7) — the main actor pairing
    /// what was listed, as `TerminalView.lookAtProgram` does; the census is
    /// told when a pairing changed. Nothing is read while none waits.
    func pairWaiting(kernel: some ActivityKernel = LiveActivityKernel()) async {
        guard hasWaiting else { return }
        let app = getpid()
        let (listedAt, children) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let listedAt = kernel.uptime()
                continuation.resume(returning: (listedAt, ProcessInspector.children(of: app, kernel: kernel)))
            }
        }
        if pair(children, listedAt: listedAt, kernel: kernel) { monitor?.contextChanged() }
    }

    /// Pairs the surfaces still waiting with `children` — the app's, oldest
    /// first, listed at `listedAt` (`CLOCK_UPTIME_RAW`, ns): a census's,
    /// perhaps a tick old; whether a pairing changed. A pairing is made
    /// from what holds now, not from what the list says: only a surface
    /// made before the list was read is offered one of its `login`s — one
    /// made since can't be in it — and a `login` is taken only while a read
    /// by its pid still finds it, alive. A list a tick old names the
    /// `login` of a pane closed since, reaped as its surface was freed, its
    /// pairing dropped: a new pane paired with it read empty to every
    /// reader — Tab Info, the poll's agent folder and pills, Suspend Tab, a
    /// drop, an MCP confirmation — until another surface was made.
    ///
    /// A pairing is over when its `login` has ended (the tab's shell
    /// exited): one `children` doesn't list is read again by its pid, so a
    /// list older than the pairing never ends it.
    @discardableResult
    func pair(
        _ children: [(pid: pid_t, start: UInt64, name: String)], listedAt: UInt64, kernel: some ActivityKernel = LiveActivityKernel()
    ) -> Bool {
        pair(children, unclaimed: Self.unclaimedLogins(children, claimed: []), listedAt: listedAt, kernel: kernel)
    }

    /// The same from a census that landed (7.7): the app's children and the
    /// `login`s its context had no pane for, both listed on the sampler's
    /// queue (`ActivitySnapshot.appChildren`, `unclaimedLogins`) — the main
    /// actor only hands them out, in microseconds, by the rules above. A
    /// zombie `login` is in neither: it never pairs (7.10).
    @discardableResult
    func pair(_ snapshot: ActivitySnapshot, kernel: some ActivityKernel = LiveActivityKernel()) -> Bool {
        pair(snapshot.appChildren, unclaimed: snapshot.unclaimedLogins, listedAt: snapshot.time, kernel: kernel)
    }

    /// `children`'s pairing, `unclaimed` the logins among them a surface may
    /// take, oldest first — less those paired since they were listed.
    private func pair(
        _ children: [(pid: pid_t, start: UInt64, name: String)], unclaimed: [ActivityProcessID], listedAt: UInt64, kernel: some ActivityKernel
    ) -> Bool {
        /// A read by its pid finds it, alive.
        func holds(_ login: ActivityProcessID) -> Bool {
            guard let now = kernel.process(login.pid) else { return false }
            return now.identity == login && !now.isZombie
        }
        let live = Set(children.map { ActivityProcessID(pid: $0.pid, start: $0.start) })
        var changed = false
        for entry in entries {
            guard let login = entry.login, !live.contains(login), !holds(login) else { continue }
            entry.login = nil
            changed = true
        }
        let claimed = Set(entries.compactMap(\.login))
        var free = unclaimed.filter { !claimed.contains($0) }[...]
        let waiting = entries.filter { $0.login == nil && $0.terminal?.hasSurface == true && $0.created <= listedAt }
            .sorted { $0.created < $1.created }
        for entry in waiting {
            while let login = free.first, !holds(login) { free.removeFirst() }
            guard let login = free.popFirst() else { break }
            entry.login = login
            changed = true
        }
        return changed
    }

    /// The children a surface may pair with: `login` processes no terminal
    /// has, oldest first. Only logins — the app's git and gh are its
    /// children too, and a surface created while one ran was paired with
    /// it: its tab's processes, agent and "still running" were git's.
    nonisolated static func unclaimedLogins(_ children: [(pid: pid_t, start: UInt64, name: String)], claimed: Set<ActivityProcessID>)
        -> [ActivityProcessID]
    {
        children.map { (identity: ActivityProcessID(pid: $0.pid, start: $0.start), name: $0.name) }
            .filter { $0.name == "login" && !claimed.contains($0.identity) }.map(\.identity).sorted()
    }
}
