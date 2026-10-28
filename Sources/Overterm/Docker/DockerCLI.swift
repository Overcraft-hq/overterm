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
    /// its credential helpers and plugins.
    func run(_ arguments: [String], success: Set<Int32> = [0], timeout: TimeInterval = 30) async throws -> String {
        try await Git.run(
            URL(fileURLWithPath: "/usr/bin/env"), Self.environment(for: endpoint, executable: executable) + [executable.path] + arguments,
            in: FileManager.default.homeDirectoryForCurrentUser, success: success, timeout: timeout)
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
