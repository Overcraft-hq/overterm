#if E2E
import AppKit
import SQLite3

/// A result's rows edited in the grid, then saved — on a SQLite file, no
/// server needed — and a connection's Server page in the right slot. With
/// Scripts/database-test-servers.sh's PostgreSQL on :55432, its Server
/// page's sessions and its Users page too; without it, that part says so.
extension E2ERunner {
    func databaseOpsScenario() async {
        let file = scratch.appendingPathComponent("ops.sqlite")
        try? FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(
            db,
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL, note TEXT); INSERT INTO orders VALUES (1, 9.5, 'first'), (2, 20, NULL), (3, 7, 'third');",
            nil, nil, nil)
        sqlite3_close(db)
        let model = DatabaseModel.shared
        var connection = DatabaseConnection(name: "Ops", kind: .sqlite)
        connection.filePath = file.path
        try? model.store.save(connection)

        // Select Top 100, from the panel: its rows can be edited, by the key.
        app.runInDatabaseConsole(connection, "SELECT * FROM orders LIMIT 100;")
        guard let editor = app.editor else { return check("the editor", false) }
        check("the console runs Select Top", await eventually(5) { editor.active?.sqlConsole?.current?.result?.rows.count == 3 })
        guard let console = editor.active?.sqlConsole, let run = console.current else { return }
        var asked: WriteConfirmation?
        console.confirmWrite = { confirmation in
            asked = confirmation
            return true
        }
        guard let rows = console.editor(for: run) else { return check("a SQLite result is offered for editing", false) }
        check("its rows are editable, found by the primary key", await eventually(5) { rows.editable?.key.columns == ["id"] }, "\(rows.state)")
        guard let grid = Self.grid(in: editor.view) else { return check("the grid is on screen", false) }

        rows.set(row: 0, column: 2, to: .text("edited"))
        rows.set(row: 1, column: 2, to: .text(""))
        rows.delete([2])
        rows.addRow()
        rows.set(new: 0, column: 1, to: .text("1.5"))
        rows.set(new: 0, column: 2, to: .text("new"))
        check("nothing runs before Save", Self.notes(file) == ["first", nil, "third"], "\(Self.notes(file))")
        check("four changes are pending", rows.edits.count == 4, "\(rows.edits)")
        check("the grid shows the added row", await eventually(3) { grid.numberOfRows == 4 }, "\(grid.numberOfRows)")
        let edited = grid.view(atColumn: 2, row: 0, makeIfNecessary: true) as? GridCell
        check("an edited cell is marked", edited?.textField?.backgroundColor == GridCell.editedTint)
        let deleted = grid.view(atColumn: 0, row: 2, makeIfNecessary: true) as? GridCell
        check("a deleted row is marked", deleted?.textField?.backgroundColor == GridCell.deletedTint)
        let fresh = grid.view(atColumn: 0, row: 3, makeIfNecessary: true) as? GridCell
        check("a new row's unset key is DEFAULT", fresh?.textField?.stringValue == "DEFAULT", fresh?.textField?.stringValue ?? "-")
        let preview = await rows.preview()
        check(
            "the preview is the statements a Save runs",
            preview == """
                DELETE FROM "main"."orders" WHERE "id" = '3';
                UPDATE "main"."orders" SET "note" = 'edited' WHERE "id" = '1';
                UPDATE "main"."orders" SET "note" = '' WHERE "id" = '2';
                INSERT INTO "main"."orders" ("total", "note") VALUES ('1.5', 'new');
                """, preview)

