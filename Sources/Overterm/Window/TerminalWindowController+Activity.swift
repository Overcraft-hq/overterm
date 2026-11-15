import AppKit
import Combine

/// The census's view of the app (docs/design/activity/analysis.md, 7.1):
/// which pane is which, as one value the sampler's queue reads whole.
extension TerminalWindowController {
    /// Every window's panes, in each strip's order: the pane's tag, its
    /// tab and window, the `login` it was paired with, the agent its tab
    /// was opened for. A surface still waiting for its `login` is paired
    /// first, from the latest census's children of the app: microseconds,
    /// no scan — as far as what holds now lets it, the list being of any
    /// age (`SurfaceProcesses.pair`). What the later stages add — a pane's
    /// title, its checkout and branch, the forwards, the tunnels — comes
    /// with the stage that reads it, and with what rebuilds it when it
    /// changes.
    static func activityContext(windows: [NSWindow] = NSApp.windows) -> ActivityContext {
        let surfaces = SurfaceProcesses.shared
        if surfaces.hasWaiting, let snapshot = ActivityMonitor.shared.sampler.latest { surfaces.pair(snapshot) }
        var context = ActivityContext()
        for controller in windows.compactMap({ $0.windowController as? TerminalWindowController }) {
            let window = controller.window?.windowNumber
            for tab in controller.store.tabs {
                for pane in tab.terminals {
                    context.panes.append(
                        ActivityContext.Pane(tag: pane.processTag, tab: tab.id, window: window, login: surfaces.login(of: pane), agent: tab.agent))
                }
            }
        }
        return context
    }

    /// The census's context follows this window's tabs and their panes: a
    /// tab opened, closed or moved in, a pane split off or moved between
    /// tabs. Surfaces and pairings say so themselves (`SurfaceProcesses`).
    func watchActivityContext() {
        store.$tabs
            .map { tabs in Publishers.MergeMany(tabs.map { $0.$splits.map { _ in () } }).prepend(()) }
            .switchToLatest()
            .sink { _ in ActivityMonitor.shared.contextChanged() }
            .store(in: &cancellables)
    }

    /// The app's census, wired once at launch: its context from every
    /// window, and each snapshot that lands pairs the surfaces still
    /// waiting for their `login` — the census lists the app's children and
    /// the logins no pane has on its queue, the main actor pairs them
    /// (7.7) — and a pairing made brings the next tick early, so a new
    /// pane's processes are read a quarter of a second later.
    static func wireActivityCensus() -> AnyCancellable {
        let monitor = ActivityMonitor.shared
        monitor.contextSource = { activityContext() }
        // @Published emits before it changes: the emitted value.
        return monitor.$snapshot.compactMap { $0 }
            .sink { snapshot in
                let surfaces = SurfaceProcesses.shared
                guard surfaces.hasWaiting, surfaces.pair(snapshot) else { return }
                ActivityMonitor.shared.surfacesPaired()
            }
    }
}

/// What the census's light tick says of one tab (docs/design/activity/
/// analysis.md, 7.8's agent-poll row): what its processes listen on, each
/// pane's own, and where its agent works. Pure: a value from a snapshot.
struct TabLightRead: Equatable {
    /// Where the tab's agent works.
    enum Agent: Equatable, Sendable {
        /// No agent runs in any pane, or its folder can't be read: nothing
        /// to follow.
        case absent
        /// The first pane's agent, its folder not read yet or its file
        /// system not answering: what the tab follows is kept as it was,
        /// never dropped for a tick.
        case unread
        case folder(String)
    }

    /// Its processes' listening TCP ports — a pane's tree and what carries
    /// its tag outside it — each holder's once, sorted: of those, only what
    /// runs as the user alone holds a pill (`ProcessInspector.running`, as
    /// the poll's `tree()` gave it), since a pill's Kill acts on it — a
    /// setuid program the pane runs, its effective uid the user's for now
    /// and root kept as its saved one, is root's (6.10's never-list).
    var ports: [ListeningPort] = []
    /// The same by pane, the index in the panes asked: a pane's header
    /// says its own, never its neighbour's server.
    var panePorts: [Int: [ListeningPort]] = [:]
    var agent = Agent.absent

