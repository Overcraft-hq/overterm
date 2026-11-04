import Foundation

/// Which kubectl runs the proxy — decision 22: an installed copy, never a
/// download. The candidates are `kubernetes.kubectlPath` (which, set,
/// overrides), where installers put it (`/usr/local/bin`,
/// `/opt/homebrew/bin`, Docker Desktop's bundle), then the login shell's
/// PATH — one file each, symlinks followed (`/usr/local/bin/kubectl` is
/// often Docker Desktop's). Once the server's minor is known, the copy
/// closest to it is chosen (kubectl's skew policy is ±1).
///
/// An isolated run or a unit test uses only the configured path: a
/// scenario's stand-in, or nothing.
enum KubectlLocator {
    static func knownFolders(home: URL) -> [String] {
        ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin", home.appendingPathComponent(".rd/bin").path]
    }

    static func candidates(
        configured: String, guarded: Bool, loginPath: String?, home: URL,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile,
        resolve: (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) -> [URL] {
        let configured = configured.trimmingCharacters(in: .whitespaces)
        let own = KubeconfigSources.expand(configured, home: home)
        if guarded { return own.map { isExecutable($0.path) ? [$0] : [] } ?? [] }
        let folders = knownFolders(home: home) + (loginPath ?? "").split(separator: ":").map(String.init)
        var found: [URL] = own.map { [$0] } ?? []
        found += folders.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).appendingPathComponent("kubectl") }
        var seen = Set<String>()
        return found.filter { isExecutable($0.path) && seen.insert(resolve($0).path).inserted }
    }

    /// The one to use: the configured one when it is set, else the closest
    /// to the server's minor (the first of equals), else the first.
    static func choose(_ candidates: [(url: URL, minor: Int?)], serverMinor: Int?, configured: Bool) -> URL? {
        guard let first = candidates.first else { return nil }
        guard !configured, let serverMinor else { return first.url }
        var best: (url: URL, distance: Int)?
        for candidate in candidates {
            guard let minor = candidate.minor else { continue }
            let distance = abs(minor - serverMinor)
            if best == nil || distance < best!.distance { best = (candidate.url, distance) }
        }
        return best?.url ?? first.url
    }
}

/// The kubectls this Mac has, their client versions asked once each
/// (`kubectl version --client -o json`, which reaches no server).
actor Kubectls {
    static let shared = Kubectls()

    private var minors: [String: Int?] = [:]

    func choose(_ candidates: [URL], serverMinor: Int?, configured: Bool, environment: [String: String]) async -> URL? {
        guard candidates.count > 1, serverMinor != nil, !configured else {
            return KubectlLocator.choose(candidates.map { ($0, nil) }, serverMinor: nil, configured: configured)
        }
        var versions: [(url: URL, minor: Int?)] = []
        for candidate in candidates {
            if minors[candidate.path] == nil { minors[candidate.path] = await Self.clientMinor(candidate, environment: environment) }
            versions.append((candidate, minors[candidate.path] ?? nil))
        }
        return KubectlLocator.choose(versions, serverMinor: serverMinor, configured: configured)
    }

    static func clientMinor(_ kubectl: URL, environment: [String: String]) async -> Int? {
        let data = await KubeBlocking.run { ShellEnvironment.run(kubectl, ["version", "--client", "-o", "json"], environment: environment, timeout: 10) }
        return data.flatMap { KubeVersion.minor($0, under: "clientVersion") }
    }
}

/// Blocking work — a shell asked, a process waited for — on a GCD thread,
/// never on a Swift-concurrency one (the cooperative pool starves).
enum KubeBlocking {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in enqueue(work, continuation) }
    }

    /// Built here, outside any actor: the block runs on a global queue.
    nonisolated private static func enqueue<T: Sendable>(_ work: @escaping @Sendable () -> T, _ continuation: CheckedContinuation<T, Never>) {
        let block: @Sendable () -> Void = { continuation.resume(returning: work()) }
        DispatchQueue.global(qos: .userInitiated).async(execute: block)
    }
}

/// A kubectl to run for a context, and what it is given.
struct KubectlTool: Sendable, Equatable {
    var kubectl: URL
    var environment: [String: String]
    /// A cache folder of the run's own (an isolated run, a test).
    var cacheDirectory: String?
}

