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
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

/// InfluxDB: the console's statements and checks, InfluxQL's JSON and
/// Flux's annotated CSV as rows, the version from `/ping` — offline; the
/// driver against 2.x and 1.8 when OVERTERM_DB_TESTS=1 and
/// Scripts/database-test-servers.sh runs them.
final class InfluxDBTests: XCTestCase {
    private func statements(_ text: String) -> [String] {
        let ns = text as NSString
        return InfluxText.statements(in: text).map { ns.substring(with: $0) }
    }

    func testStatementsByBlankLinesAndSemicolons() {
        let text = """
            SELECT * FROM cpu; SHOW MEASUREMENTS

            from(bucket: "b")
              |> range(start: -1h)
              |> filter(fn: (r) => r.host == "a;b") // a ; in a comment

            WRITE cpu,host=a value=1 1700000000000000000
            cpu,host=b value=2;3 1700000000000000000

            USE "other"
            SELECT 1
            """
        XCTAssertEqual(
            statements(text),
            [
                "SELECT * FROM cpu", "SHOW MEASUREMENTS",
                "from(bucket: \"b\")\n  |> range(start: -1h)\n  |> filter(fn: (r) => r.host == \"a;b\") // a ; in a comment",
                "WRITE cpu,host=a value=1 1700000000000000000\ncpu,host=b value=2;3 1700000000000000000",
                "USE \"other\"\nSELECT 1",
            ])
    }

    func testWhatReadsAndWhatWrites() {
        XCTAssertTrue(InfluxText.onlyReads("SELECT mean(value) FROM cpu GROUP BY time(1m)"))
        XCTAssertTrue(InfluxText.onlyReads("SHOW TAG KEYS"))
        XCTAssertTrue(InfluxText.onlyReads("USE telegraf"))
        XCTAssertTrue(InfluxText.onlyReads("from(bucket: \"b\") |> range(start: -1h) |> filter(fn: (r) => r._field == \"to(\")"))
        XCTAssertFalse(InfluxText.onlyReads("from(bucket: \"b\") |> range(start: -1h) |> to(bucket: \"c\")"))
        XCTAssertFalse(InfluxText.onlyReads("import \"http\"\nhttp.post(url: \"https://x\", data: bytes(v: \"a\"))"))
        XCTAssertTrue(InfluxText.onlyReads("import \"sql\"\nsql.from(driverName: \"postgres\", dataSourceName: \"x\", query: \"SELECT 1\")"))
        XCTAssertFalse(InfluxText.onlyReads("SELECT * INTO copy FROM cpu"))
        XCTAssertFalse(InfluxText.onlyReads("WRITE cpu value=1"))
        XCTAssertFalse(InfluxText.agentReads("DROP MEASUREMENT cpu"))
        XCTAssertFalse(InfluxText.onlyReads("CREATE DATABASE x"))
        XCTAssertEqual(InfluxText.verb(of: "WRITE cpu value=1"), "WRITE")
        XCTAssertEqual(InfluxText.verb(of: "from(bucket: \"b\")"), "Flux")
        XCTAssertEqual(InfluxText.verb(of: "USE x\nDROP DATABASE x"), "DROP")
        XCTAssertNotNil(InfluxText.danger(of: "DROP MEASUREMENT cpu"))
        XCTAssertNotNil(InfluxText.danger(of: "DELETE FROM cpu"))
        XCTAssertNil(InfluxText.danger(of: "DELETE FROM cpu WHERE time < now() - 30d"))
        XCTAssertNotNil(InfluxText.danger(of: "DROP SERIES"))
        XCTAssertNil(InfluxText.danger(of: "SELECT * FROM cpu"))
    }

