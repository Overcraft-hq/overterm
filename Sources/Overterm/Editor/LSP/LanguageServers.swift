import Foundation

/// Which language server a file gets, and the running ones: one per
/// language spec and workspace root, started on first use.
///
/// When none can be found — not installed, or it keeps dying — `server(for:)`
/// is nil and the editor goes on without one (buffer-word completion).
@MainActor
final class LanguageServers {
    static let shared = LanguageServers()

    /// One kind of server: the files it takes, how to find its root, and
    /// where its executable may be.
    struct Spec: Sendable, Hashable {
        /// "go", "typescript", "c"… — also its key here.
        var id: String
        /// Lowercased extension → LSP language id.
        var extensions: [String: String]
        /// Whole file names (no extension to go by) → LSP language id.
        var fileNames: [String: String] = [:]
        /// Files whose directory is the project root, nearest first.
        var rootMarkers: [String] = []
        /// Tried in order; the first found is used.
        var launch: [ServerDiscovery.Candidate]
    }

    nonisolated static let specs: [Spec] = [
        Spec(
            id: "go", extensions: ["go": "go"], fileNames: ["go.mod": "go.mod"], rootMarkers: ["go.work", "go.mod"],
            launch: [.executable("gopls"), .zedGopls]),
        Spec(
            id: "typescript",
            extensions: [
                "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
                "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
            ],
            rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
            launch: [
                .executable("typescript-language-server", ["--stdio"]), .executable("vtsls", ["--stdio"]),
                .zedNode("vtsls/node_modules/@vtsls/language-server/bin/vtsls.js", ["--stdio"]),
            ]),
        Spec(
            id: "python", extensions: ["py": "python", "pyi": "python"],
            rootMarkers: ["pyproject.toml", "setup.py", "setup.cfg", "pyrightconfig.json", "requirements.txt"],
            launch: [
                .executable("basedpyright-langserver", ["--stdio"]), .executable("pyright-langserver", ["--stdio"]),
                .zedNode("basedpyright/node_modules/basedpyright/langserver.index.js", ["--stdio"]),
            ]),
        Spec(id: "rust", extensions: ["rs": "rust"], rootMarkers: ["Cargo.toml"], launch: [.executable("rust-analyzer")]),
        Spec(
            id: "swift", extensions: ["swift": "swift"], rootMarkers: ["Package.swift", "buildServer.json", "compile_commands.json"],
            launch: [.xcrun("sourcekit-lsp")]),
        Spec(
            id: "c",
            extensions: [
                "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "c++": "cpp", "hh": "cpp", "hpp": "cpp", "hxx": "cpp",
                "m": "objective-c", "mm": "objective-cpp",
            ],
            rootMarkers: ["compile_commands.json", "compile_flags.txt", ".clangd"],
            launch: [.executable("clangd"), .xcrun("clangd")]),
        Spec(
            id: "json", extensions: ["json": "json", "jsonc": "jsonc"],
            fileNames: ["tsconfig.json": "jsonc", "jsconfig.json": "jsonc", ".eslintrc.json": "jsonc"],
            launch: [
                .executable("vscode-json-language-server", ["--stdio"]),
                .zedNode("json-language-server/node_modules/vscode-langservers-extracted/bin/vscode-json-language-server", ["--stdio"]),
            ]),
        Spec(
            id: "yaml", extensions: ["yaml": "yaml", "yml": "yaml"],
            launch: [
                .executable("yaml-language-server", ["--stdio"]),
                .zedNode("yaml-language-server/node_modules/yaml-language-server/bin/yaml-language-server", ["--stdio"]),
            ]),
        Spec(
            id: "bash", extensions: ["sh": "shellscript", "bash": "shellscript", "zsh": "shellscript"],
            fileNames: [
                ".bashrc": "shellscript", ".bash_profile": "shellscript", ".zshrc": "shellscript", ".zprofile": "shellscript",
                ".profile": "shellscript",
            ],
            launch: [
                .executable("bash-language-server", ["start"]),
                .zedNode("bash-language-server/node_modules/bash-language-server/out/cli.js", ["start"]),
            ]),
    ]

