import AppKit

/// Ways into the window that need no shell knowledge (onboarding 7.4).
extension TerminalWindowController {
    /// File ▸ Open Folder… and its ⌘K row: a folder picked in Finder's
    /// panel, a tab opened there (`open(_:)`) — into a repository without
    /// `cd`. Overterm never runs `git init` in it.
    @objc package func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "A tab opens in the folder you pick."
        if let cwd = store.selected?.workingDirectory { panel.directoryURL = URL(fileURLWithPath: cwd, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.open([url]) }
        }
    }
}

/// The Start card (onboarding 7.3, 7.10): the launch handed to it, Help ▸
/// Getting Started, and every press on it.
extension TerminalWindowController {
    /// This launch, once the window shows: a fresh install's card open
    /// (D-2). `Start` is inert in an isolated run; the `onboarding`
    /// scenario hands it a launch itself.
    package func beginStart(_ launch: FirstRun.Launch) {
        Start.shared.begin(launch)
    }

    /// A fresh install's panels (`FreshInstallSetup.decidePanels`): those
    /// whose tool isn't on this Mac turned off once the login shell has said
    /// its PATH, and the card told. Never by itself in an isolated run.
    package func decideFreshPanels(_ launch: FirstRun.Launch) {
        guard launch == .fresh else { return }
        Task {
            await FreshInstallSetup.decidePanels(launch)
            Start.shared.hiddenAtInstallChanged()
        }
    }

    /// Help ▸ Getting Started and its ⌘K row: the sidebar shown and the
    /// card open, whatever the flags say — the one way into it that moves
    /// the keyboard, and the person asked: to the sidebar, where Tab
    /// reaches the card and Esc goes back to the terminal.
    @objc package func showGettingStarted(_ sender: Any?) {
        guard Start.shared.active else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        Start.shared.gettingStarted()
        if let window, let target = sidebarKeyTarget?() { window.makeFirstResponder(target) }
    }

    /// A press on the card: the menu item's own action, never more — the
    /// keyboard lands where that action leaves it. A click that left the
    /// keyboard in the card itself (a SwiftUI control taking it on the
    /// press) gives it back to the selected terminal (onboarding risk 1);
    /// a key press — Full Keyboard Access — leaves it on the control.
    package func performStartAction(_ action: StartCardAction) {
        let start = Start.shared
        switch action {
        case .toggle: start.toggle()
        case .close: start.close()
        case .turnOffTips: start.turnOffTips()
        case .checkAgain: start.probe(force: true)
        case .chooseAgent(let value): start.chooseAgent(value)
        case .setPanel(let panel, let on): start.setPanel(panel, on)
        case .showHidden: start.showHidden()
        case .settings(let section): openSettings(section)
        case .command(let id): runStartCommand(id)
        }
        if NSApp.currentEvent?.type != .keyDown { keepKeyboardOutOfStartCard() }
    }

    /// A step's button, as its menu item does it — the subset that opens,
    /// where the menu item toggles: a button never closes what it names.
    private func runStartCommand(_ id: String) {
        switch id {
        case "file.openFolder": openFolder(nil)
        case "tasks.new": newTask(nil)
        case "inbox.show": if inboxItem?.isCollapsed == true { toggleInbox(nil) }
        case "changes.toggle": showChanges(nil)
        case "help.setup": showSetup(nil)
        default: break
        }
    }

    /// The keyboard out of the sidebar's card: back to the selected
    /// terminal when a press left it on a control there. The sidebar's own
    /// keyboard view (F6) keeps it.
    private func keepKeyboardOutOfStartCard() {
        guard let window, let responder = window.firstResponder as? NSView, let sidebar = sidebarItem?.viewController.view,
            responder.isDescendant(of: sidebar), responder !== sidebarKeyTarget?(), let terminal = store.selected?.terminal
        else { return }
        window.makeFirstResponder(terminal)
    }
}

