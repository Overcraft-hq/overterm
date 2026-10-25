import XCTest

@testable import Overterm

/// Saved connections: their file in Overterm's folder, their secrets never in it.
@MainActor
final class DatabaseStoreTests: XCTestCase {
    nonisolated(unsafe) private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("db-\(UUID().uuidString)/connections.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testConnectionsAreSavedAndTheirSecretsAreNot() throws {
        let secrets = MemoryDatabaseSecrets()
        let store = DatabaseStore(file: file, secrets: secrets)
        var pg = DatabaseConnection(name: "Prod", kind: .postgres)
        pg.host = "db.example.com"
        pg.user = "ada"
        pg.database = "shop"
        pg.sslMode = .require
        try store.save(pg, password: "s3cret-pw")
        var bq = DatabaseConnection(name: "Warehouse", kind: .bigquery)
        bq.project = "my-project"
        bq.bigQueryAuth = .serviceAccount
        try store.save(bq, serviceAccount: #"{"private_key": "KEY-MATERIAL"}"#)

        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(written.contains("s3cret-pw"), "a password in the file")
        XCTAssertFalse(written.contains("KEY-MATERIAL"), "a key in the file")
        XCTAssertEqual(secrets.value(.password, for: pg.id), "s3cret-pw")

        let reloaded = DatabaseStore(file: file, secrets: secrets)
        XCTAssertEqual(reloaded.connections, [pg, bq])
        XCTAssertEqual(reloaded.connections.first?.summary, "ada@db.example.com:5432/shop")

        try reloaded.delete(pg)
        XCTAssertNil(secrets.value(.password, for: pg.id), "a deleted connection's password goes too")
        XCTAssertEqual(DatabaseStore(file: file, secrets: secrets).connections.map(\.name), ["Warehouse"])
    }

    func testANewConnectionHasItsKindsDefaultsAndSaysWhatItLacks() {
        XCTAssertEqual(DatabaseConnection(name: "a", kind: .redshift).port, 5439)
        XCTAssertEqual(DatabaseConnection(name: "a", kind: .clickhouse).port, 8123)
        XCTAssertNil(DatabaseConnection(name: "a", kind: .sqlite).port)
        XCTAssertEqual(DatabaseConnection(name: "a", kind: .sqlite).problem, "Choose the database file.")
        XCTAssertEqual(DatabaseConnection(name: "a", kind: .bigquery).problem, "The project, please.")
        XCTAssertEqual(DatabaseConnection(name: " ", kind: .postgres).problem, "A name, please.")
        XCTAssertNil(DatabaseConnection(name: "a", kind: .postgres).problem)
    }
}
