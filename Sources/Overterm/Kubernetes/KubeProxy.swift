import CryptoKit
import Darwin
import Foundation

/// What every `kubectl proxy` Overterm starts is told — decision 12 and
/// docs/design/kubernetes/analysis.md, Section 4. Pure.
///
/// The socket is a credential for the cluster to any process running as
/// this user, so what it lets through is decided here, not in the page:
/// - **every** context's proxy refuses exec, attach, port-forward and the
///   pod, service and node proxy subresources (and KubeVirt's console):
///   Overterm never uses them through the socket — shells and forwards are
///   kubectl processes of their own — and a GET there reaches a process in
///   the cluster. `--reject-paths` replaces kubectl's defaults, so the
///   list repeats them;
/// - a **read-only** context's (remote and production, by default) also
///   refuses every write method, POST included: a path can't tell a
///   permission review from a create;
/// - only `Host: localhost` is answered — what `UnixHTTPTransport.kubernetes`
///   sends.
///
/// kubectl matches the filters on the decoded path, unanchored, so each
/// pattern starts with `^`; a path with `//` or `/./` is redirected by its
/// mux before it is proxied, never passed on.
///
/// Nothing outside Overterm may switch them off: kubectl (1.33+) reads
/// `~/.kube/kuberc`, whose `defaults` set any flag the command line leaves
/// out — `disable-filter: true` there would turn every filter off. So
/// `--disable-filter=false` is always given, and kubectl is started with
/// kuberc off (`KubeProxyEnvironment`).
enum KubeProxyFlags {
    static let rejectedPaths = [
        #"^/api/.*/pods/.*/(exec|attach|portforward|proxy)"#,
        #"^/api/.*/services/.*/proxy"#,
        #"^/api/.*/nodes/.*/proxy"#,
        #"^/apis/subresources\.kubevirt\.io/"#,
    ]
    static let rejectedMethods = #"^(POST|PUT|PATCH|DELETE|CONNECT)$"#
    static let acceptedHosts = #"^localhost$"#

    /// kubectl's arguments: the context named explicitly (Overterm never
    /// relies on, or changes, the current one), a cache folder of the run's
    /// own when given, then the proxy on its socket with the filters.
    static func arguments(context: String, socket: String, readOnly: Bool, cacheDirectory: String? = nil) -> [String] {
        var arguments = ["--context=\(context)"]
        if let cacheDirectory { arguments.append("--cache-dir=\(cacheDirectory)") }
        arguments += [
            "proxy",
            "--unix-socket=\(socket)",
            "--disable-filter=false",
            "--accept-hosts=\(acceptedHosts)",
            "--reject-paths=\(rejectedPaths.joined(separator: ","))",
        ]
        if readOnly { arguments.append("--reject-methods=\(rejectedMethods)") }
        return arguments
    }

    /// What kubectl prints once its socket listens.
    static func isReady(_ line: String) -> Bool { line.hasPrefix("Starting to serve on ") }
}

/// Where the proxies' sockets are: a private folder under `/tmp`, one for
/// this process, each socket named by a short hash of its context.
///
/// Not the support folder: there the path was 132 bytes and kubectl's bind
/// failed (the spike) — a unix socket's path is 104 bytes with its NUL, and
/// an EKS context's name is an ARN. The folder is the user's alone (0700,
/// checked: owned by this user, not a symlink), as kubectl's own umask
/// makes the socket; it is removed at quit, and what a crashed run left is
/// swept when the next one makes its own.
struct KubeSocketFolder: Sendable {
    /// `sun_path` holds 104 bytes, its NUL among them.
    static let maxPathBytes = 103
    static let prefix = "ot-kube-"

    let base: URL
    let uid: uid_t
    let pid: pid_t

    init(base: URL = URL(fileURLWithPath: "/tmp", isDirectory: true), uid: uid_t = getuid(), pid: pid_t = getpid()) {
        self.base = base
        self.uid = uid
        self.pid = pid
    }

    /// The app's.
    static let app = KubeSocketFolder()

    var path: String { base.appendingPathComponent("\(Self.prefix)\(uid)-\(pid)", isDirectory: true).path }

