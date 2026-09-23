import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    private var windowController: TerminalWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        UNUserNotificationCenter.current().delegate = self

        let controller = TerminalWindowController()
        // An isolated run (E2E, layout dump) reads and writes its own support
        // directory — empty unless a test prepared a session there.
        let env = ProcessInfo.processInfo.environment
        if let saved = SessionState.load(), !saved.tabs.isEmpty {
            controller.restore(saved)
        } else if AppEnvironment.isIsolated, let cwd = env["TERMINUS_E2E_CWD"] ?? env["TERMINUS_DUMP_CWD"] {
            controller.newTab(in: URL(fileURLWithPath: cwd))
        } else {
            controller.newTab(from: nil)
        }
        controller.autosaveSession()
        controller.showWindow(nil)
        windowController = controller
        controller.dumpLayoutIfRequested()

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
        guard let controller = windowController, !controller.closeConfirmed, !controller.store.tabs.isEmpty else { return .terminateNow }
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
