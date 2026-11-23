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

/// Oracle's and ClickHouse's Server page, editing and users against real
/// servers, when OVERTERM_DB_TESTS=1: ClickHouse from
/// Scripts/database-test-servers.sh (:58123), Oracle Database Free from
/// `Scripts/database-test-servers.sh oracle` (:51521, FREEPDB1). BigQuery has
/// no server to test against: its parts are pure (DatabaseOperationsKindsTests).
final class DatabaseOperationsKindsDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(_ kind: DatabaseKind, port: Int, user: String, database: String, readOnly: Bool = false) -> DatabaseConnection {
        var connection = DatabaseConnection(name: kind.title, kind: kind)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.user = user
        connection.database = database
        connection.sslMode = .disable
        connection.readOnly = readOnly
        return connection
    }

    private func refusesEveryWrite(_ driver: some DatabaseMonitoring & DatabaseTableEditing, file: StaticString = #filePath, line: UInt = #line) async {
        for attempt in [{ try await driver.cancel(session: "1,1", terminate: false) }, { try await driver.apply([EditStatement(sql: "DELETE FROM x")]) }]
            as [() async throws -> Void]
        {
            do {
                try await attempt()
                XCTFail("read-only", file: file, line: line)
            } catch {
                guard case DatabaseError.readOnly = error else { return XCTFail("\(error)", file: file, line: line) }
            }
        }
    }

    // MARK: ClickHouse

    private func clickhouse(user: String = "ot", password: String = "otpass", readOnly: Bool = false) -> ClickHouseDriver {
        ClickHouseDriver(connection(.clickhouse, port: 58123, user: user, database: "shop", readOnly: readOnly), password: password)
    }

    func testClickHouse() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh running")
        let driver = clickhouse()
        try await driver.connect()

        // Rows edited as mutations, in a MergeTree found by its key.
        _ = try await driver.execute("DROP TABLE IF EXISTS ops_orders", limit: 1)
        _ = try await driver.execute("CREATE TABLE ops_orders (id UInt64, day Date, note Nullable(String)) ENGINE = MergeTree ORDER BY id", limit: 1)
        _ = try await driver.execute("INSERT INTO ops_orders VALUES (1, '2024-01-01', 'first'), (2, '2024-01-02', NULL), (3, '2024-01-03', 'third')", limit: 1)
        guard let key = try await driver.key(of: TableName(schema: nil, name: "ops_orders")) else { return XCTFail("no key") }
        XCTAssertEqual(key.columns, ["id"])
        XCTAssertEqual(key.table, TableName(schema: "shop", name: "ops_orders"))
        XCTAssertEqual(key.fixedColumns, ["id"])
        let read = try await driver.execute("SELECT id, day, note FROM ops_orders ORDER BY id", limit: 100)
        let result = try EditableResult.match(resultColumns: read.columns, tableColumns: ["id", "day", "note"], key: key).get()
        var edits = PendingEdits()
        edits.set(row: 0, column: 2, to: .text(#"it's; "quoted" \ DROP"#), original: "first")
        edits.set(row: 1, column: 2, to: .text(""), original: nil)
        edits.set(row: 2, column: 2, to: .null, original: "third")
        edits.set(row: 2, column: 1, to: .text("2025-05-05"), original: "2024-01-03")
        edits.add([0: .text("4"), 1: .text("2024-02-29"), 2: .text("new")])
        try await driver.apply(try await driver.editStatements(edits, rows: read.rows, result: result))
        let after = try await driver.execute("SELECT id, day, note FROM ops_orders ORDER BY id", limit: 100)
        XCTAssertEqual(
            after.rows, [["1", "2024-01-01", #"it's; "quoted" \ DROP"#], ["2", "2024-01-02", ""], ["3", "2025-05-05", nil], ["4", "2024-02-29", "new"]],
            "NULL and '' kept apart")

        // No transaction: a Save stops at the statement whose row is gone,
        // the ones before it stay — and the error says so.
        var stale = PendingEdits()
        stale.delete(rows: [1])
        stale.set(row: 3, column: 2, to: .text("changed"), original: "x")
        var rows = after.rows
        rows[3] = ["99", "2024-01-01", "gone"]
        do {
            try await driver.apply(try ClickHouseOps.editStatements(stale, rows: rows, result: result))
            XCTFail("a missing row stops the Save")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("The 1 before it were applied"), error.localizedDescription)
        }
        let left = try await driver.execute("SELECT count() FROM ops_orders", limit: 1).rows
        XCTAssertEqual(left, [["3"]], "the delete before it stays")
        // A key that finds two rows changes neither.
        _ = try await driver.execute("INSERT INTO ops_orders VALUES (1, '2024-01-01', 'twin')", limit: 1)
        var twin = PendingEdits()
        twin.set(row: 0, column: 2, to: .text("x"), original: "first")
        do {
            try await driver.apply(try ClickHouseOps.editStatements(twin, rows: after.rows, result: result))
            XCTFail("the key finds two rows")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("finds 2 rows"), error.localizedDescription)
        }

        // A query running elsewhere: listed, not ours, cancelled.
        let other = clickhouse()
        let sleeping = Task { try await other.execute("SELECT sleepEachRow(0.5) FROM numbers(60) SETTINGS max_block_size = 1", limit: 1) }
        var busy: DatabaseActivity?
        for _ in 0..<50 where busy == nil {
            try await Task.sleep(for: .milliseconds(100))
            busy = try await driver.activity().value?.first { $0.statement?.contains("sleepEachRow") == true }
        }
        guard let busy else { return XCTFail("the running query isn't listed") }
        XCTAssertFalse(busy.isOwn)
        let mine = try await driver.activity().value?.contains(where: \.isOwn) == true
        XCTAssertTrue(mine, "the page's own read is marked")
        try await driver.cancel(session: busy.id, terminate: false)
        do {
            _ = try await sleeping.value
            XCTFail("cancelled")
        } catch {}
        do {
            try await driver.cancel(session: busy.id, terminate: true)
            XCTFail("no session to end")
        } catch {}

        // The record of statements, without the page's own reads.
        _ = try await driver.execute("SELECT count() FROM system.tables", limit: 1)
        _ = try await driver.execute("SYSTEM FLUSH LOGS", limit: 1)
        let slow = try await driver.slowQueries().value ?? []
        XCTAssertFalse(slow.isEmpty)
        XCTAssertFalse(slow.contains { $0.statement.contains("overterm server page") }, "the page leaves its own reads out")

        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Connections" && $0.value.contains("/") }, "\(overview.facts)")
        let sizes = try await driver.sizes().value
        XCTAssertTrue(sizes?.tables.contains { $0.schema == "shop" && $0.name == "ops_orders" } == true, "\(String(describing: sizes))")
        _ = try await driver.execute("DROP TABLE ops_orders", limit: 1)

        // Users: made with a salted hash, signed in with the password.
        let made = DatabaseUser(name: "ot app")
        _ = try? await driver.run([try ClickHouseUserStatements().drop(made)])
        _ = try? await driver.run([try ClickHouseUserStatements().drop(DatabaseUser(name: "ot_readers", isRole: true))])
        var user = NewUser()
        user.name = made.name
        user.password = #"pa'ss\word"#
        try await driver.run(try ClickHouseUserStatements().create(user))
        let signed = clickhouse(user: made.name, password: user.password)
        let me = try await signed.execute("SELECT currentUser()", limit: 1).rows
        XCTAssertEqual(me, [[made.name]], "the hash is the password's")
        try await driver.run([try ClickHouseUserStatements().grant(["SELECT", "INSERT"], on: .database("shop"), to: made, grantOption: false)])
        _ = try await driver.execute("CREATE ROLE ot_readers", limit: 1)
        try await driver.run([try ClickHouseUserStatements().grantRole(DatabaseUser(name: "ot_readers", isRole: true), to: made)])
        let grants = try await driver.grants(of: made).value ?? []
        let shop = grants.first { $0.kind == "database" }
        XCTAssertEqual(Set(shop?.privileges ?? []), ["SELECT", "INSERT"], "\(grants)")
        XCTAssertEqual(shop?.target, .database("shop"))
        XCTAssertTrue(grants.contains { $0.kind == "role" && $0.object == "ot_readers" })
        try await driver.run([try XCTUnwrap(ClickHouseUserStatements().revoke(DatabaseGrant(kind: "database", object: "shop.*", privileges: ["INSERT"], target: .database("shop")), from: made))])
        let kept = try await driver.grants(of: made).value?.first { $0.kind == "database" }?.privileges
        XCTAssertEqual(kept, ["SELECT"])
        let users = try await driver.users().value ?? []
        XCTAssertEqual(users.first { $0.name == made.name }?.memberOf, ["ot_readers"])
        let maker = ClickHouseUserStatements()
        XCTAssertTrue(maker.offers(.drop, on: try XCTUnwrap(users.first { $0.name == made.name })))
        XCTAssertFalse(maker.offers(.drop, on: try XCTUnwrap(users.first { $0.name == "ot" })), "users.xml's: SQL can't change it")
        XCTAssertFalse("\(users)".contains("otpass"))
        try await driver.run([try ClickHouseUserStatements().drop(made), try ClickHouseUserStatements().drop(DatabaseUser(name: "ot_readers", isRole: true))])
        let gone = try await driver.users().value?.contains { $0.name == made.name } ?? true
        XCTAssertFalse(gone)

        await refusesEveryWrite(clickhouse(readOnly: true))
        await driver.close()
    }

    // MARK: Oracle

    /// Closed when the test ends, whatever happened: OracleNIO asserts on a
    /// connection let go unclosed.
    private func oracle(user: String = "ot", password: String = "otpass", readOnly: Bool = false) -> OracleDriver {
        let driver = OracleDriver(connection(.oracle, port: 51521, user: user, database: "FREEPDB1", readOnly: readOnly), password: password)
        addTeardownBlock { await driver.close() }
        return driver
    }

    /// Rows edited by the primary key and by ROWID; dates and timestamps
    /// written back as the grid shows them.
    func testOracleEditing() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with `Scripts/database-test-servers.sh oracle` running")
        let driver = oracle()
        try await driver.connect()
        _ = try? await driver.execute("DROP TABLE ops_orders PURGE", limit: 1)
        _ = try await driver.execute("CREATE TABLE ops_orders (id NUMBER PRIMARY KEY, note VARCHAR2(100), d DATE, ts TIMESTAMP, total NUMBER(10,2))", limit: 1)
        for row in [
            "1, 'first', DATE '2024-01-01', TIMESTAMP '2024-01-01 10:00:00.25', 1.5", "2, NULL, NULL, NULL, NULL",
            "3, 'third', TO_DATE('2024-01-03 13:45:00', 'YYYY-MM-DD HH24:MI:SS'), NULL, 3",
        ] {
            _ = try await driver.execute("INSERT INTO ops_orders VALUES (\(row))", limit: 1)
        }
        // An unquoted name: found as Oracle reads it.
        guard let key = try await driver.key(of: TableName(schema: nil, name: "ops_orders")) else { return XCTFail("no key") }
        XCTAssertEqual(key.columns, ["ID"])
        XCTAssertEqual(key.kind, .primary)
        XCTAssertEqual(key.table, TableName(schema: "OT", name: "OPS_ORDERS"))
        let read = try await driver.execute("SELECT * FROM ops_orders ORDER BY id", limit: 100)
        XCTAssertEqual(read.rows[0], ["1", "first", "2024-01-01", "2024-01-01 10:00:00.25", "1.5"], "the grid's text")
        let result = try EditableResult.match(resultColumns: read.columns, tableColumns: ["ID", "NOTE", "D", "TS", "TOTAL"], key: key).get()
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(#"it's; "quoted" \ DROP"#), original: "first")
        edits.set(row: 1, column: 2, to: .text("2024-02-29 23:59:58"), original: nil)
        edits.set(row: 1, column: 3, to: .text("2024-02-29 23:59:58.123456"), original: nil)
        edits.set(row: 1, column: 4, to: .text("12.75"), original: nil)
        edits.set(row: 2, column: 2, to: .text("2025-05-05"), original: "2024-01-03 13:45:00")
        edits.add([0: .text("4"), 1: .text("new"), 2: .text("2024-02-29")])
        try await driver.apply(try OracleOps.editStatements(edits, rows: read.rows, result: result))
        let after = try await driver.execute("SELECT * FROM ops_orders ORDER BY id", limit: 100)
        XCTAssertEqual(
            after.rows,
            [
                ["1", #"it's; "quoted" \ DROP"#, "2024-01-01", "2024-01-01 10:00:00.25", "1.5"],
                ["2", nil, "2024-02-29 23:59:58", "2024-02-29 23:59:58.123456", "12.75"], ["3", "third", "2025-05-05", nil, "3"],
                ["4", "new", "2024-02-29", nil, nil],
            ])
        // Each value's own text found the row again (a DATE key's included),
        // and the session's formats are back as they were.
        let format = try await driver.execute("SELECT value FROM nls_session_parameters WHERE parameter = 'NLS_DATE_FORMAT'", limit: 1).rows.first?.first ?? nil
        XCTAssertNotEqual(format, "YYYY-MM-DD HH24:MI:SS")

        // A row gone: the whole Save rolled back, the delete before it too.
        var stale = PendingEdits()
        stale.delete(rows: [0])
        stale.set(row: 3, column: 1, to: .text("changed"), original: "x")
        var rows = after.rows
        rows[3] = ["99", "gone", nil, nil, nil]
        do {
            try await driver.apply(try OracleOps.editStatements(stale, rows: rows, result: result))
            XCTFail("a missing row saves nothing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing was saved"), error.localizedDescription)
        }
        let count = try await driver.execute("SELECT COUNT(*) FROM ops_orders", limit: 1).rows
        XCTAssertEqual(count, [["4"]], "the delete rolled back")

        // No key: ROWID, which the result must hold.
        _ = try? await driver.execute("DROP TABLE ops_loose PURGE", limit: 1)
        _ = try await driver.execute("CREATE TABLE ops_loose (note VARCHAR2(20), body CLOB)", limit: 1)
        _ = try await driver.execute("INSERT INTO ops_loose VALUES ('a', 'long text')", limit: 1)
        guard let rowid = try await driver.key(of: TableName(schema: "OT", name: "OPS_LOOSE")) else { return XCTFail("no ROWID key") }
        XCTAssertEqual(rowid.kind, .rowid)
        XCTAssertEqual(rowid.readOnlyColumns, ["BODY"], "a CLOB's text is its start")
        let loose = try await driver.execute("SELECT ROWID, t.* FROM ops_loose t", limit: 10)
        let looseResult = try EditableResult.match(resultColumns: loose.columns, tableColumns: ["NOTE", "BODY"], key: rowid).get()
        var change = PendingEdits()
        change.set(row: 0, column: 1, to: .text("b"), original: "a")
        try await driver.apply(try OracleOps.editStatements(change, rows: loose.rows, result: looseResult))
        let changed = try await driver.execute("SELECT note FROM ops_loose", limit: 1).rows
        XCTAssertEqual(changed, [["b"]])
        _ = try await driver.execute("DROP TABLE ops_loose PURGE", limit: 1)
        _ = try await driver.execute("DROP TABLE ops_orders PURGE", limit: 1)

        // Without SELECT_CATALOG_ROLE: said, with the grant.
        let gap = try await driver.activity().gap
        XCTAssertTrue(gap?.fix?.contains("SELECT_CATALOG_ROLE") == true, "\(String(describing: gap))")
        let users = try await driver.users().gap
        XCTAssertNotNil(users)
        let sizes = try await driver.sizes().value
        XCTAssertTrue(sizes?.notes.contains { $0.contains("user_segments") } == true, "\(String(describing: sizes))")
        let own = try await driver.grants(of: DatabaseUser(name: "OT")).value
        XCTAssertTrue(own?.contains { $0.kind == "role" } == true, "this user's own grants are user_*'s: \(String(describing: own))")
        let overview = try await driver.overview()
        XCTAssertTrue(overview.notes.contains { $0.contains("SELECT_CATALOG_ROLE") }, "\(overview)")
        await driver.close()

        await refusesEveryWrite(oracle(readOnly: true))
    }

    /// As SYSTEM: sessions, a statement cancelled, a lock, a session
    /// killed, the record of statements, sizes, users.
    func testOracleServer() async throws {
        try XCTSkipUnless(servers, "OVERTERM_DB_TESTS=1 with `Scripts/database-test-servers.sh oracle` running")
        let driver = oracle(user: "system")
        try await driver.connect()
        let overview = try await driver.overview()
        XCTAssertTrue(overview.facts.contains { $0.title == "Sessions" && $0.value.contains("/") }, "\(overview.facts)")
        XCTAssertTrue(overview.notes.isEmpty, "\(overview.notes)")

        let other = oracle()
        try await other.connect()
        let sleeping = Task { try await other.execute("BEGIN DBMS_SESSION.SLEEP(30); END;", limit: 1) }
        var busy: DatabaseActivity?
        for _ in 0..<80 where busy == nil {
            try await Task.sleep(for: .milliseconds(100))
            busy = try await driver.activity().value?.first { $0.statement?.contains("DBMS_SESSION.SLEEP(30)") == true }
        }
        guard let busy else { return XCTFail("the other session isn't listed") }
        XCTAssertEqual(busy.state, "active")
        XCTAssertFalse(busy.isOwn)
        guard let own = try await driver.activity().value?.first(where: \.isOwn) else { return XCTFail("this connection's own session is marked") }
        do {
            try await driver.cancel(session: own.id, terminate: false)
            XCTFail("never one's own session")
        } catch {}
        try await driver.cancel(session: busy.id, terminate: false)
        do {
            _ = try await sleeping.value
            XCTFail("cancelled")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("01013") || error.localizedDescription.lowercased().contains("cancel"), error.localizedDescription)
        }

        // A lock: a block holds a row while it sleeps; another waits on it.
        _ = try? await driver.execute("DROP TABLE ot.ops_lock PURGE", limit: 1)
        _ = try await driver.execute("CREATE TABLE ot.ops_lock (id NUMBER PRIMARY KEY)", limit: 1)
        _ = try await driver.execute("INSERT INTO ot.ops_lock VALUES (1)", limit: 1)
        let holder = oracle()
        try await holder.connect()
        let holding = Task { try await holder.execute("BEGIN UPDATE ops_lock SET id = id WHERE id = 1; DBMS_SESSION.SLEEP(4); END;", limit: 1) }
        try await Task.sleep(for: .milliseconds(500))
        let waiting = Task { try await other.execute("UPDATE ops_lock SET id = id WHERE id = 1", limit: 1) }
        var waits: [LockWait] = []
        for _ in 0..<30 where waits.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            waits = try await driver.locks().value ?? []
        }
        XCTAssertTrue(waits.first?.waitingStatement?.contains("UPDATE ops_lock") == true, "\(waits)")
        XCTAssertTrue(waits.first?.lock?.contains("OPS_LOCK") == true, "\(waits)")
        // The block ends, its update commits, the waiter goes on.
        _ = try await holding.value
        _ = try await waiting.value
        _ = try await driver.execute("DROP TABLE ot.ops_lock PURGE", limit: 1)

        // Another of Overterm's own sessions isn't ended from here: a
        // statement on a killed session never comes back in OracleNIO.
        let idle = try await driver.activity().value?.first { $0.user == "OT" && $0.application == OracleOps.programName }
        XCTAssertNotNil(idle)
        do {
            try await driver.cancel(session: idle?.id ?? "", terminate: true)
            XCTFail("never one of Overterm's own")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Overterm's own"), error.localizedDescription)
        }

        let slow = try await driver.slowQueries().value ?? []
        XCTAssertFalse(slow.isEmpty)
        let sizes = try await driver.sizes().value
        XCTAssertTrue(sizes?.databases.contains { $0.name == "SYS" } == true, "\(String(describing: sizes))")

        // Users: made, signed in with the password, granted, revoked, dropped.
        let name = "OT_APP"
        _ = try? await driver.run([try OracleUserStatements().drop(DatabaseUser(name: name))])
        var user = NewUser()
        user.name = "ot_app"
        user.password = #"pa'ss\word"#
        try await driver.run(try OracleUserStatements().create(user))
        let signed = oracle(user: name, password: user.password)
        try await signed.connect()
        let me = try await signed.execute("SELECT USER FROM dual", limit: 1).rows
        XCTAssertEqual(me, [[name]])
        await signed.close()
        let made = DatabaseUser(name: name)
        _ = try await driver.execute("CREATE TABLE ot.ops_grants (id NUMBER)", limit: 1)
        let table = GrantTarget.table(TableName(schema: "OT", name: "OPS_GRANTS"))
        try await driver.run([try OracleUserStatements().grant(["SELECT", "INSERT"], on: table, to: made, grantOption: false)])
        try await driver.run([try OracleUserStatements().grantRole(DatabaseUser(name: "CONNECT", isRole: true), to: made)])
        let grants = try await driver.grants(of: made).value ?? []
        XCTAssertEqual(Set(grants.first { $0.kind == "table" }?.privileges ?? []), ["SELECT", "INSERT"], "\(grants)")
        XCTAssertEqual(grants.first { $0.kind == "table" }?.target, table)
        XCTAssertTrue(grants.contains { $0.kind == "system" && $0.object == "CREATE SESSION" })
        XCTAssertTrue(grants.contains { $0.kind == "role" && $0.object == "CONNECT" })
        try await driver.run([try XCTUnwrap(OracleUserStatements().revoke(DatabaseGrant(kind: "table", object: "OT.OPS_GRANTS", privileges: ["INSERT"], target: table), from: made))])
        let left = try await driver.grants(of: made).value?.first { $0.kind == "table" }?.privileges
        XCTAssertEqual(left, ["SELECT"])
        let users = try await driver.users().value ?? []
        XCTAssertEqual(users.first { $0.name == name }?.memberOf, ["CONNECT"])
        XCTAssertTrue(users.contains { $0.name == "DBA" && $0.isRole })
        try await driver.run([try OracleUserStatements().drop(made)])
        _ = try await driver.execute("DROP TABLE ot.ops_grants PURGE", limit: 1)
        await driver.close()
    }
}
