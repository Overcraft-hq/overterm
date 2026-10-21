import AppKit
import Combine

/// A column zoomed to fill the window beside the sidebar.
enum ZoomedColumn: Equatable {
    case editor, browser
}

/// The two things that open on the right of the window: the browser column
/// (the simulator with it) and the pane the changes, the pull request and
/// the usage share. They are one slot — open together they pushed the
/// browser into the middle of the window and left all four columns too
/// narrow to work in — so one opening closes the other, and closing it
/// gives the slot back.
enum RightSlot: Equatable {
    case browser, pane
}

/// The browser column: each terminal tab's own browser (its pages), shown
/// while that tab is selected; links and ports routed into it; agents
/// given it (BrowserBridge).
extension TerminalWindowController {
    func wireBrowser() {
        guard let browser else { return }
        browserButton.isEnabled = Settings.shared.browserEnabled
        browser.onClose = { [weak self] in self?.closeBrowser() }
        browser.onToggleZoom = { [weak self] in
            guard let self else { return }
            self.setZoomed(self.zoomedColumn == .browser ? nil : .browser)
        }
        browser.onAskAgent = { [weak self] page in self?.askAboutPage(page) }
        if let simulator = browserColumn?.simulator {
            simulator.onClose = { [weak self] in self?.closeBrowser() }
            simulator.onToggleZoom = { [weak self] in
                guard let self else { return }
                self.setZoomed(self.zoomedColumn == .browser ? nil : .browser)
            }
        }
        browser.onOpenExternally = { NSWorkspace.shared.open($0) }
        browser.makeWorkspace = { [weak self] in
            guard let self, let tab = self.store.selected else { return nil }
            return self.browserWorkspace(for: tab)
        }
        BrowserBridge.shared.resolve = { [weak self] tag in self?.agentBrowser(forPane: tag) }
        store.$selectedID
            .sink { [weak self] _ in
                // @Published fires before the value lands.
                DispatchQueue.main.async { self?.showSelectedBrowser() }
            }
            .store(in: &browserObservers)
        editor?.onSaved = { [weak self] in self?.reloadAfterSave() }
        diff.$files
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadAfterSave() }
            .store(in: &browserObservers)
    }

    /// The tab's browser, made on first use — with its restored pages.
    func browserWorkspace(for tab: Tab, create: Bool = true) -> BrowserWorkspace? {
        if let workspace = browserWorkspaces[tab.id] { return workspace }
        guard create, Settings.shared.browserEnabled else { return nil }
        let workspace = BrowserWorkspace()
        workspace.onOpenExternally = { NSWorkspace.shared.open($0) }
        browserWorkspaces[tab.id] = workspace
        if let saved = pendingBrowserPages.removeValue(forKey: tab.id) {
            for url in saved.urls { workspace.newPage(url, select: false) }
            workspace.select(saved.active)
        }
        return workspace
    }

    /// What the column shows: the selected tab's browser — made now if it
    /// has pages waiting from the last session and the column is open.
    func showSelectedBrowser() {
        guard let browser, let tab = store.selected else { return }
        let create = browserItem?.isCollapsed == false && pendingBrowserPages[tab.id] != nil
        browser.show(browserWorkspace(for: tab, create: create), ports: tab.ports)
    }

    @objc func toggleBrowser(_ sender: Any?) {
        guard let browserItem, Settings.shared.browserEnabled else { return }
        // Open on the simulator, the globe takes the column back rather
        // than shutting it.
        if browserItem.isCollapsed || browserColumn?.mode != .web {
            browserColumn?.show(.web)
            showBrowserColumn()
            if browser?.workspace?.active == nil { browser?.focusAddress() }
        } else {
            closeBrowser()
        }
    }

    /// The title bar's phone, beside the globe: the same column, showing
    /// the simulator — read only while it is up.
    @objc func toggleSimulator(_ sender: Any?) {
        guard let browserItem, Settings.shared.browserEnabled else { return }
        if browserItem.isCollapsed || browserColumn?.mode != .simulator {
            showSimulator()
        } else {
            closeBrowser()
        }
    }

    func showSimulator() {
        guard Settings.shared.browserEnabled else { return }
        browserColumn?.show(.simulator)
        showBrowserColumn()
    }

    private func showBrowserColumn() {
        guard let browserItem else { return }
        takeRightSlot(.browser)
        if browserItem.isCollapsed { browserItem.animator().isCollapsed = false }
        browserButton.isOpen = true
        browserButton.isSimulator = browserColumn?.mode == .simulator
        browserColumn?.setColumnOpen(true)
        if let tab = store.selected, pendingBrowserPages[tab.id] != nil { _ = browserWorkspace(for: tab) }
        showSelectedBrowser()
    }

    func closeBrowser() {
        hideBrowserColumn()
        focusSelectedTerminal()
        restoreRightSlot(after: .browser)
    }

    /// The column goes, without saying what takes its place.
    private func hideBrowserColumn() {
        if zoomedColumn == .browser { setZoomed(nil) }
        browserItem?.animator().isCollapsed = true
        browserButton.isOpen = false
        browserButton.isSimulator = false
        browserColumn?.setColumnOpen(false)
    }

    /// Clears the right-hand slot for `slot`, remembering who had it.
    func takeRightSlot(_ slot: RightSlot) {
        switch slot {
        case .browser:
            guard diffItem?.isCollapsed == false else { return }
            setRightPaneShown(false, remember: false)
            displacedSlot = .pane
        case .pane:
            guard browserItem?.isCollapsed == false else { return }
            hideBrowserColumn()
            displacedSlot = .browser
        }
    }

    /// `slot` has closed: what it took the slot from comes back.
    func restoreRightSlot(after slot: RightSlot) {
        let displaced = displacedSlot
        displacedSlot = nil
        switch (slot, displaced) {
        case (.browser, .pane): setRightPaneShown(true, remember: false)
        case (.pane, .browser): showBrowserColumn()
        default: break
        }
    }

    /// Opens `url` in `tab`'s browser — in the page showing, or a new one —
    /// and the column comes up when that tab is the one on screen.
    func openInBrowser(_ url: URL, for tab: Tab?, newPage: Bool = false) {
        guard Settings.shared.browserEnabled, let tab = tab ?? store.selected, let workspace = browserWorkspace(for: tab) else {
            NSWorkspace.shared.open(url)
            return
        }
        if let page = workspace.active, !newPage {
            page.load(url)
        } else {
            workspace.newPage(url)
        }
        if tab.id == store.selectedID {
            // A page to look at: the column comes back from the simulator.
            browserColumn?.show(.web)
            showBrowserColumn()
        }
    }

    /// A link from Tab Info or a pane header's port: here or the system's,
    /// as Settings ▸ Browser says.
    func openLink(_ url: URL, for tab: Tab?) {
        if BrowserLinks.opensInside(url, policy: Settings.shared.browserLinks) {
            openInBrowser(url, for: tab)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// What the session file keeps of a tab's browser.
    func browserPages(of tab: Tab) -> (urls: [URL], active: Int)? {
        guard Settings.shared.browserEnabled else { return nil }
        return browserWorkspaces[tab.id]?.savedPages ?? pendingBrowserPages[tab.id]
    }

    /// The tab is closing: its browser and its agents' doors go with it.
    func forgetBrowser(of tab: Tab) {
        pendingBrowserPages[tab.id] = nil
        tab.terminals.forEach { BrowserBridge.shared.removeConfig(forPane: $0.processTag) }
        guard let workspace = browserWorkspaces.removeValue(forKey: tab.id) else { return }
        if browser?.workspace === workspace { browser?.show(nil, ports: []) }
        workspace.closeAll()
    }

    func browserSettingsChanged() {
        BrowserBridge.shared.update()
        browserButton.isEnabled = Settings.shared.browserEnabled
        guard !Settings.shared.browserEnabled else { return }
        // Off: the column goes, and every tab's pages with it.
        if browserItem?.isCollapsed == false { closeBrowser() }
        browser?.show(nil, ports: [])
        for (id, workspace) in browserWorkspaces {
            workspace.closeAll()
            browserWorkspaces[id] = nil
        }
    }

    /// Settings ▸ Browser ▸ Reload on save: a save in the editor, or the
    /// checkout changing under an agent, reloads the page showing in the
    /// selected tab's browser — a local one only.
    func reloadAfterSave() {
        guard Settings.shared.browserReloadOnSave, let tab = store.selected, let page = browserWorkspaces[tab.id]?.active,
            let url = page.url, BrowserLinks.isLocal(url) || url.isFileURL, !page.isLoading
        else { return }
        page.reload()
    }

    /// The browser of the tab a pane is in, for an agent in that pane: made
    /// if the tab has none, and the column shown when that tab is the one
    /// on screen — you watch what the agent does.
    func agentBrowser(forPane tag: String) -> AgentBrowser? {
        guard let tab = store.tabs.first(where: { $0.terminals.contains { $0.processTag == tag } }),
            let workspace = browserWorkspace(for: tab)
        else { return nil }
        if tab.id == store.selectedID {
            if browserItem?.isCollapsed == true {
                browserColumn?.show(.web)
                showBrowserColumn()
            }
            if browser?.workspace !== workspace { showSelectedBrowser() }
        }
        return workspace
    }

    /// The toolbar's ✦: the page — address, title, its errors, a screenshot
    /// — to an agent, the selected tab's first.
    func askAboutPage(_ page: BrowserSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines = ["Page: \(page.title)", "URL: \(page.url?.absoluteString ?? "(none)")"]
            let problems = page.consoleText(onlyErrors: true, limit: 30)
            if !problems.isEmpty { lines.append("Console errors:\n\(problems)") }
            if let png = try? await page.screenshot() {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-browser", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("page-\(Int(Date().timeIntervalSince1970)).png")
                if (try? png.write(to: file)) != nil { lines.append("Screenshot: \(file.path)") }
            }
            let selected = self.store.selected
            let agents = self.store.tabs.filter { $0.agent != nil }
            let ordered = agents.filter { $0.id == selected?.id } + agents.filter { $0.id != selected?.id }
            self.presentAskAgent(text: lines.joined(separator: "\n\n"), command: nil, folder: selected?.workingDirectory, targets: ordered)
        }
    }
}
