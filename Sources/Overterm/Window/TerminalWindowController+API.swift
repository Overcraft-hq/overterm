import AppKit
import Combine

/// The API client: the sidebar's panel over the checkout's Bruno
/// collections, and `.bru` requests in the editor, sent through the
/// window's APIWorkspace.
extension TerminalWindowController {
    func wireAPI() {
        editor?.apiWorkspace = apiWorkspace
        BrowserBridge.shared.resolveAPI = { [weak self] tag in self?.agentAPI(forPane: tag) }
        apiWorkspace.askAgent = { [weak self] text, folder in self?.askAgentAboutAPI(text, folder: folder) }
        // Where to look for an API being served: the selected tab's ports.
        apiWorkspace.ports = { [weak self] in self?.store.selected?.ports.map(\.port) ?? [] }
        editor?.apiWorkspaceChanged()
        sidebarPanel.$panel
            // @Published fires before the value lands.
            .sink { [weak self] panel in
                DispatchQueue.main.async { self?.updateAPIVisibility(panel: panel) }
            }
            .store(in: &cancellables)
        // A save here or an agent's edit: the tree and its names follow.
        let saved = editor?.onSaved
        editor?.onSaved = { [weak self] in
            saved?()
            if self?.apiWorkspace.visible == true { self?.apiWorkspace.reload() }
        }
        diff.$files
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .sink { [weak self] files in
                guard let self, self.apiWorkspace.visible, files.contains(where: { $0.path.hasSuffix(".bru") || $0.path.hasSuffix("bruno.json") })
                else { return }
                self.apiWorkspace.reload()
            }
            .store(in: &cancellables)
        updateAPIVisibility()
    }

    /// The panel reads the disk only while it is the one on screen and the
    /// sidebar is open (CLAUDE.md).
    func updateAPIVisibility(panel: SidebarPanel? = nil) {
        let shown = sidebarItem?.isCollapsed == false
        apiWorkspace.visible = shown && (panel ?? sidebarPanel.panel) == .api && Settings.shared.apiEnabled
    }

    /// View ▸ API Client: the sidebar, on the API panel.
    @objc func showAPIClient(_ sender: Any?) {
        guard Settings.shared.apiEnabled else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .api
        updateAPIVisibility(panel: .api)
    }

    /// The API client of the checkout an agent's pane is in: the panel's
    /// when it shows that checkout, else one of its own, read now.
    func agentAPI(forPane tag: String) -> AgentAPI? {
        guard let tab = store.tabs.first(where: { $0.terminals.contains { $0.processTag == tag } }),
            let root = tab.checkoutSource?.root
        else { return nil }
        // Read on the agent's call (APIMCP awaits loadIfNeeded), off the main thread.
        if apiWorkspace.root?.standardizedFileURL == root.standardizedFileURL { return apiWorkspace }
        let workspace = agentAPIWorkspaces[root.standardizedFileURL.path] ?? APIWorkspace(personalRoot: nil, session: apiWorkspace.session)
        agentAPIWorkspaces[root.standardizedFileURL.path] = workspace
        workspace.setRoot(root)
        return workspace
    }

    func apiSettingsChanged() {
        BrowserBridge.shared.update()
        if !Settings.shared.apiEnabled, sidebarPanel.panel == .api { sidebarPanel.panel = .files }
        // The rail lists its icons from the setting: drawn again.
        sidebarPanel.objectWillChange.send()
        updateAPIVisibility()
    }

    /// Runs requests and folders into the right-hand pane's Runner.
    func runAPI(_ items: [APIItem], title: String) {
        guard
            let collection = apiWorkspace.collection(containing: items.first?.url ?? URL(fileURLWithPath: "/"))
                ?? apiWorkspace.collection
        else { return }
        apiWorkspace.runner.run(items, title: title, in: collection, workspace: apiWorkspace)
        rightPane.mode = .runner
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updateRightPaneVisibility()
    }

    /// The last run again, under Bruno's own CLI, in a new tab at the
    /// collection — for scripts that need npm packages.
    func runAPIWithBru() {
        let runner = apiWorkspace.runner
        guard let root = runner.collectionRoot, let collection = apiWorkspace.collections.first(where: { $0.root == root }) else { return }
        // The environment the Runner shows, not whatever is picked by now.
        let command = APIRunner.bruCommand(for: runner.lastItems, in: collection, environment: runner.environment)
        newTab(in: root, running: command)
    }

    func askForAPIName(title: String, initial: String, done: @escaping (String) -> Void) {
        askForName(title: title, detail: "", initial: initial, action: "OK") { name in
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return "A name, please." }
            done(name)
            return nil
        }
    }

    func editAPISecrets(_ environment: String, in collection: BrunoCollection) {
        let workspace = apiWorkspace
        let file = workspace.environmentFile(environment, in: collection)
        let names = file?.secretNames ?? []
        var values: [String: String] = [:]
        for name in names { values[name] = workspace.secrets.value(collection: collection.root, environment: environment, name: name) }
        presentSheet { close in
            APISecretsView(
                environment: environment, names: names, values: values,
                save: { [weak self] names, values in
                    close()
                    do {
                        try workspace.saveSecrets(names, values: values, environment: environment, in: collection)
                    } catch {
                        self?.reportAPIError(error)
                    }
                }, cancel: close)
        }
    }

    /// A request and its response to an agent, as the browser's ✦ hands a page.
    func askAgentAboutAPI(_ text: String, folder: URL?) {
        let selected = store.selected
        let agents = store.tabs.filter { $0.agent != nil }
        let ordered = agents.filter { $0.id == selected?.id } + agents.filter { $0.id != selected?.id }
        presentAskAgent(text: text, command: nil, folder: folder?.path ?? selected?.workingDirectory, targets: ordered)
    }

    /// Renames a request or folder from the API panel. Its file is
    /// rewritten (its meta name), so a tab with unsaved edits in it is
    /// saved first — else the rename would leave them behind, and the next
    /// ⌘S would put the old file back beside the new one. The editor's tabs
    /// follow it, as they do a rename in Files.
    ///
    /// Paths are matched with their links resolved, before the move: the
    /// panel's tree lists /private/var where the editor opened /var, and
    /// a folder linked into the checkout differs the same way.
    func renameAPIItem(_ item: APIItem, to name: String) throws -> URL {
        let old = item.url.resolvingSymlinksInPath().path
        // Each tab's own spelling of what is being renamed, for filesMoved.
        var spellings: Set<URL> = []
        for buffer in editor?.buffers ?? [] {
            guard let url = buffer.url else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved == old || resolved.hasPrefix(old + "/") else { continue }
            spellings.insert(URL(fileURLWithPath: String(url.path.dropLast(resolved.count - old.count))))
            // Unformatted, so it is written now, before the rename reads it.
            if buffer.document.isDirty { editor?.save(buffer, overwriting: false, formatted: true) }
        }
        let target = try apiWorkspace.rename(item, to: name)
        for spelling in spellings { editor?.filesMoved(from: spelling, to: target) }
        apiWorkspace.moveResults(from: item.url, resolved: old, to: target)
        editor?.reloadIfChangedOnDisk()
        // Their request views were made for the old path: sends recorded
        // there, Reveal and Ask Agent pointing at a file that is gone.
        editor?.requestsMoved()
        tree.reload()
        return target
    }

    func informAPI(title: String, detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    func reportAPIError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