/// The tips (onboarding 7.6, D-3, D-6): the banner under the title bar,
/// what covers its place, a press on it, the marks and ⌘K that raise them,
/// and Help ▸ Reset Tips.
extension TerminalWindowController {
    /// The banner's host, in the held settings banner's place and under
    /// it: one view over the body that resizes nothing, hidden while no tip
    /// shows. It never takes the keyboard (`TipBannerHostingView`).
    func installTipBanner(in content: NSView, top: NSLayoutYAxisAnchor, under heldBanner: NSView, theme: ChromeTheme) {
        let host = TipBannerHostingView(
            rootView: TipBannerView(start: .shared, model: tipModel, theme: theme) { [weak self] action in self?.performTipAction(action) })
        host.translatesAutoresizingMaskIntoConstraints = false
        host.isHidden = true
        content.addSubview(host, positioned: .below, relativeTo: heldBanner)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: top, constant: 14),
            host.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            host.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])
        tipBanner = host
        guard Start.shared.active else { return }

        // `@Published` emits before the value lands: the emitted one decides.
        Start.shared.$state
            .map(\.banner)
            .removeDuplicates()
            .sink { [weak self] banner in self?.tipChanged(banner) }
            .store(in: &cancellables)
        Settings.shared.$held
            .map(\.isEmpty)
            .removeDuplicates()
            .sink { [weak self] empty in self?.updateTipRoom(heldShown: !empty) }
            .store(in: &cancellables)
        // Each token kept, removed at the window's close (`windowWillClose`).
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            tipObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tipFrontChanged() }
                })
        }
        // A sheet: begun, it covers the place before `attachedSheet` says so.
        tipObservers.append(
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTipRoom(sheet: true) }
            })
        tipObservers.append(
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTipRoom(sheet: false) }
            })
        tipObservers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTipRoom() }
            })
        updateTipRoom()
    }

    /// What covers the tip's place in this window — a sheet, ⌘K, Tab
    /// Peek, the held settings banner — said to `Start` by the key window,
    /// with whether the app is in front: a tip is placed only where it is
    /// seen. An isolated run counts as in front (the scenario's app may
    /// not be; it asks macOS nothing).
    package func updateTipRoom(sheet: Bool? = nil, heldShown: Bool? = nil) {
        guard Start.shared.active, let window else { return }
        let blocked = tipBlocked(sheet: sheet, heldShown: heldShown)
        tipBanner?.isHidden = Start.shared.state.banner == nil || blocked
        guard window.isKeyWindow || NSApp.keyWindow == nil else { return }
        Start.shared.room(blocked: blocked, inFront: NSApp.isActive || AppEnvironment.isIsolated)
    }

    private func tipBlocked(sheet: Bool? = nil, heldShown: Bool? = nil) -> Bool {
        (sheet ?? (window?.attachedSheet != nil)) || paletteView?.isHidden == false || (peekView != nil && peek.isOpen)
            || (heldShown ?? !Settings.shared.held.isEmpty)
    }

    private func tipFrontChanged() {
        updateTipRoom()
        // Back in front with T1 up: what macOS says may have changed meanwhile.
        if NSApp.isActive, case .needsYou = Start.shared.state.banner { readTipPermission() }
    }

    /// A tip placed, or gone: the banner shown or hidden; a new one said
    /// to VoiceOver — the focus stays where it is.
    private func tipChanged(_ banner: StartState.Banner?) {
        tipBanner?.isHidden = banner == nil || tipBlocked()
        guard let banner else { return }
        if banner.tip == .needsYou {
            tipModel.permission = nil
            readTipPermission()
        }
        guard let host = tipBanner, !host.isHidden, window?.isKeyWindow == true || NSApp.keyWindow == nil else { return }
        let words = TipBannerView.text(keys: .shared).tip(banner)
        NSAccessibility.post(
            element: host, notification: .announcementRequested,
            userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Notifications as macOS says now, for T1's offer — never a kept "allowed" (D-14).
    private func readTipPermission() {
        Task { [weak self] in
            let permission = await AttentionNotifier.authorizationState()
            self?.tipModel.permission = permission
        }
    }

    /// A tab's mark went up, by one of T1's three ways: what kind, for its words.
    func noteMarkRaised(on tab: Tab) {
        guard Start.shared.active else { return }
        // What covers the place now, not as the last notice said.
        updateTipRoom(sheet: window?.attachedSheet != nil)
        let mark: StartState.Mark
        switch tab.activity.mark {
        case .waiting: mark = .waiting
        case .done: mark = .done
        case .failed: mark = .failed
        case .none: return
        }
        Start.shared.note(.markRaised(mark, tab: tab.title))
    }

    /// ⌘K showing: T3's words for its hint row on its first three showings, else none.
    func paletteTip() -> String? {
        let start = Start.shared
        guard start.active else { return nil }
        start.note(.paletteOpened)
        guard start.state.paletteTip else { return nil }
        return TipBannerView.text(keys: .shared).paletteTip(ghosttyConfig: AppEnvironment.ghosttyConfigFile != nil)
    }

    /// A press on a tip. Open Inbox and a Settings page open what they
    /// name and leave the keyboard where that puts it; the rest give back
    /// to the selected terminal a keyboard a click left on the banner
    /// (onboarding risk 1) — a key press, Full Keyboard Access, keeps it.
    package func performTipAction(_ action: TipAction) {
        let start = Start.shared
        switch action {
        case .openInbox:
            if inboxItem?.isCollapsed == true { toggleInbox(nil) }
            return
        case .settings(let section):
            openSettings(section)
            return
        case .allowNotifications:
            // The system's question, by this click, its reason beside it (D-6).
            Task { [weak self] in
                let permission = await AttentionNotifier.requestNow()
                self?.tipModel.permission = permission
            }
        case .dismiss:
            start.dismissTip()
        case .turnOffTips:
            start.turnOffTips()
        }
        guard NSApp.currentEvent?.type != .keyDown, let window, let terminal = store.selected?.terminal else { return }
        let responder = window.firstResponder
        var onTip = false
        if let view = responder as? NSView, let host = tipBanner { onTip = view.isDescendant(of: host) }
        if onTip || responder === window { window.makeFirstResponder(terminal) }
    }

    /// Help ▸ Reset Tips and its ⌘K row: asked once, then every tip shows
    /// again the next time its moment comes, and ⌘K counts its three again.
    @objc package func resetTips(_ sender: Any?) {
        guard Start.shared.active, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Show every tip again?"
        alert.informativeText =
            "Each tip shows once more, the next time what it explains comes up."
            + (Settings.shared.tips ? "" : " Tips are off: Settings ▸ General ▸ Getting started and tips turns them on.")
        alert.addButton(withTitle: "Reset Tips")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { Start.shared.resetTips() }
        }
    }
}

