import Foundation

/// An image on its way down: each layer's progress, summed. Pure.
struct DockerPull: Equatable, Sendable {
    var image: String
    var layers: [String: DockerEngine.PullProgress] = [:]
    /// What the engine said last (`Pulling from library/redis`, `Digest: …`).
    var status = "Waiting"
    var done = false
    var error: String?

    mutating func add(_ progress: DockerEngine.PullProgress) {
        if let id = progress.id, progress.total != nil || layers[id] != nil || progress.status.hasPrefix("Pull") || progress.status.hasPrefix("Waiting") {
            layers[id] = progress
        }
        status = progress.status
    }

    /// Bytes downloaded of the layers that said how many there are.
    var downloaded: (current: Int, total: Int) {
        layers.values.filter { $0.status.hasPrefix("Downloading") || $0.status.hasPrefix("Download complete") || $0.status.hasPrefix("Pull complete") || $0.status.hasPrefix("Extracting") }
            .reduce((0, 0)) { sum, layer in
                guard let total = layer.total else { return sum }
                let current = layer.status.hasPrefix("Downloading") ? (layer.current ?? 0) : total
                return (sum.0 + current, sum.1 + total)
            }
    }

    /// `3 of 5 layers — 41 MB of 120 MB`.
    var summary: String {
        if let error { return error }
        if done { return status.isEmpty ? "Pulled" : status }
        let finished = layers.values.filter { $0.status == "Pull complete" || $0.status == "Already exists" }.count
        let bytes = downloaded
        var parts: [String] = []
        if !layers.isEmpty { parts.append("\(finished) of \(layers.count) layers") }
        if bytes.total > 0 {
            parts.append(
                "\(DockerBytes.string(bytes.current)) of \(DockerBytes.string(bytes.total))"
            )
        }
        return parts.isEmpty ? status : parts.joined(separator: " — ")
    }
}

extension DockerPageModel {
    // MARK: Database

    /// Its connection, guessed from its image, env and published port,
    /// in the Database panel's form — nothing saved until the form is.
    func openInDatabase(_ container: ContainerSummary) {
        guard DockerDatabaseGuess.kind(of: container.Image) != nil else {
            error = "\(container.name) isn't a database Overterm knows (PostgreSQL, MySQL, MariaDB, ClickHouse)."
            return
        }
        Task {
            guard let detail = try? await docker.engine?.container(container.Id) else { return }
            guard let guess = DockerDatabaseGuess.guess(container, env: detail.env, endpoint: docker.endpoint) else {
                error = "\(container.name) publishes no port on this Mac: the Database panel can't reach it."
                return
            }
            actions?.openDatabase(guess)
        }
    }

    // MARK: Builds

    /// The builds `buildx history` keeps, read when the section shows.
    func loadBuilds() {
        guard let cli = DockerCLI(endpoint: docker.endpoint) else {
            buildsError = "docker isn't on this Mac: builds are read with docker buildx."
            return
        }
        Task {
            do {
                builds = DockerBuildRecord.parse(try await cli.run(["buildx", "history", "ls", "--format", "json"], timeout: 30))
                buildsError = nil
            } catch {
                buildsError = "docker buildx history: \(error.localizedDescription)"
            }
        }
    }

    func buildDetail(_ build: DockerBuildRecord) async -> DockerBuildDetail? {
        guard let cli = DockerCLI(endpoint: docker.endpoint),
            let output = try? await cli.run(["buildx", "history", "inspect", build.shortRef, "--format", "json"], timeout: 30)
        else { return nil }
        return DockerBuildDetail.parse(output)
    }

    func buildLog(_ build: DockerBuildRecord) async -> String {
        guard let cli = DockerCLI(endpoint: docker.endpoint) else { return "" }
        return (try? await cli.run(["buildx", "history", "logs", build.shortRef], timeout: 60)) ?? "(no log)"
    }

