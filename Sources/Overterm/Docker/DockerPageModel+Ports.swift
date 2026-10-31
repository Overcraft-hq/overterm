import Foundation

/// What an Up is of: a project — by its labels, or one before it runs (its
/// checkout's files) — or a checkout's compose files nothing was read of.
enum ComposeUpTarget: Equatable {
    case project(ComposeProject)
    case checkout(URL)
}

/// Up on Free Ports: asked first (an Up), or moving what is taken (the verb).
enum ComposeFreePorts: Equatable { case ask, yes }

/// An Up's files on this Mac: the checkout's compose files (real paths, as
/// Compose finds them), Compose's project folder, the name it runs as now.
struct ComposeUpSetup: Equatable {
    var base: [String]
    var folder: String
    var running: String?
    /// Where its tab runs.
    var directory: URL
}

/// Each worktree's stack on its own ports. Before an Up of a checkout's
/// stack, Compose is asked which host ports it would publish; each is looked
/// for among the other stacks' containers and on this Mac. One taken, or a
/// name another checkout's stack has, asks first: Up on Free Ports writes an
/// override into Overterm's folder (`ComposePortStore`) and runs the stack
/// under a name of its own on free ports; every later Up uses it.
extension DockerPageModel {
    /// A compose command for a project, its files as the store says them —
    /// its override after the checkout's, when it has one.
    func composeCommand(_ project: ComposeProject, _ verb: String, services: [String] = [], profiles: [String] = []) -> String {
        ports.command(project, verb, services: services, profiles: profiles, endpoint: docker.endpoint)
    }

    /// A compose command that reads the files, in a tab (Pull, Watch, a
    /// service's Run): once the project's override is as its files are now.
    func runCompose(_ project: ComposeProject, _ verb: String, services: [String] = [], in folder: URL?) {
        withCurrentPorts(project) { [weak self] in
            guard let self else { return }
            self.actions?.run(self.composeCommand(project, verb, services: services), folder)
        }
    }

    /// Once the project's override is written again from its files, when
    /// they changed since (`ComposePortStore.refresh`); at once otherwise.
    func withCurrentPorts(_ project: ComposeProject, _ then: @escaping @MainActor () -> Void) {
        guard ports.needsRefresh(project) else { return then() }
        let endpoint = docker.endpoint
        Task { [weak self] in
            await self?.ports.refresh(for: project, endpoint: endpoint)
            then()
        }
    }

    /// Whether an Up may ask Compose and probe ports: not in an isolated run
    /// without a scenario's stub `docker`, nor in a test process unless a
    /// test asks for it (`checksPortsInTests`, with a stub of its own).
    nonisolated static var mayCheckPorts: Bool {
        if NSClassFromString("XCTestCase") != nil { return checksPortsInTests && DockerCLI.override != nil }
        return DockerCLI.override != nil || !AppEnvironment.isIsolated
    }

    /// A test's own stub answers an Up's questions.
    nonisolated(unsafe) static var checksPortsInTests = false

    /// An Up from a key, a button or a menu: typed at once when there is
    /// nothing to look at, else once the ports have been (`up`).
    func startUp(
        _ target: ComposeUpTarget, options: String = "-d", services: [String] = [], profiles: [String] = [], freePorts: ComposeFreePorts = .ask
    ) {
        let request = UpRequest(options: options, services: services, profiles: profiles, freePorts: freePorts)
        let setup = upSetup(target)
        switch start(target, setup, request) {
        case .now(let run): run()
        case .look(let setup, let kept, let cli): Task { await look(target, setup, kept, cli, request) }
        }
    }

    /// The same, awaited: back once the command is in a tab or the question
    /// is asked.
    func up(
        _ target: ComposeUpTarget, options: String = "-d", services: [String] = [], profiles: [String] = [], freePorts: ComposeFreePorts = .ask
    ) async {
        let request = UpRequest(options: options, services: services, profiles: profiles, freePorts: freePorts)
        switch start(target, upSetup(target), request) {
        case .now(let run): run()
        case .look(let setup, let kept, let cli): await look(target, setup, kept, cli, request)
        }
    }

