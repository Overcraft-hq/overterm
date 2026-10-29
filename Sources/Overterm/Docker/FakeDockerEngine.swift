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
        /// What an archive put in besides files' bytes: their modes, its
        /// folders (an empty one too), its links — as a listing and a GET
        /// give them back.
        var modes: [String: Int] = [:]
        var folders: Set<String> = []
        var links: [String: String] = [:]
        /// `--read-only`: an archive into it is refused, as the engine
        /// refuses it.
        var readOnly = false
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
        /// Its limits and restart policy, as inspect says them and
        /// `update` changes them.
        var hostConfig = ContainerDetail.HostConfigDetail(
            RestartPolicy: .init(Name: "no", MaximumRetryCount: 0), NetworkMode: "bridge", Memory: 0, NanoCpus: 0, MemorySwap: 0, CpuQuota: 0,
            CpuPeriod: 0, AutoRemove: false)
        var healthcheck: [String]?
        /// What it runs, as inspect says it (`setCommand`).
        var cmd = ["sleep", "infinity"]
        var entrypoint: [String]?
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
        /// What its create asked for, when it was made through the API.
        var created: CreateRequest?
    }

    /// A `POST /containers/create` body, as far as the fake reads it.
    struct CreateRequest: Decodable, Sendable {
        struct Host: Decodable, Sendable {
            var Binds: [String]?
            var AutoRemove: Bool?
            var NetworkMode: String?
        }
        var Image: String
        var Entrypoint: [String]?
        var Cmd: [String]?
        var Env: [String]?
        var User: String?
        var WorkingDir: String?
        var Labels: [String: String]?
        var HostConfig: Host?
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
    /// By tag: what its registry names now (`setRegistryDigest`).
    private var registryDigests: [String: String] = [:]
    private var volumes: [VolumeSummary] = []
    private var networks: [NetworkSummary] = []
    /// What each volume holds, by path in it — when each was written, and
    /// whose it is.
    private var volumeFiles: [String: [String: Data]] = [:]
    private var volumeMtimes: [String: [String: String]] = [:]
    private var volumeOwners: [String: [String: (uid: Int, gid: Int)]] = [:]
    /// Images with no `sh` (distroless): a container of one whose
    /// entrypoint is `sh` doesn't start.
    private var shellless: Set<String> = []
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
    /// moby's `refreshImage`: a container whose image's name now names
    /// another image (a pull moved the tag) is listed by its image's ID.
    /// Off unless a test asks: most of the fake's containers name images
    /// it doesn't have.
    var refreshesImages = false
    /// How long an image's inspect takes, in milliseconds: a remote
    /// engine's round trip.
    var imageInspectDelay = 0
    /// How long a running container's removal takes, in milliseconds: its
    /// kill and its rootfs. Meanwhile it is still there, holding its
    /// volumes, and a second removal is refused as moby refuses it
    /// (`SetRemovalInProgress`).
    var removalDelay = 0
    private var removing: Set<String> = []
    /// Starts refused for a container that mounts the volume, as the
    /// engine says why (`failStarts`).
    private var startFailures: [String: String] = [:]
    /// Each image's platforms, by id: one in the classic store, what its
    /// index holds in the containerd store.
    private var imagePlatforms: [String: [ImagePlatform]] = [:]
    private var execs: [String: (container: String, command: [String])] = [:]
    private var committed: [Commit] = []
    /// What a committed image holds of a config, by its id.
    private var imageRecords: [String: ImageRecord] = [:]

    /// What an image holds of a config, as its inspect says it: `Config`;
    /// in the classic store `ContainerConfig` too, the committed
    /// container's own as it was — the engine writes it whatever the
    /// changes; and the image it was made from.
    struct ImageRecord: Sendable {
        var config: ContainerDetail.Config
        var containerConfig: ContainerDetail.Config?
        var parent: String?
    }

    /// A `docker commit` as the engine was asked it.
    struct Commit: Equatable, Sendable {
        var container: String
        var repo: String
        var tag: String
        var comment: String
        /// Its Dockerfile lines, as sent: one string, a line each.
        var changes: String
        /// Nil when not said: the engine pauses it then.
        var pause: String?
    }
    private var exitCodes: [String: Int] = [:]
    private var eventStreams: [ObjectIdentifier: Channel] = [:]
    private var logFollowers: [String: [Channel]] = [:]
    private var samplers: [ObjectIdentifier: Channel] = [:]
    private var channel: Channel?
    private var tcpChannels: [Channel] = []
    private var asked: [String] = []
    /// Requests whose whole answer the client has taken off the socket.
    private var delivered: [String] = []
    /// Requests whose bodies are never read, by a part of their URI.
    private var stalling: [String] = []
    /// Removals refused, by the container's id or name, or the volume's,
    /// image's or network's: what the engine answers instead.
    private var refusals: [String: (status: Int, message: String)] = [:]
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

    /// A container; a compose service when `project` is given. `labels`
    /// go over Compose's (Testcontainers' own); `created` is now unless
    /// said.
    @discardableResult
    func add(
        name: String, image: String = "debian:bookworm-slim", state: ContainerState = .running, project: String? = nil, workingDir: String? = nil,
        service: String? = nil, ports: [DockerPort] = [], env: [String] = [], health: String? = nil, imageID: String? = nil,
        volumes: [String] = [], configFiles: [String]? = nil, labels extra: [String: String] = [:], created: Int? = nil
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
        labels.merge(extra) { $1 }
        let status = Self.status(state, health: health)
        let platform = imageID.flatMap { id in locked { imagePlatforms[id].map(bestPlatform) } }
        let summary = ContainerSummary(
            Id: id, Names: ["/" + name], Image: image, ImageID: imageID ?? "sha256:" + String(repeating: "a", count: 64), Command: "sleep infinity",
            Created: created ?? Int(Date().timeIntervalSince1970), Ports: ports, Labels: labels, State: state.rawValue, Status: status,
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
        // `--rm`: gone once it ends, as the engine removes it.
        if state == .exited, locked({ containers[id]?.hostConfig.AutoRemove == true }) {
            emit("destroy", id)
            locked { _ = containers.removeValue(forKey: id) }
        }
    }

    /// A container that removes itself (AutoRemove) ends by itself: its
    /// sleep was up.
    func expire(_ id: String) { set(id, state: .exited) }

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
            containers[id]?.hostConfig.RestartPolicy = .init(Name: restartPolicy, MaximumRetryCount: 0)
            containers[id]?.hostConfig.Memory = memory
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

    /// A file's mode, as an archive set it (0o644 unless one did).
    func fileMode(_ id: String, _ path: String) -> Int? {
        locked { containers[id]?.files[path] == nil ? nil : containers[id]?.modes[path] ?? 0o644 }
    }

    /// A folder's mode, when an archive's entry for it set one: a folder
    /// merged into keeps none of its own here.
    func folderMode(_ id: String, _ path: String) -> Int? {
        locked { containers[id].flatMap { $0.files[path] == nil && $0.links[path] == nil ? $0.modes[path] : nil } }
    }

    /// A link an archive made, its target.
    func link(_ id: String, _ path: String) -> String? { locked { containers[id]?.links[path] } }

    /// Its rootfs read-only from now on (`--read-only`), or not.
    func setReadOnly(_ id: String, _ readOnly: Bool) { locked { containers[id]?.readOnly = readOnly } }

    /// Its limits and restart policy now.
    func hostConfig(_ id: String) -> ContainerDetail.HostConfigDetail? { locked { containers[id]?.hostConfig } }

    /// As it was made: `-m`, `--cpu-quota`, `--rm`. Sends no event.
    func setHostConfig(_ id: String, _ change: (inout ContainerDetail.HostConfigDetail) -> Void) {
        locked {
            guard var host = containers[id]?.hostConfig else { return }
            change(&host)
            containers[id]?.hostConfig = host
        }
    }

    /// The commits asked for, in order.
    var commits: [Commit] { locked { committed } }

    /// What a committed image holds, by its id or a tag.
    func imageRecord(_ reference: String) -> ImageRecord? {
        locked {
            let id = images.first { $0.Id == reference || $0.tags.contains(reference) }?.Id ?? reference
            return imageRecords[id]
        }
    }

    /// Every image, those the list leaves out (a layer's parent) too.
    var allImages: [ImageSummary] { locked { images } }

    /// What a tag (`nginx:1.27`) names in its registry now: a pull of it
    /// brings that image, or says it is up to date.
    func setRegistryDigest(_ reference: String, _ digest: String) { locked { registryDigests[reference] = digest } }

    /// The image a container runs, as if made from it.
    func setImageID(_ id: String, _ imageID: String) {
        locked { containers[id]?.summary.ImageID = imageID }
        emit("update", id)
    }

    /// What it runs, as it was made.
    func setCommand(_ id: String, _ cmd: [String], entrypoint: [String]? = nil, healthcheck: [String]? = nil) {
        locked {
            containers[id]?.cmd = cmd
            containers[id]?.entrypoint = entrypoint
            if let healthcheck { containers[id]?.healthcheck = healthcheck }
        }
    }

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
    /// containerd store the platform joins the tag's index. `digest`: the
    /// one its registry gave it, recorded as `RepoDigests` (`nginx@…`), as
    /// a pull records it; none, it was built or tagged here. Another digest
    /// is another image. The containerd store records one for every named
    /// image, a build's too: its own ID, the index's digest.
    @discardableResult
    func addImage(
        _ tag: String?, size: Int, containers: Int = 0, architecture: String = "arm64", variant: String? = nil, labels: [String: String] = [:],
        shell: Bool = true, digest: String? = nil
    ) -> String {
        let platform = ImagePlatform(architecture: architecture, variant: variant)
        let index = locked { containerdStore }
        let name = (tag ?? UUID().uuidString) + (digest.map { "@" + $0 } ?? "")
        let id = index ? digest ?? Self.imageID(name) : Self.imageID(architecture == "arm64" ? name : architecture + (variant.map { "/" + $0 } ?? "") + "@" + name)
        let recorded = index ? id : digest
        let image = ImageSummary(
            Id: id, RepoTags: tag.map { [$0] } ?? ["<none>:<none>"],
            RepoDigests: tag.flatMap { tag in recorded.map { [DockerEngine.split(tag).0 + "@" + $0] } } ?? [],
            Created: Int(Date().timeIntervalSince1970) - 86_400, Size: size, Containers: containers, Labels: labels)
        locked {
            if index, let at = images.firstIndex(where: { $0.Id == image.Id }) {
                if imagePlatforms[image.Id]?.contains(platform) != true { imagePlatforms[image.Id, default: []].append(platform) }
                // Another name for the same index: one image, both tags.
                if let tag, images[at].RepoTags?.contains(tag) != true {
                    images[at].RepoTags = (images[at].RepoTags ?? []).filter { $0 != "<none>:<none>" } + [tag]
                    images[at].RepoDigests = (images[at].RepoDigests ?? []) + (image.RepoDigests ?? [])
                }
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
            if shell { shellless.remove(image.Id) } else { shellless.insert(image.Id) }
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

    func addVolume(_ name: String, size: Int, refCount: Int, project: String? = nil, anonymous: Bool = false, labels extra: [String: String] = [:]) {
        var labels = project.map { ["com.docker.compose.project": $0] } ?? [:]
        if anonymous { labels["com.docker.volume.anonymous"] = "" }
        labels.merge(extra) { $1 }
        let volume = VolumeSummary(
            Name: name, Driver: "local", Mountpoint: "/var/lib/docker/volumes/\(name)/_data", CreatedAt: nil,
            Labels: labels, Scope: "local", UsageData: .init(Size: size, RefCount: refCount))
        locked { volumes.append(volume) }
    }

    func addNetwork(_ name: String, members: [String] = [], labels: [String: String] = [:]) {
        let network = NetworkSummary(
            Name: name, Id: name + "-id", Driver: name == "host" || name == "none" ? name : "bridge", Scope: "local",
            Containers: Dictionary(uniqueKeysWithValues: members.map { ($0, .init(Name: nil, IPv4Address: "172.18.0.2/16")) }), Labels: labels,
            IPAM: .init(Driver: "default", Config: [.init(Subnet: "172.18.0.0/16", Gateway: "172.18.0.1")]))
        locked { networks.append(network) }
    }

    /// The networks there are now, by name.
    var networkNames: [String] { locked { networks.map(\.Name) } }
    /// The volumes there are now, by name.
    var volumeNames: [String] { locked { volumes.map(\.Name) } }
    /// The images there are now, by id.
    var imageIDs: [String] { locked { images.map(\.Id) } }

    /// A removal the engine refuses from now on, as it answers one —
    /// `409 "removal of container … is already in progress"`, a driver's
    /// `500`: by the container's id or name, the volume's name, the
    /// image's id or the network's name.
    func refuseRemoval(of name: String, _ status: Int, _ message: String) { locked { refusals[name] = (status, message) } }

    /// The refusal for any of these names, when a test set one.
    private func refusal(_ names: String...) -> Answer? {
        let refused = locked { () -> (status: Int, message: String)? in
            for name in names { if let refusal = refusals[name] { return refusal } }
            return nil
        }
        return refused.map { Self.error($0.status, $0.message) }
    }

    var containerIDs: [String] { locked { Array(containers.keys) } }

    /// Every request so far, `GET /v1.47/containers/json?all=1`.
    var requests: [String] { locked { asked } }

    /// The requests whose whole answer has been written to the client: one
    /// that reads only as fast as it writes to disk takes a big file's
    /// later than it is asked.
    var answered: [String] { locked { delivered } }

    fileprivate func answerWritten(_ method: HTTPMethod, _ uri: String) { locked { delivered.append("\(method.rawValue) \(uri)") } }

    /// From now on, a request whose URI has `fragment` is never read past
    /// its head: a client writing its body waits, as for an engine that
    /// has stopped taking it.
    func stall(_ fragment: String) { locked { stalling.append(fragment) } }

    fileprivate func stalls(_ uri: String) -> Bool { locked { stalling.contains { uri.contains($0) } } }

    /// The next `count` requests' connections are closed unanswered, as a
    /// busy engine's socket can drop a new one.
    func drop(_ count: Int) { locked { dropping = count } }
    private var dropping = 0

    fileprivate func takeDrop() -> Bool {
        locked {
            guard dropping > 0 else { return false }
            dropping -= 1
            return true
        }
    }

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
        /// Answered after `ms`, once `then` has run: a slow engine's work,
        /// done while the request waits.
        indirect case later(Int, Answer, @Sendable () -> Void)
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
        case "commit" where method == .POST: return commit(query)
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
        let (count, running, imageCount, machine, index) = locked {
            (containers.count, containers.values.filter { $0.summary.state == .running }.count, images.count, architecture, containerdStore)
        }
        return Self.json(
            EngineInfo(
                Name: "fake", OperatingSystem: "Overterm's fake engine", ServerVersion: "29.0.0", NCPU: 4, MemTotal: 8 << 30, Containers: count,
                ContainersRunning: running, Images: imageCount, Architecture: machine, OSType: "linux",
                DriverStatus: index ? [["driver-type", "io.containerd.snapshotter.v1"]] : [["Backing Filesystem", "extfs"], ["Supports d_type", "true"]]))
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
        if let record = locked({ imageRecords[image.Id] }) {
            func json(_ config: ContainerDetail.Config) -> Any? {
                (try? JSONEncoder().encode(config)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            object["Config"] = json(record.config)
            if let config = record.containerConfig { object["ContainerConfig"] = json(config) }
            object["Parent"] = record.parent ?? ""
        }
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
        if refreshesImages, let imageID = summary.ImageID, summary.Image != imageID,
            let named = images.first(where: { $0.RepoTags?.contains(summary.Image) == true }), named.Id != imageID
        {
            summary.Image = imageID
        }
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
        case (.POST, "start") where locked({ container.binds.values.contains { startFailures[$0] != nil } }):
            return Self.error(500, locked { container.binds.values.compactMap { startFailures[$0] }.first } ?? "")
        case (.POST, "start") where (container.entrypoint ?? container.cmd).first == "sh" && locked({ shellless.contains(container.summary.ImageID ?? "") }):
            // As runc says it; the container stays created.
            return Self.error(
                400,
                #"failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: unable to start container process: exec: "sh": executable file not found in $PATH: unknown"#
            )
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
            if let refused = refusal(id, container.summary.name) { return refused }
            if container.summary.state == .running, query["force"] != "1" {
                return Self.error(409, "cannot remove container \(container.summary.name): container is running: stop the container before removing or force remove")
            }
            let (wait, first) = locked { (removalDelay, container.summary.state == .running ? removing.insert(id).inserted : true) }
            guard first else { return Self.error(409, "removal of container \(id) is already in progress") }
            guard wait > 0, container.summary.state == .running else {
                emit("destroy", id)
                locked { _ = containers.removeValue(forKey: id) }
                return .empty(204)
            }
            return .later(wait, .empty(204)) { [self] in
                emit("destroy", id)
                locked {
                    _ = containers.removeValue(forKey: id)
                    _ = removing.remove(id)
                }
            }
        case (.POST, "update"):
            guard let change = try? JSONDecoder().decode(DockerEngine.ContainerUpdate.self, from: body) else { return Self.error(400, "bad request") }
            return update(id, change, container.hostConfig)
        case (.POST, "rename"):
            return rename(id, to: query["name"] ?? "", from: container.summary.name)
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
        case (.HEAD, "archive") where volumePath(path, in: container) != nil:
            guard let (volume, inside) = volumePath(path, in: container), let stat = volumeStat(volume, inside) else {
                return Self.error(404, "Could not find the file \(path) in container \(id)")
            }
            return .raw(200, Data(), [("X-Docker-Container-Path-Stat", (try? JSONEncoder().encode(stat))?.base64EncodedString() ?? "")])
        case (.HEAD, "archive"):
            let at = Self.normal(path)
            let name = at == "/" ? "/" : (at as NSString).lastPathComponent
            let stat: DockerTar.PathStat
            if let data = container.files[at] {
                stat = DockerTar.PathStat(
                    name: name, size: data.count, mode: UInt32(container.modes[at] ?? 0o644), mtime: container.mtimes[at] ?? "2026-01-01T00:00:00Z",
                    linkTarget: "")
            } else if let target = container.links[at] {
                stat = DockerTar.PathStat(name: name, size: target.utf8.count, mode: UInt32(1 << 27 | 0o777), mtime: "2026-01-01T00:00:00Z", linkTarget: target)
            } else if Self.isFolder(at, in: container) {
                stat = DockerTar.PathStat(name: name, size: 4096, mode: UInt32(1 << 31 | 0o755), mtime: "2026-01-01T00:00:00Z", linkTarget: "")
            } else {
                return Self.error(404, "Could not find the file \(path) in container \(id)")
            }
            return .raw(200, Data(), [("X-Docker-Container-Path-Stat", (try? JSONEncoder().encode(stat))?.base64EncodedString() ?? "")])
        case (.GET, "archive"):
            // In a mounted volume: the mount point its whole tree, under the
            // folder's own name; a file in it alone, with its owner.
            if let (volume, inside) = volumePath(path, in: container) {
                guard let archive = volumeArchive(volume, inside, top: (path as NSString).lastPathComponent) else {
                    return Self.error(404, "Could not find the file \(path) in container \(id)")
                }
                return .raw(200, archive, [("Content-Type", "application/x-tar")])
            }
            let at = Self.normal(path)
            if let data = container.files[at] {
                guard let archive = DockerTar.archive(name: (at as NSString).lastPathComponent, data: data, mode: container.modes[at] ?? 0o644) else {
                    return Self.error(500, "\(at): the name is too long")
                }
                return .raw(200, archive, [("Content-Type", "application/x-tar")])
            }
            guard Self.isFolder(at, in: container) else { return Self.error(404, "Could not find the file \(path) in container \(id)") }
            return .raw(200, Self.folderArchive(at, of: container), [("Content-Type", "application/x-tar")])
        case (.PUT, "archive"):
            return put(body, into: Self.normal(query["path"] ?? "/"), of: container, noOverwrite: query["noOverwriteDirNonDir"] == "true")
        case (.GET, "export"):
            let archive = container.files.sorted { $0.key < $1.key }.reduce(into: Data()) { out, file in
                out += (DockerTar.archive(name: String(file.key.dropFirst()), data: file.value) ?? Data()).dropLast(2 * DockerTar.block)
            }
            return .raw(200, archive + Data(count: 2 * DockerTar.block), [("Content-Type", "application/x-tar")])
        default:
            return Self.error(404, "page not found")
        }
    }

    /// An archive into `folder`, as moby's `Unpack` takes it: the folder
    /// must be there and be one, the rootfs writable; a same-named folder
    /// is merged, anything else replaced — but with `noOverwriteDirNonDir`
    /// (what `docker cp` sends) a file never replaces a folder, nor a
    /// folder a file, in its words. Entries before the one refused stay
    /// written, as there. Into a mounted volume: its files, owned as the
    /// entry says (no copyUIDGID: the tar's owner).
    private func put(_ body: Data, into folder: String, of container: Container, noOverwrite: Bool) -> Answer {
        let id = container.summary.Id
        if let refused = refusal(into: folder, of: container) { return refused }
        for entry in DockerTar.entries(of: body) {
            let full = Self.normal((folder as NSString).appendingPathComponent(entry.name))
            if let (mount, volume) = container.binds.first(where: { full.hasPrefix($0.key + "/") }) {
                guard entry.kind == .file else { continue }
                let inside = String(full.dropFirst(mount.count + 1))
                let now = Self.timestamp()
                locked {
                    volumeFiles[volume, default: [:]][inside] = entry.data
                    volumeMtimes[volume, default: [:]][inside] = now
                    volumeOwners[volume, default: [:]][inside] = (entry.uid, entry.gid)
                }
                continue
            }
            // A volume's mount point itself (an import's `volume/`).
            if container.binds.keys.contains(full) { continue }
            let now = locked { containers[id] } ?? container
            let isFolder = Self.isFolder(full, in: now)
            let isOther = now.files[full] != nil || now.links[full] != nil
            if entry.kind == .directory {
                if isOther {
                    if noOverwrite { return Self.error(500, "cannot overwrite non-directory \"\(full)\" with directory \"\(folder)\"") }
                    locked { Self.remove(full, from: &containers[id]) }
                }
                // Merged into one there, but given the entry's mode (and
                // owner), as moby's `createTarFile` does.
                locked {
                    _ = containers[id]?.folders.insert(full)
                    containers[id]?.modes[full] = entry.mode & 0o7777
                }
                continue
            }
            guard entry.kind == .file || entry.kind == .symlink else { continue }
            if isFolder {
                if noOverwrite { return Self.error(500, "cannot overwrite directory \"\(full)\" with non-directory \"\(folder)\"") }
                locked { Self.remove(full, from: &containers[id]) }
            }
            locked { Self.remove(full, from: &containers[id], folder: false) }
            if entry.kind == .file {
                setFile(id, full, entry.data)
                locked { containers[id]?.modes[full] = entry.mode & 0o7777 }
            } else {
                locked { containers[id]?.links[full] = entry.linkTarget }
            }
        }
        return .empty(200)
    }

    /// What moby refuses an archive for before it reads any of it: a
    /// folder that isn't there or isn't one, a read-only rootfs.
    private func refusal(into folder: String, of container: Container) -> Answer? {
        let id = container.summary.Id
        let inVolume = volumePath(folder, in: container)
        if let (volume, inside) = inVolume, folder != "/" {
            guard let stat = volumeStat(volume, inside) else { return Self.error(404, "Could not find the file \(folder) in container \(id)") }
            guard stat.isDirectory else { return Self.error(400, "extraction point is not a directory") }
        } else if inVolume == nil {
            guard Self.isFolder(folder, in: container) else {
                return container.files[folder] != nil
                    ? Self.error(400, "extraction point is not a directory") : Self.error(404, "Could not find the file \(folder) in container \(id)")
            }
            guard !container.readOnly else { return Self.error(400, "container rootfs is marked read-only") }
        }
        return nil
    }

    /// An answer at a request's head, its body unread — moby refuses an
    /// archive (`refusal`) before reading it, and closes: a client still
    /// writing a big one hears it after its write fails. Nil: read the
    /// body, then answer.
    func early(_ method: HTTPMethod, _ uri: String) -> Answer? {
        guard method == .PUT, let url = URLComponents(string: "http://docker" + uri) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("v1.") }
        guard parts.count == 3, parts[0] == "containers", parts[2] == "archive" else { return nil }
        guard let container = locked({ containers[parts[1]] }) else { return nil }
        let folder = Self.normal(url.queryItems?.first { $0.name == "path" }?.value ?? "/")
        guard let refused = refusal(into: folder, of: container) else { return nil }
        locked { asked.append("\(method.rawValue) \(uri)") }
        return refused
    }

    /// `/a/b/` → `/a/b`; `/` stays.
    static func normal(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// `/`, a folder an archive made, or one that has something in it.
    private static func isFolder(_ path: String, in container: Container) -> Bool {
        let path = normal(path)
        guard path != "/", !container.folders.contains(path) else { return true }
        let under = path + "/"
        return container.files.keys.contains { $0.hasPrefix(under) } || container.folders.contains { $0.hasPrefix(under) }
            || container.links.keys.contains { $0.hasPrefix(under) }
    }

    /// What is at `path` gone: a file, a link, or (`folder`) a folder and
    /// all in it.
    private static func remove(_ path: String, from container: inout Container?, folder: Bool = true) {
        guard var changed = container else { return }
        changed.files[path] = nil
        changed.modes[path] = nil
        changed.links[path] = nil
        if folder {
            let under = path + "/"
            changed.folders.remove(path)
            changed.folders = changed.folders.filter { !$0.hasPrefix(under) }
            changed.files = changed.files.filter { !$0.key.hasPrefix(under) }
            changed.modes = changed.modes.filter { !$0.key.hasPrefix(under) }
            changed.links = changed.links.filter { !$0.key.hasPrefix(under) }
        }
        container = changed
    }

    /// A folder's GET, as moby gives it: rebased to the folder's own name,
    /// its own entry first, each folder before what is in it, files with
    /// their modes, links as links.
    private static func folderArchive(_ path: String, of container: Container) -> Data {
        let top = path == "/" ? "." : (path as NSString).lastPathComponent
        let under = path == "/" ? "/" : path + "/"
        var folders = Set(container.folders.filter { $0.hasPrefix(under) })
        // The folders a file is in, from its own path's parts: never walked up.
        for file in Array(container.files.keys) + Array(container.links.keys) where file.hasPrefix(under) {
            let parts = file.dropFirst(under.count).split(separator: "/")
            for depth in 1..<max(parts.count, 1) { folders.insert(under + parts[..<depth].joined(separator: "/")) }
        }
        func name(_ full: String) -> String { top + "/" + full.dropFirst(under.count) }
        var entries: [(String, Data)] = []
        for folder in folders { entries.append((name(folder) + "/", DockerTar.header(name: name(folder) + "/", size: 0, mode: 0o755, modified: Date(), type: "5") ?? Data())) }
        for (file, data) in container.files where file.hasPrefix(under) {
            let entry = DockerTar.archive(name: name(file), data: data, mode: container.modes[file] ?? 0o644) ?? Data()
            entries.append((name(file), entry.dropLast(2 * DockerTar.block)))
        }
        for (link, target) in container.links where link.hasPrefix(under) {
            entries.append((name(link), DockerTar.header(name: name(link), size: 0, mode: 0o777, modified: Date(), type: "2", link: target) ?? Data()))
        }
        var archive = DockerTar.header(name: top + "/", size: 0, mode: 0o755, modified: Date(), type: "5") ?? Data()
        for (_, entry) in entries.sorted(by: { $0.0 < $1.0 }) { archive += entry }
        return archive + Data(count: 2 * DockerTar.block)
    }

    /// `docker update`, as moby v27 checks it, in its words: every 0 (or
    /// nothing) unchanged; a memory limit above the swap it has refused
    /// unless a swap comes with it; NanoCpus and a quota never both; no
    /// restart policy for a `--rm` one. Four CPUs, as `info` says.
    private func update(_ id: String, _ change: DockerEngine.ContainerUpdate, _ current: ContainerDetail.HostConfigDetail) -> Answer {
        let memory = change.Memory ?? 0
        let swap = change.MemorySwap ?? 0
        let nanos = change.NanoCpus ?? 0
        let quota = change.CpuQuota ?? 0
        let period = change.CpuPeriod ?? 0
        if memory != 0, memory < 6_291_456 { return Self.error(400, "Minimum memory limit allowed is 6MB") }
        if nanos < 0 || nanos > 4_000_000_000 { return Self.error(400, "Range of CPUs is from 0.01 to 4.00, as there are only 4 CPUs available") }
        if let policy = change.RestartPolicy, policy.Name != "on-failure", (policy.MaximumRetryCount ?? 0) != 0 {
            return Self.error(400, "invalid restart policy: maximum retry count can only be used with 'on-failure'")
        }
        let refused = "Cannot update container \(id): "
        if nanos > 0, (current.CpuPeriod ?? 0) > 0 {
            return Self.error(409, refused + "Conflicting options: Nano CPUs cannot be updated as CPU Period has already been set")
        }
        if nanos > 0, (current.CpuQuota ?? 0) > 0 {
            return Self.error(409, refused + "Conflicting options: Nano CPUs cannot be updated as CPU Quota has already been set")
        }
        if period > 0, (current.NanoCpus ?? 0) > 0 {
            return Self.error(409, refused + "Conflicting options: CPU Period cannot be updated as NanoCPUs has already been set")
        }
        if quota > 0, (current.NanoCpus ?? 0) > 0 {
            return Self.error(409, refused + "Conflicting options: CPU Quota cannot be updated as NanoCPUs has already been set")
        }
        if memory != 0, memory > (current.MemorySwap ?? 0), swap == 0 {
            return Self.error(
                409, refused + "Memory limit should be smaller than already set memoryswap limit, update the memoryswap at the same time")
        }
        if let name = change.RestartPolicy?.Name, !["", "no"].contains(name), current.AutoRemove == true {
            return Self.error(409, refused + "Restart policy cannot be updated because AutoRemove is enabled for the container")
        }
        setHostConfig(id) { host in
            if memory != 0 { host.Memory = memory }
            if swap != 0 { host.MemorySwap = swap }
            if nanos != 0 { host.NanoCpus = nanos }
            if quota != 0 { host.CpuQuota = quota }
            if period != 0 { host.CpuPeriod = period }
            if let policy = change.RestartPolicy, let name = policy.Name, !name.isEmpty { host.RestartPolicy = policy }
        }
        emit("update", id)
        return .json(200, Data(#"{"Warnings":[]}"#.utf8))
    }

    /// `docker rename`, as moby answers it.
    private func rename(_ id: String, to name: String, from old: String) -> Answer {
        guard name.range(of: #"^/?[a-zA-Z0-9][a-zA-Z0-9_.-]+$"#, options: .regularExpression) != nil else {
            return Self.error(400, "Error when allocating new name: Invalid container name (/\(name)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if bare == old { return Self.error(400, "Renaming a container with the same name as its current name") }
        if let holder = locked({ containers.values.first { $0.summary.name == bare } }) {
            return Self.error(
                409,
                "Error when allocating new name: Conflict. The container name \"/\(bare)\" is already in use by container \"\(holder.summary.Id)\". You have to remove (or rename) that container to be able to reuse that name."
            )
        }
        locked { containers[id]?.summary.Names = ["/" + bare] }
        emit("rename", id, extra: ["oldName": "/" + old])
        return .empty(204)
    }

    /// `docker commit`: recorded as asked, and an image of that name made
    /// — untagged without one. Its config is the container's with the
    /// changes' `ENV` and `LABEL` put over it; in the classic store the
    /// container's own config goes in as well, as it was.
    private func commit(_ query: [String: String]) -> Answer {
        let wanted = query["container"] ?? ""
        guard let container = locked({ containers[wanted] ?? containers.values.first { $0.summary.name == wanted } }) else {
            return Self.error(404, "No such container: \(wanted)")
        }
        let id = container.summary.Id
        let repo = query["repo"] ?? ""
        let tag = query["tag"] ?? ""
        let changes = query["changes"] ?? ""
        let original = Self.detail(container).Config
        var config = original
        for line in changes.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let instruction = words.first?.uppercased(), ["ENV", "LABEL"].contains(instruction) else { continue }
            for word in words.dropFirst() {
                guard let equals = word.firstIndex(of: "=") else { continue }
                let key = String(word[..<equals])
                let value = String(word[word.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if instruction == "ENV" {
                    config.Env = (config.Env ?? []).filter { !$0.hasPrefix(key + "=") } + [key + "=" + value]
                } else {
                    config.Labels = (config.Labels ?? [:]).merging([key: value]) { $1 }
                }
            }
        }
        locked {
            committed.append(Commit(container: id, repo: repo, tag: tag, comment: query["comment"] ?? "", changes: changes, pause: query["pause"]))
        }
        let reference = repo.isEmpty ? nil : repo + ":" + (tag.isEmpty ? "latest" : tag)
        let image = addImage(reference, size: 1 << 20)
        locked {
            imageRecords[image] = ImageRecord(config: config, containerConfig: containerdStore ? nil : original, parent: container.summary.ImageID)
        }
        if reference != nil { emitImage("tag", image) }
        emit("commit", id, extra: ["imageRef": reference ?? image])
        return .json(201, Data(#"{"Id":"\#(image)"}"#.utf8))
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
        if command == ["sh", "-c", "true"] { return (0, "", "") }
        guard command.first == "sh", command.contains("overterm-ls"), let folder = command.last else {
            return (127, "", "\(command.first ?? ""): not found\n")
        }
        // In a mounted volume: its files, by their path in it.
        if let container = locked({ containers[id] }), let (volume, inside) = volumePath(folder, in: container) {
            return list(locked { volumeFiles[volume] ?? [:] }, under: inside.isEmpty ? "" : inside + "/", folder: folder, top: inside.isEmpty)
        }
        guard let container = locked({ containers[id] }) else { return (2, "", "No such folder: \(folder)\n") }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return list(
            container.files, under: prefix, folder: folder, top: Self.isFolder(folder, in: container), folders: container.folders, links: container.links)
    }

    /// The listing script's answer for `files` under `prefix` — and the
    /// folders and links an archive made.
    private func list(
        _ files: [String: Data], under prefix: String, folder: String, top: Bool, folders: Set<String> = [], links: [String: String] = [:]
    ) -> (Int, String, String) {
        var lines: [String: String] = [:]
        for path in Array(files.keys) + Array(folders) + Array(links.keys) where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                lines[name] = "d\t-\t\(name)"
            } else if folders.contains(path) {
                lines[String(rest)] = "d\t-\t\(rest)"
            } else if links[path] != nil {
                lines[String(rest)] = "l\t-\t\(rest)"
            } else if lines[String(rest)] == nil, let data = files[path] {
                lines[String(rest)] = "f\t\(data.count)\t\(rest)"
            }
        }
        guard !lines.isEmpty || top else { return (2, "", "No such folder: \(folder)\n") }
        return (0, lines.values.sorted().map { $0 + "\n" }.joined(), "")
    }

    /// A container made, not started: what the helper is. From a
    /// committed image, what it doesn't say is the image's — its command,
    /// env, labels and health check — as the engine merges them.
    private func create(_ body: Data, _ query: [String: String]) -> Answer {
        guard let request = try? JSONDecoder().decode(CreateRequest.self, from: body) else { return Self.error(400, "bad request") }
        if let name = query["name"], let holder = locked({ containers.values.first { $0.summary.name == name } }) {
            return Self.error(
                409,
                "Conflict. The container name \"/\(name)\" is already in use by container \"\(holder.summary.Id)\". You have to remove (or rename) that container to be able to reuse that name."
            )
        }
        let found = image(request.Image)
        let record = found.flatMap { found in locked { imageRecords[found.Id] } }
        let labels = (record?.config.Labels ?? [:]).merging(request.Labels ?? [:]) { $1 }
        let id = add(
            name: query["name"] ?? "helper-\(UUID().uuidString.prefix(6).lowercased())", image: request.Image, state: .created,
            env: request.Env ?? record?.config.Env ?? [], imageID: found?.Id, labels: labels)
        var binds: [String: String] = [:]
        for bind in request.HostConfig?.Binds ?? [] {
            let parts = bind.split(separator: ":").map(String.init)
            if parts.count >= 2 { binds[parts[1]] = parts[0] }
        }
        // A name the engine doesn't know is made a volume, empty, as the
        // engine makes it (`registerMountPoints`).
        for name in Set(binds.values) where !name.hasPrefix("/") && locked({ !volumes.contains { $0.Name == name } }) {
            addVolume(name, size: 0, refCount: 0)
        }
        locked {
            containers[id]?.binds = binds
            containers[id]?.created = request
            // A named volume bound is a mount the list says, as the engine's.
            containers[id]?.summary.Mounts = binds.filter { !$0.value.hasPrefix("/") }.sorted { $0.key < $1.key }
                .map { DockerMountPoint(Type: "volume", Name: $0.value, Destination: $0.key) }
            if let auto = request.HostConfig?.AutoRemove { containers[id]?.hostConfig.AutoRemove = auto }
            if let mode = request.HostConfig?.NetworkMode { containers[id]?.hostConfig.NetworkMode = mode }
            if let cmd = request.Cmd ?? (request.Entrypoint == nil ? record?.config.Cmd : nil) { containers[id]?.cmd = cmd }
            if let entrypoint = request.Entrypoint {
                containers[id]?.entrypoint = entrypoint
                if request.Cmd == nil { containers[id]?.cmd = [] }
            }
            if let record {
                if request.Entrypoint == nil { containers[id]?.entrypoint = record.config.Entrypoint }
                containers[id]?.healthcheck = record.config.Healthcheck?.Test
            }
        }
        return .json(201, Data(#"{"Id":"\#(id)","Warnings":[]}"#.utf8))
    }

    /// What a volume holds now, for a test.
    func volumeContents(_ name: String) -> [String: Data] { locked { volumeFiles[name] ?? [:] } }

    /// A file in a volume — the volume made if it isn't there.
    func setVolumeFile(_ name: String, _ path: String, _ data: Data, uid: Int = 0, gid: Int = 0) {
        if locked({ !volumes.contains { $0.Name == name } }) { addVolume(name, size: 0, refCount: 0) }
        let now = Self.timestamp()
        locked {
            volumeFiles[name, default: [:]][path] = data
            volumeMtimes[name, default: [:]][path] = now
            volumeOwners[name, default: [:]][path] = (uid, gid)
        }
    }

    /// Whose a volume's file is now.
    func volumeOwner(_ name: String, _ path: String) -> (uid: Int, gid: Int)? { locked { volumeOwners[name]?[path] } }

    /// Starts of a container that mounts `volume` refused from now on, as
    /// the engine says `message` (an nfs volume whose server is away, a
    /// full disk); nil starts them again.
    func failStarts(mounting volume: String, _ message: String?) { locked { startFailures[volume] = message } }

    /// A volume gone behind the app's back, as `docker volume rm` in a
    /// terminal: no event, no refusal.
    func dropVolume(_ name: String) {
        locked {
            volumes.removeAll { $0.Name == name }
            volumeFiles[name] = nil
            volumeMtimes[name] = nil
            volumeOwners[name] = nil
        }
    }

    /// Overterm's helpers there are now (`overterm.helper=1`).
    var helperIDs: [String] { locked { containers.values.filter { $0.summary.labels["overterm.helper"] == "1" }.map(\.summary.Id).sorted() } }

    /// What a container's create asked for.
    func created(_ id: String) -> CreateRequest? { locked { containers[id]?.created } }

    /// The volume a path is in, and where in it: `/volume/conf/a` in a
    /// helper with `pgdata` at `/volume` → (pgdata, `conf/a`); the mount
    /// itself, "".
    private func volumePath(_ path: String, in container: Container) -> (volume: String, path: String)? {
        for (mount, volume) in container.binds {
            if path == mount || path == mount + "/" { return (volume, "") }
            if path.hasPrefix(mount + "/") { return (volume, String(path.dropFirst(mount.count + 1))) }
        }
        return nil
    }

    /// A volume's file, or a folder of it: what HEAD says of it, and what
    /// GET gives — a file alone, or a folder's tree under its name.
    private func volumeStat(_ volume: String, _ path: String) -> DockerTar.PathStat? {
        let (files, mtimes) = locked { (volumeFiles[volume] ?? [:], volumeMtimes[volume] ?? [:]) }
        let name = path.isEmpty ? "volume" : (path as NSString).lastPathComponent
        if let data = files[path] {
            return DockerTar.PathStat(name: name, size: data.count, mode: 0o644, mtime: mtimes[path] ?? "2026-01-01T00:00:00Z", linkTarget: "")
        }
        guard path.isEmpty || files.keys.contains(where: { $0.hasPrefix(path + "/") }) else { return nil }
        return DockerTar.PathStat(name: name, size: 4096, mode: 0o755 | (1 << 31), mtime: "2026-01-01T00:00:00Z", linkTarget: "")
    }

    private func volumeArchive(_ volume: String, _ path: String, top: String) -> Data? {
        let (files, owners) = locked { (volumeFiles[volume] ?? [:], volumeOwners[volume] ?? [:]) }
        if let data = files[path] {
            let owner = owners[path] ?? (0, 0)
            return DockerTar.archive(name: (path as NSString).lastPathComponent, data: data, uid: owner.uid, gid: owner.gid)
        }
        let prefix = path.isEmpty ? "" : path + "/"
        let under = files.filter { $0.key.hasPrefix(prefix) }
        guard path.isEmpty || !under.isEmpty else { return nil }
        var archive = DockerTar.header(name: top + "/", size: 0, mode: 0o755, modified: Date(), type: "5") ?? Data()
        for (name, data) in under.sorted(by: { $0.key < $1.key }) {
            let owner = owners[name] ?? (0, 0)
            archive += (DockerTar.archive(name: top + "/" + name.dropFirst(prefix.count), data: data, uid: owner.uid, gid: owner.gid) ?? Data())
                .dropLast(2 * DockerTar.block)
        }
        return archive + Data(count: 2 * DockerTar.block)
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
    /// the image there — for `platform` (os/arch/variant) when asked, else
    /// the engine's own. `private/…` names are refused, as a registry that
    /// wants credentials does; `amd64only/…` have no variant but amd64.
    private func pull(_ name: String, platform: String? = nil) -> Answer {
        // A tag its registry moved on (`setRegistryDigest`): up to date when
        // what it names here came with that digest, else the new image — the
        // tag taken off the old one, which keeps its repo digest.
        if let digest = locked({ registryDigests[name] }) {
            let repository = DockerEngine.split(name).0
            let here = locked { images.first { $0.tags.contains(name) } }
            if here?.RepoDigests?.contains(repository + "@" + digest) == true {
                emitImage("pull", name)
                return .raw(200, Data(#"{"status":"Status: Image is up to date for \#(name)"}"#.utf8 + [0x0A]), [("Content-Type", "application/json")])
            }
            addImage(name, size: 2048, digest: digest)
            emitImage("pull", name)
            let lines = [
                #"{"status":"Pulling from library/\#(repository)","id":"\#(DockerEngine.split(name).1)"}"#,
                #"{"status":"Pulling fs layer","progressDetail":{},"id":"l2"}"#, #"{"status":"Pull complete","progressDetail":{},"id":"l2"}"#,
                #"{"status":"Digest: \#(digest)"}"#, #"{"status":"Status: Downloaded newer image for \#(name)"}"#,
            ]
            return .raw(200, Data(lines.joined(separator: "\n").utf8 + [0x0A]), [("Content-Type", "application/json")])
        }
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
        case (.GET, "images", false):
            // As the engine lists them: an untagged image another was made
            // from is a layer of it, out of the list but with `all`.
            return Self.json(
                locked {
                    let parents = Set(imageRecords.values.compactMap(\.parent))
                    return images.filter { query["all"] == "1" || !($0.isDangling && parents.contains($0.Id)) }
                })
        case (.GET, "images", true) where id == "search":
            let term = (query["term"] ?? "").lowercased()
            let catalog = [("redis", "Redis is the world's fastest data platform", 13_000, true), ("bitnami/redis", "Bitnami Redis", 300, false)]
            let found = catalog.filter { $0.0.contains(term) }.map {
                #"{"name":"\#($0.0)","description":"\#($0.1)","star_count":\#($0.2),"is_official":\#($0.3),"is_automated":false}"#
            }
            return .json(200, Data(("[" + found.joined(separator: ",") + "]").utf8))
        case (.GET, "volumes", false): return Self.json(VolumeList(Volumes: locked { volumes }, Warnings: nil))
        case (.GET, "volumes", true):
            guard let volume = locked({ volumes.first { $0.Name == id } }) else { return Self.error(404, "get \(id): no such volume") }
            return Self.json(volume)
        case (.POST, "volumes", false):
            struct Request: Decodable { var Name: String }
            guard let name = try? JSONDecoder().decode(Request.self, from: body).Name else { return Self.error(400, "no Name") }
            if locked({ !volumes.contains { $0.Name == name } }) { addVolume(name, size: 0, refCount: 0) }
            return .json(201, Data(#"{"Name":"\#(name)","Driver":"local","Mountpoint":"/var/lib/docker/volumes/\#(name)/_data"}"#.utf8))
        case (.GET, "images", true):
            return .raw(200, Data("a saved image".utf8) + Data(count: 2 * DockerTar.block), [("Content-Type", "application/x-tar")])
        case (.GET, "networks", false): return Self.json(locked { networks })
        case (.DELETE, "images", true):
            if let refused = refusal(id) { return refused }
            locked {
                for gone in images where gone.Id == id || gone.tags.contains(id) { imageRecords.removeValue(forKey: gone.Id) }
                images.removeAll { $0.Id == id || $0.tags.contains(id) }
            }
            emitImage("delete", id)
            return Self.json([PruneReport.ImageDeleted(Untagged: nil, Deleted: id)])
        case (.DELETE, "volumes", true):
            if let refused = refusal(id) { return refused }
            // As the engine: never one a container mounts, running or not.
            let users = locked { containers.values.filter { ($0.summary.Mounts ?? []).contains { $0.Name == id } }.map(\.summary.Id).sorted() }
            guard users.isEmpty else { return Self.error(409, "remove \(id): volume is in use - [\(users.joined(separator: ", "))]") }
            locked {
                volumes.removeAll { $0.Name == id }
                volumeFiles[id] = nil
                volumeMtimes[id] = nil
                volumeOwners[id] = nil
            }
            return .empty(204)
        case (.DELETE, "networks", true):
            if let refused = refusal(id, locked({ networks.first { $0.Id == id }?.Name }) ?? id) { return refused }
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
                Image: container.reference ?? summary.Image, Env: container.env, Cmd: container.cmd, Entrypoint: container.entrypoint, WorkingDir: "/",
                User: "",
                Labels: summary.Labels,
                ExposedPorts: bindings.isEmpty ? nil : Dictionary(uniqueKeysWithValues: bindings.keys.map { ($0, EmptyObject()) }), Tty: container.tty, Hostname: String(summary.Id.prefix(12)),
                Healthcheck: container.healthcheck.map { .init(Test: $0, Interval: 30_000_000_000, Timeout: 5_000_000_000, Retries: 3) }),
            HostConfig: {
                var host = container.hostConfig
                host.PortBindings = bindings.isEmpty ? nil : bindings
                return host
            }(),
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
    /// Answered at its head (`FakeDockerEngine.early`): its body is
    /// passed over, and the connection closes once the answer is out.
    private var answeredEarly = false

    init(engine: FakeDockerEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            // Dropped: what follows in the same read (its end) is no request.
            if engine.takeDrop() {
                self.head = nil
                answeredEarly = true
                context.close(promise: nil)
                return
            }
            self.head = head
            body = Data()
            answeredEarly = false
            if engine.stalls(head.uri) {
                _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
                return
            }
            if let answer = engine.early(head.method, head.uri) {
                answeredEarly = true
                send(answer, context, head)
            }
        case .body(var buffer):
            guard !answeredEarly else { return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head, !answeredEarly else { return }
            respond(context, head)
        }
    }

    private func respond(_ context: ChannelHandlerContext, _ request: HTTPRequestHead) {
        let chunked = request.headers["Transfer-Encoding"].contains { $0.lowercased().contains("chunked") }
        let answer = engine.answer(request.method, request.uri, body: body, chunked: chunked)
        if case .later(let ms, let inner, let then) = answer {
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.eventLoop.scheduleTask(in: .milliseconds(Int64(ms))) { [self] in
                then()
                send(inner, bound.value, request)
            }
            return
        }
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
            let engine = engine
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { result in
                if case .success = result { engine.answerWritten(request.method, request.uri) }
                channel.close(promise: nil)
            }
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
        case .never, .later: break
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

extension FakeDockerEngine {
    /// What `docker scout cves --format sarif` prints for an image, in
    /// Scout 1.17's shape: four CVEs, one of each severity — a fix for two,
    /// none yet for the others. Scout isn't the Engine API: a scenario's
    /// stub `docker` prints it, and the store's tests read it.
    static let scoutReport = #"""
        {
          "version": "2.1.0",
          "$schema": "https://json.schemastore.org/sarif-2.1.0-rtm.5.json",
          "runs": [
            {
              "tool": {
                "driver": {
                  "fullName": "Docker Scout",
                  "informationUri": "https://docker.com/products/docker-scout",
                  "name": "docker scout",
                  "rules": [
                    {
                      "id": "CVE-2024-0727",
                      "name": "OsPackageVulnerability",
                      "shortDescription": { "text": "CVE-2024-0727" },
                      "helpUri": "https://scout.docker.com/v/CVE-2024-0727?s=debian&n=openssl&ns=debian&t=deb&osn=debian&osv=12&vr=%3C3.0.13-1~deb12u1",
                      "help": {
                        "text": "Processing a maliciously formatted PKCS12 file may lead OpenSSL to crash, leading to a potential Denial of Service attack.\n",
                        "markdown": "> Processing a maliciously formatted PKCS12 file may lead OpenSSL to crash.\n\n|                |                   |\n|----------------|-------------------|\n| Package        | pkg:deb/debian/openssl@3.0.11-1~deb12u1 |\n"
                      },
                      "properties": {
                        "affected_version": "<3.0.13-1~deb12u1",
                        "cvssV3_severity": "CRITICAL",
                        "fixed_version": "3.0.13-1~deb12u1",
                        "purls": ["pkg:deb/debian/openssl@3.0.11-1~deb12u1?os_distro=bookworm&os_name=debian&os_version=12"],
                        "security-severity": "9.1",
                        "tags": ["CRITICAL"]
                      }
                    },
                    {
                      "id": "CVE-2023-45853",
                      "name": "OsPackageVulnerability",
                      "shortDescription": { "text": "CVE-2023-45853" },
                      "helpUri": "https://scout.docker.com/v/CVE-2023-45853?s=debian&n=zlib&ns=debian&t=deb&osn=debian&osv=12&vr=%3E%3D1%3A1.2.13.dfsg-1",
                      "help": {
                        "text": "MiniZip in zlib through 1.3 has an integer overflow and resultant heap-based buffer overflow in zipOpenNewFileInZip4_64 via a long filename, comment, or extra field.\n\n---\nREJECTED\n",
                        "markdown": "> MiniZip in zlib through 1.3 has an integer overflow.\n"
                      },
                      "properties": {
                        "affected_version": ">=1:1.2.13.dfsg-1",
                        "cvssV3_severity": "HIGH",
                        "fixed_version": "not fixed",
                        "purls": ["pkg:deb/debian/zlib@1%3A1.2.13.dfsg-1?os_distro=bookworm&os_name=debian&os_version=12"],
                        "security-severity": "9.8",
                        "tags": ["HIGH"]
                      }
                    },
                    {
                      "id": "GHSA-67hx-6x53-jw92",
                      "name": "NpmPackageVulnerability",
                      "shortDescription": { "text": "GHSA-67hx-6x53-jw92" },
                      "helpUri": "https://scout.docker.com/v/GHSA-67hx-6x53-jw92?s=github&n=traverse&ns=%40babel&t=npm&vr=%3C7.23.2",
                      "help": {
                        "text": "Babel vulnerable to arbitrary code execution when compiling specifically crafted malicious code.\n",
                        "markdown": "> Babel vulnerable to arbitrary code execution.\n"
                      },
                      "properties": {
                        "affected_version": "<7.23.2",
                        "cvssV3_severity": "MEDIUM",
                        "fixed_version": "7.23.2",
                        "purls": ["pkg:npm/%40babel/traverse@7.22.5"],
                        "security-severity": "5.3",
                        "tags": ["MEDIUM"]
                      }
                    },
                    {
                      "id": "CVE-2005-2541",
                      "name": "OsPackageVulnerability",
                      "shortDescription": { "text": "CVE-2005-2541" },
                      "helpUri": "https://scout.docker.com/v/CVE-2005-2541?s=debian&n=tar&ns=debian&t=deb&osn=debian&osv=12&vr=%3E%3D1.34%2Bdfsg-1.2",
                      "help": {
                        "text": "Tar 1.15.1 does not properly warn the user when extracting setuid or setgid files, which may allow local users or remote attackers to gain privileges.\n",
                        "markdown": "> Tar 1.15.1 does not properly warn the user when extracting setuid or setgid files.\n"
                      },
                      "properties": {
                        "affected_version": ">=1.34+dfsg-1.2",
                        "cvssV3_severity": "LOW",
                        "fixed_version": "not fixed",
                        "purls": ["pkg:deb/debian/tar@1.34%2Bdfsg-1.2?os_distro=bookworm&os_name=debian&os_version=12"],
                        "security-severity": "3.1",
                        "tags": ["LOW"]
                      }
                    }
                  ],
                  "version": "1.17.1"
                }
              },
              "results": [
                {
                  "ruleId": "CVE-2024-0727",
                  "ruleIndex": 0,
                  "kind": "fail",
                  "level": "error",
                  "message": {
                    "text": "  Vulnerability   : CVE-2024-0727\n  Severity        : CRITICAL\n  Package         : pkg:deb/debian/openssl@3.0.11-1~deb12u1?os_distro=bookworm&os_name=debian&os_version=12\n  Affected range  : <3.0.13-1~deb12u1\n  Fixed version   : 3.0.13-1~deb12u1\n  EPSS Score      : 0.001210\n  EPSS Percentile : 0.325430\n"
                  },
                  "locations": [{ "physicalLocation": { "artifactLocation": { "uri": "/usr/share/doc/openssl/copyright" } } }]
                },
                {
                  "ruleId": "CVE-2023-45853",
                  "ruleIndex": 1,
                  "kind": "fail",
                  "level": "error",
                  "message": {
                    "text": "  Vulnerability   : CVE-2023-45853\n  Severity        : HIGH\n  Package         : pkg:deb/debian/zlib@1%3A1.2.13.dfsg-1?os_distro=bookworm&os_name=debian&os_version=12\n  Affected range  : >=1:1.2.13.dfsg-1\n  Fixed version   : not fixed\n  EPSS Score      : 0.004450\n  EPSS Percentile : 0.722530\n"
                  },
                  "locations": [{ "physicalLocation": { "artifactLocation": { "uri": "/var/lib/dpkg/status" } } }]
                },
                {
                  "ruleId": "GHSA-67hx-6x53-jw92",
                  "ruleIndex": 2,
                  "kind": "fail",
                  "level": "warning",
                  "message": {
                    "text": "  Vulnerability   : GHSA-67hx-6x53-jw92\n  Severity        : MEDIUM\n  Package         : pkg:npm/%40babel/traverse@7.22.5\n  Affected range  : <7.23.2\n  Fixed version   : 7.23.2\n"
                  },
                  "locations": [{ "physicalLocation": { "artifactLocation": { "uri": "/app/node_modules/@babel/traverse/package.json" } } }]
                },
                {
                  "ruleId": "CVE-2005-2541",
                  "ruleIndex": 3,
                  "kind": "fail",
                  "level": "note",
                  "message": {
                    "text": "  Vulnerability   : CVE-2005-2541\n  Severity        : LOW\n  Package         : pkg:deb/debian/tar@1.34%2Bdfsg-1.2?os_distro=bookworm&os_name=debian&os_version=12\n  Affected range  : >=1.34+dfsg-1.2\n  Fixed version   : not fixed\n  EPSS Score      : 0.000430\n  EPSS Percentile : 0.081120\n"
                  },
                  "locations": [{ "physicalLocation": { "artifactLocation": { "uri": "/var/lib/dpkg/status" } } }]
                }
              ]
            }
          ]
        }
        """#
}