    func removeBuild(_ build: DockerBuildRecord) {
        guard let cli = DockerCLI(endpoint: docker.endpoint) else { return }
        Task {
            do {
                _ = try await cli.run(["buildx", "history", "rm", build.shortRef], timeout: 30)
                buildSelection.remove(build.id)
                loadBuilds()
            } catch {
                self.error = "Remove the build: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Export and import

    /// An image to make a helper from: it never runs, so any will do —
    /// a small one if there is one.
    func helperImage() async -> String? {
        guard let images = try? await docker.engine?.images(), !images.isEmpty else { return nil }
        let small = ["busybox", "alpine", "debian", "ubuntu"]
        for name in small {
            if let image = images.first(where: { $0.tags.contains { $0.hasPrefix(name + ":") } }) { return image.Id }
        }
        return images.min { $0.Size < $1.Size }?.Id
    }

    private func transfer(_ what: String, _ work: @escaping () async throws -> String) {
        transferring = what
        Task {
            do {
                cleaned = try await work()
            } catch {
                self.error = "\(what): \(error.localizedDescription)"
            }
            transferring = nil
        }
    }

    func exportContainer(_ container: ContainerSummary, to file: URL) {
        transfer("Exporting \(container.name)") { [docker] in
            guard let engine = docker.engine else { throw DockerError.unreachable("Docker isn't running.") }
            let bytes = try await engine.export(container: container.Id, to: file)
            return "\(container.name)'s filesystem: \(DockerBytes.string(bytes)) in \(file.lastPathComponent)."
        }
    }

    func saveImage(_ image: ImageSummary, to file: URL) {
        let name = image.tags.first ?? image.Id
        transfer("Saving \(name)") { [docker] in
            guard let engine = docker.engine else { throw DockerError.unreachable("Docker isn't running.") }
            let bytes = try await engine.save(image: name, to: file)
            return "\(name): \(DockerBytes.string(bytes)) in \(file.lastPathComponent) — docker load takes it back."
        }
    }

    func exportVolume(_ volume: VolumeSummary, to file: URL) {
        transfer("Exporting \(volume.shortName)") { [weak self, docker] in
            guard let engine = docker.engine, let image = await self?.helperImage() else { throw Self.noHelper }
            let bytes = try await engine.export(volume: volume.Name, to: file, using: image)
            return "\(volume.shortName): \(DockerBytes.string(bytes)) in \(file.lastPathComponent)."
        }
    }

    func importVolume(_ name: String, from file: URL) {
        transfer("Importing into \(name)") { [weak self, docker] in
            guard let engine = docker.engine, let image = await self?.helperImage() else { throw Self.noHelper }
            try await engine.import(volume: name, from: file, using: image)
            docker.load(.volumes)
            return "\(file.lastPathComponent) is in the volume \(name)."
        }
    }

    /// A copy under another name: exported, then imported.
    func cloneVolume(_ volume: VolumeSummary, as name: String) {
        transfer("Cloning \(volume.shortName)") { [weak self, docker] in
            guard let engine = docker.engine, let image = await self?.helperImage() else { throw Self.noHelper }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-clone-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: file) }
            try await engine.export(volume: volume.Name, to: file, using: image)
            try await engine.import(volume: name, from: file, using: image)
            docker.load(.volumes)
            return "\(volume.shortName) copied into \(name)."
        }
    }

    nonisolated static let noHelper = DockerError(
        status: 0, message: "A volume is read through a container that never runs, and it needs any image on this Mac — pull one (busybox).")

    // MARK: Files on the Mac

    /// The project's compose file in the editor.
    func editComposeFile(_ project: ComposeProject) {
        guard let file = project.configFiles.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            error = "\(project.name)'s compose file isn't on this Mac\(project.configFiles.first.map { " (\($0))" } ?? "")."
            return
        }
        actions?.edit(URL(fileURLWithPath: file))
    }

    /// What Compose makes of the project's files — variables filled in,
    /// overrides merged — as `docker compose config` writes it, in the
    /// editor (a copy: editing it changes nothing).
    func showResolvedConfig(_ project: ComposeProject) {
        guard let cli = DockerCLI(endpoint: docker.endpoint) else {
            error = "docker isn't on this Mac, so Compose can't be asked."
            return
        }
        let folder = project.workingDir.map { URL(fileURLWithPath: $0) }
        Task {
            do {
                let arguments = ["compose", "-p", project.name] + project.configFiles.flatMap { ["-f", $0] } + ["config"]
                let yaml = try await cli.run(arguments, timeout: 30)
                let copy = AppEnvironment.supportDirectory.appendingPathComponent("Compose", isDirectory: true)
                    .appendingPathComponent("\(project.name).resolved.yaml")
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ("# docker compose config — \(project.name)\(folder.map { ", from \($0.path)" } ?? ""). A copy: editing it changes nothing.\n" + yaml)
                    .write(to: copy, atomically: true, encoding: .utf8)
                actions?.edit(copy)
            } catch {
                self.error = "Compose config: \(error.localizedDescription)"
            }
        }
    }