    /// The spec whose files these are.
    nonisolated static func spec(for url: URL) -> Spec? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        // A file name first: tsconfig.json is JSON with comments.
        if let spec = specs.first(where: { $0.fileNames[name] != nil }) { return spec }
        guard !ext.isEmpty else { return nil }
        return specs.first { $0.extensions[ext] != nil }
    }

    /// The LSP language id for didOpen: go, typescript, typescriptreact,
    /// javascript, javascriptreact, python, rust, swift, c, cpp, objective-c,
    /// objective-cpp, json, jsonc, yaml, shellscript. go.mod is "go.mod".
    nonisolated static func languageID(for url: URL) -> String? {
        guard let spec = spec(for: url) else { return nil }
        return spec.fileNames[url.lastPathComponent] ?? spec.extensions[url.pathExtension.lowercased()]
    }

    /// The workspace a file belongs to: the nearest directory holding one of
    /// the language's markers, else the git checkout's top, else its folder.
    nonisolated static func root(for url: URL, markers: [String], fileManager: FileManager = .default) -> URL {
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        func nearest(_ names: [String]) -> URL? {
            var directory = folder
            // Bounded, and stopping at "/": the root's deletingLastPathComponent
            // is "/../", never "/" again — compared by path, the walk went on
            // up "/../../…" forever and took the machine's memory with it.
            for _ in 0..<256 {
                if names.contains(where: { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) { return directory }
                if directory.pathComponents.count <= 1 { return nil }
                directory = directory.deletingLastPathComponent().standardizedFileURL
            }
            return nil
        }
        return (markers.isEmpty ? nil : nearest(markers)) ?? nearest([".git"]) ?? folder
    }

    /// Replaces discovery entirely — the end-to-end tests hand in a fake
    /// server. An isolated run or a unit test without one finds nothing: it
    /// must never launch the user's real servers.
    var discoveryOverride: ((Spec) -> LanguageServer.Command?)?
    /// Every server's diagnostics, on the main actor.
    var onDiagnostics: ((URL, [LSP.Diagnostic]) -> Void)?

    /// Deaths (or failed starts) per spec before it is left alone for the
    /// rest of the run: the first restart is free, the next isn't made.
    static let maxFailures = 2

    private let discovery: ServerDiscovery
    private let launchesRealServers: Bool
    private var servers: [String: LanguageServer] = [:]
    private var commands: [String: LanguageServer.Command?] = [:]
    private var failures: [String: Int] = [:]

    init(discovery: ServerDiscovery = ServerDiscovery(), launchesRealServers: Bool = LanguageServers.mayLaunchRealServers) {
        self.discovery = discovery
        self.launchesRealServers = launchesRealServers
    }

    /// Not in an isolated run, nor inside a test process.
    nonisolated static var mayLaunchRealServers: Bool {
        !AppEnvironment.isIsolated && NSClassFromString("XCTestCase") == nil
    }

    /// The running servers, for diagnostics (Tab Info) and tests.
    var running: [LanguageServer] { Array(servers.values) }

    /// The server for this file, launched if it isn't yet — it may still be
    /// initializing; requests wait for that. nil when the language has none
    /// on this machine, or its server has failed for good. A server that
    /// died is restarted here, once per spec per run.
    func server(for url: URL) -> LanguageServer? {
        guard let spec = Self.spec(for: url), failures[spec.id, default: 0] < Self.maxFailures else { return nil }
        let root = Self.root(for: url, markers: spec.rootMarkers)
        let key = "\(spec.id)\u{0}\(root.path)"
        if let server = servers[key] {
            switch server.state {
            case .starting, .running:
                return server
            case .dead, .idle, .stopped:
                guard fail(spec) else {
                    servers[key] = nil
                    return nil
                }
                do {
                    try server.restart()
                    return server
                } catch {
                    _ = fail(spec)
                    servers[key] = nil
                    return nil
                }
            }
        }
        guard let command = command(for: spec) else { return nil }
        let server = LanguageServer(name: spec.id, command: command, root: root)
        server.onDiagnostics = { [weak self] url, diagnostics in self?.onDiagnostics?(url, diagnostics) }
        do {
            try server.start()
        } catch {
            _ = fail(spec)
            return nil
        }
        servers[key] = server
        return server
    }

    /// The server already running for this file, if any — never starts one.
    func existingServer(for url: URL) -> LanguageServer? {
        guard let spec = Self.spec(for: url) else { return nil }
        return servers["\(spec.id)\u{0}\(Self.root(for: url, markers: spec.rootMarkers).path)"]
    }

    /// Counts a failure; whether one more try is allowed.
    private func fail(_ spec: Spec) -> Bool {
        failures[spec.id, default: 0] += 1
        return failures[spec.id, default: 0] < Self.maxFailures
    }

    /// How this spec's server is launched on this machine, looked up once.
    func command(for spec: Spec) -> LanguageServer.Command? {
        if let discoveryOverride { return discoveryOverride(spec) }
        guard launchesRealServers else { return nil }
        if let known = commands[spec.id] { return known }
        let command = discovery.command(for: spec)
        commands[spec.id] = command
        return command
    }

    /// Ends every server (shutdown, exit, killed after 2 s), all at once.
    /// Blocks until they're gone or ~4.5 s have passed: for app termination.
    func stopAll() {
        let all = Array(servers.values)
        servers = [:]
        let group = DispatchGroup()
        for server in all {
            DispatchQueue.global().async(group: group) { server.stop() }
        }
        _ = group.wait(timeout: .now() + 4.5)
    }
}

/// Finds a server's executable. A GUI app's PATH has no Homebrew, so the
/// usual install places are searched by hand; then Xcode's toolchain; then
/// what Zed downloaded for itself (`~/Library/Application Support/Zed`),
/// run with whatever node there is.
struct ServerDiscovery: Sendable {
    enum Candidate: Sendable, Hashable {
        /// A binary in one of `searchDirectories`.
        case executable(String, [String] = [])
        /// A binary in the Xcode toolchain (sourcekit-lsp, clangd).
        case xcrun(String, [String] = [])
        /// Zed's gopls: `languages/gopls/gopls_<version>_go_<version>`.
        case zedGopls
        /// A script under Zed's `languages/`, run with node.
        case zedNode(String, [String])
    }