    /// The checkout's files for an Up: a project's labels' (none of ours,
    /// all on this Mac), a checkout's as Compose finds them. Nil when they
    /// aren't here: the Up is typed as it always was.
    func upSetup(_ target: ComposeUpTarget) -> ComposeUpSetup? {
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
        switch target {
        case .project(let project) where project.planned:
            return project.workingDir.flatMap { checkoutSetup(URL(fileURLWithPath: $0), planned: project) }
        case .project(let project):
            guard let folder = project.workingDir else { return nil }
            let base = project.configFiles.filter { !ports.isOurs($0) }
            guard !base.isEmpty, base.allSatisfy(exists) else { return nil }
            return ComposeUpSetup(base: base, folder: folder, running: project.name, directory: URL(fileURLWithPath: folder))
        case .checkout(let url):
            return checkoutSetup(url)
        }
    }

    /// A checkout's files as Compose finds them, each as Compose takes it
    /// (`ComposeProjects.composePath`). A project run from its folder is
    /// this stack only when it was made from these files, or takes the
    /// plan's place (`ComposeProjects.replaces`): a test stack started
    /// there from others (`-f compose.test.yaml -p shop-test`) is another
    /// stack, whose ports are taken and whose name isn't this one's.
    private func checkoutSetup(_ checkout: URL, planned: ComposeProject? = nil) -> ComposeUpSetup? {
        let files = ComposeProjects.composeFiles(in: checkout)
        guard let first = files.first, files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        let folder = FileTreeModel.realPath(first.deletingLastPathComponent())
        let base = files.map(ComposeProjects.composePath)
        let running = docker.projects.first { project in
            project.workingDir == folder && (madeFrom(project, base) || planned.map { ComposeProjects.replaces(project, $0) } == true)
        }?.name
        return ComposeUpSetup(base: base, folder: folder, running: running, directory: checkout)
    }

    /// Whether a project's containers were made from these files: their
    /// labels' (none of ours), each as Compose takes it.
    private func madeFrom(_ project: ComposeProject, _ base: [String]) -> Bool {
        let files = project.configFiles.filter { !ports.isOurs($0) }.map { ComposeProjects.composePath(URL(fileURLWithPath: $0)) }
        return !files.isEmpty && Set(files) == Set(base)
    }

    /// Why Up on Free Ports can't help a project here; nil when it can. Its
    /// verb and a conflict's button say it; `U` says it and does nothing.
    func freePortsUnavailable(_ project: ComposeProject) -> String? {
        if project.workingDir == nil { return "Compose didn't say where it ran." }
        if upSetup(.project(project)) == nil { return "Its compose files aren't on this Mac." }
        if let version = composeVersion, !ComposePorts.supportsOverride(version: version) {
            return "It needs Docker Compose 2.24.4 or later (its !override tag); this is \(version)."
        }
        return nil
    }

    /// What an Up of a stack said: on the page — and, when the page isn't
    /// on screen (an Up from the panel, the right slot, a menu, New Task),
    /// in an alert too, as the window's own errors are.
    func reportUp(_ message: String, failed: Bool) {
        if failed { error = message } else { cleaned = message }
        if !visible { actions?.alert("Up on Free Ports", message) }
    }

    // MARK: The flow

    struct UpRequest {
        var options: String
        var services: [String]
        var profiles: [String]
        var freePorts: ComposeFreePorts

        var verb: String { "up " + options }
    }

    private enum UpStart {
        case now(() -> Void)
        case look(ComposeUpSetup, ComposePortOverride?, DockerCLI)
    }

    /// What can be decided at once: no files here, the check off with
    /// nothing kept, nothing to ask Compose with. Free ports asked for
    /// with no files here moves nothing: it says why rather than run the
    /// stack into the same ports.
    private func start(_ target: ComposeUpTarget, _ setup: ComposeUpSetup?, _ request: UpRequest) -> UpStart {
        guard let setup else {
            if request.freePorts == .yes { return .now { [weak self] in self?.reportUp(Self.cannotMove(target), failed: true) } }
            return .now { [weak self] in self?.runWritten(target, nil, request, confirmingName: true) }
        }
        let kept = keptOverride(target, setup)
        if request.freePorts == .ask, kept == nil, !Settings.shared.dockerCheckPorts {
            return .now { [weak self] in self?.runWritten(target, setup, request, confirmingName: true) }
        }
        guard Self.mayCheckPorts, let cli = DockerCLI(endpoint: docker.endpoint) else {
            return .now { [weak self] in
                if let kept { self?.run(kept, setup, request) } else { self?.runWritten(target, setup, request, confirmingName: true) }
            }
        }
        return .look(setup, kept, cli)
    }

