import Foundation

/// What `b` rebuilds in one project; `services` empty: all of it.
struct ComposeRebuild: Equatable {
    var project: ComposeProject
    var services: [String]
}

/// Up With Profiles…'s sheet: the profiles the files name, the ones ticked.
struct ComposeProfileChoice: Equatable {
    var project: ComposeProject
    var profiles: [String]
    var chosen: Set<String>

    /// `docker compose … --profile a --profile b up -d`, in the profiles'
    /// order.
    func command(endpoint: DockerEndpoint?) -> String {
        DockerCommands.compose(project, "up -d", profiles: profiles.filter(chosen.contains), endpoint: endpoint)
    }
}

/// A compose project's services and what its files say: a service rebuilt,
/// restarted, pulled, run once, its logs; the project watched, or brought up
/// with profiles. What only the files say (`ComposeFacts`) is asked of
/// Compose when something on screen draws a project's verbs, and kept until
/// its files change.
extension DockerPageModel {
    // MARK: What the files say

    /// What is known of the project's files, a stale answer included. When
    /// they changed since (or were never read), or a problem that wasn't
    /// theirs is due again (`retry`), a read starts — never an answer
    /// published at once: this is called from views' bodies.
    func composeFacts(for project: ComposeProject) -> ComposeFacts? {
        guard let stamp = ComposeFacts.stamp(project) else { return nil }
        let known = composeFacts[project.name]
        let due = known?.stamp != stamp || known?.retry.map { $0 <= Date() } == true
        if due, composeFactReads[project.name] == nil, Self.mayAskCompose { startComposeFactsRead(project, stamp) }
        return known
    }

    /// The project's facts as its files are now: read if they aren't
    /// known, or a read on its way awaited. A problem that wasn't the
    /// files' is asked about again at once: this is a key or a menu item.
    /// Nil when Compose can't be asked about it here.
    @discardableResult
    func loadComposeFacts(_ project: ComposeProject) async -> ComposeFacts? {
        guard let stamp = ComposeFacts.stamp(project), Self.mayAskCompose else { return nil }
        // A read on its way for older files is awaited, then asked again.
        for _ in 0..<3 {
            if let known = composeFacts[project.name], known.stamp == stamp, known.retry == nil { return known }
            if let reading = composeFactReads[project.name] {
                let facts = await reading.task.value
                if reading.stamp == stamp { return facts }
                continue
            }
            return await startComposeFactsRead(project, stamp).value
        }
        return composeFacts[project.name]
    }

    /// An isolated run asks only a scenario's stub `docker`.
    nonisolated static var mayAskCompose: Bool { !AppEnvironment.isIsolated || DockerCLI.override != nil }

    /// One read a project at a time; its answer kept with the stamp it was
    /// asked for, a failure too — so a file fixed is read again, and one
    /// that wasn't the files' when it is due (`retry`).
    @discardableResult
    private func startComposeFactsRead(_ project: ComposeProject, _ stamp: ComposeFacts.Stamp) -> Task<ComposeFacts?, Never> {
        let name = project.name
        let endpoint = docker.endpoint
        let task = Task { [weak self] () -> ComposeFacts? in
            let facts: ComposeFacts
            if let cli = DockerCLI(endpoint: endpoint) {
                facts = await ComposeFacts.read(project, stamp: stamp, cli: cli)
            } else {
                facts = ComposeFacts(stamp: stamp, problem: "docker isn't on this Mac.", retry: Date().addingTimeInterval(ComposeFacts.retryAfter))
            }
            guard let self else { return facts }
            self.composeFactReads[name] = nil
            if self.composeFacts[name] != facts { self.composeFacts[name] = facts }
            return facts
        }
        composeFactReads[name] = (stamp, task)
        return task
    }

    // MARK: Watch

    /// Whether a service of it has a `develop.watch`, as far as is known:
    /// a project before it runs from its plan, another from what its files
    /// said (asked when it isn't known). What offers Watch asks this.
    func watches(_ project: ComposeProject) -> Bool {
        project.planned ? project.services.contains { $0.spec?.watched == true } : composeFacts(for: project)?.watched.isEmpty == false
    }