    /// `tags`, a tab's panes — the focused one first, so its agent comes
    /// first and a process two panes place is the focused one's — as
    /// `snapshot` read them. A pane the snapshot has for another tab (one
    /// moved since its context was built) isn't this tab's yet.
    static func of(_ tags: [String], tab: UUID, in snapshot: ActivitySnapshot) -> TabLightRead {
        var read = TabLightRead()
        var seen = Set<String>()
        for (index, tag) in tags.enumerated() {
            guard let slice = snapshot.pane(tag), slice.tab == tab else { continue }
            for port in ListeningPorts.of(ProcessInspector.running(slice.placed, in: snapshot), in: snapshot) where seen.insert(port.id).inserted {
                read.ports.append(port)
                read.panePorts[index, default: []].append(port)
            }
        }
        read.agent = agent(tags, tab: tab, in: snapshot)
        read.ports.sort { ($0.port, $0.pid, $0.proto) < ($1.port, $1.pid, $1.proto) }
        return read
    }

    /// Where the tab's agent works, as `snapshot` read `tags`' panes: the
    /// first pane's agent, the focused one first, its folder the one the
    /// census knew at the tick — or `folder`'s answer, a read waited for
    /// (an MCP call's), nil when none came in time.
    static func agent(
        _ tags: [String], tab: UUID, in snapshot: ActivitySnapshot, folder: ((ActivityProcessID) -> ProcessFolders.Folder?)? = nil
    ) -> Agent {
        for tag in tags {
            guard let slice = snapshot.pane(tag), slice.tab == tab, let identity = slice.agent else { continue }
            let known: ProcessFolders.Folder?
            if let folder { known = folder(identity) } else { known = snapshot.facts[identity]?.folder }
            switch known {
            case .path(let path)?: return .folder(path)
            case .unknown?: return .absent
            case .notAnswering?, nil: return .unread
            }
        }
        return .absent
    }
}

/// The light tick (D-5; docs/design/activity/analysis.md, 7.3, 7.8, 7.9):
/// while this window is on screen it wants the census's light level for its
/// own tabs, and every snapshot that read them gives each tab its ports, its
/// panes' ports — so the pills, `TabKind.server`, the browser's empty page,
/// the API client's discovery and Docker's conflicts say what runs now — and
/// where its agent works: every tab, never only the selected one, where the
/// agent poll walked the selected tab every 2 s and ran lsof every 6 s. A
/// minimized or wholly covered window, or one on another Space, gives its
/// want back, and its tabs are read again as it shows. With no window on
/// screen there is no light tick: what must read then (`TerraformPaneMonitor`,
/// the one-off censuses) reads on its own, and the agents of a window off
/// screen are followed on their own (`OffScreenAgents`).
extension TerminalWindowController {
    /// On screen, for the light tick: visible and not wholly covered. An
    /// isolated run stays in the background, often under the user's own
    /// windows: there the window says nothing about the run, and counts as
    /// shown, as Docker's page does — unless a scenario says otherwise.
    var lightTickShown: Bool {
        if let lightTickVisibility { return lightTickVisibility }
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return AppEnvironment.isIsolated || window.occlusionState.contains(.visible)
    }

    /// This window's tabs at the light level while it is on screen, at the
    /// census's interval; given back otherwise. `tabs`: the window's, as a
    /// change of them is emitted — before it is set.
    func updateLightTick(tabs: [Tab]? = nil) {
        defer { OffScreenAgents.shared.update() }
        guard lightTickShown else {
            if lightTickWanted { endLightTick() }
            return
        }
        lightTickWanted = true
        ActivityMonitor.shared.want(self, .light(tabs: Set((tabs ?? store.tabs).map(\.id))))
    }

    /// The window going: its want given back.
    func endLightTick() {
        ActivityMonitor.shared.unwant(self)
        lightTickWanted = false
        OffScreenAgents.shared.update()
    }

    /// Wants what the window's tabs are as they change, and takes every
    /// snapshot that lands — whoever's tick it was.
    func watchLightTick() {
        // @Published emits before it changes: the emitted value.
        store.$tabs
            .sink { [weak self] tabs in self?.updateLightTick(tabs: tabs) }
            .store(in: &cancellables)
        ActivityMonitor.shared.$snapshot.compactMap { $0 }
            .sink { [weak self] snapshot in self?.takeLightTick(snapshot) }
            .store(in: &cancellables)
    }

    /// Each tab `snapshot` read at the light level: its ports, its panes',
    /// where its agent works. Only what changed is set.
    func takeLightTick(_ snapshot: ActivitySnapshot) {
        let tabs = store.tabs
        lightTickAgents = lightTickAgents.filter { entry in tabs.contains { $0.id == entry.key } }
        for tab in tabs where snapshot.covers(ActivityDemand(.light(tabs: [tab.id]))) {
            let panes = Self.focusedFirst(tab)
            let read = TabLightRead.of(panes.map(\.processTag), tab: tab.id, in: snapshot)
            if tab.ports != read.ports { tab.ports = read.ports }
            var byPane: [ObjectIdentifier: [ListeningPort]] = [:]
            for (index, ports) in read.panePorts { byPane[ObjectIdentifier(panes[index])] = ports }
            if tab.panePorts != byPane { tab.panePorts = byPane }
            follow(read.agent, of: tab)
        }
    }

