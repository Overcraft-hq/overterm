import Foundation
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

/// Oracle: SQL and PL/SQL split as SQL*Plus does, the checks, an Easy
/// Connect string, values from their bytes — offline; the driver against
/// gvenzl/oracle-free:slim when OVERTERM_DB_TESTS=1 and
/// `Scripts/database-test-servers.sh oracle` runs it.
final class OracleTests: XCTestCase {
    private func statements(_ text: String) -> [String] {
        let ns = text as NSString
        return OracleText.statements(in: text).map { ns.substring(with: $0) }
    }

    // MARK: Statements

    func testSQLSplitsAtSemicolonsOutsideStringsAndComments() {
        let text = """
            SELECT 'a;b', "we;ird" FROM dual; -- a ; in a comment
            SELECT q'[it's; here]', q'{x;}' FROM dual;
            /* ; */ SELECT # FROM t#1;
            UPDATE t SET a = 1
            """
        XCTAssertEqual(
            statements(text),
            [
                #"SELECT 'a;b', "we;ird" FROM dual"#,
                "-- a ; in a comment\nSELECT q'[it's; here]', q'{x;}' FROM dual",
                "/* ; */ SELECT # FROM t#1",
                "UPDATE t SET a = 1",
            ])
    }

    func testABlockRunsToItsSlashLine() {
        let text = """
            BEGIN
              INSERT INTO t VALUES (1);
              DBMS_OUTPUT.PUT_LINE('done;');
            END;
            /
            SELECT 1 FROM dual;
            CREATE OR REPLACE EDITIONABLE PROCEDURE p AS
            BEGIN
              NULL;
            END p;
            /
            DECLARE x NUMBER; BEGIN x := 1; END;
            """
        XCTAssertEqual(
            statements(text),
            [
                "BEGIN\n  INSERT INTO t VALUES (1);\n  DBMS_OUTPUT.PUT_LINE('done;');\nEND;",
                "SELECT 1 FROM dual",
                "CREATE OR REPLACE EDITIONABLE PROCEDURE p AS\nBEGIN\n  NULL;\nEND p;",
                // The last block runs to the end, as SQL*Plus's would at EOF.
                "DECLARE x NUMBER; BEGIN x := 1; END;",
            ])
        // A `/` alone after a statement ends it too; nothing empty is made.
        XCTAssertEqual(statements("SELECT 1 FROM dual\n/\n/\nSELECT 2 FROM dual;"), ["SELECT 1 FROM dual", "SELECT 2 FROM dual"])
        // A `/` that isn't alone on its line is division.
        XCTAssertEqual(statements("SELECT 4\n/ 2 FROM dual;"), ["SELECT 4\n/ 2 FROM dual"])
        // CREATE TABLE is SQL, CREATE TYPE PL/SQL's.
        XCTAssertFalse(OracleText.isBlock("CREATE TABLE t (a NUMBER)"))
        XCTAssertTrue(OracleText.isBlock("-- c\ncreate or replace type t as object (a number);"))
        XCTAssertTrue(OracleText.isBlock("<<outer>> BEGIN NULL; END;"))
    }