        await rows.save()
        check("Save asks first, every statement shown", asked?.detail.contains(#"UPDATE "main"."orders" SET "note" = 'edited'"#) == true, asked?.detail ?? "-")
        check("then runs them together", Self.notes(file) == ["edited", "", "new"], "\(Self.notes(file))")
        check("and reads the rows again", await eventually(5) { console.current?.result?.rows.map { $0[2] } == ["edited", "", "new"] }, "\(console.current?.result?.rows ?? [])")
        check("nothing is pending after", rows.edits.isEmpty && rows.error == nil, rows.error ?? "")
        check("what ran is in the history", model.history.contains { $0.connection == connection.id && $0.sql.hasPrefix("DELETE FROM") })

        // Declined: nothing runs, the changes stay.
        console.confirmWrite = { _ in false }
        rows.set(row: 0, column: 2, to: .null)
        await rows.save()
        check("a declined Save runs nothing", Self.notes(file) == ["edited", "", "new"] && rows.edits.count == 1)

        // Edits not saved are never lost unasked: the window's close counts
        // them, the result's tab asks, and later runs never push it out.
        check("the window's close counts them", editor.unsavedNames.contains(editor.active?.name ?? "-"), "\(editor.unsavedNames)")
        var discardAsked = 0
        console.confirmDiscard = { _ in
            discardAsked += 1
            return false
        }
        console.requestClose(run)
        check("closing its tab asks, and Cancel keeps it", await eventually(3) { discardAsked == 1 } && console.runs.contains { $0.id == run.id })
        console.run((1...11).map { "SELECT \($0)" })
        check("eleven runs after", await eventually(10) { !console.isRunning && console.runs.count >= 10 })
        check("never push out a run with edits", console.runs.contains { $0.id == run.id } && rows.edits.count == 1, "\(console.runs.count)")
        rows.discard()
        check("discarded: nothing left to ask", editor.unsavedNames.isEmpty && console.unsavedEdits() == 0, "\(editor.unsavedNames)")
        console.selected = run.id

        // A join's rows aren't edited, and the bar says why.
        console.run(["SELECT o.id, count(*) FROM orders o GROUP BY o.id"])
        check("a grouped result runs", await eventually(5) { console.current?.sql.contains("GROUP BY") == true && console.current?.result != nil })
        if let grouped = console.current, let refused = console.editor(for: grouped) {
            check("and isn't editable, said why", await eventually(5) { if case .refused(let why) = refused.state { !why.isEmpty } else { false } }, "\(refused.state)")
        }

        // Read-only: no editing offered at all.
        var reader = connection
        reader.id = UUID()
        reader.name = "Ops (read-only)"
        reader.readOnly = true
        try? model.store.save(reader)
        console.use(reader)
        console.run(["SELECT * FROM orders"])
        check("a read-only connection's rows run", await eventually(5) { console.current?.result?.rows.count == 3 && console.connection?.readOnly == true })
        check("and are never offered for editing", console.current.flatMap(console.editor(for:)) == nil)

        // The Server page: a SQLite file's numbers, read while it shows.
        app.openDatabasePage(.server, for: connection)
        check("Server opens in the right slot", app.rightPane.mode == .database && app.databaseSlot.page == .server && app.diffItem?.isCollapsed == false)
        let server = app.databaseSlot.server
        check("and reads the file's numbers", await eventually(5) { server.overview?.facts.contains { $0.title == "Journal" } == true }, server.error ?? "")
        check("SQLite's page has the overview alone", server.parts == [.overview])
        await server.checkIntegrity()
        check("Check Integrity runs integrity_check", server.integrity == "ok — no problems found.", server.integrity ?? "-")
        let items = app.databasePaletteItems().map(\.title)
        check("⌘K offers its Server page, not a Users page", items.contains("Server: Ops") && !items.contains("Users & Roles: Ops"), "\(items)")
        let said = (try? await DatabaseMCP.call("db_server", ["connection": "Ops"], model: model))?["content"].map { "\($0)" } ?? ""
        check("db_server tells an agent the same", said.contains("Journal"), said)
        app.toggleDiff(nil)
        check("hidden, it reads nothing", !server.visible)

        await postgresPages(model)
    }

    /// PostgreSQL's Server page (sessions, this one marked) and Users page —
    /// against the test server, when it is running.
    private func postgresPages(_ model: DatabaseModel) async {
        var connection = DatabaseConnection(name: "Ops PG", kind: .postgres)
        connection.host = "127.0.0.1"
        connection.port = 55432
        connection.user = "ot"
        connection.database = "shop"
        connection.sslMode = .disable
        try? model.store.save(connection, password: "otpass")
        let session = model.session(connection)
        await session.open()
        guard session.isOpen else {
            print("E2E SKIP databaseOps' PostgreSQL pages: nothing on :55432 — Scripts/database-test-servers.sh starts it")
            return
        }
        app.openDatabasePage(.server, for: connection)
        let server = app.databaseSlot.server
        check("PostgreSQL's page has every part", server.parts == MonitorPart.allCases)
        check("its overview reads connections of max", await eventually(5) { server.overview?.facts.contains { $0.title == "Connections" } == true }, server.error ?? "")
        server.part = .activity
        check("Activity lists this connection's session, marked", await eventually(5) { server.activity?.value?.contains(where: \.isOwn) == true }, server.error ?? "")
        server.paused = true
        await pause(1)
        let read = server.updated
        await pause(6)
        check("paused, it reads nothing more", server.updated == read)
        server.paused = false

        app.openDatabasePage(.users, for: connection)
        let users = app.databaseSlot.users
        check("Users lists the roles", await eventually(5) { users.users?.value?.contains { $0.name == "ot" && $0.superuser } == true }, users.error ?? "")
        users.selected = "ot"
        check("a role's grants are read", await eventually(5) { users.grants?.value != nil }, "\(String(describing: users.grants))")
        check("the server page stops while Users shows", !server.visible && users.visible)
        app.toggleDiff(nil)
        model.disconnect(connection)
    }

    /// The SQLite file's notes, by id — what is on disk, not what is shown.
    private static func notes(_ file: URL) -> [String?] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT note FROM orders ORDER BY id", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var notes: [String?] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            notes.append(sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 0)))
        }
        return notes
    }

    private static func grid(in view: NSView) -> GridTableView? {
        if let grid = view as? GridTableView { return grid }
        for subview in view.subviews { if let found = grid(in: subview) { return found } }
        return nil
    }
}
#endif
