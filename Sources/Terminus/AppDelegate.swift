import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var terminal: TerminalView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminus"
        window.center()
        window.setFrameAutosaveName("TerminusMainWindow")

        let terminal = TerminalView()
        terminal.onTitleChange = { [weak window] title in window?.title = title }
        terminal.onClose = { [weak window] _ in window?.close() }
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        self.window = window
        self.terminal = terminal

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminal?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
