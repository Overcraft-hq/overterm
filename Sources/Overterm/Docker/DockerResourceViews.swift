import SwiftUI

private func bytes(_ count: Int) -> String { DockerBytes.string(count) }

private func ago(_ seconds: Int) -> String {
    RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: TimeInterval(seconds)), relativeTo: Date())
}

/// A key, its value: the details' rows.
struct DockerDetailRow: View {
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

struct DockerDetailBlock<Content: View>: View {
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
struct DockerResourceRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let figures: [String]
    let dim: Bool
    @ObservedObject var theme: ChromeTheme
    /// An image's row: its badge when this engine runs it emulated.
    var imageID: String? = nil
    var docker: DockerModel? = nil
    /// A chip before the figures (an image's `update`), and its help.
    var badge: String? = nil
    var badgeHelp: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(theme.text3).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(dim ? theme.text2 : theme.text).lineLimit(1).truncationMode(.middle)
                    if let imageID, let docker { DockerEmulationBadge(subject: .image(imageID), docker: docker) }
                }
                Text(verbatim: subtitle).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let badge {
                Text(verbatim: badge).font(.system(size: 10)).foregroundStyle(theme.accentText)
                    .padding(.horizontal, 5).background(Capsule().stroke(theme.accentText.opacity(0.5)))
                    .help(badgeHelp ?? "")
            }
            ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                Text(verbatim: figure).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3).lineLimit(1)
            }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

// MARK: Images

