import Foundation
import SQLite3

/// A conversation the Sessions panel lists and picks back up: Claude
/// Code's (a transcript in ~/.claude/projects, `ClaudeSessions`) or
/// opencode's (a row of its own database, `OpencodeSessions`).
package struct AgentSession: Identifiable, Equatable {
    package let agent: Agent
    /// The agent's own id: what its resume takes.
    package let id: String
    /// Where it ran; resuming starts there.
    package let directory: String
    package let updated: Date
    package let title: String?
    package let lastPrompt: String?
    /// Claude's transcript; opencode keeps a row, no file of its own.
    package let file: URL?

    package init(agent: Agent, id: String, directory: String, updated: Date, title: String?, lastPrompt: String?, file: URL?) {
        self.agent = agent
        self.id = id
        self.directory = directory
        self.updated = updated
        self.title = title
        self.lastPrompt = lastPrompt
        self.file = file
    }

    package init(_ claude: ClaudeSession) {
        self.init(
            agent: .claude, id: claude.id, directory: claude.directory, updated: claude.updated, title: claude.activity.title,
            lastPrompt: claude.activity.lastPrompt, file: claude.file)
    }

    /// What picks it back up in a shell in its directory, with `launch`;
    /// nil for an id that isn't one (never typed into a shell).
    package func resumeCommand(_ launch: AgentLaunch) -> String? {
        switch agent {
        case .claude: Agent.claudeResume(session: id, launch: launch)
        case .opencode: OpencodeSessions.isValidID(id) ? launch.line("opencode --session \(id)") : nil
        case .codex, .pi, .gemini: nil
        }
    }
}

package enum AgentSessions {
    /// Every agent's sessions run in `directories` or below them, newest
    /// first, `limit` in all. Blocking: call off the main thread.
    package static func list(in directories: [String], limit: Int = 60, opencode: URL? = OpencodeSessions.database) -> [AgentSession] {
        let claude = ClaudeSessions.list(in: directories, limit: limit).map(AgentSession.init)
        let others = opencode.map { OpencodeSessions.list(in: directories, limit: limit, database: $0) } ?? []
        return Array((claude + others).sorted { $0.updated > $1.updated }.prefix(limit))
    }
}

/// opencode's sessions, from its own SQLite database — opened read-only,
/// never written: the top-level conversations (not a subagent's), not
/// archived, and the newest thing typed in each.
package enum OpencodeSessions {
    /// opencode's ids: `ses_`, then letters and digits.
    package static func isValidID(_ id: String) -> Bool {
        id.hasPrefix("ses_") && id.count > 4 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Its database: `$XDG_DATA_HOME/opencode/opencode.db`, else
    /// ~/.local/share's — where opencode 1.x keeps it. An isolated run never
    /// reads the user's: its own support folder's, a scenario's fixture.
    package static var database: URL? {
        if AppEnvironment.isIsolated {
            let fixture = AppEnvironment.supportDirectory.appendingPathComponent("opencode/opencode.db")
            return FileManager.default.fileExists(atPath: fixture.path) ? fixture : nil
        }
        let environment = ProcessInfo.processInfo.environment
        let data =
            environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        let file = data.appendingPathComponent("opencode/opencode.db")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The title opencode gives a session nobody named.
    package static func isPlaceholder(_ title: String) -> Bool { title.hasPrefix("New session - ") || title.isEmpty }

    /// The newest `limit` sessions run in `directories` or below them,
    /// newest first. A database it can't read (another version's schema,
    /// locked) lists none.
    package static func list(in directories: [String], limit: Int = 60, database: URL) -> [AgentSession] {
        let roots = directories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard !roots.isEmpty else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var rows: [(id: String, directory: String, title: String, updated: Date)] = []
        // The checkout's own, in SQL before the limit: other repositories'
        // newer sessions can't push them out. By prefix, never LIKE (a path's
        // `_` and `%` would be wildcards); kept again below by the standardized path.
        let within = roots.indices.map { "directory = ?\($0 + 1) OR substr(directory, 1, length(?\($0 + 1)) + 1) = ?\($0 + 1) || '/'" }
        let sessions = """
            SELECT id, directory, title, time_updated FROM session
            WHERE parent_id IS NULL AND time_archived IS NULL AND (\(within.joined(separator: " OR ")))
            ORDER BY time_updated DESC LIMIT \(limit * 4)
            """
        query(db, sessions, bind: roots) { statement in
            guard let id = text(statement, 0), isValidID(id), let directory = text(statement, 1) else { return }
            let path = URL(fileURLWithPath: directory).standardizedFileURL.path
            guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
            rows.append((id, path, text(statement, 2) ?? "", updated))
        }
        // The newest thing typed in each: what its row says when it has no
        // title. The newest user message's own text — not the parts opencode
        // adds to it (an @-file's contents, `synthetic`).
        let prompt = """
            SELECT json_extract(p.data, '$.text') FROM part p
            WHERE p.message_id = (
                SELECT m.id FROM message m WHERE m.session_id = ?1 AND json_extract(m.data, '$.role') = 'user'
                ORDER BY m.time_created DESC LIMIT 1)
              AND json_extract(p.data, '$.type') = 'text' AND coalesce(json_extract(p.data, '$.synthetic'), 0) = 0
            ORDER BY p.time_created LIMIT 1
            """
        var listed: [AgentSession] = []
        for row in rows where listed.count < limit {
            var typed: String?
            query(db, prompt, bind: [row.id]) { statement in typed = text(statement, 0) }
            let said = typed?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let title = isPlaceholder(row.title) ? nil : row.title
            // Nothing typed and no title: not a conversation to go back to (as Claude's).
            guard title != nil || said != nil else { continue }
            listed.append(
                AgentSession(agent: .opencode, id: row.id, directory: row.directory, updated: row.updated, title: title, lastPrompt: said, file: nil))
        }
        return listed
    }

    /// Runs `sql` with `bind`'s texts, each row to `row`; a statement that
    /// doesn't prepare runs nothing.
    private static func query(_ db: OpaquePointer, _ sql: String, bind: [String], row: (OpaquePointer) -> Void) {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            sqlite3_finalize(prepared)
            return
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: SQLite copies the text.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: bytes)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