    func testUseAndSubject() {
        XCTAssertEqual(InfluxText.use("USE \"my db\"")?.database, "my db")
        XCTAssertEqual(InfluxText.use("use telegraf\nSELECT 1")?.rest, "SELECT 1")
        XCTAssertNil(InfluxText.use("SELECT 1"))
        XCTAssertEqual(InfluxText.subject(of: "SELECT * FROM \"cpu load\" LIMIT 1"), "cpu load")
        XCTAssertEqual(InfluxText.subject(of: "SELECT * FROM telegraf.autogen.mem"), "mem")
        XCTAssertEqual(InfluxText.subject(of: "from(bucket: \"b\") |> filter(fn: (r) => r._measurement == \"disk\")"), "disk")
        XCTAssertEqual(InfluxText.subject(of: "WRITE weather,city=a temp=1"), "weather")
        XCTAssertEqual(InfluxText.lineProtocol("WRITE a v=1\n# a comment\n b v=2 "), "a v=1\nb v=2")
        XCTAssertNil(InfluxText.lineProtocol("WRITER x"))
    }

    func testBrowseByVersion() {
        var connection = DatabaseConnection(name: "i", kind: .influxdb)
        let table = CatalogTable(schema: "telegraf", name: "cpu")
        XCTAssertEqual(InfluxText.browse(table, connection: connection, limit: 100), "USE \"telegraf\"\nSELECT * FROM \"cpu\" ORDER BY time DESC LIMIT 100")
        connection.location = "2"
        XCTAssertTrue(InfluxText.browse(table, connection: connection, limit: 5).contains("r._measurement == \"cpu\""))
    }

    func testVersionFromPing() {
        XCTAssertEqual(InfluxVersion.from(header: "1.8.10"), .v1)
        XCTAssertEqual(InfluxVersion.from(header: "v2.7.11"), .v2)
        XCTAssertEqual(InfluxVersion.from(header: "3.0.1"), .v3)
        XCTAssertNil(InfluxVersion.from(header: nil))
    }

