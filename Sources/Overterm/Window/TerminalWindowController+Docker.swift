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
            showContainer: { [weak self] in self?.showContainer($0) },
            openDatabase: { [weak self] in self?.newDatabaseConnection(from: $0) },
            openFile: { [weak self] container, path in self?.openContainerFile(container, path) },
            downloadFile: { [weak self] container, path in self?.downloadContainerFile(container, path) },
            showTab: { [weak self] id in
                guard let self, let tab = self.store.tabs.first(where: { $0.id == id }) else { return }
                if self.store.showingOverlay != nil { self.hideOverlay(focus: false) }
                self.store.select(tab)
            },
            edit: { [weak self] url in
                guard let self else { return }
                if self.store.showingOverlay != nil { self.hideOverlay(focus: false) }
                self.openInEditor(url)
            },
            pickSave: { [weak self] name, then in
                guard let window = self?.window else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    MainActor.assumeIsolated { then(url) }
                }
            },
            pickOpen: { [weak self] then in
                guard let window = self?.window else { return }
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.init(filenameExtension: "tar") ?? .data]
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    MainActor.assumeIsolated { then(url) }
                }
            },
            askName: { [weak self] title, detail, initial, then in
                self?.askForName(title: title, detail: detail, initial: initial, action: "OK") { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return "A name, please." }
                    then(trimmed)
                    return nil
                }
            }
        )
    }

    // MARK: The rail's panel

    /// The panel follows the selected tab's checkout, and holds the
    /// model's poll only while it is on screen.
    func wireDockerPanel() {
        // An agent's compose up or down runs in a tab of this window.
        DockerMCP.runInTab = { [weak self] command, folder in self?.runDockerCommand(command, in: folder) }
        // A port a container wanted, held by a process in a tab: any window's.
        ContainerSession.tabHolding = { port in
            for controller in NSApp.windows.compactMap({ $0.windowController as? TerminalWindowController }) {
                for tab in controller.store.tabs {
                    if let held = tab.ports.first(where: { $0.port == port }) { return (tab.id, tab.title, held.process) }
                }
            }
            return nil
        }
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

    /// The repository's root, else the tab's own folder. A checkout with a
    /// compose file wants Docker watched — its ports in the pane headers —
    /// whether or not Docker is on screen.
    func updateDockerCheckout(root: URL?) {
        let folder = root ?? store.selected?.workingDirectory.map { URL(fileURLWithPath: $0) }
        if dockerPanel.checkout != folder { dockerPanel.checkout = folder }
        if Settings.shared.dockerEnabled, dockerPanel.composeFile != nil { DockerModel.shared.start() }
    }

    // MARK: Database

    /// A database container's connection, in the form, filled in. The
    /// page steps aside for the Database panel once it is saved.
    func newDatabaseConnection(from guess: DockerDatabaseGuess.Guess) {
        guard Settings.shared.databaseEnabled else { return openSettings(.database) }
        dockerDatabaseDraft = guess
        let model = DatabaseModel.shared
        presentSheet { [weak self] close in
            DatabaseConnectionForm(
                connection: guess.connection, isNew: true, store: model.store,
                done: { saved in
                    close()
                    guard let saved, let self else { return }
                    model.expanded.insert(saved.id.uuidString)
                    Task { await model.session(saved).open() }
                    if self.store.showingOverlay != nil { self.hideOverlay(focus: false) }
                    self.showDatabase(nil)
                }, suggestedPassword: guess.password ?? "")
        }
    }

    // MARK: A container's files

    /// A container's file in the editor: a copy under Overterm's folder,
    /// written back into the container when the editor saves it.
    func openContainerFile(_ container: ContainerSummary, _ path: String) {
        guard let engine = DockerModel.shared.engine else { return }
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        Task {
            do {
                let stat = try await engine.stat(container.Id, path: path)
                guard !stat.isDirectory else { throw DockerError(status: 0, message: "\(path) is a folder.") }
                let data = try await engine.read(container.Id, file: path)
                let local = DockerFiles.localCopy(of: path, in: container.name, under: AppEnvironment.supportDirectory)
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: local)
                dockerFileCopies[local.path] = DockerFileCopy(container: container.Id, name: container.name, path: path, stat: stat)
                hookContainerSaves()
                openInEditor(local)
            } catch {
                reportDockerError("Open \(path)", error)
            }
        }
    }

    /// The editor's save goes back into the container too, for a copy.
    private func hookContainerSaves() {
        guard !dockerSaveHooked, let editor else { return }
        dockerSaveHooked = true
        let saved = editor.onSaved
        editor.onSaved = { [weak self] in
            saved?()
            guard let self, let url = self.editor?.active?.url, let copy = self.dockerFileCopies[url.path] else { return }
            self.saveContainerFile(copy, from: url)
        }
    }

    /// Written back — asked first when the file changed in the container
    /// since it was opened (a process there wrote it, or another editor).
    func saveContainerFile(_ copy: DockerFileCopy, from local: URL, overwrite: Bool = false) {
        guard let engine = DockerModel.shared.engine else { return reportDockerError("Save \(copy.path)", DockerError.unreachable("Docker isn't running.")) }
        Task {
            do {
                let now = try? await engine.stat(copy.container, path: copy.path)
                if !overwrite, let now, now.size != copy.stat.size || now.mtime != copy.stat.mtime {
                    confirmDocker(
                        "“\((copy.path as NSString).lastPathComponent)” changed in \(copy.name)",
                        "It was written in the container after you opened it. Saving replaces that with your copy.", "Replace"
                    ) { [weak self] in self?.saveContainerFile(copy, from: local, overwrite: true) }
                    return
                }
                let data = try Data(contentsOf: local)
                try await engine.write(copy.container, file: copy.path, data: data, mode: Int(copy.stat.mode & 0o777))
                if let written = try? await engine.stat(copy.container, path: copy.path) {
                    dockerFileCopies[local.path]?.stat = written
                }
            } catch {
                reportDockerError("Save \(copy.path) into \(copy.name)", error)
            }
        }
    }

    /// A container's file to the Mac, where the user says.
    func downloadContainerFile(_ container: ContainerSummary, _ path: String) {
        guard let window, let engine = DockerModel.shared.engine else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Task { [weak self] in
                    do {
                        try await engine.read(container.Id, file: path).write(to: url)
                    } catch {
                        self?.reportDockerError("Save \(path)", error)
                    }
                }
            }
        }
    }

    func reportDockerError(_ what: String, _ error: Error) {
        dockerPage.error = "\(what): \(error.localizedDescription)"
        guard let window, store.showingOverlay != .docker else { return }
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Attention

    /// A checkout's container dying on its own marks the checkout's tab.
    func wireDockerAttention() {
        DockerModel.shared.events
            .sink { [weak self] event in
                guard let self, let alert = self.dockerAttention.note(event), Settings.shared.dockerNotifyOnExit,
                    let folder = alert.workingDir, let tab = self.tab(forProjectIn: folder)
                else { return }
                self.markContainerFailure(alert.note, on: tab)
            }
            .store(in: &cancellables)
    }

    /// The tab whose checkout holds a project run in `folder`: the
    /// selected one when it does, else the first.
    func tab(forProjectIn folder: String) -> Tab? {
        let tabs = ([store.selected].compactMap { $0 } + store.tabs).filter { tab in
            guard let directory = tab.workingDirectory else { return false }
            return DockerAttention.belongs(folder, to: FileTreeModel.realPath(FileTreeModel.treeRoot(for: directory)))
        }
        return tabs.first
    }

    // MARK: Ports

    /// The containers' ports follow the containers.
    func wireDockerPorts() {
        DockerModel.shared.$projects
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateContainerPorts() } }
            .store(in: &cancellables)
    }

    func updateContainerPorts() {
        for tab in store.tabs { updateContainerPorts(of: tab) }
    }

    /// What the compose projects of a tab's checkout publish.
    func updateContainerPorts(of tab: Tab) {
        let docker = DockerModel.shared
        var ports: [ListeningPort] = []
        if docker.connection.isRunning, !docker.projects.isEmpty, let directory = tab.workingDirectory {
            let checkout = FileTreeModel.realPath(FileTreeModel.treeRoot(for: directory))
            ports = ComposeProjects.ports(of: ComposeProjects.projects(docker.projects, in: checkout))
        }
        if tab.containerPorts != ports { tab.containerPorts = ports }
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

    func dockerSettingsChanged(_ keys: Set<String> = ["docker.enabled"]) {
        // Agents' Docker tools come and go with the setting.
        BrowserBridge.shared.update()
        if !Settings.shared.dockerEnabled {
            closeOverlay(.docker)
            if sidebarPanel.panel == .docker { sidebarPanel.panel = .files }
            if rightPane.mode == .container { rightPane.mode = .changes }
            rightPane.containerOpened = false
            dockerPanel.picked = nil
            updateDockerVisibility()
            DockerModel.shared.stop()
        } else if DockerModel.shared.isWatching, !keys.isDisjoint(with: ["docker.enabled", "docker.endpoint", "docker.context"]) {
            // Another engine, maybe: nothing starts that wasn't started,
            // and an agents' setting reconnects nothing.
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
