import Foundation

/// The `docker` command (and its runtimes' — `orb`, `colima`, `podman`),
/// for what the Engine API doesn't answer: Docker Desktop's own status, the
/// plugins' JSON. Found where the installers put it, since an app started
/// from the Dock has none of them on its PATH; run on a GCD thread
/// (`Git.run`), told to reach the engine Overterm does.
struct DockerCLI: Sendable {
    /// Folders the installers use, after the PATH Overterm was given.
    static func folders(home: URL, path: String?) -> [String] {
        let fromPath = (path ?? "").split(separator: ":").map(String.init)
        let known = [
            "/usr/local/bin", "/opt/homebrew/bin", home.appendingPathComponent(".docker/bin").path,
            home.appendingPathComponent(".orbstack/bin").path, "/Applications/Docker.app/Contents/Resources/bin",
            home.appendingPathComponent(".rd/bin").path, "/opt/podman/bin",
        ]
        var seen = Set<String>()
        return (fromPath + known).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// A scenario's own `docker` (a script answering as the CLI would),
    /// found before any other.
    nonisolated(unsafe) static var override: URL?

    /// The first of `folders` holding an executable `tool`.
    static func locate(
        _ tool: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        path: String? = ProcessInfo.processInfo.environment["PATH"], isExecutable: (String) -> Bool = FileManager.default.isExecutableFile
    ) -> URL? {
        if tool == "docker", let override { return override }
        return folders(home: home, path: path).lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }.first { isExecutable($0.path) }
    }

    /// Where the CLI looks for its plugins (`docker-scout`, `docker-mcp`):
    /// `~/.docker/cli-plugins`, Docker Desktop's, the system's.
    static func pluginFolders(home: URL, dockerConfig: URL = DockerEndpoint.home) -> [String] {
        [
            dockerConfig.appendingPathComponent("cli-plugins").path, home.appendingPathComponent(".docker/cli-plugins").path,
            "/Applications/Docker.app/Contents/Resources/cli-plugins", "/usr/local/lib/docker/cli-plugins", "/opt/homebrew/lib/docker/cli-plugins",
            "/usr/local/libexec/docker/cli-plugins", "/usr/libexec/docker/cli-plugins",
        ]
    }

    /// Whether `docker <name>` is a plugin that is there.
    static func hasPlugin(
        _ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile
    ) -> Bool {
        pluginFolders(home: home).contains { isExecutable(URL(fileURLWithPath: $0).appendingPathComponent("docker-" + name).path) }
    }

    let executable: URL
    let endpoint: DockerEndpoint?

    init(executable: URL, endpoint: DockerEndpoint?) {
        self.executable = executable
        self.endpoint = endpoint
    }

    /// `docker` (or another tool) where it is, or nil: not installed.
    init?(_ tool: String = "docker", endpoint: DockerEndpoint?) {
        guard let executable = Self.locate(tool) else { return nil }
        self.init(executable: executable, endpoint: endpoint)
    }

    /// Runs it, its output back. `env` sets the engine (its context or
    /// host) and a PATH with the tool's own folder, where `docker` finds
    /// its credential helpers and plugins. `folder`: where it runs —
    /// `compose` reads the files there.
    func run(
        _ arguments: [String], in folder: URL = FileManager.default.homeDirectoryForCurrentUser, success: Set<Int32> = [0],
        timeout: TimeInterval = 30
    ) async throws -> String {
        try await Git.run(
            URL(fileURLWithPath: "/usr/bin/env"), Self.environment(for: endpoint, executable: executable) + [executable.path] + arguments,
            in: folder, success: success, timeout: timeout)
    }

    enum Output: Sendable { case stdout, stderr }

    /// Runs it and hands over what it writes to `output` (BuildKit's
    /// progress is stderr) in whole lines as they come. No thread is
    /// blocked: FileHandle's queue reads, the process's own handler says
    /// when it ended. Another exit than `success` throws GitError with its
    /// last four lines. Ending the loop, or cancelling its task, terminates
    /// the process.
    func lines(_ arguments: [String], from output: Output = .stderr, success: Set<Int32> = [0]) -> AsyncThrowingStream<[String], Error> {
        Self.stream(
            tool: URL(fileURLWithPath: "/usr/bin/env"), arguments: Self.environment(for: endpoint, executable: executable) + [executable.path] + arguments,
            said: Array(arguments.suffix(6)), output: output, success: success)
    }

