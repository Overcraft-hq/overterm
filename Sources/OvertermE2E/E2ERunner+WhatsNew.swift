#if E2E
import AppKit

/// Issue #31's patch 5: the Help menu and macOS's menu search, View's
/// submenus, and the strip's "What's new in …" chip after an update
/// (onboarding 7.9).
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

        await whatsNewChecks()
    }

    /// A changelog of the scenario's own: this version, one skipped, the one
    /// run before (onboarding 7.9's step 19).
    func whatsNewChangelog(_ current: String) -> String {
        "# Changelog\n\n## \(current) — today\n\n- this one\n\n## 1.6.2 — then\n\n- skipped\n\n## 1.6.1 — before\n\n- ran before\n"
    }

    /// SET-G2, onboarding 7.9: after an update, the strip's chip in the
    /// update chip's place; pressed, Settings ▸ About with every version
    /// since; put away, it stays away; never a window by itself, the
    /// keyboard left in the terminal.
    private func whatsNewChecks() async {
        let updates = UpdateChecker.shared
        let defaults = AppEnvironment.defaults
        let current = updates.currentVersion
        let changelog = whatsNewChangelog(current)
        check("an isolated run says nothing by itself", updates.whatsNew == nil)
        defaults.removeObject(forKey: UpdateChecker.whatsNewSeenKey)
        updates.noteLaunch(.fresh, changelog: changelog, enabled: true)
        check("a fresh install: no chip", updates.whatsNew == nil)
        updates.noteLaunch(.same, changelog: changelog, enabled: true)
        check("the same version again: no chip", updates.whatsNew == nil)
        updates.noteLaunch(.upgraded(from: "1.6.1"), changelog: changelog, enabled: false)
        check("updates.whatsNew off: no chip", updates.whatsNew == nil)

        app.closeOverlay(.settings)
        app.focusSelectedTerminal()
        let terminal = app.store.selected?.terminal
        let overlay = app.store.showingOverlay
        updates.noteLaunch(.upgraded(from: "1.6.1"), changelog: changelog, enabled: true)
        check("an update: the chip, for this version", updates.whatsNew == current, updates.whatsNew ?? "none")
        // Drawn in the strip, wide enough for its words — the chip a person sees.
        let shown = await eventually(3) { WhatsNewChip.drawn?.version == current && (WhatsNewChip.drawn?.frame.width ?? 0) > 80 }
        check("the strip shows “What’s new in \(current)”", shown, "\(String(describing: WhatsNewChip.drawn)) in strip \(app.tabBarView?.frame ?? .zero)")
        check(
            "no page opened by itself, the keyboard still in the terminal",
            app.store.showingOverlay == overlay && terminal != nil && window.firstResponder === terminal
                && ChangelogWindowController.shared.window?.isVisible != true,
            String(describing: window.firstResponder))
        check("nothing written before it is pressed", defaults.string(forKey: UpdateChecker.whatsNewSeenKey) == nil)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.4)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-whatsnew.png")
        }

        app.showWhatsNew()
        check(
            "pressed, Settings ▸ About opens at the changelog",
            await eventually(3) { self.app.store.settingsShowing && self.app.settingsPage.section == .about }
                && app.settingsPage.focus == Changelog.whatsNewAnchor,
            "\(app.settingsPage.section) \(app.settingsPage.focus ?? "nil")")
        let skipped = ["1.6.2"].filter { UpdateChecker.isNewer(current, than: $0) }
        check("About lists the versions skipped too", updates.changes.map(\.version) == [current] + skipped, "\(updates.changes.map(\.version))")
        check("and the chip goes, the version remembered", updates.whatsNew == nil && defaults.string(forKey: UpdateChecker.whatsNewSeenKey) == current)
        check("and leaves the strip", await eventually(3) { WhatsNewChip.drawn == nil })
        updates.noteLaunch(.upgraded(from: "1.6.1"), changelog: changelog, enabled: true)
        check("not again for this version", updates.whatsNew == nil)
        updates.noteLaunch(.upgraded(from: nil), changelog: changelog, enabled: true)
        check("an update from before the key: About lists this version's alone", updates.changes.map(\.version) == [current])
        app.closeOverlay(.settings)

        defaults.removeObject(forKey: UpdateChecker.whatsNewSeenKey)
        updates.noteLaunch(.upgraded(from: "1.6.1"), changelog: changelog, enabled: true)
        updates.dismissWhatsNew()
        check(
            "its × puts it away for this version, without a window",
            updates.whatsNew == nil && defaults.string(forKey: UpdateChecker.whatsNewSeenKey) == current && !app.store.settingsShowing
                && ChangelogWindowController.shared.window?.isVisible != true)

        // Help ▸ What's New in …: About at the changelog, any time.
        let title = MainMenu.whatsNewTitle(current)
        if let item = menuItem("Help", title), let action = item.action {
            check("Help ▸ \(title) is a command with no key", item.identifier?.rawValue == "help.whatsNew" && item.keyEquivalent == "")
            NSApp.sendAction(action, to: item.target, from: item)
            check(
                "and opens Settings ▸ About at the changelog",
                await eventually(3) { self.app.store.settingsShowing && self.app.settingsPage.section == .about })
            app.closeOverlay(.settings)
        } else {
            check("Help ▸ \(title) exists", false)
        }
        updates.noteLaunch(.same, changelog: changelog, enabled: true)
    }
}
#endif
