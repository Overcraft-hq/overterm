#if E2E
import AppKit
import SwiftUI

/// Issue #31's third patch, the editor beside an agent: Undo/Redo/Cut by
/// the Edit menu's actions (EDIT-U3), a file rewritten on disk while the
/// window stays as it is (EDIT-G3), the tree's git marks and Changed only
/// (EDIT-G6), the tree following the editor (EDIT-U2), Go to File (EDIT-G1)
/// and ⌘L from the editor (EDIT-N1) — every step through the app's own
/// methods and the menu's actions, never a synthetic key.
extension E2ERunner {
    package func editorBesideScenario() async {
        let repo = scratch.appendingPathComponent("editor-beside")
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        let main = repo.appendingPathComponent("Sources/App/main.swift")
        try? "let one = 1\nlet two = 2\nlet three = 3\nprint(one + two + three)\n".write(to: main, atomically: true, encoding: .utf8)
        try? "# beside\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? await git(["init", "-q", "-b", "main"], in: repo)
        try? await git(["add", "-A"], in: repo)
        try? await git(["commit", "-q", "-m", "First"], in: repo)
        app.newTab(in: repo)
        _ = await eventually(8) { self.app.tree.root?.standardizedFileURL.path == repo.standardizedFileURL.path }
        _ = await eventually(8) { self.app.diff.root?.standardizedFileURL.path == repo.standardizedFileURL.path }
        if app.sidebarItem?.isCollapsed == true { app.toggleFileTree(nil) }
        app.sidebarPanel.panel = .files

        // EDIT-U2: the tree follows the file the editor shows.
        app.openInEditor(main)
        guard let editor = app.editor else { return check("the editor exists", false) }
        check("the file opens in the editor", await eventually(3) { editor.active?.url == main })
        check(
            "the tree opens the file's folders and picks its row",
            await eventually(3) { self.app.tree.selectedRow?.entry.name == "main.swift" },
            "\(app.tree.rows.map(\.entry.name)) selected \(app.tree.selection?.path ?? "none")")
        app.tree.collapseAll()
        app.tree.selection = nil
        app.revealInFiles(main)
        check("Reveal in Files opens them again", app.tree.selectedRow?.entry.name == "main.swift")
        app.sidebarPanel.panel = .git
        app.tree.collapseAll()
        let readme = repo.appendingPathComponent("README.md")
        app.openInEditor(readme)
        _ = await eventually(3) { editor.active?.url == readme }
        check("while Files isn't showing, the tree is left alone", app.tree.rows.map(\.entry.name) == ["Sources", "README.md"])
        app.sidebarPanel.panel = .files
        app.openInEditor(main)
        _ = await eventually(3) { editor.active?.url == main }

        // EDIT-U3: Undo, Redo and Cut, as the Edit menu sends them.
        let textView = editor.textView!
        editor.focus()
        let before = textView.string
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("// added\n", replacementRange: textView.selectedRange())
        editor.textView.breakUndoCoalescing()
        // The typing's undo group closes at the end of the run loop's turn.
        await pause(0.1)
        let menu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
        func item(_ id: String) -> NSMenuItem? { menu?.items.first { $0.identifier?.rawValue == id } }
        check("the Edit menu has Undo, Redo and Cut", item("edit.undo") != nil && item("edit.redo") != nil && item("edit.cut") != nil)
        // What the menu does for a key window: its item's action, no target,
        // down the window's responder chain from its first responder. The
        // run's app is in the background — no key window — so NSApp's own
        // nil-target search would find nobody; this is the same chain.
        func press(_ id: String) -> Bool {
            guard let item = item(id), let action = item.action, let first = window.firstResponder else { return false }
            var responder: NSResponder? = first
            while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
            guard let answering = responder else { return false }
            if let validating = answering as? NSUserInterfaceValidations, !validating.validateUserInterfaceItem(item) { return false }
            return answering.tryToPerform(action, with: item)
        }
        check("the editor's text has the keyboard", window.firstResponder === textView, String(describing: window.firstResponder))
        check("the edit is undoable", textView.undoManager?.canUndo == true && textView.undoManager === editor.active?.undo)
        check("Undo reaches the editor's text and is enabled there", press("edit.undo"))
        check("Undo takes the edit back", textView.string == before, textView.string.prefix(40).debugDescription)
        await pause(0.1)
        check("Redo reaches it too", press("edit.redo"))
        check("Redo puts it back", textView.string.hasPrefix("// added\n"), textView.string.prefix(40).debugDescription)
        textView.setSelectedRange(NSRange(location: 0, length: 9))
        check("Cut reaches it", press("edit.cut"))
        check(
            "Cut takes the selection to the clipboard", textView.string == before && NSPasteboard.general.string(forType: .string) == "// added\n",
            textView.string.prefix(40).debugDescription)
        editor.saveDocument(nil)

        // EDIT-G3: an agent rewrites the file; nobody makes the window key.
        try? "let one = 10\nlet two = 2\nlet three = 3\nprint(one + two + three)\n".write(to: main, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: main.path)
        check(
            "a file an agent rewrites reloads from the checkout's watcher", await eventually(5) { textView.string.hasPrefix("let one = 10\n") },
            textView.string.prefix(20).debugDescription)
        // With edits of yours: the bar, not a reload.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("// mine\n", replacementRange: textView.selectedRange())
        try? "let one = 100\nlet two = 2\nlet three = 3\nprint(one + two + three)\n".write(to: main, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: main.path)
        check("with edits of yours, the bar asks instead", await eventually(5) { editor.diskBar.isHidden == false })
        check("…and your edits stay", textView.string.hasSuffix("// mine\n") && textView.string.hasPrefix("let one = 10\n"))
        check("the bar names the file", editor.diskBar.message == EditorDiskBar.message("main.swift"), editor.diskBar.message)
        editor.diskBar.onKeep?()
        check("Keep Mine puts the bar away and keeps your text", editor.diskBar.isHidden && textView.string.hasSuffix("// mine\n"))
        try? "let one = 1000\nlet two = 2\nlet three = 3\nprint(one + two + three)\n".write(to: main, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(15)], ofItemAtPath: main.path)
        check("a later rewrite asks again", await eventually(5) { editor.diskBar.isHidden == false })
        editor.diskBar.onReload?()
        check(
            "Reload takes the disk's version", textView.string.hasPrefix("let one = 1000\n") && !editor.document.isDirty && editor.diskBar.isHidden,
            textView.string.prefix(20).debugDescription)

