import Darwin
import Foundation

/// A short terraform run (analysis 4.1: `fmt`, `validate`): spawned into a
/// process group of its own (`ProcessGroup`), its output bounded (1 MB),
/// a timeout (30 s), on a GCD thread — never a blocked Swift-concurrency
/// thread. Only a line `TerraformCommands` builds starts
/// (`TerraformCommands.refusal`). Not `KubeProcessRun` (Kubernetes', with
/// its SIGKILL at quit) and not a `ManagedProcess`. Every live group is
/// kept (`live`): quitting stops them with SIGINT (`stopAll`, analysis
/// 4.7), and once terraform has exited its group is swept with SIGKILL, so
/// a provider plugin validate started is never left behind.
enum TerraformRun {
    struct Result: Sendable, Equatable {
        var status: Int32
        var stdout: Data
        var stderr: String
        /// Its stdout passed the limit; what came is kept.
        var truncated = false
        var timedOut = false
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case refused(String)
        case spawn(Int32)

        var description: String {
            switch self {
            case .refused(let why): "refused: \(why)"
            case .spawn(let code): "terraform could not start: \(String(cString: strerror(code)))"
            }
        }
    }

    static let outputLimit = 1 << 20
    static let stderrLimit = 64 << 10
    static let timeout: TimeInterval = 30

    /// Runs `arguments` with `binary` in `folder`, `input` on its stdin.
    /// `file`: a descriptor the child gets as fd 3 (`show -json /dev/fd/3`,
    /// analysis 4.4) — the caller's, still open after the run. `limit`:
    /// stdout's bound.
    static func short(
        _ binary: URL, _ arguments: [String], in folder: URL, environment: [String: String], input: Data? = nil, timeout: TimeInterval = timeout,
        file: Int32? = nil, limit: Int = outputLimit
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            let work: @Sendable () -> Void = {
                continuation.resume(
                    with: Swift.Result {
                        try runBlocking(binary, arguments, in: folder, environment: environment, input: input, timeout: timeout, file: file, limit: limit)
                    })
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    /// The same, blocking the calling thread (a GCD one).
    static func runBlocking(
        _ binary: URL, _ arguments: [String], in folder: URL, environment: [String: String], input: Data?, timeout: TimeInterval,
        file: Int32? = nil, limit: Int = outputLimit
    ) throws -> Result {
        if let why = TerraformCommands.refusal(arguments) { throw Failure.refused(why) }
        let out = Pipe()
        let err = Pipe()
        let stdin = input.map { _ in Pipe() }
        let spawned = ProcessGroup.spawn(
            binary, arguments, environment, directory: folder, stdout: out.fileHandleForWriting.fileDescriptor,
            stderr: err.fileHandleForWriting.fileDescriptor, stdin: stdin?.fileHandleForReading.fileDescriptor, descriptors: file.map { [3: $0] } ?? [:])
        // The child has its own copies; ours would keep the pipes open.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        try? stdin?.fileHandleForReading.close()
        let pid: pid_t
        switch spawned {
        case .success(let child): pid = child
        case .failure(let error):
            try? stdin?.fileHandleForWriting.close()
            throw Failure.spawn(error.code.rawValue)
        }
        live.insert(pid)
        let outReader = PipeReader(out, limit: limit)
        let errReader = PipeReader(err, limit: stderrLimit)
        if let stdin, let input {
            let handle = stdin.fileHandleForWriting
            // A child that exits before reading it all must not take the app down by SIGPIPE.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            let write: @Sendable () -> Void = {
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: write)
        }
        // Past the timeout: SIGTERM to the group, then SIGKILL. Short runs
        // hold no lock and write nothing, so nothing is left half done.
        let timedOut = TimedOut()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout, repeating: 2)
        let fire: @Sendable () -> Void = {
            killpg(pid, timedOut.mark() ? SIGTERM : SIGKILL)
        }
        timer.setEventHandler(handler: fire)
        timer.resume()
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
        timer.cancel()
        // terraform is gone: whatever it left in its group (a provider
        // plugin) goes too, before the pipes it may still hold are read out.
        live.remove(pid)
        killpg(pid, SIGKILL)
        let grace = DispatchTime.now() + 2
        outReader.finish(waitingUntil: grace)
        errReader.finish(waitingUntil: grace)
        let status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        return Result(
            status: status, stdout: outReader.data, stderr: String(decoding: errReader.data, as: UTF8.self), truncated: outReader.reachedLimit,
            timedOut: timedOut.happened)
    }

    /// The process groups of the runs going now, by their leader's pid.
    static let live = LiveGroups()

    /// Stops every run going (at quit, at a scenario's end — `endRun`):
    /// SIGINT to each group, as Ctrl-C would, without waiting. A short run
    /// holds no lock and writes nothing; its waiting thread reaps it and
    /// sweeps the group if the app is still there.
    static func stopAll() {
        for group in live.all { killpg(group, SIGINT) }
    }

    final class LiveGroups: @unchecked Sendable {
        private let lock = NSLock()
        private var groups: Set<pid_t> = []
        var all: [pid_t] { lock.withLock { Array(groups) } }
        func insert(_ group: pid_t) { _ = lock.withLock { groups.insert(group) } }
        func remove(_ group: pid_t) { _ = lock.withLock { groups.remove(group) } }
    }

    /// Whether the timeout fired: the first time it says so (SIGTERM), then SIGKILL.
    private final class TimedOut: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        var happened: Bool { lock.withLock { fired } }
        /// True the first time.
        func mark() -> Bool {
            lock.withLock {
                defer { fired = true }
                return !fired
            }
        }
    }
}
