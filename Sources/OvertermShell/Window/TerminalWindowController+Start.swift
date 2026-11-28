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
