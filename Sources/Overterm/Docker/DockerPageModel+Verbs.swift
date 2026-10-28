import Foundation

/// Each resource's verbs, once: the detail's buttons and the right-click
/// menu are both drawn from these (`DockerActionBar`, `DockerVerbMenu`).
extension DockerPageModel {
    // MARK: Containers

    /// `targets`: what a menu acts on — the selection when the container is
    /// in it. `act`: who starts and stops it, and says when that failed (the
    /// panel has its own).
    func verbs(
        for container: ContainerSummary, targets: [ContainerSummary]? = nil, act: ((DockerEngine.ContainerAction) -> Void)? = nil
    ) -> [DockerVerb] {
        let targets = targets ?? [container]
        let act = act ?? { [weak self] action in self?.act(action, on: targets) }
        let endpoint = docker.endpoint
        let running = container.state == .running
        let notRunning = running ? nil : "It isn't running."
        var verbs = [
            DockerVerb(title: container.state.isUp ? "Stop" : "Start", symbol: container.state.isUp ? "stop.fill" : "play.fill", place: .button, key: "s") {
                act(container.state.isUp ? .stop : .start)
            },
            DockerVerb(title: "Restart", symbol: "arrow.clockwise", place: .button, key: "r") { act(.restart) },
            DockerVerb(title: "Open a Shell in a Tab", label: "Shell", symbol: "terminal", place: .button, key: "e", unavailable: notRunning) {
                [weak self] in self?.actions?.run(DockerCommands.shell(in: container, endpoint: endpoint), nil)
            },
        ]
        if let url = docker.ports(of: container).first?.url {
            verbs.append(
                DockerVerb(title: "Open \(url.absoluteString)", label: "Open", symbol: "safari", place: .button, key: "o") { [weak self] in
                    self?.actions?.open(url)
                })
        }
        if container.state == .running || container.state == .paused {
            let paused = container.state == .paused
            verbs.append(DockerVerb(title: paused ? "Unpause" : "Pause", symbol: paused ? "play" : "pause", key: "p") { act(paused ? .unpause : .pause) })
        }
        verbs += [
            DockerVerb(title: "Debug Shell Beside It", symbol: "ladybug", key: "E", unavailable: notRunning) { [weak self] in
                self?.actions?.run(DockerCommands.debugShell(beside: container, image: Settings.shared.dockerDebugImage, endpoint: endpoint), nil)
            },
            DockerVerb(title: "Follow Logs in a Tab", symbol: "text.alignleft", key: "t") { [weak self] in
                self?.actions?.run(DockerCommands.followLogs(of: container, endpoint: endpoint), nil)
            },
        ]
        if DockerDatabaseGuess.kind(of: container.Image) != nil {
            verbs.append(DockerVerb(title: "Open in Database…", symbol: "cylinder", key: "d", group: 1) { [weak self] in self?.openInDatabase(container) })
        }
        verbs += [
            DockerVerb(title: "Copy Name", symbol: "doc.on.doc", group: 2) { [weak self] in self?.actions?.copy(container.name) },
            DockerVerb(title: "Copy ID", symbol: "number", group: 2) { [weak self] in self?.actions?.copy(container.Id) },
            DockerVerb(title: "Copy as docker run", symbol: "terminal", group: 2) { [weak self] in self?.copyRunCommand(container) },
            DockerVerb(title: "Export Filesystem…", symbol: "square.and.arrow.up", group: 3) { [weak self] in
                self?.actions?.pickSave("\(container.name).tar") { self?.exportContainer(container, to: $0) }
            },
            DockerVerb(title: "Run Another Like It…", symbol: "plus.square.on.square", group: 3) { [weak self] in
                // Its window is the page's: brought up first from the panel.
                if self?.visible == false { self?.actions?.openPage() }
                self?.runAnother(like: container)
            },
            DockerVerb(
                title: targets.count > 1 ? "Remove \(targets.count) Containers…" : "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫"
            ) { [weak self] in self?.confirmRemove(targets) },
        ]
        return verbs
    }

