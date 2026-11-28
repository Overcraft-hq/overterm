#if E2E
import AppKit

/// Issue #31's patch 5: the Help menu and macOS's menu search, View's
/// submenus, and the strip's "What's new in …" chip after an update.
extension E2ERunner {
    func menusAndWhatsNewChecks() async {
        // DISC-U1: Help, as macOS's menu search wants it.
        let help = NSApp.mainMenu?.items.first { $0.submenu?.title == "Help" }?.submenu
        check("the menu bar has a Help menu, the app's help menu", help != nil && NSApp.helpMenu === help)
        if let shortcuts = menuItem("Help", "Keyboard Shortcuts") {
            app.closeOverlay(.settings)
            NSApp.sendAction(shortcuts.action!, to: nil, from: shortcuts)
            check(
                "Help ▸ Keyboard Shortcuts opens Settings on them",
                await eventually(3) { self.app.settingsPage.section == .shortcuts && self.app.store.settingsShowing },
                "\(app.settingsPage.section)")
            app.closeOverlay(.settings)
        } else {
            check("Help ▸ Keyboard Shortcuts exists", false)
        }
        check("Help ▸ Keyboard Shortcuts is a command", menuItem("Help", "Keyboard Shortcuts")?.identifier?.rawValue == "help.shortcuts")
        // Onboarding 7.4: into a folder without `cd`, no key by default (D-10).
        let openFolder = menuItem("File", "Open Folder…")
        check(
            "File ▸ Open Folder…, with no key",
            openFolder?.identifier?.rawValue == "file.openFolder" && openFolder?.keyEquivalent == ""
                && openFolder?.action == #selector(TerminalWindowController.openFolder(_:)))
        check("Help ▸ Overterm on GitHub", menuItem("Help", "Overterm on GitHub")?.action == #selector(AppDelegate.openGitHub(_:)))
        check("Help mirrors View Latest Changelog", menuItem("Help", "View Latest Changelog")?.action == #selector(AppDelegate.showChangelog(_:)))

        // DISC-U2: each feature's commands in a submenu, found by the title they always had.
        let view = NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
        let kubernetes = view?.items.first { $0.title == "Kubernetes" }?.submenu
        check(
            "View ▸ Kubernetes is a submenu with its commands",
            kubernetes?.items.contains { $0.identifier?.rawValue == "kubernetes.terminal" } == true,
            "\(kubernetes?.items.map(\.title) ?? [])")
        check("View keeps Changes at its top", view?.items.contains { $0.identifier?.rawValue == "changes.toggle" } == true)
        if let zoom = menuItem("View", "Zoom Pane") {
            check("a submenu's item keeps its key", zoom.keyEquivalent == "\r" || !zoom.keyEquivalent.isEmpty, zoom.keyEquivalent)
        } else {
            check("View ▸ Panes ▸ Zoom Pane exists", false)
        }

        // SET-G2: an older version stored — the chip; put away, it stays away.
        let updates = UpdateChecker.shared
        let defaults = AppEnvironment.defaults
        check("this run started with nothing stored, and so nothing to say", updates.whatsNew == nil)
        defaults.set("0.0.1", forKey: UpdateChecker.lastRunKey)
        updates.noteLaunch()
        check("a newer version than the last run offers its entry", updates.whatsNew == updates.currentVersion, updates.whatsNew ?? "none")
        // Drawn in the strip, wide enough for its words — the chip a person sees.
        let shown = await eventually(3) {
            WhatsNewChip.drawn?.version == updates.currentVersion && (WhatsNewChip.drawn?.frame.width ?? 0) > 80
        }
        check(
            "the strip shows “What’s new in \(updates.currentVersion)”", shown,
            "\(String(describing: WhatsNewChip.drawn)) in strip \(app.tabBarView?.frame ?? .zero)")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.4)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-whatsnew.png")
        }
        app.showWhatsNew()
        check(
            "pressed, the changelog opens at that version",
            await eventually(2) { ChangelogWindowController.shared.window?.isVisible == true && ChangelogWindowController.shared.focus == updates.currentVersion })
        check("and the chip goes, the version remembered", updates.whatsNew == nil && defaults.string(forKey: UpdateChecker.lastRunKey) == updates.currentVersion)
        check("and leaves the strip", await eventually(3) { WhatsNewChip.drawn == nil })
        updates.noteLaunch()
        check("the next launch says nothing again", updates.whatsNew == nil)
        ChangelogWindowController.shared.window?.close()

        defaults.set("0.0.1", forKey: UpdateChecker.lastRunKey)
        updates.noteLaunch()
        updates.dismissWhatsNew()
        check("its × puts it away without a window", updates.whatsNew == nil && ChangelogWindowController.shared.window?.isVisible != true)
    }
}
#endif
