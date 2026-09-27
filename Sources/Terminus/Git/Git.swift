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
    static func run(
        _ arguments: [String], in directory: URL, success: Set<Int32> = [0], timeout: TimeInterval? = defaultTimeout
    ) async throws -> String {
        try await run(executable, arguments, in: directory, success: success, timeout: timeout)
    }

    /// Any tool, the same way: a GCD thread, output read as it comes, no prompts.
    static func run(
        _ tool: URL, _ arguments: [String], in directory: URL, success: Set<Int32> = [0],
        timeout: TimeInterval? = defaultTimeout
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                continuation.resume(
                    with: Result { try runBlocking(tool, arguments, in: directory, success: success, timeout: timeout) })
            }
        }
    }

    /// Foundation raises an Objective-C exception — the app dies — launching
    /// a process with more arguments than this; a caller batching paths
    /// stays under it (FileTreeModel.checkIgnored).
    static let maxArguments = 4000

    static func runBlocking(
        _ tool: URL, _ arguments: [String], in directory: URL, success: Set<Int32>, timeout: TimeInterval?
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
        let outReader = PipeReader(out)
        let errReader = PipeReader(err)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

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

        if timedOut {
            throw GitError(arguments: arguments, status: -1, stderr: "\(tool.lastPathComponent) timed out after \(Int(timeout ?? 0)) s")
        }
        guard success.contains(process.terminationStatus) else {
            throw GitError(arguments: arguments, status: process.terminationStatus, stderr: String(decoding: errReader.data, as: UTF8.self))
        }
        return String(decoding: outReader.data, as: UTF8.self)
    }
}

/// Collects what a pipe delivers, on FileHandle's own queue.
private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let closed = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                closed.signal()
            } else {
                lock.withLock { buffer.append(chunk) }
            }
        }
    }

    /// Waits for end of file until `deadline`, then stops reading.
    func finish(waitingUntil deadline: DispatchTime) {
        if closed.wait(timeout: deadline) == .timedOut { handle.readabilityHandler = nil }
    }

    var data: Data { lock.withLock { buffer } }
}
