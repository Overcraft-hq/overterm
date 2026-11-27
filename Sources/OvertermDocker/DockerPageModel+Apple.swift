import Foundation

/// An Apple container's detail's tabs.
package enum AppleContainerTab: String, CaseIterable, Identifiable {
    case overview, logs

    package var id: String { rawValue }
    package var title: String { rawValue.capitalized }
}

/// The Apple Containers section: Apple's `container` through its CLI
/// (`AppleContainerModel`) — its containers, images and volumes, their
/// verbs, its keys. What runs in a terminal tab is typed with the tool's
/// full path; what it changes here is asked first when it removes.
extension DockerPageModel {
    /// The section shows `part` (nil: it doesn't): the model reads it.
    package func wantApple(_ part: AppleContainerModel.Part?) {
        guard part != appleWanted else { return }
        if let appleWanted { apple.unwant(appleWanted) }
        appleWanted = part
        if let part { apple.want(part) }
    }

    /// The selected container's Logs, followed while they show.
    package func updateAppleStream() {
        guard section == .apple, appleTab == .containers, let container = appleDetailed else {
            appleSession?.close()
            appleSession = nil
            return
        }
        if appleSession?.id != container.id {
            appleSession?.close()
            appleSession = AppleContainerSession(id: container.id)
        }
        appleSession?.follow(shown: visible && showDetail && appleDetailTab == .logs, running: container.state == .running, tool: apple.tool)
    }

    package func appleSession(for container: AppleContainers.Container) -> AppleContainerSession {
        if let appleSession, appleSession.id == container.id { return appleSession }
        appleSession?.close()
        let made = AppleContainerSession(id: container.id)
        appleSession = made
        return made
    }

    // MARK: What shows

    /// The lists as the filter leaves them: a word anywhere in a name, an
    /// image, a port or an address; `-word` leaves those out.
    package var appleContainers: [AppleContainers.Container] {
        apple.containers.filter { container in
            Self.appleMatches(filter, [container.id, container.image, container.state.rawValue, container.address ?? ""] + container.ports.map(\.label))
        }
        .sorted { ($0.state.isUp ? 0 : 1, $0.id) < ($1.state.isUp ? 0 : 1, $1.id) }
    }

    package var appleImages: [AppleContainers.Image] {
        apple.images.filter { Self.appleMatches(filter, [$0.reference, $0.id]) }.sorted { $0.reference < $1.reference }
    }

    package var appleVolumes: [AppleContainers.Volume] {
        apple.volumes.filter { Self.appleMatches(filter, [$0.name, $0.source ?? ""]) }.sorted { $0.name < $1.name }
    }

    /// Whether every word of `filter` is in one of `fields` (a `-word` in
    /// none). Pure.
    package nonisolated static func appleMatches(_ filter: String, _ fields: [String]) -> Bool {
        let text = fields.joined(separator: " ").lowercased()
        return filter.lowercased().split(separator: " ").allSatisfy { word in
            word.hasPrefix("-") && word.count > 1 ? !text.contains(word.dropFirst()) : text.contains(word)
        }
    }

    package var appleSelected: [AppleContainers.Container] { apple.containers.filter { appleSelection.contains($0.id) } }
    package var appleSelectedImages: [AppleContainers.Image] { apple.images.filter { appleImageSelection.contains($0.id) } }
    package var appleSelectedVolumes: [AppleContainers.Volume] { apple.volumes.filter { appleVolumeSelection.contains($0.name) } }

    /// The container the detail shows: the one selected.
    package var appleDetailed: AppleContainers.Container? {
        appleSelection.count == 1 ? apple.containers.first { appleSelection.contains($0.id) } : nil
    }

    // MARK: Verbs

