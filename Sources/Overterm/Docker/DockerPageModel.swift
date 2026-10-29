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
    /// A container's or a volume's file, in the editor — saved back where
    /// it came from.
    var openFile: (DockerFileSource, String) -> Void = { _, _ in }
    /// A container's or a volume's file, to the Mac.
    var downloadFile: (DockerFileSource, String) -> Void = { _, _ in }
    /// A tab of the window, brought up.
    var showTab: (UUID) -> Void = { _ in }
    /// A file on the Mac, in the editor.
    var edit: (URL) -> Void = { _ in }
    /// A copy made to be read, in the editor; removed when its tab closes.
    var showCopy: (URL) -> Void = { _ in }
    /// Where to save something: a suggested name, then the place.
    var pickSave: (String, @escaping (URL) -> Void) -> Void = { _, _ in }
    /// A file to read: then the file.
    var pickOpen: (@escaping (URL) -> Void) -> Void = { _ in }
    /// Files and folders of the Mac to copy in, several at once: what the
    /// panel says, then them (Copy Here…).
    var pickFiles: (_ message: String, _ then: @escaping ([URL]) -> Void) -> Void = { _, _ in }
    /// A name asked for: title, what it is for, the first guess, then it.
    var askName: (String, String, String, @escaping (String) -> Void) -> Void = { _, _, _, _ in }
    /// Asks — what, why, the buttons' words (Cancel is added) — then the
    /// index of the one chosen; nothing when cancelled.
    var choose: (_ title: String, _ detail: String, _ buttons: [String], _ then: @escaping (Int) -> Void) -> Void = { _, _, _, _ in }
    /// An Up of a checkout's stack through the page (`DockerPageModel.up`):
    /// from the panel, a container's conflict.
    var composeUp: (ComposeUpTarget, ComposeFreePorts) -> Void = { _, _ in }
    /// Why Up on Free Ports can't help a project here, nil when it can
    /// (`DockerPageModel.freePortsUnavailable`): a conflict's button says it.
    var freePortsUnavailable: (ComposeProject) -> String? = { _ in nil }
    /// Said in an alert — what, then why: what the page would say, when
    /// the page isn't on screen.
    var alert: (_ title: String, _ detail: String) -> Void = { _, _ in }
    /// The Ask Agent sheet, on why a container failed or on lines of a log.
    var askAgent: (DockerAgentQuestion) -> Void = { _ in }
}

/// One block of the containers list: a compose project with its
/// containers, a Testcontainers run with its, or the containers in none
/// (both nil).
struct DockerListGroup: Identifiable, Equatable {
    var project: ComposeProject?
    var containers: [ContainerSummary]
    /// A project before it runs: its services' rows, since it has no
    /// containers.
    var services: [ComposeService] = []
    /// A test run's block (`project` nil).
    var session: TestcontainersSession? = nil

    var id: String {
        if let session { return DockerPageModel.sessionTag(session.id) }
        return project.map { DockerPageModel.projectTag($0.name) } ?? DockerPageModel.looseTag
    }
}

/// The containers list's order: by name (projects, then the rest), or the
/// busiest first.
enum DockerListSort: String, CaseIterable, Sendable {
    case name, cpu, memory

    /// The order after a click on `column`'s name in the header: by it,
    /// the busiest first; clicked again, or Name, back by name.
    func clicked(_ column: DockerListSort) -> DockerListSort { column == self ? .name : column }

    func value(_ usage: DockerUsage) -> Double {
        switch self {
        case .name: 0
        case .cpu: usage.cpuPercent
        case .memory: Double(usage.memoryBytes)
        }
    }
}

