#if E2E
import AppKit
import SQLite3

/// The Sessions panel's opencode rows: a database with opencode 1.x's
/// tables written where an isolated run reads it (`OpencodeSessions.database`,
/// the support folder's — never the user's), listed beside Claude's and
/// resumed with `opencode --session <id>`, typed into nothing here.
extension E2ERunner {
    func opencodeSessionsChecks(repo: URL) async {
        let file = AppEnvironment.supportDirectory.appendingPathComponent("opencode/opencode.db")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { return check("an opencode database to read", false) }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let id = "ses_e2eOpencode0001"
        let sql = [
            "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer)",
            "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
            "CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
            "INSERT INTO session VALUES ('\(id)', 'p', NULL, 's', '\(repo.path)', 'New session - 2026-11-27T10:00:00.000Z', '1.18', \(now), \(now), NULL)",
            "INSERT INTO message VALUES ('m1', '\(id)', \(now), \(now), '{\"role\":\"user\"}')",
            "INSERT INTO part VALUES ('p1', 'm1', '\(id)', \(now), \(now), '{\"type\":\"text\",\"text\":\"wire the login form\"}')",
        ]
        for statement in sql where sqlite3_exec(db, statement, nil, nil, nil) != SQLITE_OK {
            check("the fixture's SQL", false, statement)
        }
        sqlite3_close(db)
        defer { try? FileManager.default.removeItem(at: file) }

        app.refreshSessions()
        let listed = await eventually(5) { self.app.sessions.sessions.contains { $0.id == id } }
        let row = app.sessions.sessions.first { $0.id == id }
        check(
            "opencode's session is listed, newest first",
            listed && app.sessions.sessions.first?.id == id && row?.agent == .opencode, app.sessions.sessions.map(\.id).joined(separator: ", "))
        check("…by what was typed, opencode's placeholder title left out", row?.title == nil && row?.lastPrompt == "wire the login form")
        guard let row else { return }
        let count = app.store.tabs.count
        app.resume(row, start: false)
        check(
            "resumed in a new opencode tab where it ran",
            app.store.tabs.count == count + 1 && app.store.selected?.agent == .opencode && app.store.selected?.workingDirectory == repo.path)
        check("with its own flag", row.resumeCommand(Settings.shared.launch(for: .opencode))?.contains("opencode --session \(id)") == true)
    }
}
#endif