        // EDIT-G6: the tree's marks, from the changes pane's own read.
        try? "new\n".write(to: repo.appendingPathComponent("Sources/App/New.swift"), atomically: true, encoding: .utf8)
        let marked = await eventually(8) {
            let marks = self.app.tree.marks
            return marks.mark(for: main, isDirectory: false) == .modified
                && marks.mark(for: repo.appendingPathComponent("Sources/App/New.swift"), isDirectory: false) == .untracked
                && marks.mark(for: repo.appendingPathComponent("Sources"), isDirectory: true) == .modified
        }
        check("the tree marks a modified and an untracked file, and dots their folder", marked, "\(app.tree.marks.files)")
        check(
            "an unchanged file is left plain", app.tree.marks.mark(for: readme, isDirectory: false) == nil)
        app.tree.collapseAll()
        app.tree.changedOnly = true
        check(
            "Changed only lists the changed files under their folders, open",
            app.tree.visibleRows.map(\.entry.name) == ["Sources", "App", "main.swift", "New.swift"],
            "\(app.tree.visibleRows.map(\.entry.name))")
        app.tree.changedOnly = false

        // EDIT-G1: Go to File, by name and name:line.
        editor.perform("editor.goToFile")
        check("⌘P opens Go to File", editor.picker?.identifier?.rawValue == "goToFile")
        if let picker = editor.picker {
            picker.setQuery("readme")
            check(
                "its list is the checkout's files",
                await eventually(5) {
                    picker.setQuery("readme")
                    return picker.itemTitles.first == "README.md"
                }, "\(picker.itemTitles)")
            picker.setQuery("main.swift:3")
            check("name:line ranks by the name", picker.itemTitles.first == "main.swift", "\(picker.itemTitles)")
            picker.chooseSelected()
            check(
                "and opens the file at the line", await eventually(3) { editor.active?.url == main && editor.selectedLine == 3 },
                "\(editor.active?.url?.lastPathComponent ?? "none") line \(editor.selectedLine)")
        }
        editor.textView.window?.makeFirstResponder(nil)
        app.goToFile()
        check("⌘K's Go to File opens the same picker", editor.picker?.identifier?.rawValue == "goToFile")
        editor.picker?.dismiss()

        // EDIT-N1: ⌘L with the editor's keyboard and a selection.
        editor.focus()
        let lines = textView.string as NSString
        let second = lines.lineRange(for: NSRange(location: lines.range(of: "let two").location, length: 0))
        let third = lines.lineRange(for: NSRange(location: lines.range(of: "let three").location, length: 0))
        textView.setSelectedRange(NSRange(location: second.location, length: NSMaxRange(third) - second.location - 1))
        app.askAboutSelection(nil)
        let shown = await eventually(3) { self.window.attachedSheet != nil && self.app.askAgent.isOpen }
        let asked = app.askAgent.selection
        check(
            "⌘L in the editor hands on the file's path, its lines and the text",
            shown && asked.hasPrefix("Sources/App/main.swift, lines 2–3:")
                && asked.contains("let two = 2\nlet three = 3"), asked.debugDescription)
        check("the chip names the place", app.askAgent.subject == "Sources/App/main.swift:2–3", app.askAgent.subject ?? "none")
        app.askAgent.stop()
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(5) { self.window.attachedSheet == nil }

        // A .tfvars' values through Secrets first.
        let vars = repo.appendingPathComponent("prod.tfvars")
        try? "db_password = \"hunter2-very-secret\"\n".write(to: vars, atomically: true, encoding: .utf8)
        app.openInEditor(vars)
        _ = await eventually(3) { editor.active?.url == vars }
        editor.focus()
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        app.askAboutSelection(nil)
        _ = await eventually(3) { self.window.attachedSheet != nil && self.app.askAgent.isOpen }
        check(
            "a .tfvars' secret never reaches the sheet",
            app.askAgent.isOpen && !app.askAgent.selection.contains("hunter2-very-secret")
                && app.askAgent.selection.contains("db_password"), app.askAgent.selection.debugDescription)
        app.askAgent.stop()
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(5) { self.window.attachedSheet == nil }

        // No selection in the editor: ⌘L is what it was — no sheet.
        editor.focus()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        app.askAboutSelection(nil)
        await pause(0.3)
        check("with nothing selected, ⌘L opens no sheet", window.attachedSheet == nil && !app.askAgent.isOpen)
        editor.saveDocument(nil)
    }
}
#endif