/// A window's Docker page: which section, what the filter says, what is
/// selected, which projects are folded. The containers are the app's
/// (`DockerModel`).
@MainActor
final class DockerPageModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case containers, images, volumes, networks, builds, models

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .containers: "shippingbox"
            case .images: "square.stack.3d.down.right"
            case .volumes: "externaldrive"
            case .networks: "point.3.filled.connected.trianglepath.dotted"
            case .builds: "hammer"
            case .models: "cpu"
            }
        }

        /// What the model reads for it.
        var resource: DockerModel.Resource? {
            switch self {
            case .containers: nil
            case .images: .images
            case .volumes: .volumes
            case .networks: .networks
            case .builds, .models: nil
            }
        }
    }

    @Published var section: Section = .containers
    @Published var filter = ""
    /// Stopped containers hidden.
    @Published var runningOnly = false
    /// Container ids, `project:<name>` for a project's own row,
    /// `service:<project>/<name>` for a service of one before it runs, and
    /// `testcontainers:<session>` for a test run's row.
    @Published var selection: Set<String> = []
    /// The blocks folded: a test run's is, the first time it shows
    /// (`folding`).
    @Published var collapsed: Set<String> = []
    /// The test runs listed so far, by tag: one not seen before is folded.
    private var seenSessions: Set<String> = []
    private var foldingRuns: AnyCancellable?
    /// What the last action said when it failed, until dismissed.
    @Published var error: String?
    /// Containers (and projects) with an action on its way.
    @Published var busy: Set<String> = []
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
    /// The Settings sheet, open on this.
    @Published var containerSettings: DockerContainerSettings?
    /// Docker Model Runner's: where it is, then what it has — nil while
    /// it isn't answering (`loadModels`).
    @Published var modelsPlace: ModelRunner.Place?
    @Published var models: ModelRunner.Contents?
    @Published var modelsError: String?
    @Published var modelSelection: Set<String> = []
    /// Claude Code and Codex as Docker's MCP Toolkit sees them, read each
    /// time the page shows; nil without the Toolkit.
    @Published var mcpClients: [MCPToolkitClient]?
    /// Whether `docker scout` is there, for the images' menu.
    lazy var hasScout = DockerCLI.hasPlugin("scout")
    /// What each project's files say, by its name (`ComposeFacts`): read
    /// when something on screen draws its verbs, again when its files
    /// change (`DockerPageModel+Compose`).
    @Published var composeFacts: [String: ComposeFacts] = [:]
    /// The reads on their way, by project name, with the files' stamp each
    /// was asked for.
    var composeFactReads: [String: (stamp: ComposeFacts.Stamp, task: Task<ComposeFacts?, Never>)] = [:]
    /// Up With Profiles…, open on this.
    @Published var profileChoice: ComposeProfileChoice?
    /// The profiles last ticked for each project, this run only.
    var lastProfiles: [String: Set<String>] = [:]
    /// The checkouts whose stacks run on ports of their own.
    let ports: ComposePortStore
    /// What `docker compose version --short` said, once it has.
    var composeVersion: String?
    /// The containers list's order, this window's, this run's.
    @Published var sort: DockerListSort = .name
    /// The monitor's values (`DockerModel.usage`), while this page's
    /// Containers section shows — empty otherwise, so a hidden page in
    /// another window draws nothing again for them.
    @Published private(set) var usage: [String: DockerUsage] = [:]
    private var wantsUsage = false
    private var usageFeed: AnyCancellable?

    let docker: DockerModel

    private var streams: AnyCancellable?
    private var volumeStreams: AnyCancellable?
    private var wanting: AnyCancellable?
    private var usageWanting: AnyCancellable?
    private var showing: AnyCancellable?
    /// The resource this page holds the model to (`DockerModel.want`).
    private var wanted: DockerModel.Resource?

    init(docker: DockerModel = .shared, ports: ComposePortStore = .shared) {
        self.docker = docker
        self.ports = ports
        // A section on screen is read, and kept current, while it shows.
        wanting = $section.combineLatest($visible)
            .sink { [weak self] section, visible in
                DispatchQueue.main.async {
                    self?.want(visible ? section.resource : nil)
                    if visible, section == .builds { self?.loadBuilds() }
                    if visible, section == .models { self?.loadModels() }
                }
            }
        // The list's CPU and memory: only while someone can see them.
        usageWanting = $section.combineLatest($visible, $windowVisible)
            .sink { [weak self] section, visible, windowVisible in
                DispatchQueue.main.async { self?.wantUsage(visible && windowVisible && section == .containers) }
            }
        showing = $visible.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.loadMCPToolkit() } }
        // The detail's streams follow what it shows and whether it shows.
        streams = Publishers.CombineLatest4($selection, $detailTab, $visible, $showDetail)
            .combineLatest($projectTab)
            .sink { [weak self] _ in
                // @Published fires before the values land.
                DispatchQueue.main.async { self?.updateStreams() }
            }
        // A volume's Files tab: its helper runs only while the tab shows —
        // and its volume is listed, as the detail is drawn only then.
        volumeStreams = Publishers.CombineLatest4($volumeSelection, $volumeTab, $visible, $showDetail)
            .combineLatest($section, docker.$volumes.map { $0.map(\.Name) }.removeDuplicates())
            .sink { [weak self] _ in
                // @Published fires before the values land.
                DispatchQueue.main.async { self?.updateVolumeFiles() }
            }
        // A test run folded as it first shows: at once, with the emitted
        // runs (@Published fires before they land) — a turn later, it
        // would show unfolded for a frame.
        foldingRuns = docker.$testcontainers.sink { [weak self] sessions in
            guard let self else { return }
            let (collapsed, seen) = Self.folding(self.collapsed, seen: self.seenSessions, sessions: sessions)
            self.seenSessions = seen
            if collapsed != self.collapsed { self.collapsed = collapsed }
        }
    }

    /// The folds after a list of runs: one not seen before folded, one gone
    /// forgotten, one the user unfolded left so; projects' untouched. Pure.
    nonisolated static func folding(
        _ collapsed: Set<String>, seen: Set<String>, sessions: [TestcontainersSession]
    ) -> (collapsed: Set<String>, seen: Set<String>) {
        let tags = Set(sessions.map { sessionTag($0.id) })
        var collapsed = collapsed
        collapsed.formUnion(tags.subtracting(seen))
        collapsed.subtract(seen.subtracting(tags))
        return (collapsed, tags)
    }

    private func want(_ resource: DockerModel.Resource?) {
        guard resource != wanted else { return }
        if let wanted { docker.unwant(wanted) }
        wanted = resource
        if let resource { docker.want(resource) }
        // Their sizes on the left, whichever section shows.
        if visible, docker.diskUsage == nil { docker.load(.volumes) }
    }

    /// The list's CPU and memory, read while its section shows.
    private func wantUsage(_ wants: Bool) {
        guard wants != wantsUsage else { return }
        wantsUsage = wants
        if wants {
            docker.usage.want()
            // The emitted value: @Published fires before it lands.
            usageFeed = docker.usage.$byContainer.sink { [weak self] in self?.usage = $0 }
        } else {
            usageFeed = nil
            docker.usage.unwant()
            if !usage.isEmpty { usage = [:] }
        }
    }

    /// Its window closes: everything it reads stops now, not at the sinks'
    /// next turn of the run loop, which may find the page gone — and the
    /// monitor wanted for good.
    func close() {
        visible = false
        want(nil)
        wantUsage(false)
        updateStreams()
        closeVolumeFiles()
    }

    /// What a container uses now, while it runs or is paused.
    func usage(of container: ContainerSummary) -> DockerUsage? { container.state.hasStats ? usage[container.Id] : nil }

    /// A block's: its containers' added up.
    func usage(of group: DockerListGroup) -> DockerUsage? { DockerUsage.sum(group.containers.compactMap { usage(of: $0) }) }

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

    /// The one project the detail shows: the selection, if it is one (or
    /// a service of one before it runs).
    var detailedProject: ComposeProject? {
        guard selection.count == 1, let tag = selection.first, let name = Self.project(of: tag) ?? Self.service(of: tag)?.project else { return nil }
        return project(named: name)
    }

    /// The window's: the selected tab's checkout's compose project before
    /// it runs, which the panel shows too.
    var checkoutCompose: ComposeFileModel?

    /// That project, listed among the others until one of its name exists —
    /// from this checkout or another folder: the list has one row a name —
    /// or one made from its files under another name.
    var planned: ComposeProject? {
        guard let plan = checkoutCompose?.project, !docker.projects.contains(where: { ComposeProjects.replaces($0, plan) }) else { return nil }
        return plan
    }

    /// Nothing for the list to show: no container, and no project before it
    /// runs that it would list (Running only leaves that out).
    var isEmpty: Bool { docker.containers.isEmpty && (planned == nil || runningOnly) }

    /// A project by name: the labels' one, else the one before it runs.
    func project(named name: String) -> ComposeProject? {
        docker.projects.first { $0.name == name } ?? planned.flatMap { $0.name == name ? $0 : nil }
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
    /// A service row of a project before it runs.
    nonisolated static func serviceTag(_ service: ComposeService) -> String { "service:" + service.id }
    nonisolated static func service(of tag: String) -> (project: String, service: String)? {
        guard tag.hasPrefix("service:") else { return nil }
        let id = tag.dropFirst("service:".count)
        guard let slash = id.firstIndex(of: "/") else { return nil }
        return (String(id[..<slash]), String(id[id.index(after: slash)...]))
    }
    /// A Testcontainers run's row, by its session ("" for those in none).
    nonisolated static func sessionTag(_ id: String) -> String { "testcontainers:" + id }
    nonisolated static func session(of tag: String) -> String? {
        tag.hasPrefix("testcontainers:") ? String(tag.dropFirst("testcontainers:".count)) : nil
    }

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
    /// Whether its window is on screen at all — not under another app's,
    /// minimized or hidden (its occlusion, which the window says). The
    /// list's CPU and memory heed it: read every few seconds, they aren't
    /// read for nobody.
    @Published var windowVisible = true

    /// The list as shown: projects first, by name, then the rest, then
    /// Testcontainers' runs, newest first; the filter applied; a block kept
    /// while any of its containers matches. `planned`, the checkout's
    /// project before it runs, is among them until one of its name exists;
    /// nothing of it runs, so Running only leaves it out. By CPU or memory,
    /// the busiest first (`sorted`).
    nonisolated static func groups(
        projects: [ComposeProject], planned: ComposeProject? = nil, loose: [ContainerSummary], sessions: [TestcontainersSession] = [],
        filter: DockerFilter, runningOnly: Bool, sort: DockerListSort = .name, usage: [String: DockerUsage] = [:]
    ) -> [DockerListGroup] {
        func shown(_ containers: [ContainerSummary]) -> [ContainerSummary] {
            containers.filter { (!runningOnly || $0.state.isUp) && filter.matches($0) }
        }
        var groups = projects.compactMap { project -> DockerListGroup? in
            let containers = shown(project.services.flatMap(\.containers))
            return containers.isEmpty ? nil : DockerListGroup(project: project, containers: containers)
        }
        if let planned, !runningOnly, !projects.contains(where: { ComposeProjects.replaces($0, planned) }) {
            let services = planned.services.filter(filter.matches)
            if !services.isEmpty {
                let at = groups.firstIndex { ($0.project?.name ?? "") > planned.name } ?? groups.count
                groups.insert(DockerListGroup(project: planned, containers: [], services: services), at: at)
            }
        }
        let rest = shown(loose)
        if !rest.isEmpty { groups.append(DockerListGroup(project: nil, containers: rest)) }
        for session in sessions {
            let containers = shown(session.containers)
            if !containers.isEmpty { groups.append(DockerListGroup(project: nil, containers: containers, session: session)) }
        }
        return sort == .name ? groups : sorted(groups, by: sort, usage: usage)
    }

    /// The busiest first: each block's containers by what they use, those
    /// with nothing read (stopped, or not read yet) after them in the order
    /// they came; then the blocks by what theirs add up to — "Other
    /// containers" among them like any project.
    nonisolated static func sorted(_ groups: [DockerListGroup], by sort: DockerListSort, usage: [String: DockerUsage]) -> [DockerListGroup] {
        func value(_ container: ContainerSummary) -> Double? { container.state.hasStats ? usage[container.Id].map(sort.value) : nil }
        let ordered = groups.map { group -> (group: DockerListGroup, total: Double) in
            var group = group
            let values = group.containers.map(value)
            group.containers = zip(group.containers, values).enumerated()
                .sorted { a, b in
                    switch (a.element.1, b.element.1) {
                    case (let x?, let y?) where x != y: x > y
                    case (.some, nil): true
                    case (nil, .some): false
                    default: a.offset < b.offset
                    }
                }
                .map { $0.element.0 }
            return (group, values.compactMap { $0 }.reduce(0, +))
        }
        return ordered.enumerated()
            .sorted { a, b in a.element.total != b.element.total ? a.element.total > b.element.total : a.offset < b.offset }
            .map { $0.element.group }
    }

    var groups: [DockerListGroup] {
        Self.groups(
            projects: docker.projects, planned: planned, loose: docker.loose, sessions: docker.testcontainers, filter: DockerFilter(filter),
            runningOnly: runningOnly, sort: sort, usage: usage)
    }

    /// The rows as the keyboard walks them: a project's row, then its
    /// containers unless folded.
    var rows: [String] {
        groups.flatMap { group in
            [group.id] + (collapsed.contains(group.id) ? [] : group.containers.map(\.Id) + group.services.map(Self.serviceTag))
        }
    }

    /// The containers the selection means: a project's row stands for all
    /// of its containers, a test run's for its own — not Ryuk, which still
    /// removes them when the run ends.
    var selectedContainers: [ContainerSummary] {
        var seen = Set<String>()
        var result: [ContainerSummary] = []
        for tag in selection {
            let members: [ContainerSummary] =
                if let name = Self.project(of: tag) {
                    docker.projects.first { $0.name == name }?.containers.filter { !$0.isOneOff } ?? []
                } else if Self.service(of: tag) != nil {
                    []
                } else if let id = Self.session(of: tag) {
                    docker.testcontainers.first { $0.id == id }?.members ?? []
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
        guard selection.count == 1, let tag = selection.first, Self.project(of: tag) == nil, Self.service(of: tag) == nil, Self.session(of: tag) == nil
        else { return nil }
        return docker.container(tag)
    }

    /// The one test run the detail shows: the selection, if it is its row.
    var detailedSession: TestcontainersSession? {
        guard selection.count == 1, let tag = selection.first, let id = Self.session(of: tag) else { return nil }
        return docker.testcontainers.first { $0.id == id }
    }

    /// The project the selection is in, when it is all in one.
    var selectedProject: ComposeProject? {
        let names = Set(
            selection.compactMap { tag in Self.project(of: tag) ?? Self.service(of: tag)?.project ?? docker.container(tag)?.composeProject })
        guard names.count == 1, let name = names.first else { return nil }
        return project(named: name)
    }

    /// The detail's session: one at a time, the last one closed.
    private(set) var session: ContainerSession?

    /// A volume's detail's tab, kept from one volume to the next.
    @Published var volumeTab: VolumeTab = .overview
    /// The selected volume's Files tab: one at a time, the last one closed.
    /// Made and followed by `updateVolumeFiles` alone — the view only
    /// reads it, so none is made that nothing shows.
    @Published private(set) var volumeFiles: VolumeFilesSession?
    /// Volumes being removed (Remove, Clean Up): their Files tab makes no
    /// helper meanwhile, which would hold them again.
    var removingVolumes: Set<String> = []

    private func volumeFiles(for name: String) -> VolumeFilesSession {
        if let volumeFiles, volumeFiles.volume == name { return volumeFiles }
        volumeFiles?.close()
        let made = VolumeFilesSession(volume: name, docker: docker)
        volumeFiles = made
        return made
    }

    /// The session gone: its helper's removal, for a caller that must wait
    /// till the volume is free.
    @discardableResult
    func closeVolumeFiles() -> Task<Void, Never>? {
        guard let volumeFiles else { return nil }
        self.volumeFiles = nil
        return volumeFiles.close()
    }

    /// Its helper runs while the Files tab is on screen; hidden, the
    /// session keeps its folder for when it shows again. Another volume,
    /// or another section, forgets it. A volume the list no longer has
    /// (pruned, removed in a terminal) shows no detail, so no helper:
    /// bound by its name, one would make the volume again.
    func updateVolumeFiles() {
        guard section == .volumes, volumeSelection.count == 1, let name = volumeSelection.first else {
            closeVolumeFiles()
            return
        }
        let listed = docker.volumes.contains { $0.Name == name } && !removingVolumes.contains(name)
        if visible && showDetail && volumeTab == .files && listed {
            volumeFiles(for: name).follow(shown: true)
        } else if let volumeFiles, volumeFiles.volume == name {
            volumeFiles.follow(shown: false)
        } else {
            closeVolumeFiles()
        }
    }

    /// Browse Files: the page on the volume's Files tab.
    func browseFiles(of volume: VolumeSummary) {
        if !visible { actions?.openPage() }
        section = .volumes
        volumeSelection = [volume.Name]
        showDetail = true
        volumeTab = .files
    }

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

    /// What is wrong with it (`DockerAttention.trouble`): its summary, and
    /// the inspect already read — given, or the detail's own. Nothing is
    /// read for it.
    func trouble(of container: ContainerSummary, detail: ContainerDetail? = nil) -> DockerAttention.Trouble? {
        let known = [detail, session?.detail].first { $0?.Id == container.Id } ?? nil
        return DockerAttention.trouble(of: container, detail: known)
    }

    /// Ask an Agent Why…: the window reads it, then opens the sheet.
    func askWhy(_ container: ContainerSummary) { actions?.askAgent(.failure(container)) }

    /// `a`, and ⌘L while the page shows: the first selected container that
    /// failed. False when none did.
    func askWhySelected() -> Bool {
        guard section == .containers, let failed = selectedContainers.first(where: { trouble(of: $0) != nil }) else { return false }
        askWhy(failed)
        return true
    }

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
        case .run where section == .models:
            for model in selectedModels.prefix(1) { runModel(model) }
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
        case .files:
            showDetail = true
            detailTab = .files
        case .toggleDetail: showDetail.toggle()
        case .startStop: startOrStop()
        case .restart: restart()
        case .askAgent: if !askWhySelected() { NSSound.beep() }
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
        case .client:
            let client = selected.first { $0.state == .running && (clientKind(of: $0) != nil || DockerClient.listsImageByID($0)) }
            if let client { openClient(client) }
        case .open:
            if let url = selected.compactMap({ docker.ports(of: $0).first?.url }).first { actions?.open(url) }
        case .database:
            if let container = selected.first { openInDatabase(container) }
        case .settings:
            // As its verb: not for one Docker is removing.
            if let container = detailed ?? selected.first, let verb = verbs(for: container).first(where: { $0.key == DockerKey.settings.key }),
                verb.unavailable == nil
            {
                verb.perform()
            }
        case .remove:
            // A run's row: all of it, as Ryuk would remove it.
            if let session = detailedSession { confirmRemove(session: session) } else { confirmRemove(selected) }
        case .composeUp:
            if let project = selectedProject { compose("up", project) }
        case .composeUpFreePorts:
            // As its verb: when it can't help, it says why and does nothing.
            if let project = selectedProject {
                if let why = freePortsUnavailable(project) { error = "Up on Free Ports: " + why } else { startUp(.project(project), freePorts: .yes) }
            }
        case .composeDown:
            if let project = selectedProject { compose("down", project) }
        case .rebuild: rebuild(Self.rebuilds(of: selection, in: docker.projects))
        case .watch:
            if let project = selectedProject { startWatch(project) }
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
            case .models: confirmRemove(models: selectedModels)
            case .containers: break
            }
            return true
        case .toggleDetail:
            showDetail.toggle()
            return true
        case .files where section == .volumes:
            showDetail = true
            volumeTab = .files
            return true
        default:
            return false
        }
    }

    /// A project's verbs: `up` (its ports looked at first, `startUp`),
    /// `down` (asked first), `watch` and the logs in a terminal tab;
    /// `start`, `stop`, `restart` on its containers here.
    func compose(_ verb: String, _ project: ComposeProject) {
        let lasting = project.containers.filter { !$0.isOneOff }
        let folder = project.workingDir.map { URL(fileURLWithPath: $0) }
        let endpoint = docker.endpoint
        if project.planned { return composePlanned(verb, project, in: folder) }
        switch verb {
        case "up": startUp(.project(project))
        case "logs": runCompose(project, "logs -f --tail 100", in: folder)
        case "watch": runCompose(project, "watch", in: folder)
        case "pull": runCompose(project, "pull", in: folder)
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

    /// A project before it runs: only `up`, `watch` (which ups it first)
    /// and `pull`, in its folder and without `-p`, so Compose reads its
    /// files as it did for the list — or, when its checkout has ports of
    /// its own, under that name with that override. Up looks at its ports
    /// and its name first (`startUp`); Watch asks when a project of its
    /// name runs from another folder: Compose would make that one again
    /// from this checkout's files.
    private func composePlanned(_ verb: String, _ project: ComposeProject, in folder: URL?) {
        switch verb {
        case "up": startUp(.project(project))
        case "watch":
            let watch: () -> Void = { [weak self] in self?.runCompose(project, "watch", in: folder) }
            guard ports.override(of: project) == nil, let there = runsElsewhere(project) else { return watch() }
            actions?.confirm(
                "Watch “\(project.name)” from this checkout?",
                "A project of that name runs from \(there). Compose makes it again from this checkout's files and replaces its containers.", "Watch",
                watch)
        case "pull": runCompose(project, "pull", in: folder)
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