    /// Every closure is made here, outside any actor: the pipe's handler
    /// and the process's run on queues of their own (CLAUDE.md, Apple
    /// completion handlers).
    private nonisolated static func stream(
        tool: URL, arguments: [String], said: [String], output: Output, success: Set<Int32>
    ) -> AsyncThrowingStream<[String], Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            switch output {
            case .stdout:
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
            case .stderr:
                process.standardOutput = FileHandle.nullDevice
                process.standardError = pipe
            }
            let lines = LineStream(continuation, arguments: said, success: success)
            let reading = pipe.fileHandleForReading
            reading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    lines.ended()
                } else {
                    lines.feed(data)
                }
            }
            process.terminationHandler = { process in lines.exited(process.terminationStatus) }
            let running = RunningProcess()
            continuation.onTermination = { _ in running.cancel() }
            do {
                guard try running.start(process) else {
                    reading.readabilityHandler = nil
                    return continuation.finish(throwing: CancellationError())
                }
            } catch {
                reading.readabilityHandler = nil
                continuation.finish(throwing: error)
            }
        }
    }

    /// A line stream's state, shared by the pipe's queue and the process's
    /// handler: whole lines out, the last four kept for an error, finished
    /// once both the pipe and the process have ended.
    private final class LineStream: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncThrowingStream<[String], Error>.Continuation
        private let arguments: [String]
        private let success: Set<Int32>
        private var splitter = DockerLineSplitter()
        private var last: [String] = []
        private var eof = false
        private var status: Int32?
        private var finished = false

        init(_ continuation: AsyncThrowingStream<[String], Error>.Continuation, arguments: [String], success: Set<Int32>) {
            self.continuation = continuation
            self.arguments = arguments
            self.success = success
        }

        func feed(_ data: Data) {
            lock.withLock { yield(splitter.feed(data)) }
        }

        /// End of file: the half line left is a last line.
        func ended() {
            lock.withLock {
                yield(splitter.finish().map { [$0] } ?? [])
                eof = true
                if status != nil { finish() }
            }
        }

        /// The process is gone. A child holding the pipe open (a plugin)
        /// gets two seconds to let go, as `Git.runBlocking` gives it.
        func exited(_ code: Int32) {
            let waiting = lock.withLock {
                status = code
                if eof { finish() }
                return !eof
            }
            guard waiting else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in lock.withLock { finish() } }
        }

        /// Under the lock.
        private func yield(_ data: [Data]) {
            guard !data.isEmpty, !finished else { return }
            let lines = data.map { String(decoding: $0, as: UTF8.self) }
            last = Array((last + lines).suffix(4))
            continuation.yield(lines)
        }

        /// Under the lock.
        private func finish() {
            guard !finished, let status else { return }
            finished = true
            if success.contains(status) {
                continuation.finish()
            } else {
                continuation.finish(throwing: GitError(arguments: arguments, status: status, stderr: last.joined(separator: "\n")))
            }
        }
    }

    static func environment(for endpoint: DockerEndpoint?, executable: URL) -> [String] {
        let folder = executable.deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let engine = (endpoint?.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return engine + ["PATH=\(folder):\(path)"]
    }

    /// A runtime's own word on whether it is up, or `.unknown` when its tool
    /// isn't there or says nothing readable.
    static func status(of runtime: DockerRuntime, endpoint: DockerEndpoint?) async -> DockerRuntime.Status {
        guard let (tool, arguments) = runtime.statusCommand(context: endpoint?.context),
            let cli = DockerCLI(tool, endpoint: tool == "docker" ? endpoint : nil)
        else { return .unknown }
        // Colima exits 1 while stopped; its silence is the answer.
        guard let output = try? await cli.run(arguments, success: [0, 1], timeout: 10) else { return .unknown }
        return runtime.status(fromOutput: output)
    }
}
