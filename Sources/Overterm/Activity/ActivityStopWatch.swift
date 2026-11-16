import Darwin
import Foundation

/// What became of a process after a Stop (docs/design/activity/
/// analysis.md, 6.10 step 10): its identity read once a second for five
/// seconds, then one of "Stopped", "Still running — Force Quit…", or "Came
/// back as pid N" — a process started since the Stop with the same
/// executable and parent, or holding one of its ports. Pure: each read is
/// handed in.
enum ActivityStopWatch {
    /// The process a Stop was sent to, as it was listed.
    struct Listed: Hashable, Sendable {
        var identity: ActivityProcessID
        /// What the sheet called it.
        var name: String
        var path: String?
        /// Its parent's pid when it was listed.
        var parent: pid_t
        /// The ports it listened on.
        var ports: [Int] = []
    }

    /// One of the user's processes a read found: what a comeback is told by.
    struct Seen: Hashable, Sendable {
        var identity: ActivityProcessID
        var path: String?
        var parent: pid_t
        var ports: [Int] = []
    }

    enum State: Hashable, Sendable {
        /// Asked to stop; not ended yet.
        case stopping
        /// It ended, and nothing took its place.
        case stopped
        /// Still running when the watch ended: Force Quit is offered.
        case stillRunning
        /// A process started since the Stop runs its executable under the
        /// same parent, or holds one of its ports: its supervisor started it
        /// again.
        case cameBack(pid: pid_t)
    }

    /// How long the watch reads, once a second (6.10 step 10).
    static let watch: Duration = .seconds(5)
    /// How long Force Quit is offered for what a Stop didn't end (D-11).
    static let forceQuitWindow: TimeInterval = 120

    /// What a read says: `alive`, the listed identity is still there and
    /// not a zombie; `seen`, the user's processes the read found; `sentAt`,
    /// when the Stop was sent, µs since 1970 as a start is; `final`, the
    /// watch's last read.
    static func state(_ listed: Listed, alive: Bool, seen: [Seen], sentAt: UInt64, final: Bool) -> State {
        if alive { return final ? .stillRunning : .stopping }
        let ports = Set(listed.ports)
        let back = seen.filter { process in
            guard process.identity != listed.identity, process.identity.start > sentAt else { return false }
            if let path = listed.path, process.path == path, process.parent == listed.parent { return true }
            return !ports.isDisjoint(with: process.ports)
        }
        if let first = back.min(by: { $0.identity < $1.identity }) { return .cameBack(pid: first.identity.pid) }
        return .stopped
    }

    /// What the page's header says of it.
    static func label(_ state: State, _ listed: Listed) -> String {
        let name = "“\(DockerMCP.displayed(listed.name))” (pid \(listed.identity.pid))"
        switch state {
        case .stopping: return "Stopping \(name)…"
        case .stopped: return "Stopped \(name)"
        case .stillRunning: return "\(name) still running — Force Quit…"
        case .cameBack(let pid): return "\(name) came back as pid \(pid)"
        }
    }

    /// The user's processes in `snapshot`, with their executables and the
    /// ports they listen on: what `state` is told.
    static func seen(in snapshot: ActivitySnapshot) -> [Seen] {
        snapshot.table.processes.compactMap { process in
            guard process.isOwn(by: snapshot.uid), !process.isZombie else { return nil }
            let facts = snapshot.facts[process.identity]
            let ports = facts?.sockets?.records.filter(\.isListening).map { Int($0.localPort) } ?? []
            return Seen(identity: process.identity, path: facts?.path, parent: process.parentPID, ports: ports)
        }
    }

    /// Whether `identity` is alive in `snapshot`.
    static func alive(_ identity: ActivityProcessID, in snapshot: ActivitySnapshot) -> Bool {
        snapshot.table.process(identity).map { !$0.isZombie } ?? false
    }
}