    // MARK: Compose projects

    /// `act`: who starts, stops and restarts its containers (the panel has its own).
    func verbs(for project: ComposeProject, act: ((DockerEngine.ContainerAction, [ContainerSummary]) -> Void)? = nil) -> [DockerVerb] {
        let lasting = project.containers.filter { !$0.isOneOff }
        func run(_ verb: String, _ action: DockerEngine.ContainerAction, _ containers: [ContainerSummary]) {
            if let act { act(action, containers) } else { compose(verb, project) }
        }
        return [
            DockerVerb(title: "Up (in a Tab)", label: "Up", symbol: "play.fill", place: .button, key: "u") { [weak self] in self?.compose("up", project) },
            DockerVerb(title: "Restart", symbol: "arrow.clockwise", place: .button) { run("restart", .restart, lasting) },
            DockerVerb(title: "Stop", symbol: "stop.fill", place: .button) { run("stop", .stop, lasting.filter { $0.state.isUp }) },
            DockerVerb(title: "Follow Logs in a Tab", label: "Logs in a Tab", symbol: "text.alignleft", place: .button) { [weak self] in
                self?.compose("logs", project)
            },
            DockerVerb(title: "Start", symbol: "play") { run("start", .start, lasting) },
            DockerVerb(title: "Pull Images in a Tab", symbol: "arrow.down.circle") { [weak self] in self?.compose("pull", project) },
            DockerVerb(title: "Open Compose File", symbol: "doc.text", group: 1) { [weak self] in self?.editComposeFile(project) },
            DockerVerb(title: "Show Resolved Config", symbol: "doc.text.magnifyingglass", group: 1) { [weak self] in self?.showResolvedConfig(project) },
            DockerVerb(
                title: "Copy Folder", symbol: "folder", unavailable: project.workingDir == nil ? "Compose didn't say where it ran." : nil, group: 1
            ) { [weak self] in
                if let folder = project.workingDir { self?.actions?.copy(folder) }
            },
            DockerVerb(title: "Down…", label: "Down", symbol: "eject", place: .remove, key: "D") { [weak self] in self?.compose("down", project) },
        ]
    }

    // MARK: Images

    /// `targets`: what Remove removes — the selection when the image is in it.
    func verbs(for image: ImageSummary, targets: [ImageSummary]? = nil) -> [DockerVerb] {
        let name = image.tags.first
        let endpoint = docker.endpoint
        let busy = docker.containers(using: image).filter { $0.state.isUp }
        var verbs = [
            DockerVerb(title: "Run…", symbol: "play.fill", place: .button, key: "n") { [weak self] in
                self?.runSpec = DockerRunSpec(image: name ?? image.Id)
            }
        ]
        if let name {
            verbs.append(DockerVerb(title: "Pull Again", label: "Pull", symbol: "arrow.down.circle", place: .button) { [weak self] in self?.pull(name) })
        }
        verbs.append(
            DockerVerb(title: "Tag…", symbol: "tag", place: .button) { [weak self] in
                self?.actions?.askName("Tag “\(name ?? image.shortID)”", "Another name for the same image:", name ?? "") { self?.tag(image, as: $0) }
            })
        if let name {
            verbs.append(
                DockerVerb(title: "Run in a Tab", symbol: "terminal") { [weak self] in
                    self?.actions?.run(DockerCommands.prefix(for: endpoint) + "docker run --rm -it \(DockerCommands.quote(name))", nil)
                })
            if hasScout {
                verbs.append(
                    DockerVerb(
                        title: "Docker Scout", symbol: "shield.lefthalf.filled", group: 1,
                        children: [
                            DockerVerb(title: "Quickview in a Tab", symbol: "eye") { [weak self] in self?.scout("quickview", name) },
                            DockerVerb(title: "Vulnerabilities in a Tab", symbol: "exclamationmark.shield") { [weak self] in self?.scout("cves", name) },
                            DockerVerb(title: "Base Image Updates in a Tab", symbol: "arrow.up.circle") { [weak self] in self?.scout("recommendations", name) },
                        ]))
            }
        }
        verbs.append(
            DockerVerb(title: "Save as tar…", symbol: "square.and.arrow.up", group: 2) { [weak self] in
                self?.actions?.pickSave("\((name ?? image.shortID).replacingOccurrences(of: "/", with: "_")).tar") { self?.saveImage(image, to: $0) }
            })
        if let name { verbs.append(DockerVerb(title: "Copy Name", symbol: "doc.on.doc", group: 3) { [weak self] in self?.actions?.copy(name) }) }
        verbs += [
            DockerVerb(title: "Copy ID", symbol: "number", group: 3) { [weak self] in self?.actions?.copy(image.Id) },
            DockerVerb(
                title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫",
                unavailable: busy.isEmpty ? nil : "\(busy.map(\.name).joined(separator: ", ")) runs it."
            ) { [weak self] in self?.confirmRemove(images: targets ?? [image]) },
        ]
        return verbs
    }

