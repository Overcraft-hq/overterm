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
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private var cancellables: Set<AnyCancellable> = []
    /// Follows the selected tab's cwd into the file tree.
    private var cwdSubscription: AnyCancellable?

    private static let sidebarVisibleKey = "sidebarVisible"

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
                )
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
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: terminalPane))
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "TerminusSidebar"
        self.sidebarItem = sidebarItem

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
        guard let window else { return }
        guard let repo = worktrees.main?.path else {
            showAlert("Not in a git repository", "Open a tab inside a repository first; the task’s worktree is created from it.")
            return
        }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let close = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
        }
        sheet.contentViewController = NSHostingController(
            rootView: NewTaskView(
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
            ))
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
        tab.terminal.close()
        tab.terminal.removeFromSuperview()
        store.remove(tab)
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
        cwdSubscription = selected.$workingDirectory
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] cwd in
                let root = FileTreeModel.treeRoot(for: cwd)
                self?.tree.setRoot(root)
                self?.worktrees.setAnchor(root)
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
        for tab in store.tabs { tab.terminal.close() }
    }
}
