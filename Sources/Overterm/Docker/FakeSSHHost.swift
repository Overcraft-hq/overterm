import Foundation

/// A throwaway sshd for this user on 127.0.0.1 — its own host key, the one
/// client key it lets in, nothing of ~/.ssh — through which the tests and
/// the docker scenario reach the fake engine as a remote one
/// (`ssh://127.0.0.1:port/path/to/fake.sock`). Its folder is short: the
/// sockets beside it must stay under 104 bytes.
final class FakeSSHHost {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    let port: Int
    let folder: URL
    private let process: Process

    private init(port: Int, folder: URL, process: Process) {
        self.port = port
        self.folder = folder
        self.process = process
    }

    /// What `DockerSSHForward.testOptions` is set to while it runs: its key
    /// alone (no agent, no ~/.ssh/config), its own known_hosts.
    var options: [String] {
        [
            "-F", "/dev/null", "-i", folder.appendingPathComponent("client").path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
            "-o", "UserKnownHostsFile=\(folder.path)/known_hosts",
        ]
    }

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") }

    /// Started, listening; throws `Unavailable` where it can't be.
    static func start() throws -> FakeSSHHost {
        guard isAvailable else { throw Unavailable(description: "no /usr/sbin/sshd") }
        let folder = URL(fileURLWithPath: "/tmp/ot-sshd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for key in ["host", "client"] {
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", folder.appendingPathComponent(key).path]
            keygen.standardOutput = FileHandle.nullDevice
            try keygen.run()
            keygen.waitUntilExit()
        }
        try FileManager.default.copyItem(at: folder.appendingPathComponent("client.pub"), to: folder.appendingPathComponent("authorized_keys"))
        var said = ""
        // A port someone else has: another one.
        for _ in 0..<3 {
            let port = Int.random(in: 52300...52999)
            let config = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(folder.path)/host
                AuthorizedKeysFile \(folder.path)/authorized_keys
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                UsePAM no
                StrictModes no
                AllowStreamLocalForwarding yes
                PidFile none
                """
            try config.write(to: folder.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
            let log = folder.appendingPathComponent("sshd-\(port).log")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-f", folder.appendingPathComponent("sshd_config").path, "-E", log.path]
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, process.isRunning {
                if (try? String(contentsOf: log, encoding: .utf8))?.contains("Server listening") == true {
                    return FakeSSHHost(port: port, folder: folder, process: process)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
            said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        }
        try? FileManager.default.removeItem(at: folder)
        throw Unavailable(description: "sshd didn't start: \(said)")
    }

    /// From now on, no key gets in.
    func refuseEveryone() throws {
        try Data().write(to: folder.appendingPathComponent("authorized_keys"))
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
