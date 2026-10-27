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
            guard let guess = DockerDatabaseGuess.guess(container, env: detail.env) else {
                error = "\(container.name) publishes no port on this Mac: the Database panel can't reach it."
                return
            }
            actions?.openDatabase(guess)
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
