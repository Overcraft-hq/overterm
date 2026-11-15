import Darwin
import Foundation

/// A pane pill's Stop… on a process's port (the window's `stopListener`;
/// a forward's Stop is `KubeForwards`', a container's the engine's). Asked
/// first — the process, its pid, the port, SIGTERM; every time, no setting
/// skips it —, then sent SIGTERM only while it is still the process
/// listed, the same pid and start time (`ListeningPort.start`), and still
/// holds the port, both read again just before the signal; to that pid
/// alone, never a group or a pattern. It was `kill(pid, SIGTERM)`, unasked,
/// on a pid from an lsof up to 6 s old: once the server had ended, whatever
/// took its pid got the signal (the Activity analysis, 2.4 item 5).
/// Activity's Free… replaces it (1.7.0).
enum PortStop {
    /// What a read just before the signal says of the process listed.
    enum Check: Equatable {
        /// Still that process, still listening on the port: it may be signalled.
        case same
        /// Its start time couldn't be read with the listing, so nothing tells
        /// it from a process that took its pid since — or its pid is one
        /// never signalled (a group, launchd, Overterm itself).
        case unidentified
        /// No process of the user's has its pid any more.
        case exited
        /// Its pid is another process's now: another start time.
        case reused
        /// Still that process, no longer listening on the port.
        case notListening
    }

    /// What Stop… did, once asked.
    enum Outcome: Equatable {
        case sent
        case refused(Check)
        /// kill(2) failed: its errno.
        case failed(Int32)
    }

    /// Pure: `listed` is the start time read with the listing, `now` the
    /// pid's start time read now (nil: no such process, or not the user's),
    /// `listens` whether that pid listens on the port now.
    static func check(pid: pid_t, listed: UInt64?, now: UInt64?, listens: Bool) -> Check {
        // 0 or a negative pid is a group; 1 is launchd.
        guard pid > 1, pid != getpid(), let listed else { return .unidentified }
        guard let now else { return .exited }
        guard now == listed else { return .reused }
        return listens ? .same : .notListening
    }

    /// When the question opens: the check, read as just before the signal,
    /// and — while it is still that process — its command line, masked as
    /// Tab Info's (`ProcessNode.masked`). The words are read before the
    /// start time, so a match means they are that process's. Off the main
    /// thread.
    static func opening(_ port: ListeningPort) async -> (check: Check, command: String?) {
        guard port.pid > 1, port.pid != getpid() else { return (.unidentified, nil) }
        let listens = await listening(port)
        let arguments = ProcessInspector.arguments(of: port.pid)
        let found = check(pid: port.pid, listed: port.start, now: ListeningPorts.start(of: port.pid), listens: listens)
        return (found, found == .same && !arguments.isEmpty ? ProcessNode.masked(arguments) : nil)
    }

    /// Once asked: read again — whether its pid listens on the port (lsof of
    /// that pid), then its start time, last — and only if it is still the
    /// process listed, holding the port, SIGTERM to that pid at once. Off
    /// the main thread.
    static func signal(_ port: ListeningPort) async -> Outcome {
        guard port.pid > 1, port.pid != getpid() else { return .refused(.unidentified) }
        let listens = await listening(port)
        let found = check(pid: port.pid, listed: port.start, now: ListeningPorts.start(of: port.pid), listens: listens)
        guard found == .same else { return .refused(found) }
        return kill(port.pid, SIGTERM) == 0 ? .sent : .failed(errno)
    }

    /// Whether `port.pid` listens on `port.port` now.
    private static func listening(_ port: ListeningPort) async -> Bool {
        await ListeningPorts.of([port.pid]).contains { $0.pid == port.pid && $0.port == port.port }
    }

    /// The question: every write's (`WriteConfirmation`), every character
    /// of the name and the line visible (`DockerMCP.displayed`).
    @MainActor static func confirmation(for port: ListeningPort, command: String?) -> WriteConfirmation {
        var detail = "pid \(port.pid) listens on :\(port.port)."
        if let command, !command.isEmpty { detail += "\n\n" + DockerMCP.displayed(command) }
        detail +=
            "\n\nIt is sent SIGTERM, as kill -TERM \(port.pid) sends it — "
            + "only if, right before, it is still this process and still holds :\(port.port)."
        return WriteConfirmation(title: "Stop “\(DockerMCP.displayed(port.process))” (pid \(port.pid))?", detail: detail, button: "Stop Process")
    }

    /// What the person is told when nothing was sent, or kill(2) refused:
    /// a title and a line. Nil once it was sent.
    @MainActor static func refusal(_ outcome: Outcome, port: ListeningPort) -> (title: String, detail: String)? {
        let name = "“\(DockerMCP.displayed(port.process))”"
        switch outcome {
        case .sent, .refused(.same):
            return nil
        case .refused(.exited):
            // Only the user's processes are read: another user's, or root's,
            // may hold its pid now.
            return ("\(name) has exited", "Nothing was sent: no process of yours has pid \(port.pid) any more.")
        case .refused(.reused):
            return ("\(name) has exited", "Nothing was sent: pid \(port.pid) is another process's now.")
        case .refused(.notListening):
            return ("\(name) no longer holds :\(port.port)", "Nothing was sent: pid \(port.pid) still runs, but no longer listens on :\(port.port).")
        case .refused(.unidentified):
            return (
                "\(name) can't be stopped from here",
                "Nothing was sent: Overterm can't tell that pid \(port.pid) is still the process that listened on :\(port.port). Stop it in its terminal."
            )
        case .failed(let error):
            return ("\(name) wasn't stopped", "SIGTERM to pid \(port.pid) failed: \(String(cString: strerror(error))).")
        }
    }
}
