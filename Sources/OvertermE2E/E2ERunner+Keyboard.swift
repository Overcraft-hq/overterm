#if E2E
import AppKit

/// P14 (Overcraft-hq/issue-tracker#24): the chrome's text over the
/// contrast floor, the keyboard between columns by command, and the
/// sidebar's panels walked with it — asked of the views, the keys handed to
/// the views themselves, never the system's input.
extension E2ERunner {
    package func keyboardScenario() async {
        // The floor, on the theme this run has.
        if let theme = app.theme {
            func rgb(_ color: NSColor) -> (ChromeContrast.RGB, Double) {
                let c = color.usingColorSpace(.sRGB) ?? color
                return (ChromeContrast.RGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)), Double(c.alphaComponent))
            }
            let (ground, _) = rgb(theme.winNS)
            let (second, alpha) = rgb(theme.text2NS)
            check("the secondary text reads on the window (4.5:1)", ChromeContrast.ratio(second.over(ground, alpha: alpha), ground) >= 4.5)
        }

        // A checkout with a folder, a file and a commit.
        let repo = scratch.appendingPathComponent("keyboard-repo")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "print(1)\n".write(to: repo.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try? "# keys\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "First keys"], in: repo)
        app.newTab(in: repo)
        guard let terminal = app.store.selected?.terminal else { return check("a tab in the checkout", false) }
        _ = await eventually(8) { self.app.tree.root?.standardizedFileURL.path == repo.standardizedFileURL.path }
        if app.sidebarItem?.isCollapsed == true { app.toggleFileTree(nil) }
        app.sidebarPanel.panel = .files
        app.focusSelectedTerminal()

        // Showing the sidebar's panels, or their content changing, never takes the keyboard.
        app.sidebarPanel.panel = .git
        await pause(0.3)
        app.sidebarPanel.panel = .files
        app.tree.reload()
        await pause(0.3)
        check("the sidebar changing leaves the keyboard in the terminal", app.window?.firstResponder === terminal)

        // The columns: the sidebar by its command, then back.
        check("Focus the Sidebar gives it the keyboard", app.focusColumn(.sidebar) && app.focusedColumn == .sidebar)
        guard let keys = app.window?.firstResponder as? NSView else { return check("the sidebar has a key view", false) }
        func press(_ code: UInt16, _ characters: String) {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: app.window?.windowNumber ?? 0, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { return }
            (app.window?.firstResponder as? NSView)?.keyDown(with: event)
        }
        press(125, "")
        check("↓ picks the first row", app.tree.selectedRow?.entry.name == "src", app.tree.selectedRow?.entry.name ?? "none")
        press(124, "")
        check("→ opens the folder", await eventually(3) { self.app.tree.rows.map(\.entry.name) == ["src", "main.swift", "README.md"] })
        press(38, "j")
        check("j moves down into it", app.tree.selectedRow?.entry.name == "main.swift")
        press(36, "\r")
        check(
            "↩ opens the file in the editor",
            await eventually(5) { self.app.editor?.active?.url?.lastPathComponent == "main.swift" }, app.editor?.active?.url?.path ?? "none")

        // Esc gives it back to the terminal.
        check("the sidebar's key view is the one asked", app.focusColumn(.sidebar) && app.window?.firstResponder === keys)
        press(53, "\u{1b}")
        check("Esc gives the keyboard back to the terminal", app.window?.firstResponder === app.store.selected?.terminal)

        // Overgit the same way: a commit stood on and opened.
        app.sidebarPanel.panel = .git
        if !app.overgit.isExpanded(.commits) { app.overgit.toggle(.commits) }
        _ = await eventually(8) { !self.app.overgit.commits.isEmpty }
        app.focusColumn(.sidebar)
        app.overgit.keyFocus = .section(.commits)
        press(125, "")
        check("↓ from Commits stands on the commit", app.overgit.keyCommit?.subject == "First keys", "\(String(describing: app.overgit.keyFocus))")
        press(36, "\r")
        check("↩ opens it in the right-hand pane", await eventually(3) { self.app.rightPane.mode == .commit })
        press(53, "\u{1b}")

        // The Inbox: reached by its command, J and K its own.
        if app.inboxItem?.isCollapsed == true { app.toggleInbox(nil) }
        app.focusSelectedTerminal()
        check("Focus the Inbox gives it the keyboard", app.focusColumn(.inbox) && app.focusedColumn == .inbox)
        check(
            "its own host, which reads J and K",
            app.window?.firstResponder.map { String(describing: type(of: $0)).contains("InboxHostingView") } == true,
            String(describing: app.window?.firstResponder))

        // F6 and ⇧F6 walk the open columns, wrapping.
        app.focusSelectedTerminal()
        let open = app.openColumns
        app.focusColumn(by: 1)
        let after = open[(open.firstIndex(of: .terminal)! + 1) % open.count]
        check("F6: the next open column", app.focusedColumn == after, "\(open) → \(app.focusedColumn)")
        app.focusColumn(by: -1)
        check("⇧F6: back", app.focusedColumn == .terminal)
        app.toggleInbox(nil)

        // A closed column is a beep, and stays closed.
        app.editorItem?.isCollapsed = true
        check("a closed column isn't opened for it", !app.focusColumn(.editor) && app.editorItem?.isCollapsed == true)
        app.focusSelectedTerminal()
    }
}
#endif
