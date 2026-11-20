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
    /// The connection's name: what Activity's Listening calls its port.
    let name: String
    /// The connection's id: what Activity's Disconnect closes — names
    /// aren't unique, and a rename leaves an open tunnel's as it was.
    let connection: UUID
    private let process: Process

    private init(process: Process, localPort: UInt16, name: String, connection: UUID) {
        self.process = process
        self.localPort = localPort
        self.name = name
        self.connection = connection
    }

    /// The tunnels open now — ssh's pid, its local port, the connection's
    /// name and id: their ports' owner on Activity's Listening (docs/design/
    /// activity/analysis.md, 6.8 rule 4).
    static func listed() -> [(pid: pid_t, port: UInt16, name: String, connection: UUID)] {
        lock.withLock { Array(open.values) }.compactMap { tunnel in
            tunnel.process.isRunning ? (tunnel.process.processIdentifier, tunnel.localPort, tunnel.name, tunnel.connection) : nil
        }
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
    /// Tests keep their hosts and keys out of ~/.ssh: `-F`, `-i`, before
    /// the destination (`FakeSSHHost.options`).
    nonisolated(unsafe) static var testOptions: [String] = []
    /// The ssh it runs: a test's stand-in, to see what it was started with.
    nonisolated(unsafe) static var executable = URL(fileURLWithPath: "/usr/bin/ssh")

    /// The ControlPath its ssh is given: `<user temp>/ot-run-<pid>-<start36>/db-<id>`,
    /// a path nothing creates. With `ControlMaster=no`, ssh only tries it as
    /// a client of a master, finds none (ENOENT, said nowhere) and connects
    /// itself — and a ControlMaster in the user's config can't make the
    /// tunnel a passing client of another connection. Its argv names the
    /// run that started it (`ArgvSign.databaseTunnel`): `/usr/bin/ssh`
    /// hides its environment.
    ///
    /// ssh doesn't check who made a master's socket, and the path is built
    /// from a pid and a start anyone can read: so its folder is the
    /// system's own temporary folder for this user
    /// (`userTemporaryDirectory`, never `$TMPDIR`, which a shell or
    /// launchctl can point at /tmp), and only while that is a directory of
    /// this user's that no one else can write (`isPrivateFolder`) — else
    /// `none`, as where it wouldn't fit a unix socket's 104 bytes (ssh
    /// refuses a longer one) or holds a character ssh expands.
    static func controlPath(
        for connection: UUID, run: ActivityProcessID = OvertermRun.current.identity, folder: URL? = userTemporaryDirectory
    ) -> String {
        guard let folder, isPrivateFolder(folder.path) else { return "none" }
        let id = String(connection.uuidString.lowercased().prefix(8))
        let path = folder.appendingPathComponent(ArgvSign.runFolder(run: run), isDirectory: true).appendingPathComponent("db-\(id)").path
        guard path.utf8.count < 104, path.hasPrefix("/"), !path.contains("%"), !path.contains(" ") else { return "none" }
        return path
    }

    /// This user's temporary folder as the system keeps it
    /// (`_CS_DARWIN_USER_TEMP_DIR`, under /var/folders, 0700): what
    /// `$TMPDIR` normally says, whatever the app inherited instead.
    static let userTemporaryDirectory: URL? = {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard length > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 1 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }()

    /// Whether `path` is a directory — itself, not a link — owned by this
    /// user and writable by no one else: where no other user can put a
    /// socket (a sticky /tmp is refused too).
    static func isPrivateFolder(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

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
            // Its own connection, and its run named in its argv (`controlPath`).
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath(for: connection.id))",
            "-L", "127.0.0.1:\(localPort):\(target):\(connection.port ?? connection.kind.defaultPort ?? 0)",
        ]
        if let knownHostsFile { arguments += ["-o", "UserKnownHostsFile=\(knownHostsFile)"] }
        if let port = connection.sshPort, port != 22 { arguments += ["-p", "\(port)"] }
        if !connection.sshKeyFile.isEmpty { arguments += ["-i", (connection.sshKeyFile as NSString).expandingTildeInPath] }
        if !connection.sshUser.isEmpty { arguments += ["-l", connection.sshUser] }
        arguments += testOptions
        arguments.append(connection.sshHost)
        return arguments
    }

    /// What its ssh is given before a secret: the app's environment, marked
    /// as this run's (D-15) — unseen while it runs, `/usr/bin/ssh` being a
    /// platform binary: its `ControlPath` says the run (`controlPath`).
    static func environment(_ inherited: [String: String]) -> [String: String] {
        OvertermRun.current.marking(inherited, helper: .databaseTunnel)
    }

    /// Opens it, and returns once the local end takes connections — or
    /// throws what ssh said.
    static func open(_ connection: DatabaseConnection, secret: String?) async throws -> SSHTunnel {
        let port = try freePort()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(connection, localPort: port, batch: secret == nil)
        var environment = Self.environment(ProcessInfo.processInfo.environment)
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
        let tunnel = SSHTunnel(process: process, localPort: port, name: connection.name, connection: connection.id)
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