/// An image's detail's tabs: what it is, and what Docker Scout found in it.
enum DockerImageTab: String, CaseIterable, Identifiable {
    case overview, vulnerabilities

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct DockerImagesView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var docker: DockerModel
    /// What the registries said: a row's `update`, a detail's Registry.
    @ObservedObject var updates: DockerImageUpdates
    /// What Scout found: a row's `1C 2H`, the detail's Vulnerabilities.
    @ObservedObject var scans: DockerScoutScans
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    @State private var pullName = ""
    @State private var found: [DockerEngine.SearchResult] = []

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
                        found = []
                    }
                    .accessibilityIdentifier("docker.pull")
                    .onChange(of: pullName) { _ in found = [] }
                // Hub is asked only when you ask, never as you type: what is
                // typed may be a private name.
                if DockerPageModel.hubTerm(pullName) != nil {
                    Button {
                        let term = pullName
                        Task {
                            let answer = await page.searchHub(term)
                            // Typed on meanwhile: not this name's.
                            if pullName == term { found = answer }
                        }
                    } label: {
                        Label("Search Docker Hub", systemImage: "magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.accentText)
                    .help("Ask Docker Hub, through the engine, for images named like this")
                    .accessibilityIdentifier("docker.pull.search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.rowHover.opacity(0.6)))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if !found.isEmpty { suggestions }
            ForEach(page.pulls.keys.sorted(), id: \.self) { name in
                if let pull = page.pulls[name] { pullRow(pull) }
            }
            HStack(spacing: 0) {
                List(selection: $page.imageSelection) {
                    ForEach(shown) { image in
                        let users = docker.containers(using: image)
                        DockerResourceRow(
                            symbol: image.isDangling ? "square.dashed" : "square.stack.3d.down.right",
                            title: image.tags.first ?? "<none>",
                            subtitle: [image.shortID, docker.platforms[image.Id]?.description, image.tags.count > 1 ? "+\(image.tags.count - 1) tags" : nil]
                                .compactMap { $0 }.joined(separator: " · "),
                            figures: [scans.scan(for: image.Id)?.state.report?.shortSummary].compactMap { $0 } + [
                                users.isEmpty ? "unused" : "\(users.count) container\(users.count == 1 ? "" : "s")", bytes(image.Size), ago(image.Created),
                            ],
                            dim: users.isEmpty, theme: theme, imageID: image.Id, docker: docker,
                            badge: badge(image).map(\.words), badgeHelp: badge(image)?.help
                        )
                        .tag(image.Id)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            let selected = docker.images.filter { page.imageSelection.contains($0.Id) }
                            DockerVerbMenu(verbs: page.verbs(for: image, targets: page.imageSelection.contains(image.Id) ? selected : nil))
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("docker.images")
                if page.showDetail, page.imageSelection.count == 1, let image = docker.images.first(where: { page.imageSelection.contains($0.Id) }) {
                    Rectangle().fill(theme.border).frame(width: 1)
                    DockerImageDetail(image: image, docker: docker, page: page, updates: updates, scans: scans, theme: theme, actions: actions).id(image.Id)
                        .frame(width: 420)
                }
            }
        }
    }

    /// Docker Hub's images for what is typed: a click pulls one.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(found.prefix(6)) { result in
                Button {
                    page.pull(result.name)
                    pullName = ""
                    found = []
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: result.name).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
                        if result.is_official == true {
                            Text("Official").font(.system(size: 10)).foregroundStyle(theme.accentText)
                                .padding(.horizontal, 5).background(Capsule().stroke(theme.accentText.opacity(0.5)))
                        }
                        Text(verbatim: result.description ?? "").font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: "★ \(result.star_count ?? 0)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
        .accessibilityIdentifier("docker.search")
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
}

extension DockerImagesView {
    /// A row's chip: a newer image in its registry, or another one where
    /// this one may have been built here.
    func badge(_ image: ImageSummary) -> (words: String, help: String)? {
        let states = image.tags.map(updates.state(of:))
        if states.contains(.available) { return ("update", "Its registry has a newer image under this tag — Pull Update pulls it") }
        if states.contains(.differs) {
            return ("differs", "Its registry has another image under this tag. This one was built here, or pulled before it moved on — Pull Again takes the registry's")
        }
        return nil
    }
}

/// An image, at the side of the list: what it is — its registry, who uses
/// it, its layers — or what Docker Scout found in it, a tab each.
private struct DockerImageDetail: View {
    let image: ImageSummary
    @ObservedObject var docker: DockerModel
    @ObservedObject var page: DockerPageModel
    @ObservedObject var updates: DockerImageUpdates
    @ObservedObject var scans: DockerScoutScans
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions
    @State private var layers: [ImageLayer]?

    var body: some View {
        let verbs = page.verbs(for: image)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(verbatim: image.tags.first ?? "<none>").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                        .textSelection(.enabled)
                    DockerEmulationBadge(subject: .image(image.Id), docker: docker)
                }
                DockerActionBar(verbs: verbs, theme: theme)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            tabs
            Rectangle().fill(theme.border).frame(height: 1)
            switch page.imageTab {
            case .overview:
                ScrollView {
                    overview(verbs).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                // Its layers, read while this tab shows.
                .task(id: image.Id) { layers = (try? await docker.engine?.history(of: image.Id)) ?? [] }
            case .vulnerabilities:
                DockerScoutPane(image: image, scans: scans, page: page, theme: theme, actions: actions)
            }
        }
        .accessibilityIdentifier("docker.image.detail")
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(DockerImageTab.allCases) { item in
                Button {
                    page.imageTab = item
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 12, weight: page.imageTab == item ? .semibold : .regular))
                            .foregroundStyle(page.imageTab == item ? theme.text : theme.text2)
                        // The worst of it, once scanned.
                        if item == .vulnerabilities, let report = scans.scan(for: image.Id)?.state.report {
                            let worst = report.count(.critical) + report.count(.high)
                            if worst > 0 {
                                Text(verbatim: "\(worst)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(TabStatusStyle.failed)
                                    .padding(.horizontal, 5).frame(height: 15)
                                    .background(Capsule().fill(TabStatusStyle.failed.opacity(0.14)))
                                    .help("Critical and high")
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(page.imageTab == item ? theme.selected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("docker.image.tab.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func overview(_ verbs: [DockerVerb]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let emulation = docker.emulation(ofImage: image.Id) {
                DockerEmulationNote(
                    emulation: emulation, text: emulation.imageAdvice, verb: verbs.first { $0.title == emulation.imageVerbTitle }, theme: theme)
            }
            DockerDetailBlock(title: "Image", theme: theme) {
                DockerDetailRow(key: "ID", value: image.shortID, theme: theme)
                if let platform = docker.platforms[image.Id] {
                    DockerDetailRow(key: "Platform", value: platform.description + (docker.emulation(ofImage: image.Id) != nil ? " — emulated here" : ""), theme: theme)
                }
                DockerDetailRow(key: "Size", value: bytes(image.Size), theme: theme)
                DockerDetailRow(key: "Created", value: ago(image.Created), theme: theme)
                ForEach(image.tags.dropFirst(), id: \.self) { DockerDetailRow(key: "Also", value: $0, theme: theme) }
            }
            if !image.tags.isEmpty {
                DockerDetailBlock(title: "Registry", theme: theme) {
                    TimelineView(.everyMinute) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(image.tags, id: \.self) { tag in
                                let line = registryLine(tag)
                                DockerDetailRow(key: tag, value: line.words, theme: theme)
                                if let digests = line.digests { DockerDetailRow(key: "", value: digests, theme: theme) }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("docker.image.registry")
            }
            let users = docker.containers(using: image)
            if !users.isEmpty {
                DockerDetailBlock(title: "Used by", theme: theme) {
                    ForEach(users) { DockerDetailRow(key: $0.name, value: DockerStatusStyle.status($0), theme: theme) }
                }
            }
            DockerDetailBlock(title: "Layers", theme: theme) {
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
    }

    static func step(_ createdBy: String) -> String { DockerImageDetailSteps.step(createdBy) }

    /// Where a tag stands with its registry, with its age; then the
    /// digests compared — here, then the registry's — on a row of their own.
    private func registryLine(_ tag: String) -> (words: String, digests: String?) {
        let check = updates.check(of: tag)
        let checked = check.map { " — checked " + UsageFormat.age($0.at) } ?? ""
        let here = DockerImageReference(tag)?.key.flatMap { updates.local[$0] }?.sorted().map(Self.short).joined(separator: ", ") ?? ""
        let there = check?.remote.map { Self.short($0.digest) } ?? ""
        switch updates.state(of: tag) {
        case .local:
            return (updates.isBuilt(tag) ? "Its project's files build it: no registry to ask." : "Built or tagged here: no registry to ask.", nil)
        case .unchecked: return ("Not checked — Check for Updates asks its registry.", nil)
        case .checking: return ("Checking…", nil)
        case .current: return ("Up to date\(checked).", there)
        case .available: return ("Newer in its registry\(checked). Pull Update replaces this one.", "\(here) → \(there)")
        case .differs:
            return (
                "Its registry has another image under this name\(checked). This one was built here, or pulled before it moved on — this image store doesn't say which; Pull Again takes the registry's.",
                "\(here) ≠ \(there)"
            )
        case .notInRegistry(let why): return ("Not in its registry\(checked) — built or tagged here. \(why)", nil)
        case .failed(let why): return ("Couldn't check\(checked): \(why)", nil)
        }
    }

    /// `sha256:4c0f…` → `4c0f1a2b3c4d`.
    private static func short(_ digest: String) -> String {
        String((digest.split(separator: ":").last.map(String.init) ?? digest).prefix(12))
    }
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
                    DockerResourceRow(
                        symbol: volume.isAnonymous ? "externaldrive.badge.questionmark" : "externaldrive",
                        title: volume.shortName,
                        subtitle: [volume.isAnonymous ? "anonymous" : nil, volume.composeProject.map { "compose: \($0)" }, volume.Driver]
                            .compactMap { $0 }.joined(separator: " · "),
                        figures: [users.isEmpty ? "unused" : users.map(\.name).joined(separator: ", "), volume.UsageData.map { bytes($0.Size) } ?? "—"],
                        dim: users.isEmpty, theme: theme
                    )
                    .tag(volume.Name)
                    .listRowSeparator(.hidden)
                    .contextMenu { DockerVerbMenu(verbs: page.verbs(for: volume)) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("docker.volumes")
            .contextMenu { Button("Import Into a New Volume…") { page.importVolumeAsking() } }
            if page.showDetail, page.volumeSelection.count == 1, let volume = docker.volumes.first(where: { page.volumeSelection.contains($0.Name) }) {
                Rectangle().fill(theme.border).frame(width: 1)
                DockerVolumeDetail(volume: volume, docker: docker, page: page, theme: theme, actions: actions)
                    .id(volume.Name)
                    .frame(width: 420)
                    .accessibilityIdentifier("docker.volume.detail")
            }
        }
    }
}

/// A volume, at the side of the list: what it is and what mounts it, or
/// its files (`VolumeFilesPane`) — a tab each, as a container's detail.
private struct DockerVolumeDetail: View {
    let volume: VolumeSummary
    @ObservedObject var docker: DockerModel
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: volume.shortName).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                DockerActionBar(verbs: page.verbs(for: volume), theme: theme)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            tabs
            Rectangle().fill(theme.border).frame(height: 1)
            switch page.volumeTab {
            case .overview:
                ScrollView {
                    overview.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .files:
                // Made as the tab shows (`updateVolumeFiles`), a turn later.
                if let session = page.volumeFiles, session.volume == volume.Name {
                    VolumeFilesPane(volume: volume, session: session, docker: docker, theme: theme, actions: actions)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(VolumeTab.allCases) { item in
                Button {
                    page.volumeTab = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: page.volumeTab == item ? .semibold : .regular))
                        .foregroundStyle(page.volumeTab == item ? theme.text : theme.text2)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(page.volumeTab == item ? theme.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("docker.volume.tab.\(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            DockerDetailBlock(title: "Volume", theme: theme) {
                DockerDetailRow(key: "Name", value: volume.Name, theme: theme)
                DockerDetailRow(key: "Driver", value: volume.Driver, theme: theme)
                DockerDetailRow(key: "Size", value: volume.UsageData.map { bytes($0.Size) } ?? "—", theme: theme)
                DockerDetailRow(key: "In the VM at", value: volume.Mountpoint, theme: theme)
                if let created = volume.CreatedAt { DockerDetailRow(key: "Created", value: ContainerDetailView.date(created), theme: theme) }
            }
            let users = docker.containers(mounting: volume)
            DockerDetailBlock(title: "Mounted by", theme: theme) {
                if users.isEmpty { Text("Nothing").font(.system(size: 11.5)).foregroundStyle(theme.text3) }
                ForEach(users) { container in
                    let at = (container.Mounts ?? []).first { $0.Name == volume.Name }?.Destination ?? ""
                    DockerDetailRow(key: container.name, value: at, theme: theme)
                }
            }
            let labels = (volume.Labels ?? [:]).filter { !$0.key.hasPrefix("com.docker.compose.") }
            if !labels.isEmpty {
                DockerDetailBlock(title: "Labels", theme: theme) { ForEach(labels.keys.sorted(), id: \.self) { DockerDetailRow(key: $0, value: labels[$0] ?? "", theme: theme) } }
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
                    DockerResourceRow(
                        symbol: network.isBuiltIn ? "lock" : "point.3.filled.connected.trianglepath.dotted", title: network.Name,
                        subtitle: [network.Driver, network.Scope, network.isBuiltIn ? "Docker's own" : nil].compactMap { $0 }.joined(separator: " · "),
                        figures: [members.isEmpty ? "empty" : "\(members.count) container\(members.count == 1 ? "" : "s")", network.subnet ?? ""],
                        dim: members.isEmpty, theme: theme
                    )
                    .tag(network.Id)
                    .listRowSeparator(.hidden)
                    .contextMenu { DockerVerbMenu(verbs: page.verbs(for: network)) }
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
                        DockerActionBar(verbs: page.verbs(for: network), theme: theme)
                        DockerDetailBlock(title: "Network", theme: theme) {
                            DockerDetailRow(key: "Driver", value: network.Driver ?? "", theme: theme)
                            DockerDetailRow(key: "Subnet", value: network.subnet ?? "—", theme: theme)
                            DockerDetailRow(key: "Gateway", value: network.IPAM?.Config?.first?.Gateway ?? "—", theme: theme)
                            if network.Internal == true { DockerDetailRow(key: "Internal", value: "no way out", theme: theme) }
                        }
                        DockerDetailBlock(title: "On it", theme: theme) {
                            let members = docker.containers(on: network)
                            if members.isEmpty { Text("Nothing").font(.system(size: 11.5)).foregroundStyle(theme.text3) }
                            ForEach(members) { container in
                                let address =
                                    network.Containers?[container.Id]?.IPv4Address ?? container.NetworkSettings?.Networks?[network.Name]?.IPAddress ?? ""
                                HStack(spacing: 6) {
                                    DockerDetailRow(key: container.name, value: address, theme: theme)
                                    if network.Name != "host", network.Name != "none" {
                                        Button("Disconnect") { page.disconnect(container, from: network) }
                                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(theme.accentText)
                                            .help("Take \(container.name) off \(network.Name)")
                                    }
                                }
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

// MARK: Testcontainers

/// A Testcontainers run, beside the list: what made it and when, its
/// reaper, its containers a click each, and its verbs. It reads nothing:
/// all of it is the list's.
struct TestcontainersSessionView: View {
    let session: TestcontainersSession
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    private var library: String? {
        session.lang.map { lang in [lang, session.version].compactMap { $0 }.joined(separator: " ") }
    }

    private var subtitle: String {
        [
            library, session.id.isEmpty ? "kept for reuse" : "session " + session.shortID, "started " + UsageFormat.age(session.startedDate),
            "\(session.running) of \(session.members.count) running",
        ]
        .compactMap { $0 }.joined(separator: "  —  ")
    }

    private var reaper: String {
        // Its name is the session again: its image says more.
        if let reaper = session.reaper { return "\(reaper.Image), \(DockerStatusStyle.status(reaper))" }
        return session.id.isEmpty ? "none — kept for reuse, they outlive their runs" : "none — nothing removes these but you"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        DockerStatusDot(color: DockerStatusStyle.color(session, idle: theme.text3))
                        Text("Testcontainers").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text)
                    }
                    // Its age once a minute, only while it shows.
                    TimelineView(.everyMinute) { _ in
                        Text(verbatim: subtitle).font(.system(size: 11.5)).foregroundStyle(theme.text3).lineLimit(2)
                    }
                }
                DockerActionBar(verbs: page.verbs(for: session), theme: theme)
                DockerDetailBlock(title: "Run", theme: theme) {
                    DockerDetailRow(key: "Session", value: session.id.isEmpty ? "none — kept for reuse" : session.id, theme: theme)
                    DockerDetailRow(key: "Library", value: library ?? "—", theme: theme)
                    TimelineView(.everyMinute) { _ in
                        DockerDetailRow(
                            key: "Started",
                            value: UsageFormat.age(session.startedDate) + ", " + session.startedDate.formatted(date: .abbreviated, time: .shortened),
                            theme: theme)
                    }
                    DockerDetailRow(key: "Reaper", value: reaper, theme: theme)
                }
                DockerDetailBlock(title: "Containers", theme: theme) {
                    ForEach(session.containers) { container in
                        Button {
                            page.collapsed.remove(DockerPageModel.sessionTag(session.id))
                            page.selection = [container.Id]
                        } label: {
                            DockerContainerRow(
                                container: container, inProject: true, busy: page.busy.contains(container.Id), docker: page.docker, theme: theme,
                                open: actions.open, remoteHost: page.docker.publishedHost, indented: false)
                        }
                        .buttonStyle(.plain)
                        .help("Show \(container.name)")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("docker.testcontainers.detail")
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

/// Docker Model Runner's models: what is pulled, what is loaded, what they
/// take; a chat with one in a terminal tab (`n`), a pull, a removal asked
/// first (⌫), the OpenAI endpoint to give a program.
struct DockerModelsView: View {
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(theme.border).frame(height: 1)
            if let contents = page.models {
                HStack(spacing: 0) {
                    list(contents)
                    if page.showDetail, page.modelSelection.count == 1, let model = contents.models.first(where: { page.modelSelection.contains($0.id) }) {
                        Rectangle().fill(theme.border).frame(width: 1)
                        DockerModelDetail(model: model, loaded: contents.running.first { $0.runs(model) }, page: page, theme: theme).id(model.id).frame(width: 420)
                    }
                }
            } else {
                absent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { page.loadModels() }
    }

    private func list(_ contents: ModelRunner.Contents) -> some View {
        List(selection: $page.modelSelection) {
            ForEach(contents.models) { model in
                let loaded = contents.running.first { $0.runs(model) }
                DockerResourceRow(
                    symbol: loaded == nil ? "cpu" : "bolt.fill", title: model.name,
                    subtitle: model.summary.isEmpty ? model.shortID : model.summary,
                    figures: [
                        loaded.map { "loaded · \($0.backend_name)" } ?? "",
                        RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: TimeInterval(model.created)), relativeTo: Date()),
                    ],
                    dim: false, theme: theme
                )
                .tag(model.id)
                .listRowSeparator(.hidden)
                .contextMenu { DockerVerbMenu(verbs: page.verbs(for: model)) }
            }
            if contents.models.isEmpty { Text("No models pulled yet.").font(.system(size: 12)).foregroundStyle(theme.text3) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("docker.models")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(verbatim: status).font(.system(size: 11.5)).foregroundStyle(theme.text2).lineLimit(1)
            Spacer()
            if let endpoints = page.modelsPlace.flatMap(ModelRunner.endpoints), page.models != nil {
                Menu("Endpoint") {
                    Button("Copy for a Container — \(endpoints.containers)") { actions.copy(endpoints.containers) }
                    if let mac = endpoints.mac { Button("Copy for This Mac — \(mac)") { actions.copy(mac) } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("The OpenAI-compatible API: point a program's base URL here")
            }
            Button("Pull…") { page.pullModel() }.controlSize(.small).disabled(page.models == nil)
            Button {
                page.loadModels()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Read again")
        }
    }

    private var status: String {
        if let error = page.modelsError { return error }
        guard let contents = page.models else { return "Docker Model Runner" }
        let size = contents.usage.map { " · \(DockerBytes.string(Int($0.models_disk_usage))) on disk" } ?? ""
        let loaded = contents.running.isEmpty ? "" : " · \(contents.running.count) loaded"
        return "\(contents.models.count) \(contents.models.count == 1 ? "model" : "models")\(loaded)\(size)"
    }

    /// Why there is no list, and what would make one.
    @ViewBuilder private var absent: some View {
        VStack(spacing: 10) {
            switch page.modelsPlace {
            case .desktop:
                Text("Docker Desktop's Model Runner is off.").foregroundStyle(theme.text2)
                Button("Enable Model Runner") { page.startModelRunner() }.help("docker desktop enable model-runner, in a terminal tab")
            case .stopped(_, let name):
                Text(verbatim: "Model Runner's container, \(name), is stopped.").foregroundStyle(theme.text2)
                Button("Start It") { page.startModelRunner() }
            case .absent(let command?):
                Text("This engine has no Model Runner.").foregroundStyle(theme.text2)
                Button("Install Model Runner") { page.startModelRunner() }.help("\(command), in a terminal tab — it pulls the runner's image")
            case .remote:
                Text("A remote engine's Model Runner isn't read from this Mac.").foregroundStyle(theme.text2)
            case .absent(nil), .container, nil:
                Text("Model Runner isn't answering.").foregroundStyle(theme.text2)
            }
        }
        .font(.system(size: 12))
        .padding(20)
    }
}

/// A model, at the side of the list: what it is, whether it is loaded,
/// and its verbs.
private struct DockerModelDetail: View {
    let model: RunnerModel
    let loaded: RunningModel?
    @ObservedObject var page: DockerPageModel
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: model.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).textSelection(.enabled)
                DockerActionBar(verbs: page.verbs(for: model), theme: theme)
                DockerDetailBlock(title: "Model", theme: theme) {
                    DockerDetailRow(key: "Name", value: model.reference, theme: theme)
                    DockerDetailRow(key: "ID", value: model.shortID, theme: theme)
                    if let parameters = model.config?.parameters { DockerDetailRow(key: "Parameters", value: parameters, theme: theme) }
                    if let quantization = model.config?.quantization { DockerDetailRow(key: "Quantization", value: quantization, theme: theme) }
                    if let size = model.config?.size { DockerDetailRow(key: "Size", value: size, theme: theme) }
                    if let architecture = model.config?.architecture { DockerDetailRow(key: "Architecture", value: architecture, theme: theme) }
                    if let format = model.config?.format { DockerDetailRow(key: "Format", value: format, theme: theme) }
                    if let context = model.config?.context_size { DockerDetailRow(key: "Context", value: "\(context) tokens", theme: theme) }
                    DockerDetailRow(key: "Pulled", value: ago(model.created), theme: theme)
                }
                DockerDetailBlock(title: "Loaded", theme: theme) {
                    if let loaded {
                        DockerDetailRow(key: "Backend", value: loaded.backend_name, theme: theme)
                        if let mode = loaded.mode { DockerDetailRow(key: "Mode", value: mode, theme: theme) }
                    } else {
                        Text("Not in memory: the first request loads it.").font(.system(size: 11.5)).foregroundStyle(theme.text3)
                    }
                }
                if let tags = model.tags, tags.count > 1 {
                    DockerDetailBlock(title: "Also", theme: theme) { ForEach(tags.dropFirst(), id: \.self) { DockerDetailRow(key: "Tag", value: $0, theme: theme) } }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("docker.model.detail")
    }
}