    func testInfluxQLSeriesAsRows() throws {
        let data = Data(
            #"""
            {"results":[{"statement_id":0,"series":[
              {"name":"cpu","tags":{"host":"a"},"columns":["time","value"],"values":[["2026-01-01T00:00:00Z",0.5],["2026-01-01T00:01:00Z",null]]},
              {"name":"cpu","tags":{"host":"b"},"columns":["time","value"],"values":[["2026-01-01T00:00:00Z",true]]}
            ]}]}
            """#.utf8)
        let series = try InfluxParse.influxQL(data)
        let result = InfluxParse.rows(series[0], limit: 2)
        XCTAssertEqual(result.columns, ["host", "time", "value"])
        XCTAssertEqual(result.rows, [["a", "2026-01-01T00:00:00Z", "0.5"], ["a", "2026-01-01T00:01:00Z", nil]])
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(InfluxParse.rows(series[0], limit: 10).rows.last, ["b", "2026-01-01T00:00:00Z", "true"])
        XCTAssertThrowsError(try InfluxParse.influxQL(Data(#"{"results":[{"statement_id":0,"error":"database not found: x"}]}"#.utf8))) {
            XCTAssertEqual($0.localizedDescription, "database not found: x")
        }
    }

    func testFluxAnnotatedCSV() throws {
        let csv = #"""
            #datatype,string,long,dateTime:RFC3339,string,double,string
            #group,false,false,false,true,false,true
            #default,_result,,,,,
            ,result,table,_time,_field,_value,host
            ,,0,2026-01-01T00:00:00Z,usage,1.5,a
            ,,0,2026-01-01T00:01:00Z,usage,,a

            #datatype,string,long,string,string
            #group,false,false,true,false
            #default,_result,,,
            ,result,table,_field,note
            ,,1,msg,"quoted, with ""comma"""


            """#.replacingOccurrences(of: "\n", with: "\r\n")
        let result = try InfluxParse.flux(csv, limit: 10)
        XCTAssertEqual(result.columns, ["table", "_time", "_field", "_value", "host", "note"])
        XCTAssertEqual(result.types, ["long", "dateTime:RFC3339", "string", "double", "string", "string"])
        XCTAssertEqual(result.rows[0], ["0", "2026-01-01T00:00:00Z", "usage", "1.5", "a", nil])
        XCTAssertEqual(result.rows[1][3], nil, "an empty double is NULL")
        XCTAssertEqual(result.rows[2], ["1", nil, "msg", nil, nil, "quoted, with \"comma\""])
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(try InfluxParse.flux(csv, limit: 1).truncated)
        XCTAssertThrowsError(try InfluxParse.flux(",error,reference\r\n,failed to parse: x,897\r\n", limit: 10)) {
            XCTAssertEqual($0.localizedDescription, "failed to parse: x")
        }
    }

    func testPlainCSV() {
        let result = InfluxParse.plainCSV("time,host,usage\n2026-01-01T00:00:00,a,\n2026-01-01T00:01:00,b,2\n", limit: 1)
        XCTAssertEqual(result.columns, ["time", "host", "usage"])
        XCTAssertEqual(result.rows, [["2026-01-01T00:00:00", "a", nil]])
        XCTAssertTrue(result.truncated)
    }

    func testAddressPasted() throws {
        let connection = DatabaseConnection(name: "", kind: .influxdb)
        let filled = try XCTUnwrap(KindAddress.fill(connection, from: "https://admin:s3cret@influx.example.com/influx?org=acme&bucket=metrics"))
        XCTAssertEqual(filled.connection.host, "influx.example.com")
        XCTAssertEqual(filled.connection.port, 443)
        XCTAssertEqual(filled.connection.basePath, "/influx")
        XCTAssertEqual(filled.connection.project, "acme")
        XCTAssertEqual(filled.connection.database, "metrics")
        XCTAssertEqual(filled.connection.user, "admin")
        XCTAssertEqual(filled.password, "s3cret")
    }

    // MARK: Against real servers

    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func connection(port: Int) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "InfluxDB", kind: .influxdb)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.sslMode = .disable
        return connection
    }

    /// 2.x: the version from /ping, Flux, a WRITE, InfluxQL through the
    /// compatibility API, the catalog, read-only, a wrong token.
    func testDriverAgainstInfluxDB2() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        var config = connection(port: 58086)
        config.project = "ot"
        config.database = "shop"
        let driver = InfluxDBDriver(config, password: "ot-test-token")
        try await driver.connect()
        let version = await driver.version
        XCTAssertEqual(version, .v2)
        let written = try await driver.execute("WRITE orders,store=a amount=1.5,note=\"it's\" 1700000000000000000\norders,store=b amount=2 1700000060000000000", limit: 10)
        XCTAssertEqual(written.message, "2 points written to shop.")
        let flux = try await driver.execute(
            "from(bucket: \"shop\") |> range(start: 2023-11-01T00:00:00Z) |> filter(fn: (r) => r._measurement == \"orders\" and r._field == \"amount\")",
            limit: 100)
        XCTAssertEqual(flux.rows.count, 2)
        let value = try XCTUnwrap(flux.columns.firstIndex(of: "_value"))
        XCTAssertEqual(Set(flux.rows.compactMap { $0[value] }), ["1.5", "2"])
        let influxQL = try await driver.execute("SELECT amount, store FROM orders", limit: 100)
        XCTAssertEqual(influxQL.columns, ["time", "amount", "store"])
        XCTAssertEqual(influxQL.rows.count, 2)
        let schemas = try await driver.schemas()
        XCTAssertEqual(schemas.first, "shop")
        let measurements = try await driver.tables(in: "shop").map(\.name)
        XCTAssertEqual(measurements, ["orders"])
        let columns = try await driver.columns(in: "shop").map { "\($0.table).\($0.name) \($0.type)" }.sorted()
        XCTAssertEqual(columns, ["orders.amount float", "orders.note string", "orders.store tag"])
        do {
            _ = try await driver.execute("from(bucket: \"nope\") |> range(start: -1h)", limit: 10)
            XCTFail("a missing bucket read")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nope"), error.localizedDescription)
        }
        await driver.close()
        var readOnly = config
        readOnly.readOnly = true
        do {
            _ = try await InfluxDBDriver(readOnly, password: "ot-test-token").execute("WRITE orders amount=3", limit: 1)
            XCTFail("a read-only connection wrote")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("only reads"), error.localizedDescription)
        }
        do {
            try await InfluxDBDriver(config, password: "wrong").connect()
            XCTFail("a wrong token connected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refused the credentials"), error.localizedDescription)
        }
    }

    /// 1.x (1.11): InfluxQL with a user and password, a WRITE, the catalog.
    func testDriverAgainstInfluxDB1() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        var config = connection(port: 58087)
        config.user = "ot"
        config.database = "shop"
        let driver = InfluxDBDriver(config, password: "otpass")
        try await driver.connect()
        let version = await driver.version
        XCTAssertEqual(version, .v1)
        _ = try await driver.execute("WRITE orders,store=a amount=1.5 1700000000000000000\norders,store=b amount=2 1700000060000000000", limit: 10)
        let rows = try await driver.execute("SELECT * FROM orders", limit: 1)
        XCTAssertEqual(rows.columns, ["time", "amount", "store"])
        XCTAssertEqual(rows.rows, [["2023-11-14T22:13:20Z", "1.5", "a"]])
        XCTAssertTrue(rows.truncated)
        let databases = try await driver.schemas()
        XCTAssertTrue(databases.contains("shop"))
        let measurements = try await driver.tables(in: "shop").map(\.name)
        XCTAssertEqual(measurements, ["orders"])
        let columns = try await driver.columns(in: "shop").map { "\($0.name) \($0.type)" }.sorted()
        XCTAssertEqual(columns, ["amount float", "store tag"])
        let used = try await driver.execute("USE \"_internal\"", limit: 1)
        XCTAssertEqual(used.message, "Using _internal.")
        let database = await driver.database
        XCTAssertEqual(database, "_internal")
        await driver.close()
        do {
            try await InfluxDBDriver(config, password: "wrong").connect()
            XCTFail("a wrong password connected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("refused the credentials"), error.localizedDescription)
        }
    }

    /// 3.x (Core): the version from /ping, a WRITE, SQL, InfluxQL's SHOW, the catalog.
    func testDriverAgainstInfluxDB3() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        var config = connection(port: 58181)
        config.database = "shop"
        let driver = InfluxDBDriver(config, password: nil)
        try await driver.connect()
        let version = await driver.version
        XCTAssertEqual(version, .v3)
        let written = try await driver.execute("WRITE orders,store=a amount=1.5 1700000000000000000\norders,store=b amount=2 1700000060000000000", limit: 10)
        XCTAssertEqual(written.message, "2 points written to shop.")
        let rows = try await driver.execute("SELECT store, amount FROM orders ORDER BY time", limit: 1)
        XCTAssertEqual(rows.columns, ["store", "amount"])
        XCTAssertEqual(rows.rows, [["a", "1.5"]])
        XCTAssertTrue(rows.truncated)
        let shown = try await driver.execute("SHOW MEASUREMENTS", limit: 10)
        XCTAssertEqual(InfluxParse.column("name", of: shown), ["orders"])
        let databases = try await driver.schemas()
        XCTAssertEqual(databases.first, "shop")
        let measurements = try await driver.tables(in: "shop").map(\.name)
        XCTAssertEqual(measurements, ["orders"])
        let columns = try await driver.columns(in: "shop").map { "\($0.name) \($0.type)" }.sorted()
        XCTAssertEqual(columns, ["amount Float64", "store tag", "time Timestamp(ns)"])
        do {
            _ = try await driver.execute("SELECT nope FROM orders", limit: 1)
            XCTFail("a missing column read")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nope"), error.localizedDescription)
        }
        await driver.close()
    }
}
