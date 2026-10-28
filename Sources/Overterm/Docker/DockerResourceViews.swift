import SwiftUI

private func bytes(_ count: Int) -> String { DockerBytes.string(count) }

private func ago(_ seconds: Int) -> String {
    RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: TimeInterval(seconds)), relativeTo: Date())
}

/// A key, its value: the details' rows.
private struct DetailRow: View {
    let key: String
    let value: String
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: key).font(.system(size: 11.5)).foregroundStyle(theme.text2).frame(width: 110, alignment: .leading).lineLimit(1)
            Text(verbatim: value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(theme.text).textSelection(.enabled)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailBlock<Content: View>: View {
    let title: String
    @ObservedObject var theme: ChromeTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            content
        }
    }
}

/// A row of a resource list: a glyph, a name, what is under it, figures on the right.
private struct ResourceRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let figures: [String]
    let dim: Bool
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(dim ? theme.text2 : theme.text).lineLimit(1).truncationMode(.middle)
                Text(verbatim: subtitle).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                Text(verbatim: figure).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1)
            }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

// MARK: Images

struct DockerImagesView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    @State private var pullName = ""

    private var shown: [ImageSummary] {
        let words = page.filter.lowercased().split(separator: " ").map(String.init)
        return docker.images.filter { image in
            let text = (image.tags.joined(separator: " ") + " " + image.Id).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(theme.text3)
                TextField("Pull an image — postgres:16, ghcr.io/owner/app:tag", text: $pullName)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit {
                        page.pull(pullName)
                        pullName = ""
                    }
                    .accessibilityIdentifier("docker.pull")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.6)))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ForEach(page.pulls.keys.sorted(), id: \.self) { name in
                if let pull = page.pulls[name] { pullRow(pull) }
            }
            HStack(spacing: 0) {
                List(selection: $page.imageSelection) {
                    ForEach(shown) { image in
                        let users = docker.containers(using: image)
                        ResourceRow(
                            symbol: image.isDangling ? "square.dashed" : "square.stack.3d.down.right",
                            title: image.tags.first ?? "<none>", subtitle: image.shortID + (image.tags.count > 1 ? " · +\(image.tags.count - 1) tags" : ""),
                            figures: [users.isEmpty ? "unused" : "\(users.count) container\(users.count == 1 ? "" : "s")", bytes(image.Size), ago(image.Created)],
                            dim: users.isEmpty, theme: theme
                        )
                        .tag(image.Id)
                        .listRowSeparator(.hidden)
                        .contextMenu { menu(image) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("docker.images")
                if page.showDetail, page.imageSelection.count == 1, let image = docker.images.first(where: { page.imageSelection.contains($0.Id) }) {
                    Rectangle().fill(theme.border).frame(width: 1)
                    DockerImageDetail(image: image, docker: docker, page: page, theme: theme, actions: actions).id(image.Id).frame(width: 420)
                }
            }
        }
    }

    private func pullRow(_ pull: DockerPull) -> some View {
        HStack(spacing: 8) {
            if pull.done {
                Image(systemName: pull.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(pull.error == nil ? TabStatusStyle.done : TabStatusStyle.failed)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(verbatim: pull.image).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
            Text(verbatim: pull.summary).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(2).textSelection(.enabled)
            Spacer()
            if pull.done { Button("Dismiss") { page.dismissPull(pull.image) }.buttonStyle(.plain).foregroundStyle(theme.accentText).font(.system(size: 11.5)) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .accessibilityIdentifier("docker.pull.\(pull.image)")
    }

    @ViewBuilder private func menu(_ image: ImageSummary) -> some View {
        if let name = image.tags.first {
            Button("Run…") { page.runSpec = DockerRunSpec(image: name) }
            Button("Pull Again") { page.pull(name) }
            Button("Run in a Tab") { actions.run(DockerCommands.prefix(for: docker.endpoint) + "docker run --rm -it \(DockerCommands.quote(name))", nil) }
            Divider()
            Button("Copy Name") { actions.copy(name) }
        }
        Button("Copy ID") { actions.copy(image.Id) }
        Button("Save as tar…") { actions.pickSave("\((image.tags.first ?? image.shortID).replacingOccurrences(of: "/", with: "_")).tar") { page.saveImage(image, to: $0) } }
        Divider()
        Button("Remove…") { page.confirmRemove(images: page.imageSelection.contains(image.Id) ? docker.images.filter { page.imageSelection.contains($0.Id) } : [image]) }
            .disabled(docker.containers(using: image).contains { $0.state.isUp })
    }
}

private struct DockerImageDetail: View {
    let image: ImageSummary
    @ObservedObject var docker: DockerModel
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    @State private var layers: [ImageLayer]?
    @State private var tagName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: image.tags.first ?? "<none>").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                DetailBlock(title: "Image", theme: theme) {
                    DetailRow(key: "ID", value: image.shortID, theme: theme)
                    DetailRow(key: "Size", value: bytes(image.Size), theme: theme)
                    DetailRow(key: "Created", value: ago(image.Created), theme: theme)
                    ForEach(image.tags.dropFirst(), id: \.self) { DetailRow(key: "Also", value: $0, theme: theme) }
                }
                let users = docker.containers(using: image)
                if !users.isEmpty {
                    DetailBlock(title: "Used by", theme: theme) {
                        ForEach(users) { DetailRow(key: $0.name, value: DockerStatusStyle.status($0), theme: theme) }
                    }
                }
                DetailBlock(title: "Tag", theme: theme) {
                    TextField("repository:tag", text: $tagName).textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit {
                            page.tag(image, as: tagName)
                            tagName = ""
                        }
                }
                DetailBlock(title: "Layers", theme: theme) {
                    if let layers {
                        ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: bytes(layer.Size)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                                    .frame(width: 70, alignment: .trailing)
                                Text(verbatim: Self.step(layer.CreatedBy)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text)
                                    .lineLimit(2).textSelection(.enabled)
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: image.Id) { layers = (try? await docker.engine?.history(of: image.Id)) ?? [] }
        .accessibilityIdentifier("docker.image.detail")
    }

    static func step(_ createdBy: String) -> String { DockerImageDetailSteps.step(createdBy) }
}

/// A layer's command as a Dockerfile says it. Pure.
enum DockerImageDetailSteps {
    /// `/bin/sh -c #(nop)  CMD ["nginx"]` → `CMD ["nginx"]`; a classic
    /// builder's `/bin/sh -c …` → `RUN …`; BuildKit's own lines as they are.
    static func step(_ createdBy: String) -> String {
        var text = createdBy.replacingOccurrences(of: "/bin/sh -c #(nop) ", with: "").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/bin/sh -c ") { text = "RUN " + text.dropFirst("/bin/sh -c ".count) }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

// MARK: Volumes

struct DockerVolumesView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    private var shown: [VolumeSummary] {
        let words = page.filter.lowercased().split(separator: " ").map(String.init)
        return docker.volumes.filter { volume in
            let text = (volume.Name + " " + (volume.composeProject ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page.volumeSelection) {
                ForEach(shown) { volume in
                    let users = docker.containers(mounting: volume)
                    ResourceRow(
                        symbol: volume.isAnonymous ? "externaldrive.badge.questionmark" : "externaldrive",
                        title: volume.shortName,
                        subtitle: [volume.isAnonymous ? "anonymous" : nil, volume.composeProject.map { "compose: \($0)" }, volume.Driver]
                            .compactMap { $0 }.joined(separator: " · "),
                        figures: [users.isEmpty ? "unused" : users.map(\.name).joined(separator: ", "), volume.UsageData.map { bytes($0.Size) } ?? "—"],
                        dim: users.isEmpty, theme: theme
                    )
                    .tag(volume.Name)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button("Browse in a Tab") {
                            actions.run(
                                DockerCommands.prefix(for: docker.endpoint)
                                    + "docker run --rm -it -v \(DockerCommands.quote(volume.Name)):/volume -w /volume alpine sh", nil)
                        }
                        Button("Copy Name") { actions.copy(volume.Name) }
                        Divider()
                        Button("Export…") { actions.pickSave("\(volume.shortName).tar") { page.exportVolume(volume, to: $0) } }
                        Button("Clone…") {
                            actions.askName("Clone “\(volume.shortName)”", "A new volume with the same files.", volume.shortName + "-copy") {
                                page.cloneVolume(volume, as: $0)
                            }
                        }
                        Button("Import Into a New Volume…") { importVolume() }
                        Divider()
                        Button("Remove…") { page.confirmRemove(volumes: [volume]) }.disabled(!users.isEmpty)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("docker.volumes")
            .contextMenu { Button("Import Into a New Volume…") { importVolume() } }
            if page.showDetail, page.volumeSelection.count == 1, let volume = docker.volumes.first(where: { page.volumeSelection.contains($0.Name) }) {
                Rectangle().fill(theme.border).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: volume.shortName).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        DetailBlock(title: "Volume", theme: theme) {
                            DetailRow(key: "Name", value: volume.Name, theme: theme)
                            DetailRow(key: "Driver", value: volume.Driver, theme: theme)
                            DetailRow(key: "Size", value: volume.UsageData.map { bytes($0.Size) } ?? "—", theme: theme)
                            DetailRow(key: "In the VM at", value: volume.Mountpoint, theme: theme)
                            if let created = volume.CreatedAt { DetailRow(key: "Created", value: ContainerDetailView.date(created), theme: theme) }
                        }
                        let users = docker.containers(mounting: volume)
                        DetailBlock(title: "Mounted by", theme: theme) {
                            if users.isEmpty { Text("Nothing").font(.system(size: 11.5)).foregroundStyle(theme.text3) }
                            ForEach(users) { container in
                                let at = (container.Mounts ?? []).first { $0.Name == volume.Name }?.Destination ?? ""
                                DetailRow(key: container.name, value: at, theme: theme)
                            }
                        }
                        let labels = (volume.Labels ?? [:]).filter { !$0.key.hasPrefix("com.docker.compose.") }
                        if !labels.isEmpty {
                            DetailBlock(title: "Labels", theme: theme) { ForEach(labels.keys.sorted(), id: \.self) { DetailRow(key: $0, value: labels[$0] ?? "", theme: theme) } }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(volume.Name)
                .frame(width: 420)
                .accessibilityIdentifier("docker.volume.detail")
            }
        }
    }
}

extension DockerVolumesView {
    /// A tar an export wrote, into a volume made for it.
    func importVolume() {
        actions.pickOpen { file in
            actions.askName("Import “\(file.lastPathComponent)”", "Into a new volume called:", file.deletingPathExtension().lastPathComponent) {
                page.importVolume($0, from: file)
            }
        }
    }
}

// MARK: Networks

struct DockerNetworksView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    private var shown: [NetworkSummary] {
        let words = page.filter.lowercased().split(separator: " ").map(String.init)
        return docker.networks.filter { network in words.allSatisfy { (network.Name + " " + (network.Driver ?? "")).lowercased().contains($0) } }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $page.networkSelection) {
                ForEach(shown) { network in
                    let members = docker.containers(on: network)
                    ResourceRow(
                        symbol: network.isBuiltIn ? "lock" : "point.3.filled.connected.trianglepath.dotted", title: network.Name,
                        subtitle: [network.Driver, network.Scope, network.isBuiltIn ? "Docker's own" : nil].compactMap { $0 }.joined(separator: " · "),
                        figures: [members.isEmpty ? "empty" : "\(members.count) container\(members.count == 1 ? "" : "s")", network.subnet ?? ""],
                        dim: members.isEmpty, theme: theme
                    )
                    .tag(network.Id)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button("Copy Name") { actions.copy(network.Name) }
                        Divider()
                        Button("Remove…") { page.confirmRemove(networks: [network]) }.disabled(network.isBuiltIn || !members.isEmpty)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("docker.networks")
            if page.showDetail, page.networkSelection.count == 1, let network = docker.networks.first(where: { page.networkSelection.contains($0.Id) }) {
                Rectangle().fill(theme.border).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: network.Name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                        DetailBlock(title: "Network", theme: theme) {
                            DetailRow(key: "Driver", value: network.Driver ?? "", theme: theme)
                            DetailRow(key: "Subnet", value: network.subnet ?? "—", theme: theme)
                            DetailRow(key: "Gateway", value: network.IPAM?.Config?.first?.Gateway ?? "—", theme: theme)
                            if network.Internal == true { DetailRow(key: "Internal", value: "no way out", theme: theme) }
                        }
                        DetailBlock(title: "On it", theme: theme) {
                            let members = docker.containers(on: network)
                            if members.isEmpty { Text("Nothing").font(.system(size: 11.5)).foregroundStyle(theme.text3) }
                            ForEach(members) { container in
                                let address =
                                    network.Containers?[container.Id]?.IPv4Address ?? container.NetworkSettings?.Networks?[network.Name]?.IPAddress ?? ""
                                DetailRow(key: container.name, value: address, theme: theme)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(network.Id)
                .frame(width: 420)
                .accessibilityIdentifier("docker.network.detail")
            }
        }
    }
}

// MARK: Clean Up

/// What Clean Up would remove, chosen and listed before anything goes.
struct DockerCleanUpSheet: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        let plan = page.cleanPlan
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean Up").font(.system(size: 17, weight: .semibold))
            Text("What nothing uses. Listed here first; nothing goes until you say so.").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                choice($page.cleanChoice.containers, "Stopped containers", plan.containers.map(\.name), size: nil)
                choice($page.cleanChoice.images, "Unused images", plan.images.map { $0.tags.first ?? "<none> \($0.shortID)" }, size: plan.images.reduce(0) { $0 + $1.Size }) {
                    Toggle("Tagged ones too, not only <none>", isOn: $page.cleanChoice.allImages).font(.system(size: 11.5))
                }
                choice(
                    $page.cleanChoice.volumes, "Unused volumes", plan.volumes.map(\.shortName), size: plan.volumes.reduce(0) { $0 + ($1.UsageData?.Size ?? 0) }
                ) {
                    Toggle("Named ones too — their data is deleted", isOn: $page.cleanChoice.namedVolumes).font(.system(size: 11.5))
                }
                choice($page.cleanChoice.networks, "Unused networks", plan.networks.map(\.Name), size: nil)
                choice($page.cleanChoice.buildCache, "Build cache not in use", [], size: plan.buildCache)
            }
            Divider()
            HStack {
                Text(verbatim: "Up to \(bytes(plan.reclaimable)) freed").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Cancel") { page.cleaning = false }.keyboardShortcut(.cancelAction)
                Button("Clean Up") { page.cleanUp() }.keyboardShortcut(.defaultAction).disabled(plan.isEmpty)
                    .accessibilityIdentifier("docker.cleanUp.go")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { page.prepareCleanUp() }
    }

    private func choice(_ on: Binding<Bool>, _ title: String, _ names: [String], size: Int?) -> some View {
        choice(on, title, names, size: size) { EmptyView() }
    }

    private func choice<Extra: View>(_ on: Binding<Bool>, _ title: String, _ names: [String], size: Int?, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: on) { Text(title).font(.system(size: 12.5, weight: .medium)) }
                Spacer()
                Text(verbatim: on.wrappedValue ? (names.isEmpty && size != nil ? "" : "\(names.count)") + (size.map { $0 > 0 ? "  \(bytes($0))" : "" } ?? "") : "")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            if on.wrappedValue {
                extra().padding(.leading, 20)
                if !names.isEmpty {
                    Text(verbatim: names.prefix(8).joined(separator: ", ") + (names.count > 8 ? " and \(names.count - 8) more" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 20).lineLimit(3)
                }
            }
        }
    }
}

/// What Docker takes on the disk, under the sections.
struct DockerDiskSummary: View {
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        if let usage = docker.diskUsage {
            VStack(alignment: .leading, spacing: 3) {
                Text("On disk").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
                line("Images", usage.LayersSize ?? 0)
                line("Volumes", (usage.Volumes ?? []).reduce(0) { $0 + ($1.UsageData?.Size ?? 0) })
                line("Build cache", (usage.BuildCache ?? []).reduce(0) { $0 + $1.Size })
            }
            .padding(.horizontal, 10)
            .accessibilityIdentifier("docker.disk")
        }
    }

    private func line(_ title: String, _ size: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(theme.text2)
            Spacer()
            Text(verbatim: bytes(size)).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text2)
        }
    }
}

// MARK: Run

/// The Run window: an image in a new container, the command written out
/// as it is filled in, run in a terminal tab.
struct DockerRunSheet: View {
    @State var spec: DockerRunSpec
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    let actions: DockerActions
    @State private var ports = ""
    @State private var env = ""
    @State private var volumes = ""

    private var built: DockerRunSpec {
        var spec = spec
        spec.ports = DockerRunSpec.lines(ports)
        spec.env = DockerRunSpec.lines(env)
        spec.volumes = DockerRunSpec.lines(volumes)
        return spec
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run").font(.system(size: 17, weight: .semibold))
            Form {
                TextField("Image", text: $spec.image, prompt: Text("postgres:16"))
                TextField("Name", text: $spec.name, prompt: Text("optional"))
                field("Ports", $ports, "8080:80 — one a line")
                field("Environment", $env, "KEY=value — one a line")
                field("Volumes", $volumes, "name:/data or /host/path:/in — one a line")
                TextField("Command", text: $spec.command, prompt: Text("the image's own"))
                Picker("Restart", selection: $spec.restart) {
                    Text("No").tag("")
                    Text("Always").tag("always")
                    Text("Unless stopped").tag("unless-stopped")
                    Text("On failure").tag("on-failure")
                }
                Toggle("In the background", isOn: $spec.detached)
                Toggle("Remove it when it stops", isOn: $spec.removeWhenStopped)
            }
            Text(verbatim: built.line(prefix: DockerCommands.prefix(for: docker.endpoint)))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("docker.run.command")
            HStack {
                Button("Copy") { actions.copy(built.line(prefix: DockerCommands.prefix(for: docker.endpoint))) }
                Spacer()
                Button("Cancel") { page.runSpec = nil }.keyboardShortcut(.cancelAction)
                Button("Run in a Tab") { page.run(built) }.keyboardShortcut(.defaultAction).disabled(spec.image.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            ports = spec.ports.joined(separator: "\n")
            env = spec.env.joined(separator: "\n")
            volumes = spec.volumes.joined(separator: "\n")
        }
    }

    private func field(_ title: String, _ text: Binding<String>, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12))
            TextEditor(text: text).font(.system(size: 12, design: .monospaced)).frame(height: 44)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty { Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary).padding(4).allowsHitTesting(false) }
                }
        }
    }
}
