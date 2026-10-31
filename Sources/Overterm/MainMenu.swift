import AppKit

/// The menu bar. Built in code — there is no nib. Items target the first
/// responder (nil action target): the focused terminal handles copy/paste,
/// and tab items fall through to the window controller.
///
/// An item with a shortcut is a KeyCommand: it carries the command's id and
/// starts with its default key; Keybindings then puts on the key the user
/// chose (Settings ▸ Keyboard Shortcuts, keybindings.json).
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // The standard panel, with the commit it was built from (AboutPanel).
        appMenu.addItem(withTitle: "About Overterm", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        command(appMenu, "View Latest Changelog", #selector(AppDelegate.showChangelog(_:)), "app.changelog")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        command(appMenu, "Settings…", #selector(AppDelegate.showSettings(_:)), "app.settings")
        appMenu.addItem(.separator())
        command(appMenu, "Hide Overterm", #selector(NSApplication.hide(_:)), "app.hide")
        command(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "app.hideOthers")
        appMenu.addItem(.separator())
        command(appMenu, "Quit Overterm", #selector(NSApplication.terminate(_:)), "app.quit")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        command(fileMenu, "New Tab", #selector(TerminalWindowController.newTab(_:)), "tabs.new")
        command(fileMenu, "New Claude Tab", #selector(TerminalWindowController.newClaudeTab(_:)), "tabs.newClaude")
        command(fileMenu, "New Codex Tab", #selector(TerminalWindowController.newCodexTab(_:)), "tabs.newCodex")
        command(fileMenu, "New Task…", #selector(TerminalWindowController.newTask(_:)), "tasks.new")
        fileMenu.addItem(
            withTitle: "Clean Up Merged Worktrees…", action: #selector(TerminalWindowController.cleanUpMergedWorktrees(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Pin / Unpin Tab", action: #selector(TerminalWindowController.togglePinTab(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        command(fileMenu, "Save", #selector(EditorViewController.saveDocument(_:)), "file.save")
        fileMenu.addItem(.separator())
        // ⌘W: the focused pane when the tab is split, else the tab (or the
        // Settings tab, when that is the one showing).
        command(fileMenu, "Close", #selector(TerminalWindowController.closeSelectedTab(_:)), "tabs.close")
        command(fileMenu, "Close Window", #selector(NSWindow.performClose(_:)), "window.close")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        command(editMenu, "Copy", #selector(NSText.copy(_:)), "edit.copy")
        command(editMenu, "Paste", #selector(NSText.paste(_:)), "edit.paste")
        command(editMenu, "Select All", #selector(NSText.selectAll(_:)), "edit.selectAll")
        editMenu.addItem(.separator())
        // ⌘F in the terminal is Ghostty's start_search → the overlay; this is
        // the editor's find bar (the terminal never lets the key reach here).
        let find = command(editMenu, "Find…", #selector(NSResponder.performTextFinderAction(_:)), "edit.find")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        editMenu.addItem(withTitle: "Search Terminal & Files…", action: #selector(TerminalWindowController.findInTerminal(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        command(
            editMenu, "Ask an Agent About the Selection", #selector(TerminalWindowController.askAboutSelection(_:)),
            "agents.askSelection")
        command(
            editMenu, "Copy the Last Command's Output", #selector(TerminalWindowController.copyLastOutput(_:)),
            "terminal.copyOutput")
        command(
            editMenu, "Run the Last Command Again", #selector(TerminalWindowController.rerunLastCommand(_:)),
            "terminal.rerun")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        command(viewMenu, "Command Palette", #selector(TerminalWindowController.showPalette(_:)), "palette.show")
        command(viewMenu, "Tab Info", #selector(TerminalWindowController.showSelectedTabInfo(_:)), "tabs.info")
        command(viewMenu, "Agent Inbox", #selector(TerminalWindowController.toggleInbox(_:)), "inbox.show")
        command(viewMenu, "Agent Overview", #selector(TerminalWindowController.showAgentOverview(_:)), "agents.overview")
        command(
            viewMenu, "Next Failure or Tab That Needs You", #selector(TerminalWindowController.showNextAttention(_:)),
            "tabs.nextAttention")
        for n in 1...9 {
            // One selector, the group's number in the tag: nine near-identical
            // selectors would be nine places to keep in step.
            command(viewMenu, "Go to Group \(n)", #selector(TerminalWindowController.showGroup(_:)), "groups.goto\(n)").tag = n
        }
        // ⇧⌘E is free in Ghostty v1.3.1 (only ⌘E and ⌃⇧E are bound); ⇧⌘↓
        // would never arrive — jump_to_prompt eats it in performKeyEquivalent.
        command(viewMenu, "Tab Peek", #selector(TerminalWindowController.toggleTabPeek(_:)), "tabs.peek")
        viewMenu.addItem(.separator())
        command(viewMenu, "Group Selected Tabs", #selector(TerminalWindowController.groupSelectedTabs(_:)), "groups.new")
        command(viewMenu, "Group Switcher", #selector(TerminalWindowController.showGroupSwitcher(_:)), "groups.switcher")
        command(viewMenu, "Focus on This Group", #selector(TerminalWindowController.toggleFocusedGroup(_:)), "groups.focus")
        command(viewMenu, "Stash Group", #selector(TerminalWindowController.stashSelectedGroup(_:)), "groups.stash")
        command(viewMenu, "Broadcast Input to Group…", #selector(TerminalWindowController.broadcastToGroup(_:)), "groups.broadcast")
        viewMenu.addItem(.separator())
        command(viewMenu, "Toggle Sidebar", #selector(TerminalWindowController.toggleFileTree(_:)), "sidebar.toggle")
        // Ticked while the sidebar is on it.
        command(viewMenu, "Overgit", #selector(TerminalWindowController.showOvergit(_:)), "overgit.show")
        command(viewMenu, "API Client", #selector(TerminalWindowController.showAPIClient(_:)), "api.show")
        command(viewMenu, "Notes", #selector(TerminalWindowController.showNotes(_:)), "notes.show")
        command(viewMenu, "Database", #selector(TerminalWindowController.showDatabase(_:)), "database.show")
        // A page over the body, as Settings; ⌥⌘P again goes back to the terminal.
        command(viewMenu, "Docker", #selector(TerminalWindowController.toggleDockerPage(_:)), "docker.page")
        command(viewMenu, "Docker Switcher", #selector(TerminalWindowController.showDockerSwitcher(_:)), "docker.switch")
        command(viewMenu, "Compose Up", #selector(TerminalWindowController.composeUp(_:)), "docker.composeUp")
        command(viewMenu, "Compose Down…", #selector(TerminalWindowController.composeDown(_:)), "docker.composeDown")
        command(viewMenu, "Compose Restart", #selector(TerminalWindowController.composeRestart(_:)), "docker.composeRestart")
        command(viewMenu, "Compose Watch", #selector(TerminalWindowController.composeWatch(_:)), "docker.composeWatch")
        command(viewMenu, "Today’s Note", #selector(TerminalWindowController.openDailyNote(_:)), "notes.daily")
        command(viewMenu, "Graph View", #selector(TerminalWindowController.showNotesGraph(_:)), "notes.graph")
        // Ticked while the pane shows (TerminalWindowController.validateMenuItem).
        command(viewMenu, "Changes", #selector(TerminalWindowController.toggleDiff(_:)), "changes.toggle")
        // Ticked while the column shows; off with Settings ▸ Browser.
        command(viewMenu, "Browser", #selector(TerminalWindowController.toggleBrowser(_:)), "browser.toggle")
        viewMenu.addItem(withTitle: "Pull Request", action: #selector(TerminalWindowController.showPullRequest(_:)), keyEquivalent: "")
        command(viewMenu, "Review Branch", #selector(TerminalWindowController.reviewBranch(_:)), "review.branch")
        command(viewMenu, "Usage", #selector(TerminalWindowController.showUsage(_:)), "usage.show")
        // Ghostty's own defaults, so they also work while the editor has the keyboard.
        viewMenu.addItem(.separator())
        command(viewMenu, "Split Right", #selector(TerminalWindowController.splitRight(_:)), "splits.right")
        command(viewMenu, "Split Down", #selector(TerminalWindowController.splitDown(_:)), "splits.down")
        command(viewMenu, "Next Pane", #selector(TerminalWindowController.selectNextPane(_:)), "splits.next")
        command(viewMenu, "Previous Pane", #selector(TerminalWindowController.selectPreviousPane(_:)), "splits.previous")
        command(viewMenu, "Zoom Pane", #selector(TerminalWindowController.togglePaneZoom(_:)), "splits.zoom")
        command(viewMenu, "Equalize Panes", #selector(TerminalWindowController.equalizePanes(_:)), "splits.equalize")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        command(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "window.minimize")
        windowMenu.addItem(.separator())
        command(windowMenu, "Show Next Tab", #selector(TerminalWindowController.selectNextTab(_:)), "tabs.next")
        command(windowMenu, "Show Previous Tab", #selector(TerminalWindowController.selectPreviousTab(_:)), "tabs.previous")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// An item for a KeyCommand, with the command's default key.
    @discardableResult
    private static func command(_ menu: NSMenu, _ title: String, _ action: Selector, _ id: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        if let key = KeyCommands.byID[id]?.defaultKey.flatMap(KeyCombo.init) {
            (item.keyEquivalent, item.keyEquivalentModifierMask) = key.menuKey
        }
        return item
    }
}
