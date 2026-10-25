import AppKit
import SQLite3

/// The database client, on a SQLite file — no server needed.
extension E2ERunner {
    func databaseScenario() async {
        let file = scratch.appendingPathComponent("shop.sqlite")
        try? FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(
            db, "CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL, note TEXT); INSERT INTO orders VALUES (1, 9.5, 'first'), (2, 20, NULL), (3, 7, 'third');",
            nil, nil, nil)
        sqlite3_close(db)

        let model = DatabaseModel.shared
        var connection = DatabaseConnection(name: "Shop", kind: .sqlite)
        connection.filePath = file.path
        do {
            try model.store.save(connection, password: "never-written")
        } catch {
            return check("a connection is saved", false, "\(error)")
        }
        let saved = (try? String(contentsOf: model.store.file, encoding: .utf8)) ?? ""
        check("a connection is saved in Overterm's folder", saved.contains("Shop") && model.store.file.path.contains(AppEnvironment.supportDirectory.path))
        check("and its secret is not", !saved.contains("never-written"))

        app.showDatabase(nil)
        check("View ▸ Database opens the panel", app.sidebarPanel.panel == .database && app.sidebarItem?.isCollapsed == false)
        let session = model.session(connection)
        await session.open()
        check("the connection opens", session.state == .open, "\(session.state)")
        await session.loadTables("main")
        check("its tables are listed", session.tables["main"]?.map(\.name) == ["orders"])
        await session.loadColumns("main")
        check("with their columns", session.columns(of: "orders", in: "main").map(\.name) == ["id", "total", "note"])

        // Select Top 100, from the panel: written in the console and run there.
        app.runInDatabaseConsole(connection, "SELECT * FROM orders LIMIT 100;")
        guard let editor = app.editor else { return check("the editor", false) }
        check("the connection's console opens", await eventually(5) { editor.active?.sqlConsole?.connection?.id == connection.id })
        guard let console = editor.active?.sqlConsole else { return }
        check("and runs the query", await eventually(5) { console.current?.result?.rows.count == 3 }, "\(String(describing: console.current))")
        check("its rows, NULL kept", console.current?.result?.rows[1] == ["2", "20.0", nil], "\(console.current?.result?.rows ?? [])")
        check("the console makes room for them", await eventually(3) { editor.consoleHeight.constant > 100 }, "\(editor.consoleHeight.constant)")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.8)
            app.captureWindow(to: png)
        }

        // ⌘↩: the statement at the caret.
        editor.replaceText(of: editor.active!, with: "SELECT count(*) AS n FROM orders;\n\nSELECT note FROM orders WHERE id = 3;\n")
        editor.textView.setSelectedRange(NSRange(location: 40, length: 0))
        _ = editor.runConsoleStatement()
        check("⌘↩ runs the statement at the caret", await eventually(5) { console.current?.result?.rows == [["third"]] }, "\(String(describing: console.current?.result))")

        // Completion from the catalog: tables after FROM, an alias's columns.
        editor.replaceText(of: editor.active!, with: "SELECT * FROM ord")
        editor.textView.setSelectedRange(NSRange(location: 17, length: 0))
        _ = editor.updateSQLCompletion()
        let tables = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("FROM completes the schema's tables", tables.first == "orders", "\(tables)")
        editor.acceptCompletion(at: 0)
        check("and accepting writes the name", editor.textView.string == "SELECT * FROM orders", editor.textView.string)
        editor.replaceText(of: editor.active!, with: "SELECT o.to FROM orders o")
        editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        _ = editor.updateSQLCompletion()
        let columns = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("an alias completes its table's columns", columns == ["total"], "\(columns)")
        editor.dismissCompletion()

        // A statement that destroys is asked about; refused, it isn't sent.
        console.confirm = { _, _ in false }
        console.run(["DELETE FROM orders"])
        await pause(0.5)
        console.run(["SELECT count(*) FROM orders"])
        check("a refused DELETE without WHERE isn't sent", await eventually(5) { console.current?.result?.rows == [["3"]] })

        // Read-only: refused before it is sent.
        var reader = connection
        reader.id = UUID()
        reader.name = "Shop (read-only)"
        reader.readOnly = true
        try? model.store.save(reader)
        console.use(reader)
        console.confirm = { _, _ in true }
        console.run(["INSERT INTO orders VALUES (4, 1, 'x')"])
        check(
            "a read-only connection refuses a write", await eventually(5) { console.current?.error?.contains("only reads") == true },
            console.current?.error ?? "-")
    }
}