    /// The socket's file name: the context's SHA-256, its first 12 hex digits.
    static func name(for context: String) -> String {
        SHA256.hash(data: Data(context.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    /// The socket's path for `context` — throws when it would be too long
    /// for a unix socket (a base folder deep in a temporary directory).
    func socket(for context: String) throws -> String {
        let socket = (path as NSString).appendingPathComponent(Self.name(for: context))
        guard socket.utf8.count <= Self.maxPathBytes else {
            throw KubeProxyProblem.socket("The socket's path would be \(socket.utf8.count) bytes; a unix socket's is \(Self.maxPathBytes) at most.")
        }
        return socket
    }

    /// Makes the folder (0700), or checks the one there: a directory, not a
    /// link, owned by this user, nobody else's to open — a folder someone
    /// else made in /tmp first is refused, never used.
    @discardableResult
    func prepare() throws -> String {
        sweepStale()
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw KubeProxyProblem.socket("Overterm couldn't make \(path): \(String(cString: strerror(errno))).")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw KubeProxyProblem.socket("\(path) isn't a folder.")
        }
        guard info.st_uid == uid else { throw KubeProxyProblem.socket("\(path) belongs to someone else; Overterm won't put a socket there.") }
        if info.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 {
            throw KubeProxyProblem.socket("\(path) couldn't be made private.")
        }
        return path
    }

    /// kubectl's HOME in a guarded run: a folder of the run's own, inside
    /// this one, so no file under the user's home is read.
    var isolatedHome: String { (path as NSString).appendingPathComponent("home") }

    /// Makes `isolatedHome` (0700) once the folder is prepared.
    func prepareIsolatedHome(_ home: String) throws {
        if mkdir(home, 0o700) != 0, errno != EEXIST {
            throw KubeProxyProblem.socket("Overterm couldn't make \(home): \(String(cString: strerror(errno))).")
        }
    }

    /// Removes the folder and what is in it: at quit, after every proxy closed.
    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The folders of this user's runs whose process is gone.
    func sweepStale() {
        let own = "\(Self.prefix)\(uid)-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where name.hasPrefix(own) {
            guard let other = pid_t(name.dropFirst(own.count)), other != pid, kill(other, 0) != 0, errno == ESRCH else { continue }
            let folder = base.appendingPathComponent(name).path
            var info = stat()
            guard lstat(folder, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFDIR else { continue }
            try? FileManager.default.removeItem(atPath: folder)
        }
    }
}

/// The environment a kubectl Overterm starts gets: the login shell's (a
/// Dock-launched app's PATH has no `aws`, no `kubectl-oidc_login`), with
/// `KUBECONFIG` set to exactly the files Overterm reads. Pure.
///
/// Guarded — an isolated run or a unit test — it is only the files given
/// (a scenario's `OVERTERM_KUBECONFIG`), never one under `~/.kube`, and
/// none at all is no environment: the caller then starts nothing. An
/// inherited `KUBECONFIG` is replaced, and the `AWS_*` variables go (a
/// test reaches no account); `HOME` is the run's own folder
/// (`isolatedHome`), so nothing under the user's `~/.kube` or `~/.aws` is
/// read either.
///
/// Always: kuberc is off (`KUBERC=off`, and `KUBECTL_KUBERC=false` for
/// the releases where it was a feature gate) — whatever the login shell
/// exported — so no kuberc of the user's sets a flag of the proxy's.
enum KubeProxyEnvironment {
    static func make(
        base: [String: String], kubeconfigs: [URL], guarded: Bool, home: URL, isolatedHome: String? = nil
    ) -> [String: String]? {
        var environment = base
        environment.removeValue(forKey: "KUBECONFIG")
        environment["KUBERC"] = "off"
        environment["KUBECTL_KUBERC"] = "false"
        let list = kubeconfigs.map(\.path).joined(separator: ":")
        if guarded {
            guard !kubeconfigs.isEmpty, !kubeconfigs.contains(where: { KubeconfigSources.isUsersOwn($0, home: home) }) else { return nil }
            for key in environment.keys where key.hasPrefix("AWS_") { environment.removeValue(forKey: key) }
            environment["KUBECONFIG"] = list
            if let isolatedHome { environment["HOME"] = isolatedHome }
            return environment
        }
        if !kubeconfigs.isEmpty { environment["KUBECONFIG"] = list }
        return environment
    }
}

/// How a context's user signs in, as far as the proxy's errors are concerned.
enum KubeSignIn: Hashable, Sendable {
    case none
    /// kubelogin: a browser and a listener on 127.0.0.1:8000 — one at a time.
    case oidc
    /// `aws eks get-token`: an expired SSO session is `aws sso login`.
    case aws(profile: String?)
    /// Another credential plugin, by its name.
    case plugin(String)

    init(_ auth: KubeAuth?) {
        guard case .exec(let exec) = auth else {
            self = .none
            return
        }
        if exec.isOIDCLogin {
            self = .oidc
        } else if exec.name == "aws" {
            self = .aws(profile: Self.profile(in: exec.arguments))
        } else {
            self = .plugin(exec.name)
        }
    }

    /// `--profile p` or `--profile=p`.
    static func profile(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--profile", index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix("--profile=") { return String(argument.dropFirst("--profile=".count)) }
        }
        return nil
    }

    var pluginName: String? {
        switch self {
        case .none: nil
        case .oidc: "kubectl oidc-login"
        case .aws: "aws"
        case .plugin(let name): name
        }
    }
}

/// One proxy, as it is to be started: everything `kubectl proxy` is given.
struct KubeProxySpec: Hashable, Sendable {
    var context: String
    var readOnly: Bool
    var kubectl: URL
    var socket: String
    var environment: [String: String]
    /// A cache folder of the run's own (an isolated run, a test).
    var cacheDirectory: String?
    var signIn: KubeSignIn
    /// The metrics proxy's (stage 4): only this Prometheus Service's query
    /// paths, GETs only (`KubePrometheusFlags`), on a socket of its own.
    var prometheus: KubePrometheusService? = nil

