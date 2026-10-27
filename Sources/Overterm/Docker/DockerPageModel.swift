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
        case containers

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .containers: "shippingbox"
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

    let docker: DockerModel

    private var streams: AnyCancellable?

    init(docker: DockerModel = .shared) {
        self.docker = docker
        // The detail's streams follow what it shows and whether it shows.
        streams = Publishers.CombineLatest4($selection, $detailTab, $visible, $showDetail)
            .sink { [weak self] _ in
                // @Published fires before the values land.
                DispatchQueue.main.async { self?.updateStreams() }
            }
    }

    func updateStreams() {
        guard let container = detailed else {
            session?.close()
            session = nil
            return
        }
        session(for: container.Id).follow(detailTab, shown: visible && showDetail)
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
        case .open:
            if let url = selected.lazy.compactMap({ PublishedPort.of($0.Ports ?? []).first?.url }).first { actions?.open(url) }
        case .remove: confirmRemove(selected)
        case .composeUp:
            if let project = selectedProject { compose("up", project) }
        case .composeDown:
            if let project = selectedProject { compose("down", project) }
        case .filter: focusFilter += 1
        case .help: cheatSheet = true
        }
        return true
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
