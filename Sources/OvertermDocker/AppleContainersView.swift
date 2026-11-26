import SwiftUI

/// The Apple Containers section: Apple's `container`, beside whatever
/// Docker engine the page reaches — its containers, images and volumes as
/// its CLI lists them, the selected container's detail (Overview, Logs) at
/// the right. Its service down, it says so and offers to start it.
package struct AppleContainersView: View {
    @ObservedObject package var page: DockerPageModel
    @ObservedObject package var apple: AppleContainerModel
    @ObservedObject package var theme: ChromeTheme
    package let actions: DockerActions

    package init(page: DockerPageModel, apple: AppleContainerModel, theme: ChromeTheme, actions: DockerActions) {
        self._page = ObservedObject(wrappedValue: page)
        self._apple = ObservedObject(wrappedValue: apple)
        self._theme = ObservedObject(wrappedValue: theme)
        self.actions = actions
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 10)
            if let error = apple.error { banner(error) }
            Rectangle().fill(theme.border).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("docker.apple")
    }

    @ViewBuilder private var content: some View {
        switch apple.service {
        case _ where !apple.isInstalled:
            message(
                "Apple's container tool isn't installed",
                "Its installer, from github.com/apple/container, puts it in /usr/local/bin. It needs a Mac with Apple silicon.")
        case nil:
            ProgressView().controlSize(.small)
        case .stopped?:
            VStack(spacing: 12) {
                message("Apple's container service isn't running", "container system start starts it — the first time, it may ask to install a Linux kernel.")
                Button("Start the Service") { page.startAppleService() }
                    .keyboardShortcut(.defaultAction)
                    .help("container system start, in a terminal tab")
                    .accessibilityIdentifier("docker.apple.startService")
            }
        case .unreadable(let said)?:
            message("Apple's container tool didn't answer", said)
        case .running?:
            switch page.appleTab {
            case .containers: containers
            case .images: images
            case .volumes: volumes
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $page.appleTab) {
                Text(verbatim: "Containers" + count(apple.containers.count, read: true)).tag(AppleContainerModel.Part.containers)
                Text(verbatim: "Images" + count(apple.images.count, read: apple.read.contains(.images))).tag(AppleContainerModel.Part.images)
                Text(verbatim: "Volumes" + count(apple.volumes.count, read: apple.read.contains(.volumes))).tag(AppleContainerModel.Part.volumes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("docker.apple.tab")
            Text(verbatim: status).font(.system(size: ChromeMetrics.text(11.5))).foregroundStyle(theme.text3).lineLimit(1)
            Spacer()
            Button("Pull…") { page.pullAppleImage() }.controlSize(.small).disabled(!isRunning)
            Menu {
                ForEach(DockerPageModel.ApplePrune.allCases, id: \.self) { prune in
                    Button(prune.title) { page.pruneApple(prune) }.disabled(!isRunning)
                }
                Divider()
                Button("Start the Service") { page.startAppleService() }.disabled(isRunning)
                Button("Stop the Service…") { page.stopAppleService() }.disabled(!isRunning)
                Divider()
                Button("Read Again") { apple.refresh() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: ChromeMetrics.text(12)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!apple.isInstalled)
            .accessibilityIdentifier("docker.apple.menu")
        }
    }

    private var isRunning: Bool { if case .running = apple.service { true } else { false } }

    private func count(_ count: Int, read: Bool) -> String { read && isRunning ? " \(count)" : "" }

    private var status: String {
        switch apple.service {
        case .running(let version)?:
            let running = apple.containers.filter { $0.state == .running }.count
            return ["\(running) running", version.map { "container \($0)" }].compactMap { $0 }.joined(separator: " · ")
        case .stopped?: return "Service stopped"
        case .unreadable?: return "Not answering"
        case nil: return apple.isInstalled ? "Reading…" : "Not installed"
        }
    }

    // MARK: Containers

    private var containers: some View {
        let shown = page.appleContainers
        return HStack(spacing: 0) {
            List(selection: $page.appleSelection) {
                ForEach(shown) { container in
                    DockerResourceRow(
                        symbol: container.state == .running ? "shippingbox.fill" : "shippingbox", title: container.id,
                        subtitle: AppleContainers.shortReference(container.image), figures: [container.ports.first?.label ?? "", stateLabel(container)],
                        dim: !container.state.isUp, theme: theme
                    )
                    .opacity(apple.busy.contains(container.id) ? 0.5 : 1)
                    .tag(container.id)
                    .listRowSeparator(.hidden)
                    .contextMenu { ResourceVerbMenu(verbs: page.verbs(for: container)) }
                }
                if shown.isEmpty { emptyLine(apple.containers.isEmpty ? "No containers. container run makes one." : "Nothing matches “\(page.filter)”.") }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("docker.apple.containers")
            if page.showDetail, let container = page.appleDetailed {
                Rectangle().fill(theme.border).frame(width: 1)
                AppleContainerDetail(container: container, session: page.appleSession(for: container), page: page, theme: theme, actions: actions)
                    .id(container.id)
                    .frame(width: 440)
            }
        }
    }

    private func stateLabel(_ container: AppleContainers.Container) -> String {
        guard container.state == .running, let started = container.started else { return container.state.rawValue }
        return "up " + RelativeDateTimeFormatter().localizedString(for: started, relativeTo: Date()).replacingOccurrences(of: " ago", with: "")
    }

    // MARK: Images

    private var images: some View {
        let shown = page.appleImages
        return List(selection: $page.appleImageSelection) {
            ForEach(shown) { image in
                let users = apple.containers(using: image).count
                DockerResourceRow(
                    symbol: "square.stack.3d.down.right", title: image.shortName, subtitle: image.platforms.joined(separator: ", "),
                    figures: [users > 0 ? "\(users) using" : "", image.size.map { DockerBytes.string(Int($0)) } ?? ""],
                    dim: users == 0, theme: theme
                )
                .tag(image.id)
                .listRowSeparator(.hidden)
                .contextMenu { ResourceVerbMenu(verbs: page.verbs(for: image)) }
            }
            if !apple.read.contains(.images) {
                ProgressView().controlSize(.small)
            } else if shown.isEmpty {
                emptyLine(apple.images.isEmpty ? "No images. Pull… gets one." : "Nothing matches “\(page.filter)”.")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("docker.apple.images")
    }

    // MARK: Volumes

    private var volumes: some View {
        let shown = page.appleVolumes
        return List(selection: $page.appleVolumeSelection) {
            ForEach(shown) { volume in
                let users = apple.containers(mounting: volume).map(\.id)
                DockerResourceRow(
                    symbol: "externaldrive", title: volume.name, subtitle: users.isEmpty ? "unused" : "used by " + users.joined(separator: ", "),
                    figures: [volume.format ?? "", volume.sizeBytes.map { "up to " + DockerBytes.string(Int($0)) } ?? ""], dim: users.isEmpty, theme: theme
                )
                .tag(volume.name)
                .listRowSeparator(.hidden)
                .contextMenu { ResourceVerbMenu(verbs: page.verbs(for: volume)) }
            }
            if !apple.read.contains(.volumes) {
                ProgressView().controlSize(.small)
            } else if shown.isEmpty {
                emptyLine(apple.volumes.isEmpty ? "No volumes." : "Nothing matches “\(page.filter)”.")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("docker.apple.volumes")
    }

    // MARK: Pieces

    private func emptyLine(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text3)
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: ChromeMetrics.text(30), weight: .light)).foregroundStyle(theme.text3)
            Text(verbatim: title).font(.system(size: ChromeMetrics.text(15), weight: .semibold)).foregroundStyle(theme.text)
            Text(verbatim: detail).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("docker.apple.message")
    }

    private func banner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TabStatusStyle.failed)
            Text(verbatim: error).font(.system(size: ChromeMetrics.text(12))).foregroundStyle(theme.text).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button("Dismiss") { apple.error = nil }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: ChromeMetrics.text(12)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(TabStatusStyle.failed.opacity(0.1))
        .accessibilityIdentifier("docker.apple.error")
    }
}

/// An Apple container at the side of the list: its verbs, then Overview —
/// what it runs, where it is reached, what it mounts — or its Logs.
private struct AppleContainerDetail: View {
    let container: AppleContainers.Container
    let session: AppleContainerSession
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    DockerStatusDot(color: container.state == .running ? TabStatusStyle.done : theme.text3)
                    Text(verbatim: container.id).font(.system(size: ChromeMetrics.text(15), weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
                ResourceActionBar(verbs: page.verbs(for: container), theme: theme, identifier: "docker.apple.actions")
                Picker("", selection: $page.appleDetailTab) {
                    ForEach(AppleContainerTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("docker.apple.detailTab")
            }
            .padding(16)
            Rectangle().fill(theme.border).frame(height: 1)
            switch page.appleDetailTab {
            case .overview: ScrollView { overview.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
            case .logs:
                LogsPane(
                    feed: session.feed, theme: theme, identifier: "docker.apple", runInTerminal: { [actions] in actions.run($0, nil) },
                    stoppedHelp: "Nothing runs: its log is read again when it starts")
            }
        }
        .accessibilityIdentifier("docker.apple.detail")
    }

    @ViewBuilder private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            DockerDetailBlock(title: "Container", theme: theme) {
                DockerDetailRow(key: "Image", value: container.image, theme: theme)
                DockerDetailRow(key: "State", value: container.state.rawValue, theme: theme)
                if let started = container.started, container.state == .running { DockerDetailRow(key: "Started", value: Self.when(started), theme: theme) }
                if let created = container.created { DockerDetailRow(key: "Created", value: Self.when(created), theme: theme) }
                if let platform = container.platform { DockerDetailRow(key: "Platform", value: platform, theme: theme) }
                if let cpus = container.cpus { DockerDetailRow(key: "CPUs", value: "\(cpus)", theme: theme) }
                if let memory = container.memoryBytes { DockerDetailRow(key: "Memory", value: DockerBytes.string(Int(memory), memory: true), theme: theme) }
            }
            if !container.ports.isEmpty {
                DockerDetailBlock(title: "Ports", theme: theme) {
                    ForEach(Array(container.ports.enumerated()), id: \.offset) { _, port in
                        HStack(spacing: 8) {
                            Text(verbatim: port.label).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                            if let url = port.url, container.state == .running {
                                Button("Open") { actions.open(url) }.buttonStyle(.link).font(.system(size: ChromeMetrics.text(11.5))).help(url.absoluteString)
                            }
                        }
                    }
                }
            }
            if !container.networks.isEmpty {
                DockerDetailBlock(title: "Networks", theme: theme) {
                    ForEach(Array(container.networks.enumerated()), id: \.offset) { _, network in
                        DockerDetailRow(key: network.name, value: [network.address, network.hostname].compactMap { $0 }.joined(separator: " · "), theme: theme)
                    }
                }
            }
            if !container.command.isEmpty {
                DockerDetailBlock(title: "Command", theme: theme) {
                    Text(verbatim: container.command.joined(separator: " ")).font(.system(size: ChromeMetrics.text(11.5), design: .monospaced)).foregroundStyle(theme.text)
                        .textSelection(.enabled)
                    if let folder = container.workingDirectory, !folder.isEmpty { DockerDetailRow(key: "In", value: folder, theme: theme) }
                }
            }
            if !container.mounts.isEmpty {
                DockerDetailBlock(title: "Mounts", theme: theme) {
                    ForEach(Array(container.mounts.enumerated()), id: \.offset) { _, mount in
                        DockerDetailRow(key: mount.destination, value: mount.source, theme: theme)
                    }
                }
            }
            if !container.environment.isEmpty {
                DockerDetailBlock(title: "Environment", theme: theme) {
                    ForEach(Array(container.environment.enumerated()), id: \.offset) { _, pair in
                        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        DockerDetailRow(key: parts.first ?? pair, value: parts.count > 1 ? parts[1] : "", theme: theme)
                    }
                }
            }
            if !container.labels.isEmpty {
                DockerDetailBlock(title: "Labels", theme: theme) {
                    ForEach(container.labels.sorted { $0.key < $1.key }, id: \.key) { DockerDetailRow(key: $0.key, value: $0.value, theme: theme) }
                }
            }
        }
    }

    private static func when(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
