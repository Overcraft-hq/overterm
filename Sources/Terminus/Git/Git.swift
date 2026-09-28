import Foundation

struct GitError: LocalizedError {
    let arguments: [String]
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(arguments.joined(separator: " ")) exited with \(status)" : message
    }
}

/// Runs git (and other command-line tools). Each call blocks a libdispatch thread, never a Swift
/// concurrency one: blocking the cooperative pool with many waits starves
/// the whole app (signalbox froze exactly that way).
enum Git {
    /// /usr/bin/git is the Xcode shim; a GUI app's PATH has no Homebrew.
    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    /// How long a call may take before it is killed. A read that hangs — a
    /// fetch on a dead network, gh waiting on an API — would otherwise hold
    /// its thread, and what waits on it, forever.
    static let defaultTimeout: TimeInterval = 120

    /// Processes running at once. Each blocks a thread for its whole life;
    /// without a cap, a burst of refreshes (many tabs, many worktrees) used
    /// up libdispatch's threads.
    static let maxConcurrent = 16

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Git"
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// - Parameter success: exit codes that are not failures. `git diff
    ///   --no-index` exits 1 when the files differ, which is the point.
    /// - Parameter timeout: nil for what may rightly take long — a commit
    ///   runs the repository's hooks.
    /// - Parameter outputLimit: bytes of stdout wanted at most. Past it the
    ///   process is stopped and what came so far is returned, whatever its
    ///   exit — a search that needs 50 matches needn't read a whole repo.
    ///
    /// Cancelling the calling task stops the process (a search superseded
    /// by the next keystroke) and throws CancellationError.
    static func run(
        _ arguments: [String], in directory: URL, success: Set<Int32> = [0], timeout: TimeInterval? = defaultTimeout,
        outputLimit: Int? = nil
    ) async throws -> String {
        try await run(executable, arguments, in: directory, success: success, timeout: timeout, outputLimit: outputLimit)
    }

    /// Any tool, the same way: a GCD thread, output read as it comes, no prompts.
    static func run(
        _ tool: URL, _ arguments: [String], in directory: URL, success: Set<Int32> = [0],
        timeout: TimeInterval? = defaultTimeout, outputLimit: Int? = nil
    ) async throws -> String {
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    continuation.resume(
                        with: Result {
                            try runBlocking(
                                tool, arguments, in: directory, success: success, timeout: timeout, outputLimit: outputLimit,
                                running: running)
                        })
                }
            }
        } onCancel: {
            running.cancel()
        }
    }

    /// Foundation raises an Objective-C exception — the app dies — launching
    /// a process with more arguments than this; a caller batching paths
    /// stays under it (FileTreeModel.checkIgnored).
    static let maxArguments = 4000

    static func runBlocking(
        _ tool: URL, _ arguments: [String], in directory: URL, success: Set<Int32>, timeout: TimeInterval?,
        outputLimit: Int? = nil, running: RunningProcess = RunningProcess()
    ) throws -> String {
        guard arguments.count <= maxArguments else {
            throw GitError(arguments: Array(arguments.prefix(4)), status: -1, stderr: "too many arguments (\(arguments.count))")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // Never block on a credential or editor prompt nobody can see.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // Both pipes are read as data arrives, not by a thread blocked on
        // each: a full pipe would block git, and the old stderr drain waited
        // for a pool thread that a burst of calls had all taken.
        let outReader = PipeReader(out, limit: outputLimit) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
        let errReader = PipeReader(err)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard try running.start(process) else { throw CancellationError() }

        var timedOut = false
        if exited.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A child it left behind (ssh under fetch) can hold the pipes open
        // past its exit; don't wait for that.
        let grace = DispatchTime.now() + 2
        outReader.finish(waitingUntil: grace)
        errReader.finish(waitingUntil: grace)

        if running.isCancelled { throw CancellationError() }
        if outReader.reachedLimit { return String(decoding: outReader.data, as: UTF8.self) }
        if timedOut {
            throw GitError(arguments: arguments, status: -1, stderr: "\(tool.lastPathComponent) timed out after \(Int(timeout ?? 0)) s")
        }
        guard success.contains(process.terminationStatus) else {
            throw GitError(arguments: arguments, status: process.terminationStatus, stderr: String(decoding: errReader.data, as: UTF8.self))
        }
        return String(decoding: outReader.data, as: UTF8.self)
    }
}

/// The process a `Git.run` call is running, so cancelling the task can
/// stop it — whether that comes before it starts, or after.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Launches `process` unless the call was cancelled first.
    func start(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !cancelled else { return false }
            try process.run()
            self.process = process
            return true
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

/// Collects what a pipe delivers, on FileHandle's own queue — up to `limit`
/// bytes, if given; then `onLimit` runs once and the rest is ignored.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let closed = DispatchSemaphore(value: 0)
    private let limit: Int?
    private var onLimit: (() -> Void)?
    private var hitLimit = false
    var reachedLimit: Bool { lock.withLock { hitLimit } }

    init(_ pipe: Pipe, limit: Int? = nil, onLimit: (() -> Void)? = nil) {
        handle = pipe.fileHandleForReading
        self.limit = limit
        self.onLimit = onLimit
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                closed.signal()
                return
            }
            let hit: (() -> Void)? = lock.withLock {
                guard !self.hitLimit else { return nil }
                self.buffer.append(chunk)
                guard let limit = self.limit, self.buffer.count >= limit else { return nil }
                self.hitLimit = true
                defer { self.onLimit = nil }
                return self.onLimit
            }
            hit?()
        }
    }

    /// Waits for end of file until `deadline`, then stops reading.
    func finish(waitingUntil deadline: DispatchTime) {
        if closed.wait(timeout: deadline) == .timedOut { handle.readabilityHandler = nil }
    }

    var data: Data { lock.withLock { buffer } }
}
