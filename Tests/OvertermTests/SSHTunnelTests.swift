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

    override func tearDown() {
        SSHTunnel.knownHostsFile = nil
        SSHTunnel.testOptions = []
        SSHTunnel.closeAll()
    }

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

    // MARK: The ControlPath spike (docs/design/activity/analysis.md, 6.9)

    /// A listener of the test's own on 127.0.0.1 answering "pong" to each
    /// connection until closed; its port.
    private final class Pong: @unchecked Sendable {
        let fd: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            self.fd = fd
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
            }
            guard fd >= 0, bound, listen(fd, 8) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
            port = UInt16(bigEndian: address.sin_port)
            Thread.detachNewThread {
                while true {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    _ = "pong\n".withCString { write(client, $0, 5) }
                    Darwin.close(client)
                }
            }
        }

        /// A port nobody listens on.
        static func free() -> UInt16? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
            }
            return bound ? UInt16(bigEndian: address.sin_port) : nil
        }

        func close() {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    /// What a connection to 127.0.0.1:`port` reads, or nil.
    private static func read(_ port: UInt16) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else { return nil }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = Darwin.read(fd, &buffer, buffer.count)
        return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : nil
    }

    /// The tunnel's ssh with `ControlMaster=no` and a ControlPath nothing
    /// made — its argv sign — through a throwaway sshd: it connects as it
    /// would without one, says nothing about the path on stderr, and makes
    /// nothing there. This Mac's OpenSSH; macOS 13's isn't checked here.
    func testAControlPathNothingMadeIsQuietAndTheTunnelWorks() async throws {
        guard FakeSSHHost.isAvailable else { throw XCTSkip("no /usr/sbin/sshd") }
        let host = try FakeSSHHost.start()
        defer { host.stop() }
        let pong = try Pong()
        defer { pong.close() }
        SSHTunnel.testOptions = host.options
        var connection = DatabaseConnection(name: "Behind", kind: .postgres)
        connection.host = "127.0.0.1"
        connection.port = Int(pong.port)
        connection.sshEnabled = true
        connection.sshHost = "127.0.0.1"
        connection.sshPort = host.port
        connection.sshUser = NSUserName()
        let control = SSHTunnel.controlPath(for: connection.id)
        XCTAssertNotEqual(control, "none")

        // The ssh the tunnel runs, its stderr read whole.
        let local = try XCTUnwrap(Pong.free())
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = SSHTunnel.arguments(connection, localPort: local, batch: true)
        ssh.environment = SSHTunnel.environment(ProcessInfo.processInfo.environment)
        ssh.standardInput = FileHandle.nullDevice
        ssh.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        ssh.standardError = errors
        try ssh.run()
        var answer: String?
        let deadline = Date().addingTimeInterval(15)
        while answer == nil, ssh.isRunning, Date() < deadline {
            answer = Self.read(local)
            if answer == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        if ssh.isRunning { ssh.terminate() }
        // Bounded, never `waitUntilExit`: should another of the test
        // process's waits reap it first, Foundation never hears it ended.
        let gone = Date().addingTimeInterval(10)
        while ssh.isRunning, kill(ssh.processIdentifier, 0) == 0, Date() < gone { try await Task.sleep(nanoseconds: 50_000_000) }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(answer, "pong\n", "forwarded as without a ControlPath: \(said)")
        for word in ["control", "mux", (control as NSString).lastPathComponent] {
            XCTAssertFalse(said.lowercased().contains(word.lowercased()), "said nothing of the path: \(said)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: (control as NSString).deletingLastPathComponent), "nothing made there")

        // And the tunnel itself, the way the database opens it.
        let tunnel = try await SSHTunnel.open(connection, secret: nil)
        defer { tunnel.close() }
        XCTAssertEqual(Self.read(tunnel.localPort), "pong\n")
    }
}
