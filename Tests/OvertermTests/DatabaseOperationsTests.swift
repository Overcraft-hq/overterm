import XCTest

@testable import Overterm

/// The database client's Server page, editing and users — the pure parts:
/// quoting, which results can be edited, pending changes and the statements
/// they make, the users' statements, and the engines' answers read.
final class DatabaseOperationsTests: XCTestCase {
    // MARK: Which kinds have what

    func testFeaturesAreAskedOfTheDriverType() {
        XCTAssertEqual(DatabaseKind.postgres.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.redshift.features, [.monitoring, .users], "Redshift's keys aren't enforced: no editing")
        XCTAssertEqual(DatabaseKind.mysql.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.mariadb.features, [.monitoring, .editing, .users])
        XCTAssertEqual(DatabaseKind.sqlite.features, [.monitoring, .editing])
        for kind in [DatabaseKind.mongodb, .clickhouse, .bigquery, .s3, .prometheus, .oracle] {
            XCTAssertEqual(kind.features, [], "\(kind)")
        }
        XCTAssertEqual(SQLiteDriver.monitorParts(for: .sqlite), [.overview])
    }

    // MARK: Quoting

    func testNamesAndValuesNeverEndTheirStatement() {
        XCTAssertEqual(SQLDialect.postgres.identifier(#"a"b"#), #""a""b""#)
        XCTAssertEqual(SQLDialect.postgres.identifier("x; DROP TABLE t"), #""x; DROP TABLE t""#)
        XCTAssertEqual(SQLDialect.mysql.identifier("a`b"), "`a``b`")
        XCTAssertEqual(SQLDialect.postgres.literal("a'b"), "'a''b'")
        XCTAssertEqual(SQLDialect.postgres.literal(#"a\b"#), #"'a\b'"#, "standard strings: a backslash is itself")
        XCTAssertEqual(SQLDialect.mysql.literal(#"a\'b"#), #"'a\\''b'"#, "MySQL's backslash escapes doubled")
        XCTAssertEqual(SQLDialect(engine: .mysql, backslashEscapes: false).literal(#"a\b"#), #"'a\b'"#, "NO_BACKSLASH_ESCAPES")
        XCTAssertEqual(SQLDialect.sqlite.value(.null), "NULL")
        XCTAssertEqual(SQLDialect.sqlite.value(.text("")), "''")
        XCTAssertEqual(SQLDialect.postgres.qualified(TableName(schema: "s.x", name: #"t"y"#)), #""s.x"."t""y""#)
        XCTAssertEqual(SQLDialect.mysql.qualified(TableName(schema: nil, name: "t")), "`t`")
    }

    // MARK: Which results can be edited

    private func parsed(_ sql: String) -> EditableQuery? { try? EditableQuery.parse(sql).get() }

    func testOneTableSelectsAreEditable() {
        XCTAssertEqual(parsed("SELECT * FROM orders LIMIT 100;"), EditableQuery(table: TableName(schema: nil, name: "orders"), star: true, named: []))
        XCTAssertEqual(
            parsed("select id, o.note from public.orders o where id > 1 order by id desc limit 10 offset 5"),
            EditableQuery(table: TableName(schema: "public", name: "orders"), star: false, named: ["id", "note"]))
        XCTAssertEqual(
            parsed(#"SELECT "a b", `c` FROM "my schema"."my""table" AS t"#),
            EditableQuery(table: TableName(schema: "my schema", name: #"my"table"#), star: false, named: ["a b", "c"]))
        XCTAssertEqual(parsed("SELECT rowid, * FROM t")?.named, ["rowid"])
        XCTAssertEqual(parsed("SELECT t.* FROM t")?.star, true)
        // A subquery may join: the rows are still the one table's.
        XCTAssertNotNil(parsed("SELECT * FROM a WHERE id IN (SELECT a_id FROM b JOIN c ON c.id = b.c_id GROUP BY a_id)"))
        XCTAssertNotNil(parsed("SELECT * FROM a -- JOIN b\nWHERE note = 'x JOIN y'"))
        XCTAssertNotNil(parsed("SELECT * FROM t FETCH FIRST 10 ROWS ONLY"))
    }

    func testAnythingElseIsSaidWhy() {
        func refusal(_ sql: String) -> EditRefusal? {
            if case .failure(let why) = EditableQuery.parse(sql) { return why }
            return nil
        }
        for sql in [
            "SELECT * FROM a JOIN b ON a.id = b.id", "SELECT * FROM a, b", "SELECT * FROM a LEFT JOIN b USING (id)",
            "SELECT status FROM a GROUP BY status", "SELECT DISTINCT status FROM a", "SELECT * FROM a UNION SELECT * FROM b",
            "WITH x AS (SELECT 1) SELECT * FROM x", "SELECT 1", "UPDATE a SET b = 1", "SELECT * FROM (SELECT * FROM a) s",
            "SELECT * FROM a NATURAL JOIN b", "SELECT * INTO b FROM a",
        ] {
            XCTAssertEqual(refusal(sql), .notOneTable, sql)
        }
        XCTAssertEqual(refusal("SELECT email AS id FROM users"), .expressions, "an alias could pass for the key")
        XCTAssertEqual(refusal("SELECT count(*) FROM users"), .expressions)
        XCTAssertEqual(refusal("SELECT a + 1 FROM users"), .expressions)
        XCTAssertEqual(refusal("SELECT * FROM a; SELECT * FROM b"), .severalStatements)
    }

    func testAResultsColumnsAreMatchedToItsTable() {
        let key = TableKey(table: TableName(schema: "public", name: "orders"), kind: .primary, columns: ["id"])
        let matched = try? EditableResult.match(resultColumns: ["ID", "note"], tableColumns: ["id", "note", "total"], key: key).get()
        XCTAssertEqual(matched?.columns, ["id", "note"], "the catalog's spelling")
        XCTAssertEqual(matched?.keyIndexes, [0])
        XCTAssertEqual(EditableResult.match(resultColumns: ["note"], tableColumns: ["id", "note"], key: key), .failure(.keyNotShown(["id"])))
        XCTAssertEqual(EditableResult.match(resultColumns: ["id", "n"], tableColumns: ["id", "note"], key: key), .failure(.unknownColumn("n")))
        XCTAssertEqual(EditableResult.match(resultColumns: ["id", "id"], tableColumns: ["id"], key: key), .failure(.duplicateColumn("id")))
        let rowid = TableKey(table: TableName(schema: "main", name: "t"), kind: .rowid, columns: ["rowid"])
        let byRowid = try? EditableResult.match(resultColumns: ["rowid", "a"], tableColumns: ["a"], key: rowid).get()
        XCTAssertEqual(byRowid?.keyIndexes, [0])
        XCTAssertEqual(byRowid?.isEditable(0), false, "the rowid itself isn't written")
        XCTAssertEqual(byRowid?.isEditable(1), true)
    }

    // MARK: Pending edits

    func testPendingEditsKeepNullAndEmptyApart() {
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(""), original: nil)
        XCTAssertEqual(edits.value(row: 0, column: 1), .text(""), "'' over NULL is an edit")
        edits.set(row: 0, column: 1, to: .null, original: nil)
        XCTAssertTrue(edits.isEmpty, "back to NULL: no edit left")
        edits.set(row: 1, column: 0, to: .null, original: "")
        XCTAssertEqual(edits.value(row: 1, column: 0), .null, "NULL over '' is an edit")
        edits.set(row: 2, column: 0, to: .text("x"), original: "y")
        XCTAssertEqual(edits.count, 2)
        edits.delete(rows: [2])
        XCTAssertNil(edits.value(row: 2, column: 0), "a deleted row's edits go")
        XCTAssertEqual(edits.count, 2)
        edits.set(row: 2, column: 0, to: .text("z"), original: "y")
        XCTAssertNil(edits.value(row: 2, column: 0), "a deleted row isn't edited")
        edits.revert(row: 2)
        XCTAssertFalse(edits.deleted.contains(2))
        let added = edits.add([0: .text("new")])
        edits.set(new: added, column: 1, to: .null)
        edits.set(new: added, column: 0, to: nil)
        XCTAssertEqual(edits.inserted[added], [1: .null], "a column given back its default")
        edits.remove(new: added)
        XCTAssertTrue(edits.inserted.isEmpty)
        edits.discard()
        XCTAssertTrue(edits.isEmpty)
    }

    func testADuplicateLeavesTheKeyToTheNewRow() {
        var key = TableKey(table: TableName(schema: nil, name: "t"), kind: .primary, columns: ["id"])
        key.readOnlyColumns = ["generated"]
        let result = EditableResult(key: key, columns: ["id", "note", "generated", "empty"], keyIndexes: [0])
        XCTAssertEqual(PendingEdits.duplicate(["7", "hi", "x", nil], result: result), [1: .text("hi"), 3: .null])
    }

    // MARK: The statements a Save runs

    private let orders = EditableResult(
        key: TableKey(table: TableName(schema: "public", name: "orders"), kind: .primary, columns: ["id"]), columns: ["id", "note", "total"],
        keyIndexes: [0])

    func testSaveDeletesThenUpdatesThenInserts() throws {
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text("it's; DROP TABLE x"), original: "first")
        edits.set(row: 0, column: 0, to: .text("10"), original: "1")
        edits.set(row: 1, column: 1, to: .null, original: "second")
        edits.delete(rows: [2])
        edits.add([1: .text(""), 2: .text("5")])
        edits.add()
        let rows: [[String?]] = [["1", "first", "9"], ["2", "second", nil], ["3", "third", "7"]]
        let statements = try EditStatements.make(edits, rows: rows, result: orders, dialect: .postgres).map(\.sql)
        XCTAssertEqual(
            statements,
            [
                #"DELETE FROM "public"."orders" WHERE "id" = '3'"#,
                #"UPDATE "public"."orders" SET "id" = '10', "note" = 'it''s; DROP TABLE x' WHERE "id" = '1'"#,
                #"UPDATE "public"."orders" SET "note" = NULL WHERE "id" = '2'"#,
                #"INSERT INTO "public"."orders" ("note", "total") VALUES ('', '5')"#,
                #"INSERT INTO "public"."orders" DEFAULT VALUES"#,
            ])
    }

    func testMySQLStatementsCountTheirRow() throws {
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text(#"a\b"#), original: "x")
        edits.add()
        let made = try EditStatements.make(edits, rows: [["1", "x", "2"]], result: orders, dialect: .mysql)
        XCTAssertEqual(made[0].sql, #"UPDATE `public`.`orders` SET `note` = 'a\\b' WHERE `id` = '1'"#)
        XCTAssertEqual(made[0].countSQL, "SELECT COUNT(*) FROM `public`.`orders` WHERE `id` = '1'")
        XCTAssertEqual(made[1].sql, "INSERT INTO `public`.`orders` () VALUES ()")
        XCTAssertNil(made[1].countSQL)
    }

    func testRowidAndCompositeKeys() throws {
        let rowid = EditableResult(key: TableKey(table: TableName(schema: "main", name: "t"), kind: .rowid, columns: ["rowid"]), columns: ["rowid", "a"], keyIndexes: [0])
        var edits = PendingEdits()
        edits.set(row: 0, column: 1, to: .text("b"), original: "a")
        XCTAssertEqual(
            try EditStatements.make(edits, rows: [["4", "a"]], result: rowid, dialect: .sqlite).map(\.sql), [#"UPDATE "main"."t" SET "a" = 'b' WHERE rowid = '4'"#])
        let pair = EditableResult(
            key: TableKey(table: TableName(schema: nil, name: "m"), kind: .unique("m_ab"), columns: ["a", "b"]), columns: ["b", "a", "c"], keyIndexes: [1, 0])
        var delete = PendingEdits()
        delete.delete(rows: [0])
        XCTAssertEqual(try EditStatements.make(delete, rows: [["2", "1", "x"]], result: pair, dialect: .sqlite).map(\.sql), [#"DELETE FROM "m" WHERE "a" = '1' AND "b" = '2'"#])
    }

    func testAReadOnlyColumnOrAMissingKeyIsRefused() {
        var key = orders.key
        key.readOnlyColumns = ["total"]
        let result = EditableResult(key: key, columns: orders.columns, keyIndexes: [0])
        var edits = PendingEdits()
        edits.set(row: 0, column: 2, to: .text("1"), original: "9")
        XCTAssertThrowsError(try EditStatements.make(edits, rows: [["1", "a", "9"]], result: result, dialect: .postgres))
        var gone = PendingEdits()
        gone.delete(rows: [0])
        XCTAssertThrowsError(try EditStatements.make(gone, rows: [[nil, "a", "9"]], result: orders, dialect: .postgres), "a NULL key finds nothing")
    }

    // MARK: Users' statements

    private let salt = Data(repeating: 7, count: 16)

    func testPostgresPasswordsGoAsScramVerifiers() throws {
        var user = NewUser()
        user.name = #"app"user"#
        user.password = "s3cret'pw"
        user.createDatabases = true
        user.validUntil = "2027-01-31"
        let statements = try UserStatements.create(user, dialect: .postgres, salt: salt)
        XCTAssertEqual(statements.count, 1)
        let sql = statements[0].sql
        XCTAssertTrue(sql.hasPrefix(#"CREATE ROLE "app""user" WITH LOGIN CREATEDB VALID UNTIL '2027-01-31' PASSWORD 'SCRAM-SHA-256$4096:"#), sql)
        XCTAssertFalse(sql.contains("s3cret"), "the password never goes in the clear")
        XCTAssertEqual(statements[0].shown, #"CREATE ROLE "app""user" WITH LOGIN CREATEDB VALID UNTIL '2027-01-31' PASSWORD '••••••••'"#)
        let verifier = UserStatements.scramVerifier("pencil", salt: salt)
        XCTAssertNotNil(verifier.range(of: #"^SCRAM-SHA-256\$4096:[A-Za-z0-9+/=]{24}\$[A-Za-z0-9+/=]{44}:[A-Za-z0-9+/=]{44}$"#, options: .regularExpression), verifier)
        XCTAssertEqual(verifier, UserStatements.scramVerifier("pencil", salt: salt), "the same salt, the same verifier")
        XCTAssertNotEqual(UserStatements.scramVerifier("pencil"), UserStatements.scramVerifier("pencil"), "a new salt each time")
        var role = NewUser()
        role.name = "readers"
        role.login = false
        XCTAssertEqual(try UserStatements.create(role, dialect: .postgres).map(\.sql), [#"CREATE ROLE "readers" WITH NOLOGIN"#])
        role.login = true
        XCTAssertThrowsError(try UserStatements.create(role, dialect: .postgres), "a user that logs in needs a password")
        user.validUntil = "tomorrow'); DROP ROLE x; --"
        XCTAssertThrowsError(try UserStatements.create(user, dialect: .postgres))
    }

    func testRedshiftPasswordsGoAsTheirMD5() throws {
        // AWS's own example: password ez, user user1.
        XCTAssertEqual(UserStatements.redshiftMD5("ez", user: "user1"), "md5153c434b4b77c89e6b94f12c5393af5b")
        let change = try UserStatements.password(of: DatabaseUser(name: "user1"), to: "ez", dialect: .redshift)
        XCTAssertEqual(change.sql, #"ALTER USER "user1" PASSWORD 'md5153c434b4b77c89e6b94f12c5393af5b'"#)
        XCTAssertEqual(change.shown, #"ALTER USER "user1" PASSWORD '••••••••'"#)
    }

    func testMySQLAccountsAreQuotedLiterals() throws {
        var user = NewUser()
        user.name = "a'b"
        user.host = "10.0.%"
        user.password = #"p'w\d"#
        let create = try UserStatements.create(user, dialect: .mysql)[0]
        XCTAssertEqual(create.sql, #"CREATE USER 'a''b'@'10.0.%' IDENTIFIED BY 'p''w\\d'"#)
        XCTAssertEqual(create.shown, "CREATE USER 'a''b'@'10.0.%' IDENTIFIED BY '••••••••'")
        let account = DatabaseUser(name: "x; DROP USER root", host: "%")
        XCTAssertEqual(try UserStatements.drop(account, dialect: .mysql).sql, "DROP USER 'x; DROP USER root'@'%'")
        XCTAssertEqual(try UserStatements.drop(DatabaseUser(name: "r`1", isRole: true), dialect: .mariadb).sql, "DROP ROLE `r``1`")
        XCTAssertEqual(
            try UserStatements.grantRole(DatabaseUser(name: "readers", host: "%", isRole: true), to: account, dialect: .mysql).sql,
            "GRANT 'readers'@'%' TO 'x; DROP USER root'@'%'")
    }

    func testGrantsTakeOnlyKnownPrivileges() throws {
        let user = DatabaseUser(name: "app")
        XCTAssertEqual(
            try UserStatements.grant(["SELECT", "INSERT"], on: .table(TableName(schema: "public", name: "orders")), to: user, dialect: .postgres).sql,
            #"GRANT SELECT, INSERT ON TABLE "public"."orders" TO "app""#)
        XCTAssertEqual(
            try UserStatements.grant(["ALL", "SELECT"], on: .allTables("public"), to: user, dialect: .postgres, grantOption: true).sql,
            #"GRANT ALL ON ALL TABLES IN SCHEMA "public" TO "app" WITH GRANT OPTION"#)
        XCTAssertEqual(
            try UserStatements.revoke(["CONNECT"], on: .database(#"sh"op"#), from: user, dialect: .postgres).sql, #"REVOKE CONNECT ON DATABASE "sh""op" FROM "app""#)
        XCTAssertEqual(
            try UserStatements.grant(["SELECT"], on: .database("shop"), to: DatabaseUser(name: "app", host: "%"), dialect: .mysql).sql,
            "GRANT SELECT ON `shop`.* TO 'app'@'%'")
        XCTAssertThrowsError(try UserStatements.grant(["SELECT; DROP TABLE t"], on: .schema("s"), to: user, dialect: .postgres))
        XCTAssertThrowsError(try UserStatements.grant([], on: .schema("s"), to: user, dialect: .postgres))
        XCTAssertThrowsError(try UserStatements.grant(["SELECT"], on: .server, to: user, dialect: .postgres), "PostgreSQL has no *.*")
        XCTAssertThrowsError(try UserStatements.grant(["USAGE"], on: .schema("s"), to: user, dialect: .mysql), "MySQL has no schemas apart")
        XCTAssertEqual(try UserStatements.grantRole(DatabaseUser(name: "g"), to: DatabaseUser(name: "u"), dialect: .redshift).sql, #"ALTER GROUP "g" ADD USER "u""#)
    }

    func testAnErrorNeverRepeatsThePassword() {
        let statement = UserStatement("ALTER USER 'u'@'%' IDENTIFIED BY 'hunter2'", shown: "ALTER USER 'u'@'%' IDENTIFIED BY '••••••••'")
        XCTAssertEqual(statement.scrub("syntax error near 'hunter2' at line 1"), "syntax error near '••••' at line 1")
        XCTAssertEqual(statement.scrub("near hunter2"), "near ••••")
        XCTAssertEqual(UserStatement("DROP USER 'u'").scrub("no such user"), "no such user")
    }

    // MARK: Reading the engines' answers

    private func result(_ columns: [String], _ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: columns, types: columns.map { _ in "text" }, rows: rows)
    }

    func testPostgresActivityAndKey() {
        let activity = PostgresOps.activity(
            result(
                ["id", "user", "database", "client", "application", "state", "wait_event_type", "wait_event", "query", "seconds", "own"],
                [
                    ["42", "ot", "shop", "10.0.0.1/32", "", "active", "Lock", "transactionid", "UPDATE t SET a = 1", "3.5", "f"],
                    ["7", "ot", "shop", nil, "psql", "idle", nil, nil, "", "100", "t"],
                ]))
        XCTAssertEqual(activity[0].waiting, "Lock: transactionid")
        XCTAssertNil(activity[0].application)
        XCTAssertTrue(activity[0].isActive)
        XCTAssertTrue(activity[1].isOwn)
        XCTAssertFalse(activity[1].isActive)
        XCTAssertNil(activity[1].statement)

        let columns = ["schema", "name", "index", "is_primary", "column", "not_null"]
        let unique = PostgresOps.key(
            result(columns, [["public", "t", "t_email", "f", "email", "f"], ["public", "t", "t_code_region", "f", "code", "t"], ["public", "t", "t_code_region", "f", "region", "t"]]))
        XCTAssertEqual(unique?.kind, .unique("t_code_region"), "a unique key that may be NULL is skipped")
        XCTAssertEqual(unique?.columns, ["code", "region"])
        let primary = PostgresOps.key(result(columns, [["s", "t", "t_pkey", "t", "id", "t"], ["s", "t", "t_x", "f", "x", "t"]]))
        XCTAssertEqual(primary, TableKey(table: TableName(schema: "s", name: "t"), kind: .primary, columns: ["id"]))
        XCTAssertNil(PostgresOps.key(result(columns, [])))
    }

    func testPostgresUsersNeverCarryAPassword() {
        let users = PostgresOps.users(
            result(
                ["name", "rolsuper", "rolinherit", "rolcreaterole", "rolcreatedb", "rolcanlogin", "rolreplication", "rolbypassrls", "rolconnlimit", "valid_until", "member_of"],
                [
                    ["ot", "t", "t", "t", "t", "t", "t", "t", "-1", "infinity", "[]"],
                    ["readers", "f", "t", "f", "f", "f", "f", "f", "-1", nil, #"["a\"b"]"#],
                ]))
        XCTAssertEqual(users[0].superuser, true)
        XCTAssertNil(users[0].validUntil)
        XCTAssertNil(users[0].connectionLimit)
        XCTAssertEqual(users[1].isRole, true)
        XCTAssertEqual(users[1].memberOf, [#"a"b"#])
        XCTAssertFalse(PostgresOps.usersSQL.contains("rolpassword"))
        XCTAssertFalse(PostgresOps.usersSQL.contains("pg_authid"))
    }

    func testPostgresOverviewAndGrants() {
        let overview = PostgresOps.overview(
            result(
                ["version", "server_version", "uptime", "connections", "max_connections", "cache_hit", "replica", "lag", "replicas", "database", "database_size", "commits", "rollbacks", "deadlocks"],
                [["PostgreSQL 16.4 on aarch64-unknown-linux-gnu", "16.4", "90061", "5", "100", "0.995", "f", nil, "0", "shop", "8000000", "120", "3", "0"]]),
            redshift: false)
        let facts = Dictionary(uniqueKeysWithValues: overview.facts.map { ($0.title, $0.value) })
        XCTAssertEqual(facts["Version"], "16.4")
        XCTAssertEqual(facts["Uptime"], "1 d 1 h")
        XCTAssertEqual(facts["Connections"], "5 / 100")
        XCTAssertEqual(facts["Cache hit"], "99.5%")
        XCTAssertEqual(facts["Role"], "Primary")
        let grants = PostgresOps.grants(
            result(
                ["kind", "object", "schema_name", "object_name", "privileges", "grantable"],
                [["table", "public.orders", "public", "orders", "INSERT, SELECT", "t"], ["role", "readers", nil, nil, "MEMBER", "f"]]))
        XCTAssertEqual(grants[0].privileges, ["INSERT", "SELECT"])
        XCTAssertEqual(grants[0].target, .table(TableName(schema: "public", name: "orders")))
        XCTAssertNil(grants[1].target)
    }

    func testMySQLGrantsNeverCarryAHash() {
        let grants = MySQLOps.grants([
            "GRANT USAGE ON *.* TO `ot`@`%` IDENTIFIED BY PASSWORD '*6BB4837EB74329105EE4568DDA7DC67ED2CA2AD9'",
            "GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` IDENTIFIED VIA mysql_native_password USING '*81F5E21E35407D884A6CD4A731AEBFB6AF209E1B' OR unix_socket WITH GRANT OPTION",
            "GRANT USAGE ON *.* TO 'old'@'%' IDENTIFIED WITH 'mysql_native_password' AS '*ABCDEF0123456789ABCDEF0123456789ABCDEF01'",
            "GRANT SELECT, INSERT (`a`, `b`) ON `sh``op`.`orders` TO `ot`@`%`",
            "GRANT `readers`@`%` TO `ot`@`%` WITH ADMIN OPTION",
            "SET DEFAULT ROLE `readers` FOR `ot`@`%`",
        ])
        let text = grants.map { "\($0)" }.joined()
        XCTAssertFalse(text.contains("6BB4837E"))
        XCTAssertFalse(text.contains("81F5E21E"))
        XCTAssertFalse(text.contains("ABCDEF"))
        XCTAssertEqual(grants.count, 5, "SET DEFAULT ROLE isn't a grant")
        XCTAssertEqual(grants[1].privileges, ["ALL PRIVILEGES"])
        XCTAssertTrue(grants[1].grantable, "WITH GRANT OPTION kept past the hash")
        XCTAssertEqual(grants[0].target, .server)
        XCTAssertEqual(grants[3].privileges, ["SELECT", "INSERT (`a`, `b`)"])
        XCTAssertEqual(grants[3].target, .table(TableName(schema: "sh`op", name: "orders")))
        XCTAssertEqual(grants[4].kind, "role")
        XCTAssertEqual(grants[4].object, "readers@%")
        XCTAssertTrue(grants[4].grantable)
        XCTAssertEqual(MySQLOps.target("`shop`.*"), .database("shop"))
        XCTAssertNil(MySQLOps.target("PROCEDURE `shop`.`p`"))
        XCTAssertFalse(MySQLOps.mysqlUsersSQL.lowercased().contains("authentication_string"))
        XCTAssertFalse(MySQLOps.mariaUsersSQL.lowercased().contains("password,"))
    }

    func testMySQLKeysAndUsers() {
        let columns = ["schema", "name", "index", "column", "nullable", "sub_part"]
        let key = MySQLOps.key(
            result(columns, [["shop", "t", "u_prefix", "name", "", "10"], ["shop", "t", "u_nullable", "email", "YES", nil], ["shop", "t", "u_code", "code", "", nil]]))
        XCTAssertEqual(key?.kind, .unique("u_code"), "a prefix and a nullable unique index are skipped")
        XCTAssertEqual(MySQLOps.key(result(columns, [["shop", "t", "PRIMARY", "id", "", nil]]))?.kind, .primary)
        XCTAssertEqual(
            MySQLOps.readOnlyColumns(result(["name", "type", "extra"], [["g", "int", "VIRTUAL GENERATED"], ["d", "timestamp", "DEFAULT_GENERATED"], ["b", "blob", ""]])),
            ["g", "b"], "DEFAULT_GENERATED is a default, not a generated column")
        let users = MySQLOps.users(
            result(
                ["name", "host", "locked", "expired", "super", "max_connections", "plugin"], [["ot", "%", "N", "N", "N", "0", "caching_sha2_password"], ["readers", "%", "Y", "N", "N", "0", ""]]),
            roles: result(["role", "role_host", "member", "member_host"], [["readers", "%", "ot", "%"]]))
        XCTAssertEqual(users[0].memberOf, ["readers@%"])
        XCTAssertTrue(users[1].isRole)
    }

    func testSQLiteKeys() {
        let info = { (rows: [[String?]]) in self.result(["cid", "name", "type", "notnull", "dflt_value", "pk", "hidden"], rows) }
        let table = TableName(schema: "main", name: "t")
        XCTAssertEqual(
            SQLiteOps.key(table, info: info([["0", "b", "TEXT", "0", nil, "2", "0"], ["1", "a", "INT", "1", nil, "1", "0"]]), uniqueIndexes: [], withoutRowid: false)?.columns,
            ["a", "b"], "the primary key in its own order")
        let unique = SQLiteOps.key(
            table, info: info([["0", "code", "TEXT", "1", nil, "0", "0"], ["1", "data", "BLOB", "0", nil, "0", "0"], ["2", "g", "INT", "0", nil, "0", "2"]]),
            uniqueIndexes: [("u_data", ["data"]), ("u_code", ["code"])], withoutRowid: false)
        XCTAssertEqual(unique?.kind, .unique("u_code"))
        XCTAssertEqual(unique?.readOnlyColumns, ["data", "g"])
        XCTAssertEqual(SQLiteOps.key(table, info: info([["0", "a", "TEXT", "0", nil, "0", "0"]]), uniqueIndexes: [], withoutRowid: false)?.kind, .rowid)
        XCTAssertNil(SQLiteOps.key(table, info: info([]), uniqueIndexes: [], withoutRowid: true))
    }

    // MARK: What agents read

    func testAgentsReadStatementsCutToALine() {
        let long = "SELECT\n  " + String(repeating: "x, ", count: 400) + "y FROM t"
        let text = ServerText.activity(
            [DatabaseActivity(id: "9", user: "ot", database: "shop", state: "active", statement: long, seconds: 2, isOwn: false)], of: 3, limit: 50)
        XCTAssertTrue(text.contains("| 9 | ot | shop |"), text)
        XCTAssertFalse(text.contains("\n  x"), "one line")
        XCTAssertTrue(text.contains("…"))
        XCTAssertTrue(text.contains("1 of 3 sessions"))
        XCTAssertEqual(ServerText.activity([], of: 2, limit: 50), "Nothing running: 2 sessions, all idle (“idle”: true lists them).")
        let slow = ServerText.slowQueries(
            [SlowQuery(id: "a", statement: "SELECT 1", calls: 2, total: 1, mean: 0.5), SlowQuery(id: "b", statement: "SELECT 2", calls: 1, total: 0.9, mean: 0.9)],
            byMean: true, limit: 1)
        XCTAssertTrue(slow.contains("SELECT 2") && !slow.contains("SELECT 1"), slow)
        XCTAssertEqual(ServerText.gap(MonitorGap(reason: "Off.", fix: "turn it on")), "Off.\nTo turn it on: turn it on")
        XCTAssertEqual(
            OpsText.statement("ALTER ROLE app PASSWORD 'hunter''2'; ALTER USER 'u'@'%' IDENTIFIED BY 'p\\'w'"),
            "ALTER ROLE app PASSWORD '••••'; ALTER USER 'u'@'%' IDENTIFIED BY '••••'")
        XCTAssertEqual(OpsText.maskSecrets("SET PASSWORD FOR x = PASSWORD('abc')"), "SET PASSWORD FOR x = PASSWORD('••••')")
        XCTAssertEqual(OpsText.maskSecrets("CREATE USER a IDENTIFIED WITH caching_sha2_password AS '$A$005$x'"), "CREATE USER a IDENTIFIED WITH caching_sha2_password AS '••••'")
        XCTAssertEqual(OpsText.maskSecrets("SELECT 'PASSWORD' FROM t"), "SELECT 'PASSWORD' FROM t", "a word in a string isn't a password")
        let leaked = ServerText.slowQueries([SlowQuery(id: "a", statement: "CREATE ROLE x PASSWORD 'topsecret'", calls: 1, total: 1, mean: 1)], byMean: false, limit: 5)
        XCTAssertFalse(leaked.contains("topsecret"), leaked)
        XCTAssertEqual(OpsText.duration(0.004), "4 ms")
        XCTAssertEqual(OpsText.duration(75), "1 min 15 s")
    }
}
