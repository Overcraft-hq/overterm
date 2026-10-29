import SwiftUI

/// A container's or a project's state as one colour, in the tabs' status
/// vocabulary: green running, orange on its way (paused, starting,
/// restarting, created), red wrong (exited non-zero, unhealthy, dead),
/// the theme's grey stopped.
enum DockerStatusStyle {
    static func color(_ container: ContainerSummary, idle: Color) -> Color {
        if container.health == "unhealthy" || container.state == .dead || (container.exitCode ?? 0) != 0 { return TabStatusStyle.failed }
        switch container.state {
        case .running: return container.health == "starting" ? TabStatusStyle.waiting : TabStatusStyle.done
        case .paused, .restarting, .created, .removing: return TabStatusStyle.waiting
        default: return idle
        }
    }

    static func color(_ project: ComposeProject, idle: Color) -> Color {
        if !project.failing.isEmpty { return TabStatusStyle.failed }
        switch project.status {
        case .running: return TabStatusStyle.done
        case .partial: return TabStatusStyle.waiting
        case .stopped: return idle
        }
    }

    /// What the row says of it: Docker's own words, less what the dot and
    /// the health already say.
    static func status(_ container: ContainerSummary) -> String {
        container.Status.replacingOccurrences(of: #"\s*\((healthy|unhealthy|health: starting|Paused)\)"#, with: "", options: .regularExpression)
    }
}

struct DockerStatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// A published port, a click from the browser.
struct DockerPortPill: View {
    let port: PublishedPort
    @ObservedObject var theme: ChromeTheme
    let open: (URL) -> Void

    var body: some View {
        Button {
            if let url = port.url { open(url) }
        } label: {
            Text(verbatim: port.label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.text2)
                .padding(.horizontal, 5)
                .frame(height: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(theme.rowHover))
        }
        .buttonStyle(.plain)
        .help(port.url.map { "Open \($0.absoluteString)" } ?? port.label)
    }
}

/// Whether the Docker view it is in is on screen. The page's overlay is
/// hidden, not removed, and the sidebar's panel stays while the sidebar is
/// collapsed: their views live on, and what one reads for itself (an
/// image's platform) asks only while this says so. Each host sets it — the
/// page, the panel, the right-hand pane; anywhere else nothing shows.
private struct DockerShownKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dockerShown: Bool {
        get { self[DockerShownKey.self] }
        set { self[DockerShownKey.self] = newValue }
    }
}

/// What a container runs, or an image is built for, when this engine runs
/// it emulated: a small orange `amd64`. Showing it is what asks for the
/// platform (`DockerModel.wantPlatform`), so only what is on screen is
/// read (`dockerShown`); an image's asks again after an image event (the
/// key's epoch), a container's only until it is known for good. Nothing
/// when it runs natively — a view of no size, not an EmptyView, whose task
/// may not run.
struct DockerEmulationBadge: View {
    enum Subject {
        case container(ContainerSummary)
        /// By its id.
        case image(String?)
    }

    let subject: Subject
    @ObservedObject var docker: DockerModel
    @Environment(\.dockerShown) private var shown

    private var emulation: DockerEmulation? {
        switch subject {
        case .container(let container): docker.emulation(of: container)
        case .image(let id): docker.emulation(ofImage: id)
        }
    }

    /// None while it is off screen: nothing asks, and showing it again
    /// asks once.
    private var key: String {
        guard shown else { return "" }
        switch subject {
        case .container(let container): return docker.platformKey(of: container)
        case .image(let id): return docker.platformKey(id)
        }
    }

    var body: some View {
        Group {
            if let emulation {
                Text(verbatim: emulation.image.short)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TabStatusStyle.waiting)
                    .padding(.horizontal, 4)
                    .frame(height: 14)
                    .background(Capsule().fill(TabStatusStyle.waiting.opacity(0.14)))
                    .fixedSize()
                    .help(emulation.help)
                    .accessibilityIdentifier("docker.emulated")
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: key) {
            guard shown else { return }
            switch subject {
            case .container(let container): docker.wantPlatform(of: container)
            case .image(let id): docker.wantPlatform(of: id)
            }
        }
    }
}

