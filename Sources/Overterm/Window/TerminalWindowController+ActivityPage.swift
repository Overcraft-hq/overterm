import AppKit
import SwiftUI

/// The Activity page (⌥⌘A; docs/design/activity/analysis.md, 6.2, 6.4, 7.9),
/// as the window wires it: a page over the body like Docker's, read only
/// while it is the page on screen in a window that shows.
extension TerminalWindowController {
    func activityWorkspacePage() -> WorkspacePage {
        var page = WorkspacePage(.activity)
        // Made the first time it opens.
        page.makeView = { [weak self] in
            guard let self, let theme = self.theme else { return nil }
            return NSHostingView(
                rootView: ActivityPageView(
                    page: self.activityPage, theme: theme,
                    copy: { lines in
                        guard !lines.isEmpty else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    }))
        }
        // The emitted value: `showingOverlay` isn't set yet.
        page.visibilityChanged = { [weak self] visible in self?.activityPage.visible = visible }
        page.closed = { [weak self] in self?.activityPage.close() }
        page.hasList = true
        page.press = { [weak self] characters in self?.activityPage.press(characters) ?? false }
        page.paletteItems = { [weak self] in self?.activityPaletteItems() ?? [] }
        page.occlusionChanged = { [weak self] in self?.updateActivityWindowVisible() }
        page.windowClosing = { [weak self] in self?.activityPage.close() }
        return page
    }

    /// The page declared; the Where column's titles from every window.
    func wireActivityPage() {
        declarePage(activityWorkspacePage())
        activityPage.tabTitles = { Self.activityTabTitles() }
        activityPage.tabFacts = { Self.activityTabFacts() }
        activityPage.currentTab = { [weak self] in self?.store.selected?.id }
        activityPage.runningApps = { Self.activityRunningApps() }
        activityPage.containers = { Self.activityContainers() }
        activityPage.contextFacts = { context in Self.activityContextFacts(&context) }
        let docker = ActivityDockerHold()
        activityPage.wantContainers = { wanted in
            // While Processes shows: Docker's model watched — its running
            // containers listed under their checkouts, their published ports
            // rule 6's — and the usage monitor's own cost, one Engine call a
            // container a round; nothing otherwise (6.5).
            if wanted {
                DockerModel.shared.usage.want()
                if Settings.shared.dockerEnabled, !docker.shown {
                    docker.shown = true
                    DockerModel.shared.show()
                }
            } else {
                DockerModel.shared.usage.unwant()
                if docker.shown {
                    docker.shown = false
                    DockerModel.shared.hide()
                }
            }
        }
        activitySwitcher.tabTitles = { Self.activityTabTitles() }
        activitySwitcher.stocked = { [weak self] in self?.restockPalette() }
        // The switcher holds while the palette shows its tab, however it got
        // there — ⌃⌘A or ⇥ — and lets go when ⇥ leaves it. The emitted
        // value: `scope` isn't set yet.
        palette.$scope
            .dropFirst()
            .sink { [weak self] scope in self?.activityScopeChanged(scope) }
            .store(in: &cancellables)
        activityPage.$focusList
            .dropFirst()
            .sink { [weak self] _ in self?.focusPageList(.activity) }
            .store(in: &cancellables)
    }