    /// A tab's panes, the focused one first: its agent comes first.
    static func focusedFirst(_ tab: Tab) -> [TerminalView] {
        [tab.terminal] + tab.terminals.filter { $0 !== tab.terminal }
    }

    /// The tab follows where its agent works: nothing where none runs, as
    /// it was while the folder isn't read yet, else the folder when it
    /// isn't the shell's checkout.
    func follow(_ agent: TabLightRead.Agent, of tab: Tab) {
        let following: String?
        switch agent {
        case .absent: following = nil
        case .unread: following = tab.agentDirectory
        case .folder(let folder): following = agentFollowing(folder, of: tab)
        }
        if tab.agentDirectory != following { tab.agentDirectory = following }
    }

    /// The agent's folder, when it differs from the shell's checkout: an
    /// agent in the tab's own folder changes nothing. The checkouts are
    /// looked for on disk only when the folder or the shell's moved.
    private func agentFollowing(_ folder: String, of tab: Tab) -> String? {
        if let known = lightTickAgents[tab.id], known.folder == folder, known.shell == tab.workingDirectory { return known.following }
        let shell = tab.workingDirectory.map { FileTreeModel.treeRoot(for: $0) }
        let following = FileTreeModel.treeRoot(for: folder) == shell ? nil : folder
        lightTickAgents[tab.id] = (folder, tab.workingDirectory, following)
        return following
    }
}

/// Where the agents of windows off screen work (docs/design/activity/
/// analysis.md, 7.1, 7.8, 12's "a guard that starves while hidden"). No light
/// tick reads a window's tabs while it is off screen (D-5, 7.9), yet what
/// follows a tab's agent reads on: the checkout `TerraformPaneMonitor` walks
/// and classes an ask against, the agents' `tf_` and `k8s_` tools, an MCP
/// confirmation's line, Docker's and Kubernetes' marks by checkout — and agents
/// work exactly while the person looks elsewhere. The poll it replaced kept
/// the selected tab's agent folder current every 2 s, window on screen or
/// not. So every 2 s, while a window is off screen, the tabs of those windows
/// where an agent may work — opened for one, a command running in a pane, an
/// agent's folder followed (`agentMayWork`) — have their agents' folders read:
/// one lookup in the app's census at the light level of those tabs alone,
/// their ports left for the window to read as it shows. A tab at its prompt,
/// with none of those, isn't read, as `TerraformPaneMonitor` doesn't walk one.
@MainActor
final class OffScreenAgents {
    static let shared = OffScreenAgents()
    static let interval: Duration = .seconds(2)

    private var loop: Task<Void, Never>?
    /// Rounds that read a tab (a scenario's count).
    private(set) var reads = 0

    var isFollowing: Bool { loop != nil }

    /// A window came on screen or left it, or went: the rounds run while
    /// any window is off screen.
    func update() {
        let offScreen = Self.windows().contains { !$0.lightTickShown }
        if offScreen, loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.interval)
                    guard let self, !Task.isCancelled, await self.round() else { break }
                }
            }
        } else if !offScreen, let loop {
            loop.cancel()
            self.loop = nil
        }
    }

    /// One round; false once no window is off screen.
    private func round() async -> Bool {
        let hidden = Self.windows().filter { !$0.lightTickShown }
        guard !hidden.isEmpty else {
            loop = nil
            return false
        }
        var tabs: [(TerminalWindowController, Tab)] = []
        for window in hidden {
            for tab in window.store.tabs where window.agentMayWork(in: tab) { tabs.append((window, tab)) }
        }
        guard !tabs.isEmpty else { return true }
        reads += 1
        await TerminalWindowController.followAgents(tabs)
        return true
    }

    /// Every terminal window's; none before the app is up (a unit test).
    private static func windows() -> [TerminalWindowController] {
        ((NSApp as NSApplication?)?.windows ?? []).compactMap { $0.windowController as? TerminalWindowController }
    }
}

