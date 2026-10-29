import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Docker's Engine API played on a unix socket of its own, for the tests
/// and the `docker` scenario: never the user's Docker. Holds containers,
/// images, volumes and networks as values; actions change them and send
/// the events the real engine would; logs come framed as a container
/// without a TTY sends them; a container's files are a dictionary.
final class FakeDockerEngine: @unchecked Sendable {
    struct Container: Sendable {
        var summary: ContainerSummary
        var env: [String] = []
        var tty = false
        var files: [String: Data] = [:]
        /// When each was last written, as the archive's stat says it.
        var mtimes: [String: String] = [:]
        /// Each line with the time it was written, as the engine keeps it.
        var logs: [(stream: DockerLogChunk.Stream, text: String, time: String)] = []
        var error: String = ""
        /// A volume mounted where (`HostConfig.Binds`): the helper's.
        var binds: [String: String] = [:]
        /// The name it was made from, when the list says its image's ID.
        var reference: String?
        /// How it failed, as inspect says it (`setFailure`).
        var oomKilled = false
        var restarts = 0
        var restartPolicy = "no"
        var memory = 0
        var healthcheck: [String]?
        /// Its health check's last outputs, oldest first.
        var probes: [String] = []
        var failingStreak = 0
        /// What it was made for: its image's platform then.
        var platform: ImagePlatform?
        /// What its one-shot stats say (`setUsage`): CPU as `docker stats`
        /// gives it, memory in use less the page cache.
        var cpuPercent: Double = 8
        var memoryUsed = 48 << 20
        /// Its CPU counters, moved on at each one-shot read. Not from
        /// zero: a lifetime's average (2%) isn't the rate, so a read set
        /// against `precpu_stats` instead of the read before is wrong.
        var cpuTotal = 5_000_000_000
        var systemTotal = 1_000_000_000_000
        /// How its one-shot stats answer (`setStatsAnswer`).
        var statsAnswer = StatsAnswer.read
    }

    /// A one-shot stats read's answer: the sample, the engine's 500, or
    /// none at all — a container whose shim stopped answering.
    enum StatsAnswer: Sendable {
        case read, failing, never
    }

    /// What an image is built for, as its inspect says it.
    struct ImagePlatform: Equatable, Sendable {
        var os = "linux"
        var architecture: String
        var variant: String?
    }

    let socket: String
    private let lock = NSLock()
    private var containers: [String: Container] = [:]
    private var images: [ImageSummary] = []
    private var volumes: [VolumeSummary] = []
    private var networks: [NetworkSummary] = []
    /// What each volume holds, by path in it.
    private var volumeFiles: [String: [String: Data]] = [:]
    /// Bytes of build cache not in use.
    var buildCache = 0
    /// What `/info` says the host is (`uname -m`): Apple silicon's.
    var architecture = "aarch64"
    /// What `/_ping` says it speaks: from 1.48 a container says the
    /// platform it runs (in the containerd store).
    var apiVersion = "1.47"
    /// The containerd image store's ways, Docker Desktop's default since
    /// 4.34: an image's id is its index's, the same for each platform
    /// pulled into it, and its inspect says the host's platform once the
    /// index holds it. Else the classic store's: an id a platform.
    var containerdStore = false
    /// How long an image's inspect takes, in milliseconds: a remote
    /// engine's round trip.
    var imageInspectDelay = 0
    /// Each image's platforms, by id: one in the classic store, what its
    /// index holds in the containerd store.
    private var imagePlatforms: [String: [ImagePlatform]] = [:]
    private var execs: [String: (container: String, command: [String])] = [:]
    private var exitCodes: [String: Int] = [:]
    private var eventStreams: [ObjectIdentifier: Channel] = [:]
    private var logFollowers: [String: [Channel]] = [:]
    private var samplers: [ObjectIdentifier: Channel] = [:]
    private var channel: Channel?
    private var tcpChannels: [Channel] = []
    private var asked: [String] = []
    /// Docker Model Runner, as Docker Desktop's answers under
    /// `/exp/vDD4.40` on the socket and a runner container's at the root
    /// (`listenTCP`): nil is off, answered 503.
    private var runnerModels: [FakeRunnerModel]?

