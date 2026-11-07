import Darwin
import Foundation

/// A long-lived child process Overterm starts and owns — an ssh forwarding a
/// remote engine's socket, and later `kubectl proxy` and `kubectl
/// port-forward`: started, waited for until it is ready (a socket that
/// takes connections, or a line on its stdout), its stderr kept for the
/// reason it failed, closed on demand and at quit (`closeAll`). It is only
/// ever signalled by its own pid, and what it started by theirs (found
/// before it is closed, by pid and start time) — never by a pattern
/// (`pkill -f` once killed the shell running the tests).
final class ManagedProcess: @unchecked Sendable {
    /// What says it is ready.
    enum Readiness: Sendable {
        /// A unix socket at this path takes a connection.
        case socket(String)
        /// A line on its stdout says so (`Starting to serve on …`).
        case line(@Sendable (String) -> Bool)
    }

    struct Launch: Sendable {
        var executable: URL
        var arguments: [String]
        /// Nil: this process's own.
        var environment: [String: String]? = nil
        var directory: URL? = nil
        var readiness: Readiness
        /// How long it may take to become ready.
        var timeout: TimeInterval = 20
        /// Files it makes (its socket): removed before it starts — one left
        /// by a process that died is no use — and when it is closed.
        var removing: [String] = []
    }

    enum Failure: Error, Equatable {
        /// It couldn't be started at all (no such executable).
        case couldNotStart(String)
        /// It exited before it was ready: its status, and what it said on stderr.
        case exited(status: Int32, stderr: String)
        /// Still not ready when the timeout passed; it is closed.
        case timedOut
    }

    private let process: Process
    private let removing: [String]
    /// What it said on stderr, and on stdout when a line says it is ready.
    let stderr: Output
    let stdout: Output

    private init(process: Process, removing: [String], stderr: Output, stdout: Output) {
        self.process = process
        self.removing = removing
        self.stderr = stderr
        self.stdout = stdout
    }

    var isRunning: Bool { process.isRunning }
    var pid: pid_t { process.processIdentifier }
    var terminationStatus: Int32 { process.terminationStatus }

    /// Ends it — SIGTERM to its own pid, and to what it started (an exec
    /// plugin kubectl ran: kubelogin waiting for the browser on 127.0.0.1:8000
    /// would otherwise keep the port and the sign-in for minutes) — then
    /// SIGKILL to those still there after `grace`, and removes what it made.
    /// Its children are found before it is signalled (once it exits they
    /// are launchd's), each by pid and start time: never a pid reused.
    func close() { close(grace: 2) }

