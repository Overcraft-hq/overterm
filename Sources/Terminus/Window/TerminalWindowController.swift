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
    /// Each tab's panes, laid out; only the selected tab's is visible.
    private var hosts: [Tab.ID: SplitHostView] = [:]
    private(set) var tree = FileTreeModel()
    private(set) var worktrees = WorktreeModel()
    let snippets = SnippetStore()
    private(set) var palette = PaletteModel()
    private(set) var paletteView: NSView?
    private(set) var tabBarView: NSView?
    private var rightClickMonitor: Any?
    private var dragMonitor: Any?
    /// The find bar, over the terminal's top-right corner; shows the
    /// selected terminal's search while it is active.
    private(set) var searchBar: NSHostingView<AnyView>?
    private var searchSubscription: AnyCancellable?
    /// The ⌘F overlay over the terminal (terminal + files + contents).
    let spotlight = SpotlightModel()
    private(set) var spotlightView: NSView?
    /// Polls where the selected tab's agent works (see Tab.agentDirectory).
    private var agentPoll: Timer?
    /// Shared across Tab Info popovers so CPU deltas and env reads carry over.
    private let inspector = ProcessInspector()
    /// Kept across popovers: transcripts are re-read only where they grew.
    private let claudeReader = ClaudeUsageReader()
    private(set) var infoPopover: NSPopover?
    private(set) var infoModel: TabInfoModel?
    private var theme: ChromeTheme?
    /// A press on a tab that may become a drag: the tab and where it began.
    private var pressedTab: (tab: Tab, x: CGFloat)?
    // Readable (not writable) outside so the E2E scenarios can check them.
    private(set) var split = WideDividerSplitViewController()
    private(set) var sidebarItem: NSSplitViewItem?
    /// Reads the checkout's Claude transcripts for why each file changed.
    private(set) var diff = DiffModel(transcripts: ClaudeEditsReader())
    /// The right pane's switch (Changes / Pull Request) and the PR it shows.
    let rightPane = RightPane()
    /// ⇧⌘A: every tab as a card.
    let overview = AgentOverviewModel()
    /// The Sessions panel's Claude conversations.
    let sessions = SessionsModel()
    private(set) var overviewView: NSView?
    private var overviewPoll: Timer?
    /// Esc while the overview shows, wherever the keyboard is: its host
    /// having it was not enough (a click, or the terminal behind, took it).
    private var overviewEscape: Any?
    let pullRequest = PullRequestModel()
    /// Asks GitHub again every minute: CI moves while nothing local changes.
    private var pullRequestPoll: Timer?
    private var finalSaveDone = false
    private(set) var editor: EditorViewController?
    /// Opens files in the app picked for them (the file tree, the editor's ↗).
    let opener = ExternalOpener()
    private(set) var editorItem: NSSplitViewItem?
    private(set) var diffItem: NSSplitViewItem?
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

        applySettingsAsTheyChange()
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
        self.theme = theme
        opener.window = window
        let tabBar = TabStripHostingView(
            rootView: TabBarView(
                store: store,
                diff: diff,
                worktrees: worktrees,
                updates: .shared,
                theme: theme,
                leadingInset: 78,
                actions: TabBarActions(
                    select: { [weak self] in self?.store.select($0) },
                    close: { [weak self] in self?.closeTab($0) },
                    newTab: { [weak self] in self?.newTab(from: self?.store.selected?.terminal) },
                    newAgentTab: { [weak self] in self?.newAgentTab($0) },
                    newTask: { [weak self] in self?.newTask(nil) },
                    toggleDiff: { [weak self] in self?.toggleDiffFromBadge() },
                    showPullRequest: { [weak self] in self?.showPullRequest(nil) },
                    showOverview: { [weak self] in self?.showAgentOverview(nil) },
                    showUpdate: { SettingsWindowController.shared.show(.about) },
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
                sessions: sessions,
                opener: opener,
                theme: theme,
                actions: FileTreeActions(
                    insertPath: { [weak self] in self?.insertPath($0) },
                    openInEditor: { [weak self] in self?.openInEditor($0) },
                    openExternally: { [weak self] in self?.openExternally($0) },
                    newTab: { [weak self] in self?.newTab(in: $0) },
                    relativePath: { [weak self] in self?.relativePath($0) ?? $0.path }
                ),
                worktreeActions: WorktreeActions(
                    open: { [weak self] in self?.openWorktree($0) },
                    newTab: { [weak self] in self?.newTab(in: $0.path) },
                    newAgentTab: { [weak self] worktree, agent in self?.newTab(in: worktree.path, agent: agent) },
                    remove: { [weak self] in self?.removeWorktree($0) },
                    attach: { [weak self] in self?.attach($0) },
                    detach: { [weak self] in self?.detach() },
                    newTask: { [weak self] in self?.newTask(nil) },
                    cleanUp: { [weak self] in self?.cleanUpMergedWorktrees(nil) },
                    showPullRequest: { [weak self] in self?.showPullRequest(nil) }
                ),
                snippetActions: SnippetActions(
                    use: { [weak self] snippet, run in self?.useSnippet(snippet, run: run) },
                    edit: { [weak self] in self?.editSnippet($0) }
                ),
                sessionActions: SessionActions(
                    resume: { [weak self] in self?.resume($0) },
                    resumeInNewTab: { [weak self] in self?.resume($0, inNewTab: true) },
                    refresh: { [weak self] in self?.refreshSessions() }
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
        sidebarItem.isCollapsed = !(AppEnvironment.defaults.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true)
        let terminalPane = NSViewController()
        terminalPane.view = container

        let searchBar = NSHostingView(rootView: AnyView(EmptyView()))
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = true
        container.addSubview(searchBar)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])
        self.searchBar = searchBar

        let spotlightView = NSHostingView(
            rootView: SpotlightView(
                model: spotlight, theme: theme,
                onChoose: { [weak self] in self?.chooseSpotlight($0) },
                onDismiss: { [weak self] in self?.hideSpotlight(keepTerminalSearch: false) }))
        spotlightView.translatesAutoresizingMaskIntoConstraints = false
        spotlightView.isHidden = true
        container.addSubview(spotlightView)
        NSLayoutConstraint.activate([
            spotlightView.topAnchor.constraint(equalTo: container.topAnchor),
            spotlightView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            spotlightView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            spotlightView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.spotlightView = spotlightView

        // Editor to the right of the terminal, opened from the file tree.
        let editor = EditorViewController(
            theme: theme, background: runtime.backgroundColor, foreground: runtime.foregroundColor, opener: opener)
        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.canCollapse = true
        editorItem.isCollapsed = true
        editorItem.minimumThickness = 280
        editorItem.holdingPriority = .defaultLow + 5
        editor.onClose = { [weak self] in self?.closeEditor() }
        self.editor = editor
        self.editorItem = editorItem

        // Changes pane on the far right, as in Warp; opened from the ± badge
        // in the title bar, View ▸ Changes or ⌥⌘D.
        let diffPanel = NSHostingController(
            rootView: RightPaneView(
                pane: rightPane, diff: diff, worktrees: worktrees, theme: theme,
                changes: DiffPanelView(
                    model: diff, theme: theme,
                    onClose: { [weak self] in self?.toggleDiff(nil) },
                    onDetach: { [weak self] in self?.detach() },
                    onOpen: { [weak self] in self?.openInEditor($0) }),
                pullRequest: PullRequestView(
                    model: pullRequest, theme: theme,
                    onClose: { [weak self] in self?.toggleDiff(nil) },
                    onOpenFile: { [weak self] path, line in
                        guard let self, let root = self.diff.root else { return }
                        self.openInEditor(root.appendingPathComponent(path), line: line)
                    })))
        diffPanel.sizingOptions = []
        let diffItem = NSSplitViewItem(viewController: diffPanel)
        diffItem.canCollapse = true
        diffItem.minimumThickness = 320
        diffItem.holdingPriority = .defaultLow + 5
        let showDiff = AppEnvironment.defaults.bool(forKey: Self.diffVisibleKey)
        diffItem.isCollapsed = !showDiff
        diff.panelVisible = showDiff
        self.diffItem = diffItem
        watchPullRequests()

        // The terminal pane never gives up all its width to the panels
        // beside it (it had no minimum and could be dragged to 0).
        let terminalColumn = NSSplitViewItem(viewController: terminalPane)
        terminalColumn.minimumThickness = 240
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(terminalColumn)
        split.addSplitViewItem(editorItem)
        split.addSplitViewItem(diffItem)
        split.splitView.dividerStyle = .thin
        // A diagnostic run shares the real app's defaults: it must not save
        // (or restore) divider positions. The key changes with the column
        // set (v2: diff moved here), so old positions aren't misapplied.
        if !AppEnvironment.isIsolated { split.splitView.autosaveName = "TerminusColumns.v2" }
        self.sidebarItem = sidebarItem

        tabBarView = tabBar
        installTabRightClick()
        installTabDragging()
        startAgentPoll()

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

        let overviewView = AgentOverviewHostingView(
            rootView: AgentOverviewView(
                model: overview, worktrees: worktrees, theme: theme,
                onChoose: { [weak self] in self?.chooseOverviewCard($0) },
                onDismiss: { [weak self] in self?.hideAgentOverview() }))
        overviewView.onEscape = { [weak self] in self?.hideAgentOverview() }
        overviewView.translatesAutoresizingMaskIntoConstraints = false
        overviewView.isHidden = true
        content.addSubview(overviewView)
        NSLayoutConstraint.activate([
            overviewView.topAnchor.constraint(equalTo: content.topAnchor),
            overviewView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overviewView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overviewView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.overviewView = overviewView
        window.contentView = content
    }

    private func titleBarHeight(of window: NSWindow) -> CGFloat {
        max(window.frame.height - window.contentLayoutRect.height, 28)
    }

    // MARK: Tabs

    /// Opens a tab after `source`'s, starting in its directory at its font size.
    func newTab(from source: TerminalView?) {
        let inherited = source?.inheritedSettings()
        // The tab's own OSC 7 directory first: libghostty's inherited pwd can
        // lag it under load, and the new tab then opened in ~.
        let known = source?.workingDirectory
        // Settings ▸ General: new tabs in the current tab's folder, or home.
        let directory = Settings.shared.newTabDirectory == .home ? nil : known ?? inherited?.workingDirectory
        let terminal = TerminalView(workingDirectory: directory, fontSize: inherited?.fontSize)
        addTab(terminal, after: tab(containing: source))
    }

    private func addTab(_ terminal: TerminalView, agent: Agent? = nil, after anchor: Tab?) {
        let tab = Tab(terminal: terminal, agent: agent)
        wire(terminal, in: tab)

        let host = SplitHostView(
            dividerColor: GhosttyRuntime.shared.foregroundColor.withAlphaComponent(0.18),
            dimColor: Self.paneDim)
        host.onRatioChange = { [weak self, weak tab] path, ratio in
            guard let self, let tab else { return }
            tab.setSplits(tab.splits.settingRatio(ratio, at: path))
            self.refreshHost(tab)
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hosts[tab.id] = host
        refreshHost(tab)
        store.insert(tab, after: anchor)
    }

    /// Connects one pane to its tab and the window. The tab's title and
    /// directory follow the focused pane; events and attention are the tab's.
    private func wire(_ pane: TerminalView, in tab: Tab) {
        pane.onTitleChange = { [weak tab, weak pane] title in
            guard let tab, tab.terminal === pane else { return }
            tab.shellTitle = title
        }
        pane.onWorkingDirectoryChange = { [weak tab, weak pane] directory in
            guard let tab, tab.terminal === pane else { return }
            tab.workingDirectory = directory
        }
        pane.onFocus = { [weak self, weak tab, weak pane] in
            guard let self, let tab, let pane, tab.splits.contains(pane) else { return }
            tab.focus(pane)
            self.refreshHost(tab)
            if self.store.selectedID == tab.id { self.bindSearchBar(to: pane) }
        }
        pane.onSearchRequest = { [weak self, weak pane] needle in
            guard let self, let pane else { return }
            self.showSpotlight(for: pane, needle: needle)
        }
        pane.onOpenLink = { [weak self, weak tab, weak pane] text in
            guard let self, let tab else { return false }
            let directories = [pane?.workingDirectory, tab.workingDirectory, self.diff.root?.path].compactMap { $0 }
            guard let link = FileLink.resolve(text, in: directories) else { return false }
            self.openInEditor(link.url, line: link.line)
            return true
        }
        pane.onEvent = { [weak self, weak tab] event in
            guard let self, let tab else { return }
            if tab.activity.handle(event, visible: self.isVisible(tab)) {
                AttentionNotifier.notify(tab: tab)
            }
            if event == .bell, self.isVisible(tab) { NSSound.beep() }
            self.updateAttentionBadge()
        }
        pane.onClose = { [weak self, weak tab, weak pane] _ in
            // The shell exiting (you typed exit) closes silently; Ghostty's ⌘W
            // (close_surface) asks, and a pinned tab ignores it. libghostty
            // can call this a moment before it marks the process exited, so
            // look again shortly before deciding it was ⌘W.
            Task { @MainActor [weak self, weak tab, weak pane] in
                for attempt in 0...4 {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
                    guard let self, let tab, let pane else { return }
                    if pane.processExited {
                        self.removePane(pane, from: tab)
                        return
                    }
                }
                guard let self, let tab, let pane else { return }
                if tab.isSplit {
                    self.closePane(pane, in: tab)
                } else if !tab.isPinned {
                    self.closeTab(tab)
                }
            }
        }
    }

    /// The view laying out `tab`'s panes.
    func host(of tab: Tab) -> SplitHostView? { hosts[tab.id] }

    private func refreshHost(_ tab: Tab) {
        hosts[tab.id]?.update(tree: tab.splits, focused: tab.terminal, zoomed: tab.zoomed)
    }

    /// The tab `pane` is in.
    func tab(containing pane: TerminalView?) -> Tab? {
        guard let pane else { return nil }
        return store.tabs.first { $0.splits.contains(pane) }
    }

    // MARK: Splits

    /// Splits `source` (else the selected tab's focused pane): a new pane
    /// on `direction`'s side, in the same directory, with the keyboard.
    func split(_ source: TerminalView?, _ direction: SplitTree<TerminalView>.Direction) {
        guard let tab = tab(containing: source) ?? store.selected else { return }
        let from = source.flatMap { tab.splits.contains($0) ? $0 : nil } ?? tab.terminal
        let inherited = from.inheritedSettings()
        let pane = TerminalView(workingDirectory: from.workingDirectory ?? inherited.workingDirectory, fontSize: inherited.fontSize)
        wire(pane, in: tab)
        tab.zoomed = nil
        tab.setSplits(tab.splits.inserting(pane, at: from, direction))
        refreshHost(tab)
        if store.selectedID == tab.id { window?.makeFirstResponder(pane) } else { tab.focus(pane) }
    }

    /// Moves the keyboard to the pane beside `source`'s. Unzooms.
    @discardableResult
    func focusSplit(from source: TerminalView?, _ focus: SplitTree<TerminalView>.Focus) -> Bool {
        guard let tab = tab(containing: source) ?? store.selected,
            let next = tab.splits.neighbor(of: source.flatMap { tab.splits.contains($0) ? $0 : nil } ?? tab.terminal, focus)
        else { return false }
        tab.zoomed = nil
        refreshHost(tab)
        window?.makeFirstResponder(next)
        return true
    }

    /// Ghostty's resize_split: `points` toward `direction`.
    func resizeSplit(_ source: TerminalView?, toward direction: SplitTree<TerminalView>.Direction, points: Double) {
        guard let tab = tab(containing: source) ?? store.selected, let host = hosts[tab.id] else { return }
        let size = direction.axis == .horizontal ? host.bounds.width : host.bounds.height
        guard size > 0 else { return }
        tab.setSplits(tab.splits.resizing(source ?? tab.terminal, toward: direction, by: points / Double(size)))
        refreshHost(tab)
    }

    func equalizeSplits(_ source: TerminalView?) {
        guard let tab = tab(containing: source) ?? store.selected else { return }
        tab.setSplits(tab.splits.equalized())
        refreshHost(tab)
    }

    /// The focused pane alone, filling the tab — or back to all of them.
    func toggleSplitZoom(_ source: TerminalView?) {
        guard let tab = tab(containing: source) ?? store.selected, tab.isSplit else { return }
        let pane = source.flatMap { tab.splits.contains($0) ? $0 : nil } ?? tab.terminal
        tab.zoomed = tab.zoomed == nil ? pane : nil
        refreshHost(tab)
        window?.makeFirstResponder(pane)
    }

    /// ⌘W on a pane of a split tab: closes it, asking first only if
    /// something runs in it (closing the whole tab always asks).
    func closePane(_ pane: TerminalView, in tab: Tab) {
        guard tab.isSplit else { return closeTab(tab) }
        guard pane.needsConfirmClose, let window else { return removePane(pane, from: tab) }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "Something is still running in it. Closing kills it."
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak tab, weak pane] response in
            guard response == .alertFirstButtonReturn, let self, let tab, let pane else { return }
            self.removePane(pane, from: tab)
        }
    }

    /// Takes `pane` out of `tab` — the tab itself when it was its last pane.
    /// A pane no longer in the tab is left alone: a close confirmed in a
    /// sheet, or an exit noticed late, after the pane had already gone
    /// would otherwise close the tab — and the panes left in it — unasked.
    func removePane(_ pane: TerminalView, from tab: Tab) {
        guard tab.splits.contains(pane) else { return }
        guard tab.isSplit, let rest = tab.splits.removing(pane) else { return removeTab(tab) }
        let wasFocused = tab.terminal === pane
        pane.close()
        pane.removeFromSuperview()
        tab.setSplits(rest)
        refreshHost(tab)
        if wasFocused, store.selectedID == tab.id { window?.makeFirstResponder(tab.terminal) }
    }

    /// Opens a tab after the selected one, starting in `directory` — and
    /// starting `agent` in it, if given.
    /// `startAgent: false` makes an agent tab without starting the agent
    /// (the E2E scenarios use it; nothing else should).
    /// `command`: what starts the agent, when not its plain command (a resume).
    func newTab(in directory: URL, agent: Agent? = nil, startAgent: Bool = true, command: String? = nil) {
        let fontSize = store.selected?.terminal.inheritedSettings().fontSize
        let input = startAgent ? agent.map { (command ?? $0.command(arguments: Settings.shared.arguments(for: $0))) + "\n" } : nil
        let terminal = TerminalView(workingDirectory: directory.path, initialInput: input, fontSize: fontSize)
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

    // MARK: Claude sessions

    /// Re-lists the sessions of the repository's worktrees (or, outside
    /// one, of the file tree's root).
    func refreshSessions() {
        let directories = worktrees.worktrees.isEmpty ? [tree.root?.path].compactMap { $0 } : worktrees.worktrees.map(\.path.path)
        Task { await sessions.refresh(directories: directories, tabs: store.tabs, inspector: inspector) }
    }

    /// The tab a session runs in, or — `inNewTab`, or not running — a new
    /// tab in its directory with `claude --resume <id>`. `start: false`
    /// opens the tab without typing it (the E2E scenarios; nothing else).
    func resume(_ session: ClaudeSession, inNewTab: Bool = false, start: Bool = true) {
        if !inNewTab, let id = sessions.running[session.id], let tab = store.tabs.first(where: { $0.id == id }) {
            store.select(tab)
            focusSelectedTerminal()
            return
        }
        guard let command = Agent.claudeResume(session: session.id, arguments: Settings.shared.claudeArguments) else { return }
        newTab(in: URL(fileURLWithPath: session.directory), agent: .claude, startAgent: start, command: command)
    }

    // MARK: Clipboard confirmations

    /// A sheet is asking about a clipboard request: one at a time.
    private var askingClipboard = false

    /// libghostty wants `confirmation` confirmed for `terminal`: a paste that
    /// could run commands, or a program reading the clipboard. Asks in a
    /// sheet — for the selected tab only, one at a time; anything else is
    /// refused at once — and tells `answer` whether it's allowed.
    func confirmClipboard(_ confirmation: ClipboardConfirmation, from terminal: TerminalView, answer: @escaping @MainActor (Bool) -> Void) {
        let fromSelectedTab = store.selected?.terminals.contains { $0 === terminal } == true
        guard let window, ClipboardConfirmation.shouldAsk(fromSelectedTab: fromSelectedTab, alreadyAsking: askingClipboard) else {
            return answer(false)
        }
        askingClipboard = true
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message(tab: store.selected?.title ?? "this tab")
        alert.accessoryView = Self.clipboardPreview(confirmation.preview())
        // Deny (Cancel) first: Return answers no, and handing anything over
        // takes a click. A Return already on its way to the terminal must
        // never paste or share. Set here rather than left to AppKit, which
        // hands keys out late and drops them when the app isn't frontmost.
        alert.addButton(withTitle: confirmation.denyTitle).keyEquivalent = "\r"
        alert.addButton(withTitle: confirmation.allowTitle).keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.askingClipboard = false
            answer(response == .alertSecondButtonReturn)
        }
    }

    /// The text a clipboard sheet is about: scrollable, selectable, monospaced.
    private static func clipboardPreview(_ text: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
        scroll.borderType = .bezelBorder
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.string = text
        }
        return scroll
    }

    // MARK: Opening from Finder

    /// Finder's Open With, the Dock icon, the "New Terminus Tab Here"
    /// service: a folder becomes a tab there; a file opens in the editor, in
    /// a tab already in its checkout if there is one, else a new tab in its
    /// folder (so the sidebar and changes match it).
    func open(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                newTab(in: url)
                continue
            }
            let folder = url.deletingLastPathComponent()
            let checkout = FileTreeModel.treeRoot(for: folder.path).standardizedFileURL
            if let tab = store.tabs.first(where: { $0.checkoutSource?.root.standardizedFileURL == checkout }) {
                store.select(tab)
            } else {
                newTab(in: folder)
            }
            // After the tab's checkout lands in the sidebar and changes pane.
            DispatchQueue.main.async { [weak self] in self?.openInEditor(url) }
        }
        window?.makeKeyAndOrderFront(nil)
        if !AppEnvironment.isIsolated { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        markSelectedSeen()
        editor?.reloadIfChangedOnDisk()
        // Catches what the watchers can't see: they cover the checkout and its
        // git state, not all of .git (packed-refs, say).
        Task { await diff.refresh() }
    }

    // MARK: Session

    var sessionState: SessionState { sessionState(scrollback: [:]) }

    /// `scrollback`: each pane's saved text, by pane (only at quit).
    func sessionState(scrollback: [ObjectIdentifier: String]) -> SessionState {
        SessionState(
            tabs: store.tabs.map { tab in
                .init(
                    workingDirectory: tab.workingDirectory, customTitle: tab.customTitle, color: tab.color?.rawValue,
                    isPinned: tab.isPinned, agent: tab.agent, attachedCheckout: tab.attachedCheckout?.path,
                    panes: tab.isSplit
                        ? SessionState.PaneLayout(tab.splits, directory: \.workingDirectory, scrollback: { scrollback[ObjectIdentifier($0)] })
                        : nil,
                    focusedPane: tab.isSplit ? tab.terminals.firstIndex { $0 === tab.terminal } : nil,
                    scrollback: tab.isSplit ? nil : scrollback[ObjectIdentifier(tab.terminal)])
            },
            selectedIndex: store.selectedIndex)
    }

    /// The last save, at quit or when the window closes (whichever comes
    /// first — after it the terminals are gone): with each shell pane's
    /// text. Agent tabs' aren't kept: their conversation resumes instead.
    func saveFinalSession(to url: URL = SessionState.defaultURL) {
        guard !finalSaveDone else { return }
        finalSaveDone = true
        var saved: [ObjectIdentifier: String] = [:]
        // Settings ▸ General: reopening tabs, and each shell pane's text with them.
        for tab in store.tabs where tab.agent == nil && Settings.shared.restoreTabs && Settings.shared.restoreScrollback {
            for pane in tab.terminals {
                if let text = pane.scrollbackText, let name = Scrollback.save(text) { saved[ObjectIdentifier(pane)] = name }
            }
        }
        Scrollback.removeAll(except: Set(saved.values))
        do {
            try sessionState(scrollback: saved).save(to: url)
        } catch {
            GhosttyRuntime.logger.error("session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rebuilds saved tabs: a fresh shell in each old directory (home if it
    /// is gone), agents resuming their last conversation there.
    func restore(_ state: SessionState) {
        func existing(_ path: String?) -> String? { path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } }
        for saved in state.tabs {
            // A split tab's panes, the first resuming the agent; else one terminal.
            var made: [TerminalView] = []
            let layout = saved.panes?.tree { directory, scrollback -> TerminalView in
                let pane = TerminalView(
                    workingDirectory: existing(directory), initialInput: made.isEmpty ? saved.agent.map { $0.resumeCommand(arguments: Settings.shared.arguments(for: $0)) + "\n" } : nil,
                    restoring: Scrollback.file(named: scrollback))
                made.append(pane)
                return pane
            }
            let terminal =
                made.first
                ?? TerminalView(
                    workingDirectory: existing(saved.workingDirectory), initialInput: saved.agent.map { $0.resumeCommand(arguments: Settings.shared.arguments(for: $0)) + "\n" },
                    restoring: Scrollback.file(named: saved.scrollback))
            addTab(terminal, agent: saved.agent, after: store.tabs.last)
            guard let tab = store.tabs.last else { continue }
            if let layout, made.count > 1 {
                made.dropFirst().forEach { wire($0, in: tab) }
                tab.setSplits(layout)
                refreshHost(tab)
                if let i = saved.focusedPane, made.indices.contains(i) {
                    tab.focus(made[i])
                    refreshHost(tab)
                    // The keyboard too (the pane is in the window now): the
                    // first pane took it as the tab was added.
                    if store.selectedID == tab.id { window?.makeFirstResponder(made[i]) }
                }
            }
            tab.customTitle = saved.customTitle
            tab.color = saved.color.flatMap(TabColor.init(rawValue:))
            tab.attachedCheckout = saved.attachedCheckout.flatMap {
                FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
            }
            if saved.isPinned { store.setPinned(tab, true) }
        }
        if let i = state.selectedIndex { store.select(index: i) }
    }

    /// Saves the session when anything about the tabs changes, at most once
    /// a second, so a crash loses at most that second. A throttle, not a
    /// debounce: a working agent changes its tab's title and activity many
    /// times a second, and a debounce waiting for a quiet second never saved.
    func autosaveSession(to url: URL = SessionState.defaultURL) {
        let tabChanges = store.$tabs
            .map { tabs in Publishers.MergeMany(tabs.map { $0.objectWillChange }).map { _ in () }.prepend(()) }
            .switchToLatest()
        tabChanges.merge(with: store.$selectedID.map { _ in () })
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.saveSession(to: url) }
            .store(in: &cancellables)
    }

    /// What the last save wrote, so an unchanged session isn't written again.
    private var savedSession: (url: URL, data: Data)?

    func saveSession(to url: URL = SessionState.defaultURL) {
        // After the final save, a late autosave — the terminals closing
        // change their tabs — would write over it without the scrollback.
        guard !finalSaveDone else { return }
        do {
            let data = try sessionState.encoded()
            if let savedSession, savedSession.url == url, savedSession.data == data { return }
            try SessionState.write(data, to: url)
            savedSession = (url, data)
        } catch {
            GhosttyRuntime.logger.error("session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// An agent tab in the selected tab's directory.
    func newAgentTab(_ agent: Agent) {
        let cwd = store.selected?.terminal.inheritedSettings().workingDirectory
        newTab(in: URL(fileURLWithPath: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path), agent: agent)
    }

    // MARK: Find in terminal

    /// Shows `terminal`'s find bar while its search is active; a search
    /// starting (showBar) gives the field the keyboard. Rebinding — whenever
    /// a terminal takes focus — only shows or hides the bar: taking the
    /// keyboard there bounced Esc and clicks straight back into the bar.
    private func bindSearchBar(to terminal: TerminalView) {
        guard let searchBar, let theme else { return }
        searchBar.rootView = AnyView(
            TerminalSearchBar(search: terminal.search, theme: theme, onDismiss: { [weak self] in self?.focusSelectedTerminal() }))
        showSearchBar(terminal.search.barVisible)
        // $barVisible replays its current value to a new subscriber — just
        // shown above, without the keyboard.
        searchSubscription = terminal.search.$barVisible
            .dropFirst()
            .sink { [weak self] active in
                guard let self else { return }
                self.showSearchBar(active)
                guard active, let searchBar = self.searchBar else { return }
                DispatchQueue.main.async {
                    if let field = Self.firstTextField(in: searchBar) { self.window?.makeFirstResponder(field) }
                }
            }
    }

    /// Shows or hides the find bar, above the terminals (a new tab's view is
    /// added later).
    private func showSearchBar(_ visible: Bool) {
        guard let searchBar else { return }
        searchBar.isHidden = !visible
        if visible, let container = searchBar.superview {
            container.addSubview(searchBar, positioned: .above, relativeTo: nil)
        }
    }

    /// ⌘F with the terminal focused comes through Ghostty's own binding;
    /// this is the menu's way in.
    @objc func findInTerminal(_ sender: Any?) {
        guard let terminal = store.selected?.terminal else { return }
        showSpotlight(for: terminal, needle: nil)
    }

    /// The ⌘F overlay for `terminal`, searching it and its tab's checkout.
    func showSpotlight(for terminal: TerminalView, needle: String?) {
        guard let spotlightView else { return }
        spotlight.open(root: diff.root ?? tree.root, terminal: terminal, needle: needle)
        spotlightView.isHidden = false
        spotlightView.superview?.addSubview(spotlightView, positioned: .above, relativeTo: nil)
        DispatchQueue.main.async { [weak self] in
            if let field = Self.firstTextField(in: spotlightView) { self?.window?.makeFirstResponder(field) }
        }
    }

    func hideSpotlight(keepTerminalSearch: Bool) {
        spotlightView?.isHidden = true
        spotlight.close(keepTerminalSearch: keepTerminalSearch)
        focusSelectedTerminal()
    }

    private func chooseSpotlight(_ row: SpotlightModel.Row) {
        switch row {
        case .terminal:
            // Keep the highlights; step through them with the compact bar.
            hideSpotlight(keepTerminalSearch: true)
            spotlight.terminal?.search.showBar()
        case .file(let path):
            guard let root = spotlight.root else { return }
            hideSpotlight(keepTerminalSearch: false)
            openInEditor(root.appendingPathComponent(path))
        case .content(let match):
            guard let root = spotlight.root else { return }
            hideSpotlight(keepTerminalSearch: false)
            openInEditor(root.appendingPathComponent(match.path), line: match.line)
        }
    }

    // MARK: Following the agent

    /// Every 2 s, where the selected tab's agent process (claude, codex)
    /// works. Claude Code moves its process into a worktree on
    /// EnterWorktree (and back on exit); the sidebar and diff follow.
    private func startAgentPoll() {
        agentPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAgentDirectory() }
        }
    }

    /// A scan still running: the next tick skips it (see pollAgentDirectory).
    private var agentPollInFlight = false

    private func pollAgentDirectory() {
        // A process scan slower than the 2 s tick (a loaded machine) would
        // otherwise stack up scans on the pool, their answers out of order.
        guard !agentPollInFlight, let tab = store.selected else { return }
        agentPollInFlight = true
        // The focused pane's agent first, then any other pane's.
        let panes = [tab.terminal] + tab.terminals.filter { $0 !== tab.terminal }
        let roots = panes.map { (SurfaceProcesses.shared.loginPID(of: $0), $0.processTag) }
        let inspector = self.inspector
        DispatchQueue.global(qos: .utility).async {
            let agent = Self.firstAgent(in: roots) { inspector.tree(root: $0, tag: $1) }
            let directory = agent?.workingDirectory
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.agentPollInFlight = false
                    // Only when it differs from the shell's: an agent in the
                    // tab's own directory changes nothing.
                    let shell = tab.workingDirectory.map { FileTreeModel.treeRoot(for: $0) }
                    let following = directory.flatMap { FileTreeModel.treeRoot(for: $0) == shell ? nil : $0 }
                    if tab.agentDirectory != following { tab.agentDirectory = following }
                }
            }
        }
    }

    /// The first agent process under a tab's panes (`roots`: each pane's
    /// login and tag, in order). `tree` is ProcessInspector.tree, read once
    /// per pane: it answers from the live process table, differently from
    /// one read to the next. (`lazy.compactMap(…).first` read the pane it
    /// returned twice and force-unwrapped the second answer — an agent
    /// exiting in between crashed the app.)
    nonisolated static func firstAgent(in roots: [(pid_t?, String)], tree: (pid_t?, String) -> [ProcessNode]) -> ProcessNode? {
        for (root, tag) in roots {
            if let agent = tree(root, tag).flatMap(\.flattened).first(where: isAgent) { return agent }
        }
        return nil
    }

    /// Claude Code or Codex, by process name or argv[0].
    nonisolated static func isAgent(_ node: ProcessNode) -> Bool {
        let names = ["claude", "codex"]
        if names.contains(node.name) { return true }
        guard let first = node.command.split(separator: " ").first else { return false }
        let base = (String(first) as NSString).lastPathComponent
        return names.contains(base)
    }

    /// Pins the selected tab's sidebar and diff to `worktree`.
    func attach(_ worktree: Worktree) {
        store.selected?.attachedCheckout = worktree.path
    }

    /// Back to following the agent / shell.
    func detach() {
        store.selected?.attachedCheckout = nil
    }

    // MARK: Worktrees

    /// Tabs whose shell is in `worktree` — or whose agent works there
    /// (Claude Code moves into a worktree on its own): Clean Up and Remove
    /// must not pull a worktree from under a running agent.
    private func tabs(in worktree: Worktree) -> [Tab] {
        store.tabs.filter { tab in
            [tab.workingDirectory, tab.agentDirectory].contains { directory in
                directory.flatMap { Worktree.containing($0, in: worktrees.worktrees) } == worktree
            }
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

    /// Removes the linked worktrees whose branch is merged (or whose folder
    /// is already gone), after fetching and one confirmation listing what
    /// goes and what stays. Kept: a worktree with a tab in it, uncommitted
    /// changes, or a lock — the same things single removal refuses.
    @objc func cleanUpMergedWorktrees(_ sender: Any?) {
        guard let repo = worktrees.main?.path else { return NSSound.beep() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.worktrees.refresh(fetch: true)
            var removable: [Worktree] = []
            var kept: [(Worktree, String)] = []
            for worktree in self.worktrees.cleanable {
                if worktree.isPrunable {
                    removable.append(worktree)
                } else if worktree.isLocked {
                    kept.append((worktree, "locked"))
                } else if !self.tabs(in: worktree).isEmpty {
                    kept.append((worktree, "open in a tab"))
                } else if await Self.hasChanges(worktree.path) {
                    kept.append((worktree, "uncommitted changes"))
                } else {
                    removable.append(worktree)
                }
            }
            self.confirmCleanUp(removable: removable, kept: kept, repo: repo)
        }
    }

    private static func hasChanges(_ path: URL) async -> Bool {
        let status = try? await Git.run(["status", "--porcelain"], in: path)
        // Unreadable counts as changed: never delete what we couldn't check.
        return status.map { !$0.isEmpty } ?? true
    }

    private func confirmCleanUp(removable: [Worktree], kept: [(Worktree, String)], repo: URL) {
        guard let window else { return }
        let keptLines = kept.map { "• \($0.0.displayName) — \($0.1)" }
        guard !removable.isEmpty else {
            showAlert(
                "Nothing to clean up",
                kept.isEmpty ? "No linked worktree is merged." : "Merged, but kept:\n" + keptLines.joined(separator: "\n"))
            return
        }
        let goingLines = removable.map { worktree in
            let why: String
            if worktree.isPrunable {
                why = "folder already gone"
            } else {
                why =
                    switch worktree.branch.flatMap({ worktrees.merged[$0] }) {
                    case .upstreamGone: "deleted on the remote"
                    case .mergedInto(let base): "merged into \(base)"
                    case .pullRequestMerged(let number): "pull request #\(number) merged"
                    case nil: "merged"
                    }
            }
            return "• \(worktree.displayName) — \(why)"
        }
        let alert = NSAlert()
        alert.messageText =
            removable.count == 1 ? "Remove 1 merged worktree?" : "Remove \(removable.count) merged worktrees?"
        alert.informativeText =
            goingLines.joined(separator: "\n") + (kept.isEmpty ? "" : "\n\nKept:\n" + keptLines.joined(separator: "\n"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also delete their branches"
        alert.suppressionButton?.state = .on
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let deleteBranches = alert.suppressionButton?.state == .on
            Task { @MainActor [weak self] in
                await self?.cleanUp(removable, deleteBranches: deleteBranches, repo: repo)
            }
        }
    }

    private func cleanUp(_ removable: [Worktree], deleteBranches: Bool, repo: URL) async {
        var failures: [String] = []
        for worktree in removable where !worktree.isPrunable {
            do {
                // No --force: anything dirty since the check makes git refuse.
                _ = try await Git.run(["worktree", "remove", worktree.path.path], in: repo)
            } catch {
                failures.append("\(worktree.displayName): \(error.localizedDescription)")
                continue
            }
            if deleteBranches, let branch = worktree.branch {
                // -D: a squash-merged branch isn't an ancestor, so -d refuses it;
                // merged-ness was decided above.
                do { _ = try await Git.run(["branch", "-D", branch], in: repo) } catch {
                    failures.append("branch \(branch): \(error.localizedDescription)")
                }
            }
        }
        if removable.contains(where: \.isPrunable) {
            _ = try? await Git.run(["worktree", "prune"], in: repo)
            if deleteBranches {
                for branch in removable.filter(\.isPrunable).compactMap(\.branch) where worktrees.merged[branch] != nil {
                    _ = try? await Git.run(["branch", "-D", branch], in: repo)
                }
            }
        }
        await worktrees.refresh()
        if !failures.isEmpty { showAlert("Some worktrees weren’t removed", failures.joined(separator: "\n")) }
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
                defaultBase: Settings.shared.taskBase.isEmpty ? worktrees.main?.branch ?? "HEAD" : Settings.shared.taskBase,
                defaultAgent: Settings.shared.defaultTaskAgent,
                location: Settings.shared.worktreeLocation,
                onCreate: { [weak self] branch, base, agent in
                    guard let self else { return nil }
                    do {
                        try await self.createTask(repo: repo, branch: branch, base: base, agent: agent)
                        close()
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                },
                onCancel: close
            )
        }
    }

    // MARK: Editor

    /// Shows `url` in the editor pane beside the terminal (after any
    /// unsaved-changes question about the file already open).
    func openInEditor(_ url: URL, line: Int? = nil) {
        guard let editor, let editorItem else { return }
        editor.open(url) { opened in
            guard opened else { return }
            if editorItem.isCollapsed { editorItem.animator().isCollapsed = false }
            if let line { editor.go(toLine: line) }
            editor.focus()
        }
    }

    private func closeEditor() {
        editorItem?.animator().isCollapsed = true
        focusSelectedTerminal()
    }

    /// A file in the app picked for files — asking which first, if none is
    /// yet (or it is gone). The file tree's double-click and "Open in …".
    func openExternally(_ url: URL) {
        opener.open(url)
    }

    // MARK: Layout diagnostics

    /// TERMINUS_DUMP_LAYOUT=<file> (empty: no file): open it in the editor,
    /// print the view tree's frames to stderr, quit. For debugging layout
    /// without anyone having to click around. See docs/debugging.md for the
    /// other TERMINUS_DUMP_* switches.
    func dumpLayoutIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["TERMINUS_DUMP_LAYOUT"] else { return }
        let env = ProcessInfo.processInfo.environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if !path.isEmpty { self.openInEditor(URL(fileURLWithPath: path)) }
            if env["TERMINUS_DUMP_DIFF"] != nil, self.diffItem?.isCollapsed == true { self.toggleDiff(nil) }
            if env["TERMINUS_DUMP_CLOSE"] != nil {
                // ⌘W's menu action: a sheet must come up, the tab must stay.
                // TERMINUS_DUMP_CLOSE=<seconds> waits first (let the shell reach its prompt).
                let wait = Double(env["TERMINUS_DUMP_CLOSE"] ?? "") ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.closeSelectedTab(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.5) { [weak self] in
                    let sheet = (self?.window?.attachedSheet?.contentView?.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)) ?? []
                    FileHandle.standardError.write(
                        Data("close: sheet=\(self?.window?.attachedSheet != nil) tabs=\(self?.store.tabs.count ?? -1) text=\(sheet)\n".utf8))
                    self?.window?.attachedSheet.map { self?.window?.endSheet($0) }
                }
            }
            if env["TERMINUS_DUMP_RENAME"] != nil, let tab = self.store.selected {
                // Exactly what the menu and a double-click do: select, then rename.
                self.store.select(tab)
                self.store.renamingID = tab.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    let responder = self?.window?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
                    FileHandle.standardError.write(
                        Data("rename: still renaming=\(self?.store.renamingID != nil) firstResponder=\(responder)\n".utf8))
                }
            }
            let settle = 1.5 + (Double(env["TERMINUS_DUMP_CLOSE"] ?? "") ?? 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self, let content = self.window?.contentView else { return }
                var out = "window \(self.window!.frame.size) split dividers=\(self.split.splitView.dividerThickness)\n"
                @MainActor func walk(_ v: NSView, _ depth: Int) {
                    guard depth < 11 else { return }
                    let name = String(describing: Swift.type(of: v)).prefix(60)
                    out += String(repeating: "  ", count: depth) + "\(name) \(v.frame.integral)\(v.isHidden ? " HIDDEN" : "")\n"
                    for sub in v.subviews { walk(sub, depth + 1) }
                }
                walk(content, 0)
                if let clip = (self.editor?.view.subviews.compactMap { $0 as? NSScrollView }.first)?.contentView {
                    out += "editor clip bounds \(clip.bounds.integral)\n"
                }
                for (i, item) in self.split.splitViewItems.enumerated() {
                    out += "outer item \(i) collapsed=\(item.isCollapsed) frame=\(item.viewController.view.frame.integral)\n"
                }
                // The composited window as it is on screen (terminal included).
                // An app may capture its own windows without Screen Recording
                // permission; cacheDisplay misses layer-backed content here.
                if let png = ProcessInfo.processInfo.environment["TERMINUS_DUMP_PNG"] { self.captureWindow(to: png) }
                // Drag both dividers 80 pt with in-process events (posted to
                // this app's own queue only) and see whether the panes follow.
                let splitView = self.split.splitView
                for (i, divider) in [(0, "sidebar|terminal"), (1, "terminal|editor")] {
                    let items = self.split.splitViewItems
                    guard items.count > i + 1, !items[i].isCollapsed || i == 1 else { continue }
                    let before = items.map { Int($0.viewController.view.frame.width) }
                    // 3 pt off the drawn line: inside the widened grab area only.
                    let x = items[i].viewController.view.superview!.frame.maxX + splitView.dividerThickness / 2 + 3
                    let yLocal = splitView.bounds.midY
                    let start = splitView.convert(NSPoint(x: x, y: yLocal), to: nil)
                    let end = NSPoint(x: start.x + (i == 0 ? 80 : -80), y: start.y)
                    let windowNumber = self.window!.windowNumber
                    func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                        NSEvent.mouseEvent(
                            with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    }
                    let hit = self.window!.contentView!.hitTest(self.window!.contentView!.convert(start, from: nil))
                    NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
                    NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
                    self.window!.sendEvent(mouse(.leftMouseDown, start))
                    let after = self.split.splitViewItems.map { Int($0.viewController.view.frame.width) }
                    out += "drag \(divider) at x=\(Int(start.x)) hit=\(hit.map { String(describing: Swift.type(of: $0)) } ?? "nil") widths \(before) -> \(after)\n"
                }
                FileHandle.standardError.write(Data(out.utf8))
                // TERMINUS_DUMP_PNG=<file>: also a picture of the AppKit/SwiftUI
                // layers (the terminal's Metal layer does not show).
                exit(0)
            }
        }
    }

    /// Writes the composited window, as on screen, to a PNG. An app may
    /// capture its own window without Screen Recording permission;
    /// cacheDisplay misses layer-backed content here.
    func captureWindow(to path: String, window: NSWindow? = nil) {
        guard let window = window ?? self.window,
            let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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

    /// The strip point (top-left origin) under a window event, if the event
    /// is in the strip.
    private func stripPoint(_ event: NSEvent) -> CGPoint? {
        guard event.window === window, let strip = tabBarView else { return nil }
        var point = strip.convert(event.locationInWindow, from: nil)
        guard strip.bounds.contains(point) else { return nil }
        if !strip.isFlipped { point.y = strip.bounds.height - point.y }
        return point
    }

    /// Dragging a tab reorders the strip, live: past a few points of travel,
    /// the tab slots in after every tab of its group whose middle the pointer
    /// has passed (TabStore.dragMove). Handled here, before dispatch, for the same reason as the
    /// context menu — the title bar keeps drags from SwiftUI. The press
    /// itself goes through untouched (it still selects); only the drag
    /// events are taken.
    private func installTabDragging() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.pressedTab = nil
                if self.store.renamingID == nil, let point = self.stripPoint(event), let tab = self.store.tab(at: point) {
                    self.pressedTab = (tab, point.x)
                }
                return event
            case .leftMouseDragged:
                guard let pressed = self.pressedTab, let strip = self.tabBarView, event.window === self.window else { return event }
                var point = strip.convert(event.locationInWindow, from: nil)
                if !strip.isFlipped { point.y = strip.bounds.height - point.y }
                if self.store.draggingID == nil {
                    guard abs(point.x - pressed.x) > 4 else { return nil }
                    self.store.draggingID = pressed.tab.id
                    self.store.select(pressed.tab)
                }
                // Only x matters (the pointer may drift off the strip vertically).
                withAnimation(.easeOut(duration: 0.12)) { self.store.dragMove(pressed.tab, toPointerX: point.x) }
                return nil
            case .leftMouseUp:
                // A press released without dragging is a click: select here,
                // not only in SwiftUI's tap gesture (which doesn't reliably
                // see the press once drags are being taken). Always let the
                // release through — SwiftUI saw the press and must see it end.
                if let pressed = self.pressedTab, self.store.draggingID == nil { self.store.select(pressed.tab) }
                self.pressedTab = nil
                self.store.draggingID = nil
                return event
            default:
                return event
            }
        }
    }

    func menu(for tab: Tab) -> NSMenu {
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
        menu.addItem(ClosureMenuItem("Show Info…") { [weak self] in self?.showInfo(for: tab) })
        menu.addItem(.separator())
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
        menu.addItem(ClosureMenuItem("Close Other Tabs", enabled: !others.isEmpty) { [weak self] in self?.closeTabs(others) })
        let right = store.index(of: tab).map { Array(store.tabs[($0 + 1)...]).filter { !$0.isPinned } } ?? []
        menu.addItem(ClosureMenuItem("Close Tabs to the Right", enabled: !right.isEmpty) { [weak self] in self?.closeTabs(right) })
        return menu
    }

    // MARK: Tab Info

    /// A popover under the tab: its location and what it is running, live
    /// while open.
    func showInfo(for tab: Tab) {
        infoPopover?.close()
        guard let strip = tabBarView, let theme, let frame = store.tabFrames[tab.id] else { return }
        let model = TabInfoModel(tab: tab, inspector: inspector, claudeReader: claudeReader)
        let popover = NSPopover()
        popover.behavior = .transient
        // Its contents are painted in the terminal's colours; its controls
        // must match, or a light-mode button sits black on dark.
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        popover.contentViewController = NSHostingController(rootView: TabInfoView(model: model, theme: theme))
        popover.delegate = self
        // Strip frames are top-left; the host is flipped, so that is its space.
        var rect = frame
        if !strip.isFlipped { rect.origin.y = strip.bounds.height - frame.maxY }
        popover.show(relativeTo: rect, of: strip, preferredEdge: strip.isFlipped ? .maxY : .minY)
        model.start()
        infoPopover = popover
        infoModel = model
    }

    @objc func showSelectedTabInfo(_ sender: Any?) {
        if infoPopover?.isShown == true {
            infoPopover?.close()
        } else if let tab = store.selected {
            showInfo(for: tab)
        }
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

    /// ⇧⌘A: every tab as a card; again (or Esc) hides it.
    @objc func showAgentOverview(_ sender: Any?) {
        guard let overviewView else { return }
        if !overviewView.isHidden { return hideAgentOverview() }
        Task { await overview.refresh(store.tabs, inspector: inspector) }
        overviewView.isHidden = false
        window?.makeFirstResponder(overviewView)
        overviewEscape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, event.window === self.window, self.overviewView?.isHidden == false else { return event }
            self.hideAgentOverview()
            return nil
        }
        overviewPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.overview.refresh(self.store.tabs, inspector: self.inspector) }
            }
        }
    }

    /// A card clicked: its tab, with the keyboard.
    func chooseOverviewCard(_ id: Tab.ID) {
        guard let tab = store.tabs.first(where: { $0.id == id }) else { return }
        hideAgentOverview()
        store.select(tab)
        focusSelectedTerminal()
    }

    func hideAgentOverview() {
        overviewPoll?.invalidate()
        overviewPoll = nil
        if let overviewEscape { NSEvent.removeMonitor(overviewEscape) }
        overviewEscape = nil
        guard overviewView?.isHidden == false else { return }
        overviewView?.isHidden = true
        focusSelectedTerminal()
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
            PaletteItem(id: "a.splitRight", group: .action, title: "Split Right", subtitle: "⌘D", symbol: "rectangle.split.2x1") {
                [weak self] _ in self?.split(nil, .right)
            },
            PaletteItem(id: "a.splitDown", group: .action, title: "Split Down", subtitle: "⇧⌘D", symbol: "rectangle.split.1x2") {
                [weak self] _ in self?.split(nil, .down)
            },
            PaletteItem(id: "a.newTask", group: .action, title: "New Task…", subtitle: "Worktree + branch + agent  ⇧⌘N", symbol: "arrow.triangle.branch") {
                [weak self] _ in self?.newTask(nil)
            },
            PaletteItem(id: "a.overview", group: .action, title: "Agent Overview", subtitle: "Every tab at a glance  ⇧⌘A", symbol: "square.grid.2x2") {
                [weak self] _ in self?.showAgentOverview(nil)
            },
            PaletteItem(id: "a.pullRequest", group: .action, title: "Show Pull Request", subtitle: "Checks, comments, review threads", symbol: "arrow.triangle.pull") {
                [weak self] _ in self?.showPullRequest(nil)
            },
            PaletteItem(
                id: "a.cleanUp", group: .action, title: "Clean Up Merged Worktrees…", subtitle: "Fetch, then remove merged worktrees",
                symbol: "sparkles"
            ) { [weak self] _ in self?.cleanUpMergedWorktrees(nil) },
        ]
        if store.selected?.isSplit == true {
            items += [
                PaletteItem(id: "a.nextPane", group: .action, title: "Next Pane", subtitle: "⌘]", symbol: "arrow.right.square") {
                    [weak self] _ in self?.focusSplit(from: nil, .next)
                },
                PaletteItem(id: "a.zoomPane", group: .action, title: "Zoom Pane", subtitle: "⇧⌘↩ — alone, full size, and back", symbol: "arrow.up.left.and.arrow.down.right") {
                    [weak self] _ in self?.toggleSplitZoom(nil)
                },
                PaletteItem(id: "a.equalizePanes", group: .action, title: "Equalize Panes", subtitle: "⌃⌘=", symbol: "equal.square") {
                    [weak self] _ in self?.equalizeSplits(nil)
                },
                PaletteItem(id: "a.closePane", group: .action, title: "Close Pane", subtitle: "⌘W", symbol: "xmark.square") {
                    [weak self] _ in
                    guard let self, let tab = self.store.selected else { return }
                    self.closePane(tab.terminal, in: tab)
                },
            ]
        }
        items += Agent.allCases.map { agent in
            PaletteItem(id: "a.agent.\(agent.rawValue)", group: .action, title: "New \(agent.name) Tab", subtitle: nil, symbol: agent.symbol) {
                [weak self] _ in self?.newAgentTab(agent)
            }
        }
        items += [
            PaletteItem(id: "a.sidebar", group: .action, title: "Toggle Sidebar", subtitle: "⌘B", symbol: "sidebar.left") { [weak self] _ in
                self?.toggleFileTree(nil)
            },
            PaletteItem(id: "a.diff", group: .action, title: "Changes", subtitle: "Changed files and their diffs  ⌥⌘D", symbol: "plusminus") {
                [weak self] _ in self?.toggleDiff(nil)
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

    /// What New Task does once the sheet is filled in: the worktree, then a
    /// tab in it named after the branch, with the agent started.
    func createTask(repo: URL, branch: String, base: String, agent: Agent?) async throws {
        let path = try await TaskCreator.create(repo: repo, branch: branch, base: base, location: Settings.shared.worktreeLocation)
        newTab(in: path, agent: agent)
        store.selected?.customTitle = branch
        await worktrees.refresh()
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

    // MARK: Closing — always asks (only a shell's own exit closes silently)

    /// Whether the window close has been confirmed, so quitting right after
    /// doesn't ask a second time.
    private(set) var closeConfirmed = false

    /// Closes a tab after confirming.
    func closeTab(_ tab: Tab) {
        closeTabs([tab])
    }

    /// Closes several tabs behind one confirmation.
    func closeTabs(_ tabs: [Tab]) {
        guard !tabs.isEmpty, let window else { return }
        // Settings ▸ General ▸ Ask before closing: only when something runs.
        if !Self.needsCloseConfirmation(tabs) { return tabs.forEach { removeTab($0) } }
        if tabs.count == 1 { store.select(tabs[0]) }
        let alert = NSAlert()
        alert.messageText = tabs.count == 1 ? "Close “\(tabs[0].title)”?" : "Close \(tabs.count) tabs?"
        alert.informativeText = Self.closeWarning(for: tabs)
        alert.addButton(withTitle: tabs.count == 1 ? "Close Tab" : "Close \(tabs.count) Tabs")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            tabs.forEach { self?.removeTab($0) }
        }
    }

    /// Whether closing these tabs asks first: always, unless Settings says
    /// only when something runs in them.
    static func needsCloseConfirmation(_ tabs: [Tab]) -> Bool {
        Settings.shared.confirmClose == .always || tabs.contains { $0.terminals.contains { $0.needsConfirmClose } }
    }

    /// The dim over panes without the keyboard (Settings ▸ Appearance).
    static var paneDim: NSColor { GhosttyRuntime.shared.backgroundColor.withAlphaComponent(Settings.shared.unfocusedPaneDim) }

    /// Appearance settings take effect as they change: the Ghostty overrides
    /// are rewritten and every terminal reloads its config; the pane dim
    /// repaints. Debounced — a slider or stepper moves in small steps.
    private func applySettingsAsTheyChange() {
        let settings = Settings.shared
        Publishers.MergeMany(
            settings.$fontFamily.map { _ in () }.eraseToAnyPublisher(),
            settings.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$theme.map { _ in () }.eraseToAnyPublisher(),
            settings.$windowPadding.map { _ in () }.eraseToAnyPublisher(),
            settings.$cursorStyle.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5)  // each publisher's current value, on subscribing
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink {
            Settings.shared.writeGhosttyOverrides()
            GhosttyRuntime.shared.reloadConfig()
        }
        .store(in: &cancellables)
        settings.$unfocusedPaneDim
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.hosts.values.forEach { $0.dimColor = Self.paneDim }
                }
            }
            .store(in: &cancellables)
        settings.$dockBadge
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateAttentionBadge() } }
            .store(in: &cancellables)
    }

    /// What closing these tabs would end — running processes by name, agents
    /// first, since an agent's conversation is what you'd lose.
    static func closeWarning(for tabs: [Tab]) -> String {
        let busy = tabs.filter { $0.terminals.contains { $0.needsConfirmClose } }
        guard !busy.isEmpty else {
            return tabs.count == 1 ? "Its shell is idle." : "Their shells are idle."
        }
        let names = busy.prefix(3).map { tab in tab.agent.map { "\($0.name) in “\(tab.title)”" } ?? "“\(tab.title)”" }
        let more = busy.count > 3 ? " and \(busy.count - 3) more" : ""
        return "Still running: \(names.joined(separator: ", "))\(more). Closing kills \(busy.count == 1 ? "it" : "them")."
    }

    private func removeTab(_ tab: Tab) {
        AttentionNotifier.withdraw(tab: tab)
        for pane in tab.terminals {
            pane.close()
            pane.removeFromSuperview()
        }
        hosts[tab.id]?.removeFromSuperview()
        hosts[tab.id] = nil
        store.remove(tab)
        updateAttentionBadge()
        guard store.tabs.isEmpty else { return }
        // The editor's unsaved changes keep the window: a fresh tab takes the
        // last one's place instead of the window closing — window.close()
        // skips windowShouldClose, which is where they are asked about.
        if unsavedEditorFile != nil {
            newTab(from: nil)
        } else {
            window?.close()
        }
    }

    /// Removes tabs at once, as their shells exiting would (E2E: the last
    /// tab's close path, without a sheet).
    func closeTabsWithoutAsking(_ tabs: [Tab]) { tabs.forEach { removeTab($0) } }

    /// The editor's file, when it has unsaved changes.
    var unsavedEditorFile: String? {
        guard let editor, editor.document.isDirty else { return nil }
        return editor.document.name
    }

    func closeTabs(of view: TerminalView, mode: ghostty_action_close_tab_mode_e) {
        guard let tab = tab(containing: view), let i = store.index(of: tab) else { return }
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            closeTabs(store.tabs.filter { $0.id != tab.id && !$0.isPinned })
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            closeTabs(store.tabs[(i + 1)...].filter { !$0.isPinned })
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
        guard let tab = tab(containing: view) else { return }
        store.move(tab, by: amount)
    }

    private func focusSelectedTerminal() {
        guard let terminal = store.selected?.terminal else { return }
        window?.makeFirstResponder(terminal)
    }

    private func showSelectedTab() {
        guard let selected = store.selected else { return }
        for tab in store.tabs where tab.id != selected.id {
            hosts[tab.id]?.setVisible(false)
        }
        hosts[selected.id]?.setVisible(true)
        // Not while a tab name is being edited: that field has the keyboard.
        if store.renamingID == nil { window?.makeFirstResponder(selected.terminal) }
        window?.title = selected.title
        markSelectedSeen()
        // Tree, worktrees and diff show the tab's checkout: attached, else
        // where its agent works, else the shell's directory.
        bindSearchBar(to: selected.terminal)
        cwdSubscription = selected.$workingDirectory
            .combineLatest(selected.$agentDirectory, selected.$attachedCheckout)
            .map { [agent = selected.agent] cwd, agentDirectory, attached in
                Tab.checkoutSource(workingDirectory: cwd, agentDirectory: agentDirectory, attached: attached, agent: agent)
            }
            .removeDuplicates { $0?.root == $1?.root && $0?.reason == $1?.reason }
            .sink { [weak self] source in
                guard let self, let source else { return }
                self.tree.setRoot(source.root)
                self.worktrees.setAnchor(source.root)
                self.worktrees.showing = source
                self.diff.setRoot(source.root)
                self.diff.showing = source.reason
            }
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { newTab(from: store.selected?.terminal) }
    @objc func newClaudeTab(_ sender: Any?) { newAgentTab(.claude) }
    @objc func newCodexTab(_ sender: Any?) { newAgentTab(.codex) }
    /// ⌘W: the focused pane of a split tab, else the tab.
    @objc func closeSelectedTab(_ sender: Any?) {
        guard let tab = store.selected else { return }
        if tab.isSplit {
            closePane(tab.terminal, in: tab)
        } else if tab.isPinned {
            NSSound.beep()
        } else {
            closeTab(tab)
        }
    }

    @objc func splitRight(_ sender: Any?) { split(nil, .right) }
    @objc func splitDown(_ sender: Any?) { split(nil, .down) }
    @objc func selectNextPane(_ sender: Any?) { focusSplit(from: nil, .next) }
    @objc func selectPreviousPane(_ sender: Any?) { focusSplit(from: nil, .previous) }
    @objc func equalizePanes(_ sender: Any?) { equalizeSplits(nil) }
    @objc func togglePaneZoom(_ sender: Any?) { toggleSplitZoom(nil) }

    @objc func toggleDiff(_ sender: Any?) {
        guard let diffItem else { return }
        let show = diffItem.isCollapsed
        diffItem.animator().isCollapsed = !show
        diff.panelVisible = show
        AppEnvironment.defaults.set(show, forKey: Self.diffVisibleKey)
        updatePullRequestVisibility()
        if !show { focusSelectedTerminal() }
    }

    /// The ± badge in the title bar: opens the changes pane on what the
    /// badge counts — the uncommitted changes, or the branch's once all is
    /// committed; a plain ± keeps the scope picked last — or closes it.
    /// View ▸ Changes (⌥⌘D) opens it on the scope picked last.
    func toggleDiffFromBadge() {
        if diffItem?.isCollapsed == true {
            rightPane.mode = .changes
            if let scope = diff.badge?.scope { diff.choose(scope) }
        }
        toggleDiff(nil)
    }

    /// The right pane, on the checkout's pull request.
    @objc func showPullRequest(_ sender: Any?) {
        rightPane.mode = .pullRequest
        if diffItem?.isCollapsed == true { toggleDiff(nil) }
        updatePullRequestVisibility()
    }

    // MARK: Pull requests

    /// The PR pane follows the checkout's branch and loads only while shown;
    /// the worktree list's pull requests are asked for again every minute.
    private func watchPullRequests() {
        diff.$root.combineLatest(diff.$branch)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] root, branch in self?.pullRequest.show(root: root, branch: branch) }
            .store(in: &cancellables)
        rightPane.$mode
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updatePullRequestVisibility() } }
            .store(in: &cancellables)
        pullRequestPoll = Timer.scheduledTimer(withTimeInterval: WorktreeModel.pullRequestMaxAge, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSApp.isActive || AppEnvironment.isIsolated else { return }
                Task { await self.worktrees.refreshPullRequests() }
            }
        }
    }

    private func updatePullRequestVisibility() {
        pullRequest.visible = diffItem?.isCollapsed == false && rightPane.mode == .pullRequest
    }

    @objc func toggleFileTree(_ sender: Any?) {
        guard let sidebarItem else { return }
        let show = sidebarItem.isCollapsed
        sidebarItem.animator().isCollapsed = !show
        AppEnvironment.defaults.set(show, forKey: Self.sidebarVisibleKey)
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

    /// Closing the window closes every tab: always confirmed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let editor, editor.document.isDirty {
            let alert = NSAlert()
            alert.messageText = "“\(editor.document.name)” has unsaved changes."
            alert.informativeText = "Save it (⌘S) first, or close the window and lose them."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Close Anyway")
            alert.beginSheetModal(for: sender) { response in
                guard response == .alertSecondButtonReturn else { return }
                sender.close()
            }
            return false
        }
        guard !store.tabs.isEmpty else { return true }
        if !Self.needsCloseConfirmation(store.tabs) {
            closeConfirmed = true
            return true
        }
        let alert = NSAlert()
        alert.messageText = store.tabs.count == 1 ? "Close the window?" : "Close the window and its \(store.tabs.count) tabs?"
        alert.informativeText = Self.closeWarning(for: store.tabs)
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closeConfirmed = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        saveFinalSession()
        agentPoll?.invalidate()
        pullRequestPoll?.invalidate()
        overviewPoll?.invalidate()
        for tab in store.tabs { tab.terminals.forEach { $0.close() } }
    }
}

extension TerminalWindowController: NSMenuItemValidation {
    /// View ▸ Changes is ticked while the pane shows. Everything else it
    /// handles stays enabled, as without validation.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleDiff(_:)) {
            menuItem.state = diffItem?.isCollapsed == false ? .on : .off
        }
        return true
    }
}

extension TerminalWindowController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        infoModel?.stop()
        infoModel = nil
        infoPopover = nil
    }
}