/// An emulated container's or image's box: why it is slow, what runs it
/// natively, and the verb that does — the port-conflict box's way.
struct DockerEmulationNote: View {
    let emulation: DockerEmulation
    let text: String
    let verb: DockerVerb?
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(TabStatusStyle.waiting)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: emulation.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text)
                    Text(verbatim: text).font(.system(size: 12)).foregroundStyle(theme.text2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if let verb {
                Button(verb.title) { verb.perform() }
                    .disabled(verb.unavailable != nil)
                    .help(verb.help)
                    .accessibilityIdentifier("docker.emulation.fix")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(TabStatusStyle.waiting.opacity(0.12)))
        .accessibilityIdentifier("docker.emulation")
    }
}

/// A container in a list: its dot, what it is called there, its image,
/// its ports, how long it has been up (or how it ended).
struct DockerContainerRow: View {
    let container: ContainerSummary
    /// In a project's block, it goes by its service.
    let inProject: Bool
    let busy: Bool
    /// Whose platforms the badge reads.
    let docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let open: (URL) -> Void
    /// The rail's narrow panel: no ports, no status words.
    var compact = false
    /// A remote engine's host, where its ports are (`DockerModel.publishedHost`).
    var remoteHost: String?
    /// What it uses now, for the page's columns.
    var usage: DockerUsage? = nil
    /// The page's CPU and memory columns, at the end of the row.
    var columns = false

    var title: String {
        guard inProject, let service = container.composeService else { return container.name }
        if container.isOneOff { return "\(service) (run)" }
        let number = Int(container.labels["com.docker.compose.container-number"] ?? "") ?? 1
        return number > 1 ? "\(service) #\(number)" : service
    }

    var body: some View {
        HStack(spacing: 8) {
            DockerStatusDot(color: DockerStatusStyle.color(container, idle: theme.text3))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(container.state.isUp ? theme.text : theme.text2).lineLimit(1)
                    DockerEmulationBadge(subject: .container(container), docker: docker)
                }
                Text(verbatim: container.Image).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if !compact {
                ForEach(PublishedPort.of(container.Ports ?? [], remoteHost: remoteHost).prefix(3), id: \.self) { port in
                    DockerPortPill(port: port, theme: theme, open: open)
                }
                Text(verbatim: DockerStatusStyle.status(container))
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            if busy { ProgressView().controlSize(.mini) }
            // Last and of fixed widths: they line up down the list,
            // whatever the ports and the status take.
            if columns { DockerUsageCells(usage: usage, reads: container.state.hasStats, theme: theme) }
        }
        .padding(.leading, inProject ? 18 : 0)
        .frame(height: 30)
        .contentShape(Rectangle())
        .accessibilityIdentifier("docker.container.\(container.name)")
    }
}