    private static func cannotMove(_ target: ComposeUpTarget) -> String {
        switch target {
        case .project(let project) where project.workingDir == nil:
            "Up on Free Ports can't move \(project.name)'s ports: Compose didn't say where it ran."
        case .project(let project): "Up on Free Ports can't move \(project.name)'s ports: its compose files aren't on this Mac."
        case .checkout: "Up on Free Ports can't move the stack's ports: the checkout's compose files aren't all there."
        }
    }

    /// A project's own override (by its name); a checkout's, its folder's.
    private func keptOverride(_ target: ComposeUpTarget, _ setup: ComposeUpSetup) -> ComposePortOverride? {
        if case .project(let project) = target, !project.planned { return ports.override(of: project) }
        return ports.override(in: setup.folder)
    }

    private func look(_ target: ComposeUpTarget, _ setup: ComposeUpSetup, _ kept: ComposePortOverride?, _ cli: DockerCLI, _ request: UpRequest) async {
        let version = await composeVersion(cli)
        guard let version, ComposePorts.supportsOverride(version: version) else {
            if let kept {
                // What was chosen stands — its name and its ports, as last
                // written — rather than the files' name taking another
                // checkout's stack over.
                let why = version.map { "this is Docker Compose \($0), and its !override tag needs 2.24.4 or later" } ?? "docker compose version didn't answer"
                reportUp("\(kept.project)'s ports weren't looked at — \(why). It is up with the override kept for it, as last written.", failed: true)
                return run(kept, setup, request)
            }
            if request.freePorts == .yes {
                reportUp(
                    "Up on Free Ports needs Docker Compose 2.24.4 or later — its !override tag; "
                        + (version.map { "this is \($0)." } ?? "docker compose version didn't answer."), failed: true)
            }
            return runWritten(target, setup, request, confirmingName: true)
        }
        var targetName: String?
        if case .project(let project) = target { targetName = project.name }
        // Its row is busy while this looks.
        let tag = (setup.running ?? kept?.project ?? targetName).map(Self.projectTag)
        if let tag { busy.insert(tag) }
        defer { if let tag { busy.remove(tag) } }

        // What the override is written from: the files as Compose read them.
        let stamp = ComposePortStore.stamp(of: setup.base, folder: setup.folder)
        guard let config = await ComposePortStore.readConfig(cli, base: setup.base, folder: setup.folder) else {
            // Compose says what is wrong in the tab.
            if let kept { return run(kept, setup, request) }
            return runWritten(target, setup, request, confirmingName: true)
        }
        // Who holds a port is said only in the question.
        let plan = await portPlan(
            config, setup, running: kept?.project ?? setup.running, request, keep: kept?.moves ?? [],
            namingHolders: kept == nil && request.freePorts == .ask)

        if let kept {
            // Chosen before: the same files, written again from the files as
            // they are now; a port taken since moves again, or goes back to
            // the file's when that is free and its own isn't.
            let said = ComposePorts.changes(from: kept.moves, to: plan.moves, config: config)
            guard plan.changes else {
                // Nothing left to move, and the files' name its own.
                ports.forget(kept.folder)
                reportUp(
                    said.isEmpty
                        ? "\(kept.project) needs no ports of its own any more: Overterm forgot them."
                        : "\(kept.project) is on its compose file's ports again — " + said.joined(separator: "; ") + ".", failed: false)
                return runWritten(target, setup, request, confirmingName: false)
            }
            let refreshed = ComposePortOverride(
                folder: kept.folder, project: kept.project, fileName: config.name, baseFiles: setup.base, moves: plan.moves, made: kept.made,
                stamp: stamp)
            guard save(refreshed, plan, config) else { return }
            if !said.isEmpty { reportUp("\(kept.project): " + said.joined(separator: "; ") + ".", failed: false) }
            return run(refreshed, setup, request)
        }
        if !plan.changes || (request.freePorts == .ask && !plan.needsAsking) {
            if request.freePorts == .yes {
                if let stuck = plan.unmovable.first {
                    reportUp("No free port near \(stuck.port) for \(stuck.service): \(plan.name) is up as written.", failed: true)
                } else {
                    reportUp("Nothing to move: every port \(plan.name) asks for is free.", failed: false)
                }
            }
            return runWritten(target, setup, request, confirmingName: false)
        }
        switch request.freePorts {
        case .yes:
            apply(plan, config, setup, stamp, request)
            if let stuck = plan.unmovable.first { reportUp("No free port near \(stuck.port) for \(stuck.service): it stays as written.", failed: true) }
        case .ask:
            let question = ComposePorts.question(plan)
            actions?.choose(question.title, question.detail, ["Up on Free Ports", "Up as Written"]) { [weak self] chosen in
                guard let self else { return }
                if chosen == 0 {
                    Task { await self.answered(plan, config, setup, stamp, request, target) }
                } else {
                    self.runWritten(target, setup, request, confirmingName: false)
                }
            }
        }
    }

