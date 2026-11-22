import XCTest

@testable import Overterm
@testable import OvertermCore

/// Oracle's, ClickHouse's and BigQuery's Server page, editing and users — the
/// pure parts: quoting, the statements, the engines' answers read.
final class DatabaseOperationsKindsTests: XCTestCase {
    private func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: columns, types: columns.map { _ in "" }, rows: rows)
    }

    // MARK: Quoting

    func testNamesAndValuesNeverEndTheirStatement() {
        XCTAssertEqual(SQLDialect.oracle.identifier(#"a"b"#), #""a""b""#)
        XCTAssertEqual(SQLDialect.oracle.literal("a'b"), "'a''b'")
        XCTAssertEqual(SQLDialect.oracle.literal(#"a\b"#), #"'a\b'"#, "Oracle's backslash is itself")
        for dialect in [SQLDialect.clickhouse, .bigquery] {
            XCTAssertEqual(dialect.identifier("a`b"), #"`a\`b`"#)
            XCTAssertEqual(dialect.identifier("x; DROP TABLE t"), "`x; DROP TABLE t`")
            XCTAssertEqual(dialect.literal("a'b"), #"'a\'b'"#)
            XCTAssertEqual(dialect.literal(#"a\'b"#), #"'a\\\'b'"#, "a backslash can't take the quote with it")
            XCTAssertEqual(dialect.literal("two\nlines"), #"'two\nlines'"#, "BigQuery's strings hold no raw newline")
            XCTAssertEqual(dialect.qualified(TableName(schema: "shop", name: "o`rders")), #"`shop`.`o\`rders`"#)
        }
        XCTAssertEqual(BigQueryOps.value(.text("5"), type: "INT64"), "CAST('5' AS INT64)")
        XCTAssertEqual(BigQueryOps.value(.null, type: "INT64"), "NULL")
        XCTAssertEqual(BigQueryOps.value(.text("x"), type: "STRING(40)"), "'x'")
        XCTAssertEqual(BigQueryOps.value(.text("x"), type: ""), "'x'")
        XCTAssertEqual(BigQueryOps.value(.text("1"), type: "NUMERIC(10, 2)"), "CAST('1' AS NUMERIC(10, 2))")
        XCTAssertEqual(BigQueryOps.value(.text("1"), type: "INT64) ; DROP TABLE t; --"), "'1'", "a type is the catalog's words, else no cast")
    }

    // MARK: Editing statements

    private func edits(
        key: TableKey, types: [String] = [], columns: [String] = ["id", "note"],
        make: (PendingEdits, [[String?]], EditableResult) throws -> [EditStatement]
    ) throws -> [EditStatement] {
        var result = try EditableResult.match(resultColumns: columns, tableColumns: columns, key: key).get()
        result.types = types
        var edits = PendingEdits()
        edits.delete(rows: [1])
        edits.set(row: 0, column: 1, to: .text("it's"), original: "a")
        edits.add([0: .text("3"), 1: .null])
        return try make(edits, [["1", "a"], ["2", "b"]], result)
    }

    func testOracleStatements() throws {
        let key = TableKey(table: TableName(schema: "OT", name: "ORDERS"), kind: .primary, columns: ["id"])
        XCTAssertEqual(
            try edits(key: key, make: OracleOps.editStatements).map(\.sql),
            [
                #"DELETE FROM "OT"."ORDERS" WHERE "id" = '2'"#, #"UPDATE "OT"."ORDERS" SET "note" = 'it''s' WHERE "id" = '1'"#,
                #"INSERT INTO "OT"."ORDERS" ("id", "note") VALUES ('3', NULL)"#,
            ])
        // A heap table without a key: by ROWID, never written.
        let rowid = TableKey(table: TableName(schema: "OT", name: "LOOSE"), kind: .rowid, columns: ["rowid"])
        let result = try EditableResult.match(resultColumns: ["ROWID", "NOTE"], tableColumns: ["NOTE"], key: rowid).get()
        XCTAssertFalse(result.isEditable(0))
        var change = PendingEdits()
        change.set(row: 0, column: 1, to: .text("x"), original: "y")
        XCTAssertEqual(
            try OracleOps.editStatements(change, rows: [["AAAR5aAAEAAAAFbAAA", "y"]], result: result).map(\.sql),
            [#"UPDATE "OT"."LOOSE" SET "NOTE" = 'x' WHERE rowid = 'AAAR5aAAEAAAAFbAAA'"#])
        XCTAssertEqual(
            try OracleOps.editStatements(change, rows: [["AAAR5aAAEAAAAFbAAA", "y"]], result: result).first?.note, OracleOps.rowidNote,
            "the confirmation says what a ROWID holds to")
        // A new row with nothing set: Oracle has no DEFAULT VALUES.
        var empty = PendingEdits()
        empty.add()
        XCTAssertThrowsError(try OracleOps.editStatements(empty, rows: [], result: result)) {
            XCTAssertTrue(($0 as? EditRefusal)?.message.contains("DEFAULT VALUES") == true)
        }
    }

    func testClickHouseStatementsAreMutationsCountedFirst() throws {
        var key = TableKey(table: TableName(schema: "shop", name: "orders"), kind: .primary, columns: ["id"])
        key.fixedColumns = ["id"]
        let statements = try edits(key: key, make: ClickHouseOps.editStatements)
        XCTAssertEqual(
            statements.map(\.sql),
            [
                "DELETE FROM `shop`.`orders` WHERE `id` = '2'", #"ALTER TABLE `shop`.`orders` UPDATE `note` = 'it\'s' WHERE `id` = '1'"#,
                "INSERT INTO `shop`.`orders` (`id`, `note`) VALUES ('3', NULL)",
            ])
        XCTAssertEqual(statements[0].countSQL, "SELECT count() FROM `shop`.`orders` WHERE `id` = '2'", "the key isn't unique: counted first")
        XCTAssertEqual(statements[1].countSQL, "SELECT count() FROM `shop`.`orders` WHERE `id` = '1'")
        XCTAssertNil(statements[2].countSQL)

        // The sorting key: a new row sets it, an existing row's can't change.
        let result = try EditableResult.match(resultColumns: ["id", "note"], tableColumns: ["id", "note"], key: key).get()
        XCTAssertTrue(result.isEditable(0))
        XCTAssertFalse(result.isUpdatable(0))
        XCTAssertTrue(result.isUpdatable(1))
        var change = PendingEdits()
        change.set(row: 0, column: 0, to: .text("9"), original: "1")
        XCTAssertThrowsError(try ClickHouseOps.editStatements(change, rows: [["1", "a"]], result: result)) {
            XCTAssertTrue(($0 as? EditRefusal)?.message.contains("sorting or partition key") == true)
        }
        var empty = PendingEdits()
        empty.add()
        XCTAssertThrowsError(try ClickHouseOps.editStatements(empty, rows: [], result: result), "no DEFAULT VALUES")
    }

    func testBigQueryLiteralsAreCastToTheirColumns() throws {
        let key = TableKey(table: TableName(schema: "ds", name: "orders"), kind: .primary, columns: ["id"])
        let made = try edits(key: key, types: ["INT64", "STRING"], make: BigQueryOps.editStatements)
        XCTAssertEqual(
            made.map(\.sql),
            [
                "DELETE FROM `ds`.`orders` WHERE `id` = CAST('2' AS INT64)", #"UPDATE `ds`.`orders` SET `note` = 'it\'s' WHERE `id` = CAST('1' AS INT64)"#,
                "INSERT INTO `ds`.`orders` (`id`, `note`) VALUES (CAST('3' AS INT64), NULL)",
            ])
        XCTAssertTrue(made.allSatisfy { $0.countSQL == nil }, "@@row_count counts")
        XCTAssertEqual(BigQueryOps.table(TableName(schema: nil, name: "ds.orders"), defaultDataset: ""), TableName(schema: "ds", name: "orders"))
        XCTAssertEqual(BigQueryOps.table(TableName(schema: nil, name: "p.ds.orders"), defaultDataset: ""), TableName(schema: "ds", name: "orders"))
        XCTAssertEqual(BigQueryOps.table(TableName(schema: nil, name: "orders"), defaultDataset: "main"), TableName(schema: "main", name: "orders"))
        XCTAssertNil(BigQueryOps.table(TableName(schema: nil, name: "orders"), defaultDataset: ""), "no dataset to name")
    }

    func testBigQueryScriptChecksEveryStatementInOneTransaction() {
        let script = BigQueryOps.script([EditStatement(sql: "DELETE FROM `ds`.`t` WHERE `id` = CAST('1' AS INT64)"), EditStatement(sql: "UPDATE x SET a = 1 WHERE b = 2")])
        XCTAssertEqual(
            script,
            """
            BEGIN
              BEGIN TRANSACTION;
              DELETE FROM `ds`.`t` WHERE `id` = CAST('1' AS INT64);
              IF @@row_count <> 1 THEN RAISE USING MESSAGE = FORMAT('Statement 1 changed %d rows, not 1 — the row has changed or gone since it was read, or the key isn\\'t unique. Nothing was saved.', @@row_count); END IF;
              UPDATE x SET a = 1 WHERE b = 2;
              IF @@row_count <> 1 THEN RAISE USING MESSAGE = FORMAT('Statement 2 changed %d rows, not 1 — the row has changed or gone since it was read, or the key isn\\'t unique. Nothing was saved.', @@row_count); END IF;
              COMMIT TRANSACTION;
            EXCEPTION WHEN ERROR THEN
              ROLLBACK TRANSACTION;
              RAISE USING MESSAGE = @@error.message;
            END;
            """)
    }

    // MARK: Keys

    func testOracleKeyPrimaryThenUniqueNotNullThenRowid() {
        let table = TableName(schema: "OT", name: "ORDERS")
        let columns = result(
            ["name", "type", "type_owner", "virtual", "generation"],
            [
                ["ID", "NUMBER", nil, "NO", "ALWAYS"], ["CODE", "VARCHAR2", nil, "NO", nil], ["BODY", "CLOB", nil, "NO", nil],
                ["TOTAL", "NUMBER", nil, "YES", nil], ["AT", "TIMESTAMP(6) WITH TIME ZONE", nil, "NO", nil], ["SHAPE", "SDO_GEOMETRY", "MDSYS", "NO", nil],
            ])
        let both = result(
            ["index", "kind", "column", "nullable"], [["ORDERS_PK", "P", "ID", "N"], ["ORDERS_CODE", "U", "CODE", "N"]])
        let key = OracleOps.key(table, heap: true, constraints: both, columns: columns)
        XCTAssertEqual(key?.kind, .primary)
        XCTAssertEqual(key?.columns, ["ID"])
        XCTAssertEqual(key?.readOnlyColumns, ["ID", "BODY", "TOTAL", "SHAPE"], "identity ALWAYS, a CLOB, a virtual column, an object type")
        XCTAssertEqual(key?.note, "Oracle keeps an empty string as NULL.")

        let unique = OracleOps.key(table, heap: true, constraints: result(["index", "kind", "column", "nullable"], [["U1", "U", "CODE", "N"]]), columns: columns)
        XCTAssertEqual(unique?.kind, .unique("U1"))
        let nullable = result(["index", "kind", "column", "nullable"], [["U1", "U", "CODE", "Y"]])
        let rowid = OracleOps.key(table, heap: true, constraints: nullable, columns: columns)
        XCTAssertEqual(rowid?.kind, .rowid, "a unique key that may be NULL finds nothing: ROWID")
        XCTAssertTrue(rowid?.note?.contains("SELECT ROWID") == true)
        XCTAssertNil(OracleOps.key(table, heap: false, constraints: nullable, columns: columns), "an index-organized table has no ROWID to keep")

        XCTAssertEqual(
            OracleOps.candidates(TableName(schema: nil, name: "orders"), currentSchema: "OT"),
            [TableName(schema: "OT", name: "orders"), TableName(schema: "OT", name: "ORDERS")])
        XCTAssertEqual(OracleOps.candidates(TableName(schema: "OT", name: "ORDERS"), currentSchema: "X"), [TableName(schema: "OT", name: "ORDERS")])
    }

    func testOracleFormatsAreSetForASaveAndPutBack() {
        XCTAssertEqual(
            OracleOps.nlsRestoreStatements([["NLS_DATE_FORMAT", "DD-MON-RR"], ["NLS_NUMERIC_CHARACTERS", ",."], ["NLS_LANGUAGE", "X"], ["NLS_TIMESTAMP_FORMAT", "it's"]]),
            [
                "ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-RR'", "ALTER SESSION SET NLS_NUMERIC_CHARACTERS = ',.'",
                "ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'it''s'",
            ], "only the four it set, each quoted")
    }

    func testClickHouseKeyOnlyAPlainMergeTreeByItsColumns() throws {
        func table(_ engine: String, primary: String, sorting: String? = nil) -> ResultRow {
            ResultRow.rows(of: result(["database", "name", "engine", "primary_key", "sorting_key"], [["shop", "orders", engine, primary, sorting ?? primary]])).first!
        }
        let columns = result(
            ["name", "type", "default_kind", "is_in_sorting_key", "is_in_partition_key"],
            [
                ["id", "UInt64", "", "1", "0"], ["day", "Date", "", "0", "1"], ["tags", "Array(String)", "", "0", "0"],
                ["total", "Decimal(12, 2)", "MATERIALIZED", "0", "0"], ["note", "Nullable(String)", "", "0", "0"],
            ])
        let key = try ClickHouseOps.key(table("MergeTree", primary: "id"), columns: columns).get()
        XCTAssertEqual(key.columns, ["id"])
        XCTAssertEqual(key.table, TableName(schema: "shop", name: "orders"))
        XCTAssertEqual(key.fixedColumns, ["id", "day"], "the sorting and partition keys can't be UPDATEd")
        XCTAssertEqual(key.readOnlyColumns, ["tags", "total"])
        XCTAssertEqual(key.label, "mutations")
        XCTAssertTrue(key.note?.contains("not in a transaction") == true)

        XCTAssertEqual(try ClickHouseOps.key(table("MergeTree", primary: "`id`, day"), columns: columns).get().columns, ["id", "day"])
        for (engine, primary) in [("ReplacingMergeTree", "id"), ("Log", ""), ("MergeTree", "toDate(day)"), ("MergeTree", "")] {
            XCTAssertThrowsError(try ClickHouseOps.key(table(engine, primary: primary), columns: columns).get(), "\(engine) \(primary)")
        }
        let nullable = result(["name", "type", "default_kind", "is_in_sorting_key", "is_in_partition_key"], [["id", "Nullable(UInt64)", "", "1", "0"]])
        XCTAssertThrowsError(try ClickHouseOps.key(table("MergeTree", primary: "id"), columns: nullable).get())
        XCTAssertTrue(ClickHouseOps.isUnwritable("LowCardinality(Nullable(Map(String, UInt8)))"))
        XCTAssertFalse(ClickHouseOps.isUnwritable("LowCardinality(Nullable(String))"))
    }

    func testBigQueryKeyOnlyWhereOneIsDeclared() throws {
        let table = TableName(schema: "ds", name: "orders")
        let columns = result(
            ["column_name", "data_type"],
            [["id", "INT64"], ["note", "STRING(40)"], ["at", "TIMESTAMP"], ["tags", "ARRAY<STRING>"], ["blob", "BYTES"], ["n", "NUMERIC(10, 2)"]])
        let key = try BigQueryOps.key(table, tableType: "BASE TABLE", constraints: result(["column_name"], [["id"]]), columns: columns).get()
        XCTAssertEqual(key.columns, ["id"])
        XCTAssertEqual(BigQueryOps.types(columns).types["n"], "NUMERIC(10, 2)")
        XCTAssertEqual(BigQueryOps.types(columns).order, ["id", "note", "at", "tags", "blob", "n"])
        XCTAssertEqual(key.readOnlyColumns, ["tags", "blob"])
        XCTAssertEqual(key.label, "key not enforced")
        XCTAssertThrowsError(try BigQueryOps.key(table, tableType: "BASE TABLE", constraints: result(["column_name"], []), columns: columns).get()) {
            XCTAssertTrue(($0 as? EditRefusal)?.message.contains("NOT ENFORCED") == true)
        }
        XCTAssertThrowsError(try BigQueryOps.key(table, tableType: "VIEW", constraints: result(["column_name"], [["id"]]), columns: columns).get())
    }

    // MARK: The Server page's answers

    func testOracleActivityAndSlowQueries() {
        let sessions = OracleOps.activity(
            result(
                ["ID", "user", "database", "CLIENT", "APPLICATION", "STATE", "WAITING", "SECONDS", "QUERY", "OWN"],
                [
                    ["12,345", "OT", "OT", "laptop", "sqlplus", "ACTIVE", "enq: TX - row lock contention", "4", "UPDATE t SET a = 1", "0"],
                    ["13,7", "OT", "OT", nil, "", "INACTIVE", nil, "120", nil, "1"],
                ]))
        XCTAssertEqual(sessions.map(\.state), ["active", "idle"])
        XCTAssertTrue(sessions[0].isActive)
        XCTAssertFalse(sessions[1].isActive, "INACTIVE is idle")
        XCTAssertTrue(sessions[1].isOwn)
        XCTAssertNil(sessions[1].application)
        XCTAssertEqual(sessions[0].waiting, "enq: TX - row lock contention")

        let slow = OracleOps.slowQueries([
            result(["ID", "CALLS", "TOTAL", "MEAN", "rows", "CPU", "BUFFER_GETS", "QUERY"], [["a1", "10", "5", "0.5", "10", "4", "900", "SELECT 1"]]),
            result(
                ["ID", "CALLS", "TOTAL", "MEAN", "rows", "CPU", "BUFFER_GETS", "QUERY"], [["a1", "10", "5", "0.5", "10", "4", "900", "SELECT 1"], ["b2", "1", "3", "3", nil, nil, nil, "SELECT 2"]]),
        ])
        XCTAssertEqual(slow.map(\.id), ["a1", "b2"], "each statement once, by total")
        XCTAssertEqual(slow[0].detail, "CPU 4.0 s, 900 buffer gets")

        XCTAssertTrue(OracleOps.isSession("12,345"))
        for bad in ["12", "12,3' ; DROP", "a,b", "12, 3", ""] { XCTAssertFalse(OracleOps.isSession(bad), bad) }
        let stops = OracleDriver.sessionStops(for: sessions[0], kind: .oracle) ?? []
        XCTAssertEqual(stops.map(\.command), ["ALTER SYSTEM CANCEL SQL '12,345'", "ALTER SYSTEM KILL SESSION '12,345' IMMEDIATE"])
        XCTAssertEqual(stops.map(\.terminate), [false, true])
        var ours = sessions[0]
        ours.application = OracleOps.programName
        XCTAssertEqual(OracleDriver.sessionStops(for: ours, kind: .oracle)?.map(\.terminate), [false], "Overterm's own connection: cancelled, never killed")
        var bad = sessions[0]
        bad.id = "1' OR 1=1"
        XCTAssertEqual(OracleDriver.sessionStops(for: bad, kind: .oracle), [], "a session id not of digits is never put in a statement")
        XCTAssertNil(OracleOps.stopStatement("1,2'; DROP", terminate: true))
    }

    func testOracleOverviewAndGrants() {
        let overview = OracleOps.overview(
            result(
                [
                    "VERSION", "INSTANCE_NAME", "HOST_NAME", "UPTIME", "DB_NAME", "ROLE", "OPEN_MODE", "CONTAINER", "SESSIONS", "ACTIVE", "MAX_SESSIONS",
                    "PROCESSES", "MAX_PROCESSES", "PHYSICAL_READS", "LOGICAL_READS", "COMMITS", "ROLLBACKS",
                ],
                [["23.5.0.24.07", "FREE", "db1", "3600", "FREE", "PRIMARY", "READ WRITE", "FREEPDB1", "10", "2", "472", "80", "300", "10", "1000", "50", "1"]]))
        let facts = Dictionary(uniqueKeysWithValues: overview.facts.map { ($0.title, $0) })
        XCTAssertEqual(facts["Sessions"]?.value, "10 / 472")
        XCTAssertEqual(facts["Buffer cache hit"]?.value, "99.0%")
        XCTAssertEqual(facts["Database"]?.value, "FREE / FREEPDB1")
        XCTAssertEqual(facts["Uptime"]?.value, "1 h 0 min")

        let grants = OracleOps.grants(
            result(
                ["KIND", "PRIVILEGE", "GRANTABLE", "OWNER", "OBJECT_NAME"],
                [
                    ["system", "CREATE SESSION", "NO", nil, nil], ["role", "CONNECT", "YES", nil, nil], ["table", "SELECT", "NO", "HR", "EMP"],
                    ["table", "UPDATE", "YES", "HR", "EMP"], ["package", "EXECUTE", "NO", "SYS", "DBMS_LOCK"],
                ]))
        XCTAssertEqual(grants.map(\.kind), ["system", "role", "table", "package"])
        XCTAssertEqual(grants[0].target, .server)
        XCTAssertEqual(grants[2].privileges, ["SELECT", "UPDATE"])
        XCTAssertTrue(grants[2].grantable)
        XCTAssertEqual(grants[2].target, .table(TableName(schema: "HR", name: "EMP")))
        XCTAssertNil(grants[3].target, "a package isn't revoked from here")

        let users = OracleOps.users(
            result(
                ["NAME", "ACCOUNT_STATUS", "EXPIRY_DATE", "PROFILE", "AUTHENTICATION_TYPE", "COMMON"],
                [["APP", "LOCKED", "2027-01-01", "DEFAULT", "PASSWORD", "NO"], ["SVC", "OPEN", nil, "DEFAULT", "NONE", "NO"]]),
            roles: result(["NAME", "AUTHENTICATION_TYPE", "ORACLE_MAINTAINED"], [["DBA", "NONE", "Y"], ["APP_ROLE", "NONE", "N"]]),
            memberships: result(["GRANTEE", "GRANTED_ROLE"], [["APP", "APP_ROLE"], ["APP", "DBA"]]))
        XCTAssertEqual(users.map(\.name), ["APP", "SVC", "DBA", "APP_ROLE"])
        XCTAssertEqual(users[0].memberOf, ["APP_ROLE", "DBA"])
        XCTAssertFalse(users[0].canLogin, "locked")
        XCTAssertEqual(users[0].attributes, ["locked"])
        XCTAssertFalse(users[1].canLogin, "a schema-only account has no password")
        XCTAssertEqual(users[2].attributes, [OracleOps.maintained])
        let maker = OracleUserStatements()
        XCTAssertFalse(maker.offers(.drop, on: users[2]), "Oracle's own role isn't dropped")
        XCTAssertTrue(maker.offers(.drop, on: users[3]))
        XCTAssertFalse(maker.offers(.password, on: users[3]), "a role has no password here")
        XCTAssertEqual(maker.roleCandidates(for: users[1], among: users).map(\.name), ["DBA", "APP_ROLE"], "roles only")
        XCTAssertEqual(maker.roleCandidates(for: users[0], among: users).map(\.name), [], "already a member of both")
        XCTAssertEqual(maker.revoke(grants[0], from: users[0])?.sql, #"REVOKE CREATE SESSION FROM "APP""#)
        XCTAssertEqual(maker.revoke(grants[1], from: users[0])?.sql, #"REVOKE "CONNECT" FROM "APP""#)
        XCTAssertEqual(maker.revoke(grants[2], from: users[0])?.sql, #"REVOKE SELECT, UPDATE ON "HR"."EMP" FROM "APP""#)
        XCTAssertNil(maker.revoke(grants[3], from: users[0]))
        XCTAssertNil(
            maker.revoke(DatabaseGrant(kind: "system", object: "X; DROP USER SYS", privileges: [], target: .server), from: users[0]),
            "only a privilege's words")
    }

    func testClickHouseAnswers() {
        let sessions = ClickHouseOps.activity(
            result(
                ["id", "user", "db", "client", "client_name", "http_user_agent", "seconds", "query", "is_cancelled", "read_rows", "memory", "own"],
                [
                    ["q-1", "ot", "shop", "::ffff:172.17.0.1", "", "curl/8", "12.5", "SELECT sleep(3)", "0", "100", "1.00 MiB", "0"],
                    ["q-2", "ot", "shop", "::1", "", "", "0.001", ClickHouseOps.marker + "SELECT … system.processes", "0", "0", "0.00 B", "1"],
                ]))
        XCTAssertEqual(sessions[0].client, "172.17.0.1")
        XCTAssertEqual(sessions[0].application, "curl/8 · 1.00 MiB memory, 100 rows read")
        XCTAssertEqual(sessions[0].state, "running")
        XCTAssertTrue(sessions[1].isOwn)
        XCTAssertFalse(sessions[1].statement?.contains("overterm") ?? true)
        var odd = sessions[0]
        odd.id = "x'; DROP"
        let stops = ClickHouseDriver.sessionStops(for: odd, kind: .clickhouse) ?? []
        XCTAssertEqual(stops.map(\.command), [#"KILL QUERY WHERE query_id = 'x\'; DROP'"#], "a query id is a literal; there is no session to end")
        XCTAssertEqual(stops.map(\.terminate), [false])

        let slow = ClickHouseOps.slowQueries([
            result(["hash", "db", "who", "calls", "total", "mean", "result_count", "read_size", "text"], [["1", "shop", "ot", "4", "2", "0.5", "8", "1.00 KiB", "SELECT 1"]])
        ])
        XCTAssertEqual(slow.first?.user, "ot")
        XCTAssertEqual(slow.first?.detail, "1.00 KiB read")
        XCTAssertTrue(ClickHouseOps.slowSQL(byMean: true).contains("NOT startsWith(query, '/* overterm server page */')"), "the page's own reads left out")
        XCTAssertTrue(ClickHouseOps.isMissing(DatabaseError.failed("Table system.query_log does not exist. (UNKNOWN_TABLE)")))

        let users = ClickHouseOps.users(
            result(["name", "storage", "auth", "hosts", "default_database"], [["default", "users_xml", "no_password", "::/0", ""], ["app", "local_directory", "sha256_password", "", "shop"]]),
            roles: result(["name", "storage"], [["readers", "local_directory"]]),
            memberships: result(["user_name", "role_name", "granted_role_name"], [["app", nil, "readers"]]))
        let maker = ClickHouseUserStatements()
        XCTAssertTrue(users[0].attributes.contains(ClickHouseOps.configUser), "users.xml: SQL can't change it, said")
        for action in [UserAction.password, .grant, .grantRole, .drop] {
            XCTAssertFalse(maker.offers(action, on: users[0]), "nothing offered on a users.xml user")
            XCTAssertTrue(maker.offers(action, on: users[1]))
        }
        XCTAssertNil(maker.revoke(DatabaseGrant(kind: "server", object: "*.*", privileges: ["SHOW"], target: .server), from: users[0]))
        XCTAssertEqual(users[1].memberOf, ["readers"])
        XCTAssertEqual(users[2].isRole, true)

        let grants = ClickHouseOps.grants(
            result(
                ["access_type", "database", "table", "column", "is_partial_revoke", "grant_option"],
                [["SELECT", "shop", nil, nil, "0", "0"], ["INSERT", "shop", nil, nil, "0", "1"], ["SELECT", "shop", "orders", "note", "0", "0"], ["SHOW", nil, nil, nil, "0", "0"]]),
            roles: result(["granted_role_name", "with_admin_option"], [["readers", "0"]]))
        XCTAssertEqual(grants.map(\.object), ["shop.*", "shop.orders", "*.*", "readers"])
        XCTAssertEqual(grants[0].privileges, ["SELECT", "INSERT"])
        XCTAssertEqual(grants[0].target, .database("shop"))
        XCTAssertEqual(grants[1].privileges, ["SELECT(note)"])
        XCTAssertEqual(grants[2].target, .server)
        XCTAssertEqual(grants[3].kind, "role")
    }

    func testBigQueryJobsAndRegion() {
        let answer: [String: Any] = [
            "jobs": [
                [
                    "jobReference": ["projectId": "p", "jobId": "job_a", "location": "EU"], "state": "RUNNING", "user_email": "a@x.dev",
                    "configuration": ["jobType": "QUERY", "query": ["query": "SELECT 1"]], "statistics": ["creationTime": "1000", "startTime": "2000"],
                ],
                [
                    "jobReference": ["projectId": "p", "jobId": "job_b", "location": "EU"], "state": "PENDING",
                    "configuration": ["jobType": "LOAD"], "statistics": ["creationTime": "1000"],
                ],
            ]
        ]
        let listed = BigQueryOps.jobs(answer, now: Date(timeIntervalSince1970: 12), own: ["job_b"])
        XCTAssertEqual(listed.jobs.map(\.id), ["job_b", "job_a"], "the longest first")
        XCTAssertEqual(listed.jobs[1].seconds, 10, "running since it started")
        XCTAssertEqual(listed.jobs[0].seconds, 11, "pending since it was made")
        XCTAssertEqual(listed.jobs[1].statement, "SELECT 1")
        XCTAssertEqual(listed.jobs[0].statement, "LOAD")
        XCTAssertTrue(listed.jobs[0].isOwn)
        XCTAssertEqual(listed.locations, ["job_a": "EU", "job_b": "EU"])

        XCTAssertEqual(BigQueryOps.region("EU").qualifier, "`region-eu`")
        XCTAssertEqual(BigQueryOps.region("us-central1").qualifier, "`region-us-central1`")
        XCTAssertEqual(BigQueryOps.region("").assumed, true)
        XCTAssertEqual(BigQueryOps.region("eu`; DROP").qualifier, "`region-eudrop`", "only a region's letters, digits and dashes")
        XCTAssertTrue(BigQueryOps.isJobID("bquxjob_1a2b-3c"))
        XCTAssertFalse(BigQueryOps.isJobID("../datasets"))
        XCTAssertEqual(BigQueryDriver.sessionStops(for: listed.jobs[1], kind: .bigquery)?.map(\.menu), ["Cancel Job…"])
        var odd = listed.jobs[1]
        odd.id = "../datasets"
        XCTAssertEqual(BigQueryDriver.sessionStops(for: odd, kind: .bigquery), [], "only a job id goes in the address")

        let overview = BigQueryOps.overview(project: "p", location: "", datasets: 3, jobs: listed.jobs, everyone: false)
        XCTAssertEqual(overview.facts.first { $0.title == "Running" }?.value, "1")
        XCTAssertTrue(overview.notes.contains { $0.contains("bigquery.jobs.listAll") })

        let slow = BigQueryOps.slowQueries(
            result(["id", "query", "user", "calls", "total", "mean", "slot_seconds", "bytes", "billed"], [["h", "SELECT x", "a@x.dev", "3", "6", "2", "90", "1073741824", "0"]]))
        XCTAssertEqual(slow.first?.detail, "1 GB processed, 1 min 30 s of slots")
        XCTAssertTrue(BigQueryOps.slowSQL(region: "`region-eu`").contains("FROM `region-eu`.INFORMATION_SCHEMA.JOBS_BY_PROJECT"))
    }

    // MARK: Users' statements

    func testOracleUserStatements() throws {
        let maker = OracleUserStatements(owner: "OT")
        XCTAssertTrue(maker.form.sql)
        XCTAssertEqual(maker.form.grantKinds.map(\.title), ["System privilege", "Table"])
        XCTAssertEqual(maker.form.grantKinds[1].fields.first?.fill, .text("OT"))
        var user = NewUser()
        user.name = "app_user"
        user.password = "pa'ss word"
        let made = try maker.create(user)
        XCTAssertEqual(made.map(\.sql), [#"CREATE USER "APP_USER" IDENTIFIED BY "pa'ss word""#, #"GRANT CREATE SESSION TO "APP_USER""#], "a plain name as Oracle reads it")
        XCTAssertEqual(made[0].shown, #"CREATE USER "APP_USER" IDENTIFIED BY "••••••••""#)
        XCTAssertFalse(made.map(\.shown).joined().contains("pa'ss"))
        XCTAssertEqual(made[0].scrub("ORA-00988: \"pa'ss word\""), "ORA-00988: \"••••\"")
        user.login = false
        XCTAssertEqual(try maker.create(user).count, 1, "no CREATE SESSION: it doesn't log in")
        user.name = "mixed Case"
        XCTAssertEqual(try maker.create(user)[0].sql.prefix(25), #"CREATE USER "mixed Case" "#)
        user.password = #"a"b"#
        XCTAssertThrowsError(try maker.create(user), "Oracle's password can't hold a quote")
        user.name = #"x"; DROP USER SYS"#
        user.password = "ok"
        XCTAssertThrowsError(try maker.create(user))
        user.name = "a'b"
        XCTAssertEqual(try maker.create(user)[0].sql, #"CREATE USER "a'b" IDENTIFIED BY "ok""#, "a quote in a quoted name ends nothing")

        let app = DatabaseUser(name: "APP_USER")
        XCTAssertEqual(
            try maker.grant(["CREATE TABLE", "CREATE VIEW"], on: .server, to: app, grantOption: true).sql, #"GRANT CREATE TABLE, CREATE VIEW TO "APP_USER" WITH ADMIN OPTION"#)
        let table = maker.target(maker.form.grantKinds[1], fields: ["hr", "emp"])
        XCTAssertEqual(try maker.grant(["SELECT"], on: table, to: app, grantOption: false).sql, #"GRANT SELECT ON "HR"."EMP" TO "APP_USER""#)
        XCTAssertEqual(
            try maker.grant(["SELECT"], on: table, to: app, grantOption: true).sql, #"GRANT SELECT ON "HR"."EMP" TO "APP_USER" WITH GRANT OPTION"#)
        XCTAssertEqual(maker.target(maker.form.grantKinds[0], fields: []), .server)
        XCTAssertThrowsError(try maker.grant(["SELECT; DROP"], on: .server, to: app, grantOption: false), "a privilege is the list's, never typed")
        XCTAssertThrowsError(try maker.grant(["SELECT"], on: .database("x"), to: app, grantOption: false))
        XCTAssertEqual(try maker.grantRole(DatabaseUser(name: "DBA", isRole: true), to: app).sql, #"GRANT "DBA" TO "APP_USER""#)
        XCTAssertEqual(try maker.drop(app).sql, #"DROP USER "APP_USER""#)
        XCTAssertEqual(try maker.drop(DatabaseUser(name: "R", isRole: true)).sql, #"DROP ROLE "R""#)
        XCTAssertEqual(try maker.password(of: app, to: "n3w").shown, #"ALTER USER "APP_USER" IDENTIFIED BY "••••••••""#)
        XCTAssertThrowsError(try maker.password(of: DatabaseUser(name: #"a"b"#), to: "x"))
    }

    func testClickHouseUserStatementsSendAHash() throws {
        let maker = ClickHouseUserStatements()
        XCTAssertTrue(maker.form.sql)
        var user = NewUser()
        user.name = "a`b"
        user.password = "pa'ss"
        user.validUntil = "2030-01-31"
        let salt = Data([0xab, 0xcd])
        let made = try maker.create(user, salt: salt)
        let hash = ClickHouseUserStatements.hash("pa'ss", salt: "abcd")
        XCTAssertEqual(made.map(\.sql), [#"CREATE USER `a\`b` IDENTIFIED WITH sha256_hash BY '"# + hash + "' SALT 'abcd' VALID UNTIL '2030-01-31'"])
        XCTAssertEqual(made[0].shown, #"CREATE USER `a\`b` IDENTIFIED WITH sha256_hash BY '••••••••' SALT 'abcd' VALID UNTIL '2030-01-31'"#)
        XCTAssertFalse(made[0].sql.contains("pa'ss"), "the password never goes on the wire")
        XCTAssertEqual(made[0].scrub("bad hash " + hash), "bad hash ••••")
        user.validUntil = "soon"
        XCTAssertThrowsError(try maker.create(user, salt: salt))
        user.validUntil = ""
        user.login = false
        user.password = ""
        XCTAssertEqual(try maker.create(user).map(\.sql), [#"CREATE ROLE `a\`b`"#], "one that doesn't log in is a role")
        user.password = "x"
        XCTAssertThrowsError(try maker.create(user), "a role has no password")

        let app = DatabaseUser(name: "app")
        let database = maker.target(maker.form.grantKinds[1], fields: ["shop"])
        XCTAssertEqual(try maker.grant(["SELECT", "INSERT"], on: database, to: app, grantOption: false).sql, "GRANT SELECT, INSERT ON `shop`.* TO `app`")
        let table = maker.target(maker.form.grantKinds[2], fields: ["shop", "o`rders"])
        XCTAssertEqual(try maker.grant(["ALL", "SELECT"], on: table, to: app, grantOption: true).sql, #"GRANT ALL ON `shop`.`o\`rders` TO `app` WITH GRANT OPTION"#)
        XCTAssertEqual(try maker.grant(["SHOW"], on: .server, to: app, grantOption: false).sql, "GRANT SHOW ON *.* TO `app`")
        XCTAssertThrowsError(try maker.grant(["SELECT ON *.* TO x; --"], on: .server, to: app, grantOption: false))
        XCTAssertEqual(
            maker.revoke(DatabaseGrant(kind: "table", object: "shop.o`rders", privileges: ["SELECT", "SELECT(note)", "revoked INSERT"], target: table), from: app)?
                .sql, #"REVOKE SELECT ON `shop`.`o\`rders` FROM `app`"#, "a column's and a partial revoke's left alone")
        XCTAssertEqual(maker.revoke(DatabaseGrant(kind: "role", object: "readers", privileges: ["MEMBER"]), from: app)?.sql, "REVOKE `readers` FROM `app`")
        XCTAssertEqual(try maker.grantRole(DatabaseUser(name: "readers", isRole: true), to: app).sql, "GRANT `readers` TO `app`")
        XCTAssertEqual(try maker.drop(DatabaseUser(name: "readers", isRole: true)).sql, "DROP ROLE `readers`")
        XCTAssertEqual(try maker.drop(app).sql, "DROP USER `app`")
        XCTAssertTrue(try maker.password(of: app, to: "x").sql.hasPrefix("ALTER USER `app` IDENTIFIED WITH sha256_hash BY '"))
        XCTAssertEqual(
            maker.roleCandidates(for: app, among: [app, DatabaseUser(name: "readers", isRole: true), DatabaseUser(name: "bob")]).map(\.name), ["readers"])
    }

    // MARK: Agents

    func testOraclesPasswordsAreMaskedInOthersStatements() {
        XCTAssertEqual(OpsText.statement(#"CREATE USER app IDENTIFIED BY "s3cr et""#), #"CREATE USER app IDENTIFIED BY "••••""#)
        XCTAssertEqual(OpsText.statement("alter user app identified by s3cret account unlock"), #"alter user app identified by "••••" account unlock"#)
        XCTAssertEqual(OpsText.statement("CREATE USER a IDENTIFIED BY 'x'"), "CREATE USER a IDENTIFIED BY '••••'", "the single-quoted kind as before")
        XCTAssertEqual(
            OpsText.statement("CREATE USER a IDENTIFIED WITH sha256_hash BY 'abc' SALT 'f0'"), "CREATE USER a IDENTIFIED WITH sha256_hash BY '••••' SALT 'f0'")
    }

    func testAgentsReadBigQuerysCostBesideTheStatements() {
        let text = ServerText.slowQueries(
            [SlowQuery(id: "1", statement: "SELECT\n  x", calls: 2, total: 4, mean: 2, rows: nil, database: nil, user: nil, detail: "1 GB processed")], byMean: false,
            limit: 10)
        XCTAssertTrue(text.contains("| cost |"), text)
        XCTAssertTrue(text.contains("1 GB processed"))
        XCTAssertTrue(text.contains("SELECT x"), "one line")
        let plain = ServerText.slowQueries([SlowQuery(id: "1", statement: "SELECT 1", calls: 1, total: 1, mean: 1, rows: 1)], byMean: false, limit: 10)
        XCTAssertFalse(plain.contains("cost"), "no column for kinds that say nothing more")
    }
}
