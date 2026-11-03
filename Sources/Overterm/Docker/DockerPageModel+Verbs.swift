import Foundation

/// Each resource's verbs, once: the detail's buttons and the right-click
/// menu are both drawn from these (`ResourceActionBar`, `ResourceVerbMenu`).
extension DockerPageModel {
    // MARK: Containers

    /// `targets`: what a menu acts on — the selection when the container is
    /// in it. `detail`: its inspect, when someone else's detail has read it
    /// (the panel's; the page's own is known). `act`: who starts and stops
    /// it, and says when that failed (the panel has its own).
    func verbs(
        for container: ContainerSummary, targets: [ContainerSummary]? = nil, detail: ContainerDetail? = nil,
        act: ((DockerEngine.ContainerAction) -> Void)? = nil
    ) -> [ResourceVerb] {
        let targets = targets ?? [container]
        let act = act ?? { [weak self] action in self?.act(action, on: targets) }
        let endpoint = docker.endpoint
        let running = container.state == .running
        let notRunning = running ? nil : "It isn't running."
        let gone = container.state == .dead || container.state == .removing ? "Docker is removing it." : nil
        var verbs = [
            ResourceVerb(title: container.state.isUp ? "Stop" : "Start", symbol: container.state.isUp ? "stop.fill" : "play.fill", place: .button, key: "s") {
                act(container.state.isUp ? .stop : .start)
            }
        ]
        // One that failed: an agent told how it ended (`DockerAgentBrief`).
        if trouble(of: container, detail: detail) != nil {
            verbs.append(
                ResourceVerb(title: "Ask an Agent Why…", label: "Ask Why", symbol: "sparkles", place: .button, key: "a") { [weak self] in
                    self?.askWhy(container)
                })
        }
        verbs += [
            ResourceVerb(title: "Restart", symbol: "arrow.clockwise", place: .button, key: "r") { act(.restart) },
            ResourceVerb(title: "Open a Shell in a Tab", label: "Shell", symbol: "terminal", place: .button, key: "e", unavailable: notRunning) {
                [weak self] in self?.actions?.run(DockerCommands.shell(in: container, endpoint: endpoint), nil)
            },
        ]
        // A database's own client, signed in from its env (DockerClient).
        let reference = imageReference(of: container, detail: detail)
        if let client = DockerClient.kind(of: container, reference: reference) {
            verbs.append(
                ResourceVerb(
                    title: "Open \(client.program) in a Tab", label: client.program, symbol: "cylinder", place: .button, key: "q", unavailable: notRunning
                ) { [weak self] in self?.openClient(container) })
        }
        if let url = docker.ports(of: container).first?.url {
            verbs.append(
                ResourceVerb(title: "Open \(url.absoluteString)", label: "Open", symbol: "safari", place: .button, key: "o") { [weak self] in
                    self?.actions?.open(url)
                })
        }
        if container.state == .running || container.state == .paused {
            let paused = container.state == .paused
            verbs.append(ResourceVerb(title: paused ? "Unpause" : "Pause", symbol: paused ? "play" : "pause", key: "p") { act(paused ? .unpause : .pause) })
        }
        verbs += [
            ResourceVerb(title: "Debug Shell Beside It", symbol: "ladybug", key: "E", unavailable: notRunning) { [weak self] in
                self?.actions?.run(DockerCommands.debugShell(beside: container, image: Settings.shared.dockerDebugImage, endpoint: endpoint), nil)
            },
            ResourceVerb(title: "Follow Logs in a Tab", symbol: "text.alignleft", key: "t") { [weak self] in
                self?.actions?.run(DockerCommands.followLogs(of: container, endpoint: endpoint), nil)
            },
        ]
        // A test's compose stack (Go's compose module) is its run's, not a
        // project's: nothing to rebuild it from.
        if container.composeProject != nil, !container.isOneOff, !Testcontainers.isMember(container) {
            verbs.append(
                ResourceVerb(title: "Rebuild and Start Its Service in a Tab", symbol: "hammer", key: "b") { [weak self] in
                    guard let self else { return }
                    self.rebuild(Self.rebuilds(of: Set(targets.map(\.Id)), in: self.docker.projects))
                })
        }
        // An amd64 image on Apple silicon: built again, or its image's own
        // variant, in a tab.
        if let emulation = docker.emulation(of: container) {
            let built = builds(container)
            let native = nativeCommand(for: container, detail: detail)
            verbs.append(
                ResourceVerb(
                    title: emulation.verbTitle(for: container, built: built), symbol: "cpu",
                    unavailable: native == nil ? "Its image goes by its id now: there is no name to pull." : nil, group: 1,
                    note: emulation.summary + " " + emulation.advice(for: container, built: built)
                ) { [weak self] in self?.runNatively(container, detail: detail) })
        }
        if DockerDatabaseGuess.kind(of: container, reference: reference) != nil {
            verbs.append(ResourceVerb(title: "Open in Database…", symbol: "cylinder", key: "d", group: 1) { [weak self] in self?.openInDatabase(container) })
        }
        verbs += [
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 2) { [weak self] in self?.actions?.copy(container.name) },
            ResourceVerb(title: "Copy ID", symbol: "number", group: 2) { [weak self] in self?.actions?.copy(container.Id) },
            ResourceVerb(title: "Copy as docker run", symbol: "terminal", group: 2) { [weak self] in self?.copyRunCommand(container) },
            // Its memory, CPUs and restart policy in place; the sheet is the
            // page's, brought up first from the panel. So is what a rename
            // and a save say as they go, and when they fail.
            ResourceVerb(title: "Settings…", symbol: "slider.horizontal.3", key: ",", unavailable: gone, group: 3) { [weak self] in
                if self?.visible == false { self?.actions?.openPage() }
                self?.editSettings(container)
            },
            ResourceVerb(title: "Rename…", symbol: "pencil", group: 3) { [weak self] in
                if self?.visible == false { self?.actions?.openPage() }
                self?.askRename(container)
            },
            ResourceVerb(title: "Export Filesystem…", symbol: "square.and.arrow.up", group: 4) { [weak self] in
                self?.actions?.pickSave("\(container.name).tar") { self?.exportContainer(container, to: $0) }
            },
            ResourceVerb(title: "Save as Image…", symbol: "square.stack.3d.down.right", unavailable: gone, group: 4) { [weak self] in
                if self?.visible == false { self?.actions?.openPage() }
                self?.askSaveAsImage(container)
            },
            ResourceVerb(title: "Run Another Like It…", symbol: "plus.square.on.square", group: 4) { [weak self] in
                // Its window is the page's: brought up first from the panel.
                if self?.visible == false { self?.actions?.openPage() }
                self?.runAnother(like: container)
            },
            ResourceVerb(
                title: targets.count > 1 ? "Remove \(targets.count) Containers…" : "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫"
            ) { [weak self] in self?.confirmRemove(targets) },
        ]
        return verbs
    }

    // MARK: Emulation

    /// What runs an emulated container natively (`DockerCommands.native`),
    /// its project's files as the store says them; nil when it runs
    /// natively, or its image has no name left to pull.
    func nativeCommand(for container: ContainerSummary, detail: ContainerDetail? = nil) -> (command: String, folder: URL?)? {
        guard let emulation = docker.emulation(of: container) else { return nil }
        let project = container.composeProject.flatMap { name in docker.projects.first { $0.name == name } }
        let command = DockerCommands.native(
            container, reference: imageReference(of: container, detail: detail), project: project, platform: emulation.engine, built: builds(container),
            endpoint: docker.endpoint, files: project.map { ports.files(for: $0) })
        return command.map { ($0, project?.workingDir.map { URL(fileURLWithPath: $0) }) }
    }

    /// Whether its project's files build its service (`ComposeFacts.built`):
    /// an image's name can't say — `image:` names what `build:` makes, and
    /// a tag moves on. Nil while they aren't read, or can't be; false for
    /// a container that is no service.
    func builds(_ container: ContainerSummary) -> Bool? {
        guard DockerEmulation.isService(container), let name = container.composeProject, let service = container.composeService else { return false }
        guard let project = docker.projects.first(where: { $0.name == name }) else { return nil }
        return composeFacts(for: project)?.built.map { $0.contains(service) }
    }

    /// Its verb: in a tab in its project's folder, once its files have
    /// said what they build and the project's override is as they are now.
    func runNatively(_ container: ContainerSummary, detail: ContainerDetail? = nil) {
        let run: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, let native = self.nativeCommand(for: container, detail: detail) else { return }
            self.actions?.run(native.command, native.folder)
        }
        guard DockerEmulation.isService(container), let name = container.composeProject, let project = docker.projects.first(where: { $0.name == name })
        else { return run() }
        Task { [weak self] in
            await self?.loadComposeFacts(project)
            self?.withCurrentPorts(project, run)
        }
    }

    // MARK: Compose projects

    /// `act`: who starts, stops and restarts its containers (the panel has
    /// its own); `report`: where Check for Updates says what it couldn't
    /// do (the panel's line; the page's banners when nil). Watch and Up
    /// With Profiles… are there when its files say so (`composeFacts(for:)`).
    func verbs(
        for project: ComposeProject, act: ((DockerEngine.ContainerAction, [ContainerSummary]) -> Void)? = nil, report: ((String) -> Void)? = nil
    ) -> [ResourceVerb] {
        if project.planned { return verbs(planned: project, report: report) }
        let lasting = project.containers.filter { !$0.isOneOff }
        let facts = composeFacts(for: project)
        func run(_ verb: String, _ action: DockerEngine.ContainerAction, _ containers: [ContainerSummary]) {
            if let act { act(action, containers) } else { compose(verb, project) }
        }
        var verbs = [
            ResourceVerb(title: "Up (in a Tab)", label: "Up", symbol: "play.fill", place: .button, key: "u") { [weak self] in self?.compose("up", project) }
        ]
        verbs += pullUpdatesVerbs(project)
        if facts?.watched.isEmpty == false {
            verbs.append(ResourceVerb(title: "Watch in a Tab", label: "Watch", symbol: "eye", place: .button, key: "w") { [weak self] in self?.startWatch(project) })
        }
        verbs += [
            ResourceVerb(title: "Restart", symbol: "arrow.clockwise", place: .button) { run("restart", .restart, lasting) },
            ResourceVerb(title: "Stop", symbol: "stop.fill", place: .button) { run("stop", .stop, lasting.filter { $0.state.isUp }) },
            ResourceVerb(title: "Follow Logs in a Tab", label: "Logs in a Tab", symbol: "text.alignleft", place: .button) { [weak self] in
                self?.compose("logs", project)
            },
            ResourceVerb(title: "Start", symbol: "play") { run("start", .start, lasting) },
            freePortsVerb(project),
            ResourceVerb(title: "Rebuild and Up in a Tab", symbol: "hammer", key: "b") { [weak self] in
                self?.rebuild([ComposeRebuild(project: project, services: [])])
            },
        ]
        if let profiles = facts?.profiles, !profiles.isEmpty {
            verbs.append(
                ResourceVerb(title: "Up With Profiles…", symbol: "square.stack.3d.up") { [weak self] in self?.chooseProfiles(project, profiles) })
        }
        verbs.append(ResourceVerb(title: "Pull Images in a Tab", symbol: "arrow.down.circle") { [weak self] in self?.compose("pull", project) })
        verbs.append(checkUpdatesVerb(project, report: report))
        verbs += ownPortsVerbs(project)
        verbs += [
            ResourceVerb(title: "Open Compose File", symbol: "doc.text", group: 1) { [weak self] in self?.editComposeFile(project) },
            ResourceVerb(title: "Show Resolved Config", symbol: "doc.text.magnifyingglass", group: 1) { [weak self] in self?.showResolvedConfig(project) },
            ResourceVerb(
                title: "Copy Folder", symbol: "folder", unavailable: project.workingDir == nil ? "Compose didn't say where it ran." : nil, group: 1
            ) { [weak self] in
                if let folder = project.workingDir { self?.actions?.copy(folder) }
            },
            ResourceVerb(title: "Down…", label: "Down", symbol: "eject", place: .remove, key: "D") { [weak self] in self?.compose("down", project) },
        ]
        return verbs
    }

    /// Pull Updates, when its registries name newer images for some of
    /// its services: those pulled in a tab.
    private func pullUpdatesVerbs(_ project: ComposeProject) -> [ResourceVerb] {
        guard !updates.summary(of: project).available.isEmpty else { return [] }
        return [
            ResourceVerb(title: "Pull Updates in a Tab", label: "Pull Updates", symbol: "arrow.down.circle.fill", place: .button) { [weak self] in
                self?.pullUpdates(project)
            }
        ]
    }

    /// Check for Updates (C): its services' images asked of their
    /// registries — not those its files build. While a check runs, the
    /// verb stops it.
    private func checkUpdatesVerb(_ project: ComposeProject, report: ((String) -> Void)?) -> ResourceVerb {
        if updates.running { return stopCheckingVerb }
        var unavailable: String?
        if updates.references(of: project).isEmpty {
            unavailable = updates.built(of: project).isEmpty ? "Its services name no image." : "Its files build its images: no registry to ask."
        }
        return ResourceVerb(title: "Check for Updates", symbol: "arrow.triangle.2.circlepath", key: DockerKey.checkUpdates.key, unavailable: unavailable) {
            [weak self] in self?.checkUpdates(project, report: report)
        }
    }

    /// A check under way, stopped: what it asked stays.
    var stopCheckingVerb: ResourceVerb {
        ResourceVerb(title: "Stop Checking for Updates", symbol: "stop.circle") { [weak self] in self?.updates.cancel() }
    }

    /// Up on Free Ports (U): whatever of the stack's ports is taken moved,
    /// without asking — an override in Overterm's folder. With its files
    /// elsewhere (a remote engine's), or a Compose too old for it (known
    /// after an Up asked), it says why not (`freePortsUnavailable`).
    private func freePortsVerb(_ project: ComposeProject) -> ResourceVerb {
        ResourceVerb(title: "Up on Free Ports", symbol: "arrow.left.arrow.right", key: "U", unavailable: freePortsUnavailable(project)) { [weak self] in
            self?.startUp(.project(project), freePorts: .yes)
        }
    }

    /// A stack on ports of its own: back to the file's, and the command
    /// its Up runs (for a shell that should start it the same way).
    private func ownPortsVerbs(_ project: ComposeProject) -> [ResourceVerb] {
        guard ports.override(of: project) != nil else { return [] }
        return [
            ResourceVerb(title: "Back to the File's Ports…", symbol: "arrow.uturn.backward") { [weak self] in self?.confirmForgetPorts(project) },
            ResourceVerb(title: "Copy Up Command", symbol: "doc.on.doc", group: 1) { [weak self] in
                self?.withCurrentPorts(project) { [weak self] in
                    guard let self else { return }
                    self.actions?.copy(self.composeCommand(project, "up -d"))
                }
            },
        ]
    }

    /// A project before it runs: what can be done to nothing yet — no
    /// stop, restart, logs or down. Watch ups it first, when its plan says
    /// a service has a `develop.watch`.
    private func verbs(planned project: ComposeProject, report: ((String) -> Void)?) -> [ResourceVerb] {
        var verbs = [
            ResourceVerb(title: "Up (in a Tab)", label: "Up", symbol: "play.fill", place: .button, key: "u") { [weak self] in self?.compose("up", project) }
        ]
        verbs += pullUpdatesVerbs(project)
        if watches(project) {
            verbs.append(ResourceVerb(title: "Watch in a Tab", label: "Watch", symbol: "eye", place: .button, key: "w") { [weak self] in self?.startWatch(project) })
        }
        verbs += [
            ResourceVerb(title: "Pull Images in a Tab", label: "Pull", symbol: "arrow.down.circle", place: .button) { [weak self] in
                self?.compose("pull", project)
            },
            checkUpdatesVerb(project, report: report),
            freePortsVerb(project),
        ]
        verbs += ownPortsVerbs(project)
        verbs += [
            ResourceVerb(title: "Open Compose File", symbol: "doc.text", group: 1) { [weak self] in self?.editComposeFile(project) },
            ResourceVerb(title: "Show Resolved Config", symbol: "doc.text.magnifyingglass", group: 1) { [weak self] in self?.showResolvedConfig(project) },
            ResourceVerb(title: "Copy Folder", symbol: "folder", group: 1) { [weak self] in
                if let folder = project.workingDir { self?.actions?.copy(folder) }
            },
        ]
        return verbs
    }

    /// A service of a project Compose has made: rebuilt and started, run
    /// once, pulled, its logs followed — in a tab in the project's folder;
    /// restarted here, through the engine, as the project's Restart is; its
    /// logs shown in the project's Logs tab, narrowed to it.
    func verbs(for service: ComposeService, in project: ComposeProject) -> [ResourceVerb] {
        let lasting = service.containers.filter { !$0.isOneOff }
        let never = service.containers.isEmpty ? "Nothing of it has run yet." : nil
        return [
            ResourceVerb(title: "Rebuild and Start in a Tab", label: "Rebuild", symbol: "hammer", place: .button, key: "b") { [weak self] in
                self?.rebuild([ComposeRebuild(project: project, services: [service.name])])
            },
            ResourceVerb(
                title: "Restart", symbol: "arrow.clockwise", place: .button, unavailable: lasting.isEmpty ? "Compose hasn't made it yet." : nil
            ) { [weak self] in self?.act(.restart, on: lasting) },
            ResourceVerb(title: "Show Its Logs", label: "Logs", symbol: "text.alignleft", place: .button, unavailable: never) { [weak self] in
                self?.showLogs(of: service, in: project)
            },
            ResourceVerb(title: "Follow Its Logs in a Tab", symbol: "text.alignleft", unavailable: never) { [weak self] in
                self?.composeService("logs -f --tail 100", service, project)
            },
            ResourceVerb(title: "Pull in a Tab", symbol: "arrow.down.circle") { [weak self] in self?.composeService("pull", service, project) },
            ResourceVerb(title: "Run a One-Off in a Tab", symbol: "play.rectangle") { [weak self] in self?.composeService("run --rm", service, project) },
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 1) { [weak self] in self?.actions?.copy(service.name) },
        ]
    }

    // MARK: Testcontainers runs

    /// A test run's: Stop All leaves Ryuk, so it still removes them when the
    /// run ends; Remove All is what Ryuk does then (`remove(session:)`).
    func verbs(for session: TestcontainersSession) -> [ResourceVerb] {
        let up = session.members.filter { $0.state.isUp }
        return [
            ResourceVerb(title: "Stop All", symbol: "stop.fill", place: .button, unavailable: up.isEmpty ? "Nothing in it runs." : nil) { [weak self] in
                self?.act(.stop, on: up)
            },
            ResourceVerb(
                title: "Copy Session ID", label: "Copy ID", symbol: "number", place: .button,
                unavailable: session.id.isEmpty ? "These belong to no run — kept for reuse." : nil
            ) { [weak self] in self?.actions?.copy(session.id) },
            ResourceVerb(title: "Remove All…", label: "Remove All", symbol: "trash", place: .remove, key: "⌫") { [weak self] in
                self?.confirmRemove(session: session)
            },
        ]
    }

    // MARK: Images

    /// `targets`: what Remove removes — the selection when the image is in it.
    func verbs(for image: ImageSummary, targets: [ImageSummary]? = nil) -> [ResourceVerb] {
        let name = image.tags.first
        let endpoint = docker.endpoint
        let busy = docker.containers(using: image).filter { $0.state.isUp }
        var verbs = [
            ResourceVerb(title: "Run…", symbol: "play.fill", place: .button, key: "n") { [weak self] in
                self?.runSpec = DockerRunSpec(image: name ?? image.Id)
            }
        ]
        if let name {
            // Its registry names another image now: that one, as a button —
            // in a tab when the engine couldn't sign in to its registry.
            if let newer = image.tags.first(where: { updates.state(of: $0) == .available }) {
                let hub = DockerImageReference(newer)?.domain == "docker.io"
                verbs.append(
                    ResourceVerb(title: hub ? "Pull Update" : "Pull Update in a Tab", label: "Update", symbol: "arrow.down.circle.fill", place: .button) {
                        [weak self] in self?.pullUpdates(images: [image])
                    })
            } else {
                verbs.append(ResourceVerb(title: "Pull Again", label: "Pull", symbol: "arrow.down.circle", place: .button) { [weak self] in self?.pull(name) })
            }
        }
        verbs.append(
            ResourceVerb(title: "Tag…", symbol: "tag", place: .button) { [weak self] in
                self?.actions?.askName("Tag “\(name ?? image.shortID)”", "Another name for the same image:", name ?? "") { self?.tag(image, as: $0) }
            })
        if let name {
            verbs.append(
                ResourceVerb(title: "Run in a Tab", symbol: "terminal") { [weak self] in
                    self?.actions?.run(DockerCommands.prefix(for: endpoint) + "docker run --rm -it \(DockerCommands.quote(name))", nil)
                })
            // Over the network, so only when asked: a tag built or tagged
            // here has no registry to ask.
            verbs.append(
                updates.running
                    ? stopCheckingVerb
                    : ResourceVerb(
                        title: "Check for Updates", symbol: "arrow.triangle.2.circlepath", key: DockerKey.checkUpdates.key,
                        unavailable: updates.uncheckable(image)
                    ) { [weak self] in self?.checkUpdates(images: targets ?? [image]) })
            // Built for another architecture: the engine's own variant.
            if let emulation = docker.emulation(ofImage: image.Id) {
                verbs.append(ResourceVerb(title: emulation.imageVerbTitle, symbol: "cpu") { [weak self] in self?.pull(name, platform: emulation.engine) })
            }
            if hasScout {
                verbs.append(
                    ResourceVerb(
                        title: "Docker Scout", symbol: "shield.lefthalf.filled", group: 1,
                        children: [
                            // Here, on its Vulnerabilities tab; the rest in a tab.
                            ResourceVerb(
                                title: "Scan for Vulnerabilities", symbol: "shield.lefthalf.filled",
                                unavailable: scans.scan(for: image.Id)?.state.isScanning == true ? "Scanning…" : nil
                            ) { [weak self] in self?.scanVulnerabilities(image) },
                            ResourceVerb(title: "Quickview in a Tab", symbol: "eye", group: 1) { [weak self] in self?.scout("quickview", name) },
                            ResourceVerb(title: "Vulnerabilities in a Tab", symbol: "exclamationmark.shield", group: 1) { [weak self] in
                                self?.scout("cves", name)
                            },
                            ResourceVerb(title: "Base Image Updates in a Tab", symbol: "arrow.up.circle", group: 1) { [weak self] in
                                self?.scout("recommendations", name)
                            },
                        ]))
            }
        }
        verbs.append(
            ResourceVerb(title: "Save as tar…", symbol: "square.and.arrow.up", group: 2) { [weak self] in
                self?.actions?.pickSave("\((name ?? image.shortID).replacingOccurrences(of: "/", with: "_")).tar") { self?.saveImage(image, to: $0) }
            })
        if let name { verbs.append(ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 3) { [weak self] in self?.actions?.copy(name) }) }
        verbs += [
            ResourceVerb(title: "Copy ID", symbol: "number", group: 3) { [weak self] in self?.actions?.copy(image.Id) },
            ResourceVerb(
                title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫",
                unavailable: busy.isEmpty ? nil : "\(busy.map(\.name).joined(separator: ", ")) runs it."
            ) { [weak self] in self?.confirmRemove(images: targets ?? [image]) },
        ]
        return verbs
    }

    // MARK: Volumes

    func verbs(for volume: VolumeSummary) -> [ResourceVerb] {
        let users = docker.containers(mounting: volume)
        let endpoint = docker.endpoint
        return [
            // Its files on the page, its detail's Files tab; a shell on it
            // in a tab is behind More.
            ResourceVerb(title: "Browse Files", label: "Files", symbol: "folder", place: .button, key: "f") { [weak self] in
                self?.browseFiles(of: volume)
            },
            ResourceVerb(title: "Export…", symbol: "square.and.arrow.up", place: .button) { [weak self] in
                self?.actions?.pickSave("\(volume.shortName).tar") { self?.exportVolume(volume, to: $0) }
            },
            ResourceVerb(title: "Clone…", symbol: "plus.square.on.square", place: .button) { [weak self] in
                self?.actions?.askName("Clone “\(volume.shortName)”", "A new volume with the same files.", volume.shortName + "-copy") {
                    self?.cloneVolume(volume, as: $0)
                }
            },
            ResourceVerb(title: "Open a Shell on It in a Tab", label: "Shell", symbol: "terminal") { [weak self] in
                self?.actions?.run(
                    DockerCommands.prefix(for: endpoint) + "docker run --rm -it -v \(DockerCommands.quote(volume.Name)):/volume -w /volume alpine sh", nil)
            },
            ResourceVerb(title: "Import Into a New Volume…", symbol: "square.and.arrow.down") { [weak self] in self?.importVolumeAsking() },
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 1) { [weak self] in self?.actions?.copy(volume.Name) },
            ResourceVerb(title: "Copy Mountpoint", symbol: "folder", group: 1) { [weak self] in self?.actions?.copy(volume.Mountpoint) },
            ResourceVerb(
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

    func verbs(for network: NetworkSummary) -> [ResourceVerb] {
        let members = docker.containers(on: network)
        // A container on host or none has no other network to have.
        let fixed = network.Name == "host" || network.Name == "none"
        let others = docker.containers.filter { container in !members.contains { $0.Id == container.Id } }
        var verbs = [
            ResourceVerb(
                title: "Connect a Container", label: "Connect", symbol: "link", place: .button,
                unavailable: fixed ? "Nothing joins \(network.Name) this way." : others.isEmpty ? "Every container is on it." : nil,
                children: others.map { container in
                    ResourceVerb(title: container.name, symbol: "shippingbox") { [weak self] in self?.connect(container, to: network) }
                }),
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", place: .button) { [weak self] in self?.actions?.copy(network.Name) },
        ]
        if let subnet = network.subnet {
            verbs.append(ResourceVerb(title: "Copy Subnet", symbol: "number") { [weak self] in self?.actions?.copy(subnet) })
        }
        verbs += [
            ResourceVerb(title: "Copy ID", symbol: "number") { [weak self] in self?.actions?.copy(network.Id) },
            ResourceVerb(
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

    /// What the detail's session knows of it — its inspect, its steps —
    /// when it is the build the detail shows.
    func verbs(for build: DockerBuildRecord) -> [ResourceVerb] {
        let endpoint = docker.endpoint
        let session = buildSession.flatMap { $0.ref == build.shortRef ? $0 : nil }
        let detail = session?.detail
        var verbs: [ResourceVerb] = []
        if let file = detail?.dockerfileURL {
            verbs.append(
                ResourceVerb(title: "Open Dockerfile", label: "Dockerfile", symbol: "doc.text", place: .button) { [weak self] in
                    self?.actions?.edit(file)
                })
        }
        verbs += [
            // The plain alternative: buildx's own printer, a running build
            // followed to its end.
            ResourceVerb(title: "Log in a Tab", symbol: "text.alignleft", place: .button, key: DockerKey.followLogs.key) { [weak self] in
                self?.actions?.run(DockerCommands.buildLog(build, endpoint: endpoint), nil)
            },
            ResourceVerb(title: "Copy Ref", symbol: "doc.on.doc", place: .button) { [weak self] in self?.actions?.copy(build.shortRef) },
        ]
        // Only once the build args are known: a step's name can hold a
        // secret one's value, and this goes to the clipboard.
        if let session, session.secretsKnown, !session.progress.steps.isEmpty {
            verbs.append(
                ResourceVerb(title: "Copy Log", symbol: "doc.plaintext") { [weak self, weak session] in
                    guard let text = session?.plainText else { return }
                    self?.actions?.copy(text)
                })
        }
        if let context = detail?.context {
            verbs.append(ResourceVerb(title: "Copy Context", symbol: "folder") { [weak self] in self?.actions?.copy(context) })
        }
        verbs.append(
            ResourceVerb(
                title: "Remove Record…", label: "Remove", symbol: "trash", place: .remove, key: DockerKey.remove.key,
                unavailable: build.running ? "It's still running." : nil
            ) { [weak self] in self?.confirmRemove(builds: [build]) })
        return verbs
    }

    // MARK: Models

    func verbs(for model: RunnerModel) -> [ResourceVerb] {
        var verbs = [
            ResourceVerb(title: "Chat in a Tab", label: "Chat", symbol: "bubble.left.and.bubble.right", place: .button, key: "n") { [weak self] in
                self?.runModel(model)
            },
            ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", place: .button) { [weak self] in self?.actions?.copy(model.reference) },
            ResourceVerb(title: "Copy ID", symbol: "number") { [weak self] in self?.actions?.copy(model.id) },
        ]
        if let endpoints = modelsPlace.flatMap(ModelRunner.endpoints) {
            verbs.append(
                ResourceVerb(title: "Copy Endpoint for a Container", symbol: "link", group: 1) { [weak self] in
                    self?.actions?.copy(endpoints.containers)
                })
            if let mac = endpoints.mac {
                verbs.append(ResourceVerb(title: "Copy Endpoint for This Mac", symbol: "link", group: 1) { [weak self] in self?.actions?.copy(mac) })
            }
        }
        verbs.append(
            ResourceVerb(title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫") { [weak self] in
                self?.confirmRemove(models: [model])
            })
        return verbs
    }
}