    var home: URL
    /// Absolute executables by spec id, ahead of everything else — for a
    /// setting naming one.
    var overrides: [String: LanguageServer.Command]
    var searchDirectories: [URL]
    /// Xcode's toolchains, looked in before asking xcrun.
    var toolchainDirectories: [URL]
    var runsXcrun: Bool

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, overrides: [String: LanguageServer.Command] = [:],
        searchDirectories: [URL]? = nil, toolchainDirectories: [URL]? = nil, runsXcrun: Bool = true
    ) {
        self.home = home
        self.overrides = overrides
        self.searchDirectories =
            searchDirectories
            ?? (["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0) }
                + ["go/bin", ".cargo/bin", ".local/bin"].map { home.appendingPathComponent($0) }
                + [URL(fileURLWithPath: "/usr/bin")])
        self.toolchainDirectories =
            toolchainDirectories
            ?? [
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
                "/Library/Developer/CommandLineTools/usr/bin",
            ].map { URL(fileURLWithPath: $0) }
        self.runsXcrun = runsXcrun
    }

    var zedDirectory: URL { home.appendingPathComponent("Library/Application Support/Zed") }

    func command(for spec: LanguageServers.Spec) -> LanguageServer.Command? {
        if let command = overrides[spec.id] { return command }
        for candidate in spec.launch {
            if let command = command(for: candidate) { return command }
        }
        return nil
    }

    /// The search directories on the server's PATH as well: gopls runs `go`,
    /// rust-analyzer `cargo`, and a node script `#!/usr/bin/env node`.
    var environment: [String: String] {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return ["PATH": (searchDirectories.map(\.path) + [path]).joined(separator: ":")]
    }

    func command(for candidate: Candidate) -> LanguageServer.Command? {
        switch candidate {
        case .executable(let name, let arguments):
            guard let executable = find(name) else { return nil }
            return LanguageServer.Command(executable: executable, arguments: arguments, environment: environment)
        case .xcrun(let name, let arguments):
            guard let executable = toolchain(name) else { return nil }
            return LanguageServer.Command(executable: executable, arguments: arguments, environment: environment)
        case .zedGopls:
            guard let executable = zedGopls() else { return nil }
            return LanguageServer.Command(executable: executable, environment: environment)
        case .zedNode(let script, let arguments):
            let script = zedDirectory.appendingPathComponent("languages").appendingPathComponent(script)
            guard FileManager.default.fileExists(atPath: script.path), let node = node() else { return nil }
            return LanguageServer.Command(executable: node, arguments: [script.path] + arguments, environment: environment)
        }
    }

    /// The first executable of that name in the search directories. A rustup
    /// proxy for a component that isn't installed only prints an error, so
    /// rust-analyzer in ~/.cargo/bin counts only if a toolchain has it.
    func find(_ name: String) -> URL? {
        for directory in searchDirectories {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if name == "rust-analyzer", url.resolvingSymlinksInPath().lastPathComponent == "rustup", !rustupHasRustAnalyzer() { continue }
            return url
        }
        return nil
    }

    private func rustupHasRustAnalyzer() -> Bool {
        let toolchains = home.appendingPathComponent(".rustup/toolchains")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: toolchains.path)) ?? []
        return names.contains { FileManager.default.isExecutableFile(atPath: toolchains.appendingPathComponent("\($0)/bin/rust-analyzer").path) }
    }

    /// In Xcode's (or the Command Line Tools') toolchain, else `xcrun --find`
    /// for another selected Xcode. xcrun only runs when developer tools are
    /// there at all — without them it offers to install them, in a dialog.
    func toolchain(_ name: String) -> URL? {
        for directory in toolchainDirectories {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        guard runsXcrun,
            FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools")
                || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        else { return nil }
        let output = try? Git.runBlocking(
            URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", name], in: home, success: [0], timeout: 5)
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// Zed keeps gopls as `languages/gopls/gopls_<gopls>_go_<go>` — the
    /// binary itself (a directory holding `gopls` is taken too). The newest.
    func zedGopls() -> URL? {
        let directory = zedDirectory.appendingPathComponent("languages/gopls")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.filter({ $0.hasPrefix("gopls_") }).sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let binary = isDirectory.boolValue ? url.appendingPathComponent("gopls") : url
            if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        }
        let gobin = directory.appendingPathComponent("gobin/gopls")
        return FileManager.default.isExecutableFile(atPath: gobin.path) ? gobin : nil
    }

    /// node from the search directories, else the one Zed downloaded
    /// (`node/node-v<version>-darwin-<arch>/bin/node`).
    func node() -> URL? {
        if let node = find("node") { return node }
        let directory = zedDirectory.appendingPathComponent("node")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.filter({ $0.hasPrefix("node-") }).sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            let node = directory.appendingPathComponent("\(name)/bin/node")
            if FileManager.default.isExecutableFile(atPath: node.path) { return node }
        }
        return nil
    }
}
