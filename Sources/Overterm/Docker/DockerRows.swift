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

/// A container in a list: its dot, what it is called there, its image,
/// its ports, how long it has been up (or how it ended).
struct DockerContainerRow: View {
    let container: ContainerSummary
    /// In a project's block, it goes by its service.
    let inProject: Bool
    let busy: Bool
    @ObservedObject var theme: ChromeTheme
    let open: (URL) -> Void
    /// The rail's narrow panel: no ports, no status words.
    var compact = false

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
                Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(container.state.isUp ? theme.text : theme.text2).lineLimit(1)
                Text(verbatim: container.Image).font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if !compact {
                ForEach(PublishedPort.of(container.Ports ?? []).prefix(3), id: \.self) { port in
                    DockerPortPill(port: port, theme: theme, open: open)
                }
                Text(verbatim: DockerStatusStyle.status(container))
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(1)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            if busy { ProgressView().controlSize(.mini) }
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
                    button("stop.fill", "Stop its containers") { act("stop") }
                    button("arrow.clockwise", "Restart its containers") { act("restart") }
                }
                Text(verbatim: "\(project.running)/\(project.containers.filter { !$0.isOneOff }.count)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
                    .help("\(project.running) running")
            } else {
                Text("Other containers").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.text2)
                Spacer(minLength: 6)
                Text(verbatim: "\(group.containers.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text3)
            }
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