    /// The engine's own settings in the editor: made `{}` when Docker
    /// Desktop has none yet; applied when it restarts.
    func editEngineConfig() {
        guard let file = docker.runtime.configFile(context: docker.endpoint?.context) else {
            error = "\(docker.runtime.name) keeps its settings elsewhere."
            return
        }
        if !FileManager.default.fileExists(atPath: file.path), docker.runtime == .dockerDesktop {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("{}\n".utf8).write(to: file)
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            error = "\(file.path) isn't there."
            return
        }
        actions?.edit(file)
    }

    // MARK: Run

    /// The Run window's command, in a terminal tab where it pulls and starts.
    func run(_ spec: DockerRunSpec) {
        runSpec = nil
        guard !spec.image.isEmpty else { return }
        actions?.run(spec.line(prefix: DockerCommands.prefix(for: docker.endpoint)), nil)
    }

    /// What would make `container` again, as a `docker run` (its image's
    /// own env and command left out).
    func runSpec(like container: ContainerSummary) async -> DockerRunSpec? {
        guard let engine = docker.engine, let detail = try? await engine.container(container.Id) else { return nil }
        let image = (try? await engine.imageConfig(container.ImageID ?? container.Image)) ?? (env: [], command: [])
        return DockerRunSpec.from(container, detail, imageEnv: image.env, imageCommand: image.command)
    }

    func copyRunCommand(_ container: ContainerSummary) {
        Task {
            guard let spec = await runSpec(like: container) else { return }
            actions?.copy(spec.line(prefix: DockerCommands.prefix(for: docker.endpoint)))
        }
    }

    /// The Run window, filled in as `container` was made — a new name.
    func runAnother(like container: ContainerSummary) {
        Task {
            guard var spec = await runSpec(like: container) else { return }
            spec.name = ""
            runSpec = spec
        }
    }

    // MARK: Images

    /// A public image down, its progress shown as it comes. One the engine
    /// may not pull alone (a private registry) says so; a terminal tab,
    /// where the credential helper signs in, can.
    func pull(_ name: String) {
        let image = name.trimmingCharacters(in: .whitespaces)
        guard !image.isEmpty, let engine = docker.engine, pulls[image]?.done != false else { return }
        pulls[image] = DockerPull(image: image)
        Task {
            do {
                for try await progress in engine.pull(image) { pulls[image]?.add(progress) }
                pulls[image]?.done = true
                docker.load(.images)
            } catch {
                let message = error.localizedDescription
                let auth = message.contains("unauthorized") || message.contains("denied") || message.contains("authentication")
                pulls[image]?.error = auth ? "\(message) — pull it in a terminal tab (docker pull \(image)), where your credentials are." : message
                pulls[image]?.done = true
            }
        }
    }

    func dismissPull(_ image: String) { pulls[image] = nil }

    /// Docker Hub's images for a term, through the engine; none when it
    /// can't reach Hub.
    func searchHub(_ term: String) async -> [DockerEngine.SearchResult] {
        (try? await docker.engine?.search(term)) ?? []
    }

    func tag(_ image: ImageSummary, as name: String) {
        let (repository, tag) = DockerEngine.split(name.trimmingCharacters(in: .whitespaces))
        Task {
            do {
                try await docker.engine?.tag(image: image.Id, repository: repository, tag: tag)
                docker.load(.images)
            } catch {
                self.error = "Tag \(image.shortID): \(error.localizedDescription)"
            }
        }
    }

