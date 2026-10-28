import Darwin
import Foundation

/// `ssh://[user@]host[:port]`, as `DOCKER_HOST` and a context spell a
/// remote engine. A path after the host names the engine's socket there
/// (the CLI asks the host's own `docker` for it). Pure.
struct DockerSSHTarget: Hashable, Sendable {
    var user: String?
    var host: String
    var port: Int?
    var socket: String?

    static func parse(_ url: String) -> DockerSSHTarget? {
        guard url.hasPrefix("ssh://") else { return nil }
        var rest = String(url.dropFirst("ssh://".count))
        var socket: String?
        if let slash = rest.firstIndex(of: "/") {
            let path = String(rest[slash...])
            if path != "/" { socket = path }
            rest = String(rest[..<slash])
        }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var host = rest
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...])
        }
        guard !host.isEmpty else { return nil }
        return DockerSSHTarget(user: user.flatMap { $0.isEmpty ? nil : $0 }, host: host, port: port, socket: socket)
    }

    /// As `DOCKER_HOST` spells it.
    var url: String {
        "ssh://" + (user.map { "\($0)@" } ?? "") + (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "") + (socket ?? "")
    }

    /// ssh's words for where to go, last on its command line.
    var destination: [String] {
        var words: [String] = []
        if let user { words += ["-l", user] }
        if let port, port != 22 { words += ["-p", "\(port)"] }
        return words + [host]
    }

    /// What the engine menu offers on the host — where the engine's
    /// settings and log are — run in a terminal tab, where ssh and sudo
    /// ask what they need.
    var commands: [(title: String, command: String)] {
        let ssh = (["ssh"] + destination).map(DockerCommands.quote).joined(separator: " ")
        let tty = (["ssh", "-t"] + destination).map(DockerCommands.quote).joined(separator: " ")
        return [
            ("Open a Shell on \(host)", ssh),
            ("Edit the Engine's Settings on \(host)", tty + " sudoedit /etc/docker/daemon.json"),
            ("Follow the Engine's Log on \(host)", tty + " journalctl -fu docker"),
        ]
    }
}

/// A remote engine, reached the way the Database client reaches a bastion:
/// the system's ssh, forwarding a socket on this Mac to the engine's on the
/// host (`-L local.sock:/var/run/docker.sock`). The transport talks to a
/// unix socket as it does to a local engine, and one ssh carries every
/// request and stream. The user's ~/.ssh/config, keys and agent do for it
/// what they do for `docker -H ssh://`; nothing is asked (BatchMode) — a
/// prompt nobody can answer would hang it.
final class DockerSSHForward: @unchecked Sendable {
    let target: DockerSSHTarget
    /// The local end: only this user may use it (the engine is root on the host).
    let socket: String
    private let process: Process
    private let said: Said

    private init(target: DockerSSHTarget, socket: String, process: Process, said: Said) {
        self.target = target
        self.socket = socket
        self.process = process
        self.said = said
    }

    var isOpen: Bool { process.isRunning }

    /// Why the host's end refused the last request, as ssh said it
    /// (`connect failed: Permission denied` — the user isn't in the docker
    /// group there): the local end takes the connection either way.
    var refusal: String? { Self.refusal(in: said.text) }

