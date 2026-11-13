import Foundation

/// A redis-server of the tests' own: on a free port, nothing saved to disk,
/// in a folder of its own — never the user's server. TLS (rediss) when
/// asked, with a certificate made for it. Nil when this Mac has no
/// redis-server (CI): the tests that need one skip.
final class E2ERedisServer: @unchecked Sendable {
    let port: Int
    let password: String
    let folder: URL
    let tls: Bool
    private let process: Process

    static var executable: String? {
        let paths =
            ["/opt/homebrew/bin/redis-server", "/usr/local/bin/redis-server"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/redis-server" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    init?(password: String = "otpass", tls: Bool = false) {
        guard let executable = Self.executable, let port = Self.freePort() else { return nil }
        self.port = port
        self.password = password
        self.tls = tls
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-redis-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var arguments = ["--save", "", "--appendonly", "no", "--dir", folder.path, "--bind", "127.0.0.1", "--daemonize", "no", "--loglevel", "warning"]
        if !password.isEmpty { arguments += ["--requirepass", password] }
        if tls {
            let cert = folder.appendingPathComponent("cert.pem").path
            let key = folder.appendingPathComponent("key.pem").path
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            openssl.arguments = [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", key, "-out", cert,
            ]
            openssl.standardOutput = FileHandle.nullDevice
            openssl.standardError = FileHandle.nullDevice
            guard (try? openssl.run()) != nil else { return nil }
            openssl.waitUntilExit()
            arguments += ["--port", "0", "--tls-port", String(port), "--tls-cert-file", cert, "--tls-key-file", key, "--tls-auth-clients", "no"]
        } else {
            arguments += ["--port", String(port)]
        }
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Ready when the port takes a connection.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !Self.listening(port) { usleep(50_000) }
        guard Self.listening(port) else {
            stop()
            return nil
        }
    }

    /// A connection to it, as the form would save one.
    func connection(name: String = "Cache", database: String = "") -> DatabaseConnection {
        var connection = DatabaseConnection(name: name, kind: .redis)
        connection.host = "127.0.0.1"
        connection.port = port
        connection.database = database
        connection.sslMode = tls ? .require : .disable
        return connection
    }

    func stop() {
        // Its own pid, never a pattern.
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: folder)
    }

    deinit { stop() }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    private static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
