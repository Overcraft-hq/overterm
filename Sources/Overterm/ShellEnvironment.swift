import Foundation

/// The environment the user's own shell would give a command — PATH and the
/// rest — for an app started from the Dock, whose environment is launchd's.
///
/// A tool is as likely to be under nvm, bun, Homebrew or ~/.local as on
/// `/usr/bin:/bin`, and a tool it starts in turn (kubectl's exec credential
/// plugins: `aws`, `kubectl-oidc_login`) is looked up on the PATH it was
/// handed. So the login shell is asked once and the answer kept.
///
/// **Interactive**, not just a login shell: nvm is set up in .zshrc, which a
/// login shell doesn't read — `-lc` found nothing while the same lookup in
/// a pane found it at once.
///
/// The shell runs with `HISTFILE=/dev/null`, so asking it puts nothing in
/// the user's history (Freelens's sync did, #1696); the user's own HISTFILE
/// is put back in the answer. It gets `timeout` seconds: a startup file that
/// waits (a prompt, ssh-agent, the keychain) must not hold every caller.
///
/// An isolated run (E2E, the layout dump) never asks the user's shell: it
/// gets the environment it was started with.
enum ShellEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: (answer: [String: String]?, at: Date)?

    /// How long the shell may take to answer before it is stopped.
    static let timeout: TimeInterval = 10
    /// A shell that couldn't be asked is asked again after this long; an
    /// answer is kept for good.
    static let retryAfter: TimeInterval = 60

    /// What the login shell said, asked once; nil in an isolated run or when
    /// the shell couldn't be asked. Blocking (up to `timeout`) the first
    /// time: call off the main thread.
    static func login() -> [String: String]? {
        if AppEnvironment.isIsolated { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let asked, asked.answer != nil || Date().timeIntervalSince(asked.at) < retryAfter { return asked.answer }
        let answer = askTheShell()
        asked = (answer, Date())
        return answer
    }

    /// The environment to hand a command: the login shell's, else the one
    /// Overterm was started with.
    static func environment() -> [String: String] {
        login() ?? ProcessInfo.processInfo.environment
    }

    /// `tool` on the login shell's PATH, if the shell said one and it holds
    /// an executable `tool`.
    static func executable(_ tool: String) -> URL? {
        guard let login = login() else { return nil }
        return executable(tool, in: login)
    }

    /// The first folder of `environment`'s PATH holding an executable `tool`.
    static func executable(
        _ tool: String, in environment: [String: String], isExecutable: (String) -> Bool = FileManager.default.isExecutableFile
    ) -> URL? {
        guard !tool.isEmpty, !tool.contains("/") else { return nil }
        for folder in (environment["PATH"] ?? "").split(separator: ":") where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(tool)
            if isExecutable(candidate.path) { return candidate }
        }
        return nil
    }

    /// Printed before the environment, so whatever the shell's startup files
    /// print (a greeting, a prompt's instant mode) is told apart from it.
    static let marker = "__OVERTERM_SHELL_ENVIRONMENT__"

    /// What the shell is told to run: the marker, then every variable.
    static let script = "printf '%s\\0' \(marker); /usr/bin/env -0"

    /// `$SHELL -lic '…; env -0'`, history off.
    private static func askTheShell() -> [String: String]? {
        let inherited = ProcessInfo.processInfo.environment
        let shell = URL(fileURLWithPath: inherited["SHELL"] ?? "/bin/zsh")
        guard let data = run(shell, ["-lic", script], environment: launchEnvironment(inherited), timeout: timeout),
            let parsed = parse(data)
        else { return nil }
        return restoringHistory(parsed, inherited: inherited)
    }

    /// The environment the shell is started with: Overterm's own, with
    /// history going nowhere.
    static func launchEnvironment(_ inherited: [String: String]) -> [String: String] {
        inherited.merging(["HISTFILE": "/dev/null"]) { _, ours in ours }
    }

    /// The answer with the user's own HISTFILE back (or none, as Overterm
    /// had), so a command or a tab handed it keeps its history. A HISTFILE
    /// the startup files set themselves is theirs, and kept.
    static func restoringHistory(_ environment: [String: String], inherited: [String: String]) -> [String: String] {
        guard environment["HISTFILE"] == "/dev/null" else { return environment }
        var environment = environment
        environment["HISTFILE"] = inherited["HISTFILE"]
        return environment
    }

    /// Runs `shell` and returns what it wrote, or nil if it couldn't start
    /// or didn't finish within `timeout` (it is then stopped). A child it
    /// left behind holding the pipe open is not waited for.
    static func run(_ shell: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = shell
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let reader = PipeReader(out)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            reader.finish(waitingUntil: .now())
            return nil
        }
        reader.finish(waitingUntil: .now() + 2)
        return reader.data
    }

    /// The `NAME=value` entries after the marker, each ended by a NUL (a
    /// value may hold newlines). Nil when the marker never came or no PATH
    /// did: that is not the shell's environment.
    static func parse(_ data: Data) -> [String: String]? {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        // The first field that ends with the marker: anything the startup
        // files printed is glued to its front.
        guard let start = fields.firstIndex(where: { $0.hasSuffix(marker) }) else { return nil }
        var environment: [String: String] = [:]
        for field in fields[(start + 1)...] {
            guard let equals = field.firstIndex(of: "="), equals != field.startIndex else { continue }
            environment[String(field[..<equals])] = String(field[field.index(after: equals)...])
        }
        return environment["PATH"] == nil ? nil : environment
    }
}
