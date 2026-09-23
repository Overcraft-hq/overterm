import AppKit
import GhosttyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: TerminalWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let controller = TerminalWindowController()
        controller.newTab(from: nil)
        controller.showWindow(nil)
        windowController = controller

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
        windowController?.store.tabs.forEach { $0.terminal.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
