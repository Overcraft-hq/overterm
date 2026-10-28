import Combine
import SwiftUI

/// A window's Docker panel and the container it shows on the right: which
/// checkout the selected tab is in, the container picked, its tab.
@MainActor
final class DockerPanelModel: ObservableObject {
    /// The selected tab's checkout (its repository's root, else its folder).
    @Published var checkout: URL?
    /// The container in the right-hand pane.
    @Published var picked: String?
    @Published var tab: ContainerTab = .logs
    /// Whether that pane shows it now (the window says).
    @Published var slotVisible = false
    @Published var error: String?
    @Published var collapsed: Set<String> = []

    let docker: DockerModel

    private var streams: AnyCancellable?

    init(docker: DockerModel = .shared) {
        self.docker = docker
        streams = Publishers.CombineLatest3($picked, $tab, $slotVisible)
            .sink { [weak self] _ in
                // @Published fires before the values land.
                DispatchQueue.main.async { self?.updateStreams() }
            }
    }

    func updateStreams() {
        guard let id = picked else {
            session?.close()
            session = nil
            return
        }
        session(for: id).follow(tab, shown: slotVisible)
    }

    /// The checkout's compose projects: its stack.
    var here: [ComposeProject] { checkout.map { docker.projects(in: $0) } ?? [] }

    /// What else runs: containers of other projects, or of none.
    var others: [ContainerSummary] {
        let mine = Set(here.flatMap(\.containers).map(\.Id))
        return docker.containers.filter { $0.state.isUp && !mine.contains($0.Id) }
    }

    /// A compose file at the checkout's top, for "Up" when nothing runs.
    var composeFile: URL? { checkout.flatMap(ComposeProjects.composeFile(in:)) }

    private(set) var session: ContainerSession?

    func session(for id: String) -> ContainerSession {
        if let session, session.id == id { return session }
        session?.close()
        let made = ContainerSession(id: id, docker: docker)
        session = made
        return made
    }

    func act(_ action: DockerEngine.ContainerAction, on containers: [ContainerSummary]) {
        for container in containers {
            Task {
                do {
                    try await docker.perform(action, on: container.Id)
                } catch {
                    self.error = "\(action.rawValue.capitalized) \(container.name): \(error.localizedDescription)"
                }
            }
        }
    }
}

