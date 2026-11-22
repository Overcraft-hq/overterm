import Darwin
import Foundation

/// A long-lived child process Overterm starts and owns — an ssh forwarding a
/// remote engine's socket, and later `kubectl proxy` and `kubectl
/// port-forward`: started, waited for until it is ready (a socket that
/// takes connections, or a line on its stdout), its stderr kept for the
/// reason it failed, closed on demand and at quit (`closeAll`). It runs in
/// a process group of its own (`ProcessGroup`), and is only ever signalled
/// by that group — whatever it started, even reparented — and what it
/// started by their own pids (found before it is closed, by pid and start
/// time: one that left the group); never by a pattern (`pkill -f` once
/// killed the shell running the tests).
package final class ManagedProcess: @unchecked Sendable {
    /// What says it is ready.
    package enum Readiness: Sendable {
        /// A unix socket at this path takes a connection.
        case socket(String)
        /// A line on its stdout says so (`Starting to serve on …`).
        case line(@Sendable (String) -> Bool)
    }

    package struct Launch: Sendable {
        package var executable: URL
        package var arguments: [String]
        /// Nil: this process's own.
        package var environment: [String: String]? = nil
        package var directory: URL? = nil
        package var readiness: Readiness
        /// How long it may take to become ready.
        package var timeout: TimeInterval = 20
        /// Files it makes (its socket): removed before it starts — one left
        /// by a process that died is no use — and when it is closed.
        package var removing: [String] = []
        /// Which of Overterm's children it is: `OVERTERM_HELPER`, beside the
        /// run's `OVERTERM_RUN` (docs/design/activity/analysis.md, D-15).
        package var helper: OvertermRun.Helper = .managed

        /// The environment it is started with: the launch's, or this
        /// process's, marked as this run's `helper`.
        package var markedEnvironment: [String: String] {
            OvertermRun.current.marking(environment ?? ProcessInfo.processInfo.environment, helper: helper)
        }
    }

    package enum Failure: Error, Equatable {
        /// It couldn't be started at all (no such executable).
        case couldNotStart(String)
        /// It exited before it was ready: its status, and what it said on stderr.
        case exited(status: Int32, stderr: String)
        /// Still not ready when the timeout passed; it is closed.
        case timedOut
    }

    private let process: ProcessGroup.Child
    /// Its start time: its group is signalled after the grace only while
    /// it, or one of what it started, is still that process.
    private let started: UInt64?
    private let removing: [String]
    /// Its stderr's and stdout's pipes, held for as long as it is: a pipe
    /// let go closes its read end, and what it said after is never read
    /// (`Process` held them before).
    private let pipes: [Pipe]
    /// What it said on stderr, and on stdout when a line says it is ready.
    package let stderr: Output
    package let stdout: Output

    private init(process: ProcessGroup.Child, removing: [String], pipes: [Pipe], stderr: Output, stdout: Output) {
        self.process = process
        self.pipes = pipes
        self.started = ProcessInspector.kinfo(process.pid)?.start
        self.removing = removing
        self.stderr = stderr
        self.stdout = stdout
    }

    package var isRunning: Bool { process.isRunning }
    package var pid: pid_t { process.pid }
    package var terminationStatus: Int32 { process.terminationStatus }

    /// Ends it — SIGTERM to its process group, and to what it started that
    /// left it (an exec plugin kubectl ran: kubelogin waiting for the
    /// browser on 127.0.0.1:8000 would otherwise keep the port and the
    /// sign-in for minutes) — then SIGKILL to those still there after
    /// `grace`, and removes what it made. The group reaches one reparented
    /// once kubectl exited, and one started a moment before the signal;
    /// its children are found before it is signalled, each by pid and
    /// start time: never a pid reused.
    ///
    /// It is no longer open once this returns (its files gone, out of
    /// `openGroups`); the finding and the signals follow on a queue of
    /// their own, in the order closes came (`closing`): finding its family
    /// reads the process table, and `KubeForwards.end` closes a forward on
    /// the main thread (docs/design/activity/analysis.md, 2.4 item 3).
    /// `closeAll` waits for them.
    package func close() { close(grace: 2) }

    /// `table`: how the family's table is read — on `closing`, never the
    /// caller's thread; the tests' records where it ran.
    package func close(grace: TimeInterval, table: @escaping @Sendable () -> ProcessTable? = { ProcessTable.read(LiveActivityKernel()) }) {
        let process = self.process
        let started = self.started
        Self.closing.async(execute: Self.ending(process, started: started, grace: grace, table: table))
        removing.forEach { unlink($0) }
        Self.lock.withLock { Self.live.removeAll { $0 === self } }
    }

    /// Where closes find their families and signal them, one after another
    /// (a test holds it to see a close return before its work runs).
    package static let closing = DispatchQueue(label: "\(AppEnvironment.bundleIdentifier).managed-process-close", qos: .userInitiated)

    /// The close's work, for `closing`: the family found — its group's
    /// leader by its start, what it started from one read of the process
    /// table — then SIGTERM, and SIGKILL after `grace`.
    private nonisolated static func ending(
        _ process: ProcessGroup.Child, started: UInt64?, grace: TimeInterval, table: @escaping @Sendable () -> ProcessTable?
    ) -> @Sendable () -> Void {
        {
            let group = process.pid
            let leader = started.map { [(pid: group, start: $0)] } ?? []
            let family = leader + (table().map { descendants(of: group, in: $0) } ?? [])
            // Its group even once it exited: what it started may still be there.
            if groupIsOurs(process) { killpg(group, SIGTERM) }
            for child in family.dropFirst(leader.count) { kill(child.pid, SIGTERM) }
            if grace > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: killing(process, family))
            }
        }
    }

    /// Every process under `pid` — its children and theirs, bounded —
    /// each with its start time (µs): the census's child map (7.8), of one
    /// table read now, where each node was a read of its own (16 ms a node
    /// as a walk of every pid). Now, not a tick old: a close counts on what
    /// has just started. Blocking: never the main thread.
    package static func descendants(of pid: pid_t, limit: Int = 64) -> [(pid: pid_t, start: UInt64)] {
        guard let table = ProcessTable.read(LiveActivityKernel()) else { return [] }
        return descendants(of: pid, limit: limit, in: table)
    }

    /// The same, from `table`: whatever holds `pid` there, then everything
    /// below it, parents linked by start time; a zombie left out. Pure.
    package static func descendants(of pid: pid_t, limit: Int = 64, in table: ProcessTable) -> [(pid: pid_t, start: UInt64)] {
        guard let root = table.process(pid: pid) else { return [] }
        let live = table.descendants(of: root.identity).filter { !$0.isZombie }.prefix(max(limit, 0))
        return live.map { (pid: $0.pid, start: $0.identity.start) }
    }

    /// Whether its group's id is still its group's: the leader not yet
    /// reaped (its pid can't be reused), or no process with that pid — a
    /// pid isn't given out while a group of that id has a member, so a
    /// process there now is another's group leader, never signalled.
    private nonisolated static func groupIsOurs(_ leader: ProcessGroup.Child) -> Bool {
        leader.isRunning || ProcessInspector.kinfo(leader.pid) == nil
    }

    /// SIGKILL to each still running as the same process (its start time),
    /// and to the group while it is still its (`groupIsOurs`).
    private nonisolated static func killing(_ leader: ProcessGroup.Child, _ family: [(pid: pid_t, start: UInt64)]) -> @Sendable () -> Void {
        let family = family.map { ($0.pid, $0.start) }
        return {
            let alive = family.filter { ProcessInspector.kinfo($0.0)?.start == $0.1 }
            if groupIsOurs(leader) { killpg(leader.pid, SIGKILL) }
            for (pid, _) in alive { kill(pid, SIGKILL) }
        }
    }

    /// Starts it, and returns once it is ready — or throws why not, having
    /// closed it: cancelled while it waits, it is closed at once and
    /// `CancellationError` thrown.
    package static func start(_ launch: Launch) async throws -> ManagedProcess {
        launch.removing.forEach { unlink($0) }
        let stderr = Output()
        let stdout = Output()
        let errors = Pipe()
        read(errors, into: stderr)
        var output: Pipe?
        if case .line = launch.readiness {
            // Read for as long as it runs: a pipe nobody empties fills, and
            // the process blocks writing to it.
            let pipe = Pipe()
            read(pipe, into: stdout)
            output = pipe
        }
        let null = open("/dev/null", O_WRONLY)
        defer { if null >= 0 { Darwin.close(null) } }
        let spawned = ProcessGroup.spawn(
            launch.executable, launch.arguments, launch.markedEnvironment, directory: launch.directory,
            stdout: output?.fileHandleForWriting.fileDescriptor ?? null, stderr: errors.fileHandleForWriting.fileDescriptor)
        // The child has its own: ours closed, or the readers never see EOF.
        try? errors.fileHandleForWriting.close()
        try? output?.fileHandleForWriting.close()
        let process: ProcessGroup.Child
        switch spawned {
        case .success(let pid): process = ProcessGroup.Child(pid: pid)
        case .failure(let error):
            errors.fileHandleForReading.readabilityHandler = nil
            output?.fileHandleForReading.readabilityHandler = nil
            throw Failure.couldNotStart(error.localizedDescription)
        }
        let managed = ManagedProcess(process: process, removing: launch.removing, pipes: [errors] + (output.map { [$0] } ?? []), stderr: stderr, stdout: stdout)
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

    package static func isReady(_ readiness: Readiness, stdout: Output) -> Bool {
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
    package static func accepts(_ path: String) -> Bool {
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
    package static func closeAll() {
        let all = lock.withLock {
            defer { live = [] }
            return live
        }
        // At quit nothing waits for a grace: SIGTERM to each and its
        // children — sent before this returns, every close before them too.
        all.forEach { $0.close(grace: 0) }
        closing.sync {}
    }

    /// The pids of those running, for tests.
    package static var livePIDs: [pid_t] { lock.withLock { live.filter(\.isRunning).map(\.pid) } }

    /// Those running, for an end-to-end run to see each gone after quitting.
    package static var liveProcesses: [ManagedProcess] { lock.withLock { live.filter(\.isRunning) } }

    /// The process groups of those not closed yet, each its leader's pid,
    /// while the group is still its own (`groupIsOurs`): what one started
    /// stays in it — an exec plugin even once kubectl exited and it was
    /// reparented —, so Activity's signal path refuses it as Overterm's
    /// own (docs/design/activity/analysis.md, 6.5 rule 2). Any thread.
    package static var openGroups: [pid_t] { lock.withLock { live }.filter { groupIsOurs($0.process) }.map(\.pid) }

    /// What it said on a stream — its last 16 KB: a process lives as long
    /// as the app, and ssh adds a line for every refused connection.
    package final class Output: @unchecked Sendable {
        package static let limit = 16 << 10
        private let lock = NSLock()
        private var data = Data()
        private var ended = false
        package func append(_ more: Data) {
            lock.withLock {
                data.append(more)
                if data.count > Self.limit { data = Data(data.suffix(Self.limit)) }
            }
        }
        package func finish() { lock.withLock { ended = true } }
        package var finished: Bool { lock.withLock { ended } }
        package var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// What a pool keeps: something over a managed process.
package protocol ManagedResource: AnyObject, Sendable {
    var isOpen: Bool { get }
    func close()
}

/// One process a key (a host, a context), opened by the first use and again
/// on the next use after it has gone (the network changed, the Mac slept);
/// uses that arrive while it opens wait for that one.
package actor ManagedProcessPool<Key: Hashable & Sendable, Value: ManagedResource> {
    private let open: @Sendable (Key) async throws -> Value
    private var values: [Key: Value] = [:]
    private var opening: [Key: Task<Value, Error>] = [:]
    /// Every one opened, for `closeAll` from outside the actor.
    private let all = Opened()

    package init(open: @escaping @Sendable (Key) async throws -> Value) {
        self.open = open
    }

    /// The open one for `key`, opened now if there is none.
    package func value(for key: Key) async throws -> Value {
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
    package func existing(_ key: Key) -> Value? { values[key] }

    /// Closes the one for `key`, when it is no longer wanted.
    package func close(_ key: Key) {
        values.removeValue(forKey: key)?.close()
    }

    /// Closes every one this pool opened.
    package nonisolated func closeAll() { all.closeAll() }

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
