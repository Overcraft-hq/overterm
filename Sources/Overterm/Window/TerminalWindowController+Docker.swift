import AppKit
import Combine
import SwiftUI

/// Docker: the page over the body (⌥⌘P), the commands it types into
/// terminal tabs, and the setting that turns it all off.
extension TerminalWindowController {
    var dockerActions: DockerActions {
        DockerActions(
            run: { [weak self] command, folder in self?.runDockerCommand(command, in: folder) },
            confirm: { [weak self] title, detail, button, then in self?.confirmDocker(title, detail, button, then) },
            open: { [weak self] url in self?.openDockerLink(url) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            settings: { [weak self] in self?.openSettings(.docker) },
            openPage: { [weak self] in self?.toggleDockerPage(nil) },
            showContainer: { [weak self] in self?.showContainer($0) }
        )
    }

    // MARK: The rail's panel

    /// The panel follows the selected tab's checkout, and holds the
    /// model's poll only while it is on screen.
    func wireDockerPanel() {
        diff.$root
            .combineLatest(store.$selectedID)
            .sink { [weak self] root, _ in
                // @Published fires before the value lands; the root given is the new one.
                DispatchQueue.main.async { self?.updateDockerCheckout(root: root) }
            }
            .store(in: &cancellables)
        sidebarPanel.$panel
            .sink { [weak self] panel in DispatchQueue.main.async { self?.updateDockerVisibility(panel: panel) } }
            .store(in: &cancellables)
    }

    /// The repository's root, else the tab's own folder.
    func updateDockerCheckout(root: URL?) {
        let folder = root ?? store.selected?.workingDirectory.map { URL(fileURLWithPath: $0) }
        if dockerPanel.checkout != folder { dockerPanel.checkout = folder }
    }

    func updateDockerVisibility(panel: SidebarPanel? = nil) {
        let shown = sidebarItem?.isCollapsed == false && (panel ?? sidebarPanel.panel) == .docker && Settings.shared.dockerEnabled
        guard shown != dockerPanelShown else { return }
        dockerPanelShown = shown
        if shown { DockerModel.shared.show() } else { DockerModel.shared.hide() }
    }

    /// The rail's shippingbox: the sidebar, on the Docker panel.
    @objc func showDockerPanel(_ sender: Any?) {
        guard Settings.shared.dockerEnabled else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .docker
        updateDockerVisibility(panel: .docker)
    }

    /// A container in the right-hand pane, on its logs the first time.
    func showContainer(_ container: ContainerSummary) {
        dockerPanel.picked = container.Id
        rightPane.containerOpened = true
        rightPane.mode = .container
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// The page's view, made the first time it opens.
    func makeOverlay(_ overlay: WorkspaceOverlay) -> NSView? {
        switch overlay {
        case .settings: return nil
        case .docker:
            guard let theme else { return nil }
            dockerPage.actions = dockerActions
            return NSHostingView(rootView: DockerPageView(page: dockerPage, docker: .shared, theme: theme, actions: dockerActions))
        }
    }

    /// View ▸ Docker (⌥⌘P): the page, or back to the terminal from it.
    @objc func toggleDockerPage(_ sender: Any?) {
        guard Settings.shared.dockerEnabled else { return openSettings(.docker) }
        if store.showingOverlay == .docker {
            hideOverlay()
        } else {
            showOverlay(.docker)
            focusDockerList()
        }
    }

    /// The keyboard to the list's table — AppKit's way, since SwiftUI's
    /// focus wouldn't take it back from the filter field. Its table exists
    /// only once SwiftUI has laid the list out: tried again shortly.
    func focusDockerList(attempts: Int = 10) {
        guard store.showingOverlay == .docker, let page = dockerView else { return }
        if let table = Self.firstTable(in: page) {
            window?.makeFirstResponder(table)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusDockerList(attempts: attempts - 1) }
        }
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    /// The model polls only while a page shows it; events run regardless
    /// once it has started.
    func watchDockerPage() -> AnyCancellable {
        var shown = false
        return store.$showingOverlay
            .map { $0 == .docker }
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.dockerPage.visible = visible
                guard visible != shown else { return }
                shown = visible
                if visible { DockerModel.shared.show() } else { DockerModel.shared.hide() }
            }
    }

    /// Letters act on the list while its table has the keyboard; in the
    /// filter field they are text. SwiftUI's own key handling is macOS 14.
    func installDockerKeys() {
        dockerKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleDockerKey(event) else { return event }
            return nil
        }
        dockerPage.$focusList
            .dropFirst()
            .sink { [weak self] _ in self?.focusDockerList() }
            .store(in: &cancellables)
    }

