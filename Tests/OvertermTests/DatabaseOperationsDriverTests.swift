import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

/// The Server page, editing and users against real databases: SQLite
/// always; PostgreSQL, MySQL and MariaDB when OVERTERM_DB_TESTS=1 and
/// Scripts/database-test-servers.sh has them running (pg_stat_statements
/// preloaded, performance_schema on).
final class DatabaseOperationsDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(_ kind: DatabaseKind, port: Int, user: String = "ot", readOnly: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(name: kind.title, kind: kind)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.user = user
        connection.database = "shop"
        connection.sslMode = .disable
        connection.readOnly = readOnly
        return connection
    }

    /// Edits made, saved, read back; a Save whose row has gone rolls back whole.
    private func exercise<D: DatabaseTableEditing>(
        _ driver: D, table: String, create: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        _ = try? await driver.execute("DROP TABLE \(table)", limit: 1)
        _ = try await driver.execute(create, limit: 1)
        _ = try await driver.execute("INSERT INTO \(table) (id, note) VALUES (1, 'first'), (2, NULL), (3, 'third')", limit: 1)
        let dialect = await driver.editDialect()
        guard let key = try await driver.key(of: TableName(schema: nil, name: table)) else { return XCTFail("no key", file: file, line: line) }
        XCTAssertEqual(key.columns, ["id"], file: file, line: line)
        XCTAssertEqual(key.kind, .primary, file: file, line: line)
        let read = try await driver.execute("SELECT id, note FROM \(table) ORDER BY id", limit: 100)
        let result = try EditableResult.match(resultColumns: read.columns, tableColumns: ["id", "note"], key: key).get()
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(#"it's; "quoted" \ DROP"#), original: "first")
        edits.set(row: 1, column: 1, to: .text(""), original: nil)
        edits.set(row: 2, column: 1, to: .null, original: "third")
        edits.add([0: .text("4"), 1: .text("new")])
        try await driver.apply(try EditStatements.make(edits, rows: read.rows, result: result, dialect: dialect))
        let after = try await driver.execute("SELECT id, note FROM \(table) ORDER BY id", limit: 100)
        XCTAssertEqual(after.rows, [["1", #"it's; "quoted" \ DROP"#], ["2", ""], ["3", nil], ["4", "new"]], "NULL and '' kept apart", file: file, line: line)

        // The same value again: MySQL says 0 rows changed; the key still finds it.
        var same = PendingEdits()
        same.set(row: 3, column: 1, to: .text("new"), original: "old")
        try await driver.apply(try EditStatements.make(same, rows: after.rows, result: result, dialect: dialect))

        // A row gone since it was read: the whole Save is rolled back — the
        // delete before it, which did find its row, too.
        var stale = PendingEdits()
        stale.delete(rows: [1])
        stale.set(row: 3, column: 1, to: .text("changed"), original: "x")
        var rows = after.rows
        rows[3] = ["99", "gone"]
        do {
            try await driver.apply(try EditStatements.make(stale, rows: rows, result: result, dialect: dialect))
            XCTFail("a missing row saves nothing", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing was saved") || error.localizedDescription.contains("nothing was saved"), error.localizedDescription, file: file, line: line)
        }
        let untouched = try await driver.execute("SELECT note FROM \(table) WHERE id = 2", limit: 1)
        XCTAssertEqual(untouched.rows, [[""]], "the delete rolled back", file: file, line: line)
        _ = try await driver.execute("DROP TABLE \(table)", limit: 1)
    }

    // MARK: SQLite

    func testSQLite() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ot-ops-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var config = DatabaseConnection(name: "local", kind: .sqlite)
        config.filePath = file.path
        let driver = SQLiteDriver(config)
        try await driver.connect()
        try await exercise(driver, table: "orders", create: "CREATE TABLE orders (id INTEGER PRIMARY KEY, note TEXT)")

        _ = try await driver.execute("CREATE TABLE loose (a TEXT, b BLOB)", limit: 1)
        _ = try await driver.execute("INSERT INTO loose VALUES ('x', x'00ff')", limit: 1)
        let rowid = try await driver.key(of: TableName(schema: nil, name: "loose"))
        XCTAssertEqual(rowid?.kind, .rowid)
        XCTAssertEqual(rowid?.readOnlyColumns, ["b"], "a BLOB's text is its size, not its bytes")
        _ = try await driver.execute("CREATE TABLE coded (code TEXT NOT NULL, n INT, UNIQUE (code))", limit: 1)
        let coded = try await driver.key(of: TableName(schema: "main", name: "coded"))
        XCTAssertEqual(coded?.kind, .unique("sqlite_autoindex_coded_1"))
        _ = try await driver.execute("CREATE VIEW v AS SELECT * FROM coded", limit: 1)
        let view = try await driver.key(of: TableName(schema: nil, name: "v"))
        XCTAssertNil(view, "a view isn't edited")

        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Journal" && $0.value == "delete" }, "\(overview.facts)")
        let integrity = try await driver.integrityCheck()
        XCTAssertEqual(integrity, "ok — no problems found.")
        await driver.close()

        // Read-only: nothing is saved.
        config.readOnly = true
        let reader = SQLiteDriver(config)
        try await reader.connect()
        do {
            try await reader.apply([EditStatement(sql: "DELETE FROM loose")])
            XCTFail("read-only")
        } catch {
            XCTAssertEqual(error as? DatabaseError, .readOnly("saving the edits"))
        }
        await reader.close()
    }

    // MARK: PostgreSQL

    func testPostgres() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh running")
        let driver = PostgresDriver(connection(.postgres, port: 55432), password: "otpass")
        try await driver.connect()
        defer { Task { await driver.close() } }
        try await exercise(driver, table: "ops_orders", create: "CREATE TABLE ops_orders (id int PRIMARY KEY, note text)")

        // Without the extension: said, with the lines that turn it on.
        _ = try await driver.execute("DROP EXTENSION IF EXISTS pg_stat_statements", limit: 1)
        let missing = try await driver.slowQueries().gap
        XCTAssertTrue(missing?.reason.contains("isn't installed") == true, "\(String(describing: missing))")
        XCTAssertTrue(missing?.fix?.contains("CREATE EXTENSION pg_stat_statements") == true)
        // The record of statements, once the extension is in this database.
        _ = try await driver.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements", limit: 1)
        _ = try await driver.execute("SELECT count(*) FROM pg_class", limit: 1)
        let slow = try await driver.slowQueries()
        XCTAssertFalse(slow.value?.isEmpty ?? true, "\(slow)")

        // Another session, busy: listed, not ours, cancelled.
        let other = PostgresDriver(connection(.postgres, port: 55432), password: "otpass")
        try await other.connect()
        let sleeping = Task { try await other.execute("SELECT pg_sleep(30)", limit: 1) }
        var busy: DatabaseActivity?
        for _ in 0..<50 where busy == nil {
            try await Task.sleep(for: .milliseconds(100))
            busy = try await driver.activity().value?.first { $0.statement?.contains("pg_sleep(30)") == true && !$0.isOwn }
        }
        guard let busy else { return XCTFail("the other session isn't listed") }
        XCTAssertEqual(busy.state, "active")
        let own = try await driver.activity().value?.first(where: \.isOwn)
        XCTAssertNotNil(own, "this connection's own session is marked")
        do {
            try await driver.cancel(session: own?.id ?? "", terminate: false)
            XCTFail("never one's own session")
        } catch {}
        try await driver.cancel(session: busy.id, terminate: false)
        do {
            _ = try await sleeping.value
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cancel"), error.localizedDescription)
        }

        // A lock: one session holds a row, another waits on it.
        _ = try await driver.execute("CREATE TABLE IF NOT EXISTS ops_lock (id int PRIMARY KEY)", limit: 1)
        _ = try await driver.execute("INSERT INTO ops_lock VALUES (1) ON CONFLICT DO NOTHING", limit: 1)
        let holder = PostgresDriver(connection(.postgres, port: 55432), password: "otpass")
        try await holder.connect()
        _ = try await holder.execute("BEGIN", limit: 1)
        _ = try await holder.execute("UPDATE ops_lock SET id = 1 WHERE id = 1", limit: 1)
        let waiter = Task { try await other.execute("UPDATE ops_lock SET id = 1 WHERE id = 1", limit: 1) }
        var waits: [LockWait] = []
        for _ in 0..<50 where waits.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            waits = try await driver.locks().value ?? []
        }
        XCTAssertEqual(waits.first?.waitingStatement, "UPDATE ops_lock SET id = 1 WHERE id = 1")
        XCTAssertNotNil(waits.first?.lock)
        _ = try await holder.execute("ROLLBACK", limit: 1)
        _ = try await waiter.value
        await holder.close()
        await other.close()
        _ = try await driver.execute("DROP TABLE ops_lock", limit: 1)

        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Connections" }, "\(overview.facts)")
        let sizes = try await driver.sizes().value
        XCTAssertTrue(sizes?.databases.contains { $0.name == "shop" } == true, "\(String(describing: sizes))")
        XCTAssertEqual(sizes?.notes, [])

        // Users: made with a SCRAM verifier, then signed in with the password.
        let name = #"ot app"user"#
        _ = try? await driver.run([try UserStatements.drop(DatabaseUser(name: name), dialect: .postgres)])
        var user = NewUser()
        user.name = name
        user.password = #"pa'ss\word"#
        try await driver.run(try UserStatements.create(user, dialect: .postgres))
        var signIn = connection(.postgres, port: 55432, user: name)
        signIn.database = "shop"
        let signed = PostgresDriver(signIn, password: user.password)
        try await signed.connect()
        let me = try await signed.execute("SELECT current_user", limit: 1).rows
        XCTAssertEqual(me, [[name]], "the verifier is the password's")
        await signed.close()
        let made = DatabaseUser(name: name)
        _ = try await driver.execute("CREATE TABLE IF NOT EXISTS ops_grants (id int)", limit: 1)
        try await driver.run([
            try UserStatements.grant(["SELECT", "INSERT"], on: .table(TableName(schema: "public", name: "ops_grants")), to: made, dialect: .postgres)
        ])
        let grants = try await driver.grants(of: made).value ?? []
        let table = grants.first { $0.kind == "table" && $0.object == "public.ops_grants" }
        XCTAssertEqual(table?.privileges, ["INSERT", "SELECT"], "\(grants)")
        XCTAssertEqual(table?.target, .table(TableName(schema: "public", name: "ops_grants")))
        try await driver.run([try UserStatements.revoke(["INSERT"], on: table!.target!, from: made, dialect: .postgres)])
        let left = try await driver.grants(of: made).value?.first { $0.kind == "table" }?.privileges
        XCTAssertEqual(left, ["SELECT"])
        let users = try await driver.users().value ?? []
        XCTAssertTrue(users.contains { $0.name == name && $0.canLogin }, "\(users)")
        try await driver.run([try UserStatements.revoke(["SELECT"], on: table!.target!, from: made, dialect: .postgres)])
        try await driver.run([try UserStatements.drop(made, dialect: .postgres)])
        let gone = try await driver.users().value?.contains { $0.name == name } ?? true
        XCTAssertFalse(gone)
        _ = try await driver.execute("DROP TABLE ops_grants", limit: 1)
    }

    func testPostgresReadOnlyRefusesEveryWrite() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh running")
        let driver = PostgresDriver(connection(.postgres, port: 55432, readOnly: true), password: "otpass")
        try await driver.connect()
        defer { Task { await driver.close() } }
        _ = try await driver.activity()
        for attempt in [
            { try await driver.cancel(session: "1", terminate: true) }, { try await driver.apply([EditStatement(sql: "DELETE FROM x")]) },
            { try await driver.run([UserStatement("DROP ROLE x")]) },
        ] as [() async throws -> Void] {
            do {
                try await attempt()
                XCTFail("read-only")
            } catch {
                guard case DatabaseError.readOnly = error else { return XCTFail("\(error)") }
            }
        }
    }

    // MARK: MySQL, MariaDB

    func testMySQL() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh running")
        try await exerciseMySQL(.mysql, port: 53306)
    }

    func testMariaDB() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh running")
        try await exerciseMySQL(.mariadb, port: 53307)
    }

    private func exerciseMySQL(_ kind: DatabaseKind, port: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        // root: the users' catalog and other sessions are an administrator's to read.
        let driver = MySQLDriver(connection(kind, port: port, user: "root"), password: "otpass")
        try await driver.connect()
        defer { Task { await driver.close() } }
        try await exercise(driver, table: "ops_orders", create: "CREATE TABLE ops_orders (id int PRIMARY KEY, note text)", file: file, line: line)

        // Another session, busy: listed, KILL QUERY stops it.
        let other = MySQLDriver(connection(kind, port: port), password: "otpass")
        try await other.connect()
        let sleeping = Task { try await other.execute("SELECT SLEEP(30)", limit: 1) }
        var busy: DatabaseActivity?
        for _ in 0..<50 where busy == nil {
            try await Task.sleep(for: .milliseconds(100))
            busy = try await driver.activity().value?.first { $0.statement?.contains("SLEEP(30)") == true }
        }
        guard let busy else { return XCTFail("the other session isn't listed", file: file, line: line) }
        XCTAssertFalse(busy.isOwn, file: file, line: line)
        let mine = try await driver.activity().value?.contains(where: \.isOwn) == true
        XCTAssertTrue(mine, file: file, line: line)
        try await driver.cancel(session: busy.id, terminate: false)
        // SLEEP killed returns 1 rather than failing: either way it's over.
        _ = try? await sleeping.value

        // performance_schema's record of statements.
        _ = try await driver.execute("SELECT COUNT(*) FROM information_schema.TABLES", limit: 1)
        let slow = try await driver.slowQueries()
        XCTAssertFalse(slow.value?.isEmpty ?? true, "\(slow)", file: file, line: line)

        // A lock: one session holds a row, another waits on it.
        _ = try await driver.execute("CREATE TABLE IF NOT EXISTS shop.ops_lock (id int PRIMARY KEY) ENGINE=InnoDB", limit: 1)
        _ = try await driver.execute("INSERT IGNORE INTO shop.ops_lock VALUES (1)", limit: 1)
        let holder = MySQLDriver(connection(kind, port: port), password: "otpass")
        try await holder.connect()
        _ = try await holder.execute("START TRANSACTION", limit: 1)
        _ = try await holder.execute("UPDATE ops_lock SET id = 1 WHERE id = 1", limit: 1)
        let waiter = Task { try await other.execute("UPDATE ops_lock SET id = 1 WHERE id = 1", limit: 1) }
        var waits: [LockWait] = []
        for _ in 0..<50 where waits.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            waits = try await driver.locks().value ?? []
        }
        let locksNow = try await driver.locks()
        XCTAssertEqual(waits.first?.waitingStatement, "UPDATE ops_lock SET id = 1 WHERE id = 1", "\(locksNow)", file: file, line: line)
        _ = try await holder.execute("ROLLBACK", limit: 1)
        _ = try await waiter.value
        await holder.close()
        await other.close()
        _ = try await driver.execute("DROP TABLE shop.ops_lock", limit: 1)

        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Connections" }, "\(overview.facts)", file: file, line: line)
        let sizes = try await driver.sizes().value
        XCTAssertTrue(sizes?.databases.contains { $0.name == "shop" } == true, "\(String(describing: sizes))", file: file, line: line)

        // Users: made with a password that quotes and escapes, signed in with it.
        let dialect = await driver.userDialect()
        let made = DatabaseUser(name: "ot'app", host: "%")
        _ = try? await driver.run([try UserStatements.drop(made, dialect: dialect)])
        var user = NewUser()
        user.name = made.name
        user.password = #"pa'ss\word"#
        try await driver.run(try UserStatements.create(user, dialect: dialect))
        try await driver.run([try UserStatements.grant(["SELECT", "INSERT"], on: .database("shop"), to: made, dialect: dialect)])
        let signed = MySQLDriver(connection(kind, port: port, user: made.name), password: user.password)
        try await signed.connect()
        let one = try await signed.execute("SELECT 1", limit: 1).rows
        XCTAssertEqual(one, [["1"]], file: file, line: line)
        await signed.close()
        let grants = try await driver.grants(of: made).value ?? []
        let shop = grants.first { $0.kind == "database" }
        XCTAssertEqual(Set(shop?.privileges ?? []), ["SELECT", "INSERT"], "\(grants)", file: file, line: line)
        XCTAssertEqual(shop?.target, .database("shop"), file: file, line: line)
        XCTAssertFalse(grants.description.contains("IDENTIFIED"), "no password hash in a grant: \(grants)", file: file, line: line)
        try await driver.run([try UserStatements.revoke(["INSERT"], on: .database("shop"), from: made, dialect: dialect)])
        let left = try await driver.grants(of: made).value?.first { $0.kind == "database" }?.privileges
        XCTAssertEqual(left, ["SELECT"], file: file, line: line)
        let users = try await driver.users().value ?? []
        XCTAssertTrue(users.contains { $0.name == made.name && $0.host == "%" }, "\(users)", file: file, line: line)
        try await driver.run([try UserStatements.drop(made, dialect: dialect)])

        // A user who may not read mysql.user is told so.
        let plain = MySQLDriver(connection(kind, port: port), password: "otpass")
        try await plain.connect()
        let gap = try await plain.users().gap
        XCTAssertNotNil(gap, file: file, line: line)
        await plain.close()
    }
}
