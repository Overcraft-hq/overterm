import AppKit

/// The menu bar. Built in code — there is no nib. Items target the first
/// responder (nil action target): the focused terminal handles copy/paste,
/// and tab items fall through to the window controller.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Terminus", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Terminus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Terminus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(TerminalWindowController.newTab(_:)), keyEquivalent: "t")
        let claude = fileMenu.addItem(withTitle: "New Claude Tab", action: #selector(TerminalWindowController.newClaudeTab(_:)), keyEquivalent: "c")
        claude.keyEquivalentModifierMask = [.command, .option]
        let codex = fileMenu.addItem(withTitle: "New Codex Tab", action: #selector(TerminalWindowController.newCodexTab(_:)), keyEquivalent: "x")
        codex.keyEquivalentModifierMask = [.command, .option]
        let task = fileMenu.addItem(withTitle: "New Task…", action: #selector(TerminalWindowController.newTask(_:)), keyEquivalent: "n")
        task.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Pin / Unpin Tab", action: #selector(TerminalWindowController.togglePinTab(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorViewController.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(TerminalWindowController.closeSelectedTab(_:)), keyEquivalent: "w")
        let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // ⌘F in the terminal is Ghostty's start_search → the overlay; this is
        // the editor's find bar (the terminal never lets the key reach here).
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        editMenu.addItem(withTitle: "Search Terminal & Files…", action: #selector(TerminalWindowController.findInTerminal(_:)), keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Command Palette", action: #selector(TerminalWindowController.showPalette(_:)), keyEquivalent: "p")
        viewMenu.addItem(withTitle: "Tab Info", action: #selector(TerminalWindowController.showSelectedTabInfo(_:)), keyEquivalent: "i")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(TerminalWindowController.toggleFileTree(_:)), keyEquivalent: "b")
        let diff = viewMenu.addItem(withTitle: "Toggle Diff", action: #selector(TerminalWindowController.toggleDiff(_:)), keyEquivalent: "d")
        diff.keyEquivalentModifierMask = [.command, .option]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let next = windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(TerminalWindowController.selectNextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        let previous = windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(TerminalWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }
}
