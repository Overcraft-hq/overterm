import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase

/// DuckDB against its own library (Scripts/fetch-duckdb.sh), on files of the
/// test's own and in memory: values as text — a LIST, a STRUCT, a MAP as
/// `duckdb` prints them —, the catalog, keys, a Save in one transaction,
/// read-only, a cancelled scan; and what an agent may run without asking.
final class DuckDBTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + ".wal"))
        }
        files = []
    }

    private func file(_ ext: String = "duckdb") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ot-\(UUID().uuidString).\(ext)")
        files.append(url)
        return url
    }

    private func connection(_ path: String, readOnly: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "local", kind: .duckdb)
        connection.filePath = path
        connection.readOnly = readOnly
        return connection
    }

    func testStatementsAndValues() async throws {
        let driver = DuckDBDriver(connection(file().path))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, note VARCHAR)", limit: 10)
        let inserted = try await driver.execute("INSERT INTO orders (id, note) VALUES (1, 'first'), (2, NULL), (3, 'it''s; third')", limit: 10)
        XCTAssertFalse(inserted.hasRows)
        XCTAssertEqual(inserted.affected, 3)
        let all = try await driver.execute("SELECT id, note FROM orders ORDER BY id", limit: 100)
        XCTAssertEqual(all.columns, ["id", "note"])
        XCTAssertEqual(all.types, ["INTEGER", "VARCHAR"])
        XCTAssertEqual(all.rows, [["1", "first"], ["2", nil], ["3", "it's; third"]])
        let limited = try await driver.execute("SELECT id FROM orders ORDER BY id;", limit: 2)
        XCTAssertEqual(limited.rows, [["1"], ["2"]])
        XCTAssertTrue(limited.truncated, "more rows than the limit")
        let fromFirst = try await driver.execute("FROM orders ORDER BY id DESC -- the newest", limit: 1)
        XCTAssertEqual(fromFirst.rows, [["3", "it's; third"]], "DuckDB's FROM-first, a comment on its last line")
        do {
            _ = try await driver.execute("SELECT nope FROM orders", limit: 10)
            XCTFail("a missing column")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nope"), error.localizedDescription)
        }
        // Nested values as `duckdb` prints them; the statement's own names, twice the same one too.
        let nested = try await driver.execute(
            #"SELECT [1,2] AS l, {'a': 1, 'b': 'x y'} AS s, MAP {'k': 2} AS m, 1.5::DECIMAL(4,2) AS d, '{"a":1}'::JSON AS j, 1 AS a, 2 AS a"#,
            limit: 10)
        XCTAssertEqual(nested.columns, ["l", "s", "m", "d", "j", "a", "a"])
        XCTAssertEqual(nested.types, ["LIST", "STRUCT", "MAP", "DECIMAL(4,2)", "JSON", "INTEGER", "INTEGER"])
        XCTAssertEqual(nested.rows, [["[1, 2]", "{'a': 1, 'b': x y}", "{k=2}", "1.50", #"{"a":1}"#, "1", "2"]])
        let empty = try await driver.execute("SELECT 1 AS a WHERE false", limit: 10)
        XCTAssertEqual(empty.columns, ["a"], "an empty result keeps its columns")
        let pragma = try await driver.execute("PRAGMA table_info('orders')", limit: 10)
        XCTAssertEqual(pragma.rows.count, 2, "a statement that isn't a SELECT runs as it is")
        let begin = try await driver.execute("BEGIN TRANSACTION", limit: 1)
        XCTAssertFalse(begin.hasRows)
        _ = try await driver.execute("COMMIT", limit: 1)
        let returning = try await driver.execute("INSERT INTO orders VALUES (9, 'r') RETURNING id", limit: 10)
        XCTAssertEqual(returning.rows, [["9"]])

        let schemas = try await driver.schemas()
        XCTAssertEqual(schemas, ["main"])
        let tables = try await driver.tables(in: "main")
        XCTAssertEqual(tables.map(\.name), ["orders"])
        let columns = try await driver.columns(in: "main")
        XCTAssertEqual(columns.map(\.name), ["id", "note"])
        XCTAssertEqual(columns.map(\.nullable), [false, true])
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "DuckDB" && $0.value.hasPrefix("v") }, "\(overview.facts)")
        XCTAssertTrue(overview.facts.contains { $0.title == "Tables" && $0.value == "1" }, "\(overview.facts)")
        await driver.close()
    }

    func testFilesAndMemory() async throws {
        let memory = DuckDBDriver(connection(DuckDBDriver.memory))
        try await memory.connect()
        // No extension fetched or loaded by itself; CSV, Parquet and JSON are the library's own.
        let settings = try await memory.execute(
            "SELECT current_setting('autoload_known_extensions') AS a, current_setting('autoinstall_known_extensions') AS b", limit: 1)
        XCTAssertEqual(settings.rows, [["false", "false"]])
        let csv = file("csv")
        try "a,b\n1,x\n".write(to: csv, atomically: true, encoding: .utf8)
        let read = try await memory.execute("SELECT * FROM '\(csv.path)'", limit: 5)
        XCTAssertEqual(read.rows, [["1", "x"]])
        let parquet = file("parquet")
        _ = try await memory.execute("COPY (SELECT 1 AS a) TO '\(parquet.path)' (FORMAT parquet)", limit: 1)
        let back = try await memory.execute("SELECT * FROM read_parquet('\(parquet.path)')", limit: 5)
        XCTAssertEqual(back.rows, [["1"]])
        await memory.close()

        // Read-only: DuckDB itself refuses the write.
        let path = file().path
        let writer = DuckDBDriver(connection(path))
        try await writer.connect()
        _ = try await writer.execute("CREATE TABLE t (a INT)", limit: 1)
        await writer.close()
        let reader = DuckDBDriver(connection(path, readOnly: true))
        try await reader.connect()
        do {
            _ = try await reader.execute("CREATE TABLE x (a INT)", limit: 1)
            XCTFail("a read-only file was written")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("read-only"), error.localizedDescription)
        }
        do {
            try await reader.apply([EditStatement(sql: "DELETE FROM t")])
            XCTFail("read-only")
        } catch {
            XCTAssertEqual(error as? DatabaseError, .readOnly("saving the edits"))
        }
        await reader.close()
        do {
            try await DuckDBDriver(connection(path + ".missing", readOnly: true)).connect()
            XCTFail("a read-only connection made a file")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("No file at"), error.localizedDescription)
        }
    }

    /// DuckDB's lock is the process's: the app opens a file once, however
    /// many connections (and Test buttons) ask for it — a second one closed
    /// keeps the first's lock, and read-only beside writable is refused.
    func testOneFileIsOneDatabase() async throws {
        let path = file().path
        let first = DuckDBDriver(connection(path))
        try await first.connect()
        _ = try await first.execute("CREATE TABLE t (x INT)", limit: 1)
        let second = DuckDBDriver(connection(path))
        try await second.connect()
        let seen = try await second.execute("SELECT count(*) FROM t", limit: 1)
        XCTAssertEqual(seen.rows, [["0"]], "the same database")
        await second.close()
        let after = try await first.execute("INSERT INTO t VALUES (1)", limit: 1)
        XCTAssertEqual(after.affected, 1, "the first keeps working once the second closed")
        do {
            try await DuckDBDriver(connection(path, readOnly: true)).connect()
            XCTFail("read-only beside writable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("open in Overterm already"), error.localizedDescription)
        }
        await first.close()
        let memory = DuckDBDriver(connection(DuckDBDriver.memory))
        try await memory.connect()
        _ = try await memory.execute("CREATE TABLE only_here (a INT)", limit: 1)
        let other = DuckDBDriver(connection(DuckDBDriver.memory))
        try await other.connect()
        let tables = try await other.tables(in: "main")
        XCTAssertEqual(tables, [], "each in-memory database its own")
    }

    func testACancelledRunStops() async throws {
        let driver = DuckDBDriver(connection(DuckDBDriver.memory))
        try await driver.connect()
        let run = Task { try await driver.execute("SELECT count(*) FROM range(10000000000) a", limit: 1) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("ten billion rows counted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Interrupt"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        await driver.close()
    }

    func testKeysAndSave() async throws {
        let driver = DuckDBDriver(connection(file().path))
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, note VARCHAR)", limit: 1)
        _ = try await driver.execute("INSERT INTO orders VALUES (1, 'first'), (2, NULL), (3, 'third')", limit: 1)
        let primary = try await driver.key(of: TableName(schema: nil, name: "ORDERS"))
        XCTAssertEqual(primary?.kind, .primary)
        XCTAssertEqual(primary?.table, TableName(schema: "main", name: "orders"), "found as an unquoted name is")
        _ = try await driver.execute("CREATE TABLE coded (code VARCHAR NOT NULL UNIQUE, n INT, tags INT[])", limit: 1)
        let unique = try await driver.key(of: TableName(schema: "main", name: "coded"))
        XCTAssertEqual(unique?.kind, .unique("coded_code_key"))
        XCTAssertEqual(unique?.readOnlyColumns, ["tags"], "a LIST's text isn't written back")
        _ = try await driver.execute("CREATE TABLE pair (a INT, b INT, PRIMARY KEY (b, a))", limit: 1)
        let pair = try await driver.key(of: TableName(schema: nil, name: "pair"))
        XCTAssertEqual(pair?.columns, ["b", "a"], "the key's own order")
        _ = try await driver.execute("CREATE TABLE loose (a INT)", limit: 1)
        let loose = try await driver.key(of: TableName(schema: nil, name: "loose"))
        XCTAssertNil(loose, "no key: never its rowid")
        _ = try await driver.execute("CREATE VIEW v AS SELECT * FROM orders", limit: 1)
        let view = try await driver.key(of: TableName(schema: nil, name: "v"))
        XCTAssertNil(view, "a view isn't edited")

        // A Save through the grid's statements, then one whose row is gone: nothing of it is kept.
        guard let primary else { return XCTFail("no key") }
        let read = try await driver.execute("SELECT id, note FROM orders ORDER BY id", limit: 100)
        let result = try EditableResult.match(resultColumns: read.columns, tableColumns: ["id", "note"], key: primary).get()
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(#"it's; "quoted" \ DROP"#), original: "first")
        edits.set(row: 1, column: 1, to: .text(""), original: nil)
        edits.set(row: 2, column: 1, to: .null, original: "third")
        edits.add([0: .text("4"), 1: .text("new")])
        let dialect = await driver.editDialect()
        try await driver.apply(try EditStatements.make(edits, rows: read.rows, result: result, dialect: dialect))
        let after = try await driver.execute("SELECT id, note FROM orders ORDER BY id", limit: 100)
        XCTAssertEqual(after.rows, [["1", #"it's; "quoted" \ DROP"#], ["2", ""], ["3", nil], ["4", "new"]], "NULL and '' kept apart")
        var stale = PendingEdits()
        stale.delete(rows: [1])
        stale.set(row: 3, column: 1, to: .text("changed"), original: "x")
        var rows = after.rows
        rows[3] = ["99", "gone"]
        do {
            try await driver.apply(try EditStatements.make(stale, rows: rows, result: result, dialect: dialect))
            XCTFail("a missing row saves nothing")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("nothing was saved"), error.localizedDescription)
        }
        let untouched = try await driver.execute("SELECT note FROM orders WHERE id = 2", limit: 1)
        XCTAssertEqual(untouched.rows, [[""]], "the delete rolled back")
        await driver.close()
    }

    func testWhatAnAgentRunsWithoutAsking() {
        for read in [
            "SELECT * FROM orders", "FROM orders LIMIT 3", "SUMMARIZE orders", "PRAGMA table_info('orders')", "DESCRIBE orders",
            "SELECT 'it''s fine' AS a -- read_csv('x') in a comment", "SELECT name FROM t WHERE name = 'bob'",
        ] {
            XCTAssertTrue(DatabaseKind.duckdb.agentReads(read), read)
        }
        for asked in [
            "SELECT * FROM 'orders.csv'", "FROM '/etc/hosts'", "SELECT * FROM read_text('~/.ssh/id_rsa')", "SELECT * FROM READ_CSV ('x')",
            "SELECT * FROM query('DROP TABLE t')", #"SELECT * FROM "data.parquet""#, "SELECT * FROM 's3://bucket/x'", "INSERT INTO t VALUES (1)",
            "ATTACH 'other.db'", "COPY t TO 'x.csv'", "INSTALL httpfs", "PRAGMA import_database('x')", "WITH a AS (DELETE FROM t RETURNING *) SELECT * FROM a",
            // A function's name quoted, a path built at run time, a dollar-quoted string.
            #"SELECT content FROM "read_text"(chr(47)||'Users'||chr(47)||'.aws')"#, #"SELECT * FROM "main"."read_csv"('x')"#,
            "SELECT * FROM $$~/secret.csv$$", "SELECT * FROM $a$/etc/hosts$a$",
        ] {
            XCTAssertFalse(DatabaseKind.duckdb.agentReads(asked), asked)
        }
        XCTAssertTrue(DatabaseKind.duckdb.agentReads(#"SELECT "note" FROM "orders" WHERE id = $1"#), "a parameter isn't a string")
        XCTAssertTrue(DatabaseKind.duckdb.onlyReads("FROM t"))
        XCTAssertFalse(DatabaseKind.duckdb.onlyReads("INSTALL httpfs"), "refused on a read-only connection")
        XCTAssertEqual(DuckText.outside("SELECT * FROM 'a.csv'"), "It names “a.csv”, which DuckDB reads as a file or a URL.")
        XCTAssertEqual(DuckText.outside("SELECT * FROM read_parquet('x')"), "It calls read_parquet(), which reads outside the database or runs text as SQL.")
        XCTAssertNil(DuckText.outside("SELECT name FROM t WHERE name = 'bob'"))
    }

    @MainActor func testPure() {
        XCTAssertEqual(DuckDBOps.asText("SELECT 1; \n", limit: 5), "SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (\nSELECT 1\n) LIMIT 5")
        XCTAssertTrue(DuckDBOps.isNested("INTEGER[]"))
        XCTAssertTrue(DuckDBOps.isNested("STRUCT(a INTEGER)"))
        XCTAssertFalse(DuckDBOps.isNested("VARCHAR"))
        let lock = #"IO Error: Could not set lock on file "/x.duckdb": Conflicting lock is held in /usr/local/bin/duckdb (PID 4)"#
        XCTAssertTrue(DuckDBOps.explainOpen(lock).hasSuffix("Close it there, then connect again."))
        XCTAssertEqual(DuckDBOps.explainOpen("IO Error: Could not read block 4"), "IO Error: Could not read block 4")
        XCTAssertEqual(DatabaseKind.duckdb.features, [.monitoring, .editing])
        XCTAssertNil(DatabaseKind.duckdb.defaultPort)
        XCTAssertEqual(DatabaseConnection(name: "a", kind: .duckdb).problem, "Choose the database file, or keep it in memory.")
        var memory = DatabaseConnection(name: "a", kind: .duckdb)
        memory.filePath = DuckDBDriver.memory
        XCTAssertNil(memory.problem)
        XCTAssertEqual(memory.summary, "In memory")
        XCTAssertEqual(DatabaseSession.startingSchema(DatabaseConnection(name: "a", kind: .duckdb), schemas: ["other", "main"]), "main")
    }
}
