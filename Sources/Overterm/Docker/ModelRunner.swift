import Foundation
import NIOHTTP1

/// A model Docker Model Runner has pulled, as its `/models` lists it.
struct RunnerModel: Decodable, Identifiable, Equatable, Sendable {
    struct Config: Decodable, Equatable, Sendable {
        var format: String?
        var quantization: String?
        /// `8B`.
        var parameters: String?
        var architecture: String?
        /// `4.68 GiB`, as the runner writes it.
        var size: String?
        var context_size: Int?
    }

    var id: String
    var tags: [String]?
    /// Seconds since 1970.
    var created: Int
    var config: Config?

    /// `ai/smollm2:latest` → `smollm2`, as `docker model list` shows it;
    /// the short id when it has no tag.
    var name: String { tags?.first.map(Self.display) ?? shortID }
    var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    /// What `docker model run` and `rm` take.
    var reference: String { tags?.first ?? id }

    static func display(_ tag: String) -> String {
        var name = tag
        for prefix in ["index.docker.io/", "docker.io/", "ai/"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        if name.hasSuffix(":latest") { name.removeLast(":latest".count) }
        return name
    }

    /// `8B · Q4_K_M · 4.68 GiB · llama`.
    var summary: String {
        [config?.parameters, config?.quantization, config?.size, config?.architecture].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}

/// A model loaded in a backend (`/engines/ps`).
struct RunningModel: Decodable, Equatable, Sendable {
    var backend_name: String
    var model_name: String
    var mode: String?
    var in_use: Bool?
    var loading: Bool?

    /// Whether it is `model` — by id, or by a tag written either way
    /// (`ai/smollm2`, `ai/smollm2:latest`, `smollm2`).
    func runs(_ model: RunnerModel) -> Bool {
        let name = RunnerModel.display(model_name.lowercased())
        return model_name == model.id || (model.tags ?? []).contains { RunnerModel.display($0.lowercased()) == name }
    }
}

/// What the models and the backend take on disk, in bytes (`/engines/df`).
struct RunnerDiskUsage: Decodable, Equatable, Sendable {
    var models_disk_usage: Int64
    var default_backend_disk_usage: Int64
}

/// Docker Model Runner — the Models section — read from the runner's own
/// API, never `docker model`: on Docker Engine (OrbStack, Colima…) the CLI
/// installs the runner — pulls its image, makes a container and a volume —
/// the first time any of its commands runs, `list` and `status` too.
/// Docker Desktop's runner answers over the engine's socket under
/// `/exp/vDD4.40`; an engine's is a `docker/model-runner` container
/// already there, at its published port. Pure but for `read`.
enum ModelRunner {
    enum Place: Equatable, Sendable {
        /// Docker Desktop's, over the engine's own socket.
        case desktop
        /// The runner's container, at 127.0.0.1:port.
        case container(id: String, port: Int)
        /// The container is there, stopped.
        case stopped(id: String, name: String)
        /// No runner here; what installs or enables one.
        case absent(command: String?)
        /// On a remote engine: not read from here.
        case remote
    }

    static let desktopPrefix = "/exp/vDD4.40"

    /// Where this engine's runner is. A remote engine's isn't this Mac's.
    static func place(runtime: DockerRuntime, remote: Bool, containers: [ContainerSummary]) -> Place {
        if remote { return .remote }
        if runtime == .dockerDesktop { return .desktop }
        guard let runner = containers.first(where: { $0.Image.hasPrefix("docker/model-runner") }) else {
            return .absent(command: "docker model install-runner")
        }
        guard runner.state == .running else { return .stopped(id: runner.Id, name: runner.name) }
        let port = PublishedPort.of(runner.Ports ?? []).first { $0.containerPort == 12434 } ?? PublishedPort.of(runner.Ports ?? []).first
        guard let port else { return .absent(command: nil) }
        return .container(id: runner.Id, port: port.hostPort)
    }

    /// The OpenAI-compatible endpoint, for a container and for this Mac.
    static func endpoints(_ place: Place) -> (containers: String, mac: String?)? {
        switch place {
        case .desktop: ("http://model-runner.docker.internal/engines/v1", nil)
        case .container(_, let port): ("http://host.docker.internal:\(port)/engines/v1", "http://localhost:\(port)/engines/v1")
        default: nil
        }
    }

    /// What it has, what is loaded, what it takes. Docker Desktop answers
    /// 503 while its runner is off: `nil` then.
    struct Contents: Equatable, Sendable {
        var models: [RunnerModel]
        var running: [RunningModel]
        var usage: RunnerDiskUsage?
    }

    static func read(_ place: Place, engine: DockerEngine) async throws -> Contents? {
        guard let (transport, prefix) = client(place, engine: engine) else { return nil }
        let models = try await transport.send(.GET, prefix + "/models", body: nil, headers: [])
        if models.status == 503 { return nil }
        guard models.status == 200 else { throw DockerError(status: models.status, message: models.errorMessage) }
        let decoded = try JSONDecoder().decode([RunnerModel]?.self, from: models.body) ?? []
        let running = try? await transport.send(.GET, prefix + "/engines/ps", body: nil, headers: [])
        let usage = try? await transport.send(.GET, prefix + "/engines/df", body: nil, headers: [])
        return Contents(
            models: decoded.sorted { $0.name.lowercased() < $1.name.lowercased() },
            running: running.flatMap { $0.status == 200 ? try? JSONDecoder().decode([RunningModel]?.self, from: $0.body) : nil } ?? [],
            usage: usage.flatMap { $0.status == 200 ? try? JSONDecoder().decode(RunnerDiskUsage.self, from: $0.body) : nil })
    }

    /// Removes a model — what `docker model rm` asks the runner.
    static func remove(_ model: RunnerModel, place: Place, engine: DockerEngine) async throws {
        guard let (transport, prefix) = client(place, engine: engine) else { return }
        let name = model.reference.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.reference
        let response = try await transport.send(.DELETE, prefix + "/models/" + name, body: nil, headers: [])
        guard (200..<300).contains(response.status) else { throw DockerError(status: response.status, message: response.errorMessage) }
    }

    private static func client(_ place: Place, engine: DockerEngine) -> (DockerTransport, String)? {
        switch place {
        case .desktop: (engine.transport, desktopPrefix)
        case .container(_, let port): (NIODockerTransport(address: .tcp(host: "127.0.0.1", port: port)), "")
        default: nil
        }
    }
}