/// The rail's Docker panel: the selected tab's checkout's stack first —
/// its compose projects and their containers — then what else runs. A
/// container clicked opens in the right-hand pane.
struct DockerPanelView: View {
    @ObservedObject var panel: DockerPanelModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var settings: Settings
    @ObservedObject var theme: ChromeTheme
    let group: TabGroup?
    let actions: DockerActions
    let openPage: () -> Void
    /// A container in the right-hand pane.
    let show: (ContainerSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Docker", group: group, theme: theme, help: panel.checkout?.path) {
                PanelHeaderButton(symbol: "macwindow", help: "The Docker page (⌥⌘P)", action: openPage, theme: theme)
            }
            if let error = panel.error {
                Text(verbatim: error).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).lineLimit(3)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    .onTapGesture { panel.error = nil }
            }
            switch docker.connection {
            case .running: content
            case .connecting: ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
            case .down(let reason): down(reason)
            case .off: note("Docker is off in Settings.")
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityIdentifier("docker.panel")
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section("This checkout")
                let here = panel.here
                if here.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No compose project runs here.").font(.system(size: 12)).foregroundStyle(theme.text2)
                        if let file = panel.composeFile {
                            Button {
                                actions.run(DockerCommands.prefix(for: docker.endpoint) + "docker compose up -d", panel.checkout)
                            } label: {
                                Label("Up — \(file.lastPathComponent)", systemImage: "play.fill").font(.system(size: 11.5))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.accentText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                } else {
                    ForEach(here) { project in
                        let group = DockerListGroup(project: project, containers: project.containers)
                        DockerProjectRow(
                            group: group, folded: panel.collapsed.contains(group.id), busy: false, theme: theme,
                            fold: { toggle(group.id) }, act: { _ in }, compact: true
                        )
                        .padding(.horizontal, 8)
                        .contextMenu { projectMenu(project) }
                        if !panel.collapsed.contains(group.id) {
                            ForEach(project.containers) { container in row(container, inProject: true) }
                        }
                    }
                }
                if settings.bool("docker.showAllContainers") {
                    let others = panel.others
                    if !others.isEmpty {
                        section("Running elsewhere")
                        ForEach(others) { container in row(container, inProject: false) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ container: ContainerSummary, inProject: Bool) -> some View {
        Button {
            show(container)
        } label: {
            DockerContainerRow(container: container, inProject: inProject, busy: false, theme: theme, open: actions.open, compact: true)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(panel.picked == container.Id && panel.slotVisible ? theme.rowSel : .clear))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(container.state.isUp ? "Stop" : "Start") { panel.act(container.state.isUp ? .stop : .start, on: [container]) }
            Button("Restart") { panel.act(.restart, on: [container]) }
            Divider()
            Button("Open a Shell in a Tab") { actions.run(DockerCommands.shell(in: container, endpoint: docker.endpoint), nil) }
                .disabled(container.state != .running)
            Button("Follow Logs in a Tab") { actions.run(DockerCommands.followLogs(of: container, endpoint: docker.endpoint), nil) }
            if let url = PublishedPort.of(container.Ports ?? []).first?.url {
                Button("Open \(url.absoluteString)") { actions.open(url) }
            }
            if DockerDatabaseGuess.kind(of: container.Image) != nil {
                Button("Open in Database…") {
                    Task {
                        guard let detail = try? await docker.engine?.container(container.Id),
                            let guess = DockerDatabaseGuess.guess(container, env: detail.env)
                        else { return }
                        actions.openDatabase(guess)
                    }
                }
            }
            Divider()
            Button("Copy Name") { actions.copy(container.name) }
        }
    }

    @ViewBuilder private func projectMenu(_ project: ComposeProject) -> some View {
        let folder = project.workingDir.map { URL(fileURLWithPath: $0) }
        Button("Up (in a Tab)") { actions.run(DockerCommands.compose(project, "up -d", endpoint: docker.endpoint), folder) }
        Button("Restart") { panel.act(.restart, on: project.containers.filter { !$0.isOneOff }) }
        Button("Stop") { panel.act(.stop, on: project.containers.filter { $0.state.isUp }) }
        Divider()
        Button("Follow Logs in a Tab") { actions.run(DockerCommands.compose(project, "logs -f --tail 100", endpoint: docker.endpoint), folder) }
        Button("Down…") {
            actions.confirm(
                "Take “\(project.name)” down?",
                "docker compose down stops and removes its containers and networks, in a terminal tab. Its volumes stay.", "Down"
            ) { actions.run(DockerCommands.compose(project, "down", endpoint: docker.endpoint), folder) }
        }
    }

    private func toggle(_ id: String) {
        if panel.collapsed.contains(id) { panel.collapsed.remove(id) } else { panel.collapsed.insert(id) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(theme.text2).padding(.horizontal, 12).padding(.top, 8)
    }

    private func down(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(docker.runtimeStatus == .starting ? "\(docker.runtime.name) is starting…" : "\(docker.runtime.name) isn't running")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.text)
            Text(verbatim: reason).font(.system(size: 11)).foregroundStyle(theme.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let start = docker.runtime.command(.start, context: docker.endpoint?.context) {
                    Button("Start") {
                        actions.run(start, nil)
                        docker.reconnect()
                    }
                }
                Button("Try Again") { docker.reconnect() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// The container picked in the panel, in the right-hand pane.
struct DockerSlotView: View {
    @ObservedObject var panel: DockerPanelModel
    @ObservedObject var docker: DockerModel
    @ObservedObject var theme: ChromeTheme
    let actions: DockerActions

    var body: some View {
        if let id = panel.picked, let container = docker.container(id) {
            ContainerDetailView(
                container: container, session: panel.session(for: id), tab: $panel.tab, theme: theme, actions: actions,
                act: { panel.act($0, on: [container]) },
                remove: {
                    actions.confirm("Remove “\(container.name)”?", "Its volumes stay.", "Remove") {
                        Task { try? await docker.remove(container.Id, force: true) }
                    }
                }
            )
            .id(id)
        } else {
            Text("Pick a container in the Docker panel.").font(.system(size: 12)).foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
