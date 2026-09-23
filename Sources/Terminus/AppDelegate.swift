import AppKit
import GhosttyKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private var windowController: TerminalWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        UNUserNotificationCenter.current().delegate = self

        let controller = TerminalWindowController()
        // A diagnostic run must not touch the real session: no restore (it
        // would resume agents), no autosave.
        let diagnostic = ProcessInfo.processInfo.environment["TERMINUS_DUMP_LAYOUT"] != nil
        if !diagnostic, let saved = SessionState.load(), !saved.tabs.isEmpty {
            controller.restore(saved)
        } else if diagnostic, let cwd = ProcessInfo.processInfo.environment["TERMINUS_DUMP_CWD"] {
            controller.newTab(in: URL(fileURLWithPath: cwd))
        } else {
            controller.newTab(from: nil)
        }
        if !diagnostic { controller.autosaveSession() }
        controller.showWindow(nil)
        windowController = controller
        controller.dumpLayoutIfRequested()

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quitting kills every tab's process; ask once if any is still running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = GhosttyRuntime.shared.app, ghostty_app_needs_confirm_quit(app) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Terminus?"
        alert.informativeText = "Some tabs still have running processes. Quitting will kill them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save first: the autosave is debounced and would miss a quick quit.
        windowController?.saveSession()
        windowController?.store.tabs.forEach { $0.terminal.close() }
    }

    /// Returning to the app is "seeing" the selected tab.
    func applicationDidBecomeActive(_ notification: Notification) {
        windowController?.windowDidBecomeKey(notification)
    }

    /// Clicking a tab's notification brings that tab up.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = (response.notification.request.content.userInfo[AttentionNotifier.tabIDKey] as? String).flatMap(UUID.init(uuidString:)) {
            windowController?.reveal(tabID: id)
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
