import Foundation
import NIOHTTP1

/// The Engine API's calls the UI makes, by what they are for.
extension DockerEngine {
    // MARK: The engine

    func info() async throws -> EngineInfo { try await get(EngineInfo.self, "/info") }

    func diskUsage() async throws -> DockerDiskUsage { try await get(DockerDiskUsage.self, "/system/df") }

    /// What changes containers, as it happens: the events a list shows
    /// (`DockerEvent.listed`), from now on.
    func events() -> AsyncThrowingStream<DockerEvent, Error> {
        func list(_ words: [String]) -> String { words.map { "\"\($0)\"" }.joined(separator: ",") }
        let filters = #"{"type":[\#(list(DockerEvent.types))],"event":[\#(list(DockerEvent.listed.sorted()))]}"#
        return decodedLines(stream("/events", ["filters": filters]), as: DockerEvent.self)
    }

    // MARK: Containers

    /// At 1.48 where the engine speaks it: each says the platform it runs
    /// (`ImageManifestDescriptor`, the containerd store's).
    func containers(all: Bool = true) async throws -> [ContainerSummary] {
        try await get([ContainerSummary].self, "/containers/json", all ? ["all": "1"] : [:], version: version(wanting: Self.manifestVersion))
    }

    func container(_ id: String) async throws -> ContainerDetail {
        try await get(ContainerDetail.self, "/containers/\(id)/json", version: version(wanting: Self.manifestVersion))
    }

    /// Where a container first says what it runs.
    static let manifestVersion = "1.48"

    /// Inspect as the engine wrote it, indented, for the Inspect tab.
    func containerJSON(_ id: String) async throws -> String {
        try await prettyJSON(send(.GET, "/containers/\(id)/json").body)
    }

    enum ContainerAction: String, Sendable {
        case start, stop, restart, pause, unpause, kill
    }

    func perform(_ action: ContainerAction, on id: String) async throws {
        // A stop waits for the process; ten seconds, as the CLI.
        try await send(.POST, "/containers/\(id)/\(action.rawValue)", action == .stop || action == .restart ? ["t": "10"] : [:])
    }

    func remove(container id: String, force: Bool = false, volumes: Bool = false) async throws {
        try await send(.DELETE, "/containers/\(id)", ["force": force ? "1" : "0", "v": volumes ? "1" : "0"])
    }

    func rename(container id: String, to name: String) async throws {
        try await send(.POST, "/containers/\(id)/rename", ["name": name])
    }

    /// What `docker update` changes on a container, running or not: only
    /// the fields given — nil is left out, and the engine reads it (and
    /// every 0) as unchanged. `CpuPeriod` is here for the fake engine to
    /// read; Overterm never sends one.
    struct ContainerUpdate: Codable, Equatable, Sendable {
        var Memory: Int?
        var MemorySwap: Int?
        var NanoCpus: Int?
        var CpuQuota: Int?
        var CpuPeriod: Int?
        var RestartPolicy: ContainerDetail.HostConfigDetail.RestartPolicy?
    }

    /// Changes it in place; what the engine warns of (no swap accounting
    /// on its kernel) back.
    @discardableResult
    func update(container id: String, _ change: ContainerUpdate) async throws -> [String] {
        struct Answer: Decodable { var Warnings: [String]? }
        let body = try JSONEncoder().encode(change)
        let response = try await send(.POST, "/containers/\(id)/update", body: body, headers: [("Content-Type", "application/json")])
        return (try? JSONDecoder().decode(Answer.self, from: response.body))?.Warnings ?? []
    }

    /// Its files and config as a new image (`docker commit`): paused while
    /// it is copied, the engine's default, as the CLI's. `changes` are
    /// Dockerfile lines (`ENV KEY=""`) put over its config. No body: the
    /// container's own config is the image's. Untagged without a
    /// repository. Returns the image's id.
    func commit(container id: String, repository: String? = nil, tag: String = "latest", comment: String = "", changes: [String] = []) async throws
        -> String
    {
        struct Answer: Decodable { var Id: String }
        var query = ["container": id]
        if let repository {
            query["repo"] = repository
            query["tag"] = tag
        }
        if !comment.isEmpty { query["comment"] = comment }
        if !changes.isEmpty { query["changes"] = changes.joined(separator: "\n") }
        let response = try await send(.POST, "/commit", query)
        return try JSONDecoder().decode(Answer.self, from: response.body).Id
    }

