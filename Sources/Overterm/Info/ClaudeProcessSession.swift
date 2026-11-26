import Foundation

/// Which conversation a running Claude Code has: it writes
/// `<pid>.json` in its sessions folder (`AppEnvironment.claudeProcessSessionsDirectory`)
/// with the `sessionId` that `--resume` takes. Read so that a restored
/// pane picks up its own conversation, never the newest one of its
/// folder — two Claudes in one checkout came back as the same one.
package enum ClaudeProcessSession {
    /// A file larger than this is not Claude's.
    package static let maxBytes = 256 * 1024

    private struct File: Decodable {
        var pid: Int32?
        var sessionId: String?
        /// When it began, in ms since 1970.
        var startedAt: Double?
    }

    /// `pid`'s conversation, when its file names one that is a session id
    /// (`ClaudeSession.isValidID`). `started`: the process's start, in µs
    /// since 1970 (`ActivityProcessID.start`) — a file begun before it is
    /// an earlier process's that had the same pid, and is not read.
    package static func sessionID(pid: pid_t, started: UInt64? = nil, in directory: URL = AppEnvironment.claudeProcessSessionsDirectory) -> String? {
        guard pid > 0 else { return nil }
        let url = directory.appendingPathComponent("\(pid).json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return sessionID(in: data, pid: pid, started: started)
    }

    /// The same over the file's bytes. Pure.
    package static func sessionID(in data: Data, pid: pid_t, started: UInt64? = nil) -> String? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.pid == pid,
            let id = file.sessionId, ClaudeSession.isValidID(id)
        else { return nil }
        if let started, let began = file.startedAt {
            // Five seconds of slack: Claude writes it once it has started.
            guard began >= Double(started / 1000) - 5000 else { return nil }
        }
        return id
    }
}
