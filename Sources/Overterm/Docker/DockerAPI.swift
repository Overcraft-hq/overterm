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
    }

    /// A command in a running container, no TTY and no input, its output
    /// back when it ends. The engine answers `start` by hijacking the
    /// connection: the output comes framed until it closes.
    func exec(_ id: String, _ command: [String]) async throws -> ExecResult {
        struct Created: Decodable { var Id: String }
        struct Inspect: Decodable { var ExitCode: Int? }
        let json = [("Content-Type", "application/json")]
        let create = try JSONSerialization.data(withJSONObject: ["AttachStdout": true, "AttachStderr": true, "Tty": false, "Cmd": command])
        let made = try JSONDecoder().decode(Created.self, from: try await send(.POST, "/containers/\(id)/exec", body: create, headers: json).body)
        let start = try JSONSerialization.data(withJSONObject: ["Detach": false, "Tty": false])
        var demuxer = DockerLogDemuxer(framed: true)
        var stdout = ""
        var stderr = ""
        for try await data in transport.stream(.POST, path("/exec/\(made.Id)/start"), body: start, headers: json) {
            for chunk in demuxer.feed(data) {
                if chunk.stream == .stderr { stderr += chunk.text } else { stdout += chunk.text }
            }
        }
        let inspect = try await get(Inspect.self, "/exec/\(made.Id)/json")
        return ExecResult(stdout: stdout, stderr: stderr, exitCode: inspect.ExitCode ?? 0)
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
        let response = try await send(.HEAD, "/containers/\(id)/archive", ["path": path])
        guard let header = response.header("X-Docker-Container-Path-Stat"), let stat = DockerTar.pathStat(header) else {
            throw DockerError(status: response.status, message: "\(path): Docker said nothing about it.")
        }
        return stat
    }

    func read(_ id: String, file: String) async throws -> Data {
        let entries = DockerTar.entries(of: try await send(.GET, "/containers/\(id)/archive", ["path": file]).body)
        guard let entry = entries.first(where: { $0.kind == .file }) else { throw DockerError(status: 0, message: "\(file) isn't a file.") }
        return entry.data
    }

    /// Writes `data` as `file`, through a plain ustar archive (DockerTar).
    func write(_ id: String, file: String, data: Data, mode: Int = 0o644) async throws {
        let url = URL(fileURLWithPath: file)
        guard let archive = DockerTar.archive(name: url.lastPathComponent, data: data, mode: mode) else {
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

    /// A container made and never started, `volume` at /volume — enough for
    /// the archive endpoint to read and write the volume: nothing runs, so
    /// any image on the Mac will do. Labelled, and removed by the caller.
    func helper(mounting volume: String, image: String) async throws -> String {
        struct Created: Decodable { var Id: String }
        let body = try JSONSerialization.data(withJSONObject: [
            "Image": image, "Cmd": ["true"], "Labels": ["overterm.helper": "1"],
            "HostConfig": ["Binds": ["\(volume):/volume"]],
        ])
        let response = try await send(.POST, "/containers/create", body: body, headers: [("Content-Type", "application/json")])
        return try JSONDecoder().decode(Created.self, from: response.body).Id
    }

    /// A volume's files as a tar, `volume/` at its top.
    @discardableResult
    func export(volume name: String, to file: URL, using image: String) async throws -> Int {
        let helper = try await helper(mounting: name, image: image)
        defer { Task { try? await remove(container: helper, force: true) } }
        return try await download("/containers/\(helper)/archive", ["path": "/volume"], to: file)
    }

    /// A volume made (if it isn't there) and filled from a tar `export`
    /// wrote.
    func `import`(volume name: String, from file: URL, using image: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name, "Labels": ["overterm.imported": "1"]])
        try await send(.POST, "/volumes/create", body: body, headers: [("Content-Type", "application/json")])
        let helper = try await helper(mounting: name, image: image)
        defer { Task { try? await remove(container: helper, force: true) } }
        let tar = try Data(contentsOf: file, options: .mappedIfSafe)
        try await send(.PUT, "/containers/\(helper)/archive", ["path": "/"], body: tar, headers: [("Content-Type", "application/x-tar")])
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
