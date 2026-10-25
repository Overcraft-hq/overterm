import XCTest

@testable import Overterm

/// The tunnel's ssh arguments, always; a real tunnel through the bastion of
/// Scripts/database-test-servers.sh to its PostgreSQL with OVERTERM_DB_TESTS=1.
final class SSHTunnelTests: XCTestCase {
    private var servers: Bool { ProcessInfo.processInfo.environment["OVERTERM_DB_TESTS"] == "1" }

    private func tunnelled() -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Behind", kind: .postgres)
        // The database as the bastion sees it.
        connection.host = "ot-pg"
        connection.port = 5432
        connection.user = "ot"
        connection.database = "shop"
        connection.sslMode = .disable
        connection.sshEnabled = true
        connection.sshHost = "127.0.0.1"
        connection.sshPort = 52222
        connection.sshUser = "tunnel"
        return connection
    }

    override func setUp() {
        // Never the user's known_hosts.
        SSHTunnel.knownHostsFile = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-known-hosts-\(UUID())").path
    }

    override func tearDown() { SSHTunnel.knownHostsFile = nil }

    func testTheArgumentsForwardALocalPortToTheDatabase() {
        SSHTunnel.knownHostsFile = nil
        var connection = tunnelled()
        connection.sshKeyFile = "~/.ssh/bastion"
        let arguments = SSHTunnel.arguments(connection, localPort: 61000, batch: true)
        XCTAssertTrue(arguments.contains("127.0.0.1:61000:ot-pg:5432"), "\(arguments)")
        XCTAssertEqual(arguments.last, "127.0.0.1")
        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-p")! + 1], "52222")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-l")! + 1], "tunnel")
        XCTAssertFalse(arguments.contains("~/.ssh/bastion"), "the key's path is expanded")
        // A default port says nothing; an IPv6 database is bracketed.
        connection.sshPort = 22
        connection.host = "fd00::5"
        let plain = SSHTunnel.arguments(connection, localPort: 61000, batch: false)
        XCTAssertFalse(plain.contains("-p"))
        XCTAssertTrue(plain.contains("127.0.0.1:61000:[fd00::5]:5432"))
        XCTAssertTrue(plain.contains("BatchMode=no"))
    }

    func testOnlyAServerDatabaseWithAHostUsesOne() {
        var connection = tunnelled()
        XCTAssertTrue(connection.usesTunnel)
        connection.sshHost = ""
        XCTAssertFalse(connection.usesTunnel)
        var sqlite = DatabaseConnection(name: "File", kind: .sqlite)
        sqlite.sshEnabled = true
        sqlite.sshHost = "bastion"
        XCTAssertFalse(sqlite.usesTunnel)
    }

    func testAConnectionKeepsItsTunnelAcrossASave() throws {
        let connection = tunnelled()
        let data = try JSONEncoder().encode(connection)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ot-pg") && text.contains("52222"))
        XCTAssertEqual(try JSONDecoder().decode(DatabaseConnection.self, from: data), connection)
    }

    func testPostgresThroughTheBastion() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        let (driver, tunnel) = try await DatabaseDrivers.open(tunnelled(), password: "otpass", serviceAccount: nil, sshSecret: "tunnelpass")
        defer { tunnel?.close() }
        XCTAssertNotNil(tunnel)
        try await driver.connect()
        let result = try await driver.execute("SELECT current_database() AS db, inet_server_port() AS port", limit: 1)
        XCTAssertEqual(result.rows, [["shop", "5432"]])
        await driver.close()
    }

    func testAWrongPasswordSaysWhatSSHSaid() async throws {
        guard servers else { throw XCTSkip("OVERTERM_DB_TESTS=1 with Scripts/database-test-servers.sh") }
        do {
            _ = try await SSHTunnel.open(tunnelled(), secret: "wrong")
            XCTFail("opened with a wrong password")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("SSH: "), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.lowercased().contains("denied"), error.localizedDescription)
        }
    }
}