    struct FakeRunnerModel: Sendable {
        var tag: String
        var parameters = "360M"
        var quantization = "Q4_K_M"
        var size = "256.35 MiB"
        var loaded = false
        /// The same for the same tag, as a digest is.
        var id: String {
            let hash = tag.utf8.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1) }
            return "sha256:" + String(String(hash, radix: 16).reversed()).padding(toLength: 64, withPad: "0", startingAt: 0)
        }
    }

    init(socket: String) {
        self.socket = socket
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start() throws {
        try? FileManager.default.removeItem(atPath: socket)
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // No pipelining help: it stops reading while a response is
                    // open, and a followed log, idle, would never see its
                    // client leave (Docker does).
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(Handler(engine: self))
                }
            }
        channel = try bootstrap.bind(unixDomainSocketPath: socket).wait()
    }

    /// The same answers on 127.0.0.1 too, at `port` or one of the system's:
    /// what a container publishing it would be, or a port a program on this
    /// Mac holds. Returns the port; each listens until `stop`.
    func listenTCP(port: Int = 0) throws -> Int {
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                    try channel.pipeline.syncOperations.addHandler(Handler(engine: self))
                }
            }
        let bound = try bootstrap.bind(host: "127.0.0.1", port: port).wait()
        locked { tcpChannels.append(bound) }
        return bound.localAddress?.port ?? 0
    }

    func setModelRunner(_ models: [FakeRunnerModel]?) { locked { runnerModels = models } }
    var modelRunnerTags: [String]? { locked { runnerModels?.map(\.tag) } }

    func stop() {
        let open = locked { Array(eventStreams.values) + Array(samplers.values) + logFollowers.values.flatMap { $0 } }
        open.forEach { $0.close(promise: nil) }
        try? channel?.close().wait()
        let listening = locked {
            defer { tcpChannels = [] }
            return tcpChannels
        }
        for tcp in listening { try? tcp.close().wait() }
        try? FileManager.default.removeItem(atPath: socket)
    }

    // MARK: State, as a test sets it

    /// A container; a compose service when `project` is given.
    @discardableResult
    func add(
        name: String, image: String = "debian:bookworm-slim", state: ContainerState = .running, project: String? = nil, workingDir: String? = nil,
        service: String? = nil, ports: [DockerPort] = [], env: [String] = [], health: String? = nil, imageID: String? = nil,
        volumes: [String] = [], configFiles: [String]? = nil
    ) -> String {
        let id = String((name + UUID().uuidString).utf8.map { String(format: "%02x", $0) }.joined().prefix(64))
        var labels: [String: String] = [:]
        if let project {
            labels["com.docker.compose.project"] = project
            labels["com.docker.compose.service"] = service ?? name
            labels["com.docker.compose.container-number"] = "1"
            labels["com.docker.compose.oneoff"] = "False"
            if let workingDir {
                labels["com.docker.compose.project.working_dir"] = workingDir
                labels["com.docker.compose.project.config_files"] = (configFiles ?? [workingDir + "/compose.yaml"]).joined(separator: ",")
            }
        }
        let status = Self.status(state, health: health)
        let platform = imageID.flatMap { id in locked { imagePlatforms[id].map(bestPlatform) } }
        let summary = ContainerSummary(
            Id: id, Names: ["/" + name], Image: image, ImageID: imageID ?? "sha256:" + String(repeating: "a", count: 64), Command: "sleep infinity",
            Created: Int(Date().timeIntervalSince1970), Ports: ports, Labels: labels, State: state.rawValue, Status: status,
            Mounts: volumes.map { DockerMountPoint(Type: "volume", Name: $0, Destination: "/data") },
            Health: health.map { .init(Status: $0, FailingStreak: 0) })
        locked { containers[id] = Container(summary: summary, env: env, platform: platform) }
        emit("create", id)
        return id
    }

    static func status(_ state: ContainerState, health: String? = nil, exitCode: Int = 0) -> String {
        switch state {
        case .running: health.map { "Up 2 minutes (\($0))" } ?? "Up 2 minutes"
        case .paused: "Up 2 minutes (Paused)"
        case .exited: "Exited (\(exitCode)) 3 seconds ago"
        // As moby writes it.
        case .restarting: "Restarting (\(exitCode)) 2 seconds ago"
        case .created: "Created"
        default: state.rawValue.capitalized
        }
    }

    /// Lines the container has written; to followers too.
    func log(_ id: String, _ text: String, stream: DockerLogChunk.Stream = .stdout) {
        let time = Self.timestamp()
        let followers = locked {
            containers[id]?.logs.append((stream, text, time))
            return logFollowers[id] ?? []
        }
        let frame = Self.frame(stream, time + " " + text + "\n")
        for channel in followers {
            channel.eventLoop.execute {
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: frame))), promise: nil)
            }
        }
    }

    /// The container exits (or comes back), as if by itself: an event, as
    /// Docker sends one.
    func set(_ id: String, state: ContainerState, exitCode: Int = 0, health: String? = nil, error: String = "") {
        locked {
            containers[id]?.summary.State = state.rawValue
            containers[id]?.summary.Status = Self.status(state, health: health, exitCode: exitCode)
            containers[id]?.summary.Health = health.map { .init(Status: $0, FailingStreak: 0) }
            containers[id]?.error = error
        }
        // A followed log ends when its container stops, as Docker's does.
        if !state.isUp {
            let followers = locked { logFollowers.removeValue(forKey: id) ?? [] }
            for channel in followers {
                channel.eventLoop.execute {
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
                }
            }
        }
        if let health { emit("health_status: \(health)", id) }
        let action =
            switch state {
            case .running: "start"
            case .exited: "die"
            case .paused: "pause"
            default: state.rawValue
            }
        emit(action, id, extra: state == .exited ? ["exitCode": "\(exitCode)"] : [:])
    }

    /// How it failed, as its inspect will say: out of memory, its
    /// restarts, its health check and that check's last outputs. Sends no
    /// event; `set` does.
    func setFailure(
        _ id: String, oomKilled: Bool = false, restarts: Int = 0, restartPolicy: String = "no", memory: Int = 0, healthcheck: [String]? = nil,
        probes: [String] = [], failingStreak: Int = 0
    ) {
        locked {
            containers[id]?.oomKilled = oomKilled
            containers[id]?.restarts = restarts
            containers[id]?.restartPolicy = restartPolicy
            containers[id]?.memory = memory
            containers[id]?.healthcheck = healthcheck
            containers[id]?.probes = probes
            containers[id]?.failingStreak = failingStreak
        }
    }

    /// The tag it was made from now names a newer image (a pull): the
    /// list says its image's ID, as Docker's does; inspect still says the
    /// name (`Config.Image`).
    func supersedeImage(of id: String) {
        locked {
            guard let container = containers[id], container.reference == nil else { return }
            containers[id]?.reference = container.summary.Image
            containers[id]?.summary.Image = container.summary.ImageID ?? container.summary.Image
        }
        emit("update", id)
    }

    /// What its one-shot stats say from now on.
    func setUsage(_ id: String, cpuPercent: Double, memory: Int) {
        locked {
            containers[id]?.cpuPercent = cpuPercent
            containers[id]?.memoryUsed = memory
        }
    }

    /// How its one-shot stats answer from now on.
    func setStatsAnswer(_ id: String, _ answer: StatsAnswer) { locked { containers[id]?.statsAnswer = answer } }

    func file(_ id: String, _ path: String) -> Data? { locked { containers[id]?.files[path] } }

    func setFile(_ id: String, _ path: String, _ data: Data) {
        let now = Self.timestamp()
        locked {
            containers[id]?.files[path] = data
            containers[id]?.mtimes[path] = now
        }
    }

    /// An image; untagged (`<none>`) when `tag` is nil. Its id back — the
    /// same for the same tag and platform (in the containerd store, for
    /// the same tag). Built for arm64 unless said. In the classic store
    /// the tag moves to it from another image, as a pull moves it; in the
    /// containerd store the platform joins the tag's index.
    @discardableResult
    func addImage(_ tag: String?, size: Int, containers: Int = 0, architecture: String = "arm64", variant: String? = nil) -> String {
        let platform = ImagePlatform(architecture: architecture, variant: variant)
        let index = locked { containerdStore }
        let name = tag ?? UUID().uuidString
        let image = ImageSummary(
            Id: Self.imageID(index || architecture == "arm64" ? name : architecture + (variant.map { "/" + $0 } ?? "") + "@" + name),
            RepoTags: tag.map { [$0] } ?? ["<none>:<none>"], RepoDigests: [], Created: Int(Date().timeIntervalSince1970) - 86_400, Size: size,
            Containers: containers, Labels: [:])
        locked {
            if index, images.contains(where: { $0.Id == image.Id }) {
                if imagePlatforms[image.Id]?.contains(platform) != true { imagePlatforms[image.Id, default: []].append(platform) }
                return
            }
            images.removeAll { $0.Id == image.Id }
            if let tag {
                for at in images.indices where images[at].RepoTags?.contains(tag) == true {
                    let left = (images[at].RepoTags ?? []).filter { $0 != tag }
                    images[at].RepoTags = left.isEmpty ? ["<none>:<none>"] : left
                }
            }
            images.append(image)
            imagePlatforms[image.Id] = [platform]
        }
        return image.Id
    }

    /// The same for the same seed, as a digest is: its bytes as they are
    /// when they fit (a test reads them), else its SHA-256 — two long tags
    /// alike in their first 32 bytes are two images.
    static func imageID(_ seed: String) -> String {
        let bytes = Array(seed.utf8)
        let hex =
            bytes.count <= 32
            ? bytes.map { String(format: "%02x", $0) }.joined().padding(toLength: 64, withPad: "0", startingAt: 0)
            : SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        return "sha256:" + hex
    }

    /// What an image runs here: the host's platform when it has it, else
    /// its first — as the containerd store picks from an index.
    private func bestPlatform(_ platforms: [ImagePlatform]) -> ImagePlatform {
        let own = DockerPlatform(engine: architecture)?.architecture
        return platforms.first { $0.architecture == own } ?? platforms.first ?? ImagePlatform(architecture: "arm64")
    }

    func addVolume(_ name: String, size: Int, refCount: Int, project: String? = nil, anonymous: Bool = false) {
        var labels = project.map { ["com.docker.compose.project": $0] } ?? [:]
        if anonymous { labels["com.docker.volume.anonymous"] = "" }
        let volume = VolumeSummary(
            Name: name, Driver: "local", Mountpoint: "/var/lib/docker/volumes/\(name)/_data", CreatedAt: nil,
            Labels: labels, Scope: "local", UsageData: .init(Size: size, RefCount: refCount))
        locked { volumes.append(volume) }
    }

    func addNetwork(_ name: String, members: [String] = []) {
        let network = NetworkSummary(
            Name: name, Id: name + "-id", Driver: name == "host" || name == "none" ? name : "bridge", Scope: "local",
            Containers: Dictionary(uniqueKeysWithValues: members.map { ($0, .init(Name: nil, IPv4Address: "172.18.0.2/16")) }), Labels: [:],
            IPAM: .init(Driver: "default", Config: [.init(Subnet: "172.18.0.0/16", Gateway: "172.18.0.1")]))
        locked { networks.append(network) }
    }

    var containerIDs: [String] { locked { Array(containers.keys) } }

    /// Every request so far, `GET /v1.47/containers/json?all=1`.
    var requests: [String] { locked { asked } }

    /// Who is waiting for events now.
    var listening: Int { locked { eventStreams.count } }

    /// Which are open, for a test's message.
    var streams: String {
        locked { "events \(eventStreams.count), stats \(samplers.count), logs \(logFollowers.values.reduce(0) { $0 + $1.count })" }
    }

    /// Streams still open: events, followed logs, stats.
    var openStreams: Int { locked { eventStreams.count + samplers.count + logFollowers.values.reduce(0) { $0 + $1.count } } }

    func summary(_ id: String) -> ContainerSummary? { locked { containers[id]?.summary } }

    private func emit(_ action: String, _ id: String, extra: [String: String] = [:]) {
        let (streams, labels) = locked { (Array(eventStreams.values), containers[id]?.summary.labels ?? [:]) }
        var attributes = labels.merging(extra) { $1 }
        attributes["name"] = locked { containers[id]?.summary.name }
        let event = DockerEvent(Type: "container", Action: action, Actor: .init(ID: id, Attributes: attributes), time: Int(Date().timeIntervalSince1970))
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A)
        for channel in streams {
            channel.eventLoop.execute {
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: line))), promise: nil)
            }
        }
    }

    static func frame(_ stream: DockerLogChunk.Stream, _ text: String) -> Data {
        let body = Data(text.utf8)
        var header = Data([stream.rawValue, 0, 0, 0])
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { header.append(contentsOf: $0) }
        return header + body
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Answers

    enum Answer: Sendable {
        case json(Int, Data)
        case empty(Int)
        case raw(Int, Data, [(String, String)])
        /// Stays open; the engine writes to it later.
        case events
        case follow(String, Data)
        case stats(String)
        /// Asked, never answered: the connection stays open till the
        /// client closes it.
        case never
        case notFound
    }

    func answer(_ method: HTTPMethod, _ uri: String, body: Data, chunked: Bool = false) -> Answer {
        locked { asked.append("\(method.rawValue) \(uri)") }
        // As the engine does: a start with a body of unknown length is
        // refused (it took every real start down once).
        if method == .POST, chunked, uri.hasSuffix("/start") {
            return Self.error(400, "starting container with non-empty request body was deprecated since API v1.22 and removed in v1.24")
        }
        guard let url = URLComponents(string: "http://docker" + uri) else { return .notFound }
        let runnerPath = url.path.hasPrefix(ModelRunner.desktopPrefix) ? String(url.path.dropFirst(ModelRunner.desktopPrefix.count)) : url.path
        if runnerPath == "/models" || runnerPath.hasPrefix("/models/") || runnerPath.hasPrefix("/engines/") { return modelRunner(method, runnerPath) }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        var parts = url.path.split(separator: "/").map(String.init)
        let version = parts.first?.hasPrefix("v1.") == true ? String(parts.removeFirst().dropFirst()) : apiVersion
        guard let kind = parts.first else { return .notFound }
        // `containers/<id>/logs` → id and `logs`; `containers/json` → no id.
        let named = ["containers", "images", "volumes", "networks", "exec"].contains(kind) && parts.count > 1 && !["json", "prune", "create"].contains(parts[1])
        let id = named ? parts[1] : ""
        let verb = named ? parts.dropFirst(2).joined(separator: "/") : parts.dropFirst().joined(separator: "/")
        switch kind {
        case "_ping": return .raw(200, Data("OK".utf8), [("API-Version", locked { apiVersion }), ("Docker-Experimental", "false")])
        case "info": return info()
        case "events": return .events
        case "system" where verb == "df": return diskUsage()
        case "build" where verb == "prune":
            let freed = locked { buildCache }
            locked { buildCache = 0 }
            return Self.json(PruneReport(SpaceReclaimed: freed, CachesDeleted: freed > 0 ? ["cache"] : []))
        case "containers" where verb == "prune", "images" where verb == "prune", "volumes" where verb == "prune", "networks" where verb == "prune":
            return Self.json(prune(kind, all: (query["filters"] ?? "").contains("\"dangling\":[\"false\"]") || (query["filters"] ?? "").contains("\"all\"")))
        case "containers" where !named && verb == "create" && method == .POST: return create(body, query)
        case "containers": return named ? container(method, id, verb, query, body, version: version) : containerList(query, version: version)
        case "exec": return exec(method, id, verb)
        case "images" where named && verb == "history": return image(id).map { Self.json(Self.history(of: $0)) } ?? Self.error(404, "No such image: \(id)")
        case "images" where named && verb == "json": return image(id).map(imageInspect) ?? Self.error(404, "No such image: \(id)")
        case "images" where named && verb == "tag":
            guard let found = image(id) else { return Self.error(404, "No such image: \(id)") }
            let name = (query["repo"] ?? "") + ":" + (query["tag"] ?? "latest")
            locked { if let at = images.firstIndex(where: { $0.Id == found.Id }) { images[at].RepoTags = (images[at].RepoTags ?? []) + [name] } }
            emitImage("tag", found.Id)
            return .empty(201)
        case "images" where !named && verb == "create": return pull((query["fromImage"] ?? "") + ":" + (query["tag"] ?? "latest"), platform: query["platform"])
        case "networks" where named && ["connect", "disconnect"].contains(verb):
            return other(method, kind, id, named, body, query.merging(["_verb": verb]) { $1 })
        case "images", "volumes", "networks": return other(method, kind, id, named, body, query)
        default: return Self.error(404, "page not found")
        }
    }

    private func modelRunner(_ method: HTTPMethod, _ path: String) -> Answer {
        guard let models = locked({ runnerModels }) else { return Self.error(503, "service unavailable") }
        func data(_ object: Any) -> Answer { .json(200, (try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
        switch (method, path) {
        case (.GET, "/models"):
            return data(
                models.map { model in
                    [
                        "id": model.id, "tags": [model.tag], "created": 1_760_000_000,
                        "config": ["format": "gguf", "parameters": model.parameters, "quantization": model.quantization, "size": model.size, "architecture": "llama"],
                    ] as [String: Any]
                })
        case (.GET, "/engines/ps"):
            return data(models.filter(\.loaded).map { ["backend_name": "llama.cpp", "model_name": $0.tag, "mode": "completion"] })
        case (.GET, "/engines/df"):
            return data(["models_disk_usage": models.count * 268_000_000, "default_backend_disk_usage": 0])
        case (.DELETE, _) where path.hasPrefix("/models/"):
            let name = String(path.dropFirst("/models/".count)).removingPercentEncoding ?? ""
            guard models.contains(where: { $0.tag == name }) else { return Self.error(404, "model not found") }
            locked { runnerModels?.removeAll { $0.tag == name } }
            return .empty(200)
        default:
            return Self.error(404, "page not found")
        }
    }

    static func json<T: Encodable>(_ value: T) -> Answer { .json(200, (try? JSONEncoder().encode(value)) ?? Data()) }

    static func error(_ status: Int, _ message: String) -> Answer {
        .json(status, (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data())
    }

    private func info() -> Answer {
        let (count, running, imageCount, machine) = locked {
            (containers.count, containers.values.filter { $0.summary.state == .running }.count, images.count, architecture)
        }
        return Self.json(
            EngineInfo(
                Name: "fake", OperatingSystem: "Overterm's fake engine", ServerVersion: "29.0.0", NCPU: 4, MemTotal: 8 << 30, Containers: count,
                ContainersRunning: running, Images: imageCount, Architecture: machine, OSType: "linux"))
    }

    /// An image's inspect: its summary's fields and its platform, the
    /// variant only when it has one (the engine leaves an empty one out).
    /// How long a request waits for its answer, in milliseconds: an
    /// image's inspect `imageInspectDelay`, the rest none.
    func delay(of uri: String) -> Int {
        let parts = (URLComponents(string: "http://docker" + uri)?.path ?? "").split(separator: "/").map(String.init).filter { !$0.hasPrefix("v1.") }
        return parts.count == 3 && parts[0] == "images" && parts[2] == "json" ? locked { imageInspectDelay } : 0
    }

    private func imageInspect(_ image: ImageSummary) -> Answer {
        var object = ((try? JSONEncoder().encode(image)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        let platform = locked { imagePlatforms[image.Id].map(bestPlatform) } ?? ImagePlatform(architecture: "arm64")
        object["Os"] = platform.os
        object["Architecture"] = platform.architecture
        if let variant = platform.variant { object["Variant"] = variant }
        return .json(200, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func diskUsage() -> Answer {
        let usage = locked {
            DockerDiskUsage(
                LayersSize: images.reduce(0) { $0 + $1.Size }, Images: images, Containers: [], Volumes: volumes,
                BuildCache: buildCache > 0 ? [.init(ID: "cache", Size: buildCache, InUse: false, Shared: false)] : [])
        }
        return Self.json(usage)
    }

    private func containerList(_ query: [String: String], version: String) -> Answer {
        let all = query["all"] == "1"
        let list = locked { containers.values.map { summary(of: $0, version: version) } }
        return Self.json(list.filter { all || $0.state == .running }.sorted { $0.name < $1.name })
    }

    /// As the engine lists it at `version`: from 1.48, in the containerd
    /// store, with the platform it was made for.
    private func summary(of container: Container, version: String) -> ContainerSummary {
        var summary = container.summary
        if containerdStore, DockerEngine.older(version, DockerEngine.manifestVersion) == DockerEngine.manifestVersion, let platform = container.platform {
            summary.ImageManifestDescriptor = .init(platform: .init(architecture: platform.architecture, os: platform.os, variant: platform.variant))
        }
        return summary
    }

    private func container(_ method: HTTPMethod, _ id: String, _ verb: String, _ query: [String: String], _ body: Data, version: String) -> Answer {
        let found = locked { containers[id] ?? containers.values.first { $0.summary.name == id } }
        guard let container = found else { return Self.error(404, "No such container: \(id)") }
        let id = container.summary.Id
        let path = query["path"] ?? ""
        switch (method, verb) {
        case (.GET, "json"):
            var detail = Self.detail(container)
            detail.ImageManifestDescriptor = locked { summary(of: container, version: version) }.ImageManifestDescriptor
            return Self.json(detail)
        case (.POST, "start"), (.POST, "stop"), (.POST, "restart"), (.POST, "pause"), (.POST, "unpause"), (.POST, "kill"):
            let state: ContainerState =
                switch verb {
                case "stop", "kill": .exited
                case "pause": .paused
                default: .running
                }
            // Asked to stop: Docker says `kill` before the `die`.
            if ["stop", "kill", "restart"].contains(verb) { emit("kill", id, extra: ["signal": verb == "kill" ? "9" : "15"]) }
            if verb == "restart" { set(id, state: .exited, exitCode: 143) }
            set(id, state: state, exitCode: verb == "kill" ? 137 : 143)
            return .empty(204)
        case (.DELETE, ""):
            if container.summary.state == .running, query["force"] != "1" {
                return Self.error(409, "cannot remove container \(container.summary.name): container is running: stop the container before removing or force remove")
            }
            emit("destroy", id)
            locked { _ = containers.removeValue(forKey: id) }
            return .empty(204)
        case (.GET, "logs"):
            let tail = Int(query["tail"] ?? "") ?? container.logs.count
            let frames = container.logs.suffix(tail).reduce(into: Data()) { $0 += Self.frame($1.stream, $1.time + " " + $1.text + "\n") }
            if query["follow"] == "1" { return .follow(id, frames) }
            return .raw(200, frames, [("Content-Type", "application/vnd.docker.multiplexed-stream")])
        case (.GET, "top"):
            return .json(200, Data(#"{"Titles":["PID","USER","TIME","COMMAND"],"Processes":[["42","root","0:00","sleep infinity"],["57","nginx","0:01","nginx: worker process"]]}"#.utf8))
        case (.GET, "changes"):
            let changes = container.files.keys.sorted().map { #"{"Path":"\#($0)","Kind":1}"# }
            return .json(200, Data(("[" + changes.joined(separator: ",") + "]").utf8))
        case (.GET, "stats") where query["stream"] == "false" && !container.summary.state.hasStats:
            // As the engine answers for a stopped or restarting one: empty.
            return Self.json(Self.emptyStats)
        case (.GET, "stats") where query["stream"] == "false" && ["1", "true"].contains(query["one-shot"] ?? ""):
            switch container.statsAnswer {
            case .read: return .json(200, oneShotSample(id))
            case .failing: return Self.error(500, "failed to get stats: task \(id) not found")
            case .never: return .never
            }
        case (.GET, "stats") where query["stream"] == "false":
            return .json(200, statsSample(id, tick: 1))
        case (.GET, "stats"):
            return .stats(id)
        case (.POST, "exec"):
            guard container.summary.state == .running else { return Self.error(409, "container \(id) is not running") }
            struct Request: Decodable { var Cmd: [String] }
            guard let command = try? JSONDecoder().decode(Request.self, from: body).Cmd else { return Self.error(400, "no Cmd") }
            let execID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            locked { execs[execID] = (id, command) }
            return .json(201, Data(#"{"Id":"\#(execID)"}"#.utf8))
        case (.HEAD, "archive"):
            guard let data = container.files[path] else { return Self.error(404, "Could not find the file \(path) in container \(id)") }
            let stat = DockerTar.PathStat(
                name: (path as NSString).lastPathComponent, size: data.count, mode: 0o644, mtime: container.mtimes[path] ?? "2026-01-01T00:00:00Z",
                linkTarget: "")
            return .raw(200, Data(), [("X-Docker-Container-Path-Stat", (try? JSONEncoder().encode(stat))?.base64EncodedString() ?? "")])
        case (.GET, "archive"):
            // A volume's mount point: its files, under the folder's own name.
            if let volume = container.binds[path] {
                let files = locked { volumeFiles[volume] ?? [:] }
                let top = (path as NSString).lastPathComponent
                var archive = DockerTar.header(name: top + "/", size: 0, mode: 0o755, modified: Date(), type: "5") ?? Data()
                for (name, data) in files.sorted(by: { $0.key < $1.key }) {
                    archive += (DockerTar.archive(name: top + "/" + name, data: data) ?? Data()).dropLast(2 * DockerTar.block)
                }
                archive += Data(count: 2 * DockerTar.block)
                return .raw(200, archive, [("Content-Type", "application/x-tar")])
            }
            guard let data = container.files[path], let archive = DockerTar.archive(name: (path as NSString).lastPathComponent, data: data) else {
                return Self.error(404, "Could not find the file \(path) in container \(id)")
            }
            return .raw(200, archive, [("Content-Type", "application/x-tar")])
        case (.PUT, "archive"):
            let folder = query["path"] ?? "/"
            for entry in DockerTar.entries(of: body) where entry.kind == .file {
                let full = (folder as NSString).appendingPathComponent(entry.name)
                // Into a mounted volume, when it lands under its mount point.
                if let (mount, volume) = container.binds.first(where: { full.hasPrefix($0.key + "/") }) {
                    locked { volumeFiles[volume, default: [:]][String(full.dropFirst(mount.count + 1))] = entry.data }
                } else {
                    setFile(id, full, entry.data)
                }
            }
            return .empty(200)
        case (.GET, "export"):
            let archive = container.files.sorted { $0.key < $1.key }.reduce(into: Data()) { out, file in
                out += (DockerTar.archive(name: String(file.key.dropFirst()), data: file.value) ?? Data()).dropLast(2 * DockerTar.block)
            }
            return .raw(200, archive + Data(count: 2 * DockerTar.block), [("Content-Type", "application/x-tar")])
        default:
            return Self.error(404, "page not found")
        }
    }

    /// An exec's start and its exit: the listing script answered from the
    /// container's files; anything else isn't there (127, as a shell says).
    private func exec(_ method: HTTPMethod, _ execID: String, _ verb: String) -> Answer {
        guard let (containerID, command) = locked({ execs[execID] }) else { return Self.error(404, "No such exec instance: \(execID)") }
        switch (method, verb) {
        case (.POST, "start"):
            let (code, out, err) = run(command, in: containerID)
            locked { exitCodes[execID] = code }
            var frames = Data()
            if !out.isEmpty { frames += Self.frame(.stdout, out) }
            if !err.isEmpty { frames += Self.frame(.stderr, err) }
            return .raw(200, frames, [("Content-Type", "application/vnd.docker.multiplexed-stream")])
        case (.GET, "json"):
            return .json(200, Data(#"{"ExitCode":\#(locked { exitCodes[execID] } ?? 0),"Running":false}"#.utf8))
        default:
            return Self.error(404, "page not found")
        }
    }

    private func run(_ command: [String], in id: String) -> (Int, String, String) {
        guard command.first == "sh", command.contains("overterm-ls"), let folder = command.last else {
            return (127, "", "\(command.first ?? ""): not found\n")
        }
        let files = locked { containers[id]?.files ?? [:] }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var lines: [String: String] = [:]
        for (path, data) in files where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                lines[name] = "d\t-\t\(name)"
            } else {
                lines[String(rest)] = "f\t\(data.count)\t\(rest)"
            }
        }
        guard !lines.isEmpty || folder == "/" else { return (2, "", "No such folder: \(folder)\n") }
        return (0, lines.values.sorted().map { $0 + "\n" }.joined(), "")
    }

    /// A container made, not started: what the helper is.
    private func create(_ body: Data, _ query: [String: String]) -> Answer {
        struct Request: Decodable {
            struct Host: Decodable { var Binds: [String]? }
            var Image: String
            var HostConfig: Host?
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: body) else { return Self.error(400, "bad request") }
        let id = add(name: query["name"] ?? "helper-\(UUID().uuidString.prefix(6).lowercased())", image: request.Image, state: .created)
        var binds: [String: String] = [:]
        for bind in request.HostConfig?.Binds ?? [] {
            let parts = bind.split(separator: ":").map(String.init)
            if parts.count >= 2 { binds[parts[1]] = parts[0] }
        }
        locked { containers[id]?.binds = binds }
        return .json(201, Data(#"{"Id":"\#(id)","Warnings":[]}"#.utf8))
    }

    /// What a volume holds now, for a test.
    func volumeContents(_ name: String) -> [String: Data] { locked { volumeFiles[name] ?? [:] } }

    func setVolumeFile(_ name: String, _ path: String, _ data: Data) { locked { volumeFiles[name, default: [:]][path] = data } }

    private func image(_ idOrName: String) -> ImageSummary? {
        locked { images.first { $0.Id == idOrName || $0.tags.contains(idOrName) || $0.shortID == idOrName } }
    }

    static func history(of image: ImageSummary) -> [ImageLayer] {
        [
            ImageLayer(Id: image.Id, Created: image.Created, CreatedBy: "/bin/sh -c #(nop)  CMD [\"sleep\" \"infinity\"]", Size: 0),
            ImageLayer(Id: "<missing>", Created: image.Created, CreatedBy: "/bin/sh -c apt-get update &&     apt-get install -y curl", Size: image.Size / 2),
            ImageLayer(Id: "<missing>", Created: image.Created, CreatedBy: "/bin/sh -c #(nop) ADD file:abc in / ", Size: image.Size / 2),
        ]
    }

    /// A pull, as the engine streams one: a few layers downloading, then
    /// the image there — for `platform` (os/arch/variant) when asked, else
    /// the engine's own. `private/…` names are refused, as a registry that
    /// wants credentials does; `amd64only/…` have no variant but amd64.
    private func pull(_ name: String, platform: String? = nil) -> Answer {
        if name.hasPrefix("private/") {
            return .json(
                200, Data(#"{"errorDetail":{"message":"pull access denied"},"error":"pull access denied for private, repository does not exist or may require 'docker login'"}"#.utf8 + [0x0A]))
        }
        let parts = (platform ?? "").split(separator: "/").map(String.init)
        let own = DockerPlatform(engine: locked { architecture })
        let arch = parts.count > 1 ? parts[1] : own?.architecture ?? "arm64"
        let variant = parts.count > 2 ? parts[2] : parts.count > 1 ? nil : own?.variant
        if name.hasPrefix("amd64only/"), arch != "amd64" {
            // The classic store's words; containerd's say "no match for platform in manifest".
            let message = "no matching manifest for linux/\(arch)\((arch == "arm64" ? "v8" : variant).map { "/" + $0 } ?? "") in the manifest list entries"
            return .json(200, Data(#"{"errorDetail":{"message":"\#(message)"},"error":"\#(message)"}"#.utf8 + [0x0A]))
        }
        let lines = [
            #"{"status":"Pulling from library/\#(name)","id":"latest"}"#, #"{"status":"Pulling fs layer","progressDetail":{},"id":"l1"}"#,
            #"{"status":"Downloading","progressDetail":{"current":512,"total":2048},"id":"l1"}"#,
            #"{"status":"Download complete","progressDetail":{},"id":"l1"}"#, #"{"status":"Pull complete","progressDetail":{},"id":"l1"}"#,
            #"{"status":"Status: Downloaded newer image for \#(name)"}"#,
        ]
        addImage(name, size: 2048, architecture: arch, variant: variant)
        emitImage("pull", name)
        return .raw(200, Data(lines.joined(separator: "\n").utf8 + [0x0A]), [("Content-Type", "application/json")])
    }

    private func emitImage(_ action: String, _ id: String) {
        let streams = locked { Array(eventStreams.values) }
        let event = DockerEvent(Type: "image", Action: action, Actor: .init(ID: id, Attributes: [:]), time: Int(Date().timeIntervalSince1970))
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A)
        for channel in streams {
            channel.eventLoop.execute { channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: line))), promise: nil) }
        }
    }

    private func other(_ method: HTTPMethod, _ kind: String, _ id: String, _ named: Bool, _ body: Data, _ query: [String: String]) -> Answer {
        switch (method, kind, named) {
        case (.GET, "images", false): return Self.json(locked { images })
        case (.GET, "images", true) where id == "search":
            let term = (query["term"] ?? "").lowercased()
            let catalog = [("redis", "Redis is the world's fastest data platform", 13_000, true), ("bitnami/redis", "Bitnami Redis", 300, false)]
            let found = catalog.filter { $0.0.contains(term) }.map {
                #"{"name":"\#($0.0)","description":"\#($0.1)","star_count":\#($0.2),"is_official":\#($0.3),"is_automated":false}"#
            }
            return .json(200, Data(("[" + found.joined(separator: ",") + "]").utf8))
        case (.GET, "volumes", false): return Self.json(VolumeList(Volumes: locked { volumes }, Warnings: nil))
        case (.POST, "volumes", false):
            struct Request: Decodable { var Name: String }
            guard let name = try? JSONDecoder().decode(Request.self, from: body).Name else { return Self.error(400, "no Name") }
            if locked({ !volumes.contains { $0.Name == name } }) { addVolume(name, size: 0, refCount: 0) }
            return .json(201, Data(#"{"Name":"\#(name)","Driver":"local","Mountpoint":"/var/lib/docker/volumes/\#(name)/_data"}"#.utf8))
        case (.GET, "images", true):
            return .raw(200, Data("a saved image".utf8) + Data(count: 2 * DockerTar.block), [("Content-Type", "application/x-tar")])
        case (.GET, "networks", false): return Self.json(locked { networks })
        case (.DELETE, "images", true):
            locked { images.removeAll { $0.Id == id || $0.tags.contains(id) } }
            emitImage("delete", id)
            return Self.json([PruneReport.ImageDeleted(Untagged: nil, Deleted: id)])
        case (.DELETE, "volumes", true):
            locked { volumes.removeAll { $0.Name == id } }
            return .empty(204)
        case (.DELETE, "networks", true):
            locked { networks.removeAll { $0.Id == id || $0.Name == id } }
            return .empty(204)
        case (.POST, "networks", true):
            // `networks/<id>/connect`, `…/disconnect`: on both records, as the
            // engine keeps them — the network's and the container's.
            let verb = query["_verb"] ?? ""
            struct Request: Decodable { var Container: String }
            guard let wanted = try? JSONDecoder().decode(Request.self, from: body).Container else { return Self.error(400, "no Container") }
            return locked { () -> Answer in
                guard let at = networks.firstIndex(where: { $0.Id == id || $0.Name == id }) else { return Self.error(404, "network \(id) not found") }
                guard let container = containers.keys.first(where: { $0 == wanted || containers[$0]?.summary.name == wanted }) else {
                    return Self.error(404, "No such container: \(wanted)")
                }
                let name = networks[at].Name
                var attachments = containers[container]?.summary.NetworkSettings?.Networks ?? [:]
                if verb == "connect" {
                    networks[at].Containers = (networks[at].Containers ?? [:]).merging([container: .init(Name: nil, IPv4Address: "172.18.0.9/16")]) { $1 }
                    attachments[name] = .init(NetworkID: networks[at].Id, IPAddress: "172.18.0.9")
                } else {
                    networks[at].Containers?.removeValue(forKey: container)
                    attachments.removeValue(forKey: name)
                }
                containers[container]?.summary.NetworkSettings = .init(Networks: attachments)
                return .empty(200)
            }
        default:
            return Self.error(404, "page not found")
        }
    }

    /// What is unused goes, as the engine's prune: untagged images and
    /// anonymous volumes only, unless `all`.
    private func prune(_ kind: String, all: Bool) -> PruneReport {
        var report = PruneReport(SpaceReclaimed: 0)
        locked {
            let used = Set(containers.values.compactMap(\.summary.ImageID))
            switch kind {
            case "images":
                let unused = images.filter { ($0.Containers ?? 0) == 0 && !used.contains($0.Id) && (all || $0.isDangling) }
                report.SpaceReclaimed = unused.reduce(0) { $0 + $1.Size }
                report.ImagesDeleted = unused.map { .init(Untagged: $0.tags.first, Deleted: $0.Id) }
                images.removeAll { image in unused.contains { $0.Id == image.Id } }
            case "volumes":
                let mounted = Set(containers.values.flatMap { ($0.summary.Mounts ?? []).compactMap(\.Name) })
                let unused = volumes.filter { ($0.UsageData?.RefCount ?? 0) == 0 && !mounted.contains($0.Name) && (all || $0.isAnonymous) }
                report.SpaceReclaimed = unused.reduce(0) { $0 + ($1.UsageData?.Size ?? 0) }
                report.VolumesDeleted = unused.map(\.Name)
                volumes.removeAll { volume in unused.contains { $0.Name == volume.Name } }
            case "containers":
                let stopped = containers.values.filter { $0.summary.state == .exited }.map(\.summary.Id)
                report.ContainersDeleted = stopped
                stopped.forEach { containers.removeValue(forKey: $0) }
            default:
                let unused = networks.filter { !$0.isBuiltIn && ($0.Containers ?? [:]).isEmpty }.map(\.Name)
                report.NetworksDeleted = unused
                networks.removeAll { unused.contains($0.Name) }
            }
        }
        return report
    }

    static func detail(_ container: Container) -> ContainerDetail {
        let summary = container.summary
        let probes = container.probes.map { ContainerDetail.Health.Probe(Start: nil, End: nil, ExitCode: 1, Output: $0) }
        // What it publishes, as inspect keeps it whatever its state.
        var bindings: [String: [ContainerDetail.HostConfigDetail.PortBinding]?] = [:]
        for port in summary.Ports ?? [] {
            guard let host = port.PublicPort else { continue }
            let key = "\(port.PrivatePort)/\(port.Type)"
            bindings[key] = ((bindings[key] ?? nil) ?? []) + [.init(HostIp: port.IP == "0.0.0.0" ? "" : port.IP, HostPort: "\(host)")]
        }
        return ContainerDetail(
            Id: summary.Id, Name: "/" + summary.name, Created: nil, Image: summary.ImageID, RestartCount: container.restarts, Platform: "linux",
            State: .init(
                Status: summary.State, Running: summary.state == .running, Paused: summary.state == .paused, Restarting: summary.state == .restarting,
                OOMKilled: container.oomKilled, Dead: summary.state == .dead, Pid: summary.state == .running ? 42 : 0,
                ExitCode: summary.exitCode ?? DockerAttention.restartingExit(summary.Status) ?? 0, Error: container.error, StartedAt: nil,
                FinishedAt: summary.state == .exited ? "2026-10-29T10:00:00.000000000Z" : nil,
                Health: summary.Health.map { .init(Status: $0.Status, FailingStreak: container.failingStreak, Log: probes) }),
            Config: .init(
                Image: container.reference ?? summary.Image, Env: container.env, Cmd: ["sleep", "infinity"], Entrypoint: nil, WorkingDir: "/", User: "",
                Labels: summary.Labels,
                ExposedPorts: bindings.isEmpty ? nil : Dictionary(uniqueKeysWithValues: bindings.keys.map { ($0, EmptyObject()) }), Tty: container.tty, Hostname: String(summary.Id.prefix(12)),
                Healthcheck: container.healthcheck.map { .init(Test: $0, Interval: 30_000_000_000, Timeout: 5_000_000_000, Retries: 3) }),
            HostConfig: .init(
                RestartPolicy: .init(Name: container.restartPolicy, MaximumRetryCount: 0), NetworkMode: "bridge", Memory: container.memory, NanoCpus: 0,
                PortBindings: bindings.isEmpty ? nil : bindings),
            Mounts: summary.Mounts, NetworkSettings: .init(Networks: ["bridge": .init(IPAddress: "172.17.0.2", Gateway: "172.17.0.1", MacAddress: nil)]))
    }

    fileprivate func follow(_ id: String, _ channel: Channel) { locked { logFollowers[id, default: []].append(channel) } }

    fileprivate func listen(_ channel: Channel) { locked { eventStreams[ObjectIdentifier(channel)] = channel } }

    fileprivate func sample(_ channel: Channel) { locked { samplers[ObjectIdentifier(channel)] = channel } }

    fileprivate func forget(_ channel: Channel) {
        locked {
            eventStreams.removeValue(forKey: ObjectIdentifier(channel))
            samplers.removeValue(forKey: ObjectIdentifier(channel))
            for key in logFollowers.keys { logFollowers[key]?.removeAll { $0 === channel } }
        }
    }

    /// The engine's sample for a container it has none for: its zero
    /// time, zero counters, no system usage.
    static let emptyStats = ContainerStatsSample(
        read: "0001-01-01T00:00:00Z", cpu_stats: .init(cpu_usage: .init(total_usage: 0)), precpu_stats: .init(cpu_usage: .init(total_usage: 0)),
        memory_stats: .init())

    /// A one-shot read, as the engine answers it: the counters now, its
    /// `precpu_stats` zeros. Each read moves them on by what `setUsage`
    /// said over a tenth of a second of four CPUs, so a read set against
    /// the one before it gives exactly that.
    private func oneShotSample(_ id: String) -> Data {
        let (cpu, system, memory) = locked { () -> (Int, Int, Int) in
            guard var container = containers[id] else { return (0, 0, 0) }
            container.cpuTotal += Int(container.cpuPercent * 250_000)
            container.systemTotal += 100_000_000
            containers[id] = container
            return (container.cpuTotal, container.systemTotal, container.memoryUsed)
        }
        let sample = ContainerStatsSample(
            read: Self.timestamp(), cpu_stats: .init(cpu_usage: .init(total_usage: cpu), system_cpu_usage: system, online_cpus: 4),
            precpu_stats: .init(cpu_usage: .init(total_usage: 0)),
            memory_stats: .init(usage: memory + (16 << 20), limit: 1 << 30, stats: ["inactive_file": 16 << 20]),
            networks: ["eth0": .init(rx_bytes: 1000, tx_bytes: 500)], blkio_stats: nil, pids_stats: .init(current: 3))
        return (try? JSONEncoder().encode(sample)) ?? Data()
    }

    /// One sample, the CPU's numbers moving on each time.
    func statsSample(_ id: String, tick: Int) -> Data {
        let sample = ContainerStatsSample(
            read: Self.timestamp(),
            cpu_stats: .init(cpu_usage: .init(total_usage: 2_000_000 * (tick + 1)), system_cpu_usage: 100_000_000 * (tick + 1), online_cpus: 4),
            precpu_stats: .init(cpu_usage: .init(total_usage: 2_000_000 * tick), system_cpu_usage: 100_000_000 * tick, online_cpus: 4),
            memory_stats: .init(usage: 64 << 20, limit: 1 << 30, stats: ["inactive_file": 16 << 20]),
            networks: ["eth0": .init(rx_bytes: 1000 * tick, tx_bytes: 500 * tick)], blkio_stats: nil, pids_stats: .init(current: 3))
        var line = (try? JSONEncoder().encode(sample)) ?? Data()
        line.append(0x0A)
        return line
    }
}

/// One request at a time on a connection: the head, the body, then the
/// answer — or, for a stream, a head now and bodies as the engine writes.
private final class Handler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let engine: FakeDockerEngine
    private var head: HTTPRequestHead?
    private var body = Data()
    private var statsTask: RepeatedTask?

    init(engine: FakeDockerEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { return }
            respond(context, head)
        }
    }

    private func respond(_ context: ChannelHandlerContext, _ request: HTTPRequestHead) {
        let chunked = request.headers["Transfer-Encoding"].contains { $0.lowercased().contains("chunked") }
        let answer = engine.answer(request.method, request.uri, body: body, chunked: chunked)
        // Asked now, answered later: a slow engine.
        let delay = engine.delay(of: request.uri)
        guard delay > 0 else { return send(answer, context, request) }
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.eventLoop.scheduleTask(in: .milliseconds(Int64(delay))) { [self] in send(answer, bound.value, request) }
    }

    private func send(_ answer: FakeDockerEngine.Answer, _ context: ChannelHandlerContext, _ request: HTTPRequestHead) {
        let channel = context.channel
        func headers(_ pairs: [(String, String)]) -> HTTPHeaders {
            var headers = HTTPHeaders(pairs)
            headers.add(name: "Server", value: "Overterm-fake-docker")
            return headers
        }
        func whole(_ status: Int, _ data: Data, _ extra: [(String, String)] = []) {
            var head = HTTPResponseHead(version: request.version, status: HTTPResponseStatus(statusCode: status), headers: headers(extra))
            head.headers.add(name: "Content-Length", value: "\(request.method == .HEAD ? 0 : data.count)")
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            if request.method != .HEAD, !data.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: data)))), promise: nil) }
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        }
        func open(_ contentType: String) {
            var head = HTTPResponseHead(version: request.version, status: .ok, headers: headers([("Content-Type", contentType)]))
            head.headers.add(name: "Transfer-Encoding", value: "chunked")
            context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
        }
        switch answer {
        case .json(let status, let data): whole(status, data, [("Content-Type", "application/json")])
        case .empty(let status): whole(status, Data())
        case .raw(let status, let data, let extra): whole(status, data, extra)
        case .notFound: whole(404, Data(#"{"message":"page not found"}"#.utf8))
        case .never: break
        case .events:
            open("application/json")
            engine.listen(channel)
        case .follow(let id, let frames):
            open("application/vnd.docker.multiplexed-stream")
            if !frames.isEmpty { context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: frames)))), promise: nil) }
            engine.follow(id, channel)
        case .stats(let id):
            open("application/json")
            let ticks = Ticks()
            let engine = engine
            engine.sample(channel)
            statsTask = channel.eventLoop.scheduleRepeatedTask(initialDelay: .zero, delay: .milliseconds(200)) { _ in
                let sample = engine.statsSample(id, tick: ticks.next())
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: sample))), promise: nil)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        statsTask?.cancel()
        engine.forget(context.channel)
    }
}

/// A stats stream's count, on its event loop only.
private final class Ticks: @unchecked Sendable {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
