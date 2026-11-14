import Darwin
import Foundation

/// A child started into a process group of its own (posix_spawn with
/// `POSIX_SPAWN_SETPGROUP`): signalled as a group (`killpg`), so what it
/// started — an exec plugin kubectl ran, even one reparented once kubectl
/// exited, or one started a moment before the signal — ends with it. Stdin
/// /dev/null unless given, stdout and stderr the descriptors given, no other
/// descriptor of the app's, the signals as a new process has them.
/// `newSession`: a session of its own as well (`POSIX_SPAWN_SETSID`), so no
/// controlling terminal and no SIGHUP when the app's goes — Terraform's
/// detached apply; its group is still its own, led by it.
enum ProcessGroup {
    /// The child's pid (its group's id too), or the errno posix_spawn gave.
    static func spawn(
        _ executable: URL, _ arguments: [String], _ environment: [String: String], directory: URL? = nil, stdout: Int32, stderr: Int32,
        stdin: Int32? = nil, descriptors: [Int32: Int32] = [:], newSession: Bool = false
    ) -> Result<pid_t, POSIXError> {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        // Others the child is handed, by its own number (`/dev/fd/3`): every
        // other descriptor of the app's is closed at exec.
        for (child, parent) in descriptors.sorted(by: { $0.key < $1.key }) where child > 2 {
            if child == parent {
                // dup2 onto itself leaves close-on-exec set: inherited instead.
                posix_spawn_file_actions_addinherit_np(&actions, child)
            } else {
                posix_spawn_file_actions_adddup2(&actions, parent, child)
            }
        }
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session makes the child its own group's leader: setsid after
        // a setpgid that made it one already would fail.
        let grouping = newSession ? POSIX_SPAWN_SETSID : POSIX_SPAWN_SETPGROUP
        posix_spawnattr_setflags(&attributes, Int16(grouping | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        if !newSession { posix_spawnattr_setpgroup(&attributes, 0) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let failed = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard failed == 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: failed) ?? .EIO)) }
        return .success(pid)
    }

    /// One spawned child, reaped when it exits (a dispatch source, and
    /// whenever it is asked about): its status as `Process` says it — the
    /// exit code, or the signal that ended it.
    final class Child: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var status: Int32?
        private var source: DispatchSourceProcess?

        init(pid: pid_t) {
            self.pid = pid
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
            // Strong until it exits: a zombie nobody reaps otherwise.
            source.setEventHandler { self.reap() }
            lock.withLock { self.source = source }
            source.resume()
            // Exited before the source was there: reaped now.
            reap()
        }

        var isRunning: Bool {
            reap()
            return lock.withLock { status == nil }
        }

        var terminationStatus: Int32 { lock.withLock { status ?? 0 } }

        private func reap() {
            let done: DispatchSourceProcess? = lock.withLock {
                guard status == nil else { return nil }
                var raw: Int32 = 0
                let answer = waitpid(pid, &raw, WNOHANG)
                if answer == pid {
                    status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
                } else if answer == -1, errno == ECHILD {
                    status = -1
                } else {
                    return nil
                }
                defer { source = nil }
                return source
            }
            done?.cancel()
        }
    }
}
