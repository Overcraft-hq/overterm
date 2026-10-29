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
        let unknown = "\(container.name) isn't a database Overterm knows (PostgreSQL, MySQL, MariaDB, ClickHouse)."
        guard DockerDatabaseGuess.kind(of: container, reference: imageReference(of: container)) != nil || DockerClient.listsImageByID(container) else {
            error = unknown
            return
        }
        Task {
            guard let detail = try? await docker.engine?.container(container.Id) else { return }
            // An image listed by its ID is known by the name inspect keeps.
            guard DockerDatabaseGuess.kind(of: container, reference: detail.Config.Image) != nil else {
                error = unknown
                return
            }
            guard let guess = DockerDatabaseGuess.guess(container, env: detail.env, endpoint: docker.endpoint, reference: detail.Config.Image) else {
                error = "\(container.name) publishes no port on this Mac: the Database panel can't reach it."
                return
            }
            actions?.openDatabase(guess)
        }
    }

    /// Its own client in a terminal tab (`DockerClient`): who to sign in as
    /// is read from its env by name — inspect, only when asked — and
    /// expanded by its own shell, so the tab's command line holds no secret.
    /// An image listed by its ID is known once inspect names it. A failure
    /// is said on the page, and in an alert when the page isn't on screen
    /// (the panel's menu, the right-hand pane).
    func openClient(_ container: ContainerSummary) {
        let known = clientKind(of: container)
        guard container.state == .running, known != nil || DockerClient.listsImageByID(container), let engine = docker.engine else { return }
        let endpoint = docker.endpoint
        Task {
            do {
                let detail = try await engine.container(container.Id)
                guard let kind = DockerClient.kind(of: container, reference: detail.Config.Image) else { return }
                actions?.run(DockerClient.command(kind, in: container, env: DockerClient.names(in: detail.env), endpoint: endpoint), nil)
            } catch {
                let what = known.map { "\($0.program) in \(container.name)" } ?? "\(container.name)'s client"
                self.error = "\(what): \(error.localizedDescription)"
                if !visible { actions?.alert(what, error.localizedDescription) }
            }
        }
    }

    /// Its own client's kind, as far as what is read says
    /// (`DockerClient.kind`).
    func clientKind(of container: ContainerSummary, detail: ContainerDetail? = nil) -> DockerClient.Kind? {
        DockerClient.kind(of: container, reference: imageReference(of: container, detail: detail))
    }

    /// The name a container's image was made from, when the list says only
    /// its ID: inspect's, as read already for its detail — the page's, or
    /// `detail` (the panel's). Never read for this.
    func imageReference(of container: ContainerSummary, detail: ContainerDetail? = nil) -> String? {
        guard DockerClient.listsImageByID(container) else { return nil }
        for known in [detail, session?.detail] where known?.Id == container.Id { return known?.Config.Image }
        return nil
    }

    // MARK: Models

    var selectedModels: [RunnerModel] { models?.models.filter { modelSelection.contains($0.id) } ?? [] }

    /// Model Runner's models, read when the section shows — from the
    /// runner's own API, never `docker model` (which installs a runner
    /// on an engine that has none).
    func loadModels() {
        guard let engine = docker.engine else { return }
        let place = ModelRunner.place(runtime: docker.runtime, remote: docker.publishedHost != nil, containers: docker.containers)
        modelsPlace = place
        Task {
            do {
                let contents = try await ModelRunner.read(place, engine: engine)
                if contents != models { models = contents }
                modelsError = nil
            } catch {
                models = nil
                modelsError = "Model Runner: \(error.localizedDescription)"
            }
        }
    }

    /// A chat with it, in a terminal tab.
    func runModel(_ model: RunnerModel) {
        actions?.run(DockerCommands.prefix(for: docker.endpoint) + "docker model run " + DockerCommands.quote(model.reference), nil)
    }

    /// A model by name, pulled in a terminal tab where its layers show.
    func pullModel() {
        actions?.askName("Pull a Model", "From Docker Hub (ai/…) or Hugging Face (hf.co/…):", "ai/smollm2") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.actions?.run(DockerCommands.prefix(for: self.docker.endpoint) + "docker model pull " + DockerCommands.quote(name), nil)
        }
    }

    /// What starts the runner where it isn't answering: Docker Desktop's
    /// setting, the engine's container, or its install — in a terminal
    /// tab, but for a container that is only stopped.
    func startModelRunner() {
        switch modelsPlace {
        case .desktop: actions?.run("docker desktop enable model-runner", nil)
        case .stopped(let id, _):
            Task {
                try? await docker.perform(.start, on: id)
                loadModels()
            }
        case .absent(let command?): actions?.run(DockerCommands.prefix(for: docker.endpoint) + command, nil)
        default: break
        }
    }

    func confirmRemove(models: [RunnerModel]) {
        guard !models.isEmpty, let engine = docker.engine, let place = modelsPlace else { return }
        let names = models.map(\.name)
        actions?.confirm(
            models.count == 1 ? "Remove “\(names[0])”?" : "Remove \(models.count) models?",
            "Its files leave Model Runner's store; pulling it again downloads it all.", "Remove"
        ) { [weak self] in
            Task {
                for model in models {
                    do {
                        try await ModelRunner.remove(model, place: place, engine: engine)
                        self?.modelSelection.remove(model.id)
                    } catch {
                        self?.error = "Remove \(model.name): \(error.localizedDescription)"
                    }
                }
                self?.loadModels()
            }
        }
    }

    // MARK: Scout

    /// Docker Scout on an image, in a terminal tab: it signs in, sends the
    /// image's packages to Docker's service and prints as it goes.
    func scout(_ verb: String, _ image: String) {
        actions?.run(DockerCommands.scout(verb, image: image, endpoint: docker.endpoint), nil)
    }

    // MARK: MCP Toolkit

    func loadMCPToolkit() {
        Task {
            let clients = await DockerMCPToolkit.read(endpoint: docker.endpoint)
            if clients != mcpClients { mcpClients = clients }
        }
    }

    /// Connects an agent to the Toolkit's gateway, or disconnects it — in
    /// a terminal tab: it rewrites that agent's own config.
    func toggleMCP(_ client: MCPToolkitClient) {
        actions?.run(DockerMCPToolkit.command(client, connect: !client.connected), nil)
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
    func helperImage() async -> String? { await docker.engine?.anyImage() }

    /// Long work on the page — an export, an import, a commit: `what` said
    /// while it runs, its answer once it is done, or why it failed.
    func transfer(_ what: String, _ work: @escaping () async throws -> String) {
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
            guard let engine = docker.engine, let image = await self?.helperImage() else { throw DockerError.noHelperImage }
            let bytes = try await engine.export(volume: volume.Name, to: file, using: image)
            return "\(volume.shortName): \(DockerBytes.string(bytes)) in \(file.lastPathComponent)."
        }
    }

    func importVolume(_ name: String, from file: URL) {
        transfer("Importing into \(name)") { [weak self, docker] in
            guard let engine = docker.engine, let image = await self?.helperImage() else { throw DockerError.noHelperImage }
            try await engine.import(volume: name, from: file, using: image)
            docker.load(.volumes)
            return "\(file.lastPathComponent) is in the volume \(name)."
        }
    }

    /// A copy under another name: exported, then imported.
    func cloneVolume(_ volume: VolumeSummary, as name: String) {
        transfer("Cloning \(volume.shortName)") { [weak self, docker] in
            guard let engine = docker.engine, let image = await self?.helperImage() else { throw DockerError.noHelperImage }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-clone-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: file) }
            try await engine.export(volume: volume.Name, to: file, using: image)
            try await engine.import(volume: name, from: file, using: image)
            docker.load(.volumes)
            return "\(volume.shortName) copied into \(name)."
        }
    }

    // MARK: Files on the Mac

    /// The project's compose file in the editor.
    func editComposeFile(_ project: ComposeProject) {
        if project.planned, let folder = project.workingDir {
            guard let file = ComposeProjects.composeFile(in: URL(fileURLWithPath: folder)) else {
                error = "\(project.name)'s compose file isn't in \((folder as NSString).abbreviatingWithTildeInPath) any more."
                return
            }
            actions?.edit(file)
            return
        }
        guard let file = project.configFiles.first(where: { !ports.isOurs($0) && FileManager.default.fileExists(atPath: $0) }) else {
            error = "\(project.name)'s compose file isn't on this Mac\(project.configFiles.first.map { " (\($0))" } ?? "")."
            return
        }
        actions?.edit(URL(fileURLWithPath: file))
    }

    /// What Compose makes of the project's files — variables filled in,
    /// overrides merged — as `docker compose config` writes it, in the
    /// editor: a copy, so editing it changes nothing, and it goes when its
    /// tab closes. A copy is a file, and a secret never lands on disk: env
    /// files' contents aren't asked for, and what Compose filled in from
    /// the variables is masked (`ComposeConfig.masked`).
    func showResolvedConfig(_ project: ComposeProject) {
        guard let cli = DockerCLI(endpoint: docker.endpoint) else {
            error = "docker isn't on this Mac, so Compose can't be asked."
            return
        }
        let folder = project.workingDir.map { URL(fileURLWithPath: $0) }
        let endpoint = docker.endpoint
        Task {
            // Its override as its files are now, if it has one.
            await ports.refresh(for: project, endpoint: endpoint)
            // One before it runs is its folder's files, as `up` reads them:
            // no `-p` (a name read earlier may be stale), no `-f` — unless
            // its checkout has ports of its own: then as its Up has them.
            let kept = ports.override(of: project)
            let arguments: [String]
            if project.planned, let kept {
                arguments = ["compose", "-p", kept.project] + ports.files(for: project).flatMap { ["-f", $0] } + ["config"]
            } else {
                arguments = (project.planned ? ["compose"] : ComposeFacts.arguments(project, files: ports.files(for: project))) + ["config"]
            }
            let place = (project.planned && kept == nil ? folder : nil) ?? FileManager.default.homeDirectoryForCurrentUser
            do {
                let yaml = try await cli.composeConfig(arguments, in: place, timeout: 30)
                let masked = ComposeConfig.masked(yaml, secrets: folder.map(ComposeConfig.dotEnvSecrets(in:)) ?? [])
                let copy = AppEnvironment.supportDirectory.appendingPathComponent("Compose", isDirectory: true)
                    .appendingPathComponent("\(project.name).resolved.yaml")
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                let header = "# docker compose config — \(project.name)\(folder.map { ", from \($0.path)" } ?? ""). A copy, secrets masked: editing it changes nothing.\n"
                try (header + masked).write(to: copy, atomically: true, encoding: .utf8)
                actions?.showCopy(copy)
            } catch {
                self.error = "Compose config: \(ComposeConfig.message(error))"
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
    /// where the credential helper signs in, can. `platform`: that variant
    /// of it (an emulated image's native one), shown as `image (platform)`;
    /// an image without one says so.
    func pull(_ name: String, platform: DockerPlatform? = nil) {
        let image = name.trimmingCharacters(in: .whitespaces)
        let key = platform.map { "\(image) (\($0.description))" } ?? image
        guard !image.isEmpty, let engine = docker.engine, pulls[key]?.done != false else { return }
        pulls[key] = DockerPull(image: key)
        Task {
            do {
                for try await progress in engine.pull(image, platform: platform?.description) { pulls[key]?.add(progress) }
                pulls[key]?.done = true
                docker.load(.images)
            } catch {
                pulls[key]?.error = Self.pullError(error.localizedDescription, image: image, platform: platform)
                pulls[key]?.done = true
            }
        }
    }

    /// What a pull's failure says: where credentials are, or that no such
    /// variant exists (the classic store's words, then containerd's).
    nonisolated static func pullError(_ message: String, image: String, platform: DockerPlatform?) -> String {
        if let platform, message.contains("no matching manifest") || message.contains("no match for platform") {
            return "\(image) has no \(platform.description) variant — build one for it, or use another image."
        }
        let auth = message.contains("unauthorized") || message.contains("denied") || message.contains("authentication")
        let command = platform.map { "docker pull --platform \($0.description) \(image)" } ?? "docker pull \(image)"
        return auth ? "\(message) — pull it in a terminal tab (\(command)), where your credentials are." : message
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
                    // Its Files tab's helper holds it, and every other helper
                    // on it: the engine would refuse. Each waited for till it
                    // is gone, and none made again meanwhile.
                    self.removingVolumes.insert(volume.Name)
                    if self.volumeFiles?.volume == volume.Name { await self.closeVolumeFiles()?.value }
                    await DockerHelpers.remove(mounting: volume.Name, on: self.docker.engine)
                    do {
                        try await self.docker.engine?.remove(volume: volume.Name)
                        self.volumeSelection.remove(volume.Name)
                    } catch {
                        self.error = "Remove \(volume.shortName): \(error.localizedDescription)"
                    }
                    self.removingVolumes.remove(volume.Name)
                }
                // One that stayed shows its Files again.
                self.updateVolumeFiles()
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
        // A volume a helper holds is in use, and a prune leaves it.
        let volumes = choice.volumes ? cleanPlan.volumes.map(\.Name) : []
        cleaning = false
        Task {
            var freed = 0
            var removed = 0
            removingVolumes.formUnion(volumes)
            if let shown = volumeFiles?.volume, volumes.contains(shown) { await closeVolumeFiles()?.value }
            for volume in volumes { await DockerHelpers.remove(mounting: volume, on: engine) }
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
                    volumeSelection.subtract(report.VolumesDeleted ?? [])
                }
                if choice.networks { removed += try await engine.prune(.networks).NetworksDeleted?.count ?? 0 }
                if choice.buildCache { freed += try await engine.prune(.buildCache).SpaceReclaimed ?? 0 }
                cleaned = "Removed \(removed), freed \(DockerBytes.string(freed))."
            } catch {
                self.error = "Clean Up: \(error.localizedDescription)"
            }
            removingVolumes.subtract(volumes)
            // One the prune left shows its Files again.
            updateVolumeFiles()
            await docker.reload()
            prepareCleanUp()
        }
    }
}
