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
            showCopy: { [weak self] url in self?.showDockerReadCopy(url) },
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
            },
            choose: { [weak self] title, detail, buttons, then in self?.chooseDocker(title, detail, buttons, then) },
            composeUp: { [weak self] target, freePorts in self?.dockerPage.startUp(target, freePorts: freePorts) },
            freePortsUnavailable: { [weak self] project in self?.dockerPage.freePortsUnavailable(project) },
            alert: { [weak self] title, detail in self?.alertDocker(title, detail) },
            askAgent: { [weak self] in self?.askAgent(about: $0) }
        )
    }

    // MARK: The rail's panel

    /// The panel follows the selected tab's checkout, and holds the
    /// model's poll only while it is on screen.
    func wireDockerPanel() {
        // The panel's menus and the right-hand pane are the page's verbs —
        // set before the page first opens — acting through the panel.
        dockerPage.actions = dockerActions
        dockerPanel.verbs = { [weak self] container in
            guard let self else { return [] }
            return self.dockerPage.verbs(for: container, detail: self.dockerPanel.session?.detail) { [weak self] in
                self?.dockerPanel.act($0, on: [container])
            }
        }
        dockerPanel.projectVerbs = { [weak self] project in
            guard let self else { return [] }
            return self.dockerPage.verbs(for: project) { [weak self] action, containers in self?.dockerPanel.act(action, on: containers) }
        }
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
        // The checkout's compose project before it runs: the panel's and the page's.
        dockerPage.checkoutCompose = dockerPanel.checkoutCompose
        DockerModel.shared.$connection
            .map(\.isRunning)
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published fires before the value lands.
                DispatchQueue.main.async { self?.updateComposeFile() }
            }
            .store(in: &cancellables)
    }

    /// The repository's root, else the tab's own folder. A checkout with a
    /// compose file wants Docker watched — its ports in the pane headers —
    /// whether or not Docker is on screen.
    func updateDockerCheckout(root: URL?) {
        let folder = root ?? store.selected?.workingDirectory.map { URL(fileURLWithPath: $0) }
        if dockerPanel.checkout != folder { dockerPanel.checkout = folder }
        if Settings.shared.dockerEnabled, dockerPanel.composeFile != nil { DockerModel.shared.start() }
        updateComposeFile()
    }

    /// The checkout's compose file is read while the panel or the page
    /// shows Docker in this window, and the engine answers.
    func updateComposeFile() {
        let shown = (dockerPanelShown || dockerPage.visible) && Settings.shared.dockerEnabled && DockerModel.shared.connection.isRunning
        dockerPanel.checkoutCompose.update(checkout: dockerPanel.checkout, shown: shown)
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

    /// A copy made to be read (a resolved compose config), in the editor:
    /// it goes when its tab closes, or the window does.
    func showDockerReadCopy(_ url: URL) {
        guard let editor else { return }
        dockerReadCopies.insert(url.resolvingSymlinksInPath().path)
        if editor.onBufferClosed == nil {
            editor.onBufferClosed = { [weak self] closed in self?.removeDockerReadCopy(closed.resolvingSymlinksInPath().path) }
        }
        if store.showingOverlay != nil { hideOverlay(focus: false) }
        openInEditor(url)
    }

    func removeDockerReadCopy(_ path: String) {
        guard dockerReadCopies.remove(path) != nil else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    func removeDockerReadCopies() {
        let paths = dockerReadCopies
        paths.forEach(removeDockerReadCopy)
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

    /// What the page would say, as a sheet: the page isn't on screen.
    func alertDocker(_ title: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
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
        ([store.selected].compactMap { $0 } + store.tabs).first { checkoutHolds($0, folder) }
    }

    /// Whether the tab's checkout (its repository, else its folder) holds a
    /// project run in `folder`.
    func checkoutHolds(_ tab: Tab, _ folder: String) -> Bool {
        guard let checkout = checkout(of: tab) else { return false }
        return DockerAttention.belongs(folder, to: checkout)
    }

    /// The tab's repository, else its folder; real paths, as Compose's
    /// labels say a project's folder.
    private func checkout(of tab: Tab) -> String? {
        tab.workingDirectory.map { FileTreeModel.realPath(FileTreeModel.treeRoot(for: $0)) }
    }

    // MARK: Asking an agent

    /// Ask Why, or lines of a log: the container read once, now, then the
    /// Ask Agent sheet. A brief that can't be read (no engine: no secrets
    /// to take out) is said, never sent unscrubbed.
    func askAgent(about question: DockerAgentQuestion) {
        guard window?.attachedSheet == nil else { return NSSound.beep() }
        Task { [weak self] in
            do {
                let brief = try await DockerAgentBriefing.brief(question, docker: .shared)
                self?.presentDockerBrief(brief)
            } catch {
                self?.reportDockerError("Ask an agent", error)
            }
        }
    }

    /// The sheet, the agents of the container's checkout first, the
    /// closest of them first (`DockerAttention.closeness`); a new one opens
    /// in its compose folder. The git diff is offered when that folder is
    /// in the window's checkout.
    func presentDockerBrief(_ brief: DockerAgentBrief) {
        guard window?.attachedSheet == nil else { return NSSound.beep() }
        let agents = store.tabs.filter { $0.agent != nil }
        let ranked = agents.enumerated().compactMap { index, tab -> (rank: Int, index: Int, tab: Tab)? in
            guard let folder = brief.folder, let checkout = checkout(of: tab),
                let rank = DockerAttention.closeness(
                    of: checkout, to: folder, isRepository: FileManager.default.fileExists(atPath: checkout + "/.git"))
            else { return nil }
            return (rank, index, tab)
        }
        let mine = ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.tab)
        let ordered = mine + agents.filter { agent in !mine.contains { $0 === agent } }
        let folder = brief.folder.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? store.selected?.workingDirectory
        let diffHere =
            diff.isRepository
            && brief.folder.map { folder in diff.root.map { DockerAttention.belongs(folder, to: FileTreeModel.realPath($0)) } == true } == true
        presentAskAgent(
            text: brief.text, command: nil, folder: folder, targets: ordered, message: brief.message, subject: brief.subject, parts: brief.parts,
            diff: diffHere)
    }

    // MARK: Ports

    /// The containers' ports follow the containers — and the stacks put on
    /// ports of their own, whose pills say where each came from.
    func wireDockerPorts() {
        // A worktree removed takes its override with it.
        ComposePortStore.shared.prune()
        DockerModel.shared.$projects
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateContainerPorts() } }
            .store(in: &cancellables)
        ComposePortStore.shared.$overrides
            .dropFirst()
            .sink { [weak self] _ in
                // @Published fires before the value lands.
                DispatchQueue.main.async {
                    self?.updateContainerPorts()
                    self?.dockerPanel.checkoutCompose.readAgain()
                }
            }
            .store(in: &cancellables)
    }

    func updateContainerPorts() {
        for tab in store.tabs { updateContainerPorts(of: tab) }
    }

    /// What the compose projects of a tab's checkout publish.
    func updateContainerPorts(of tab: Tab) {
        let docker = DockerModel.shared
        var ports: [ListeningPort] = []
        // A remote engine's ports are its host's, not this checkout's servers.
        if docker.connection.isRunning, docker.publishedHost == nil, !docker.projects.isEmpty, let directory = tab.workingDirectory {
            let checkout = FileTreeModel.realPath(FileTreeModel.treeRoot(for: directory))
            let here = ComposeProjects.projects(docker.projects, in: checkout)
            ports = ComposeProjects.ports(of: here, overrides: ComposePortStore.shared.overrides(of: here))
        }
        if tab.containerPorts != ports { tab.containerPorts = ports }
    }

    func updateDockerVisibility(panel: SidebarPanel? = nil) {
        let shown = sidebarItem?.isCollapsed == false && (panel ?? sidebarPanel.panel) == .docker && Settings.shared.dockerEnabled
        guard shown != dockerPanelShown else { return }
        dockerPanelShown = shown
        dockerPanel.panelVisible = shown
        if shown { DockerModel.shared.show() } else { DockerModel.shared.hide() }
        updateComposeFile()
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
            return NSHostingView(
                rootView: DockerPageView(
                    page: dockerPage, docker: .shared, checkoutCompose: dockerPanel.checkoutCompose, theme: theme, actions: dockerActions))
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
                self?.updateComposeFile()
                guard visible != shown else { return }
                shown = visible
                if visible { DockerModel.shared.show() } else { DockerModel.shared.hide() }
            }
    }

    /// The list's CPU and memory are read only while the window is on
    /// screen at all: under another app's, minimized or the app hidden, it
    /// reads none (`DockerPageModel.windowVisible`). An isolated run stays
    /// in the background (AppDelegate), often under the user's own windows:
    /// there the window says nothing about the run, and counts as shown.
    func updateDockerWindowVisible() {
        guard !AppEnvironment.isIsolated, let window else { return }
        let shown = window.occlusionState.contains(.visible)
        if dockerPage.windowVisible != shown { dockerPage.windowVisible = shown }
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

    /// Asks with the buttons given and Cancel; then the index of the one
    /// chosen. As a sheet: one already attached (New Task's) goes first.
    func chooseDocker(_ title: String, _ detail: String, _ buttons: [String], _ then: @escaping (Int) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        alert.addButton(withTitle: "Cancel")
        let count = buttons.count
        alert.beginSheetModal(for: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < count else { return }
            MainActor.assumeIsolated { then(index) }
        }
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

    /// Containers came or went while the palette shows them, or what a
    /// project's files say came in (Compose Watch).
    func watchDockerPalette() -> AnyCancellable {
        DockerModel.shared.$containers.dropFirst().map { _ in () }
            .merge(with: dockerPage.$composeFacts.dropFirst().map { _ in () })
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
        // Asked of Compose while the palette shows; restocked when it answers.
        let watched = composeWatchable(stack).filter(dockerPage.watches)
        if !watched.isEmpty {
            items.append(
                PaletteItem(id: "a.composeWatch", group: .action, title: "Compose Watch", subtitle: watched.map(\.name).joined(separator: ", "), symbol: "eye") {
                    [weak self] _, _ in self?.composeWatch(nil)
                })
        }
        if !stack.isEmpty || dockerPanel.composeFile != nil {
            items.append(
                PaletteItem(
                    id: "a.composeUp", group: .action, title: "Compose Up",
                    subtitle: stack.isEmpty
                        ? dockerPanel.currentPlan?.name ?? dockerPanel.composeFile?.lastPathComponent : stack.map(\.name).joined(separator: ", "),
                    symbol: "play.fill"
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
                    // Its ports looked at first, as the page's Up does.
                    self.dockerPage.startUp(.project(project))
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
    /// compose file at its top when none runs — its project before it
    /// runs, when it was read from the files as they are. Each looks at its
    /// ports first (`DockerPageModel.startUp`).
    @objc func composeUp(_ sender: Any?) {
        let stack = dockerPanelStack()
        if stack.isEmpty {
            guard let checkout = dockerPanel.checkout, dockerPanel.composeFile != nil else { return NSSound.beep() }
            // Read from the files as they are: its Up asks first when its
            // name runs from another folder. Either way the command names no
            // project, so Compose takes it from the files.
            if let plan = dockerPanel.currentPlan { return dockerPage.compose("up", plan) }
            dockerPage.startUp(.checkout(checkout))
        } else {
            for project in stack { dockerPage.startUp(.project(project)) }
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

    /// `compose watch` in a tab for each of the stack's projects with a
    /// service to watch — their files asked about now, Docker on screen or
    /// not; with no stack, the plan's, as Compose Up does. A beep when none
    /// has one.
    @objc func composeWatch(_ sender: Any?) {
        let projects = composeWatchable(dockerPanelStack())
        guard !projects.isEmpty else { return NSSound.beep() }
        Task {
            var any = false
            for project in projects where await dockerPage.watch(project) == nil { any = true }
            if !any { NSSound.beep() }
        }
    }

    /// What Compose Watch would watch: the stack, else the plan when it was
    /// read from the files as they are.
    private func composeWatchable(_ stack: [ComposeProject]) -> [ComposeProject] {
        stack.isEmpty ? dockerPanel.currentPlan.map { [$0] } ?? [] : stack
    }
}
