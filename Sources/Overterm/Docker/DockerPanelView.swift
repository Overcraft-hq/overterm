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
    /// Whether the sidebar shows the panel now (the window says): its
    /// views live on while it is collapsed.
    @Published var panelVisible = false
    @Published var error: String?
    @Published var collapsed: Set<String> = []
    /// What can be done to a container or a project here: the page's verbs,
    /// with the panel starting and stopping (its errors are its own). The
    /// window sets them.
    var verbs: (ContainerSummary) -> [DockerVerb] = { _ in [] }
    var projectVerbs: (ComposeProject) -> [DockerVerb] = { _ in [] }
    /// A test run on the page, by its session (the window sets it).
    var showRun: (String) -> Void = { _ in }

    let docker: DockerModel
    /// The checkout's compose project before it runs; the page shows it too.
    let checkoutCompose: ComposeFileModel

    private var streams: AnyCancellable?

    init(docker: DockerModel = .shared, checkoutCompose: ComposeFileModel? = nil) {
        self.docker = docker
        self.checkoutCompose = checkoutCompose ?? ComposeFileModel(docker: docker)
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

    /// What else runs: containers of other projects, or of none. Not
    /// Testcontainers': a test run's dozen would bury the rest (`runs`).
    var others: [ContainerSummary] {
        let mine = Set(here.flatMap(\.containers).map(\.Id))
        return docker.containers.filter { $0.state.isUp && !mine.contains($0.Id) && !Testcontainers.isMember($0) }
    }

    /// The test runs with something running, the newest first: one row.
    var runs: [TestcontainersSession] { docker.testcontainers.filter { $0.running > 0 } }

    /// A compose file at the checkout's top, for "Up" when nothing runs.
    var composeFile: URL? { checkout.flatMap(ComposeProjects.composeFile(in:)) }

    /// The checkout's compose project before it runs: until one of its
    /// name runs here, or one made from its files under another name, when
    /// the labels' project takes its place.
    var plan: ComposeProject? {
        guard let plan = checkoutCompose.project, !here.contains(where: { ComposeProjects.replaces($0, plan) }) else { return nil }
        return plan
    }

    /// The plan, when it was read from the files as they are now: what the
    /// View menu and the palette act on, Docker on screen or not.
    var currentPlan: ComposeProject? { checkoutCompose.isCurrent ? plan : nil }

    /// A project of the plan's name running from another folder — usually
    /// another worktree whose file sets `name:`. Its Up asks first.
    var planElsewhere: ComposeProject? {
        plan.flatMap { plan in docker.projects.first { $0.name == plan.name } }
    }

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
    /// The panel's, observed for its plan.
    @ObservedObject var checkoutCompose: ComposeFileModel
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
        .environment(\.dockerShown, panel.panelVisible)
        .accessibilityIdentifier("docker.panel")
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section("This checkout")
                let here = panel.here
                let plan = panel.plan
                ForEach(here) { project in
                    let group = DockerListGroup(project: project, containers: project.containers)
                    DockerProjectRow(
                        group: group, folded: panel.collapsed.contains(group.id), busy: false, theme: theme,
                        fold: { toggle(group.id) }, act: { _ in }, compact: true
                    )
                    .padding(.horizontal, 8)
                    .contextMenu { DockerVerbMenu(verbs: panel.projectVerbs(project)) }
                    if !panel.collapsed.contains(group.id) {
                        ForEach(project.containers) { container in row(container, inProject: true) }
                    }
                }
                if let plan { planned(plan) }
                if here.isEmpty, plan == nil { nothingHere }
                if settings.bool("docker.showAllContainers") {
                    let others = panel.others
                    let runs = panel.runs
                    if !others.isEmpty || !runs.isEmpty {
                        section("Running elsewhere")
                        ForEach(others) { container in row(container, inProject: false) }
                        if let newest = runs.first { testRuns(runs, newest: newest) }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// The checkout's project before it runs: its services as Compose will
    /// make them, and Up.
    @ViewBuilder private func planned(_ plan: ComposeProject) -> some View {
        let group = DockerListGroup(project: plan, containers: [], services: plan.services)
        let verbs = panel.projectVerbs(plan)
        DockerProjectRow(
            group: group, folded: panel.collapsed.contains(group.id), busy: false, theme: theme, fold: { toggle(group.id) }, act: { _ in },
            compact: true
        )
        .padding(.horizontal, 8)
        .contextMenu { DockerVerbMenu(verbs: verbs) }
        if !panel.collapsed.contains(group.id) {
            ForEach(plan.services) { service in
                DockerPlannedServiceRow(service: service, theme: theme, compact: true, folder: plan.workingDir)
                    .padding(.horizontal, 12)
                    .contextMenu { DockerVerbMenu(verbs: verbs) }
            }
        }
        VStack(alignment: .leading, spacing: 5) {
            if let up = verbs.first(where: { $0.key == "u" }) {
                Button {
                    up.perform()
                } label: {
                    Label("Up — not created yet", systemImage: "play.fill").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentText)
                .help("docker compose up -d, in a terminal tab in the checkout — another worktree's ports or name taken, asked first")
                .accessibilityIdentifier("docker.panel.up")
            }
            if let other = panel.planElsewhere {
                Text(verbatim: "“\(other.name)” runs from \(other.workingDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "another folder")")
                    .font(.system(size: 11)).foregroundStyle(theme.text3).lineLimit(2).truncationMode(.head)
            }
            if let error = checkoutCompose.error { composeError(error) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Testcontainers' runs, summed up in one row: the newest on the page.
    /// Two lines, as a container's row: the rail is narrow, and one line
    /// cut the count off.
    private func testRuns(_ runs: [TestcontainersSession], newest: TestcontainersSession) -> some View {
        let running = runs.reduce(0) { $0 + $1.running }
        return Button {
            panel.showRun(newest.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "testtube.2").font(.system(size: 10.5)).foregroundStyle(theme.text3).frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Testcontainers").font(.system(size: 12.5)).foregroundStyle(theme.text).lineLimit(1)
                    Text(verbatim: "\(running) running in \(runs.count) run\(runs.count == 1 ? "" : "s")")
                        .font(.system(size: 10.5)).foregroundStyle(theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("On the Docker page")
        .accessibilityIdentifier("docker.panel.testcontainers")
    }

    /// No project here, before it runs or since.
    private var nothingHere: some View {
        VStack(alignment: .leading, spacing: 8) {
            if checkoutCompose.reading, let file = panel.composeFile {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: "Reading \(file.lastPathComponent)…").font(.system(size: 12)).foregroundStyle(theme.text2)
                }
            } else {
                Text("No compose project runs here.").font(.system(size: 12)).foregroundStyle(theme.text2)
            }
            if let error = checkoutCompose.error { composeError(error) }
            if let file = panel.composeFile {
                Button {
                    if let checkout = panel.checkout { actions.composeUp(.checkout(checkout), .ask) }
                } label: {
                    Label("Up — \(file.lastPathComponent)", systemImage: "play.fill").font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentText)
                .help("docker compose up -d, in a terminal tab in the checkout — another worktree's ports or name taken, asked first")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func composeError(_ error: String) -> some View {
        Text(verbatim: error).font(.system(size: 11)).foregroundStyle(TabStatusStyle.failed).lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .help("What docker compose config said; the services are from the last time it could read the file")
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(theme.text3)
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ container: ContainerSummary, inProject: Bool) -> some View {
        Button {
            show(container)
        } label: {
            DockerContainerRow(container: container, inProject: inProject, busy: false, docker: docker, theme: theme, open: actions.open, compact: true)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(panel.picked == container.Id && panel.slotVisible ? theme.rowSel : .clear))
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .contextMenu { DockerVerbMenu(verbs: panel.verbs(container)) }
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
                container: container, session: panel.session(for: id), tab: $panel.tab, docker: docker, theme: theme, actions: actions,
                verbs: { panel.verbs(container) }
            )
            .id(id)
            .environment(\.dockerShown, panel.slotVisible)
        } else {
            Text("Pick a container in the Docker panel.").font(.system(size: 12)).foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
