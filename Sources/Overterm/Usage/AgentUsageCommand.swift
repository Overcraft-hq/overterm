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
enum AgentUsageCommand {
    /// Set by the E2E runner: a stand-in that answers from a fixture.
    nonisolated(unsafe) static var executableOverride: URL?

    /// Where a GUI app has to look. Its PATH is not the shell's: `claude`
    /// is as likely to be under nvm, bun or ~/.claude/local as anywhere,
    /// so the login shell is asked once and the answer kept.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: URL??

    static func executable() -> URL? {
        if let executableOverride { return executableOverride }
        lock.lock()
        defer { lock.unlock() }
        if let found { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = [
            "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.bun/bin/claude",
        ]
        if let path = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            found = URL(fileURLWithPath: path)
            return found!
        }
        found = askTheShell()
        return found!
    }

    /// `$SHELL -lic 'command -v claude'`: the one way to find a tool a
    /// version manager put somewhere only the shell knows about.
    /// **Interactive**, not just a login shell: nvm is set up in .zshrc,
    /// which a login shell doesn't read — `-lc` here found nothing while
    /// the same lookup in a pane found it at once.
    private static func askTheShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// How long a refresh may take before it is given up on: it is one
    /// request, and nothing waits for it.
    static let timeout: TimeInterval = 20

    /// Runs `claude -p "/usage"`. Blocking; call off the main thread.
    /// Returns what it printed, which is what the pane's numbers must
    /// agree with; the structured figures are read from the file it
    /// refreshes.
    @discardableResult
    static func askClaude() -> String? {
        guard let executable = executable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting: a full pipe would hold the process open.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
