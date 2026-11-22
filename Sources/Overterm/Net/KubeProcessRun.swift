import Darwin
import Foundation

/// A short-lived process: its exit status and what it wrote, or nil when
/// it couldn't start or didn't end in time. It starts in a process group
/// of its own — an exec plugin it runs (kubelogin listening on
/// 127.0.0.1:8000, aws, gke-gcloud-auth-plugin) is in it too — and the
/// group is ended when it is done, timed out (SIGTERM, then SIGKILL) or
/// not, so nothing it started outlives it. Every one running is known
/// (`livePIDs`) and ended at quit (`stopAll`), by its group's id — never
/// by a pattern.
package enum KubeProcessRun {
    package struct Result: Sendable {
        package var status: Int32
        package var stdout: String
        package var stderr: String
        /// Its output went past the limit: what came is the start of it.
        package var truncated = false

        package init(status: Int32, stdout: String, stderr: String, truncated: Bool = false) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
            self.truncated = truncated
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: Set<pid_t> = []

    /// The ones running now (each its group's id), for tests.
    package static var livePIDs: [pid_t] { lock.withLock { running.sorted() } }

    /// Every one still running, its whole group: at quit.
    package static func stopAll() {
        // Under the lock: a run reaps its process only after taking it out
        // of `running`, so the group's id can't be another's yet.
        lock.withLock {
            for pid in running { killpg(pid, SIGKILL) }
            running = []
        }
    }

    /// `input`, when given, is its stdin — written through a pipe, never a
    /// file (a release's values for `helm template --values -`); else stdin
    /// is /dev/null. `helper`: which of Overterm's children it is, said in
    /// its environment beside the run's marker (D-15).
    package static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval, outputLimit: Int = 64 * 1024,
        input: Data? = nil, helper: OvertermRun.Helper = .kubectl
    ) -> Result? {
        let out = Pipe()
        let err = Pipe()
        let stdin = input.map { _ in Pipe() }
        let outReader = PipeReader(out, limit: outputLimit)
        let errReader = PipeReader(err, limit: 64 * 1024)
        let pid = lock.withLock { () -> pid_t? in
            guard
                let pid = try? ProcessGroup.spawn(
                    executable, arguments, OvertermRun.current.marking(environment, helper: helper), stdout: out.fileHandleForWriting.fileDescriptor,
                    stderr: err.fileHandleForWriting.fileDescriptor, stdin: stdin?.fileHandleForReading.fileDescriptor
                ).get()
            else { return nil }
            running.insert(pid)
            return pid
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        if let stdin {
            try? stdin.fileHandleForReading.close()
            if pid != nil, let input { feed(input, to: stdin.fileHandleForWriting) } else { try? stdin.fileHandleForWriting.close() }
        }
        guard let pid else {
            outReader.finish(waitingUntil: .now())
            errReader.finish(waitingUntil: .now())
            return nil
        }
        let ended = waitForExit(pid, until: Date().addingTimeInterval(timeout))
        if !ended {
            lock.withLock { _ = killpg(pid, SIGTERM) }
            _ = waitForExit(pid, until: Date().addingTimeInterval(2))
        }
        // Whatever it started and left: the group goes with it. The leader
        // isn't reaped yet, so the group's id is still its own.
        lock.withLock {
            if running.remove(pid) != nil { killpg(pid, SIGKILL) }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        guard ended else {
            outReader.finish(waitingUntil: .now())
            errReader.finish(waitingUntil: .now())
            return nil
        }
        outReader.finish(waitingUntil: .now() + 2)
        errReader.finish(waitingUntil: .now() + 2)
        return Result(
            status: exitStatus(status), stdout: String(decoding: outReader.data, as: UTF8.self), stderr: String(decoding: errReader.data, as: UTF8.self),
            truncated: outReader.reachedLimit)
    }

    /// `data` written to a child's stdin and the pipe closed, on a thread of
    /// its own (a pipe holds 64 KB: the child reads as it is written). A
    /// child that exits first only ends the write (EPIPE: SIGPIPE is
    /// ignored for writes to a pipe here, `F_SETNOSIGPIPE`).
    private static func feed(_ data: Data, to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let block: @Sendable () -> Void = {
            data.withUnsafeBytes { buffer in
                guard var base = buffer.baseAddress else { return }
                var left = buffer.count
                while left > 0 {
                    let wrote = write(handle.fileDescriptor, base, left)
                    if wrote < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    left -= wrote
                    base = base.advanced(by: wrote)
                }
            }
            try? handle.close()
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: block)
    }

    /// The exit code, or 128 + the signal that ended it, as a shell says it.
    package static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Whether it has exited by `deadline` — left unreaped (`WNOWAIT`).
    private static func waitForExit(_ pid: pid_t, until deadline: Date) -> Bool {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { return true }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }
}