    /// `docker compose watch` in a tab in the project's folder; nil when it
    /// went there, else why not. Compose watches only services with a
    /// `develop.watch`, and refuses a project with none: it is asked first.
    func watch(_ project: ComposeProject) async -> String? {
        let watched: [String]
        if project.planned {
            // Its plan is Compose's own reading of the files.
            watched = project.services.filter { $0.spec?.watched == true }.map(\.name)
        } else {
            guard let facts = await loadComposeFacts(project) else {
                return "Compose can't be asked about “\(project.name)” here: no docker, or none of its compose files on this Mac."
            }
            if facts.watched.isEmpty, let problem = facts.problem { return "Compose couldn't read \(project.name)'s files: \(problem)" }
            watched = facts.watched
        }
        guard !watched.isEmpty else { return "No service of \(project.name) has develop.watch: Compose watches only those." }
        compose("watch", project)
        return nil
    }

    /// Watch, saying why not on the page.
    func startWatch(_ project: ComposeProject) {
        Task {
            if let why = await watch(project) { error = why }
        }
    }

    // MARK: Rebuild

    /// What `b` rebuilds: a project's row, all of it; a container, its
    /// service. One-offs are no service's, and a container in no project
    /// has none. In the projects' order, services sorted. Pure.
    nonisolated static func rebuilds(of selection: Set<String>, in projects: [ComposeProject]) -> [ComposeRebuild] {
        projects.compactMap { project in
            if selection.contains(projectTag(project.name)) { return ComposeRebuild(project: project, services: []) }
            let services = project.services.filter { service in
                service.containers.contains { !$0.isOneOff && selection.contains($0.Id) }
            }
            return services.isEmpty ? nil : ComposeRebuild(project: project, services: services.map(\.name).sorted())
        }
    }

    /// `up -d --build`, one tab a project (four at most, like the other
    /// keys that open tabs): its images built again, what changed made again.
    func rebuild(_ rebuilds: [ComposeRebuild]) {
        let endpoint = docker.endpoint
        for rebuild in rebuilds.prefix(4) {
            actions?.run(
                DockerCommands.compose(rebuild.project, "up -d --build", services: rebuild.services, endpoint: endpoint), composeFolder(rebuild.project))
        }
    }

    // MARK: A service

    /// A compose verb for one service, in a tab in the project's folder:
    /// `pull`, `run --rm`, `logs -f --tail 100`.
    func composeService(_ verb: String, _ service: ComposeService, _ project: ComposeProject) {
        actions?.run(DockerCommands.compose(project, verb, services: [service.name], endpoint: docker.endpoint), composeFolder(project))
    }

    /// The project's Logs tab, narrowed to the service.
    func showLogs(of service: ComposeService, in project: ComposeProject) {
        let tag = Self.projectTag(project.name)
        if selection != [tag] { selection = [tag] }
        showDetail = true
        projectTab = .logs
        projectSession(for: project.name).service = service.name
    }

    // MARK: Profiles

    /// Up With Profiles…'s sheet, on the page — brought up first from the
    /// panel. Ticked as last time in this run.
    func chooseProfiles(_ project: ComposeProject, _ profiles: [String]) {
        if !visible { actions?.openPage() }
        profileChoice = ComposeProfileChoice(project: project, profiles: profiles, chosen: (lastProfiles[project.name] ?? []).intersection(profiles))
    }

    /// The sheet's Up: those profiles' services with the rest, in a tab.
    func upWithProfiles() {
        guard let choice = profileChoice, !choice.chosen.isEmpty else { return }
        profileChoice = nil
        lastProfiles[choice.project.name] = choice.chosen
        actions?.run(choice.command(endpoint: docker.endpoint), composeFolder(choice.project))
    }

    private func composeFolder(_ project: ComposeProject) -> URL? {
        project.workingDir.map { URL(fileURLWithPath: $0) }
    }
}