/// How a context's proxy is made: which kubectl, its environment, its
/// socket, and the checks before anything starts — a plugin that isn't
/// installed, one that needs a terminal.
struct KubeProxyPlanner: Sendable {
    var folder: KubeSocketFolder = .app
    /// An isolated run or a unit test: only OVERTERM_KUBECONFIG, only the configured kubectl.
    var guarded: Bool = AppEnvironment.guardsKubeconfig
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// The kubeconfig files; blocking the first time (the shell is asked).
    var kubeconfigs: @Sendable ([String]) -> [URL] = { AppEnvironment.kubeconfigs(extra: $0) }
    /// The environment kubectl starts from: the login shell's, blocking the
    /// first time — the process's own when guarded (a unit test asks no
    /// shell of the user's).
    var baseEnvironment: @Sendable () -> [String: String] = {
        AppEnvironment.guardsKubeconfig ? ProcessInfo.processInfo.environment : ShellEnvironment.environment()
    }
    var kubectls: Kubectls = .shared

    func plan(_ context: KubeContext, configuration: KubeProxies.Configuration, serverMinor: Int?) async throws -> KubeProxySpec {
        let tool = try await tool(context, configuration: configuration, serverMinor: serverMinor)
        let socket = try folder.socket(for: context.name)
        return KubeProxySpec(
            context: context.name, readOnly: !context.isWritable, kubectl: tool.kubectl, socket: socket, environment: tool.environment,
            cacheDirectory: tool.cacheDirectory, signIn: KubeSignIn(context.auth))
    }

    /// Which kubectl a short-lived process for `context` runs (`kubectl auth
    /// can-i`), with what environment — the proxy's: Overterm's kubeconfig
    /// files as `KUBECONFIG`, kuberc off, and guarded the run's own HOME and
    /// cache. The same checks first: a plugin that isn't installed, one
    /// that needs a terminal.
    func tool(_ context: KubeContext, configuration: KubeProxies.Configuration, serverMinor: Int?) async throws -> KubectlTool {
        if case .exec(let exec) = context.auth, exec.interactiveMode == "Always" { throw KubeProxyProblem.needsTerminal(context: context.name) }
        let guarded = self.guarded
        let home = self.home
        let kubeconfigs = self.kubeconfigs
        let base = self.baseEnvironment
        let extra = configuration.extraKubeconfigs
        // Guarded, kubectl's HOME is the run's own folder: not the user's.
        let isolatedHome = guarded ? folder.isolatedHome : nil
        let environment = await KubeBlocking.run { () -> [String: String]? in
            let files = kubeconfigs(extra)
            // Guarded with none to read: nothing is asked, nothing starts.
            if guarded && files.isEmpty { return nil }
            return KubeProxyEnvironment.make(base: base(), kubeconfigs: files, guarded: guarded, home: home, isolatedHome: isolatedHome)
        }
        guard let environment else { throw KubeProxyProblem.noKubeconfig }
        if case .exec(let exec) = context.auth, !Self.isInstalled(exec, in: environment) {
            throw KubeProxyProblem.pluginMissing(exec.name, hint: exec.installHint)
        }
        let candidates = KubectlLocator.candidates(
            configured: configuration.kubectlPath, guarded: guarded, loginPath: environment["PATH"], home: home)
        let configured = !configuration.kubectlPath.trimmingCharacters(in: .whitespaces).isEmpty
        guard let kubectl = await kubectls.choose(candidates, serverMinor: serverMinor, configured: configured, environment: environment) else {
            throw KubeProxyProblem.noKubectl
        }
        try folder.prepare()
        if let isolatedHome { try folder.prepareIsolatedHome(isolatedHome) }
        let cache = guarded ? (folder.path as NSString).appendingPathComponent("cache") : nil
        return KubectlTool(kubectl: kubectl, environment: environment, cacheDirectory: cache)
    }

    /// Whether the plugin's command is there: a path that is executable, or
    /// a name on the environment's PATH — for `kubectl oidc-login`, kubectl's
    /// plugin `kubectl-oidc_login` too.
    static func isInstalled(
        _ exec: KubeExec, in environment: [String: String], isExecutable: (String) -> Bool = FileManager.default.isExecutableFile
    ) -> Bool {
        func found(_ command: String) -> Bool {
            command.contains("/")
                ? isExecutable(command) : ShellEnvironment.executable(command, in: environment, isExecutable: isExecutable) != nil
        }
        let tool = (exec.command as NSString).lastPathComponent
        if tool == "kubectl", let sub = exec.arguments.first, !sub.hasPrefix("-") {
            // kubectl itself is the proxy's; its plugin must be on the PATH.
            return found("kubectl-" + sub.replacingOccurrences(of: "-", with: "_"))
        }
        return found(exec.command)
    }
}
