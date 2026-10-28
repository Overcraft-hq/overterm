import AppKit
import Combine
import Foundation

/// What the Docker page and panel ask the window to do.
struct DockerActions {
    /// A command typed into a new terminal tab in `folder` (home when nil).
    var run: (_ command: String, _ folder: URL?) -> Void
    /// Asks — what, why, the button's word — then does it.
    var confirm: (_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) -> Void
    /// A published port, in the browser.
    var open: (URL) -> Void
    var copy: (String) -> Void
    /// Settings ▸ Docker.
    var settings: () -> Void
    /// The page (⌥⌘P), from the panel.
    var openPage: () -> Void = {}
    /// A container in the right-hand pane, from the panel.
    var showContainer: (ContainerSummary) -> Void = { _ in }
    /// A database container's connection, in the Database panel's form.
    var openDatabase: (DockerDatabaseGuess.Guess) -> Void = { _ in }
    /// A container's file, in the editor — saved back into the container.
    var openFile: (ContainerSummary, String) -> Void = { _, _ in }
    /// A container's file, to the Mac.
    var downloadFile: (ContainerSummary, String) -> Void = { _, _ in }
    /// A tab of the window, brought up.
    var showTab: (UUID) -> Void = { _ in }
    /// A file on the Mac, in the editor.
    var edit: (URL) -> Void = { _ in }
    /// Where to save something: a suggested name, then the place.
    var pickSave: (String, @escaping (URL) -> Void) -> Void = { _, _ in }
    /// A file to read: then the file.
    var pickOpen: (@escaping (URL) -> Void) -> Void = { _ in }
    /// A name asked for: title, what it is for, the first guess, then it.
    var askName: (String, String, String, @escaping (String) -> Void) -> Void = { _, _, _, _ in }
}

/// One block of the containers list: a compose project with its
/// containers, or the containers in none (`project` nil).
struct DockerListGroup: Identifiable, Equatable {
    var project: ComposeProject?
    var containers: [ContainerSummary]

    var id: String { project.map { DockerPageModel.projectTag($0.name) } ?? DockerPageModel.looseTag }
}

