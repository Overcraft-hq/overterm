import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private var windowController: TerminalWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppEnvironment.carryOverFormerDefaults()
        NSApp.mainMenu = MainMenu.build()
        NSApp.servicesProvider = self
        UNUserNotificationCenter.current().delegate = self

        let controller = TerminalWindowController()
        // An isolated run (E2E, layout dump) reads and writes its own support
        // directory — empty unless a test prepared a session there.
        let env = ProcessInfo.processInfo.environment
        if Settings.shared.restoreTabs, let saved = SessionState.load(), !saved.tabs.isEmpty {
            controller.restore(saved)
        } else if AppEnvironment.isIsolated, let cwd = env["TERMINUS_E2E_CWD"] ?? env["TERMINUS_DUMP_CWD"] {
            controller.newTab(in: URL(fileURLWithPath: cwd))
        } else {
            controller.newTab(from: nil)
        }
        controller.autosaveSession()
        controller.showWindow(nil)
        UpdateChecker.shared.checkIfDue()
        windowController = controller
        controller.dumpLayoutIfRequested()
        if let scenario = AppEnvironment.e2eScenario { E2ERunner.start(scenario, app: controller) }

        // An isolated run stays in the background: it must not take the
        // keyboard from whatever the user is doing.
        if AppEnvironment.isIsolated {
            controller.window?.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Quitting closes every tab: always confirmed — unless the window's own
    /// close was just confirmed, or nothing is open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Unsaved editor changes ask first, whatever Settings says about tabs
        // (closing the window asks about them itself).
        if let controller = windowController, !controller.closeConfirmed, let file = controller.unsavedEditorFile {
            let alert = NSAlert()
            alert.messageText = "“\(file)” has unsaved changes."
            alert.informativeText = "Quitting loses them. Save it (⌘S) first, or quit anyway."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        guard let controller = windowController, !controller.closeConfirmed, !controller.store.tabs.isEmpty,
            TerminalWindowController.needsCloseConfirmation(controller.store.tabs)
        else { return .terminateNow }
        let tabs = controller.store.tabs
        let alert = NSAlert()
        alert.messageText = tabs.count == 1 ? "Quit Terminus?" : "Quit Terminus and close \(tabs.count) tabs?"
        alert.informativeText =
            TerminalWindowController.closeWarning(for: tabs) + " Tabs come back on the next launch; agents resume their conversation."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save first: the autosave is debounced and would miss a quick quit.
        // With each pane's text — unless closing the window already did.
        windowController?.saveFinalSession()
        windowController?.store.tabs.forEach { $0.terminals.forEach { $0.close() } }
    }

    /// Terminus ▸ Settings… (⌘,).
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func showChangelog(_ sender: Any?) {
        ChangelogWindowController.shared.show()
    }

    /// Settings ▸ About, checking.
    @objc func checkForUpdates(_ sender: Any?) {
        SettingsWindowController.shared.show(.about)
        Task { await UpdateChecker.shared.check() }
    }

    /// Finder's Open With, or a drop on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        windowController?.open(urls)
    }

    /// Finder's "New Terminus Tab Here" (Info.plist NSServices): the
    /// selected files and folders, as for Open With.
    @objc func newTabHere(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files or folders to open." as NSString
            return
        }
        windowController?.open(urls)
    }

    /// Terminus ▸ About Terminus. The menu item has no target: the action
    /// reaches the app's delegate after the windows' responders.
    @objc func showAbout(_ sender: Any?) {
        AboutPanel.show()
    }

    /// Returning to the app is "seeing" the selected tab.
    func applicationDidBecomeActive(_ notification: Notification) {
        windowController?.windowDidBecomeKey(notification)
    }

    /// Clicking a tab's notification brings that tab up. nonisolated: the
    /// system may call it off the main thread, and this conformance's
    /// isolation check would trap there (as AttentionNotifier's completion
    /// did); the tab is revealed on the main thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = (response.notification.request.content.userInfo[AttentionNotifier.tabIDKey] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id { self.windowController?.reveal(tabID: id) }
            }
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