    func testTheStatementAtTheCaret() {
        let text = "SELECT 1 FROM dual;\nBEGIN NULL; END;\n/\n"
        let at = OracleText.statement(at: 25, in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(at, "BEGIN NULL; END;")
    }

    // MARK: What it does

    func testReadsWritesAndDanger() {
        XCTAssertTrue(OracleText.onlyReads("select * from emp"))
        XCTAssertTrue(OracleText.onlyReads("WITH a AS (SELECT 1 x FROM dual) SELECT x FROM a"))
        XCTAssertTrue(OracleText.onlyReads("DESC emp"))
        XCTAssertFalse(OracleText.onlyReads("SELECT * FROM emp FOR UPDATE"))
        XCTAssertFalse(OracleText.onlyReads("BEGIN NULL; END;"), "a block is a write")
        XCTAssertFalse(OracleText.onlyReads("DECLARE x NUMBER; BEGIN SELECT 1 INTO x FROM dual; END;"))
        XCTAssertFalse(OracleText.onlyReads("EXEC dbms_stats.gather_schema_stats('OT')"))
        XCTAssertFalse(OracleText.onlyReads("MERGE INTO t USING s ON (1=1) WHEN MATCHED THEN UPDATE SET a = 1"))

        XCTAssertTrue(OracleText.agentReads("SELECT 'DELETE' AS word FROM dual"), "a string's word isn't one")
        XCTAssertFalse(OracleText.agentReads("WITH FUNCTION f RETURN NUMBER IS BEGIN RETURN 1; END; SELECT f FROM dual"))
        XCTAssertFalse(OracleText.agentReads("SELECT a INTO :x FROM t"))
        XCTAssertTrue(OracleText.agentReads("SELECT created FROM t"))

        XCTAssertEqual(OracleText.danger(of: "DROP TABLE emp PURGE"), "It drops table emp.")
        XCTAssertEqual(OracleText.danger(of: "truncate table emp"), "It empties the table.")
        XCTAssertNotNil(OracleText.danger(of: "DELETE emp"))
        XCTAssertNil(OracleText.danger(of: "DELETE FROM emp WHERE id = 1"))
        XCTAssertNil(OracleText.danger(of: "DELETE FROM emp WHERE note = 'x'"))
        XCTAssertNotNil(OracleText.danger(of: "DELETE FROM emp -- WHERE id = 1"), "a commented WHERE isn't one")
        XCTAssertNotNil(OracleText.danger(of: "BEGIN DELETE FROM emp; COMMIT; END;"), "inside a block too")
        XCTAssertNil(OracleText.danger(of: "BEGIN DELETE FROM emp WHERE id = 1; END;"))
        XCTAssertNotNil(OracleText.danger(of: "BEGIN EXECUTE IMMEDIATE 'DROP TABLE emp'; END;"))

        XCTAssertEqual(OracleText.subject(of: "SELECT * FROM hr.employees e"), "employees")
        XCTAssertEqual(OracleText.subject(of: "desc hr.emp"), "HR")
        XCTAssertEqual(OracleText.verb(of: "/* hi */ select 1 from dual"), "SELECT")
    }

    func testWhatIsSent() {
        XCTAssertEqual(OracleText.prepared("SELECT 1 FROM dual;"), "SELECT 1 FROM dual")
        XCTAssertEqual(OracleText.prepared("BEGIN NULL; END"), "BEGIN NULL; END;")
        XCTAssertEqual(OracleText.prepared("BEGIN NULL; END;"), "BEGIN NULL; END;")
        XCTAssertEqual(OracleText.prepared("exec p(1, 'a');"), "BEGIN p(1, 'a'); END;")
        XCTAssertEqual(OracleText.described("DESC hr.employees")?.owner, "HR")
        XCTAssertEqual(OracleText.described("describe \"Mixed Case\";")?.name, "Mixed Case")
        XCTAssertNil(OracleText.described("DESC")?.name)
        XCTAssertEqual(
            OracleText.browse(CatalogTable(schema: "OT", name: "Order Lines"), limit: 100), #"SELECT * FROM OT."Order Lines" FETCH FIRST 100 ROWS ONLY;"#)
    }

    func testTypeNames() {
        XCTAssertEqual(OracleText.typeName("VARCHAR2", length: 400, precision: nil, scale: nil, charLength: 100, charUsed: "C"), "VARCHAR2(100 CHAR)")
        XCTAssertEqual(OracleText.typeName("VARCHAR2", length: 40, precision: nil, scale: nil, charLength: 40, charUsed: "B"), "VARCHAR2(40)")
        XCTAssertEqual(OracleText.typeName("NUMBER", length: 22, precision: 10, scale: 2, charLength: 0, charUsed: nil), "NUMBER(10,2)")
        XCTAssertEqual(OracleText.typeName("NUMBER", length: 22, precision: nil, scale: nil, charLength: 0, charUsed: nil), "NUMBER")
        XCTAssertEqual(OracleText.typeName("NUMBER", length: 22, precision: nil, scale: 0, charLength: 0, charUsed: nil), "INTEGER")
        XCTAssertEqual(OracleText.typeName("TIMESTAMP(6)", length: 11, precision: nil, scale: 6, charLength: 0, charUsed: nil), "TIMESTAMP(6)")
    }

    // MARK: Easy Connect

    func testEasyConnect() {
        XCTAssertEqual(OracleAddress.parse("localhost:1521/FREEPDB1"), .init(host: "localhost", port: 1521, service: "FREEPDB1"))
        XCTAssertEqual(OracleAddress.parse("//db.example.com/sales.example.com"), .init(host: "db.example.com", port: nil, service: "sales.example.com"))
        XCTAssertEqual(
            OracleAddress.parse("tcps://adb.eu-frankfurt-1.oraclecloud.com:1522/abc_high.adb.oraclecloud.com?wallet_location=/x"),
            .init(host: "adb.eu-frankfurt-1.oraclecloud.com", port: 1522, service: "abc_high.adb.oraclecloud.com", tls: true))
        XCTAssertEqual(OracleAddress.parse("db:1521:ORCL"), .init(host: "db", port: 1521, service: "ORCL", sid: true))
        XCTAssertEqual(
            OracleAddress.parse("jdbc:oracle:thin:@//db:1521/svc:dedicated/inst1"), .init(host: "db", port: 1521, service: "svc"))
        XCTAssertEqual(
            OracleAddress.parse("scott/ti@ger@db:1521/orclpdb1"),
            .init(host: "db", port: 1521, service: "orclpdb1", user: "scott", password: "ti@ger"))
        XCTAssertEqual(OracleAddress.parse("[::1]:1521/FREE"), .init(host: "::1", port: 1521, service: "FREE"))
        XCTAssertNil(OracleAddress.parse("(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=db)(PORT=1521)))"), "a descriptor isn't spread over fields")
        XCTAssertNil(OracleAddress.parse(""))
    }

    // MARK: Values

    func testNumbersExactly() {
        XCTAssertEqual(OracleValueText.number([0x80]), "0")
        XCTAssertEqual(OracleValueText.number([0xC1, 0x02]), "1")
        XCTAssertEqual(OracleValueText.number([0xC2, 0x02]), "100")
        XCTAssertEqual(OracleValueText.number([0xC2, 0x02, 0x18, 0x2E]), "123.45")
        XCTAssertEqual(OracleValueText.number([0xC0, 0x33]), "0.5")
        XCTAssertEqual(OracleValueText.number([0xC0, 0x06]), "0.05")
        XCTAssertEqual(OracleValueText.number([0x3E, 0x64, 0x66]), "-1")
        XCTAssertEqual(OracleValueText.number([0x3D, 0x64, 0x4E, 0x38, 0x66]), "-123.45")
        // 12345678901234567890: past a Double's 53 bits, every digit kept.
        XCTAssertEqual(OracleValueText.number([0xCA, 0x0D, 0x23, 0x39, 0x4F, 0x5B, 0x0D, 0x23, 0x39, 0x4F, 0x5B]), "12345678901234567890")
    }

    func testDatesAndIntervals() {
        // 2024-02-29 13:45:07
        XCTAssertEqual(OracleValueText.dateTime([120, 124, 2, 29, 14, 46, 8], withZone: false), "2024-02-29 13:45:07")
        XCTAssertEqual(OracleValueText.dateTime([120, 124, 2, 29, 1, 1, 1], withZone: false), "2024-02-29")
        // …with 0.123456 s
        XCTAssertEqual(
            OracleValueText.dateTime([120, 124, 2, 29, 14, 46, 8, 0x07, 0x5B, 0xCA, 0x00], withZone: false), "2024-02-29 13:45:07.123456")
        // 12:00 UTC at +05:30 is 17:30 there.
        XCTAssertEqual(
            OracleValueText.dateTime([120, 124, 1, 1, 13, 1, 1, 0, 0, 0, 0, 25, 90], withZone: true), "2024-01-01 17:30:00 +05:30")
        XCTAssertEqual(
            OracleValueText.dateTime([120, 124, 1, 1, 13, 1, 1, 0, 0, 0, 0, 15, 30], withZone: true), "2024-01-01 06:30:00 -05:30")
        // +2 days 03:04:05.5
        XCTAssertEqual(
            OracleValueText.interval([0x80, 0, 0, 2, 63, 64, 65, 0x9D, 0xCD, 0x65, 0x00], yearToMonth: false), "+2 03:04:05.5")
        XCTAssertEqual(OracleValueText.interval([0x80, 0, 0, 1, 66], yearToMonth: true), "+1-06")
        XCTAssertEqual(OracleValueText.hex([0xDE, 0xAD, 0x01]), "DEAD01")
        XCTAssertEqual(OracleValueText.lob("CLOB", text: String(repeating: "a", count: 250), bytes: 0), String(repeating: "a", count: 200) + "… (CLOB, 250 characters)")
        XCTAssertEqual(OracleValueText.lob("BLOB", text: nil, bytes: 2048), "(BLOB, 2 KB)")
        XCTAssertEqual(OracleDriver.lobText([0x00, 0x68, 0x00, 0xE9]), "hé")
        XCTAssertEqual(OracleDriver.lobText(Array("hé".utf8)), "hé")
    }

    func testErrorsInWords() {
        XCTAssertTrue(OracleErrors.explain(number: 1017, message: "ORA-01017: invalid", place: "h:1", service: "S").contains("user or password"))
        XCTAssertTrue(OracleErrors.explain(number: 12514, message: "ORA-12514", place: "h:1", service: "NOPE").contains("“NOPE”"))
        XCTAssertEqual(OracleErrors.explain(number: 942, message: "ORA-00942: table or view does not exist", place: "", service: ""), "ORA-00942: table or view does not exist")
    }

    // MARK: Docker

    private func container(_ image: String) -> ContainerSummary {
        ContainerSummary(
            Id: "ora", Names: ["/ora"], Image: image, Created: 1, Ports: [DockerPort(IP: "0.0.0.0", PrivatePort: 1521, PublicPort: 51521, Type: "tcp")],
            Labels: [:], State: "running", Status: "Up")
    }

    func testDockerImagesAsConnections() throws {
        for image in [
            "gvenzl/oracle-free:slim", "gvenzl/oracle-xe:21-slim", "container-registry.oracle.com/database/free:latest",
            "container-registry.oracle.com/database/enterprise:21.3.0.0", "oracle/database:19.3.0-ee",
        ] {
            XCTAssertEqual(DockerDatabaseGuess.kind(of: image)?.0, .oracle, image)
        }
        for image in ["oraclelinux:9", "ghcr.io/oracle/oraclelinux:9", "ghcr.io/graalvm/graalvm-ce", "iamseth/oracledb_exporter", "container-registry.oracle.com/mysql/community-server:9.1"] {
            XCTAssertNotEqual(DockerDatabaseGuess.kind(of: image)?.0, .oracle, image)
        }

        let app = try XCTUnwrap(
            DockerDatabaseGuess.guess(
                container("gvenzl/oracle-free:slim"), env: [("ORACLE_PASSWORD", "sys"), ("APP_USER", "ot"), ("APP_USER_PASSWORD", "otpass")]))
        XCTAssertEqual(app.connection.kind, .oracle)
        XCTAssertEqual(app.connection.port, 51521)
        XCTAssertEqual(app.connection.user, "ot")
        XCTAssertEqual(app.password, "otpass")
        XCTAssertEqual(app.connection.database, "FREEPDB1")
        XCTAssertEqual(app.connection.sslMode, .disable)

        let system = try XCTUnwrap(DockerDatabaseGuess.guess(container("gvenzl/oracle-xe:21"), env: [("ORACLE_PASSWORD", "sys")]))
        XCTAssertEqual(system.connection.user, "system")
        XCTAssertEqual(system.password, "sys")
        XCTAssertEqual(system.connection.database, "XEPDB1")
        let named = DockerDatabaseGuess.guess(container("gvenzl/oracle-free"), env: [("ORACLE_DATABASE", "SHOP,OTHER")])
        XCTAssertEqual(named?.connection.database, "SHOP")
        let official = DockerDatabaseGuess.guess(container("container-registry.oracle.com/database/enterprise:21.3.0.0"), env: [("ORACLE_PWD", "pw")])
        XCTAssertEqual(official?.connection.database, "ORCLPDB1")
        XCTAssertEqual(official?.password, "pw")
    }

    // MARK: Against gvenzl/oracle-free:slim

    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(user: String = "ot", service: String = "FREEPDB1") -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Oracle", kind: .oracle)
        connection.host = "127.0.0.1"
        connection.port = 51521
        connection.user = user
        connection.database = service
        connection.sslMode = .disable
        return connection
    }

    func testDriverAgainstOracleFree() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh oracle") }
        let driver = OracleDriver(connection(), password: "otpass")
        try await driver.connect()
        defer { Task { await driver.close() } }
        _ = try? await driver.execute("DROP TABLE ot_items PURGE", limit: 1)
        _ = try await driver.execute(
            """
            CREATE TABLE ot_items (id NUMBER(10) PRIMARY KEY, name VARCHAR2(40 CHAR) NOT NULL, price NUMBER(12,2), big NUMBER,
              made DATE, at TIMESTAMP(6), zoned TIMESTAMP(3) WITH TIME ZONE, took INTERVAL DAY TO SECOND, note CLOB, data BLOB, raw16 RAW(4),
              ratio BINARY_DOUBLE)
            """, limit: 1)
        let inserted = try await driver.execute(
            """
            INSERT INTO ot_items VALUES (1, 'Ünïcode;', 1234.5, 12345678901234567890.0001, DATE '2024-02-29',
              TIMESTAMP '2024-02-29 13:45:07.123456', TIMESTAMP '2024-01-01 12:00:00.5 +05:30', INTERVAL '2 03:04:05.5' DAY TO SECOND,
              RPAD('x', 300, 'y'), HEXTORAW('DEADBEEF'), HEXTORAW('0A0B'), 0.25);
            """, limit: 1)
        XCTAssertEqual(inserted.affected, 1)
        _ = try await driver.execute("INSERT INTO ot_items (id, name) VALUES (2, 'two')", limit: 1)

        let read = try await driver.execute("SELECT * FROM ot_items ORDER BY id", limit: 100)
        XCTAssertEqual(
            read.columns, ["ID", "NAME", "PRICE", "BIG", "MADE", "AT", "ZONED", "TOOK", "NOTE", "DATA", "RAW16", "RATIO"])
        XCTAssertEqual(read.types[0], "NUMBER")
        XCTAssertEqual(read.types[8], "CLOB")
        let row = read.rows[0]
        XCTAssertEqual(row[0], "1")
        XCTAssertEqual(row[1], "Ünïcode;")
        XCTAssertEqual(row[2], "1234.5")
        XCTAssertEqual(row[3], "12345678901234567890.0001")
        XCTAssertEqual(row[4], "2024-02-29")
        XCTAssertEqual(row[5], "2024-02-29 13:45:07.123456")
        XCTAssertEqual(row[6], "2024-01-01 12:00:00.5 +05:30")
        XCTAssertEqual(row[7], "+2 03:04:05.5")
        XCTAssertEqual(row[8], "x" + String(repeating: "y", count: 199) + "… (CLOB, 300 characters)")
        XCTAssertEqual(row[9], "(BLOB, 4 bytes)")
        XCTAssertEqual(row[10], "0A0B")
        XCTAssertEqual(row[11], "0.25")
        XCTAssertEqual(read.rows[1][2], nil, "NULL is nil")

        // The limit kept, more said, and the connection still good after.
        let many = try await driver.execute("SELECT level FROM dual CONNECT BY level <= 5000", limit: 10)
        XCTAssertEqual(many.rows.count, 10)
        XCTAssertTrue(many.truncated)
        let after = try await driver.execute("SELECT COUNT(*) FROM ot_items", limit: 10)
        XCTAssertEqual(after.rows, [["2"]])

        // An empty read keeps its columns.
        let empty = try await driver.execute("SELECT id, name FROM ot_items WHERE 1 = 0", limit: 10)
        XCTAssertEqual(empty.columns, ["ID", "NAME"])
        XCTAssertEqual(empty.types, ["NUMBER", "VARCHAR2"])

        // PL/SQL: a block with DBMS_OUTPUT, EXEC, a procedure made and called.
        let block = try await driver.execute(
            "BEGIN UPDATE ot_items SET price = price + 1 WHERE id = 1; DBMS_OUTPUT.PUT_LINE('changed ' || SQL%ROWCOUNT); END;", limit: 1)
        XCTAssertEqual(block.message, "PL/SQL procedure successfully completed.\nchanged 1")
        _ = try await driver.execute(
            "CREATE OR REPLACE PROCEDURE ot_bump(p_id NUMBER) AS BEGIN UPDATE ot_items SET price = price + 1 WHERE id = p_id; END;", limit: 1)
        _ = try await driver.execute("EXEC ot_bump(1)", limit: 1)
        let bumped = try await driver.execute("SELECT price FROM ot_items WHERE id = 1", limit: 1)
        XCTAssertEqual(bumped.rows, [["1236.5"]])

        // DESC, as SQL*Plus.
        let described = try await driver.execute("DESC ot_items", limit: 100)
        XCTAssertEqual(described.columns, ["Name", "Null?", "Type"])
        XCTAssertEqual(described.rows[1], ["NAME", "NOT NULL", "VARCHAR2(40 CHAR)"])
        XCTAssertEqual(described.rows[2], ["PRICE", nil, "NUMBER(12,2)"])

        // The catalog: the user's own schema first, its tables and columns.
        let schemas = try await driver.schemas()
        XCTAssertEqual(schemas.first, "OT")
        XCTAssertFalse(schemas.contains("SYS"), "Oracle's own schemas are left out")
        _ = try await driver.execute("CREATE OR REPLACE VIEW ot_cheap AS SELECT id, name FROM ot_items WHERE price < 10", limit: 1)
        let tables = try await driver.tables(in: "OT")
        XCTAssertTrue(tables.contains(CatalogTable(schema: "OT", name: "OT_ITEMS")))
        XCTAssertTrue(tables.contains(CatalogTable(schema: "OT", name: "OT_CHEAP", isView: true)))
        let columns = try await driver.columns(in: "OT").filter { $0.table == "OT_ITEMS" }
        XCTAssertEqual(columns.first, CatalogColumn(table: "OT_ITEMS", name: "ID", type: "NUMBER(10)", nullable: false))

        // An error is Oracle's own words.
        do {
            _ = try await driver.execute("SELECT * FROM ot_missing", limit: 1)
            XCTFail("no such table")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ORA-00942"), error.localizedDescription)
        }
        _ = try await driver.execute("DROP VIEW ot_cheap", limit: 1)
        _ = try await driver.execute("DROP PROCEDURE ot_bump", limit: 1)
        _ = try await driver.execute("DROP TABLE ot_items PURGE", limit: 1)
    }

