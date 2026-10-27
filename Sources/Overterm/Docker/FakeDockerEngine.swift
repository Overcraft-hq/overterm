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
        /// Each line with the time it was written, as the engine keeps it.
        var logs: [(stream: DockerLogChunk.Stream, text: String, time: String)] = []
        var error: String = ""
    }

    let socket: String
    private let lock = NSLock()
    private var containers: [String: Container] = [:]
    private var images: [ImageSummary] = []
    private var volumes: [VolumeSummary] = []
    private var networks: [NetworkSummary] = []
    /// Bytes of build cache not in use.
    var buildCache = 0
    private var eventStreams: [ObjectIdentifier: Channel] = [:]
    private var logFollowers: [String: [Channel]] = [:]
    private var samplers: [ObjectIdentifier: Channel] = [:]
    private var channel: Channel?
    private var asked: [String] = []

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

    func stop() {
        let open = locked { Array(eventStreams.values) + Array(samplers.values) + logFollowers.values.flatMap { $0 } }
        open.forEach { $0.close(promise: nil) }
        try? channel?.close().wait()
        try? FileManager.default.removeItem(atPath: socket)
    }

    // MARK: State, as a test sets it

    /// A container; a compose service when `project` is given.
    @discardableResult
    func add(
        name: String, image: String = "debian:bookworm-slim", state: ContainerState = .running, project: String? = nil, workingDir: String? = nil,
        service: String? = nil, ports: [DockerPort] = [], env: [String] = [], health: String? = nil, imageID: String? = nil,
        volumes: [String] = []
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
                labels["com.docker.compose.project.config_files"] = workingDir + "/compose.yaml"
            }
        }
        let status = Self.status(state, health: health)
        let summary = ContainerSummary(
            Id: id, Names: ["/" + name], Image: image, ImageID: imageID ?? "sha256:" + String(repeating: "a", count: 64), Command: "sleep infinity",
            Created: Int(Date().timeIntervalSince1970), Ports: ports, Labels: labels, State: state.rawValue, Status: status,
            Mounts: volumes.map { DockerMountPoint(Type: "volume", Name: $0, Destination: "/data") },
            Health: health.map { .init(Status: $0, FailingStreak: 0) })
        locked { containers[id] = Container(summary: summary, env: env) }
        emit("create", id)
        return id
    }

    static func status(_ state: ContainerState, health: String? = nil, exitCode: Int = 0) -> String {
        switch state {
        case .running: health.map { "Up 2 minutes (\($0))" } ?? "Up 2 minutes"
        case .paused: "Up 2 minutes (Paused)"
        case .exited: "Exited (\(exitCode)) 3 seconds ago"
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

    func file(_ id: String, _ path: String) -> Data? { locked { containers[id]?.files[path] } }

    func setFile(_ id: String, _ path: String, _ data: Data) { locked { containers[id]?.files[path] = data } }

    /// An image; untagged (`<none>`) when `tag` is nil. Its id back.
    @discardableResult
    func addImage(_ tag: String?, size: Int, containers: Int = 0) -> String {
        let seed = tag ?? UUID().uuidString
        let image = ImageSummary(
            Id: "sha256:" + String(seed.utf8.map { String(format: "%02x", $0) }.joined().prefix(64)).padding(toLength: 64, withPad: "0", startingAt: 0),
            RepoTags: tag.map { [$0] } ?? ["<none>:<none>"], RepoDigests: [], Created: Int(Date().timeIntervalSince1970) - 86_400, Size: size,
            Containers: containers, Labels: [:])
        locked { images.append(image) }
        return image.Id
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

    enum Answer {
        case json(Int, Data)
        case empty(Int)
        case raw(Int, Data, [(String, String)])
        /// Stays open; the engine writes to it later.
        case events
        case follow(String, Data)
        case stats(String)
        case notFound
    }

    func answer(_ method: HTTPMethod, _ uri: String, body: Data) -> Answer {
        locked { asked.append("\(method.rawValue) \(uri)") }
        guard let url = URLComponents(string: "http://docker" + uri) else { return .notFound }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.first?.hasPrefix("v1.") == true { parts.removeFirst() }
        guard let kind = parts.first else { return .notFound }
        // `containers/<id>/logs` → id and `logs`; `containers/json` → no id.
        let named = ["containers", "images", "volumes", "networks"].contains(kind) && parts.count > 1 && !["json", "prune", "create"].contains(parts[1])
        let id = named ? parts[1] : ""
        let verb = named ? parts.dropFirst(2).joined(separator: "/") : parts.dropFirst().joined(separator: "/")
        switch kind {
        case "_ping": return .raw(200, Data("OK".utf8), [("API-Version", "1.47"), ("Docker-Experimental", "false")])
        case "info": return info()
        case "events": return .events
        case "system" where verb == "df": return diskUsage()
        case "build" where verb == "prune":
            let freed = locked { buildCache }
            locked { buildCache = 0 }
            return Self.json(PruneReport(SpaceReclaimed: freed, CachesDeleted: freed > 0 ? ["cache"] : []))
        case "containers" where verb == "prune", "images" where verb == "prune", "volumes" where verb == "prune", "networks" where verb == "prune":
            return Self.json(prune(kind, all: (query["filters"] ?? "").contains("\"dangling\":[\"false\"]") || (query["filters"] ?? "").contains("\"all\"")))
        case "containers": return named ? container(method, id, verb, query, body) : containerList(query)
        case "images" where named && verb == "history": return image(id).map { Self.json(Self.history(of: $0)) } ?? Self.error(404, "No such image: \(id)")
        case "images" where named && verb == "json": return image(id).map { Self.json($0) } ?? Self.error(404, "No such image: \(id)")
        case "images" where named && verb == "tag":
            guard let found = image(id) else { return Self.error(404, "No such image: \(id)") }
            let name = (query["repo"] ?? "") + ":" + (query["tag"] ?? "latest")
            locked { if let at = images.firstIndex(where: { $0.Id == found.Id }) { images[at].RepoTags = (images[at].RepoTags ?? []) + [name] } }
            emitImage("tag", found.Id)
            return .empty(201)
        case "images" where !named && verb == "create": return pull((query["fromImage"] ?? "") + ":" + (query["tag"] ?? "latest"))
        case "images", "volumes", "networks": return other(method, kind, id, named)
        default: return Self.error(404, "page not found")
        }
    }

    static func json<T: Encodable>(_ value: T) -> Answer { .json(200, (try? JSONEncoder().encode(value)) ?? Data()) }

    static func error(_ status: Int, _ message: String) -> Answer {
        .json(status, (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data())
    }

    private func info() -> Answer {
        let (count, running, imageCount) = locked { (containers.count, containers.values.filter { $0.summary.state == .running }.count, images.count) }
        return Self.json(
            EngineInfo(
                Name: "fake", OperatingSystem: "Overterm's fake engine", ServerVersion: "29.0.0", NCPU: 4, MemTotal: 8 << 30, Containers: count,
                ContainersRunning: running, Images: imageCount))
    }

    private func diskUsage() -> Answer {
        let usage = locked {
            DockerDiskUsage(
                LayersSize: images.reduce(0) { $0 + $1.Size }, Images: images, Containers: [], Volumes: volumes,
                BuildCache: buildCache > 0 ? [.init(ID: "cache", Size: buildCache, InUse: false, Shared: false)] : [])
        }
        return Self.json(usage)
    }

    private func containerList(_ query: [String: String]) -> Answer {
        let all = query["all"] == "1"
        let list = locked { containers.values.map(\.summary) }
        return Self.json(list.filter { all || $0.state == .running }.sorted { $0.name < $1.name })
    }

    private func container(_ method: HTTPMethod, _ id: String, _ verb: String, _ query: [String: String], _ body: Data) -> Answer {
        let found = locked { containers[id] ?? containers.values.first { $0.summary.name == id } }
        guard let container = found else { return Self.error(404, "No such container: \(id)") }
        let id = container.summary.Id
        let path = query["path"] ?? ""
        switch (method, verb) {
        case (.GET, "json"):
            return Self.json(Self.detail(container))
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
        case (.GET, "stats"):
            return .stats(id)
        case (.HEAD, "archive"):
            guard let data = container.files[path] else { return Self.error(404, "Could not find the file \(path) in container \(id)") }
            let stat = DockerTar.PathStat(name: (path as NSString).lastPathComponent, size: data.count, mode: 0o644, mtime: Self.timestamp(), linkTarget: "")
            return .raw(200, Data(), [("X-Docker-Container-Path-Stat", (try? JSONEncoder().encode(stat))?.base64EncodedString() ?? "")])
        case (.GET, "archive"):
            guard let data = container.files[path], let archive = DockerTar.archive(name: (path as NSString).lastPathComponent, data: data) else {
                return Self.error(404, "Could not find the file \(path) in container \(id)")
            }
            return .raw(200, archive, [("Content-Type", "application/x-tar")])
        case (.PUT, "archive"):
            for entry in DockerTar.entries(of: body) where entry.kind == .file {
                setFile(id, ((query["path"] ?? "/") as NSString).appendingPathComponent(entry.name), entry.data)
            }
            return .empty(200)
        default:
            return Self.error(404, "page not found")
        }
    }

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
    /// the image there. `private/…` names are refused, as a registry that
    /// wants credentials does.
    private func pull(_ name: String) -> Answer {
        if name.hasPrefix("private/") {
            return .json(
                200, Data(#"{"errorDetail":{"message":"pull access denied"},"error":"pull access denied for private, repository does not exist or may require 'docker login'"}"#.utf8 + [0x0A]))
        }
        let lines = [
            #"{"status":"Pulling from library/\#(name)","id":"latest"}"#, #"{"status":"Pulling fs layer","progressDetail":{},"id":"l1"}"#,
            #"{"status":"Downloading","progressDetail":{"current":512,"total":2048},"id":"l1"}"#,
            #"{"status":"Download complete","progressDetail":{},"id":"l1"}"#, #"{"status":"Pull complete","progressDetail":{},"id":"l1"}"#,
            #"{"status":"Status: Downloaded newer image for \#(name)"}"#,
        ]
        addImage(name, size: 2048)
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

    private func other(_ method: HTTPMethod, _ kind: String, _ id: String, _ named: Bool) -> Answer {
        switch (method, kind, named) {
        case (.GET, "images", false): return Self.json(locked { images })
        case (.GET, "volumes", false): return Self.json(VolumeList(Volumes: locked { volumes }, Warnings: nil))
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
        return ContainerDetail(
            Id: summary.Id, Name: "/" + summary.name, Created: nil, Image: summary.ImageID, RestartCount: 0, Platform: "linux",
            State: .init(
                Status: summary.State, Running: summary.state == .running, Paused: summary.state == .paused, Restarting: false, OOMKilled: false,
                Dead: false, Pid: summary.state == .running ? 42 : 0, ExitCode: summary.exitCode ?? 0, Error: container.error, StartedAt: nil,
                FinishedAt: nil, Health: summary.Health.map { .init(Status: $0.Status, FailingStreak: 0, Log: []) }),
            Config: .init(
                Image: summary.Image, Env: container.env, Cmd: ["sleep", "infinity"], Entrypoint: nil, WorkingDir: "/", User: "",
                Labels: summary.Labels, ExposedPorts: nil, Tty: container.tty, Hostname: String(summary.Id.prefix(12))),
            HostConfig: .init(RestartPolicy: .init(Name: "no", MaximumRetryCount: 0), NetworkMode: "bridge", Memory: 0, NanoCpus: 0),
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
        switch engine.answer(request.method, request.uri, body: body) {
        case .json(let status, let data): whole(status, data, [("Content-Type", "application/json")])
        case .empty(let status): whole(status, Data())
        case .raw(let status, let data, let extra): whole(status, data, extra)
        case .notFound: whole(404, Data(#"{"message":"page not found"}"#.utf8))
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
