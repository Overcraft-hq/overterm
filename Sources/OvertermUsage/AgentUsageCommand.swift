import Foundation

/// Asks an agent's own CLI what is left, so the pane can never say
/// something its own command doesn't.
///
/// Claude keeps the answer in `~/.claude.json`, but only writes it when it
/// asks the service — in the middle of a long day that file was eight
/// hours old and said a window had rolled over while `/usage` said 6%.
/// Reading it alone is reading yesterday's paper.
///
/// So the numbers are refreshed the way a person would: by running
/// `claude -p "/usage"`, which prints exactly what `/usage` prints in a
/// session *and* writes the fresh figures to that file. We then read the
/// file, because it carries the same numbers as structured data — exact
/// reset instants rather than "Oct 16 at 2:20am (Europe/Istanbul)" to be
/// parsed back. No credentials are read and no undocumented endpoint is
/// called: the agent's own command does its own talking.
package enum AgentUsageCommand {
    /// Set by the E2E runner: a stand-in that answers from a fixture.
    package nonisolated(unsafe) static var executableOverride: URL?

    /// Where a GUI app has to look. Its PATH is not the shell's: `claude`
    /// is as likely to be under nvm, bun or ~/.claude/local as anywhere,
    /// so the known places are tried, then the login shell's PATH
    /// (`ShellEnvironment`), and the answer kept.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: URL??

    package static func executable() -> URL? {
        if let executableOverride { return executableOverride }
        // An isolated run (E2E, the layout dump) never runs the user's own
        // agent: it talked to their account and wrote their ~/.claude.json,
        // and the usage scenario's meters waited out its seconds.
        if AppEnvironment.isIsolated { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let found { return found }
        // Shared with New Task's and an agent tab's check (`AgentFinder`).
        let known = AgentFinder.knownPaths(for: .claude, home: FileManager.default.homeDirectoryForCurrentUser.path)
        if let path = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            found = URL(fileURLWithPath: path)
            return found!
        }
        found = ShellEnvironment.executable("claude")
        return found!
    }

    /// How long a refresh may take before it is given up on: it is one
    /// request, and nothing waits for it.
    package static let timeout: TimeInterval = 20

    /// What it is given: the app's environment, marked as this run's (D-15).
    package static func environment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        OvertermRun.current.marking(inherited, helper: .agentUsage)
    }

    /// Runs `claude -p "/usage"`. Blocking; call off the main thread.
    /// Returns what it printed, which is what the pane's numbers must
    /// agree with; the structured figures are read from the file it
    /// refreshes.
    @discardableResult
    package static func askClaude() -> String? {
        guard let executable = executable() else { return nil }
        lock.lock()
        let flag = takesNoPersistence
        lock.unlock()
        let first = run(executable, arguments(persisting: !flag))
        guard flag, refusesFlag(status: first.status, stderr: first.stderr) else { return first.text }
        // A Claude Code older than the flag refuses it and prints nothing:
        // asked again as before, and not offered the flag again this run.
        lock.lock()
        takesNoPersistence = false
        lock.unlock()
        return run(executable, arguments(persisting: true)).text
    }

    /// `/usage` as a one-off: `--no-session-persistence` keeps it from
    /// writing a session — run from ~ every ten minutes, it had left 818
    /// transcripts in a month under ~/.claude/projects/-Users-<name>, each
    /// a `/usage` and its output, in `claude --resume`'s list. It is a
    /// local command: no model is asked, nothing spent (cost 0, no model
    /// usage in those files); ~/.claude.json is still written.
    package static func arguments(persisting: Bool) -> [String] {
        persisting ? ["-p", "/usage"] : ["-p", "/usage", "--no-session-persistence"]
    }

    /// Whether a run's failure is Claude Code not knowing the flag — and
    /// nothing else: a timeout or a network error keeps it.
    package static func refusesFlag(status: Int32, stderr: String) -> Bool {
        status != 0 && stderr.contains("no-session-persistence") && stderr.lowercased().contains("unknown option")
    }

    /// Whether this run's `claude` takes the flag (until it refuses it).
    nonisolated(unsafe) private static var takesNoPersistence = true

    private static func run(_ executable: URL, _ arguments: [String]) -> (text: String?, status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (nil, -1, "") }
        // Both pipes drained on threads of their own, and the process waited
        // for with the deadline: a read to the pipe's end waited for every
        // writer, so a `claude` that hung (or a child holding the pipe) held
        // the refresh forever and the deadline never came.
        let output = PipeDrain(out)
        let errors = PipeDrain(err)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        let data = output.take(within: 2)
        let text = String(decoding: data, as: UTF8.self)
        let status = process.isRunning ? -1 : process.terminationStatus
        return (text.isEmpty ? nil : text, status, String(decoding: errors.take(within: 1).prefix(4096), as: UTF8.self))
    }
}

/// A pipe read to its end on a thread of its own; what it read, waited for
/// a bounded time (a child that kept the pipe open is left to it).
private final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func take(within seconds: Double) -> Data {
        done.wait(timeout: .now() + seconds) == .success ? data : Data()
    }
}
