import Foundation

/// Which `login` process belongs to which terminal.
///
/// libghostty spawns `/usr/bin/login … <shell>` as a direct child of this
/// app for every surface but doesn't expose the pid. Surfaces are created
/// one at a time on the main thread and each spawns its child right away,
/// so the n-th unclaimed child (by start time) belongs to the n-th
/// unclaimed surface (by creation). A pairing, once made, is kept.
@MainActor
final class SurfaceProcesses {
    static let shared = SurfaceProcesses()

    private final class Entry {
        weak var terminal: TerminalView?
        let created: UInt64
        var pid: pid_t?
        init(_ terminal: TerminalView, created: UInt64) {
            self.terminal = terminal
            self.created = created
        }
    }

    private var entries: [Entry] = []

    /// Call right after the terminal's surface is created.
    func register(_ terminal: TerminalView) {
        entries.append(Entry(terminal, created: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
    }

    /// The terminal's `login` pid, pairing any unpaired ones first — which
    /// lists the app's children, a process scan.
    func loginPID(of terminal: TerminalView) -> pid_t? {
        if let pid = pairedLoginPID(of: terminal) { return pid }
        return loginPID(of: terminal, children: ProcessInspector.children(of: getpid()))
    }

    /// The terminal's `login` pid if it is paired already: no scan.
    func pairedLoginPID(of terminal: TerminalView) -> pid_t? {
        entries.removeAll { $0.terminal == nil }
        return entries.first { $0.terminal === terminal }?.pid
    }

    /// The same, pairing with `children` — ProcessInspector.children(of:
    /// getpid()), listed off the main thread.
    func loginPID(of terminal: TerminalView, children: [(pid: pid_t, start: UInt64, name: String)]) -> pid_t? {
        if let pid = pairedLoginPID(of: terminal) { return pid }
        let live = Set(children.map(\.pid))
        // A dead child's pairing is over (the tab's shell exited).
        for entry in entries where entry.pid.map({ !live.contains($0) }) == true { entry.pid = nil }
        let free = Self.unclaimedLogins(children, claimed: Set(entries.compactMap(\.pid)))
        let waiting = entries.filter { $0.pid == nil && $0.terminal?.surface != nil }.sorted { $0.created < $1.created }
        for (entry, pid) in zip(waiting, free) { entry.pid = pid }
        return entries.first { $0.terminal === terminal }?.pid
    }

    /// The children a surface may pair with: `login` processes no terminal
    /// has, oldest first. Only logins — the app's git and gh are its
    /// children too, and a surface created while one ran was paired with
    /// it: its tab's processes, agent and "still running" were git's.
    nonisolated static func unclaimedLogins(_ children: [(pid: pid_t, start: UInt64, name: String)], claimed: Set<pid_t>) -> [pid_t] {
        children.filter { $0.name == "login" && !claimed.contains($0.pid) }.sorted { $0.start < $1.start }.map(\.pid)
    }
}