/// The Setup page (onboarding 7.7): a page over the body like Activity's,
/// opened only by the person — Help ▸ Check Setup…, its ⌘K row, the Start
/// card's link, the "isn't on your PATH" warning — never by itself. Read
/// while it shows; dropped when it goes.
extension TerminalWindowController {
    package func setupWorkspacePage() -> WorkspacePage {
        var page = WorkspacePage(.setup)
        page.makeView = { [weak self] in
            guard let self, let theme = self.theme else { return nil }
            let view = SetupHostingView(
                rootView: SetupView(model: self.setupPage, theme: theme) { [weak self] action in self?.performSetupAction(action) })
            // Esc: the page put away, the keyboard back to the terminal.
            view.escape = { [weak self] in self?.hideOverlay() }
            return view
        }
        // The panels' tools by the features' own finders, which live above Overterm.
        setupPage.readPanels = { await SetupPanelProbe.read() }
        // The emitted value: `showingOverlay` isn't set yet.
        page.visibilityChanged = { [weak self] visible in self?.setupPage.visible = visible }
        page.closed = { [weak self] in self?.setupPage.visible = false }
        page.windowClosing = { [weak self] in self?.setupPage.visible = false }
        return page
    }

    /// Help ▸ Check Setup… and every link to it: the page shown, with the
    /// keyboard — the person asked for it (`showOverlay`).
    @objc package func showSetup(_ sender: Any?) {
        showOverlay(.setup)
    }

    /// A press on the page. Nothing is fixed for the person: a command is
    /// copied, or typed into a new tab without Return (3.2).
    package func performSetupAction(_ action: SetupPageAction) {
        switch action {
        case .checkAgain:
            setupPage.checkAgain()
        case .copy(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .newTab(let command):
            if let setupTabRecorder { return setupTabRecorder(command) }
            hideOverlay(focus: false)
            newTab(in: FileManager.default.homeDirectoryForCurrentUser, typing: command)
        case .open(let url):
            // An isolated run opens nothing in the default browser.
            guard !AppEnvironment.isIsolated else { return }
            NSWorkspace.shared.open(url)
        case .settings(let section, let key):
            openSettings(section, focus: key)
        case .allowNotifications:
            setupPage.allowNotifications()
        case .usageAsk(let on):
            setupPage.setUsageAsk(on)
        case .resetTips:
            resetTips(nil)
        case .panels(let open):
            setupPage.setPanelsOpen(open)
        }
    }
}
