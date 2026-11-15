import CryptoKit
import Darwin
import Foundation

/// A plan file once `plan` has written it (analysis 4.4): opened, hashed
/// from that descriptor, and its path unlinked — from then on the plan is
/// the descriptor, handed to `show -json /dev/fd/3` (and, in stage 2a, to
/// `apply /dev/fd/3`). Nothing is left to swap, sweep after a crash, or
/// back up. Closed when the record holding it goes.
final class TerraformPlanFile: @unchecked Sendable {
    let descriptor: Int32
    let sha256: String
    let size: Int
    /// The file's mode as `plan` wrote it: 0600 under the `umask 077` launcher.
    let mode: mode_t

    init(descriptor: Int32, sha256: String, size: Int, mode: mode_t) {
        self.descriptor = descriptor
        self.sha256 = sha256
        self.size = size
        self.mode = mode
    }

    deinit { close(descriptor) }

    /// The SHA-256 of what `descriptor` holds, read with `pread`.
    static func sha256(of descriptor: Int32, size: Int) -> String? {
        var hasher = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while offset < size {
            let got = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, min($0.count, size - offset), off_t(offset)) }
            guard got > 0 else { return nil }
            hasher.update(data: Data(buffer[0..<got]))
            offset += got
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Opens `url` as `plan` left it (a regular file, never a link),
    /// hashes it and unlinks the path. Nil when there is none to hold.
    static func hold(_ url: URL, limit: Int) -> TerraformPlanFile? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        unlink(url.path)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit,
            let sha = sha256(of: fd, size: Int(info.st_size))
        else {
            close(fd)
            return nil
        }
        return TerraformPlanFile(descriptor: fd, sha256: sha, size: Int(info.st_size), mode: info.st_mode & 0o777)
    }
}

/// A terraform run whose `-json` stream Overterm reads as it comes (4.1:
/// plans and init): spawned into a process group of its own
/// (`ProcessGroup`), its stdout read line by line on the calling GCD
/// thread, decoded there (`TerraformUIMessage`) and handed on in 120 ms
/// batches; stderr bounded. Only a line `TerraformCommands` builds starts.
/// A plan starts through `/bin/sh -c 'umask 077; exec "$0" "$@"'` (4.4):
/// `posix_spawn` has no umask, and the app's is process-wide. The exit
/// code decides, never the stream: a plan's 0 (no changes), 2 (changes),
/// 1 (failed, even when a plan file was written, spike 23). Stopped with
/// one SIGINT to its group (`TerraformRun.live`, `stopAll`): a plan holding
/// the lock lets it go. Never a `ManagedProcess`, never SIGKILL while it runs.
enum TerraformStreamRun {
    struct Outcome: Sendable {
        var status: Int32
        var stderr: String
        /// The plan, held by its descriptor: only for exit 0 or 2.
        var file: TerraformPlanFile?
        /// Exit 0 or 2 with a plan file past `maxPlanBytes`: planned, not held.
        var tooLarge = false
    }

    static let batchInterval: UInt64 = 120_000_000
    static let maxPending = 4 << 20
    /// The plan file's bound (`terraform.maxPlanBytes`): what `show` reads too.
    static let maxPlanBytes = 64 << 20

    static let umaskLauncher = "umask 077; exec \"$0\" \"$@\""

    /// Runs `arguments` with `binary` in `folder`; blocking (a GCD thread's).
    /// `planFile`: where the plan writes, held once it exits 0 or 2.
    static func run(
        _ binary: URL, _ arguments: [String], in folder: URL, environment: [String: String], planFile: URL? = nil,
        started: @Sendable (pid_t) -> Void = { _ in }, batch: @Sendable ([TerraformUIMessage]) -> Void
    ) throws -> Outcome {
        if let why = TerraformCommands.refusal(arguments) { throw TerraformRun.Failure.refused(why) }
        let out = Pipe()
        let err = Pipe()
        let launched = planFile != nil
        let spawned = ProcessGroup.spawn(
            launched ? URL(fileURLWithPath: "/bin/sh") : binary, launched ? ["-c", umaskLauncher, binary.path] + arguments : arguments, environment,
            directory: folder, stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor)
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let pid: pid_t
        switch spawned {
        case .success(let child): pid = child
        case .failure(let error): throw TerraformRun.Failure.spawn(error.code.rawValue)
        }
        TerraformRun.live.insert(pid)
        started(pid)
        let errReader = PipeReader(err, limit: TerraformRun.stderrLimit)
        let fd = out.fileHandleForReading.fileDescriptor
        var pending = Data()
        var messages: [TerraformUIMessage] = []
        var flushed = DispatchTime.now().uptimeNanoseconds
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            pending.append(contentsOf: buffer[0..<got])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                messages.append(TerraformUIMessage.decode(String(decoding: line, as: UTF8.self)))
                pending.removeSubrange(pending.startIndex...newline)
            }
            if pending.count > maxPending {
                messages.append(.raw("(a line too long to keep)"))
                pending.removeAll()
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - flushed >= batchInterval, !messages.isEmpty {
                batch(messages)
                messages = []
                flushed = now
            }
        }
        if !pending.isEmpty { messages.append(TerraformUIMessage.decode(String(decoding: pending, as: UTF8.self))) }
        if !messages.isEmpty { batch(messages) }
        try? out.fileHandleForReading.close()
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
        TerraformRun.live.remove(pid)
        // terraform is gone: a provider plugin it left goes too.
        killpg(pid, SIGKILL)
        errReader.finish(waitingUntil: .now() + 2)
        let status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        var file: TerraformPlanFile?
        var tooLarge = false
        if let planFile {
            if status == 0 || status == 2 {
                var info = stat()
                if lstat(planFile.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) > maxPlanBytes {
                    tooLarge = true
                } else {
                    file = TerraformPlanFile.hold(planFile, limit: maxPlanBytes)
                }
            }
            // Exit 1 may still leave a file (spike 23): never kept.
            unlink(planFile.path)
        }
        return Outcome(status: status, stderr: TerraformPlan.scrub(String(decoding: errReader.data, as: UTF8.self)), file: file, tooLarge: tooLarge)
    }

    /// Stops a run going: one SIGINT to its group, as Ctrl-C does (D-3).
    static func interrupt(_ pid: pid_t) {
        guard TerraformRun.live.all.contains(pid) else { return }
        killpg(pid, SIGINT)
    }
}