    /// Up on Free Ports, answered — maybe long after the question: the
    /// ports looked at again first, since another window's override may
    /// have given out the same ones meanwhile, and what moved since said.
    private func answered(
        _ asked: ComposePortPlan, _ config: ComposeConfig, _ setup: ComposeUpSetup, _ stamp: [String: String], _ request: UpRequest,
        _ target: ComposeUpTarget
    ) async {
        let plan = await portPlan(config, setup, running: setup.running, request, keep: asked.moves, namingHolders: false)
        guard plan.changes else { return runWritten(target, setup, request, confirmingName: false) }
        let said = ComposePorts.changes(from: asked.moves, to: plan.moves, config: config)
        if !said.isEmpty { reportUp("\(plan.name): " + said.joined(separator: "; ") + ".", failed: false) }
        apply(plan, config, setup, stamp, request)
    }

    /// The override made, kept and used.
    private func apply(_ plan: ComposePortPlan, _ config: ComposeConfig, _ setup: ComposeUpSetup, _ stamp: [String: String], _ request: UpRequest) {
        let made = ComposePortOverride(
            folder: setup.folder, project: plan.name, fileName: config.name, baseFiles: setup.base, moves: plan.moves, made: Date(), stamp: stamp)
        if save(made, plan, config) { run(made, setup, request) }
    }

    /// What the stack would run into now, and where its ports would go:
    /// its name, each port it wants among the other stacks' containers and
    /// on this Mac, the ports other overrides give out. `namingHolders`:
    /// lsof names what holds a port (for the question).
    private func portPlan(
        _ config: ComposeConfig, _ setup: ComposeUpSetup, running: String?, _ request: UpRequest, keep: [ComposePortMove], namingHolders: Bool
    ) async -> ComposePortPlan {
        let folder = setup.folder
        let named = ComposePortPlan.projectName(
            fileName: config.name, folder: folder, running: running, projects: docker.projects, reserved: ports.reservedNames(except: folder))
        let name = named.name
        let containers = docker.containers
        let own: (ContainerSummary) -> Bool = { $0.composeProject == name && $0.composeWorkingDir == folder }
        // A remote engine's ports are its host's: only its containers count.
        let isBound: (Int, String) -> Bool = docker.publishedHost == nil ? { ListeningPorts.isBound($0, proto: $1) } : { _, _ in false }
        var wanted: [ComposePortKey] = []
        for service in config.services {
            for port in service.ports {
                if let host = port.hostPort, !wanted.contains(ComposePortKey(port: host, proto: port.proto)) {
                    wanted.append(ComposePortKey(port: host, proto: port.proto))
                }
            }
        }
        let census = ComposePortCensus.taken(wanted: wanted, containers: containers, own: own, isBound: isBound)
        let taken = namingHolders ? await refine(census) : census
        return ComposePortPlan.make(
            config: config,
            active: ComposePorts.activeProfiles(dotEnv: ComposeProjects.dotEnv(in: URL(fileURLWithPath: folder)), extra: request.profiles),
            taken: taken, isFree: { ComposePortCensus.isFree($0, $1, containers: containers, own: own, isBound: isBound) },
            reserved: ports.reservedPorts(except: folder), keep: keep, name: name, nameHolder: named.holder)
    }