    /// A commit whose image keeps nothing `changes` take out. The classic
    /// image store writes the container's own config into the image as
    /// well (`container_config`, as it was: secrets, Compose's labels),
    /// and `docker save` and `docker push` carry it; no parameter changes
    /// that. So the container is committed untagged, with the changes; a
    /// container made from that (never started) is committed under the
    /// name, its own config the changed one; and it is removed. The first
    /// image stays as the new one's parent, which the engine lists no more
    /// than any layer's, and removes with it. Returns the image's id.
    func commitAnew(
        container id: String, helper name: String, repository: String, tag: String, comment: String, changes: [String]
    ) async throws -> String {
        let first = try await commit(container: id, changes: changes)
        var helper: String?
        do {
            let made = try await create(fromImage: first, name: name)
            helper = made
            let image = try await commit(container: made, repository: repository, tag: tag, comment: comment)
            try? await remove(container: made, force: true, volumes: true)
            return image
        } catch {
            if let helper { try? await remove(container: helper, force: true, volumes: true) }
            try? await remove(image: first)
            throw error
        }
    }

    /// A container made from `image` and nothing else — its command, env
    /// and labels the image's own; never started. Returns its id.
    func create(fromImage image: String, name: String) async throws -> String {
        struct Created: Decodable { var Id: String }
        let body = try JSONSerialization.data(withJSONObject: ["Image": image])
        let response = try await send(.POST, "/containers/create", ["name": name], body: body, headers: [("Content-Type", "application/json")])
        return try JSONDecoder().decode(Created.self, from: response.body).Id
    }

