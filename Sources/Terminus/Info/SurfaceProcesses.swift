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

    /// The terminal's `login` pid, pairing any unpaired ones first.
    func loginPID(of terminal: TerminalView) -> pid_t? {
        entries.removeAll { $0.terminal == nil }
        if let pid = entries.first(where: { $0.terminal === terminal })?.pid { return pid }
        let children = ProcessInspector.children(of: getpid())
        let live = Set(children.map(\.pid))
        // A dead child's pairing is over (the tab's shell exited).
        for entry in entries where entry.pid.map({ !live.contains($0) }) == true { entry.pid = nil }
        let claimed = Set(entries.compactMap(\.pid))
        let free = children.filter { !claimed.contains($0.pid) }.map(\.pid)
        let waiting = entries.filter { $0.pid == nil && $0.terminal?.surface != nil }.sorted { $0.created < $1.created }
        for (entry, pid) in zip(waiting, free) { entry.pid = pid }
        return entries.first { $0.terminal === terminal }?.pid
    }
}