    package func verbs(for container: AppleContainers.Container) -> [ResourceVerb] {
        guard let tool = apple.tool else { return [] }
        let up = container.state.isUp
        let id = container.id
        let notRunning = up ? nil : "It isn't running."
        var verbs = [
            ResourceVerb(title: up ? "Stop" : "Start", symbol: up ? "stop.fill" : "play.fill", place: .button, key: "s") { [weak self] in
                self?.startOrStopApple([container])
            },
            ResourceVerb(title: "Shell in a Tab", label: "Shell", symbol: "terminal", place: .button, key: "e", unavailable: notRunning) { [weak self] in
                self?.actions?.run(AppleContainerCommands.shell(tool, in: id), nil)
            },
            ResourceVerb(title: "Logs", symbol: "text.alignleft", place: .button, key: "l") { [weak self] in
                self?.showDetail = true
                self?.appleDetailTab = .logs
            },
            ResourceVerb(title: "Follow Logs in a Tab", symbol: "terminal", key: "t") { [weak self] in
                self?.actions?.run(AppleContainerCommands.followLogs(tool, of: id), nil)
            },
        ]
        if let url = container.ports.lazy.compactMap(\.url).first {
            verbs.append(ResourceVerb(title: "Open \(url.absoluteString)", label: "Open", symbol: "safari", key: "o") { [weak self] in self?.actions?.open(url) })
        }
        verbs += [
            ResourceVerb(title: "Kill", symbol: "bolt.slash", unavailable: notRunning) { [weak self] in
                self?.apple.perform(AppleContainerCommands.kill(id), on: id, what: "Kill \(id)")
            },
            ResourceVerb(title: "Copy ID", symbol: "doc.on.doc", group: 1) { [weak self] in self?.actions?.copy(id) },
        ]
        if let address = container.address {
            verbs.append(ResourceVerb(title: "Copy Address", symbol: "network", group: 1) { [weak self] in self?.actions?.copy(address) })
        }
        verbs.append(
            ResourceVerb(title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫") { [weak self] in
                self?.confirmRemoveApple([container])
            })
        return verbs
    }

    package func verbs(for image: AppleContainers.Image) -> [ResourceVerb] {
        guard let tool = apple.tool else { return [] }
        let users = apple.containers(using: image)
        return [
            ResourceVerb(title: "Run in a Tab", label: "Run", symbol: "play.fill", place: .button, key: "n") { [weak self] in
                self?.actions?.run(AppleContainerCommands.run(tool, image: image.reference), nil)
            },
            ResourceVerb(title: "Pull Again in a Tab", label: "Pull", symbol: "arrow.down.circle", place: .button) { [weak self] in
                self?.actions?.run(AppleContainerCommands.pull(tool, image: image.reference), nil)
            },
            ResourceVerb(title: "Copy Reference", symbol: "doc.on.doc", group: 1) { [weak self] in self?.actions?.copy(image.reference) },
            ResourceVerb(
                title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫",
                unavailable: users.isEmpty ? nil : "\(users.map(\.id).joined(separator: ", ")) \(users.count == 1 ? "is" : "are") made from it."
            ) { [weak self] in self?.confirmRemoveApple(images: [image]) },
        ]
    }

    package func verbs(for volume: AppleContainers.Volume) -> [ResourceVerb] {
        let users = apple.containers(mounting: volume)
        var verbs = [ResourceVerb(title: "Copy Name", symbol: "doc.on.doc", group: 1) { [weak self] in self?.actions?.copy(volume.name) }]
        if let source = volume.source, !source.isEmpty {
            verbs.append(ResourceVerb(title: "Copy Its File's Path", symbol: "folder", group: 1) { [weak self] in self?.actions?.copy(source) })
        }
        verbs.append(
            ResourceVerb(
                title: "Remove…", label: "Remove", symbol: "trash", place: .remove, key: "⌫",
                unavailable: users.isEmpty ? nil : "\(users.map(\.id).joined(separator: ", ")) \(users.count == 1 ? "mounts" : "mount") it."
            ) { [weak self] in self?.confirmRemoveApple(volumes: [volume]) })
        return verbs
    }

    // MARK: Acting

    /// Start the stopped ones, stop the running ones — what `s` does.
    package func startOrStopApple(_ containers: [AppleContainers.Container]) {
        guard !containers.isEmpty else { return }
        let stopping = containers.contains { $0.state.isUp }
        for container in containers where container.state.isUp == stopping {
            apple.perform(
                stopping ? AppleContainerCommands.stop(container.id) : AppleContainerCommands.start(container.id), on: container.id,
                what: "\(stopping ? "Stop" : "Start") \(container.id)")
        }
    }

    package func confirmRemoveApple(_ containers: [AppleContainers.Container]) {
        guard !containers.isEmpty else { return }
        let running = containers.contains { $0.state.isUp }
        actions?.confirm(
            containers.count == 1 ? "Remove “\(containers[0].id)”?" : "Remove \(containers.count) containers?",
            (running ? "Running ones are stopped first. " : "") + "Their volumes stay.", "Remove"
        ) { [weak self] in
            guard let self else { return }
            for container in containers {
                self.apple.perform(AppleContainerCommands.delete(container.id), on: container.id, what: "Remove \(container.id)")
                self.appleSelection.remove(container.id)
            }
        }
    }

