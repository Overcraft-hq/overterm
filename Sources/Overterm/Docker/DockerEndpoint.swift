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
        /// `ssh://user@host`: a remote engine, its socket forwarded here by
        /// the system's ssh (`DockerSSHForward`).
        case ssh(DockerSSHTarget)
        /// `npipe://` and the like: nothing a Mac reaches.
        case unsupported(String)
    }

    var address: Address
    /// The context it came from (`desktop-linux`, `orbstack`, `colima`), or
    /// nil for `DOCKER_HOST` and the default.
    var context: String?
    /// Why this one: "DOCKER_HOST", "context desktop-linux", "default".
    var source: String

    static let defaultHost = "unix:///var/run/docker.sock"

    /// As `DOCKER_HOST` spells it.
    var host: String {
        switch address {
        case .unix(let path): "unix://" + path
        case .tcp(let host, let port): "tcp://\(host.contains(":") ? "[\(host)]" : host):\(port)"
        case .ssh(let target): target.url
        case .unsupported(let host): host
        }
    }

    /// The host a remote engine runs on — where its published ports are —
    /// or nil for one on this Mac (its own socket, a VM's forwarded to
    /// localhost). For `ssh://`, the name as written; ~/.ssh/config may
    /// call it something else (`DockerModel.publishedHost`).
    var remoteHost: String? {
        switch address {
        case .tcp(let host, _): ["127.0.0.1", "localhost", "::1"].contains(host) ? nil : host
        case .ssh(let target): target.host
        case .unix, .unsupported: nil
        }
    }

    /// What a `docker` command is given to reach this engine: the context
    /// it came from, else its host. Nothing for the default, which the CLI
    /// finds by itself.
    var environment: [String: String] {
        if let context { return ["DOCKER_CONTEXT": context] }
        return source == "default" ? [:] : ["DOCKER_HOST": host]
    }

    /// `unix:///path`, `tcp://host:port`, `http://host:port`,
    /// `ssh://user@host`; anything else is unsupported, kept as written.
    static func address(of host: String) -> Address {
        if host.hasPrefix("unix://") { return .unix(String(host.dropFirst("unix://".count))) }
        if let target = DockerSSHTarget.parse(host) { return .ssh(target) }
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

    /// A context picked in Overterm (`docker.context`), for Overterm alone:
    /// the CLI's own current context is never changed. Nil when it has no
    /// record (removed since).
    static func chosen(context: String, docker: URL = home) -> DockerEndpoint? {
        if context == "default" { return DockerEndpoint(address: address(of: defaultHost), context: "default", source: "docker.context") }
        guard let host = contextHost(context, docker: docker) else { return nil }
        return DockerEndpoint(address: address(of: host), context: context, source: "docker.context")
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