    /// A key down: the list's when it has the keyboard and the key means
    /// something there (DockerKey), with no ⌘, ⌃ or ⌥ — those are menus'.
    func handleDockerKey(_ event: NSEvent) -> Bool {
        guard dockerListHasKeyboard(event), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let characters = event.characters
        else { return false }
        return dockerPage.press(characters)
    }

    /// The page shows in this window and its list — a table under it, not a
    /// text field's editor — is the first responder.
    func dockerListHasKeyboard(_ event: NSEvent? = nil) -> Bool {
        guard store.showingOverlay == .docker, event?.window ?? window === window, let page = dockerView,
            let table = window?.firstResponder as? NSTableView
        else { return false }
        return table.isDescendant(of: page)
    }

    func dockerSettingsChanged() {
        if !Settings.shared.dockerEnabled {
            closeOverlay(.docker)
            if sidebarPanel.panel == .docker { sidebarPanel.panel = .files }
            if rightPane.mode == .container { rightPane.mode = .changes }
            rightPane.containerOpened = false
            dockerPanel.picked = nil
            updateDockerVisibility()
            DockerModel.shared.stop()
        } else if DockerModel.shared.isWatching {
            // Another engine, maybe: nothing starts that wasn't started.
            DockerModel.shared.reconnect()
        }
        // The rail lists its icons from the setting: drawn again.
        sidebarPanel.objectWillChange.send()
    }

    /// A command in a new tab: compose in the project's folder, the rest
    /// in the selected tab's (or home).
    func runDockerCommand(_ command: String, in folder: URL?) {
        let directory =
            folder.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? store.selected.flatMap { $0.workingDirectory.map { URL(fileURLWithPath: $0) } }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        newTab(in: directory, running: command)
    }

    func confirmDocker(_ title: String, _ detail: String, _ button: String, _ then: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { then() }
        }
    }

    /// A container's port: the browser column when links open inside
    /// (the page steps aside for it), else the default browser.
    func openDockerLink(_ url: URL) {
        guard BrowserLinks.opensInside(url, policy: Settings.shared.browserLinks), Settings.shared.browserEnabled else {
            NSWorkspace.shared.open(url)
            return
        }
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        openInBrowser(url, for: store.selected)
    }
}

// MARK: The switcher and the palette

extension TerminalWindowController {
    /// ⇧⌥⌘P: the palette, on containers and compose projects. Docker is
    /// started if it wasn't; what it lists comes in as it answers.
    @objc func showDockerSwitcher(_ sender: Any?) {
        guard Settings.shared.dockerEnabled else { return openSettings(.docker) }
        DockerModel.shared.start()
        if paletteView?.isHidden == false, palette.scope == .container { return hidePalette() }
        if paletteView?.isHidden != false { showPalette(nil) }
        palette.scope = .container
    }