    func testReadOnlyAgainstOracleFree() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh oracle") }
        var config = connection()
        config.readOnly = true
        let driver = OracleDriver(config, password: "otpass")
        try await driver.connect()
        defer { Task { await driver.close() } }
        // Refused before sending.
        do {
            _ = try await driver.execute("BEGIN NULL; END;", limit: 1)
            XCTFail("a block on a read-only connection")
        } catch {
            XCTAssertEqual(error as? DatabaseError, .readOnly("BEGIN"))
        }
        // And the server's own refusal behind: a read that writes through a
        // function would meet SET TRANSACTION READ ONLY. Reads still run,
        // one after the other (each transaction ended).
        for _ in 0..<3 {
            let read = try await driver.execute("SELECT 1 AS one FROM dual", limit: 1)
            XCTAssertEqual(read.rows, [["1"]])
        }
    }

    func testFailuresInWords() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh oracle") }
        let wrong = OracleDriver(connection(), password: "nope")
        do {
            try await wrong.connect()
            XCTFail("a wrong password")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refused the user or password"), error.localizedDescription)
        }
        let service = OracleDriver(connection(service: "NOPE"), password: "otpass")
        do {
            try await service.connect()
            XCTFail("an unknown service")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("doesn't serve “NOPE”"), error.localizedDescription)
        }
        var closed = connection()
        closed.port = 51599
        do {
            try await OracleDriver(closed, password: "otpass").connect()
            XCTFail("nothing there")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing answers"), error.localizedDescription)
        }
        var tls = connection()
        tls.sslMode = .require
        do {
            try await OracleDriver(tls, password: "otpass").connect()
            XCTFail("TLS to a plain listener")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("TLS"), error.localizedDescription)
        }
    }
}