    func close(grace: TimeInterval) {
        if process.isRunning {
            let family = Self.descendants(of: process.processIdentifier)
            process.terminate()
            for child in family { kill(child.pid, SIGTERM) }
            if !family.isEmpty, grace > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: Self.killing(family))
            }
        }
        removing.forEach { unlink($0) }
        Self.lock.withLock { Self.live.removeAll { $0 === self } }
    }

    /// Every process under `pid` — its children and theirs, bounded —
    /// each with its start time (µs).
    static func descendants(of pid: pid_t, limit: Int = 64) -> [(pid: pid_t, start: UInt64)] {
        var found: [(pid: pid_t, start: UInt64)] = []
        var queue = [pid]
        var seen: Set<pid_t> = [pid]
        while let parent = queue.first, found.count < limit {
            queue.removeFirst()
            for child in ProcessInspector.children(of: parent) where seen.insert(child.pid).inserted {
                found.append((child.pid, child.start))
                queue.append(child.pid)
                if found.count >= limit { break }
            }
        }
        return found
    }

    /// SIGKILL to each still running as the same process (its start time).
    private nonisolated static func killing(_ family: [(pid: pid_t, start: UInt64)]) -> @Sendable () -> Void {
        let family = family.map { ($0.pid, $0.start) }
        return {
            for (pid, start) in family where ProcessInspector.kinfo(pid)?.start == start { kill(pid, SIGKILL) }
        }
    }

    /// Starts it, and returns once it is ready — or throws why not, having
    /// closed it: cancelled while it waits, it is closed at once and
    /// `CancellationError` thrown.
    static func start(_ launch: Launch) async throws -> ManagedProcess {
        launch.removing.forEach { unlink($0) }
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        if let environment = launch.environment { process.environment = environment }
        if let directory = launch.directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let stderr = Output()
        let stdout = Output()
        let errors = Pipe()
        process.standardError = errors
        read(errors, into: stderr)
        var output: Pipe?
        if case .line = launch.readiness {
            // Read for as long as it runs: a pipe nobody empties fills, and
            // the process blocks writing to it.
            let pipe = Pipe()
            process.standardOutput = pipe
            read(pipe, into: stdout)
            output = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            output?.fileHandleForReading.readabilityHandler = nil
            throw Failure.couldNotStart(error.localizedDescription)
        }
        let managed = ManagedProcess(process: process, removing: launch.removing, stderr: stderr, stdout: stdout)
        lock.withLock { live = live.filter(\.isRunning) + [managed] }
        let deadline = Date().addingTimeInterval(launch.timeout)
        while Date() < deadline {
            // Whoever waits gave up (a forward stopped or edited while it
            // starts): closed now, or it holds its port and its sign-in
            // until it is ready or the timeout passes, with nobody to close it.
            if Task.isCancelled {
                managed.close()
                throw CancellationError()
            }
            if !process.isRunning {
                managed.close()
                // What it said, from the handler: never readDataToEndOfFile,
                // which waits for every writer — a ProxyCommand that
                // outlives ssh held a cooperative thread for good.
                for _ in 0..<10 where !stderr.finished { try? await Task.sleep(nanoseconds: 50_000_000) }
                errors.fileHandleForReading.readabilityHandler = nil
                output?.fileHandleForReading.readabilityHandler = nil
                throw Failure.exited(status: process.terminationStatus, stderr: stderr.text)
            }
            if isReady(launch.readiness, stdout: stdout) { return managed }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        managed.close()
        throw Failure.timedOut
    }

    static func isReady(_ readiness: Readiness, stdout: Output) -> Bool {
        switch readiness {
        case .socket(let path): accepts(path)
        case .line(let says): stdout.text.components(separatedBy: .newlines).contains(where: says)
        }
    }

    /// Cleared at EOF: a handler left on fires again and again with
    /// nothing, a core spinning for the life of the app (once per reopened
    /// process), as Git.run and DockerCLI already know. Built here, outside
    /// any actor: the handler runs on the pipe's own queue.
    nonisolated private static func read(_ pipe: Pipe, into output: Output) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.append(data)
            }
        }
    }

    /// Whether a unix socket at `path` takes a connection.
    static func accepts(_ path: String) -> Bool {
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

    // MARK: Every one, for quitting

    /// Every process started and not yet closed — or each would outlive the app.
    nonisolated(unsafe) private static var live: [ManagedProcess] = []
    private static let lock = NSLock()

    /// Closes every one; at quit.
    static func closeAll() {
        let all = lock.withLock {
            defer { live = [] }
            return live
        }
        // At quit nothing waits for a grace: SIGTERM to each and its children.
        all.forEach { $0.close(grace: 0) }
    }

    /// The pids of those running, for tests.
    static var livePIDs: [pid_t] { lock.withLock { live.filter(\.isRunning).map(\.pid) } }

    /// What it said on a stream — its last 16 KB: a process lives as long
    /// as the app, and ssh adds a line for every refused connection.
    final class Output: @unchecked Sendable {
        static let limit = 16 << 10
        private let lock = NSLock()
        private var data = Data()
        private var ended = false
        func append(_ more: Data) {
            lock.withLock {
                data.append(more)
                if data.count > Self.limit { data = Data(data.suffix(Self.limit)) }
            }
        }
        func finish() { lock.withLock { ended = true } }
        var finished: Bool { lock.withLock { ended } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// What a pool keeps: something over a managed process.
protocol ManagedResource: AnyObject, Sendable {
    var isOpen: Bool { get }
    func close()
}

/// One process a key (a host, a context), opened by the first use and again
/// on the next use after it has gone (the network changed, the Mac slept);
/// uses that arrive while it opens wait for that one.
actor ManagedProcessPool<Key: Hashable & Sendable, Value: ManagedResource> {
    private let open: @Sendable (Key) async throws -> Value
    private var values: [Key: Value] = [:]
    private var opening: [Key: Task<Value, Error>] = [:]
    /// Every one opened, for `closeAll` from outside the actor.
    private let all = Opened()

    init(open: @escaping @Sendable (Key) async throws -> Value) {
        self.open = open
    }

    /// The open one for `key`, opened now if there is none.
    func value(for key: Key) async throws -> Value {
        if let value = values[key], value.isOpen { return value }
        values[key]?.close()
        values[key] = nil
        let open = self.open
        let all = self.all
        let task =
            opening[key]
            ?? Task {
                let value = try await open(key)
                all.add(value)
                return value
            }
        opening[key] = task
        defer { opening[key] = nil }
        let value = try await task.value
        values[key] = value
        return value
    }

    /// The one for `key` if it was opened, open or not.
    func existing(_ key: Key) -> Value? { values[key] }

    /// Closes the one for `key`, when it is no longer wanted.
    func close(_ key: Key) {
        values.removeValue(forKey: key)?.close()
    }

    /// Closes every one this pool opened.
    nonisolated func closeAll() { all.closeAll() }

    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Value] = []
        func add(_ value: Value) { lock.withLock { values = values.filter(\.isOpen) + [value] } }
        func closeAll() {
            let values = lock.withLock {
                defer { self.values = [] }
                return self.values
            }
            values.forEach { $0.close() }
        }
    }
}