    var arguments: [String] {
        if let prometheus {
            return KubePrometheusFlags.arguments(context: context, socket: socket, service: prometheus, cacheDirectory: cacheDirectory)
        }
        return KubeProxyFlags.arguments(context: context, socket: socket, readOnly: readOnly, cacheDirectory: cacheDirectory)
    }

    /// This context's metrics proxy: the same kubectl, environment and
    /// credentials, its own socket beside the context's, read-only.
    func metrics(_ service: KubePrometheusService) throws -> KubeProxySpec {
        var spec = self
        spec.prometheus = service
        spec.readOnly = true
        spec.socket = try KubePrometheusFlags.socket(beside: socket)
        return spec
    }

    /// Ready when kubectl says it serves; its socket removed before (one a
    /// dead proxy left) and when it is closed — kubectl leaves it.
    var launch: ManagedProcess.Launch {
        ManagedProcess.Launch(
            executable: kubectl, arguments: arguments, environment: environment, readiness: .line(KubeProxyFlags.isReady), timeout: 20,
            removing: [socket])
    }
}

extension UnixHTTPTransport {
    /// A context's proxy: `Host: localhost` or it answers 403, `/version` to
    /// say it's there.
    static func kubernetes(socket: String, context: String) -> UnixHTTPTransport {
        UnixHTTPTransport(address: .unix(socket), host: "localhost", readinessPath: "/version", service: "kubectl proxy for \(context)")
    }
}

/// A running `kubectl proxy`: the transport to its socket, what kubectl
/// said on stderr (an exec plugin's own errors land there), closed by its
/// pid. Tests make one over any transport.
final class KubeProxy: ManagedResource {
    let context: String
    let readOnly: Bool
    let signIn: KubeSignIn
    let transport: any HTTPTransport
    /// kubectl's pid; nil for a test's.
    let pid: pid_t?
    private let running: @Sendable () -> Bool
    private let said: @Sendable () -> String
    private let ending: @Sendable () -> Void

    init(
        context: String, readOnly: Bool, signIn: KubeSignIn, transport: any HTTPTransport, pid: pid_t? = nil,
        isRunning: @escaping @Sendable () -> Bool, stderr: @escaping @Sendable () -> String = { "" }, close: @escaping @Sendable () -> Void
    ) {
        self.context = context
        self.readOnly = readOnly
        self.signIn = signIn
        self.transport = transport
        self.pid = pid
        self.running = isRunning
        self.said = stderr
        self.ending = close
    }

    var isOpen: Bool { running() }
    var stderr: String { said() }
    func close() { ending() }

    /// Starts kubectl and returns once it serves — or throws why not.
    static func open(_ spec: KubeProxySpec) async throws -> KubeProxy {
        do {
            let process = try await ManagedProcess.start(spec.launch)
            return KubeProxy(
                context: spec.context, readOnly: spec.readOnly, signIn: spec.signIn,
                transport: UnixHTTPTransport.kubernetes(socket: spec.socket, context: spec.context), pid: process.pid,
                isRunning: { process.isRunning }, stderr: { process.stderr.text }, close: { process.close() })
        } catch ManagedProcess.Failure.couldNotStart(let reason) {
            throw KubeProxyProblem.proxyFailed("kubectl couldn't start: \(reason)")
        } catch ManagedProcess.Failure.exited(let status, let stderr) {
            throw KubeProxyProblem.proxyFailed(KubeProxyProblem.lastLine(of: stderr) ?? "kubectl proxy exited (\(status)).")
        } catch ManagedProcess.Failure.timedOut {
            throw KubeProxyProblem.proxyFailed("kubectl proxy didn't start in 20 seconds.")
        }
    }
}