    static func refusal(in text: String) -> String? {
        let line = text.components(separatedBy: .newlines).last { $0.contains("open failed") }
        guard let line, let range = line.range(of: "open failed: ") else { return nil }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    func close() {
        if process.isRunning { process.terminate() }
        unlink(socket)
    }

    /// Tests keep their hosts and keys out of ~/.ssh: `-F`, `-i`,
    /// `UserKnownHostsFile`, before the destination.
    nonisolated(unsafe) static var testOptions: [String] = []

    static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    /// What every ssh here is told: its own connection (a ControlMaster in
    /// the user's config would make the forward a passing client), no
    /// prompts, a new host remembered as `ssh` asks a person to — a changed
    /// key is still refused.
    static func common() -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ] + testOptions
    }

    /// The forward's arguments — pure.
    static func arguments(_ target: DockerSSHTarget, localSocket: String, remoteSocket: String) -> [String] {
        ["-N", "-T"] + common() + [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            // A socket left by an ssh that died is replaced, not refused.
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "StreamLocalBindMask=0177",
            "-L", "\(localSocket):\(remoteSocket)",
        ] + target.destination
    }

    /// What asks the host's `docker` where its engine is — the context
    /// `docker system dial-stdio` would use, which is what the CLI runs there.
    static func socketQuery(_ target: DockerSSHTarget) -> [String] {
        ["-T"] + common() + target.destination + ["--", "docker context inspect --format '{{.Endpoints.docker.Host}}'"]
    }

    static let defaultRemoteSocket = "/var/run/docker.sock"

    /// The engine's socket from that answer; nil for anything not a unix socket.
    static func remoteSocket(fromOutput output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.hasPrefix("unix://"), line.count > "unix://".count else { return nil }
        return String(line.dropFirst("unix://".count))
    }

    /// The local end's path: short (a unix socket's path is 104 bytes at
    /// most), this process's own, one a host.
    static func localSocket(for target: DockerSSHTarget, folder: URL = FileManager.default.temporaryDirectory) -> String {
        let key = String(UInt64(bitPattern: Int64(target.url.hashValue)) % 0xFFFF_FFFF, radix: 16)
        return folder.appendingPathComponent("ot-docker-\(getpid())-\(key).sock").path
    }

    /// Where the engine's socket is on the host: the target's own path, else
    /// what its `docker` says, else the usual place. ssh's own failure (it
    /// exits 255: no route, refused key) is the answer — the forward would
    /// fail the same way, after another wait.
    static func remoteSocket(of target: DockerSSHTarget) async throws -> String {
        if let socket = target.socket { return socket }
        do {
            let output = try await Git.run(ssh, socketQuery(target), in: FileManager.default.homeDirectoryForCurrentUser, timeout: 25)
            return remoteSocket(fromOutput: output) ?? defaultRemoteSocket
        } catch let error as GitError where error.status == 255 {
            throw DockerError.unreachable("SSH: " + said(error.stderr, fallback: "\(target.host) didn't let Overterm in."))
        } catch let error as GitError where error.status > 0 {
            return defaultRemoteSocket
        }
    }

    /// Opens it, and returns once the local end takes connections — or
    /// throws what ssh said.
    static func open(_ target: DockerSSHTarget) async throws -> DockerSSHForward {
        let remote = try await remoteSocket(of: target)
        let local = localSocket(for: target)
        unlink(local)
        let process = Process()
        process.executableURL = ssh
        process.arguments = arguments(target, localSocket: local, remoteSocket: remote)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let said = Said()
        errors.fileHandleForReading.readabilityHandler = { handle in said.append(handle.availableData) }
        do {
            try process.run()
        } catch {
            throw DockerError.unreachable("ssh couldn't start: \(error.localizedDescription)")
        }
        let forward = DockerSSHForward(target: target, socket: local, process: process, said: said)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                forward.close()
                errors.fileHandleForReading.readabilityHandler = nil
                said.append(errors.fileHandleForReading.readDataToEndOfFile())
                throw DockerError.unreachable("SSH: " + Self.said(said.text, fallback: "ssh exited (\(process.terminationStatus))."))
            }
            if accepts(local) { return forward }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        forward.close()
        throw DockerError.unreachable("SSH: \(target.host) didn't open the forward in 20 seconds.")
    }

    /// The host's real name, as ~/.ssh/config makes it (`ssh -G`, which
    /// connects nowhere): where its published ports are. Nil when ssh
    /// can't say.
    static func hostName(of target: DockerSSHTarget) async -> String? {
        let arguments = ["-G"] + testOptions + target.destination
        guard let output = try? await Git.run(ssh, arguments, in: FileManager.default.homeDirectoryForCurrentUser, timeout: 5) else { return nil }
        return hostName(fromConfig: output)
    }

    static func hostName(fromConfig output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("hostname ") {
            let name = line.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// ssh's last word, its notices left out. ssh ends its lines with \r\n
    /// — one Character, so never split on "\n".
    private static func said(_ text: String, fallback: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last ?? fallback
    }

    private static func accepts(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
    }

    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// One forward a host, opened by the first request and again when its ssh
/// has gone (the network changed, the Mac slept); requests that arrive
/// while it opens wait for that one.
actor DockerSSHForwards {
    static let shared = DockerSSHForwards()

    private var forwards: [DockerSSHTarget: DockerSSHForward] = [:]
    private var opening: [DockerSSHTarget: Task<DockerSSHForward, Error>] = [:]

    /// Every forward, for closing when the app quits — or each ssh would
    /// outlive it.
    nonisolated(unsafe) private static var all: [DockerSSHForward] = []
    private static let lock = NSLock()

    func socket(for target: DockerSSHTarget) async throws -> String {
        if let forward = forwards[target], forward.isOpen { return forward.socket }
        forwards[target]?.close()
        forwards[target] = nil
        let task =
            opening[target]
            ?? Task {
                let forward = try await DockerSSHForward.open(target)
                Self.lock.withLock { Self.all = Self.all.filter(\.isOpen) + [forward] }
                return forward
            }
        opening[target] = task
        defer { opening[target] = nil }
        let forward = try await task.value
        forwards[target] = forward
        return forward.socket
    }

    /// Closes the forward to `target`, when it is no longer the engine.
    func close(_ target: DockerSSHTarget) {
        forwards.removeValue(forKey: target)?.close()
    }

    func refusal(_ target: DockerSSHTarget) -> String? { forwards[target]?.refusal }

    static func closeAll() {
        let forwards = lock.withLock {
            defer { all = [] }
            return all
        }
        forwards.forEach { $0.close() }
    }
}