    /// Who an unknown holder is: a process in one of the windows' tabs, or
    /// lsof's (only the user's own processes; another's stays unknown).
    private func refine(_ taken: [ComposePortKey: DockerPortConflict.Holder]) async -> [ComposePortKey: DockerPortConflict.Holder] {
        var refined = taken
        var asking: [ComposePortKey] = []
        for (key, holder) in taken where holder == .unknown {
            if let (id, title, process) = ContainerSession.tabHolding(key.port) {
                refined[key] = .tab(id: id, title: title, process: process)
            } else if key.proto == "tcp" {
                asking.append(key)
            }
        }
        let found = await withTaskGroup(of: (ComposePortKey, ListeningPort?).self) { group in
            for key in asking { group.addTask { (key, await ListeningPorts.holder(of: key.port)) } }
            var found: [ComposePortKey: ListeningPort] = [:]
            for await (key, holder) in group { if let holder { found[key] = holder } }
            return found
        }
        for (key, holder) in found { refined[key] = .process(pid: holder.pid, command: holder.process) }
        return refined
    }

    /// `docker compose version --short`, asked once (an answer is kept).
    func composeVersion(_ cli: DockerCLI) async -> String? {
        if let composeVersion { return composeVersion }
        guard let output = try? await cli.run(["compose", "version", "--short"], timeout: 10) else { return nil }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return nil }
        composeVersion = version
        return version
    }

    private func save(_ override: ComposePortOverride, _ plan: ComposePortPlan, _ config: ComposeConfig) -> Bool {
        do {
            try ports.save(override, yaml: ComposePorts.overrideYAML(plan: plan, config: config, folder: override.folder))
            return true
        } catch {
            reportUp("Up on Free Ports couldn't write its override: \(error.localizedDescription)", failed: true)
            return false
        }
    }

    // MARK: Running it

    /// With the override: the checkout's files, then it, under its name.
    private func run(_ override: ComposePortOverride, _ setup: ComposeUpSetup, _ request: UpRequest) {
        let command = DockerCommands.compose(
            name: override.project, files: setup.base + [ports.file(of: override).path], request.verb, services: request.services,
            profiles: request.profiles, endpoint: docker.endpoint)
        actions?.run(command, setup.directory)
    }

    /// As the files say. A project by its labels with its own files; one
    /// before it runs, or a checkout, in its folder with none — Compose
    /// names it from the files. `confirmingName`: nothing looked at its
    /// name, so one before it runs asks first, as it always has, when a
    /// project of its name runs from another folder.
    private func runWritten(_ target: ComposeUpTarget, _ setup: ComposeUpSetup?, _ request: UpRequest, confirmingName: Bool) {
        let endpoint = docker.endpoint
        switch target {
        case .project(let project) where project.planned:
            let folder = project.workingDir.map { URL(fileURLWithPath: $0) }
            let command = DockerCommands.compose(project, request.verb, services: request.services, profiles: request.profiles, endpoint: endpoint)
            let up: () -> Void = { [weak self] in self?.actions?.run(command, folder) }
            guard confirmingName, let there = runsElsewhere(project) else { return up() }
            actions?.confirm(
                "Up “\(project.name)” from this checkout?",
                "A project of that name runs from \(there). Compose makes it again from this checkout's files and replaces its containers.", "Up", up)
        case .project(let project):
            let command =
                setup.map {
                    DockerCommands.compose(project, request.verb, services: request.services, profiles: request.profiles, endpoint: endpoint, files: $0.base)
                } ?? composeCommand(project, request.verb, services: request.services, profiles: request.profiles)
            actions?.run(command, project.workingDir.map { URL(fileURLWithPath: $0) })
        case .checkout(let url):
            actions?.run(
                DockerCommands.compose(name: nil, files: [], request.verb, services: request.services, profiles: request.profiles, endpoint: endpoint), url)
        }
    }

    /// Where a project of a planned one's name runs, when not from its
    /// checkout: usually another worktree whose file sets `name:`.
    func runsElsewhere(_ project: ComposeProject) -> String? {
        guard let other = docker.projects.first(where: { $0.name == project.name }), let folder = project.workingDir,
            ComposeProjects.projects([other], in: folder).isEmpty
        else { return nil }
        return other.workingDir.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "another folder"
    }

    // MARK: Back to the file's ports

    /// Forgets the project's override, asked first. Its containers keep
    /// their ports until its next Up.
    func confirmForgetPorts(_ project: ComposeProject) {
        guard let kept = ports.override(of: project) else { return }
        actions?.confirm(
            "Back to the compose file's ports?",
            "Overterm forgets \(kept.summary) for \((kept.folder as NSString).abbreviatingWithTildeInPath). Its containers keep them until it is next up; then they ask for the file's ports again.",
            "Forget"
        ) { [weak self] in self?.ports.forget(kept.folder) }
    }
}
