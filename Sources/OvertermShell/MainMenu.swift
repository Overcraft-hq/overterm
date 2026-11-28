import AppKit

/// The menu bar. Built in code — there is no nib. Items target the first
/// responder (nil action target): the focused terminal handles copy/paste,
/// and tab items fall through to the window controller.
///
/// An item with a shortcut is a KeyCommand: it carries the command's id and
/// starts with its default key; Keybindings then puts on the key the user
/// chose (Settings ▸ Keyboard Shortcuts, keybindings.json).
@MainActor
package enum MainMenu {
    package static func build() -> NSMenu {
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
        command(fileMenu, "New opencode Tab", #selector(TerminalWindowController.newOpencodeTab(_:)), "tabs.newOpencode")
        command(fileMenu, "New pi Tab", #selector(TerminalWindowController.newPiTab(_:)), "tabs.newPi")
        command(fileMenu, "New Gemini Tab", #selector(TerminalWindowController.newGeminiTab(_:)), "tabs.newGemini")
        command(fileMenu, "New Task…", #selector(TerminalWindowController.newTask(_:)), "tasks.new")
        // A tab in a folder picked in Finder's panel: into a repository without `cd`.
        command(fileMenu, "Open Folder…", #selector(TerminalWindowController.openFolder(_:)), "file.openFolder")
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
        // First-responder actions: the editor's text view answers them with
        // its file's own undo; the terminal never sees them (Ghostty holds
        // ⌘Z and ⇧⌘Z there, and has nothing to cut).
        command(editMenu, "Undo", Selector(("undo:")), "edit.undo")
        command(editMenu, "Redo", Selector(("redo:")), "edit.redo")
        editMenu.addItem(.separator())
        command(editMenu, "Cut", #selector(NSText.cut(_:)), "edit.cut")
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

        // View: what is used every day at the top; each feature's commands
        // in a submenu of its own (DISC-U2). Keybindings finds an item by its
        // identifier in any submenu, so keys and rebinding are unchanged.
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        command(viewMenu, "Command Palette", #selector(TerminalWindowController.showPalette(_:)), "palette.show")
        command(viewMenu, "Tab Info", #selector(TerminalWindowController.showSelectedTabInfo(_:)), "tabs.info")
        command(viewMenu, "Inbox", #selector(TerminalWindowController.toggleInbox(_:)), "inbox.show")
        command(viewMenu, "Agent Overview", #selector(TerminalWindowController.showAgentOverview(_:)), "agents.overview")
        command(
            viewMenu, "Next Failure or Tab That Needs You", #selector(TerminalWindowController.showNextAttention(_:)),
            "tabs.nextAttention")
        // ⇧⌘E is free in Ghostty v1.3.1 (only ⌘E and ⌃⇧E are bound); ⇧⌘↓
        // would never arrive — jump_to_prompt eats it in performKeyEquivalent.
        command(viewMenu, "Tab Peek", #selector(TerminalWindowController.toggleTabPeek(_:)), "tabs.peek")
        command(viewMenu, "Presentation Mode", #selector(TerminalWindowController.togglePresentation(_:)), "view.presentation")
        viewMenu.addItem(.separator())
        command(viewMenu, "Toggle Sidebar", #selector(TerminalWindowController.toggleFileTree(_:)), "sidebar.toggle")
        // Ticked while the sidebar is on it.
        command(viewMenu, "Overgit", #selector(TerminalWindowController.showOvergit(_:)), "overgit.show")
        command(viewMenu, "API Client", #selector(TerminalWindowController.showAPIClient(_:)), "api.show")
        command(viewMenu, "Database", #selector(TerminalWindowController.showDatabase(_:)), "database.show")
        command(viewMenu, "Files", #selector(TerminalWindowController.showFiles(_:)), "files.show")
        command(viewMenu, "Sessions", #selector(TerminalWindowController.showSessions(_:)), "sessions.show")
        command(viewMenu, "Snippets", #selector(TerminalWindowController.showSnippets(_:)), "snippets.show")
        // Ticked while the pane shows (TerminalWindowController.validateMenuItem).
        command(viewMenu, "Changes", #selector(TerminalWindowController.toggleDiff(_:)), "changes.toggle")
        // Ticked while the column shows; off with Settings ▸ Browser.
        command(viewMenu, "Browser", #selector(TerminalWindowController.toggleBrowser(_:)), "browser.toggle")
        // The title bar's phone; off with Settings ▸ Simulator.
        command(viewMenu, "Simulator", #selector(TerminalWindowController.toggleSimulator(_:)), "simulator.toggle")
        viewMenu.addItem(withTitle: "Pull Request", action: #selector(TerminalWindowController.showPullRequest(_:)), keyEquivalent: "")
        command(viewMenu, "Create Pull Request…", #selector(TerminalWindowController.createPullRequest(_:)), "pullRequest.create")
        command(viewMenu, "Review Branch", #selector(TerminalWindowController.reviewBranch(_:)), "review.branch")
        command(viewMenu, "Usage", #selector(TerminalWindowController.showUsage(_:)), "usage.show")
        viewMenu.addItem(.separator())

        let groups = submenu(viewMenu, "Groups")
        for n in 1...9 {
            // One selector, the group's number in the tag: nine near-identical
            // selectors would be nine places to keep in step.
            command(groups, "Go to Group \(n)", #selector(TerminalWindowController.showGroup(_:)), "groups.goto\(n)").tag = n
        }
        groups.addItem(.separator())
        command(groups, "Group Selected Tabs", #selector(TerminalWindowController.groupSelectedTabs(_:)), "groups.new")
        command(groups, "Group Switcher", #selector(TerminalWindowController.showGroupSwitcher(_:)), "groups.switcher")
        command(groups, "Focus on This Group", #selector(TerminalWindowController.toggleFocusedGroup(_:)), "groups.focus")
        command(groups, "Stash Group", #selector(TerminalWindowController.stashSelectedGroup(_:)), "groups.stash")
        command(groups, "Broadcast Input to Group…", #selector(TerminalWindowController.broadcastToGroup(_:)), "groups.broadcast")

        // Ghostty's own defaults, so they also work while the editor has the keyboard.
        let panes = submenu(viewMenu, "Panes")
        command(panes, "Split Right", #selector(TerminalWindowController.splitRight(_:)), "splits.right")
        command(panes, "Split Down", #selector(TerminalWindowController.splitDown(_:)), "splits.down")
        command(panes, "Next Pane", #selector(TerminalWindowController.selectNextPane(_:)), "splits.next")
        command(panes, "Previous Pane", #selector(TerminalWindowController.selectPreviousPane(_:)), "splits.previous")
        command(panes, "Zoom Pane", #selector(TerminalWindowController.togglePaneZoom(_:)), "splits.zoom")
        command(panes, "Equalize Panes", #selector(TerminalWindowController.equalizePanes(_:)), "splits.equalize")

        let columns = submenu(viewMenu, "Columns")
        command(columns, "Focus the Sidebar", #selector(TerminalWindowController.focusSidebarColumn(_:)), "columns.sidebar")
        command(columns, "Focus the Terminal", #selector(TerminalWindowController.focusTerminalColumn(_:)), "columns.terminal")
        command(columns, "Focus the Editor", #selector(TerminalWindowController.focusEditorColumn(_:)), "columns.editor")
        command(columns, "Focus the Right Pane", #selector(TerminalWindowController.focusRightColumn(_:)), "columns.right")
        command(columns, "Focus the Inbox", #selector(TerminalWindowController.focusInboxColumn(_:)), "columns.inbox")
        command(columns, "Next Column", #selector(TerminalWindowController.focusNextColumn(_:)), "columns.next")
        command(columns, "Previous Column", #selector(TerminalWindowController.focusPreviousColumn(_:)), "columns.previous")
        viewMenu.addItem(.separator())

        // A page over the body, as Settings; ⌥⌘P again goes back to the terminal.
        let docker = submenu(viewMenu, "Docker")
        command(docker, "Show Docker", #selector(TerminalWindowController.toggleDockerPage(_:)), "docker.page")
        command(docker, "Docker Switcher", #selector(TerminalWindowController.showDockerSwitcher(_:)), "docker.switch")
        docker.addItem(.separator())
        command(docker, "Compose Up", #selector(TerminalWindowController.composeUp(_:)), "docker.composeUp")
        command(docker, "Compose Down…", #selector(TerminalWindowController.composeDown(_:)), "docker.composeDown")
        command(docker, "Compose Restart", #selector(TerminalWindowController.composeRestart(_:)), "docker.composeRestart")
        command(docker, "Compose Watch", #selector(TerminalWindowController.composeWatch(_:)), "docker.composeWatch")
        // Docker's way: ⌥⌘J again goes back to the terminal.
        let kubernetes = submenu(viewMenu, "Kubernetes")
        command(kubernetes, "Show Kubernetes", #selector(TerminalWindowController.toggleKubernetesPage(_:)), "kubernetes.page")
        command(kubernetes, "Kubernetes Switcher", #selector(TerminalWindowController.showKubernetesSwitcher(_:)), "kubernetes.switch")
        command(
            kubernetes, "Terminal in Kubernetes Context…", #selector(TerminalWindowController.openKubernetesTerminalPicker(_:)),
            "kubernetes.terminal")
        // Enabled while the page shows a list (TerminalWindowController.validateMenuItem).
        command(
            kubernetes, "Export Kubernetes List as CSV…", #selector(TerminalWindowController.exportKubernetesList(_:)), "kubernetes.exportCSV")
        // Docker's way: ⌥⌘A again goes back to the terminal.
        let activity = submenu(viewMenu, "Activity")
        command(activity, "Show Activity", #selector(TerminalWindowController.toggleActivityPage(_:)), "activity.page")
        command(activity, "Activity Switcher", #selector(TerminalWindowController.showActivitySwitcher(_:)), "activity.switch")
        command(activity, "Activity: Listening", #selector(TerminalWindowController.showActivityListening(_:)), "activity.listening")
        command(activity, "Free a Port…", #selector(TerminalWindowController.showActivityFreePort(_:)), "activity.freePort")
        // The rail's Terraform panel; its switcher scopes the palette to the roots.
        let terraform = submenu(viewMenu, "Terraform")
        command(terraform, "Show Terraform", #selector(TerminalWindowController.showTerraformPanel(_:)), "terraform.show")
        command(terraform, "Terraform Switcher", #selector(TerminalWindowController.showTerraformSwitcher(_:)), "terraform.switch")
        command(
            terraform, "Terminal in Terraform Root…", #selector(TerminalWindowController.openTerraformTerminalPicker(_:)), "terraform.terminal")
        command(terraform, "Plan Terraform Root", #selector(TerminalWindowController.planSelectedTerraformRoot(_:)), "terraform.plan")
        command(
            terraform, "Copy Terraform Plan Summary", #selector(TerminalWindowController.copyTerraformPlanSummary(_:)), "terraform.copySummary")
        let notes = submenu(viewMenu, "Notes")
        command(notes, "Show Notes", #selector(TerminalWindowController.showNotes(_:)), "notes.show")
        command(notes, "Today’s Note", #selector(TerminalWindowController.openDailyNote(_:)), "notes.daily")
        command(notes, "Graph View", #selector(TerminalWindowController.showNotesGraph(_:)), "notes.graph")
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

        // Help (DISC-U1): macOS puts its menu search here — every item of
        // every menu found by typing a word of its title.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        command(helpMenu, "Keyboard Shortcuts", #selector(AppDelegate.showKeyboardShortcuts(_:)), "help.shortcuts")
        // The keys of wherever the keyboard is (DISC-N1).
        command(helpMenu, "Keys Here", #selector(TerminalWindowController.showKeysHere(_:)), "help.keysHere")
        // Onboarding 7.8: Settings ▸ About at the changelog, the versions skipped too.
        command(helpMenu, whatsNewTitle(FirstRun.currentVersion), #selector(AppDelegate.showWhatsNew(_:)), "help.whatsNew")
        // Mirrored from the app menu, without its identifier: a key the
        // person gives it belongs on one item.
        helpMenu.addItem(withTitle: "View Latest Changelog", action: #selector(AppDelegate.showChangelog(_:)), keyEquivalent: "")
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: "Overterm on GitHub", action: #selector(AppDelegate.openGitHub(_:)), keyEquivalent: "")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        return main
    }

    /// A submenu of `menu`, under an item of the same title.
    private static func submenu(_ menu: NSMenu, _ title: String) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        item.submenu = sub
        return sub
    }

    /// Help ▸ What's New's title, this build's version in it; ⌘K's row says the same.
    package static func whatsNewTitle(_ version: String) -> String { "What's New in \(version)" }

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
