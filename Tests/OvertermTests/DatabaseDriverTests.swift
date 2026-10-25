import XCTest
import _CryptoExtras

@testable import Overterm

/// The drivers against real databases. SQLite always; PostgreSQL, MySQL and
/// ClickHouse when OVERTERM_DB_TESTS=1 and Scripts/database-test-servers.sh
/// has them running in Docker. BigQuery's signing and answers, offline.
final class DatabaseDriverTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(_ kind: DatabaseKind, port: Int) -> DatabaseConnection {
        var connection = DatabaseConnection(name: kind.title, kind: kind)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.user = "ot"
        connection.database = "shop"
        connection.sslMode = .disable
        return connection
    }

    /// The same work on every server: a table made, filled, read back,
    /// limited, described; a mistake said as the server says it.
    private func exercise(_ driver: any DatabaseDriver, schema: String, create: String, file: StaticString = #filePath, line: UInt = #line)
        async throws
    {
        try await driver.connect()
        _ = try? await driver.execute("DROP TABLE orders", limit: 10)
        _ = try await driver.execute(create, limit: 10)
        let inserted = try await driver.execute("INSERT INTO orders (id, note) VALUES (1, 'first'), (2, NULL), (3, 'it''s; third')", limit: 10)
        XCTAssertFalse(inserted.hasRows, file: file, line: line)
        let all = try await driver.execute("SELECT id, note FROM orders ORDER BY id", limit: 100)
        XCTAssertEqual(all.columns, ["id", "note"], file: file, line: line)
        XCTAssertEqual(all.rows, [["1", "first"], ["2", nil], ["3", "it's; third"]], file: file, line: line)
        XCTAssertFalse(all.truncated, file: file, line: line)
        let limited = try await driver.execute("SELECT id FROM orders ORDER BY id", limit: 2)
        XCTAssertEqual(limited.rows.count, 2, file: file, line: line)
        XCTAssertTrue(limited.truncated, "more rows than the limit", file: file, line: line)
        do {
            _ = try await driver.execute("SELECT nope FROM orders", limit: 10)
            XCTFail("a missing column", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("nope"), error.localizedDescription, file: file, line: line)
        }
        let schemas = try await driver.schemas()
        XCTAssertTrue(schemas.contains(schema), "\(schemas)", file: file, line: line)
        let tables = try await driver.tables(in: schema)
        XCTAssertTrue(tables.contains { $0.name == "orders" }, "\(tables)", file: file, line: line)
        let columns = try await driver.columns(in: schema).filter { $0.table == "orders" }
        XCTAssertEqual(columns.map(\.name), ["id", "note"], file: file, line: line)
        _ = try await driver.execute("DROP TABLE orders", limit: 10)
        await driver.close()
    }

    func testSQLite() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var connection = DatabaseConnection(name: "local", kind: .sqlite)
        connection.filePath = file.path
        try await exercise(SQLiteDriver(connection), schema: "main", create: "CREATE TABLE orders (id INTEGER PRIMARY KEY, note TEXT)")
        // Read-only: SQLite itself refuses the write.
        connection.readOnly = true
        let reader = SQLiteDriver(connection)
        try await reader.connect()
        do {
            _ = try await reader.execute("CREATE TABLE x (a int)", limit: 1)
            XCTFail("a read-only file was written")
        } catch {}
    }

    func testPostgres() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = PostgresDriver(connection(.postgres, port: 55432), password: "otpass")
        try await exercise(driver, schema: "public", create: "CREATE TABLE orders (id int PRIMARY KEY, note text)")
        // Types as text; no rows, still its columns.
        try await driver.connect()
        let typed = try await driver.execute(
            """
            SELECT 1::int AS i, true AS b, '{"a": 1}'::jsonb AS j, NULL::text AS n, DATE '2026-03-07' AS d,
              TIMESTAMP '2026-03-07 09:05:01' AS t, 12.50::numeric AS m, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS u,
              2.5::float8 AS f, '\\xdead'::bytea AS y, ARRAY[1, 2] AS a
            """, limit: 10)
        XCTAssertEqual(
            typed.rows,
            [["1", "t", "{\"a\": 1}", nil, "2026-03-07", "2026-03-07 09:05:01", "12.5", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "2.5", "\\xdead", "{1,2}"]])
        XCTAssertEqual(typed.types.first, "INTEGER")
        let empty = try await driver.execute("SELECT 1 AS a, 'x' AS b WHERE false", limit: 10)
        XCTAssertEqual(empty.columns, ["a", "b"], "an empty result keeps its columns")
        await driver.close()
        var readOnly = connection(.postgres, port: 55432)
        readOnly.readOnly = true
        let reader = PostgresDriver(readOnly, password: "otpass")
        try await reader.connect()
        do {
            _ = try await reader.execute("CREATE TABLE x (a int)", limit: 1)
            XCTFail("a read-only session wrote")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("read-only"), error.localizedDescription)
        }
        await reader.close()
        // A wrong password is the server's sentence, not a code.
        do {
            try await PostgresDriver(connection(.postgres, port: 55432), password: "wrong").connect()
            XCTFail("connected with a wrong password")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("password"), error.localizedDescription)
        }
    }

    func testMySQL() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = MySQLDriver(connection(.mysql, port: 53306), password: "otpass")
        try await exercise(driver, schema: "shop", create: "CREATE TABLE orders (id int PRIMARY KEY, note text)")
        try await driver.connect()
        _ = try await driver.execute("CREATE TABLE IF NOT EXISTS counted (id int)", limit: 1)
        let affected = try await driver.execute("INSERT INTO counted VALUES (1), (2), (3)", limit: 1)
        XCTAssertEqual(affected.affected, 3, "a write says how many rows it changed")
        _ = try await driver.execute("DROP TABLE counted", limit: 1)
        await driver.close()
    }

    func testClickHouse() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let driver = ClickHouseDriver(connection(.clickhouse, port: 58123), password: "otpass")
        try await exercise(driver, schema: "shop", create: "CREATE TABLE orders (id UInt32, note Nullable(String)) ENGINE = MergeTree ORDER BY id")
    }

    // MARK: BigQuery, offline

    func testBigQueryServiceAccountSignsItsJWT() throws {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let jwt = try BigQueryDriver.jwt(
            email: "bot@p.iam.gserviceaccount.com", privateKey: key.pemRepresentation, audience: "https://oauth2.googleapis.com/token",
            now: Date(timeIntervalSince1970: 1000))
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func decode(_ part: String) -> Data {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            return Data(base64Encoded: base64)!
        }
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        XCTAssertEqual(claims["iss"] as? String, "bot@p.iam.gserviceaccount.com")
        XCTAssertEqual(claims["exp"] as? Int, 4600)
        XCTAssertEqual(claims["scope"] as? String, "https://www.googleapis.com/auth/bigquery")
        let signature = _RSA.Signing.RSASignature(rawRepresentation: decode(parts[2]))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8), padding: .insecurePKCS1v1_5))
    }

    func testBigQueryAnswersAreRead() {
        let answer: [String: Any] = [
            "jobComplete": true, "totalRows": "3", "totalBytesProcessed": "2048", "cacheHit": false,
            "schema": [
                "fields": [
                    ["name": "id", "type": "INTEGER"], ["name": "at", "type": "TIMESTAMP"],
                    ["name": "tags", "type": "STRING", "mode": "REPEATED"],
                ]
            ],
            "rows": [
                ["f": [["v": "1"], ["v": "1.7729E9"], ["v": [["v": "a"], ["v": "b"]]]]],
                ["f": [["v": "2"], ["v": NSNull()], ["v": []]]],
            ],
        ]
        let result = BigQueryDriver.parse(answer, limit: 10)
        XCTAssertEqual(result.columns, ["id", "at", "tags"])
        XCTAssertEqual(result.types, ["INTEGER", "TIMESTAMP", "ARRAY<STRING>"])
        XCTAssertEqual(result.rows[0][0], "1")
        XCTAssertEqual(result.rows[0][1], "2026-03-07T16:13:20.000Z")
        XCTAssertEqual(result.rows[0][2], #"["a","b"]"#)
        XCTAssertNil(result.rows[1][1])
        XCTAssertTrue(result.truncated, "three rows, two fetched")
        XCTAssertEqual(result.message, "2 KB processed")
    }

    func testClickHouseAnswersAreRead() throws {
        let body = #"{"meta":[{"name":"id","type":"UInt32"},{"name":"note","type":"Nullable(String)"}],"data":[[1,"a"],[2,null]],"rows":2,"statistics":{"rows_read":2}}"#
        let result = try ClickHouseDriver.parse(Data(body.utf8), limit: 1)
        XCTAssertEqual(result.rows, [["1", "a"]])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(
            ClickHouseDriver.message("Code: 60. DB::Exception: Table shop.x does not exist. (UNKNOWN_TABLE) (version 24.8.1)"),
            "Table shop.x does not exist. (UNKNOWN_TABLE)")
    }
}
