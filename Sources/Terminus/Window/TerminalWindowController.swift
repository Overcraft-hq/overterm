import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// One Terminus window: the tab strip in the title bar; below it the
/// collapsible sidebar and the selected tab's terminal. Every tab's
/// TerminalView stays alive in the container (hidden and occluded when not
/// selected) so its pty and scrollback survive tab switches.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let store = TabStore()
    private let container = NSView()
    private let tree = FileTreeModel()
    private let worktrees = WorktreeModel()
    let snippets = SnippetStore()
    private let palette = PaletteModel()
    private var paletteView: NSView?
    private var tabBarView: NSView?
    private var rightClickMonitor: Any?
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private let diff = DiffModel()
    /// Diff panel above the terminal, inside the terminal pane.
    private let terminalSplit = NSSplitViewController()
    private var diffItem: NSSplitViewItem?
    private var cancellables: Set<AnyCancellable> = []
    /// Follows the selected tab's cwd into the file tree.
    private var cwdSubscription: AnyCancellable?

    private static let sidebarVisibleKey = "sidebarVisible"
    private static let diffVisibleKey = "diffVisible"

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty compact toolbar makes the title bar tall enough for tabs
        // and vertically centres the traffic lights in it.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = GhosttyRuntime.shared.backgroundColor
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("TerminusMainWindow")
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)

        store.$selectedID
            .sink { [weak self] _ in
                // @Published fires before the value lands; read it next turn.
                DispatchQueue.main.async { self?.showSelectedTab() }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildLayout(in window: NSWindow) {
        let runtime = GhosttyRuntime.shared
        let theme = ChromeTheme(background: runtime.backgroundColor, foreground: runtime.foregroundColor)
        let tabBar = NSHostingView(
            rootView: TabBarView(
                store: store,
                theme: theme,
                leadingInset: 78,
                actions: TabBarActions(
                    select: { [weak self] in self?.store.select($0) },
                    close: { [weak self] in self?.closeTab($0) },
                    newTab: { [weak self] in self?.newTab(from: self?.store.selected?.terminal) },
                    newAgentTab: { [weak self] in self?.newAgentTab($0) },
                    newTask: { [weak self] in self?.newTask(nil) },
                    renameEnded: { [weak self] in self?.focusSelectedTerminal() },
                    setPinned: { [weak self] tab, pinned in self?.store.setPinned(tab, pinned) }
                )
            )
            .background(theme.strip)
            // The strip sits in the title bar on purpose; without this SwiftUI
            // pads it down by the title bar's safe-area inset.
            .ignoresSafeArea()
        )

        // Sidebar | terminal. A plain split item, not the sidebar kind: that
        // one paints its own translucent material over our theme colour.
        let sidebar = NSHostingController(
            rootView: SidebarView(
                tree: tree,
                worktrees: worktrees,
                snippets: snippets,
                theme: theme,
                actions: FileTreeActions(
                    insertPath: { [weak self] in self?.insertPath($0) },
                    newTab: { [weak self] in self?.newTab(in: $0) },
                    relativePath: { [weak self] in self?.relativePath($0) ?? $0.path }
                ),
                worktreeActions: WorktreeActions(
                    open: { [weak self] in self?.openWorktree($0) },
                    newTab: { [weak self] in self?.newTab(in: $0.path) },
                    newAgentTab: { [weak self] worktree, agent in self?.newTab(in: worktree.path, agent: agent) },
                    remove: { [weak self] in self?.removeWorktree($0) },
                    newTask: { [weak self] in self?.newTask(nil) }
                ),
                snippetActions: SnippetActions(
                    use: { [weak self] snippet, run in self?.useSnippet(snippet, run: run) },
                    edit: { [weak self] in self?.editSnippet($0) }
                ),
                onClose: { [weak self] in self?.toggleFileTree(nil) }
            ))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 520
        sidebarItem.holdingPriority = .defaultLow + 10
        // Shown on first launch; after that, as the user left it.
        sidebarItem.isCollapsed = !(UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true)
        let terminalPane = NSViewController()
        terminalPane.view = container

        // Diff over terminal. Hidden by default: it runs git while open.
        let diffPanel = NSHostingController(
            rootView: DiffPanelView(model: diff, theme: theme, onClose: { [weak self] in self?.toggleDiff(nil) }))
        diffPanel.sizingOptions = []
        let diffItem = NSSplitViewItem(viewController: diffPanel)
        diffItem.canCollapse = true
        diffItem.minimumThickness = 120
        diffItem.holdingPriority = .defaultLow + 10
        let showDiff = UserDefaults.standard.bool(forKey: Self.diffVisibleKey)
        diffItem.isCollapsed = !showDiff
        diff.isActive = showDiff
        let terminalItem = NSSplitViewItem(viewController: terminalPane)
        terminalItem.minimumThickness = 120
        terminalSplit.splitView.isVertical = false
        terminalSplit.addSplitViewItem(diffItem)
        terminalSplit.addSplitViewItem(terminalItem)
        terminalSplit.splitView.dividerStyle = .thin
        terminalSplit.splitView.autosaveName = "TerminusDiff"
        self.diffItem = diffItem

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: terminalSplit))
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "TerminusSidebar"
        self.sidebarItem = sidebarItem

        tabBarView = tabBar
        installTabRightClick()

        let content = NSView()
        let body = split.view
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabBar)
        content.addSubview(body)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: titleBarHeight(of: window)),
            body.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // The palette floats over everything, hidden until ⌘P.
        let paletteView = NSHostingView(
            rootView: PaletteView(
                model: palette,
                theme: theme,
                onChoose: { [weak self] item, run in
                    self?.hidePalette()
                    item.perform(run)
                },
                onDismiss: { [weak self] in self?.hidePalette() }
            ))
        paletteView.translatesAutoresizingMaskIntoConstraints = false
        paletteView.isHidden = true
        content.addSubview(paletteView)
        NSLayoutConstraint.activate([
            paletteView.topAnchor.constraint(equalTo: content.topAnchor),
            paletteView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paletteView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paletteView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.paletteView = paletteView
        window.contentView = content
    }

    private func titleBarHeight(of window: NSWindow) -> CGFloat {
        max(window.frame.height - window.contentLayoutRect.height, 28)
    }

    // MARK: Tabs

    /// Opens a tab after `source`'s, starting in its directory at its font size.
    func newTab(from source: TerminalView?) {
        let inherited = source?.inheritedSettings()
        let terminal = TerminalView(workingDirectory: inherited?.workingDirectory, fontSize: inherited?.fontSize)
        addTab(terminal, after: store.tabs.first { $0.terminal === source })
    }

    private func addTab(_ terminal: TerminalView, agent: Agent? = nil, after anchor: Tab?) {
        let tab = Tab(terminal: terminal, agent: agent)
        terminal.onTitleChange = { [weak tab] in tab?.shellTitle = $0 }
        terminal.onWorkingDirectoryChange = { [weak tab] in tab?.workingDirectory = $0 }
        terminal.onEvent = { [weak self, weak tab] event in
            guard let self, let tab else { return }
            if tab.activity.handle(event, visible: self.isVisible(tab)) {
                AttentionNotifier.notify(tab: tab)
            }
            if event == .bell, self.isVisible(tab) { NSSound.beep() }
            self.updateAttentionBadge()
        }
        terminal.onClose = { [weak self, weak tab, weak terminal] processAlive in
            guard let self, let tab else { return }
            // A pinned tab ignores close requests (Ghostty's cmd+w is
            // close_surface) but still goes away when its process exits.
            if tab.isPinned, terminal?.processExited == false { return }
            self.closeTab(tab, confirm: processAlive)
        }

        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        store.insert(tab, after: anchor)
    }

    /// Opens a tab after the selected one, starting in `directory` — and
    /// starting `agent` in it, if given.
    func newTab(in directory: URL, agent: Agent? = nil) {
        let fontSize = store.selected?.terminal.inheritedSettings().fontSize
        let terminal = TerminalView(workingDirectory: directory.path, initialInput: agent.map { $0.command + "\n" }, fontSize: fontSize)
        addTab(terminal, agent: agent, after: store.selected)
    }

    // MARK: Attention

    /// Actually in front of you: selected, in the key window, app active.
    private func isVisible(_ tab: Tab) -> Bool {
        NSApp.isActive && window?.isKeyWindow == true && store.selectedID == tab.id
    }

    /// The selected tab has been seen once the window is in front.
    private func markSelectedSeen() {
        guard let tab = store.selected, isVisible(tab), tab.activity.needsAttention else { return }
        tab.activity.seen()
        AttentionNotifier.withdraw(tab: tab)
        updateAttentionBadge()
    }

    private func updateAttentionBadge() {
        AttentionNotifier.updateBadge(count: store.tabs.filter { $0.activity.needsAttention }.count)
    }

    /// Brings up a tab a notification was about.
    func reveal(tabID: UUID) {
        guard let tab = store.tabs.first(where: { $0.id == tabID }) else { return }
        store.select(tab)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        markSelectedSeen()
        // Catches what the file watcher can't see, e.g. staging from another
        // app (a worktree's index lives in the main repository's .git).
        Task { await diff.refresh() }
    }

    // MARK: Session

    var sessionState: SessionState {
        SessionState(
            tabs: store.tabs.map {
                .init(
                    workingDirectory: $0.workingDirectory, customTitle: $0.customTitle, color: $0.color?.rawValue,
                    isPinned: $0.isPinned, agent: $0.agent)
            },
            selectedIndex: store.selectedIndex)
    }

    /// Rebuilds saved tabs: a fresh shell in each old directory (home if it
    /// is gone), agents resuming their last conversation there.
    func restore(_ state: SessionState) {
        for saved in state.tabs {
            let cwd = saved.workingDirectory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            let terminal = TerminalView(workingDirectory: cwd, initialInput: saved.agent.map { $0.resumeCommand + "\n" })
            addTab(terminal, agent: saved.agent, after: store.tabs.last)
            guard let tab = store.tabs.last else { continue }
            tab.customTitle = saved.customTitle
            tab.color = saved.color.flatMap(TabColor.init(rawValue:))
            if saved.isPinned { store.setPinned(tab, true) }
        }
        if let i = state.selectedIndex { store.select(index: i) }
    }

    /// Saves the session a second after anything about the tabs changes, so
    /// a crash loses at most that second.
    func autosaveSession(to url: URL = SessionState.defaultURL) {
        let tabChanges = store.$tabs
            .map { tabs in Publishers.MergeMany(tabs.map { $0.objectWillChange }).map { _ in () }.prepend(()) }
            .switchToLatest()
        tabChanges.merge(with: store.$selectedID.map { _ in () })
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.saveSession(to: url) }
            .store(in: &cancellables)
    }

    func saveSession(to url: URL = SessionState.defaultURL) {
        do {
            try sessionState.save(to: url)
        } catch {
            GhosttyRuntime.logger.error("session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// An agent tab in the selected tab's directory.
    func newAgentTab(_ agent: Agent) {
        let cwd = store.selected?.terminal.inheritedSettings().workingDirectory
        newTab(in: URL(fileURLWithPath: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path), agent: agent)
    }

    // MARK: Worktrees

    private func tabs(in worktree: Worktree) -> [Tab] {
        store.tabs.filter { tab in
            tab.workingDirectory.flatMap { Worktree.containing($0, in: worktrees.worktrees) } == worktree
        }
    }

    /// Selects the (first) tab already in `worktree`, else opens one there.
    func openWorktree(_ worktree: Worktree) {
        if let tab = tabs(in: worktree).first {
            store.select(tab)
        } else {
            newTab(in: worktree.path)
        }
    }

    /// `git worktree remove`, after confirming. Refused while a tab is in it:
    /// its shell would be left in a deleted directory. A dirty worktree gets
    /// a second, explicit Force.
    func removeWorktree(_ worktree: Worktree, force: Bool = false) {
        guard let window, let repo = worktrees.main?.path else { return }
        let open = tabs(in: worktree)
        guard open.isEmpty else {
            showAlert(
                "Close its tabs first",
                "“\(worktree.displayName)” has \(open.count) open tab\(open.count == 1 ? "" : "s"). Close \(open.count == 1 ? "it" : "them") before removing the worktree.")
            return
        }
        let alert = NSAlert()
        alert.messageText = force ? "Force-remove “\(worktree.displayName)”?" : "Remove worktree “\(worktree.displayName)”?"
        alert.informativeText =
            force
            ? "It has uncommitted or untracked changes. Force-removing deletes them. The branch is kept."
            : "Deletes \(worktree.path.path). The branch is kept."
        alert.addButton(withTitle: force ? "Force Remove" : "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = force ? .critical : .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await Git.run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path.path], in: repo)
                    await self.worktrees.refresh()
                } catch {
                    // git refuses a dirty worktree without --force; offer it.
                    if !force, (error as? GitError)?.stderr.contains("--force") == true {
                        self.removeWorktree(worktree, force: true)
                    } else {
                        self.showAlert("Couldn’t remove the worktree", error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: Tasks

    /// New Task: a worktree on a new (or existing) branch next to the repo,
    /// then a tab in it named after the branch, with the agent started.
    @objc func newTask(_ sender: Any?) {
        guard let repo = worktrees.main?.path else {
            showAlert("Not in a git repository", "Open a tab inside a repository first; the task’s worktree is created from it.")
            return
        }
        presentSheet { close in
            NewTaskView(
                repo: repo,
                defaultBase: worktrees.main?.branch ?? "HEAD",
                onCreate: { [weak self] branch, base, agent in
                    guard let self else { return nil }
                    do {
                        let path = try await TaskCreator.create(repo: repo, branch: branch, base: base)
                        close()
                        self.newTab(in: path, agent: agent)
                        self.store.selected?.customTitle = branch
                        await self.worktrees.refresh()
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                },
                onCancel: close
            )
        }
    }

    // MARK: Tab context menu

    /// Right-clicks on the strip never reach SwiftUI: the strip lives in the
    /// title bar, which takes them first. So the window catches them before
    /// dispatch, finds the tab under the pointer and shows the menu itself.
    private func installTabRightClick() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.window, let strip = self.tabBarView else { return event }
            var point = strip.convert(event.locationInWindow, from: nil)
            guard strip.bounds.contains(point) else { return event }
            if !strip.isFlipped { point.y = strip.bounds.height - point.y }
            guard let tab = self.store.tab(at: point) else { return event }
            NSMenu.popUpContextMenu(self.menu(for: tab), with: event, for: strip)
            return nil
        }
    }

    private func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        if !tab.isPinned {
            menu.addItem(
                ClosureMenuItem("Rename Tab…") { [weak self] in
                    self?.store.select(tab)
                    self?.store.renamingID = tab.id
                })
        }
        if tab.customTitle != nil {
            menu.addItem(ClosureMenuItem("Reset Name") { tab.customTitle = nil })
        }
        menu.addItem(
            ClosureMenuItem(tab.isPinned ? "Unpin Tab" : "Pin Tab") { [weak self] in
                self?.store.setPinned(tab, !tab.isPinned)
            })

        let colors = NSMenu()
        for color in TabColor.allCases {
            let item = ClosureMenuItem(color.name, state: tab.color == color ? .on : .off) {
                tab.color = tab.color == color ? nil : color
            }
            item.image = color.swatch
            colors.addItem(item)
        }
        colors.addItem(.separator())
        colors.addItem(ClosureMenuItem("None", enabled: tab.color != nil) { tab.color = nil })
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New Tab to the Right") { [weak self] in self?.newTab(from: tab.terminal) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Tab", enabled: !tab.isPinned) { [weak self] in self?.closeTab(tab) })
        let others = store.tabs.filter { $0.id != tab.id && !$0.isPinned }
        menu.addItem(ClosureMenuItem("Close Other Tabs", enabled: !others.isEmpty) { [weak self] in others.forEach { self?.closeTab($0) } })
        let right = store.index(of: tab).map { Array(store.tabs[($0 + 1)...]).filter { !$0.isPinned } } ?? []
        menu.addItem(ClosureMenuItem("Close Tabs to the Right", enabled: !right.isEmpty) { [weak self] in right.forEach { self?.closeTab($0) } })
        return menu
    }

    // MARK: Palette

    @objc func showPalette(_ sender: Any?) {
        guard let paletteView else { return }
        if !paletteView.isHidden {
            hidePalette()
            return
        }
        palette.reset(with: paletteItems())
        paletteView.isHidden = false
        // The hosting view is reused, so its field has to be focused on
        // every show, after SwiftUI has laid it out.
        DispatchQueue.main.async { [weak self] in
            guard let field = Self.firstTextField(in: paletteView) else { return }
            self?.window?.makeFirstResponder(field)
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }

    private func hidePalette() {
        paletteView?.isHidden = true
        focusSelectedTerminal()
    }

    /// Actions first, then tabs, worktrees and snippets — the order shown
    /// before typing.
    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = [
            PaletteItem(id: "a.newTab", group: .action, title: "New Tab", subtitle: "⌘T", symbol: "plus") { [weak self] _ in
                self?.newTab(from: self?.store.selected?.terminal)
            },
            PaletteItem(id: "a.newTask", group: .action, title: "New Task…", subtitle: "Worktree + branch + agent  ⇧⌘N", symbol: "arrow.triangle.branch") {
                [weak self] _ in self?.newTask(nil)
            },
        ]
        items += Agent.allCases.map { agent in
            PaletteItem(id: "a.agent.\(agent.rawValue)", group: .action, title: "New \(agent.name) Tab", subtitle: nil, symbol: agent.symbol) {
                [weak self] _ in self?.newAgentTab(agent)
            }
        }
        items += [
            PaletteItem(id: "a.sidebar", group: .action, title: "Toggle Sidebar", subtitle: "⌘B", symbol: "sidebar.left") { [weak self] _ in
                self?.toggleFileTree(nil)
            },
            PaletteItem(id: "a.diff", group: .action, title: "Toggle Diff", subtitle: "⌥⌘D", symbol: "plusminus") { [weak self] _ in
                self?.toggleDiff(nil)
            },
            PaletteItem(id: "a.snippet", group: .action, title: "New Snippet…", subtitle: nil, symbol: "text.badge.plus") { [weak self] _ in
                self?.editSnippet(nil)
            },
            PaletteItem(id: "a.snippetsFile", group: .action, title: "Open Snippets File", subtitle: snippets.url.path, symbol: "doc.text") {
                [weak self] _ in
                guard let self else { return }
                NSWorkspace.shared.open(self.snippets.url)
            },
        ]
        items += store.tabs.map { tab in
            PaletteItem(
                id: "t.\(tab.id)", group: .tab, title: tab.title, subtitle: tab.workingDirectory,
                symbol: tab.agent?.symbol ?? (tab.isPinned ? "pin" : "terminal")
            ) { [weak self] _ in self?.store.select(tab) }
        }
        items += worktrees.worktrees.map { worktree in
            PaletteItem(
                id: "w.\(worktree.path.path)", group: .worktree, title: worktree.displayName, subtitle: worktree.path.path,
                symbol: worktree.isMain ? "house" : "arrow.triangle.branch"
            ) { [weak self] _ in self?.openWorktree(worktree) }
        }
        items += snippets.snippets.map { snippet in
            PaletteItem(id: "s.\(snippet.id)", group: .snippet, title: snippet.name, subtitle: snippet.command, symbol: "text.alignleft") {
                [weak self] run in self?.useSnippet(snippet, run: run)
            }
        }
        return items
    }

    // MARK: Snippets

    /// Types a snippet into the selected terminal — Return too when `run` —
    /// asking for its placeholder values first if it has any.
    func useSnippet(_ snippet: Snippet, run: Bool) {
        guard snippet.placeholders.isEmpty else {
            presentSheet { close in
                SnippetFillView(
                    snippet: snippet,
                    onUse: { [weak self] command, run in
                        close()
                        self?.type(command, run: run)
                    },
                    onCancel: close)
            }
            return
        }
        type(snippet.command, run: run)
    }

    private func type(_ command: String, run: Bool) {
        guard let terminal = store.selected?.terminal else { return }
        terminal.insertText(command)
        if run { terminal.pressReturn() }
        focusSelectedTerminal()
    }

    func editSnippet(_ snippet: Snippet?) {
        presentSheet { close in
            SnippetEditorView(
                snippet: snippet ?? Snippet(name: "", command: ""),
                isNew: snippet == nil,
                onSave: { [weak self] edited in
                    self?.snippets.upsert(edited)
                    close()
                },
                onCancel: close)
        }
    }

    /// Shows a SwiftUI view as a sheet; the builder gets the closure that
    /// dismisses it.
    private func presentSheet<Content: View>(_ build: (@escaping () -> Void) -> Content) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let close = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
        }
        sheet.contentViewController = NSHostingController(rootView: build(close))
        window.beginSheet(sheet) { [weak self] _ in self?.focusSelectedTerminal() }
    }

    private func showAlert(_ title: String, _ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: Paths

    /// `url` as the selected tab's shell would write it: relative to its cwd
    /// when inside it, else absolute.
    func relativePath(_ url: URL) -> String {
        Self.relativePath(url, cwd: store.selected?.workingDirectory)
    }

    nonisolated static func relativePath(_ url: URL, cwd: String?) -> String {
        let path = url.standardizedFileURL.path
        guard let cwd = cwd.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) else { return path }
        if path == cwd { return "." }
        return path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
    }

    /// Types the path into the selected terminal, shell-quoted, with a
    /// trailing space so the next word can follow.
    private func insertPath(_ url: URL) {
        guard let terminal = store.selected?.terminal else { return }
        terminal.insertText(Self.shellQuoted(relativePath(url)) + " ")
        focusSelectedTerminal()
    }

    /// Leaves plain paths bare; anything with shell metacharacters goes in
    /// single quotes.
    nonisolated static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+,:@%"))
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Closes a tab, asking first when that would kill a running process.
    /// `confirm` is libghostty's verdict when it initiated the close; for a
    /// close from our UI we ask the surface.
    func closeTab(_ tab: Tab, confirm: Bool? = nil) {
        let needsConfirm = confirm ?? tab.terminal.needsConfirmClose
        guard needsConfirm, let window else {
            removeTab(tab)
            return
        }
        store.select(tab)
        let alert = NSAlert()
        alert.messageText = "Close Tab?"
        alert.informativeText = "A process is still running in “\(tab.title)”. Closing the tab will kill it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.removeTab(tab)
        }
    }

    private func removeTab(_ tab: Tab) {
        AttentionNotifier.withdraw(tab: tab)
        tab.terminal.close()
        tab.terminal.removeFromSuperview()
        store.remove(tab)
        updateAttentionBadge()
        if store.tabs.isEmpty { window?.close() }
    }

    func closeTabs(of view: TerminalView, mode: ghostty_action_close_tab_mode_e) {
        guard let tab = store.tabs.first(where: { $0.terminal === view }), let i = store.index(of: tab) else { return }
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            store.tabs.filter { $0.id != tab.id && !$0.isPinned }.forEach { closeTab($0) }
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            store.tabs[(i + 1)...].filter { !$0.isPinned }.forEach { closeTab($0) }
        default:
            if !tab.isPinned { closeTab(tab) }
        }
    }

    /// Ghostty's goto_tab: 1-based index, or previous/next/last.
    func gotoTab(_ value: Int32) -> Bool {
        guard store.tabs.count > 1 else { return false }
        switch value {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: store.selectAdjacent(-1)
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: store.selectAdjacent(1)
        case GHOSTTY_GOTO_TAB_LAST.rawValue: store.select(index: store.tabs.count - 1)
        case 1...: store.select(index: min(Int(value) - 1, store.tabs.count - 1))
        default: return false
        }
        return true
    }

    func moveTab(of view: TerminalView, by amount: Int) {
        guard let tab = store.tabs.first(where: { $0.terminal === view }) else { return }
        store.move(tab, by: amount)
    }

    private func focusSelectedTerminal() {
        guard let terminal = store.selected?.terminal else { return }
        window?.makeFirstResponder(terminal)
    }

    private func showSelectedTab() {
        guard let selected = store.selected else { return }
        for tab in store.tabs where tab.id != selected.id {
            tab.terminal.setVisible(false)
        }
        selected.terminal.setVisible(true)
        window?.makeFirstResponder(selected.terminal)
        window?.title = selected.title
        markSelectedSeen()
        cwdSubscription = selected.$workingDirectory
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] cwd in
                let root = FileTreeModel.treeRoot(for: cwd)
                self?.tree.setRoot(root)
                self?.worktrees.setAnchor(root)
                self?.diff.setRoot(root)
            }
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { newTab(from: store.selected?.terminal) }
    @objc func newClaudeTab(_ sender: Any?) { newAgentTab(.claude) }
    @objc func newCodexTab(_ sender: Any?) { newAgentTab(.codex) }
    @objc func closeTab(_ sender: Any?) {
        guard let tab = store.selected else { return }
        if tab.isPinned {
            NSSound.beep()
        } else {
            closeTab(tab)
        }
    }

    @objc func toggleDiff(_ sender: Any?) {
        guard let diffItem else { return }
        let show = diffItem.isCollapsed
        diffItem.animator().isCollapsed = !show
        diff.isActive = show
        UserDefaults.standard.set(show, forKey: Self.diffVisibleKey)
        if !show { focusSelectedTerminal() }
    }

    @objc func toggleFileTree(_ sender: Any?) {
        guard let sidebarItem else { return }
        let show = sidebarItem.isCollapsed
        sidebarItem.animator().isCollapsed = !show
        UserDefaults.standard.set(show, forKey: Self.sidebarVisibleKey)
        // Collapsing can strand keyboard focus in the hidden panel.
        if !show { focusSelectedTerminal() }
    }

    @objc func togglePinTab(_ sender: Any?) {
        guard let tab = store.selected else { return }
        store.setPinned(tab, !tab.isPinned)
    }
    @objc func selectNextTab(_ sender: Any?) { store.selectAdjacent(1) }
    @objc func selectPreviousTab(_ sender: Any?) { store.selectAdjacent(-1) }

    // MARK: NSWindowDelegate

    /// The window's close button closes every tab; confirm once if any has a
    /// running process.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = store.tabs.filter { $0.terminal.needsConfirmClose }
        guard !busy.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close Window?"
        alert.informativeText =
            "\(busy.count) tab\(busy.count == 1 ? " has a" : "s have") running process\(busy.count == 1 ? "" : "es"). Closing the window will kill \(busy.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: sender) { response in
            guard response == .alertFirstButtonReturn else { return }
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        for tab in store.tabs { tab.terminal.close() }
    }
}