/// A compose project's own row: fold, state, name, where it was started,
/// how much of it runs; up, stop and restart on hover.
struct DockerProjectRow: View {
    let group: DockerListGroup
    let folded: Bool
    let busy: Bool
    @ObservedObject var theme: ChromeTheme
    let fold: () -> Void
    /// `up`, `stop`, `restart`, `down`.
    let act: (String) -> Void
    var compact = false
    /// Its containers' use added up, for the page's columns.
    var usage: DockerUsage? = nil
    var columns = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: fold) {
                Image(systemName: folded ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.text3).frame(width: 12, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let project = group.project {
                DockerStatusDot(color: DockerStatusStyle.color(project, idle: theme.text3))
                Text(verbatim: project.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                if !compact, let folder = project.workingDir {
                    Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 6)
                if busy { ProgressView().controlSize(.mini) }
                if hovering && !compact {
                    button("play.fill", "Up — docker compose up -d, in a tab") { act("up") }
                    if !project.planned {
                        button("stop.fill", "Stop its containers") { act("stop") }
                        button("arrow.clockwise", "Restart its containers") { act("restart") }
                    }
                }
                Text(verbatim: "\(project.running)/\(project.expected)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                    .help(project.planned ? "Not created yet" : "\(project.running) running")
            } else {
                Text("Other containers").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text2)
                Spacer(minLength: 6)
                Text(verbatim: "\(group.containers.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
            }
            if columns { DockerUsageCells(usage: usage, reads: group.containers.contains { $0.state.hasStats }, theme: theme) }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityIdentifier("docker.project.\(group.project?.name ?? "other")")
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(theme.text2).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A service of a project before it runs: a hollow dot, what it runs — its
/// image or the folder it is built from, the services it waits for — and,
/// with room, the host ports it will publish, as words: nothing listens yet.
struct DockerPlannedServiceRow: View {
    let service: ComposeService
    @ObservedObject var theme: ChromeTheme
    /// The rail's narrow panel: no ports, no status words.
    var compact = false
    /// The checkout, for a build folder said from it.
    var folder: String?
    /// Under its project's row, as a container is.
    var indented = true
    /// The page's CPU and memory columns: blank, so its words line up
    /// with the containers'.
    var columns = false

    var body: some View {
        let replicas = service.spec?.replicas ?? 1
        HStack(spacing: 8) {
            Circle().strokeBorder(theme.text3, lineWidth: 1.2).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(verbatim: service.name).font(.system(size: 12.5)).foregroundStyle(theme.text2).lineLimit(1)
                    if replicas > 1 {
                        Text(verbatim: "×\(replicas)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(theme.text3)
                    }
                    if service.spec?.watched == true {
                        Image(systemName: "eye").font(.system(size: 9.5)).foregroundStyle(theme.text3)
                            .help("develop.watch: Watch syncs or rebuilds it as its files change")
                    }
                }
                Text(verbatim: service.spec?.summary(in: folder) ?? "")
                    .font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if !compact {
                ForEach((service.spec?.ports ?? []).filter { $0.published != nil }.prefix(3), id: \.self) { port in
                    Text(verbatim: port.label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.text3)
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(RoundedRectangle(cornerRadius: 4).stroke(theme.border))
                        .help("Published on this port once it runs")
                }
                Text("Not created").font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1).frame(minWidth: 70, alignment: .trailing)
            }
            if columns { DockerUsageCells(usage: nil, reads: false, theme: theme) }
        }
        .padding(.leading, indented ? 18 : 0)
        .frame(height: 30)
        .contentShape(Rectangle())
        .accessibilityIdentifier("docker.planned.\(service.name)")
    }
}

/// A row's CPU and memory on the page's list, as `docker stats` says them:
/// a dash while a running one waits for its second read, nothing for one
/// that isn't running. Memory turns orange near its limit.
struct DockerUsageCells: View {
    static let cpuWidth: CGFloat = 52
    static let memoryWidth: CGFloat = 70

    let usage: DockerUsage?
    /// Whether it is read at all: running or paused.
    let reads: Bool
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(spacing: 8) {
            cell(usage?.cpuLabel, width: Self.cpuWidth, color: theme.text2)
                .help("Of one CPU, as docker stats says it — 200% is two CPUs flat out")
            cell(usage?.memoryLabel, width: Self.memoryWidth, color: usage?.nearMemoryLimit == true ? TabStatusStyle.waiting : theme.text2)
                .help(memoryHelp)
        }
        .accessibilityIdentifier("docker.usage")
    }

    private func cell(_ label: String?, width: CGFloat, color: Color) -> some View {
        Text(verbatim: reads ? label ?? "—" : "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(label == nil ? theme.text3 : color)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private var memoryHelp: String {
        guard let usage else { return "Memory in use, as docker stats works it out" }
        guard usage.memoryLimit > 0 else { return "In use: \(usage.memoryLabel)" }
        return "\(usage.memoryLabel) of \(DockerBytes.string(usage.memoryLimit, memory: true)) — " + String(format: "%.0f%%", usage.memoryPercent)
    }
}

/// The page's list header: the columns' names; CPU and Memory sort by
/// themselves, the busiest first, and again (or Name) back by name.
struct DockerListColumns: View {
    @Binding var sort: DockerListSort
    @ObservedObject var theme: ChromeTheme

    var body: some View {
        HStack(spacing: 8) {
            column("Name", .name, help: "By name: projects, then the rest")
            Spacer(minLength: 6)
            column("CPU", .cpu, help: "Sort by CPU, the busiest first (again: by name)")
                .frame(width: DockerUsageCells.cpuWidth, alignment: .trailing)
            column("Memory", .memory, help: "Sort by memory, the biggest first (again: by name)")
                .frame(width: DockerUsageCells.memoryWidth, alignment: .trailing)
        }
        .frame(height: 22)
    }

    private func column(_ title: String, _ order: DockerListSort, help: String) -> some View {
        let active = sort == order
        return Button {
            sort = sort.clicked(order)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if active && order != .name { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(active ? theme.text : theme.text3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier("docker.sort.\(order.rawValue)")
    }
}