    // MARK: Volumes

    func verbs(for volume: VolumeSummary) -> [DockerVerb] {
        let users = docker.containers(mounting: volume)
        let endpoint = docker.endpoint
        return [
            DockerVerb(title: "Browse in a Tab", label: "Browse", symbol: "terminal", place: .button) { [weak self] in
                self?.actions?.run(
                    DockerCommands.prefix(for: endpoint) + "docker run --rm -it -v \(DockerCommands.quote(volume.Name)):/volume -w /volume alpine sh", nil)
            },
            DockerVerb(title: "Export…", symbol: "square.and.arrow.up", place: .button) { [weak self] in
                self?.actions?.pickSave("\(volume.shortName).tar") { self?.exportVolume(volume, to: $0) }
            },
            DockerVerb(title: "Clone…", symbol: "plus.square.on.square", place: .button) { [weak self] in
                self?.actions?.askName("Clone “\(volume.shortName)”", "A new volume with the same files.", volume.shortName + "-copy") {
                    self?.cloneVolume(volume, as: $0)
                }
            },
            DockerVerb(title: "Import Into a New Volume…", symbol: "square.and.arrow.down") { [weak self] in self?.importVolumeAsking() },
            DockerVerb(title: "Copy Name", symbol: "doc.on.doc", group: 1) { [weak self] in self?.actions?.copy(volume.Name) },
            DockerVerb(title: "Copy Mountpoint", symbol: "folder", group: 1) { [weak self] in self?.actions?.copy(volume.Mountpoint) },
            DockerVerb(
                title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫",
                unavailable: users.isEmpty ? nil : "\(users.map(\.name).joined(separator: ", ")) mounts it."
            ) { [weak self] in self?.confirmRemove(volumes: [volume]) },
        ]
    }

    /// A tar an export wrote, into a volume made for it.
    func importVolumeAsking() {
        actions?.pickOpen { [weak self] file in
            self?.actions?.askName("Import “\(file.lastPathComponent)”", "Into a new volume called:", file.deletingPathExtension().lastPathComponent) {
                self?.importVolume($0, from: file)
            }
        }
    }

    // MARK: Networks

    func verbs(for network: NetworkSummary) -> [DockerVerb] {
        let members = docker.containers(on: network)
        // A container on host or none has no other network to have.
        let fixed = network.Name == "host" || network.Name == "none"
        let others = docker.containers.filter { container in !members.contains { $0.Id == container.Id } }
        var verbs = [
            DockerVerb(
                title: "Connect a Container", label: "Connect", symbol: "link", place: .button,
                unavailable: fixed ? "Nothing joins \(network.Name) this way." : others.isEmpty ? "Every container is on it." : nil,
                children: others.map { container in
                    DockerVerb(title: container.name, symbol: "shippingbox") { [weak self] in self?.connect(container, to: network) }
                }),
            DockerVerb(title: "Copy Name", symbol: "doc.on.doc", place: .button) { [weak self] in self?.actions?.copy(network.Name) },
        ]
        if let subnet = network.subnet {
            verbs.append(DockerVerb(title: "Copy Subnet", symbol: "number") { [weak self] in self?.actions?.copy(subnet) })
        }
        verbs += [
            DockerVerb(title: "Copy ID", symbol: "number") { [weak self] in self?.actions?.copy(network.Id) },
            DockerVerb(
                title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫",
                unavailable: network.isBuiltIn
                    ? "Docker's own." : members.isEmpty ? nil : "\(members.map(\.name).joined(separator: ", ")) \(members.count == 1 ? "is" : "are") on it."
            ) { [weak self] in self?.confirmRemove(networks: [network]) },
        ]
        return verbs
    }

