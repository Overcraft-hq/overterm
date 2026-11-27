#if E2E
import AppKit

/// DuckDB in the database client: a file made by the driver, its table in
/// the tree, a nested value in the console's grid as `duckdb` prints it, a
/// CSV beside it read by a query. The database scenario's last part.
extension E2ERunner {
    func duckdbChecks() async {
        let file = scratch.appendingPathComponent("shop.duckdb")
        try? FileManager.default.removeItem(at: file)
        let csv = scratch.appendingPathComponent("prices.csv")
        try? "sku,price\na,1.5\nb,2\n".write(to: csv, atomically: true, encoding: .utf8)
        var connection = DatabaseConnection(name: "Ducks", kind: .duckdb)
        connection.filePath = file.path
        let maker = DuckDBDriver(connection)
        do {
            try await maker.connect()
            _ = try await maker.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, tags VARCHAR[])", limit: 1)
            _ = try await maker.execute("INSERT INTO orders VALUES (1, ['new', 'gift']), (2, [])", limit: 1)
        } catch {
            return check("a DuckDB file is made", false, "\(error)")
        }
        // One program at a time opens a file it can write: the maker lets go.
        await maker.close()

        let model = DatabaseModel.shared
        try? model.store.save(connection)
        let session = model.session(connection)
        await session.open()
        check("a DuckDB connection opens", session.state == .open, "\(session.state)")
        await session.loadTables("main")
        check("its tables are listed", session.tables["main"]?.map(\.name) == ["orders"], "\(session.tables)")

        app.runInDatabaseConsole(connection, "SELECT id, tags FROM orders ORDER BY id;")
        guard let editor = app.editor else { return check("the editor", false) }
        check("its console opens", await eventually(5) { editor.active?.sqlConsole?.connection?.id == connection.id })
        guard let console = editor.active?.sqlConsole else { return }
        check(
            "a LIST reads as duckdb prints it", await eventually(5) { console.current?.result?.rows == [["1", "[new, gift]"], ["2", "[]"]] },
            "\(String(describing: console.current?.result?.rows))")
        console.run(["SELECT sum(price) AS total FROM '\(csv.path)'"])
        check(
            "a CSV beside it is read by a query", await eventually(5) { console.current?.result?.rows == [["3.5"]] },
            "\(String(describing: console.current?.result?.rows)) \(console.current?.error ?? "")")
        await session.close()
    }
}
#endif