    package func confirmRemoveApple(images: [AppleContainers.Image]) {
        let removable = images.filter { apple.containers(using: $0).isEmpty }
        guard !removable.isEmpty else { return }
        actions?.confirm(
            removable.count == 1 ? "Remove the image “\(removable[0].shortName)”?" : "Remove \(removable.count) images?",
            "It is pulled again the next time something runs it.", "Remove"
        ) { [weak self] in
            guard let self else { return }
            for image in removable {
                self.apple.perform(AppleContainerCommands.deleteImage(image.reference), on: image.id, what: "Remove \(image.shortName)")
                self.appleImageSelection.remove(image.id)
            }
        }
    }

    package func confirmRemoveApple(volumes: [AppleContainers.Volume]) {
        let removable = volumes.filter { apple.containers(mounting: $0).isEmpty }
        guard !removable.isEmpty else { return }
        actions?.confirm(
            removable.count == 1 ? "Remove the volume “\(removable[0].name)”?" : "Remove \(removable.count) volumes?",
            "Their data is deleted, and can't be brought back.", "Remove"
        ) { [weak self] in
            guard let self else { return }
            for volume in removable {
                self.apple.perform(AppleContainerCommands.deleteVolume(volume.name), on: volume.name, what: "Remove \(volume.name)")
                self.appleVolumeSelection.remove(volume.name)
            }
        }
    }

    /// Clean Up's three: what each removes said before it goes, what it
    /// freed after.
    package enum ApplePrune: CaseIterable {
        case containers, images, volumes

        package var title: String {
            switch self {
            case .containers: "Remove Stopped Containers…"
            case .images: "Remove Unused Images…"
            case .volumes: "Remove Unused Volumes…"
            }
        }

        package var arguments: [String] {
            switch self {
            case .containers: AppleContainerCommands.prune
            case .images: AppleContainerCommands.pruneImages
            case .volumes: AppleContainerCommands.pruneVolumes
            }
        }

        package var question: (title: String, detail: String) {
            switch self {
            case .containers: ("Remove every stopped container?", "container prune removes them. Their volumes stay.")
            case .images: ("Remove the images nothing uses?", "container image prune removes those no tag and no container holds.")
            case .volumes: ("Remove the volumes nothing mounts?", "container volume prune deletes their data, and it can't be brought back.")
            }
        }
    }

    package func pruneApple(_ prune: ApplePrune) {
        let question = prune.question
        actions?.confirm(question.title, question.detail, "Remove") { [weak self] in
            self?.apple.prune(prune.arguments) { said in self?.cleaned = said.isEmpty ? "Done." : said }
        }
    }

    /// Pull…: a reference asked for, pulled in a terminal tab, where its
    /// progress and a sign-in show.
    package func pullAppleImage() {
        guard let tool = apple.tool else { return }
        actions?.askName("Pull an Image", "With Apple's container — a name, a tag:", "alpine:latest") { [weak self] reference in
            let trimmed = reference.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            self?.actions?.run(AppleContainerCommands.pull(tool, image: trimmed), nil)
        }
    }

    /// Its service, started or stopped in a terminal tab: the first start
    /// may ask to install a kernel, and that is the person's answer.
    package func startAppleService() {
        guard let tool = apple.tool else { return }
        actions?.run(AppleContainerCommands.startService(tool), nil)
    }

    package func stopAppleService() {
        guard let tool = apple.tool else { return }
        actions?.confirm("Stop Apple's container service?", "Every container it runs is stopped. container system stop, in a terminal tab.", "Stop") { [weak self] in
            self?.actions?.run(AppleContainerCommands.stopService(tool), nil)
        }
    }

    // MARK: Keys

    /// A key in the section: the selected container's, image's or
    /// volume's verb with that key.
    package func pressApple(_ key: DockerKey) -> Bool {
        switch key {
        case .toggleDetail:
            showDetail.toggle()
            return true
        case .details where appleTab == .containers:
            showDetail = true
            appleDetailTab = .logs
            return true
        case .startStop where appleTab == .containers:
            startOrStopApple(appleSelected)
            return true
        case .remove:
            switch appleTab {
            case .containers: confirmRemoveApple(appleSelected)
            case .images: confirmRemoveApple(images: appleSelectedImages)
            case .volumes: confirmRemoveApple(volumes: appleSelectedVolumes)
            }
            return true
        default: break
        }
        let offered: [ResourceVerb]
        switch appleTab {
        case .containers: offered = appleDetailed.map { verbs(for: $0) } ?? []
        case .images: offered = appleSelectedImages.first.map { verbs(for: $0) } ?? []
        case .volumes: offered = appleSelectedVolumes.first.map { verbs(for: $0) } ?? []
        }
        guard let verb = offered.first(where: { $0.key == key.key }) else { return false }
        if verb.unavailable == nil { verb.perform() }
        return true
    }
}