    func connect(_ container: ContainerSummary, to network: NetworkSummary) {
        changeNetwork {
            try await $0.connect(container: container.Id, to: network.Id)
        } failed: {
            "Connect \(container.name): \($0)"
        }
    }

    func disconnect(_ container: ContainerSummary, from network: NetworkSummary) {
        changeNetwork {
            try await $0.disconnect(container: container.Id, from: network.Id)
        } failed: {
            "Disconnect \(container.name): \($0)"
        }
    }

    /// The engine sends no list-worthy event for a connect (Docker sends one
    /// at every start too): both lists are read again here.
    private func changeNetwork(_ change: @escaping @Sendable (DockerEngine) async throws -> Void, failed: @escaping (String) -> String) {
        guard let engine = docker.engine else { return }
        Task {
            do {
                try await change(engine)
            } catch {
                self.error = failed(error.localizedDescription)
            }
            await docker.reload()
            docker.load(.networks)
        }
    }

    // MARK: Builds

    func verbs(for build: DockerBuildRecord, detail: DockerBuildDetail? = nil) -> [DockerVerb] {
        let endpoint = docker.endpoint
        var verbs: [DockerVerb] = []
        if let file = detail?.dockerfileURL {
            verbs.append(
                DockerVerb(title: "Open Dockerfile", label: "Dockerfile", symbol: "doc.text", place: .button) { [weak self] in
                    self?.actions?.edit(file)
                })
        }
        verbs += [
            DockerVerb(title: "Log in a Tab", symbol: "text.alignleft", place: .button) { [weak self] in
                self?.actions?.run(DockerCommands.prefix(for: endpoint) + "docker buildx history logs \(DockerCommands.quote(build.shortRef))", nil)
            },
            DockerVerb(title: "Copy Ref", symbol: "doc.on.doc", place: .button) { [weak self] in self?.actions?.copy(build.shortRef) },
        ]
        if let context = detail?.context {
            verbs.append(DockerVerb(title: "Copy Context", symbol: "folder") { [weak self] in self?.actions?.copy(context) })
        }
        verbs.append(DockerVerb(title: "Remove Record", label: "Remove", symbol: "trash", place: .remove, key: "⌫") { [weak self] in self?.removeBuild(build) })
        return verbs
    }

    // MARK: Models

    func verbs(for model: RunnerModel) -> [DockerVerb] {
        var verbs = [
            DockerVerb(title: "Chat in a Tab", label: "Chat", symbol: "bubble.left.and.bubble.right", place: .button, key: "n") { [weak self] in
                self?.runModel(model)
            },
            DockerVerb(title: "Copy Name", symbol: "doc.on.doc", place: .button) { [weak self] in self?.actions?.copy(model.reference) },
            DockerVerb(title: "Copy ID", symbol: "number") { [weak self] in self?.actions?.copy(model.id) },
        ]
        if let endpoints = modelsPlace.flatMap(ModelRunner.endpoints) {
            verbs.append(
                DockerVerb(title: "Copy Endpoint for a Container", symbol: "link", group: 1) { [weak self] in
                    self?.actions?.copy(endpoints.containers)
                })
            if let mac = endpoints.mac {
                verbs.append(DockerVerb(title: "Copy Endpoint for This Mac", symbol: "link", group: 1) { [weak self] in self?.actions?.copy(mac) })
            }
        }
        verbs.append(
            DockerVerb(title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫") { [weak self] in
                self?.confirmRemove(models: [model])
            })
        return verbs
    }
}
