import Foundation

/// Which engine is answering: what its socket and its `/info` say. The
/// engine bar names it, says whether it is up while the socket is silent,
/// and knows how to start and stop it.
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
    /// A remote engine is an engine: what starts Docker Desktop here would
    /// start this Mac's, not the host's.
    static func of(_ endpoint: DockerEndpoint, operatingSystem: String? = nil) -> DockerRuntime {
        if endpoint.remoteHost != nil { return .engine }
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
        let profile = Self.colimaProfile(context).map { " --profile \($0)" } ?? ""
        switch (self, action) {
        case (.dockerDesktop, _): return "docker desktop \(action.rawValue)"
        case (.orbStack, _): return "orb \(action.rawValue)"
        case (.colima, _): return "colima \(action.rawValue)\(profile)"
        case (.podman, .start): return "podman machine start"
        case (.podman, .stop): return "podman machine stop"
        case (.podman, .restart): return "podman machine stop && podman machine start"
        // rdctl starts the app when it isn't running.
        case (.rancherDesktop, .start): return "rdctl start"
        case (.rancherDesktop, .stop): return "rdctl shutdown"
        case (.rancherDesktop, .restart): return "rdctl shutdown && rdctl start"
        default: return nil
        }
    }

    enum Action: String, Sendable { case start, stop, restart }

    /// The rest of what the runtime's own CLI does for it — updates,
    /// diagnostics, Kubernetes — run in a terminal tab where the user sees
    /// it ask and answer.
    func extras(context: String? = nil) -> [(title: String, command: String)] {
        let profile = Self.colimaProfile(context).map { " --profile \($0)" } ?? ""
        switch self {
        case .dockerDesktop:
            return [
                ("Check for Updates", "docker desktop update --check-only"), ("Update Docker Desktop", "docker desktop update"),
                ("Kubernetes Status", "docker desktop kubernetes status"), ("Diagnose", "docker desktop diagnose"),
                ("Docker Desktop's Logs", "docker desktop logs"),
            ]
        case .orbStack: return [("OrbStack's Status", "orb status"), ("OrbStack's Logs", "orb logs")]
        case .colima: return [("Colima's Status", "colima status\(profile)"), ("Colima's Profiles", "colima list")]
        case .podman: return [("Podman Machines", "podman machine list")]
        case .rancherDesktop: return [("Rancher Desktop's Settings", "rdctl list-settings"), ("Rancher Desktop's Version", "rdctl version")]
        case .engine: return []
        }
    }

    /// `colima-work` → work; Colima's default profile's context is `colima`.
    static func colimaProfile(_ context: String?) -> String? {
        guard let context, context.hasPrefix("colima-") else { return nil }
        return String(context.dropFirst("colima-".count))
    }

    /// Where the engine's own settings live as its runtime keeps them —
    /// edited in the editor, applied when it restarts. Docker Desktop's
    /// Settings ▸ Docker Engine is `~/.docker/daemon.json`.
    func configFile(context: String? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        switch self {
        case .dockerDesktop: home.appendingPathComponent(".docker/daemon.json")
        case .orbStack: home.appendingPathComponent(".orbstack/config/docker.json")
        case .colima: home.appendingPathComponent(".colima/\(Self.colimaProfile(context) ?? "default")/colima.yaml")
        case .rancherDesktop, .podman, .engine: nil
        }
    }

    // MARK: Whether it is up

    /// What the runtime says of itself — asked only while its socket is
    /// silent, to tell "stopped" from "starting" from "not installed".
    enum Status: Equatable, Sendable {
        case running, starting, stopped
        /// Docker Desktop's Resource Saver: the engine wakes on the first call.
        case paused
        case unknown
    }

    /// The tool and its arguments that ask (`docker desktop status`…).
    func statusCommand(context: String? = nil) -> (tool: String, arguments: [String])? {
        switch self {
        case .dockerDesktop: ("docker", ["desktop", "status", "--format", "json"])
        case .orbStack: ("orb", ["status"])
        case .colima: ("colima", ["status", "--json"] + (Self.colimaProfile(context).map { ["--profile", $0] } ?? []))
        case .podman: ("podman", ["machine", "inspect", "--format", "{{.State}}"])
        // Its app's API: refused while the app isn't running.
        case .rancherDesktop: ("rdctl", ["api", "/v1/backend_state"])
        case .engine: nil
        }
    }

    /// What that command printed. Colima prints JSON only while running
    /// (and exits 1, saying so on stderr, when not).
    func status(fromOutput output: String) -> Status {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .dockerDesktop:
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return .unknown }
            if let pause = json["PauseType"] as? String, !pause.isEmpty { return .paused }
            return Self.word(json["Status"] as? String ?? "")
        case .colima:
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] ? .running : .stopped
        case .orbStack, .podman:
            return Self.word(text.split(separator: "\n").first.map(String.init) ?? "")
        case .rancherDesktop:
            // `{"vmState":"STARTED","locked":false}`; DISABLED is up with
            // Kubernetes off.
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], let state = json["vmState"] as? String else {
                return .unknown
            }
            return state == "DISABLED" ? .running : state == "ERROR" ? .unknown : Self.word(state)
        case .engine:
            return .unknown
        }
    }

    private static func word(_ word: String) -> Status {
        switch word.lowercased() {
        case "running", "started": .running
        case "starting", "start", "initializing", "booting": .starting
        case "stopped", "stopping", "exited", "stop": .stopped
        case "paused": .paused
        default: .unknown
        }
    }
}
