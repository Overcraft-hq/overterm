import Darwin
import Foundation

/// A database behind a bastion: the system's ssh forwarding a local port
/// to it (`ssh -N -L`), so whatever the user's ~/.ssh/config, keys and
/// agent already do for that host works here too. The driver connects to
/// the local end; TLS still checks the database's own name
/// (`DatabaseConnection.serverName`).
///
/// A password or a key's passphrase comes from the keychain and reaches
/// ssh through SSH_ASKPASS — a script that prints an environment variable
/// set for that one process; nothing secret is written to disk. Without
/// one, ssh may not ask at all (BatchMode): a prompt nobody can answer
/// would hang the connection.
final class SSHTunnel: @unchecked Sendable {
    let localPort: UInt16
    private let process: Process

    private init(process: Process, localPort: UInt16) {
        self.process = process
        self.localPort = localPort
    }

    /// Every tunnel still open: closed when the app quits, or each ssh
    /// would outlive it.
    nonisolated(unsafe) private static var open: [ObjectIdentifier: SSHTunnel] = [:]
    private static let lock = NSLock()

    static func closeAll() {
        let tunnels = lock.withLock { Array(open.values) }
        tunnels.forEach { $0.close() }
    }

    func close() {
        _ = Self.lock.withLock { Self.open.removeValue(forKey: ObjectIdentifier(self)) }
        if process.isRunning { process.terminate() }
    }

    /// Tests keep their hosts out of the user's ~/.ssh/known_hosts.
    nonisolated(unsafe) static var knownHostsFile: String?

    /// The arguments for a tunnel to `connection` from `localPort` — pure.
    static func arguments(_ connection: DatabaseConnection, localPort: UInt16, batch: Bool) -> [String] {
        let target = connection.host.contains(":") ? "[\(connection.host)]" : connection.host
        var arguments = [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            // A host seen for the first time is remembered, as `ssh` asks a
            // person to; a changed key is still refused.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=\(batch ? "yes" : "no")",
            "-L", "127.0.0.1:\(localPort):\(target):\(connection.port ?? connection.kind.defaultPort ?? 0)",
        ]
        if let knownHostsFile { arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile)"] }
        if let port = connection.sshPort, port != 22 { arguments += ["-p", "\(port)"] }
        if !connection.sshKeyFile.isEmpty { arguments += ["-i", (connection.sshKeyFile as NSString).expandingTildeInPath] }
        if !connection.sshUser.isEmpty { arguments += ["-l", connection.sshUser] }
        arguments.append(connection.sshHost)
        return arguments
    }

    /// Opens it, and returns once the local end takes connections — or
    /// throws what ssh said.
    static func open(_ connection: DatabaseConnection, secret: String?) async throws -> SSHTunnel {
        let port = try freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(connection, localPort: port, batch: secret == nil)
        var environment = ProcessInfo.processInfo.environment
        if let secret {
            environment["SSH_ASKPASS"] = try askpass().path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = environment["DISPLAY"] ?? ":0"
            environment["OVERTERM_SSH_SECRET"] = secret
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let said = Said()
        errors.fileHandleForReading.readabilityHandler = { handle in said.append(handle.availableData) }
        do {
            try process.run()
        } catch {
            throw DatabaseError.failed("ssh couldn't start: \(error.localizedDescription)")
        }
        let tunnel = SSHTunnel(process: process, localPort: port)
        lock.withLock { open[ObjectIdentifier(tunnel)] = tunnel }
        // Ready when the local end answers; ssh binds it only once it is in.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                tunnel.close()
                // What it said last may not have been read yet.
                errors.fileHandleForReading.readabilityHandler = nil
                said.append(errors.fileHandleForReading.readDataToEndOfFile())
                // ssh ends its lines with \r\n — one Character, so never split on "\n".
                let text = said.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
                throw DatabaseError.failed("SSH: " + (text.last ?? "ssh exited (\(process.terminationStatus))."))
            }
            if accepts(port) { return tunnel }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        tunnel.close()
        throw DatabaseError.failed("SSH: \(connection.sshHost) didn't open the tunnel in 20 seconds.")
    }

    /// A port nobody is listening on, from the system.
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError.failed("No local port for the tunnel.") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw DatabaseError.failed("No local port for the tunnel.") }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func accepts(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// The askpass script: it prints the variable, and holds no secret
    /// itself. In this user's temporary folder (only they can read it),
    /// written again whenever it has been cleared away.
    private static func askpass() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppEnvironment.bundleIdentifier).ssh-askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$OVERTERM_SSH_SECRET\"\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

extension DatabaseDrivers {
    /// A driver for `connection`, through its SSH tunnel when it has one —
    /// the driver aimed at the tunnel's local end, TLS at the real name.
    static func open(
        _ connection: DatabaseConnection, password: String?, serviceAccount: String?, sshSecret: String?
    ) async throws -> (driver: any DatabaseDriver, tunnel: SSHTunnel?) {
        guard connection.usesTunnel else {
            return (make(connection, password: password, serviceAccount: serviceAccount), nil)
        }
        let tunnel = try await SSHTunnel.open(connection, secret: sshSecret)
        var local = connection
        local.serverName = connection.host
        local.host = "127.0.0.1"
        local.port = Int(tunnel.localPort)
        return (make(local, password: password, serviceAccount: serviceAccount), tunnel)
    }
}
