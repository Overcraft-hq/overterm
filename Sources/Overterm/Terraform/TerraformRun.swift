import Darwin
import Foundation

/// A short terraform run (analysis 4.1: `fmt`, `validate`): spawned into a
/// process group of its own (`ProcessGroup`), its output bounded (1 MB),
/// a timeout (30 s), on a GCD thread — never a blocked Swift-concurrency
/// thread. Only a line `TerraformCommands` builds starts
/// (`TerraformCommands.refusal`). Not `KubeProcessRun` (Kubernetes', with
/// its SIGKILL at quit) and not a `ManagedProcess`. Every live group is
/// kept (`live`): quitting stops them with SIGINT (`stopAll`, analysis
/// 4.7) — the ones that take a lock or write (New Task's init, the lock
/// probe, force-unlock: `interruptible` false) given a moment to end
/// first —, and once terraform has exited its group is swept with SIGKILL,
/// so a provider plugin validate started is never left behind.
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
    /// stdout's bound. Cancelling the task stops an `interruptible` run
    /// (a read: fmt, validate, a state read, a workspace list): SIGINT to
    /// its group, as Ctrl-C would, and it is swept once terraform has
    /// exited. A run that writes or takes a lock — New Task's `init
    /// -backend=false`, the lock probe, `force-unlock` — passes false: a
    /// cancelled task leaves it to end on its own (its timeout still holds),
    /// never half done.
    static func short(
        _ binary: URL, _ arguments: [String], in folder: URL, environment: [String: String], input: Data? = nil, timeout: TimeInterval = timeout,
        file: Int32? = nil, limit: Int = outputLimit, interruptible: Bool = true
    ) async throws -> Result {
        guard interruptible else {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let work: @Sendable () -> Void = {
                    continuation.resume(
                        with: Swift.Result {
                            try runBlocking(
                                binary, arguments, in: folder, environment: environment, input: input, timeout: timeout, file: file, limit: limit,
                                interruptible: false)
                        })
                }
                DispatchQueue.global(qos: .userInitiated).async(execute: work)
            }
        }
        let stopper = Stopper()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let work: @Sendable () -> Void = {
                    continuation.resume(
                        with: Swift.Result {
                            try runBlocking(
                                binary, arguments, in: folder, environment: environment, input: input, timeout: timeout, file: file, limit: limit,
                                stopper: stopper)
                        })
                }
                DispatchQueue.global(qos: .userInitiated).async(execute: work)
            }
        } onCancel: {
            stopper.stop()
        }
    }

    /// The same, blocking the calling thread (a GCD one). `stopper`: what
    /// stops it from elsewhere (a cancelled task); `interruptible`: whether
    /// quitting interrupts it at once (`stopAll`).
    static func runBlocking(
        _ binary: URL, _ arguments: [String], in folder: URL, environment: [String: String], input: Data?, timeout: TimeInterval,
        file: Int32? = nil, limit: Int = outputLimit, stopper: Stopper? = nil, interruptible: Bool = true
    ) throws -> Result {
        if let why = TerraformCommands.refusal(arguments) { throw Failure.refused(why) }
        if stopper?.isStopped == true { throw CancellationError() }
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
        live.insert(pid, interruptible: interruptible)
        stopper?.started(pid)
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
        // Past the timeout: SIGTERM to the group, then SIGKILL — terraform
        // takes SIGTERM as an interrupt, releasing a lock it holds.
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
        stopper?.finished()
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

    /// The longest quitting waits for a run that writes or holds a lock.
    static let quitGrace: TimeInterval = 3

    /// Stops every run going (at quit, at a scenario's end — `endRun`):
    /// SIGINT to each read's group at once, as Ctrl-C would; a run that
    /// writes or holds a lock (`interruptible` false: an init, the lock
    /// probe, force-unlock) is given up to `grace` to end on its own first,
    /// then interrupted too — terraform releases a lock it took on SIGINT.
    /// Each waiting thread reaps its run and sweeps the group if the app is
    /// still there.
    static func stopAll(grace: TimeInterval = quitGrace) {
        live.stopped()
        for group in live.all where live.isInterruptible(group) { killpg(group, SIGINT) }
        let deadline = Date().addingTimeInterval(grace)
        while live.all.contains(where: { !live.isInterruptible($0) }), Date() < deadline { usleep(50_000) }
        for group in live.all { killpg(group, SIGINT) }
    }

    final class LiveGroups: @unchecked Sendable {
        private let lock = NSLock()
        /// Each group, and whether quitting interrupts it at once.
        private var groups: [pid_t: Bool] = [:]
        var all: [pid_t] { lock.withLock { Array(groups.keys) } }
        func isInterruptible(_ group: pid_t) -> Bool { lock.withLock { groups[group] ?? true } }
        func insert(_ group: pid_t, interruptible: Bool = true) { lock.withLock { groups[group] = interruptible } }
        func remove(_ group: pid_t) { _ = lock.withLock { groups.removeValue(forKey: group) } }
        /// How many times `stopAll` ran: a run that sees it change while it
        /// went may have been interrupted.
        private var stops = 0
        var generation: Int { lock.withLock { stops } }
        func stopped() { lock.withLock { stops += 1 } }
    }

    /// Stops one run from another thread: SIGINT to its group once it has
    /// started (at once if it already has), never after it was reaped.
    final class Stopper: @unchecked Sendable {
        private let lock = NSLock()
        private var group: pid_t?
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }

        func started(_ pid: pid_t) {
            let stop = lock.withLock {
                group = pid
                return stopped
            }
            if stop { killpg(pid, SIGINT) }
        }

        func finished() { lock.withLock { group = nil } }

        func stop() {
            let running = lock.withLock {
                stopped = true
                return group
            }
            if let running { killpg(running, SIGINT) }
        }
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