    /// Every window's tabs' titles, by id.
    static func activityTabTitles() -> [UUID: String] {
        var titles: [UUID: String] = [:]
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            for tab in controller.store.tabs { titles[tab.id] = tab.title }
        }
        return titles
    }

    /// What every window says of its tabs (6.5): title, the checkout its
    /// sidebar shows, its branch and repository from the window's
    /// worktrees, its place in the strips; and every checkout known.
    static func activityTabFacts() -> (tabs: [UUID: ActivityTabFacts], checkouts: [String]) {
        var tabs: [UUID: ActivityTabFacts] = [:]
        var checkouts: Set<String> = []
        var order = 0
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            let worktrees = controller.worktrees.worktrees
            let repository = worktrees.first(where: \.isMain).map { $0.path.lastPathComponent }
            for worktree in worktrees where !worktree.isPrunable { checkouts.insert(worktree.path.standardizedFileURL.path) }
            for tab in controller.store.tabs {
                let checkout = activityCheckout(of: tab)
                if let checkout { checkouts.insert(checkout) }
                let worktree = checkout.flatMap { path in worktrees.first { $0.path.standardizedFileURL.path == path } }
                var facts = ActivityTabFacts(id: tab.id, title: tab.title, checkout: checkout, branch: worktree?.branch, order: order, agent: tab.agent)
                if worktree != nil { facts.repository = repository }
                tabs[tab.id] = facts
                order += 1
            }
        }
        return (tabs, checkouts.sorted())
    }

    /// The checkout a tab's sidebar shows, kept by what it is made of: the
    /// lookup asks the disk for `.git` up the folders, and the page's rows
    /// are made every tick.
    static func activityCheckout(of tab: Tab) -> String? {
        let key = [tab.attachedCheckout?.path, tab.agentDirectory, tab.workingDirectory].map { $0 ?? "" }.joined(separator: "\u{0}")
        if let known = activityCheckouts[key] { return known.isEmpty ? nil : known }
        let checkout = tab.checkoutSource?.root.standardizedFileURL.path
        if activityCheckouts.count > 256 { activityCheckouts = [:] }
        activityCheckouts[key] = checkout ?? ""
        return checkout
    }

    @MainActor private static var activityCheckouts: [String: String] = [:]

    /// The forwards Overterm keeps, what a local engine's running
    /// containers publish, the bridge's port: who holds what (6.5).
    static func activityContextFacts(_ context: inout ActivityContext) {
        context.forwards = KubeForwards.shared.forwards.compactMap { forward in
            forward.pid.map { ActivityContext.Forward(pid: $0, port: UInt16(clamping: forward.spec.localPort), target: forward.spec.target.description, tab: forward.spec.tab) }
        }
        context.bridgePort = BrowserBridge.shared.port
        let docker = DockerModel.shared
        guard docker.endpoint?.remoteHost == nil else { return }
        context.published = docker.containers.filter { $0.State == "running" }.flatMap { container in
            (container.Ports ?? []).compactMap { port in
                port.PublicPort.map { published in
                    ActivityContext.PublishedPort(
                        container: (container.Names.first ?? container.Id).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                        project: container.Labels?["com.docker.compose.project"], address: port.IP ?? "", port: UInt16(clamping: published),
                        proto: port.Type)
                }
            }
        }
    }

    /// The apps running, their bundles by pid.
    static func activityRunningApps() -> [pid_t: String] {
        var apps: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bundle = app.bundleURL?.path { apps[app.processIdentifier] = bundle }
        }
        return apps
    }

    /// The running containers of a local engine, with what its usage
    /// monitor last read; none from a remote one, whose processes aren't
    /// this Mac's.
    static func activityContainers() -> [ActivityContainer] {
        let docker = DockerModel.shared
        guard docker.endpoint?.remoteHost == nil else { return [] }
        var containers: [ActivityContainer] = []
        let folders = Dictionary(docker.projects.map { ($0.name, $0.workingDir) }, uniquingKeysWith: { first, _ in first })
        for container in docker.containers where container.State == "running" {
            let project = container.Labels?["com.docker.compose.project"]
            let usage = docker.usage.byContainer[container.Id]
            let name = (container.Names.first ?? container.Id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            containers.append(
                ActivityContainer(
                    id: container.Id, name: name, project: project, folder: project.flatMap { folders[$0] ?? nil }, cpu: usage?.cpuPercent,
                    memory: usage.map { UInt64(max($0.memoryBytes, 0)) }))
        }
        return containers
    }

    /// View ▸ Activity (⌥⌘A): the page, or back to the terminal from it.
    /// With Activity off, its settings.
    @objc func toggleActivityPage(_ sender: Any?) {
        guard Settings.shared.activityEnabled else { return openSettings(.activity) }
        togglePage(.activity)
    }

    /// The page, shown (a link's, the switcher's), on `section`.
    func showActivityPage(_ section: ActivityPageModel.Section? = nil) {
        guard Settings.shared.activityEnabled else { return openSettings(.activity) }
        if let section { activityPage.section = section }
        if store.showingOverlay != .activity { togglePage(.activity) }
    }

    /// The page reads only while its window is on screen at all (7.9). An
    /// isolated run stays in the background, often under the user's own
    /// windows: there the window says nothing about the run, and counts as
    /// shown, as Docker's page does.
    func updateActivityWindowVisible() {
        guard !AppEnvironment.isIsolated, let window else { return }
        let shown = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if activityPage.windowVisible != shown { activityPage.windowVisible = shown }
    }

    /// An `activity.` setting changed: off closes the page and stops its
    /// reading; the interval and everyone's are the page's want and rows.
    func activitySettingsChanged() {
        if !Settings.shared.activityEnabled {
            closeOverlay(.activity)
            if paletteView?.isHidden == false, palette.scope == .activity { hidePalette() }
        }
        // `activity.appServices` is the census's to read (D-31).
        ActivityMonitor.shared.contextChanged()
        activityPage.settingsChanged()
    }

    /// ⌃⌘A: the palette, on the listening ports and the busiest processes.
    /// It holds the census's full level while it shows, so `:5000` finds
    /// AirPlay's listener with no page showing. With Activity off, its
    /// settings.
    @objc func showActivitySwitcher(_ sender: Any?) {
        guard Settings.shared.activityEnabled else { return openSettings(.activity) }
        togglePalette(scope: .activity)
        guard paletteView?.isHidden == false, palette.scope == .activity else { return }
        activitySwitcher.open()
    }

    /// The palette's tab changed to `scope`: the switcher held on
    /// Activity's while the palette shows, given back on any other.
    func activityScopeChanged(_ scope: PaletteItem.Group?) {
        if scope == .activity {
            guard Settings.shared.activityEnabled, paletteView?.isHidden == false else { return }
            activitySwitcher.open()
        } else {
            activitySwitcher.close()
        }
    }

    /// The palette closed: the switcher's hold goes — after what was picked
    /// has opened the page, so the page's want comes first and the ticks
    /// run on rather than starting again.
    func releaseActivitySwitcher() {
        guard activitySwitcher.holding else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.paletteView?.isHidden != false else { return }
            self.activitySwitcher.close()
        }
    }

    /// A switcher row picked: ↩ shows it on the page; ⌥↩ opens a port where
    /// Settings ▸ Browser says, or goes to a process's tab.
    func pickActivityRow(_ row: ActivitySwitcher.Row, run: Bool) {
        let section: ActivityPageModel.Section
        if case .port = row.target { section = .listening } else { section = .processes }
        if !run {
            let tab = row.tab.flatMap { id in store.tabs.first { $0.id == id } }
            if case .port(let url?) = row.target { return openLink(url, for: tab ?? store.selected) }
            if let id = row.tab, let (window, _) = Self.activityWindow(of: id) {
                if store.showingOverlay != nil { hideOverlay(focus: false) }
                return window.reveal(tabID: id)
            }
        }
        showActivityPage(section)
        activityPage.reveal(row.id, in: section)
    }

    /// The window holding tab `id`.
    static func activityWindow(of id: UUID) -> (TerminalWindowController, Tab)? {
        for window in (NSApp as NSApplication?)?.windows ?? [] {
            guard let controller = window.windowController as? TerminalWindowController else { continue }
            if let tab = controller.store.tabs.first(where: { $0.id == id }) { return (controller, tab) }
        }
        return nil
    }

    /// Activity: Listening (`activity.listening`, no key by default): the
    /// page on the listening ports.
    @objc func showActivityListening(_ sender: Any?) {
        showActivityPage(.listening)
    }

    /// What the palette offers of Activity: the page and its Listening, and
    /// while the switcher holds the census, its rows.
    func activityPaletteItems() -> [PaletteItem] {
        guard Settings.shared.activityEnabled else { return [] }
        let rows = (activitySwitcher.rows ?? []).map { row in
            PaletteItem(
                id: "activity.\(row.id)", group: .activity, title: row.title, subtitle: row.subtitle,
                symbol: { if case .port = row.target { return "dot.radiowaves.left.and.right" } else { return "cpu" } }()
            ) { [weak self] run, _ in self?.pickActivityRow(row, run: run) }
        }
        return rows + [
            PaletteItem(id: "a.activity", group: .action, title: "Activity", subtitle: "Every process and port on this Mac  ⌥⌘A  ·  ⌃⌘A its switcher", symbol: "cpu") {
                [weak self] _, _ in self?.showActivityPage(.processes)
            },
            PaletteItem(
                id: "a.activity.listening", group: .action, title: "Activity: Listening", subtitle: "Your processes' listening ports, and who holds each",
                symbol: "dot.radiowaves.left.and.right"
            ) { [weak self] _, _ in self?.showActivityListening(nil) },
        ]
    }
}

/// Whether a window's Activity page holds Docker's model shown (`show`,
/// given back by `hide` once, whatever the setting did in between).
@MainActor
final class ActivityDockerHold {
    var shown = false
}
