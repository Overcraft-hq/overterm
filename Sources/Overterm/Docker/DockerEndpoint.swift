import CryptoKit
import Foundation

/// Where Docker's engine answers, found the way the `docker` CLI finds it,
/// so Overterm talks to the engine the user's terminal does:
///
/// 1. `DOCKER_HOST`;
/// 2. `DOCKER_CONTEXT`, else `currentContext` in `~/.docker/config.json`;
/// 3. that context's record, `~/.docker/contexts/meta/<sha256(name)>/meta.json`
///    (`Endpoints.docker.Host`) — `default` has none;
/// 4. `unix:///var/run/docker.sock`.
///
/// Pure once the files are read (`resolve` takes them as values).
struct DockerEndpoint: Equatable, Sendable {
    enum Address: Equatable, Sendable {
        case unix(String)
        case tcp(host: String, port: Int)
        /// `ssh://user@host` and the like: a remote engine, not reached
        /// directly (the plan's third stage).
        case unsupported(String)
    }

    var address: Address
    /// The context it came from (`desktop-linux`, `orbstack`, `colima`), or
    /// nil for `DOCKER_HOST` and the default.
    var context: String?
    /// Why this one: "DOCKER_HOST", "context desktop-linux", "default".
    var source: String

    static let defaultHost = "unix:///var/run/docker.sock"

    /// `unix:///path`, `tcp://host:port`, `http://host:port`; anything else
    /// is unsupported, kept as written.
    static func address(of host: String) -> Address {
        if host.hasPrefix("unix://") { return .unix(String(host.dropFirst("unix://".count))) }
        for scheme in ["tcp://", "http://"] where host.hasPrefix(scheme) {
            let rest = host.dropFirst(scheme.count).split(separator: "/").first.map(String.init) ?? ""
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            let port = parts.count > 1 ? Int(parts[parts.count - 1]) ?? 2375 : 2375
            let name = parts.count > 1 ? parts.dropLast().joined(separator: ":") : rest
            return .tcp(host: name.isEmpty ? "127.0.0.1" : name, port: port)
        }
        return .unsupported(host)
    }

    /// The context's record's folder name.
    static func metaFolder(for context: String) -> String {
        SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What the files say, in the CLI's order. `contextHost` answers a
    /// context's endpoint from its record (nil: no record).
    static func resolve(
        environment: [String: String], currentContext: String?, contextHost: (String) -> String?
    ) -> DockerEndpoint {
        if let host = environment["DOCKER_HOST"], !host.isEmpty {
            return DockerEndpoint(address: address(of: host), context: nil, source: "DOCKER_HOST")
        }
        let context = environment["DOCKER_CONTEXT"].flatMap { $0.isEmpty ? nil : $0 } ?? currentContext
        if let context, context != "default", let host = contextHost(context) {
            return DockerEndpoint(address: address(of: host), context: context, source: "context \(context)")
        }
        return DockerEndpoint(address: address(of: defaultHost), context: nil, source: "default")
    }

    /// The endpoint for this Mac: the environment Overterm was started with,
    /// `~/.docker`, as the CLI reads them. `docker` is `~/.docker` (an
    /// isolated run hands in its own).
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment, docker: URL = home) -> DockerEndpoint {
        let config = (try? Data(contentsOf: docker.appendingPathComponent("config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return resolve(environment: environment, currentContext: config?["currentContext"] as? String) {
            contextHost($0, docker: docker)
        }
    }

    static var home: URL {
        if let dir = ProcessInfo.processInfo.environment["DOCKER_CONFIG"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker")
    }

    static func contextHost(_ context: String, docker: URL) -> String? {
        let meta = docker.appendingPathComponent("contexts/meta/\(metaFolder(for: context))/meta.json")
        guard let data = try? Data(contentsOf: meta), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ((json["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String
    }

    /// Every context there is, by name, for the switcher; the default first.
    static func contexts(docker: URL = home) -> [(name: String, host: String)] {
        let folder = docker.appendingPathComponent("contexts/meta")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var result: [(String, String)] = [("default", defaultHost)]
        for name in names.sorted() {
            let meta = folder.appendingPathComponent(name).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let context = json["Name"] as? String,
                let host = ((json["Endpoints"] as? [String: Any])?["docker"] as? [String: Any])?["Host"] as? String
            else { continue }
            result.append((context, host))
        }
        return result
    }
}

/// Which engine is answering: what its socket and its `/info` say. The
/// panel names it and knows how to start and stop it.
enum DockerRuntime: String, Equatable, Sendable {
    case dockerDesktop, orbStack, colima, rancherDesktop, podman, engine

    var name: String {
        switch self {
        case .dockerDesktop: "Docker Desktop"
        case .orbStack: "OrbStack"
        case .colima: "Colima"
        case .rancherDesktop: "Rancher Desktop"
        case .podman: "Podman"
        case .engine: "Docker Engine"
        }
    }

    /// From the socket's path, the context's name and `/info`'s
    /// OperatingSystem (Docker Desktop and OrbStack say who they are there).
    static func of(_ endpoint: DockerEndpoint, operatingSystem: String? = nil) -> DockerRuntime {
        let os = operatingSystem?.lowercased() ?? ""
        let path: String = {
            if case .unix(let path) = endpoint.address { return path.lowercased() }
            return ""
        }()
        let context = endpoint.context?.lowercased() ?? ""
        if os.contains("docker desktop") || path.contains("/.docker/run/") || context == "desktop-linux" { return .dockerDesktop }
        if os.contains("orbstack") || path.contains("/.orbstack/") || context == "orbstack" { return .orbStack }
        if path.contains("/.colima/") || context.hasPrefix("colima") { return .colima }
        if path.contains("/.rd/") || context == "rancher-desktop" { return .rancherDesktop }
        if path.contains("podman") || context.contains("podman") { return .podman }
        return .engine
    }

    /// What starts it, stops it and restarts it, as commands — run in a
    /// terminal tab so the user sees them. Nil where there is no command.
    func command(_ action: Action, context: String? = nil) -> String? {
        let profile = context.flatMap { $0.hasPrefix("colima-") ? " --profile \($0.dropFirst("colima-".count))" : nil } ?? ""
        switch (self, action) {
        case (.dockerDesktop, _): return "docker desktop \(action.rawValue)"
        case (.orbStack, _): return "orb \(action.rawValue)"
        case (.colima, _): return "colima \(action.rawValue)\(profile)"
        case (.podman, .start): return "podman machine start"
        case (.podman, .stop): return "podman machine stop"
        case (.podman, .restart): return "podman machine stop && podman machine start"
        case (.rancherDesktop, .start): return "open -a 'Rancher Desktop'"
        default: return nil
        }
    }

    enum Action: String, Sendable { case start, stop, restart }
}