/// A window's Docker page: which section, what the filter says, what is
/// selected, which projects are folded. The containers are the app's
/// (`DockerModel`).
@MainActor
final class DockerPageModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case containers, images, volumes, networks, builds

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .containers: "shippingbox"
            case .images: "square.stack.3d.down.right"
            case .volumes: "externaldrive"
            case .networks: "point.3.filled.connected.trianglepath.dotted"
            case .builds: "hammer"
            }
        }

        /// What the model reads for it.
        var resource: DockerModel.Resource? {
            switch self {
            case .containers: nil
            case .images: .images
            case .volumes: .volumes
            case .networks: .networks
            case .builds: nil
            }
        }
    }

    @Published var section: Section = .containers
    @Published var filter = ""
    /// Stopped containers hidden.
    @Published var runningOnly = false
    /// Container ids, and `project:<name>` for a project's own row.
    @Published var selection: Set<String> = []
    @Published var collapsed: Set<String> = []
    /// What the last action said when it failed, until dismissed.
    @Published var error: String?
    /// Containers (and projects) with an action on its way.
    @Published private(set) var busy: Set<String> = []
    /// `?`: the keys.
    @Published var cheatSheet = false
    /// Bumped to put the keyboard in the filter field (`/`).
    @Published var focusFilter = 0
    /// The other sections' selections: image ids, volume names, network ids.
    @Published var imageSelection: Set<String> = []
    @Published var volumeSelection: Set<String> = []
    @Published var networkSelection: Set<String> = []
    /// Images being pulled, by name: their layers' progress.
    @Published var pulls: [String: DockerPull] = [:]
    /// Clean Up's sheet, and what it would remove.
    @Published var cleaning = false
    @Published var cleanChoice = DockerPrunePlan.Choice()
    /// What Clean Up freed, said once — and what an export or an import
    /// did.
    @Published var cleaned: String?
    /// An export or import on its way: what it is.
    @Published var transferring: String?
    /// Builds, as `buildx history` keeps them.
    @Published var builds: [DockerBuildRecord] = []
    @Published var buildSelection: Set<String> = []
    @Published var buildsError: String?
    /// The Run window, open on this.
    @Published var runSpec: DockerRunSpec?

    let docker: DockerModel

    private var streams: AnyCancellable?
    private var wanting: AnyCancellable?
    /// The resource this page holds the model to (`DockerModel.want`).
    private var wanted: DockerModel.Resource?

    init(docker: DockerModel = .shared) {
        self.docker = docker
        // A section on screen is read, and kept current, while it shows.
        wanting = $section.combineLatest($visible)
            .sink { [weak self] section, visible in
                DispatchQueue.main.async {
                    self?.want(visible ? section.resource : nil)
                    if visible, section == .builds { self?.loadBuilds() }
                }
            }
        // The detail's streams follow what it shows and whether it shows.
        streams = Publishers.CombineLatest4($selection, $detailTab, $visible, $showDetail)
            .combineLatest($projectTab)
            .sink { [weak self] _ in
                // @Published fires before the values land.
                DispatchQueue.main.async { self?.updateStreams() }
            }
    }

    private func want(_ resource: DockerModel.Resource?) {
        guard resource != wanted else { return }
        if let wanted { docker.unwant(wanted) }
        wanted = resource
        if let resource { docker.want(resource) }
        // Their sizes on the left, whichever section shows.
        if visible, docker.diskUsage == nil { docker.load(.volumes) }
    }

    func updateStreams() {
        if let project = detailedProject {
            projectSession(for: project.name).follow(shown: visible && showDetail && projectTab == .logs)
        } else {
            projectSession?.close()
            projectSession = nil
        }
        guard let container = detailed else {
            session?.close()
            session = nil
            return
        }
        session(for: container.Id).follow(detailTab, shown: visible && showDetail)
    }

    /// The one project the detail shows: the selection, if it is one.
    var detailedProject: ComposeProject? {
        guard selection.count == 1, let name = selection.first.flatMap(Self.project(of:)) else { return nil }
        return docker.projects.first { $0.name == name }
    }

    /// The project detail's session: one at a time.
    private(set) var projectSession: ProjectSession?

    func projectSession(for name: String) -> ProjectSession {
        if let projectSession, projectSession.name == name { return projectSession }
        projectSession?.close()
        let made = ProjectSession(name: name, docker: docker)
        projectSession = made
        return made
    }

    nonisolated static let looseTag = "loose"
    nonisolated static func projectTag(_ name: String) -> String { "project:" + name }
    nonisolated static func project(of tag: String) -> String? { tag.hasPrefix("project:") ? String(tag.dropFirst("project:".count)) : nil }

    /// The window's, set when it makes the page.
    var actions: DockerActions?
    /// The selected container's detail beside the list (Space).
    @Published var showDetail = true
    /// Its tab, kept from one container to the next.
    @Published var detailTab: ContainerTab = .overview
    /// A project's detail's tab.
    @Published var projectTab: ProjectDetailView.Tab = .logs
    /// Whether the page is on screen (the window says): a hidden page's
    /// detail reads no logs and no stats.
    @Published var visible = false

    /// The list as shown: projects first, by name, then the rest; the
    /// filter applied; a project kept while any of its containers matches.
    nonisolated static func groups(projects: [ComposeProject], loose: [ContainerSummary], filter: DockerFilter, runningOnly: Bool) -> [DockerListGroup] {
        func shown(_ containers: [ContainerSummary]) -> [ContainerSummary] {
            containers.filter { (!runningOnly || $0.state.isUp) && filter.matches($0) }
        }
        var groups = projects.compactMap { project -> DockerListGroup? in
            let containers = shown(project.services.flatMap(\.containers))
            return containers.isEmpty ? nil : DockerListGroup(project: project, containers: containers)
        }
        let rest = shown(loose)
        if !rest.isEmpty { groups.append(DockerListGroup(project: nil, containers: rest)) }
        return groups
    }

    var groups: [DockerListGroup] {
        Self.groups(projects: docker.projects, loose: docker.loose, filter: DockerFilter(filter), runningOnly: runningOnly)
    }

    /// The rows as the keyboard walks them: a project's row, then its
    /// containers unless folded.
    var rows: [String] {
        groups.flatMap { group in
            [group.id] + (collapsed.contains(group.id) ? [] : group.containers.map(\.Id))
        }
    }

    /// The containers the selection means: a project's row stands for all
    /// of its containers.
    var selectedContainers: [ContainerSummary] {
        var seen = Set<String>()
        var result: [ContainerSummary] = []
        for tag in selection {
            let members: [ContainerSummary] =
                if let name = Self.project(of: tag) {
                    docker.projects.first { $0.name == name }?.containers.filter { !$0.isOneOff } ?? []
                } else if tag == Self.looseTag {
                    docker.loose
                } else {
                    docker.container(tag).map { [$0] } ?? []
                }
            for container in members where seen.insert(container.Id).inserted { result.append(container) }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// The one container the detail shows: the selection, if it is one.
    var detailed: ContainerSummary? {
        guard selection.count == 1, let tag = selection.first, Self.project(of: tag) == nil else { return nil }
        return docker.container(tag)
    }

    /// The project the selection is in, when it is all in one.
    var selectedProject: ComposeProject? {
        let names = Set(selection.compactMap { tag in Self.project(of: tag) ?? docker.container(tag)?.composeProject })
        guard names.count == 1, let name = names.first else { return nil }
        return docker.projects.first { $0.name == name }
    }

    /// The detail's session: one at a time, the last one closed.
    private(set) var session: ContainerSession?

    func session(for id: String) -> ContainerSession {
        if let session, session.id == id { return session }
        session?.close()
        let made = ContainerSession(id: id, docker: docker)
        session = made
        return made
    }

    /// Bumped when the page comes up, to give the list the keyboard.
    @Published var focusList = 0

    func toggleFold(_ tag: String) {
        if collapsed.contains(tag) { collapsed.remove(tag) } else { collapsed.insert(tag) }
    }

    // MARK: Acting

    /// Start the stopped ones, stop the running ones — what `s` does.
    func startOrStop() {
        let containers = selectedContainers
        guard !containers.isEmpty else { return }
        let action: DockerEngine.ContainerAction = containers.contains { $0.state.isUp } ? .stop : .start
        act(action, on: containers)
    }

    func restart() { act(.restart, on: selectedContainers) }

    func pauseOrUnpause() {
        let containers = selectedContainers.filter { $0.state == .running || $0.state == .paused }
        guard !containers.isEmpty else { return }
        act(containers.allSatisfy { $0.state == .paused } ? .unpause : .pause, on: containers)
    }

    func act(_ action: DockerEngine.ContainerAction, on containers: [ContainerSummary]) {
        for container in containers {
            busy.insert(container.Id)
            Task {
                defer { self.busy.remove(container.Id) }
                do {
                    try await docker.perform(action, on: container.Id)
                } catch {
                    self.error = "\(action.rawValue.capitalized) \(container.name): \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Keys

    /// A key typed while the list has the keyboard (DockerKey). Whether it
    /// meant something; anything else goes on to the list.
    @discardableResult
    func press(_ characters: String) -> Bool {
        if cheatSheet {
            cheatSheet = false
            return true
        }
        guard let key = DockerKey.of(characters) else { return false }
        if let section = key.section {
            self.section = section
            return true
        }
        switch key {
        case .filter:
            focusFilter += 1
            return true
        case .help:
            cheatSheet = true
            return true
        case .cleanUp:
            cleaning = true
            return true
        case .run:
            let image = section == .images ? docker.images.first { imageSelection.contains($0.Id) }?.tags.first : detailed?.Image
            runSpec = DockerRunSpec(image: image ?? "")
            return true
        default: break
        }
        guard section == .containers else { return pressInList(key) }
        let selected = selectedContainers
        let endpoint = docker.endpoint
        switch key {
        case .details, .logs:
            showDetail = true
            detailTab = .logs
        case .inspect:
            showDetail = true
            detailTab = .inspect
        case .toggleDetail: showDetail.toggle()
        case .startStop: startOrStop()
        case .restart: restart()
        case .pause: pauseOrUnpause()
        case .followLogs:
            for container in selected.prefix(4) { actions?.run(DockerCommands.followLogs(of: container, endpoint: endpoint), nil) }
        case .shell:
            for container in selected.prefix(4) where container.state == .running {
                actions?.run(DockerCommands.shell(in: container, endpoint: endpoint), nil)
            }
        case .debugShell:
            if let container = selected.first(where: { $0.state == .running }) {
                actions?.run(DockerCommands.debugShell(beside: container, image: Settings.shared.dockerDebugImage, endpoint: endpoint), nil)
            }
        case .open:
            if let url = selected.lazy.compactMap({ PublishedPort.of($0.Ports ?? []).first?.url }).first { actions?.open(url) }
        case .database:
            if let container = selected.first { openInDatabase(container) }
        case .remove: confirmRemove(selected)
        case .composeUp:
            if let project = selectedProject { compose("up", project) }
        case .composeDown:
            if let project = selectedProject { compose("down", project) }
        default: break
        }
        return true
    }

    /// Images, volumes, networks: what a key means there.
    private func pressInList(_ key: DockerKey) -> Bool {
        switch key {
        case .remove:
            switch section {
            case .images: confirmRemove(images: docker.images.filter { imageSelection.contains($0.Id) })
            case .volumes: confirmRemove(volumes: docker.volumes.filter { volumeSelection.contains($0.Name) })
            case .networks: confirmRemove(networks: docker.networks.filter { networkSelection.contains($0.Id) })
            case .builds: for build in builds where buildSelection.contains(build.id) { removeBuild(build) }
            case .containers: break
            }
            return true
        case .toggleDetail:
            showDetail.toggle()
            return true
        default:
            return false
        }
    }

    /// A project's verbs: `up`, `down` (asked first) and the logs in a
    /// terminal tab; `start`, `stop`, `restart` on its containers here.
    func compose(_ verb: String, _ project: ComposeProject) {
        let lasting = project.containers.filter { !$0.isOneOff }
        let folder = project.workingDir.map { URL(fileURLWithPath: $0) }
        let endpoint = docker.endpoint
        switch verb {
        case "up": actions?.run(DockerCommands.compose(project, "up -d", endpoint: endpoint), folder)
        case "logs": actions?.run(DockerCommands.compose(project, "logs -f --tail 100", endpoint: endpoint), folder)
        case "pull": actions?.run(DockerCommands.compose(project, "pull", endpoint: endpoint), folder)
        case "start": act(.start, on: lasting)
        case "stop": act(.stop, on: lasting.filter { $0.state.isUp })
        case "restart": act(.restart, on: lasting)
        case "down":
            actions?.confirm(
                "Take “\(project.name)” down?",
                "docker compose down stops and removes its containers and networks, in a terminal tab. Its volumes stay.", "Down"
            ) { [weak self] in self?.actions?.run(DockerCommands.compose(project, "down", endpoint: endpoint), folder) }
        default: break
        }
    }

    func confirmRemove(_ containers: [ContainerSummary]) {
        guard !containers.isEmpty else { return }
        let running = containers.filter { $0.state.isUp }.count
        actions?.confirm(
            containers.count == 1 ? "Remove “\(containers[0].name)”?" : "Remove \(containers.count) containers?",
            (running > 0 ? "Running ones are stopped first. " : "") + "Their volumes stay.", "Remove"
        ) { [weak self] in self?.remove(containers) }
    }

    /// Removes them — running ones stopped first, as `docker rm -f`. The
    /// window asks before.
    func remove(_ containers: [ContainerSummary]) {
        for container in containers {
            busy.insert(container.Id)
            Task {
                defer { self.busy.remove(container.Id) }
                do {
                    try await docker.remove(container.Id, force: true)
                    self.selection.remove(container.Id)
                } catch {
                    self.error = "Remove \(container.name): \(error.localizedDescription)"
                }
            }
        }
    }
}