    /// Containers came or went while the palette shows them.
    func watchDockerPalette() -> AnyCancellable {
        DockerModel.shared.$containers
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.restockPalette() } }
    }

    /// What the palette offers of Docker: the page, the checkout's stack's
    /// verbs, every container and project. A container's ↩ shows it on
    /// the page; ⌥↩ a shell in it (or starts it); a project's ⌥↩ is `up`.
    func dockerPaletteItems() -> [PaletteItem] {
        guard Settings.shared.dockerEnabled else { return [] }
        let docker = DockerModel.shared
        var items = [
            PaletteItem(id: "a.docker", group: .action, title: "Docker", subtitle: "Containers, compose projects, logs  ⌥⌘P", symbol: "shippingbox") {
                [weak self] _, _ in self?.toggleDockerPage(nil)
            }
        ]
        let stack = dockerPanelStack()
        if !stack.isEmpty {
            let names = stack.map(\.name).joined(separator: ", ")
            items += [
                PaletteItem(id: "a.composeRestart", group: .action, title: "Compose Restart", subtitle: names, symbol: "arrow.clockwise") {
                    [weak self] _, _ in self?.composeRestart(nil)
                },
                PaletteItem(id: "a.composeDown", group: .action, title: "Compose Down…", subtitle: names, symbol: "stop.fill") {
                    [weak self] _, _ in self?.composeDown(nil)
                },
            ]
        }
        if !stack.isEmpty || dockerPanel.composeFile != nil {
            items.append(
                PaletteItem(
                    id: "a.composeUp", group: .action, title: "Compose Up",
                    subtitle: stack.isEmpty ? dockerPanel.composeFile?.lastPathComponent : stack.map(\.name).joined(separator: ", "), symbol: "play.fill"
                ) { [weak self] _, _ in self?.composeUp(nil) })
        }
        guard docker.connection.isRunning else { return items }
        items += docker.projects.map { project in
            PaletteItem(
                id: "d.p.\(project.name)", group: .container, title: project.name,
                subtitle: "\(project.running)/\(project.containers.filter { !$0.isOneOff }.count) running"
                    + (project.workingDir.map { " — " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""),
                symbol: "square.stack.3d.up"
            ) { [weak self] run, _ in
                guard let self else { return }
                if run {
                    self.revealOnDockerPage(DockerPageModel.projectTag(project.name))
                } else {
                    self.runDockerCommand(DockerCommands.compose(project, "up -d", endpoint: docker.endpoint), in: project.workingDir.map { URL(fileURLWithPath: $0) })
                }
            }
        }
        items += docker.containers.map { container in
            PaletteItem(
                id: "d.c.\(container.Id)", group: .container, title: container.name,
                subtitle: [DockerStatusStyle.status(container), container.Image].joined(separator: " — "),
                symbol: container.state.isUp ? "shippingbox.fill" : "shippingbox"
            ) { [weak self] run, _ in
                guard let self else { return }
                if run {
                    self.revealOnDockerPage(container.Id)
                } else if container.state == .running {
                    self.runDockerCommand(DockerCommands.shell(in: container, endpoint: docker.endpoint), in: nil)
                } else {
                    self.dockerPage.act(.start, on: [container])
                }
            }
        }
        return items
    }

    /// The page, with this container (or `project:<name>`) selected and
    /// in view: the filter cleared, its project unfolded.
    func revealOnDockerPage(_ tag: String) {
        dockerPage.filter = ""
        if let container = DockerModel.shared.container(tag) {
            dockerPage.runningOnly = dockerPage.runningOnly && container.state.isUp
            if let project = container.composeProject { dockerPage.collapsed.remove(DockerPageModel.projectTag(project)) }
        }
        dockerPage.selection = [tag]
        if store.showingOverlay != .docker { showOverlay(.docker) }
        focusDockerList()
    }

    // MARK: The checkout's stack

    /// The selected tab's checkout's compose projects.
    func dockerPanelStack() -> [ComposeProject] {
        updateDockerCheckout(root: diff.root)
        return dockerPanel.here
    }

    /// Compose Up: the checkout's projects again from their files, or the
    /// compose file at its top when none runs.
    @objc func composeUp(_ sender: Any?) {
        let endpoint = DockerModel.shared.endpoint
        let stack = dockerPanelStack()
        if stack.isEmpty {
            guard dockerPanel.composeFile != nil else { return NSSound.beep() }
            runDockerCommand(DockerCommands.prefix(for: endpoint) + "docker compose up -d", in: dockerPanel.checkout)
        } else {
            for project in stack {
                runDockerCommand(DockerCommands.compose(project, "up -d", endpoint: endpoint), in: project.workingDir.map { URL(fileURLWithPath: $0) })
            }
        }
    }

    @objc func composeDown(_ sender: Any?) {
        let stack = dockerPanelStack()
        guard !stack.isEmpty else { return NSSound.beep() }
        let endpoint = DockerModel.shared.endpoint
        confirmDocker(
            stack.count == 1 ? "Take “\(stack[0].name)” down?" : "Take \(stack.count) projects down?",
            "docker compose down stops and removes their containers and networks, in a terminal tab. Their volumes stay.", "Down"
        ) { [weak self] in
            for project in stack {
                self?.runDockerCommand(
                    DockerCommands.compose(project, "down", endpoint: endpoint), in: project.workingDir.map { URL(fileURLWithPath: $0) })
            }
        }
    }

    /// Restarted here, through the engine: nothing for a tab to show.
    @objc func composeRestart(_ sender: Any?) {
        let stack = dockerPanelStack()
        guard !stack.isEmpty else { return NSSound.beep() }
        dockerPage.act(.restart, on: stack.flatMap(\.containers).filter { !$0.isOneOff })
    }
}