    /// Images, asked first. One a stopped container was made from is
    /// removed with force (the container stays, by its id); one a running
    /// container uses isn't offered.
    func confirmRemove(images: [ImageSummary]) {
        let removable = images.filter { image in !docker.containers(using: image).contains { $0.state.isUp } }
        guard !removable.isEmpty else { return }
        let names = removable.map { $0.tags.first ?? $0.shortID }
        actions?.confirm(
            removable.count == 1 ? "Remove “\(names[0])”?" : "Remove \(removable.count) images?",
            "Their layers go unless another image shares them. An image is pulled or built again when it is next needed.", "Remove"
        ) { [weak self] in
            guard let self else { return }
            Task {
                for image in removable {
                    do {
                        try await self.docker.engine?.remove(image: image.Id, force: !self.docker.containers(using: image).isEmpty)
                        self.imageSelection.remove(image.Id)
                    } catch {
                        self.error = "Remove \(image.tags.first ?? image.shortID): \(error.localizedDescription)"
                    }
                }
                // After they went, not as they go.
                self.docker.load(.images)
            }
        }
    }

    // MARK: Volumes and networks

    /// Volumes no container mounts, asked first: their data goes with them.
    func confirmRemove(volumes: [VolumeSummary]) {
        let removable = volumes.filter { docker.containers(mounting: $0).isEmpty }
        guard !removable.isEmpty else { return }
        actions?.confirm(
            removable.count == 1 ? "Remove the volume “\(removable[0].shortName)”?" : "Remove \(removable.count) volumes?",
            "Their data is deleted, and can't be brought back.", "Remove"
        ) { [weak self] in
            guard let self else { return }
            Task {
                for volume in removable {
                    do {
                        try await self.docker.engine?.remove(volume: volume.Name)
                        self.volumeSelection.remove(volume.Name)
                    } catch {
                        self.error = "Remove \(volume.shortName): \(error.localizedDescription)"
                    }
                }
                self.docker.load(.volumes)
            }
        }
    }

    func confirmRemove(networks: [NetworkSummary]) {
        let removable = networks.filter { !$0.isBuiltIn && docker.containers(on: $0).isEmpty }
        guard !removable.isEmpty else { return }
        actions?.confirm(
            removable.count == 1 ? "Remove the network “\(removable[0].Name)”?" : "Remove \(removable.count) networks?",
            "Nothing is on them. Compose makes its own again at the next up.", "Remove"
        ) { [weak self] in
            guard let self else { return }
            Task {
                for network in removable {
                    do {
                        try await self.docker.engine?.remove(network: network.Id)
                        self.networkSelection.remove(network.Id)
                    } catch {
                        self.error = "Remove \(network.Name): \(error.localizedDescription)"
                    }
                }
                self.docker.load(.networks)
            }
        }
    }

    // MARK: Clean Up

    /// What Clean Up would remove with the choices made.
    var cleanPlan: DockerPrunePlan {
        DockerPrunePlan.make(
            cleanChoice, containers: docker.containers, images: docker.images, volumes: docker.volumes, networks: docker.networks,
            buildCache: docker.diskUsage?.BuildCache ?? [])
    }

    /// Everything Clean Up lists needs reading first.
    func prepareCleanUp() {
        for resource in [DockerModel.Resource.images, .volumes, .networks] { docker.load(resource) }
    }

    /// The engine's prunes, in the order that frees most: containers first,
    /// so their images and volumes are unused by the time those go.
    func cleanUp() {
        guard let engine = docker.engine else { return }
        let choice = cleanChoice
        cleaning = false
        Task {
            var freed = 0
            var removed = 0
            do {
                if choice.containers { removed += try await engine.prune(.containers).ContainersDeleted?.count ?? 0 }
                if choice.images {
                    let report = try await engine.prune(.images, everythingUnused: choice.allImages)
                    freed += report.SpaceReclaimed ?? 0
                    removed += report.ImagesDeleted?.filter { $0.Deleted != nil }.count ?? 0
                }
                if choice.volumes {
                    let report = try await engine.prune(.volumes, everythingUnused: choice.namedVolumes)
                    freed += report.SpaceReclaimed ?? 0
                    removed += report.VolumesDeleted?.count ?? 0
                }
                if choice.networks { removed += try await engine.prune(.networks).NetworksDeleted?.count ?? 0 }
                if choice.buildCache { freed += try await engine.prune(.buildCache).SpaceReclaimed ?? 0 }
                cleaned = "Removed \(removed), freed \(DockerBytes.string(freed))."
            } catch {
                self.error = "Clean Up: \(error.localizedDescription)"
            }
            await docker.reload()
            prepareCleanUp()
        }
    }
}