    /// The last `tail` lines, then (`follow`) what comes; demuxed when the
    /// container has no TTY.
    func logs(_ id: String, tty: Bool, tail: Int = 500, follow: Bool, timestamps: Bool = true, since: Int? = nil)
        -> AsyncThrowingStream<[DockerLogChunk], Error>
    {
        var query = ["stdout": "1", "stderr": "1", "tail": "\(tail)", "timestamps": timestamps ? "1" : "0", "follow": follow ? "1" : "0"]
        if let since { query["since"] = "\(since)" }
        let bytes = stream("/containers/\(id)/logs", query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var demuxer = DockerLogDemuxer(framed: !tty)
                do {
                    for try await data in bytes {
                        let chunks = demuxer.feed(data)
                        if !chunks.isEmpty { continuation.yield(chunks) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A sample a second, while iterated.
    func stats(_ id: String) -> AsyncThrowingStream<ContainerStatsSample, Error> {
        decodedLines(stream("/containers/\(id)/stats", ["stream": "1"]), as: ContainerStatsSample.self)
    }

    /// One sample, taken as it is asked (`one-shot`, API 1.41): it comes at
    /// once, with no `precpu_stats` — the list sets it against its own read
    /// before (`DockerUsageReadings`). `stream=false` alone has the engine
    /// wait for two of its samples, a second or two.
    func oneShotStats(_ id: String) async throws -> ContainerStatsSample {
        try await get(ContainerStatsSample.self, "/containers/\(id)/stats", ["stream": "false", "one-shot": "true"])
    }

    func top(_ id: String) async throws -> (titles: [String], processes: [[String]]) {
        struct Top: Decodable {
            var Titles: [String]
            var Processes: [[String]]
        }
        let top = try await get(Top.self, "/containers/\(id)/top")
        return (top.Titles, top.Processes)
    }

    /// What changed in its filesystem since it started.
    struct Change: Decodable, Equatable, Sendable {
        enum Kind: Int, Decodable, Sendable { case modified = 0, added = 1, deleted = 2 }
        var Path: String
        var Kind: Kind
    }

    func changes(_ id: String) async throws -> [Change] {
        // The engine answers `null` for none.
        (try await get([Change]?.self, "/containers/\(id)/changes")) ?? []
    }

    // MARK: Running a command in it

    struct ExecResult: Equatable, Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int
        /// Why the output stops short: past the limit, or the deadline.
        var cut: String?
        /// Still running when it was no longer read — its exit code isn't
        /// known; the command goes on in the container.
        var running = false
    }

    /// A command in a running container, no TTY and no input, its output
    /// back when it ends. The engine answers `start` by hijacking the
    /// connection: the output comes framed until it closes. `limit` (bytes)
    /// and `timeout` stop the reading of a command an agent gave, which may
    /// never end (`tail -f`) or never stop writing (`yes`).
    func exec(_ id: String, _ command: [String], limit: Int? = nil, timeout: Duration? = nil) async throws -> ExecResult {
        struct Created: Decodable { var Id: String }
        struct Inspect: Decodable {
            var ExitCode: Int?
            var Running: Bool?
        }
        let json = [("Content-Type", "application/json")]
        let create = try JSONSerialization.data(withJSONObject: ["AttachStdout": true, "AttachStderr": true, "Tty": false, "Cmd": command])
        let made = try JSONDecoder().decode(Created.self, from: try await send(.POST, "/containers/\(id)/exec", body: create, headers: json).body)
        let start = try JSONSerialization.data(withJSONObject: ["Detach": false, "Tty": false])
        var result = try await Self.collect(transport.stream(.POST, path("/exec/\(made.Id)/start"), body: start, headers: json), limit: limit, timeout: timeout)
        let inspect = try await get(Inspect.self, "/exec/\(made.Id)/json")
        result.exitCode = inspect.ExitCode ?? 0
        result.running = inspect.Running == true
        return result
    }

    /// An exec's frames, read till they end — or till `limit` bytes have
    /// come, or `timeout` has passed; `cut` then says which. Leaving the
    /// stream closes its connection.
    nonisolated static func collect(_ frames: AsyncThrowingStream<Data, Error>, limit: Int?, timeout: Duration?) async throws -> ExecResult {
        try await withThrowingTaskGroup(of: ExecResult?.self) { group in
            group.addTask {
                var result = ExecResult(stdout: "", stderr: "", exitCode: 0)
                var demuxer = DockerLogDemuxer(framed: true)
                var read = 0
                for try await data in frames {
                    read += data.count
                    for chunk in demuxer.feed(data) {
                        if chunk.stream == .stderr { result.stderr += chunk.text } else { result.stdout += chunk.text }
                    }
                    if let limit, read >= limit {
                        result.cut = "output cut at \(DockerBytes.string(limit, memory: true))"
                        break
                    }
                }
                // The deadline's: the stream ends when its reader is cancelled.
                if Task.isCancelled, result.cut == nil, let timeout { result.cut = "not read past \(timeout.formatted(.units(allowed: [.minutes, .seconds])))" }
                return result
            }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return nil
                }
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            // The deadline came first: what the frames said till then.
            while let next = try await group.next() {
                if let next { return next }
            }
            return ExecResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    /// A folder's entries (DockerFiles), through `exec`.
    func list(_ id: String, folder: String) async throws -> [DockerFiles.Entry] {
        let result = try await exec(id, DockerFiles.command(listing: folder))
        guard result.exitCode == 0 else {
            let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // 126/127: no `sh` to run (a distroless image).
            throw DockerError(status: 0, message: [126, 127].contains(result.exitCode) ? "This image has no shell: its folders can't be listed." : said)
        }
        return DockerFiles.parse(result.stdout)
    }

    // MARK: Files in a container

    /// What a path is — without reading it.
    func stat(_ id: String, path: String) async throws -> DockerTar.PathStat {
        let response: DockerResponse
        do {
            response = try await send(.HEAD, "/containers/\(id)/archive", ["path": path])
        } catch let error as DockerError where error.status == 404 && error.message == "HTTP 404" {
            // A HEAD's answer has no body to say why: a 404 is the path.
            throw DockerError(status: 404, message: "\(path) isn't there.")
        }
        guard let header = response.header("X-Docker-Container-Path-Stat"), let stat = DockerTar.pathStat(header) else {
            throw DockerError(status: response.status, message: "\(path): Docker said nothing about it.")
        }
        return stat
    }

    /// A file as the archive has it: its contents and its owner.
    func readEntry(_ id: String, file: String) async throws -> DockerTar.Entry {
        let entries = DockerTar.entries(of: try await send(.GET, "/containers/\(id)/archive", ["path": file]).body)
        guard let entry = entries.first(where: { $0.kind == .file }) else { throw DockerError(status: 0, message: "\(file) isn't a file.") }
        return entry
    }

    func read(_ id: String, file: String) async throws -> Data { try await readEntry(id, file: file).data }

    /// Writes `data` as `file`, through a plain ustar archive (DockerTar),
    /// owned by `uid` and `gid`: the engine gives what it extracts the
    /// tar's owner, so a file written back keeps its own only when told it.
    func write(_ id: String, file: String, data: Data, mode: Int = 0o644, uid: Int = 0, gid: Int = 0) async throws {
        let url = URL(fileURLWithPath: file)
        guard let archive = DockerTar.archive(name: url.lastPathComponent, data: data, mode: mode, uid: uid, gid: gid) else {
            throw DockerError(status: 0, message: "\(file): the name is too long to write.")
        }
        try await send(
            .PUT, "/containers/\(id)/archive", ["path": url.deletingLastPathComponent().path], body: archive,
            headers: [("Content-Type", "application/x-tar")])
    }

    // MARK: Export and import

    /// A stream's bytes into a file as they come — a container's
    /// filesystem, an image, a volume can be gigabytes. Returns the bytes.
    @discardableResult
    func download(_ path: String, _ query: [String: String] = [:], to file: URL) async throws -> Int {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var written = 0
        do {
            for try await data in stream(path, query) {
                try handle.write(contentsOf: data)
                written += data.count
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return written
    }

    /// Its filesystem as a tar (`docker export`).
    @discardableResult
    func export(container id: String, to file: URL) async throws -> Int { try await download("/containers/\(id)/export", to: file) }

    /// An image as a tar `docker load` takes back (`docker save`).
    @discardableResult
    func save(image name: String, to file: URL) async throws -> Int { try await download("/images/\(name)/get", to: file) }

    /// An image to make a helper from that never runs: any will do — a
    /// small one if there is one.
    func anyImage() async -> String? {
        guard let images = try? await images(), !images.isEmpty else { return nil }
        for name in DockerVolumeFiles.shells {
            if let image = images.first(where: { $0.tags.contains { $0.hasPrefix(name + ":") } }) { return image.Id }
        }
        return images.min { $0.Size < $1.Size }?.Id
    }

    /// A helper's name: `overterm-helper-` or `overterm-files-`, then 8 hex.
    static func helperName(_ kind: String) -> String {
        "overterm-\(kind)-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    /// What every helper is labelled: Overterm's, this run's, and the
    /// volume it holds.
    static func helperLabels(_ volume: String) -> [String: String] {
        ["overterm.helper": "1", "overterm.run": DockerHelpers.run, "overterm.volume": volume]
    }

    /// The volume there, or why not: a container bound to a name the
    /// engine doesn't know makes an empty volume of it — one removed in a
    /// terminal, or pruned, would come back, and a save would land in it.
    func requireVolume(_ name: String) async throws {
        do {
            try await send(.GET, "/volumes/\(name)")
        } catch let error as DockerError where error.status == 404 {
            throw DockerError.volumeGone(name)
        }
    }

    /// A container made and never started, `volume` at /volume — enough for
    /// the archive endpoint to read and write the volume: nothing runs, so
    /// any image on the Mac will do. Only for a volume there is; labelled,
    /// recorded (`DockerHelpers`), and removed by the caller (`removeHelper`).
    func helper(mounting volume: String, image: String) async throws -> String {
        struct Created: Decodable { var Id: String }
        try await requireVolume(volume)
        let body = try JSONSerialization.data(withJSONObject: [
            "Image": image, "Cmd": ["true"], "Labels": Self.helperLabels(volume),
            "HostConfig": ["Binds": ["\(volume):\(DockerVolumeFiles.mount)"]],
        ])
        let response = try await send(
            .POST, "/containers/create", ["name": Self.helperName("helper")], body: body, headers: [("Content-Type", "application/json")])
        let id = try JSONDecoder().decode(Created.self, from: response.body).Id
        DockerHelpers.made(id, volume: volume, on: self)
        return id
    }

    /// `body` with a helper that never starts (`helper(mounting:)`),
    /// removed after, whatever `body` did — gone when this returns.
    func withHelper<T: Sendable>(mounting volume: String, image: String, _ body: @Sendable (String) async throws -> T) async throws -> T {
        let helper = try await helper(mounting: volume, image: image)
        do {
            let result = try await body(helper)
            await removeHelper(helper)
            return result
        } catch {
            await removeHelper(helper)
            throw error
        }
    }

    /// A volume's Files tab's helper: one that runs, so `exec` can list its
    /// folders — `sh` from `image`, as root (a volume's files are a
    /// database's, 999's), with no network, for `lifetime` seconds, then
    /// gone by itself (AutoRemove) should nobody remove it. The image's own
    /// entrypoint is replaced, so none of its startup runs. Only for a
    /// volume there is. A start that fails (no `sh`, a platform this engine
    /// can't run, a volume that won't mount) leaves nothing.
    func filesHelper(
        mounting volume: String, image: String, lifetime: Int = DockerVolumeFiles.lifetime, labels extra: [String: String] = [:]
    ) async throws -> String {
        struct Created: Decodable { var Id: String }
        try await requireVolume(volume)
        let labels = Self.helperLabels(volume).merging(extra) { own, _ in own }
        // Entrypoint and User both said: with an entrypoint the image's
        // command isn't merged in, and an empty user would be the image's.
        let body = try JSONSerialization.data(withJSONObject: [
            "Image": image, "Entrypoint": ["sh", "-c", "exec sleep \(lifetime)"], "User": "0:0", "WorkingDir": DockerVolumeFiles.mount,
            "Labels": labels,
            "HostConfig": ["Binds": ["\(volume):\(DockerVolumeFiles.mount)"], "AutoRemove": true, "NetworkMode": "none"],
        ])
        let response = try await send(
            .POST, "/containers/create", ["name": Self.helperName("files")], body: body, headers: [("Content-Type", "application/json")])
        let id = try JSONDecoder().decode(Created.self, from: response.body).Id
        DockerHelpers.made(id, volume: volume, on: self)
        do {
            try await perform(.start, on: id)
        } catch {
            await removeHelper(id)
            throw error
        }
        return id
    }

    /// Removed, once however many ask (`DockerHelpers.remove`): returns
    /// when the engine no longer has it.
    func removeHelper(_ id: String) async { await DockerHelpers.remove(id, on: self) }

    /// The removal itself: with force, a running one too, and with its
    /// anonymous volumes — an image's `VOLUME` (postgres', redis') made one
    /// at create, and AutoRemove would take them only when its sleep ends.
    /// The volume it was given by name is never one of them. Gone already
    /// (AutoRemove, a 404) is no failure; a removal on its way elsewhere
    /// (a 409) is waited for, at most 5 s, till the engine no longer has it.
    func deleteHelper(_ id: String) async {
        do {
            try await remove(container: id, force: true, volumes: true)
        } catch let error as DockerError where error.status == 409 {
            let until = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < until {
                do {
                    try await send(.GET, "/containers/\(id)/json")
                } catch {
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } catch {}
    }

    /// Overterm's helpers as the engine lists them, whichever run made them.
    func helpers() async throws -> [ContainerSummary] {
        try await get([ContainerSummary].self, "/containers/json", ["all": "1", "filters": #"{"label":["overterm.helper=1"]}"#]).filter(\.isHelper)
    }

    /// `body` run on a container's file, or a volume's through a helper
    /// made for it and removed after, whatever `body` did: the container's
    /// id and the path as it has it.
    func reaching<T: Sendable>(_ source: DockerFileSource, _ path: String, _ body: @Sendable (String, String) async throws -> T) async throws -> T {
        switch source {
        case .container(let id, _):
            return try await body(id, path)
        case .volume(let name):
            guard let image = await anyImage() else { throw DockerError.noHelperImage }
            return try await withHelper(mounting: name, image: image) { try await body($0, DockerVolumeFiles.helperPath(path)) }
        }
    }

    /// A volume's files as a tar, `volume/` at its top.
    @discardableResult
    func export(volume name: String, to file: URL, using image: String) async throws -> Int {
        try await withHelper(mounting: name, image: image) { helper in
            try await self.download("/containers/\(helper)/archive", ["path": DockerVolumeFiles.mount], to: file)
        }
    }

    /// A volume made (if it isn't there) and filled from a tar `export`
    /// wrote.
    func `import`(volume name: String, from file: URL, using image: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name, "Labels": ["overterm.imported": "1"]])
        try await send(.POST, "/volumes/create", body: body, headers: [("Content-Type", "application/json")])
        let tar = try Data(contentsOf: file, options: .mappedIfSafe)
        try await withHelper(mounting: name, image: image) { helper in
            _ = try await self.send(.PUT, "/containers/\(helper)/archive", ["path": "/"], body: tar, headers: [("Content-Type", "application/x-tar")])
        }
    }

    // MARK: Images, volumes, networks

    func images() async throws -> [ImageSummary] { try await get([ImageSummary].self, "/images/json") }

    func imageJSON(_ name: String) async throws -> String { try await prettyJSON(send(.GET, "/images/\(name)/json").body) }

    /// What an image sets itself: its env and its command.
    func imageConfig(_ name: String) async throws -> (env: [String], command: [String]) {
        struct Image: Decodable {
            struct Config: Decodable {
                var Env: [String]?
                var Cmd: [String]?
            }
            var Config: Config?
        }
        let image = try await get(Image.self, "/images/\(name)/json")
        return (image.Config?.Env ?? [], image.Config?.Cmd ?? [])
    }

    func history(of image: String) async throws -> [ImageLayer] { try await get([ImageLayer].self, "/images/\(image)/history") }

    /// What an image is built for, as its inspect says: `/images/json`
    /// doesn't. In the containerd store an id is the image's index, and
    /// this is the platform it would run here — the engine's own once
    /// the index holds it.
    func platform(ofImage id: String) async throws -> DockerPlatform? {
        struct Image: Decodable {
            var Os: String?
            var Architecture: String?
            var Variant: String?
        }
        let image = try await get(Image.self, "/images/\(id)/json")
        return DockerPlatform(os: image.Os, architecture: image.Architecture, variant: image.Variant)
    }

    /// Several images' platforms, eight asked at a time; one that can't be
    /// read (gone, or no architecture said) is left out.
    func platforms(ofImages ids: [String]) async -> [String: DockerPlatform] {
        var found: [String: DockerPlatform] = [:]
        for start in stride(from: 0, to: ids.count, by: 8) {
            let chunk = ids[start..<min(start + 8, ids.count)]
            await withTaskGroup(of: (String, DockerPlatform?).self) { group in
                for id in chunk { group.addTask { (id, try? await self.platform(ofImage: id)) } }
                for await (id, platform) in group {
                    if let platform { found[id] = platform }
                }
            }
        }
        return found
    }

    func remove(image id: String, force: Bool = false) async throws {
        try await send(.DELETE, "/images/\(id)", ["force": force ? "1" : "0"])
    }

    func tag(image id: String, repository: String, tag: String) async throws {
        try await send(.POST, "/images/\(id)/tag", ["repo": repository, "tag": tag])
    }

    /// One line of a pull's progress: a layer (`id`), what it is doing,
    /// and how far.
    struct PullProgress: Equatable, Sendable {
        var id: String?
        var status: String
        var current: Int?
        var total: Int?
    }

    /// An image on Docker Hub, as the engine's search finds it.
    struct SearchResult: Decodable, Identifiable, Equatable, Sendable {
        var name: String
        var description: String?
        var star_count: Int?
        var is_official: Bool?

        var id: String { name }
    }

    /// Docker Hub's images matching `term`, best first — asked by the
    /// engine, as `docker search` asks.
    func search(_ term: String, limit: Int = 10) async throws -> [SearchResult] {
        try await get([SearchResult].self, "/images/search", ["term": term, "limit": "\(limit)"])
    }

    /// A public image's pull, its progress line by line. `platform`
    /// (`linux/arm64`, os[/arch[/variant]]): that variant of it, rather than
    /// the engine's own.
    func pull(_ image: String, platform: String? = nil) -> AsyncThrowingStream<PullProgress, Error> {
        let (name, tag) = Self.split(image)
        var query = ["fromImage": name, "tag": tag]
        if let platform { query["platform"] = platform }
        let bytes = transport.stream(.POST, path("/images/create", query), body: nil, headers: [])
        return AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = DockerLineSplitter()
                do {
                    for try await data in bytes {
                        for line in splitter.feed(data) {
                            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                            if let error = json["error"] as? String { throw DockerError(status: 0, message: error) }
                            let detail = json["progressDetail"] as? [String: Any]
                            continuation.yield(
                                PullProgress(
                                    id: json["id"] as? String, status: json["status"] as? String ?? "", current: detail?["current"] as? Int,
                                    total: detail?["total"] as? Int))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `postgres:16` → (postgres, 16); `localhost:5000/app` → (…, latest).
    static func split(_ image: String) -> (String, String) {
        if let at = image.firstIndex(of: "@") { return (String(image[..<at]), String(image[image.index(after: at)...])) }
        if let colon = image.lastIndex(of: ":"), !image[image.index(after: colon)...].contains("/") {
            return (String(image[..<colon]), String(image[image.index(after: colon)...]))
        }
        return (image, "latest")
    }

    func volumes() async throws -> [VolumeSummary] { try await get(VolumeList.self, "/volumes").Volumes ?? [] }

    func remove(volume name: String, force: Bool = false) async throws {
        try await send(.DELETE, "/volumes/\(name)", ["force": force ? "1" : "0"])
    }

    func networks() async throws -> [NetworkSummary] { try await get([NetworkSummary].self, "/networks") }

    func network(_ id: String) async throws -> NetworkSummary { try await get(NetworkSummary.self, "/networks/\(id)") }

    func remove(network id: String) async throws { try await send(.DELETE, "/networks/\(id)") }

    /// A container onto a network, running or not — `docker network connect`.
    func connect(container id: String, to network: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Container": id])
        try await send(.POST, "/networks/\(network)/connect", body: body, headers: [("Content-Type", "application/json")])
    }

    /// Off it — `docker network disconnect`.
    func disconnect(container id: String, from network: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Container": id, "Force": false])
        try await send(.POST, "/networks/\(network)/disconnect", body: body, headers: [("Content-Type", "application/json")])
    }

    enum Prunable: String, Sendable { case containers, images, volumes, networks, buildCache = "build" }

    /// Prunes what is unused; for images, every unused one (`dangling=false`)
    /// rather than only untagged ones, as Docker Desktop's "Clean up" does
    /// — the preview (DockerPrunePlan) lists them first.
    func prune(_ what: Prunable, everythingUnused: Bool = false) async throws -> PruneReport {
        var query: [String: String] = [:]
        if what == .images, everythingUnused { query["filters"] = #"{"dangling":["false"]}"# }
        if what == .volumes, everythingUnused { query["filters"] = #"{"all":["true"]}"# }
        let response = try await send(.POST, what == .buildCache ? "/build/prune" : "/\(what.rawValue)/prune", query)
        return (try? JSONDecoder().decode(PruneReport.self, from: response.body)) ?? PruneReport()
    }

    // MARK: Helpers

    func prettyJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: pretty, as: UTF8.self)
    }

    func decodedLines<T: Decodable & Sendable>(_ bytes: AsyncThrowingStream<Data, Error>, as type: T.Type) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = DockerLineSplitter()
                let decoder = JSONDecoder()
                do {
                    for try await data in bytes {
                        for line in splitter.feed(data) {
                            if let value = try? decoder.decode(T.self, from: line) { continuation.yield(value) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
