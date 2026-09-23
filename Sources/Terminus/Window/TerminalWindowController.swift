import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// One Terminus window: the tab strip in the title bar, and below it the
/// selected tab's terminal. Every tab's TerminalView stays alive in the
/// container (hidden and occluded when not selected) so its pty and
/// scrollback survive tab switches.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let store = TabStore()
    private let container = NSView()
    private var tabBarHeight: NSLayoutConstraint?
    private var cancellables: Set<AnyCancellable> = []

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
        let theme = TabBarTheme(background: runtime.backgroundColor, foreground: runtime.foregroundColor)
        let tabBar = NSHostingView(
            rootView: TabBarView(
                store: store,
                theme: theme,
                leadingInset: 78,
                actions: TabBarActions(
                    select: { [weak self] in self?.store.select($0) },
                    close: { [weak self] in self?.closeTab($0) },
                    newTab: { [weak self] in self?.newTab(from: self?.store.selected?.terminal) },
                    renameEnded: { [weak self] in self?.focusSelectedTerminal() },
                    setPinned: { [weak self] tab, pinned in self?.store.setPinned(tab, pinned) }
                )
            )
            .background(theme.strip)
            // The strip sits in the title bar on purpose; without this SwiftUI
            // pads it down by the title bar's safe-area inset.
            .ignoresSafeArea()
        )

        let content = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabBar)
        content.addSubview(container)
        let height = tabBar.heightAnchor.constraint(equalToConstant: titleBarHeight(of: window))
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            height,
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        tabBarHeight = height
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
        let tab = Tab(terminal: terminal)
        terminal.onTitleChange = { [weak tab] in tab?.shellTitle = $0 }
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
        store.insert(tab, after: store.tabs.first { $0.terminal === source })
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
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) { newTab(from: store.selected?.terminal) }
    @objc func closeTab(_ sender: Any?) {
        guard let tab = store.selected else { return }
        if tab.isPinned {
            NSSound.beep()
        } else {
            closeTab(tab)
        }
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
