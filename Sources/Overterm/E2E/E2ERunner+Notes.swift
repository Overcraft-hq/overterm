import AppKit

/// Notes: the vault in the sidebar, its notes in the editor.
extension E2ERunner {
    func notesScenario() async {
        let notes = app.notes
        let root = notes.vault.root
        check("an isolated run has a vault of its own", root.path.contains(AppEnvironment.supportDirectory.path), root.path)
        try? FileManager.default.removeItem(at: root)
        func write(_ path: String, _ text: String) {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        write("Welcome.md", "# Welcome\n\nSee [[Plan]].\n")
        write("Projects/Plan.md", "---\ntags: [work]\n---\n# Plan\n\nBack to [[Welcome]].\n- [ ] ship it\n")
        write(".obsidian/daily-notes.json", #"{"folder": "Daily", "format": "YYYY-MM-DD"}"#)
        notes.settingsChanged()

        app.sidebarPanel.panel = .files
        await pause(0.2)
        check("the vault isn't read while the panel isn't showing", !notes.visible && notes.tree == nil)
        app.showNotes(nil)
        check("Notes shows the vault", await eventually(5) { notes.visible && notes.tree?.allNotes.count == 2 })
        check("in Obsidian's order", notes.tree?.children?.map(\.name) == ["Projects", "Welcome"], "\(notes.tree?.children?.map(\.name) ?? [])")
        check("its links are indexed", notes.index.backlinks(of: "Welcome.md").map(\.source) == ["Projects/Plan.md"])
        check("its tags too", notes.index.tags["work"] == 1)

        if let sidebar = app.sidebarItem?.viewController.view,
            let panel = Self.find(NSView.self, in: sidebar, where: { $0.className.contains("Hosting") })
        {
            let frame = panel.convert(panel.bounds, to: nil)
            let column = sidebar.convert(sidebar.bounds, to: nil)
            check("the panel stays inside its column", frame.minX >= column.minX - 1 && frame.maxX <= column.maxX + 1, "\(frame) \(column)")
        }

        let plan = root.appendingPathComponent("Projects/Plan.md")
        app.openNote(plan)
        guard let editor = app.editor else { return check("editor exists", false) }
        check("a note opens in the editor", await eventually(3) { editor.active?.url?.standardizedFileURL == plan.standardizedFileURL })
        check("and is the one the tree marks", await eventually(2) { notes.current?.standardizedFileURL == plan.standardizedFileURL })
        check("its folder is open in the tree", notes.expanded.contains(plan.deletingLastPathComponent().standardizedFileURL.path))

        app.newNote(in: nil)
        let untitled = root.appendingPathComponent("Untitled.md")
        check("New Note makes Untitled.md and opens it", await eventually(3) { editor.active?.url?.lastPathComponent == "Untitled.md" })
        check("in the vault", FileManager.default.fileExists(atPath: untitled.path))

        app.openDailyNote(nil)
        let daily = notes.vault.dailyNote(for: Date())
        check("Today's Note goes where Obsidian's settings say", daily.path.contains("/Daily/") && FileManager.default.fileExists(atPath: daily.path), daily.path)
        check("and opens", await eventually(3) { editor.active?.url?.standardizedFileURL == daily.standardizedFileURL })
        check("the tree picks up what was written", await eventually(5) { notes.tree?.allNotes.count == 4 }, "\(notes.tree?.allNotes.map(\.name) ?? [])")

        app.sidebarPanel.panel = .files
        check("another panel stops the reading", await eventually(2) { !notes.visible })
    }
}