extension TerminalWindowController {
    /// Whether an agent may be working in `tab`: it was opened for one, a
    /// command runs in one of its panes (an agent typed there), or it
    /// follows an agent's folder already — which goes when the agent does.
    func agentMayWork(in tab: Tab) -> Bool {
        tab.agent != nil || tab.agentDirectory != nil || tab.terminals.contains { blocks(of: $0).ledger.running != nil }
    }

    /// Where these tabs' agents work, read now — one lookup in the app's
    /// census at the light level of these tabs alone, on a GCD thread (7.7)
    /// — and followed by the light tick's rule: what a window off screen has
    /// instead of the light tick (`OffScreenAgents`). Their ports aren't
    /// taken: the window reads them again as it shows. A tab whose window
    /// came on screen meanwhile is the light tick's again. `fresh`, an MCP
    /// call's: the lookup ticks now, and each agent's folder is a read begun
    /// since the call, waited for (`ProcessFolders.folder(readSince:of:)`,
    /// 200 ms at most), never the one known while a read goes on — the
    /// freshest there is, taken whichever window shows.
    static func followAgents(_ tabs: [(TerminalWindowController, Tab)], fresh: Bool = false) async {
        guard !tabs.isEmpty else { return }
        // The lookup reads the context the monitor last built: a rebuild
        // waiting is made now, so a tab opened since has its panes in it.
        ActivityMonitor.shared.flushContext()
        let asked = tabs.map { _, tab in (id: tab.id, tags: focusedFirst(tab).map(\.processTag)) }
        guard let (snapshot, agents) = await agentsNow(asked, fresh: fresh) else { return }
        // A pairing the snapshot brings, as a landing tick's does (7.7).
        let surfaces = SurfaceProcesses.shared
        if surfaces.hasWaiting, surfaces.pair(snapshot) { ActivityMonitor.shared.surfacesPaired() }
        for (window, tab) in tabs where fresh || !window.lightTickShown {
            if let agent = agents[tab.id] { window.follow(agent, of: tab) }
        }
    }

    /// The lookup and the agents it read, off the main thread: a GCD
    /// thread's, never a blocked Swift-concurrency thread's (7.7).
    private nonisolated static func agentsNow(_ tabs: [(id: UUID, tags: [String])], fresh: Bool) async -> (
        ActivitySnapshot, [UUID: TabLightRead.Agent]
    )? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let census = ActivitySampler.app
                let since = census.kernel.uptime()
                let demand = ActivityDemand(.light(tabs: Set(tabs.map(\.id))))
                // Unpaced: a window off screen's app may be napped, and
                // its slow ticks would keep the cadence stretched after.
                guard
                    let snapshot = census.lookup(
                        within: fresh ? 0 : ProcessInspector.freshness, demand: demand, context: census.appContext, paced: false,
                        answers: { $0.covers(demand) })
                else { return continuation.resume(returning: nil) }
                var agents: [UUID: TabLightRead.Agent] = [:]
                for tab in tabs {
                    agents[tab.id] = TabLightRead.agent(
                        tab.tags, tab: tab.id, in: snapshot, folder: fresh ? { census.folders.folder(readSince: since, of: $0) } : nil)
                }
                continuation.resume(returning: (snapshot, agents))
            }
        }
    }

    /// The checkout pane `tag` works in, for an agent's MCP call — the
    /// `tf_` and `k8s_` tools' scope, an MCP confirmation's line: its tab's,
    /// `Tab.checkoutSource`, in any window. While that window is off screen
    /// no light tick reads its tabs (7.9), and agents ask exactly while the
    /// person looks elsewhere (7.1): its agent's folder is read again first
    /// and waited for (`followAgents(fresh:)`), so an agent that moved into
    /// a worktree is scoped to it at its first call. Nil for a pane no
    /// window has.
    static func paneCheckout(_ tag: String) async -> URL? {
        guard let (window, tab) = locate(pane: tag) else { return nil }
        if !window.lightTickShown { await followAgents([(window, tab)], fresh: true) }
        return tab.checkoutSource?.root
    }

    /// The same, as the tab says it now, read again by nothing: what a
    /// call's helpers ask once its start has read it (`KubeMCP.paneFollow`).
    static func knownCheckout(ofPane tag: String) -> URL? {
        locate(pane: tag)?.1.checkoutSource?.root
    }

    /// The window and the tab of pane `tag`, over every pane of every tab
    /// (`tab.terminals`) of every window.
    static func locate(pane tag: String) -> (TerminalWindowController, Tab)? {
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            if let tab = controller.store.tabs.first(where: { $0.terminals.contains { $0.processTag == tag } }) { return (controller, tab) }
        }
        return nil
    }
}
