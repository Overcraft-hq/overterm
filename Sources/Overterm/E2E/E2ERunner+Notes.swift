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

        await readingView(notes: notes, root: root)

        // Renamed: every link to it written again, the open tab following.
        let welcome = root.appendingPathComponent("Welcome.md")
        app.openNote(welcome)
        _ = await eventually(3) { editor.active?.url?.lastPathComponent == "Welcome.md" }
        app.moveNote(welcome, to: root.appendingPathComponent("Start.md"))
        let planText = { (try? String(contentsOf: plan, encoding: .utf8)) ?? "" }
        check("a rename writes the links to it again", await eventually(3) { planText().contains("Back to [[Start]].") }, planText())
        check("its tab follows it", editor.active?.url?.lastPathComponent == "Start.md")
        check("and the index knows it", await eventually(3) { notes.index.backlinks(of: "Start.md").contains { $0.source == "Projects/Plan.md" } })

        // The lower half: backlinks with their lines, tags, tasks.
        notes.detail = .backlinks
        let lines = notes.backlinkLines(of: "Start.md")
        check("backlinks carry the line they're on", lines.contains { $0.source == "Projects/Plan.md" && $0.text == "Back to [[Start]]." }, "\(lines)")
        notes.tagFilter = "work"
        let tree = notes.tree ?? NoteItem(url: root, kind: .folder)
        let tagged = Set(notes.index.notes(tagged: "work").map { notes.url(of: $0).standardizedFileURL.path })
        let rows = NotesPanelView.rows(tree, query: "", expanded: [], tagged: tagged).map(\.item.name)
        check("a tag picked lists its notes", rows == ["Plan"], "\(rows)")
        notes.tagFilter = nil
        editor.filesRemoved(at: plan)
        let taskLine = planText().components(separatedBy: "\n").firstIndex { $0.hasPrefix("- [ ] ship it") } ?? -1
        app.toggleNoteTask(plan, line: taskLine)
        check("a task ticked in the pane is ticked in its file", planText().contains("- [x] ship it"), planText())

        // `[[` completes the vault's notes; the link is closed on accepting.
        app.openNote(untitled)
        _ = await eventually(3) { editor.active?.url?.lastPathComponent == "Untitled.md" }
        if editor.active?.showsPreview == true { editor.toggleMarkdownPreview() }
        editor.textView.setSelectedRange(NSRange(location: (editor.textView.string as NSString).length, length: 0))
        editor.textView.insertText("See [[Sta", replacementRange: editor.textView.selectedRange())
        _ = editor.updateNoteCompletion()
        let offered = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("[[ offers the vault's notes", editor.completion?.isNote == true && offered.first == "Start", "\(offered)")
        editor.acceptCompletion(at: 0)
        check("accepting writes the link, closed", editor.textView.string.hasSuffix("See [[Start]]"), editor.textView.string)
        editor.textView.insertText(" #wo", replacementRange: editor.textView.selectedRange())
        _ = editor.updateNoteCompletion()
        let tags = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("# offers the vault's tags", tags == ["work"], "\(tags)")
        editor.dismissCompletion()

        // An image pasted lands where the vault keeps attachments, embedded.
        let board = NSPasteboard(name: NSPasteboard.Name("overterm-e2e-\(UUID().uuidString)"))
        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        board.setData(image.tiffRepresentation, forType: .tiff)
        check("an image pastes into a note", editor.pasteIntoNote(from: board))
        let pasted = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.filter { $0.hasPrefix("Pasted image ") } ?? []
        check("saved as Obsidian names it", pasted.count == 1 && pasted[0].hasSuffix(".png"), "\(pasted)")
        check("and embedded at the caret", editor.textView.string.contains("![[\(pasted.first ?? "?")]]"), editor.textView.string)
        board.releaseGlobally()

        // Insert template: the vault's templates folder, its fields filled.
        write(".obsidian/templates.json", #"{"folder": "Templates"}"#)
        write("Templates/Meeting.md", "## {{title}} — {{date:YYYY}}\n")
        notes.reload()
        _ = await eventually(3) { notes.vault.settings.templatesFolder == "Templates" }
        check("the vault's templates are listed", notes.vault.templates.map(\.lastPathComponent) == ["Meeting.md"])
        if let template = notes.vault.templates.first {
            editor.insertTemplate(template)
            let year = String(Calendar.current.component(.year, from: Date()))
            check("a template inserts filled", editor.textView.string.contains("## Untitled — \(year)"), editor.textView.string)
        }

        // ⌘F finds notes by name and by what they say.
        if let terminal = app.store.selected?.terminal {
            app.spotlight.open(root: nil, terminal: terminal, needle: "ship it")
            let found = await eventually(5) {
                app.spotlight.rows.contains {
                    if case .note(let m) = $0 { return m.path == "Projects/Plan.md" && m.line > 0 }; return false
                }
            }
            check("⌘F finds a note by a line in it", found, "\(app.spotlight.rows.map(\.id))")
            app.spotlight.query = "Start"
            check(
                "and by its name",
                await eventually(3) {
                    app.spotlight.rows.contains {
                        if case .note(let m) = $0 { return m.path == "Start.md" && m.line == 0 }; return false
                    }
                })
            app.spotlight.close(keepTerminalSearch: false)
        }

        // ⌘L for a note: Ask Agent's sheet, with the note in it.
        app.openNote(plan)
        _ = await eventually(3) { editor.active?.url?.lastPathComponent == "Plan.md" }
        app.askAgentAboutNote()
        check("Ask an Agent About This Note opens its sheet", await eventually(2) { self.window.attachedSheet != nil })
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        _ = await eventually(2) { self.window.attachedSheet == nil }

        // Terminal output into today's note, under its command.
        editor.filesRemoved(at: daily)
        app.appendToTodaysNote("BUILD OK", command: "make app", folder: nil)
        let todays = (try? String(contentsOf: daily, encoding: .utf8)) ?? ""
        check("terminal text goes to today's note, fenced under its command", todays.contains("`make app`\n```\nBUILD OK\n```"), todays)

        // The graph, in the right-hand pane.
        app.openNote(plan)
        app.showNotesGraph(nil)
        check("Graph View takes the right-hand pane", app.rightPane.mode == .graph && app.diffItem?.isCollapsed == false)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(1.5)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-graph.png")
        }

        // A folder's New Tab Here: a terminal whose shell starts in it.
        let tabs = app.store.tabs.count
        let projects = root.appendingPathComponent("Projects")
        app.notesActions.newTab(projects)
        check(
            "New Tab Here opens a terminal in the folder",
            await eventually(5) {
                self.app.store.tabs.count == tabs + 1
                    && self.app.store.selected?.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                        == projects.resolvingSymlinksInPath().path
            }, app.store.selected?.workingDirectory ?? "-")

        app.sidebarPanel.panel = .files
        check("another panel stops the reading", await eventually(2) { !notes.visible })
    }

    /// A note read as Obsidian draws it: links, embeds, callouts, math,
    /// mermaid; a link followed, a task ticked in the text.
    private func readingView(notes: NotesModel, root: URL) async {
        guard let editor = app.editor else { return }
        let rich = root.appendingPathComponent("Rich.md")
        try? """
        ---
        status: draft
        tags: [demo, notes]
        ---
        # Rich

        Links to [[Welcome]], [[Projects/Plan#Plan|the plan]] and [[Nowhere]]. A ==highlight== and #inline-tag.%%hidden%%

        > [!warning] Careful
        > Inside the callout.

        Euler: $e^{i\\pi} + 1 = 0$

        ```mermaid
        graph TD
          A --> B
        ```

        - [ ] first task
        - [x] second task

        ![[Plan]]

        ![[dot.png]]
        """.write(to: rich, atomically: true, encoding: .utf8)
        let dot = NSImage(size: NSSize(width: 6, height: 6))
        dot.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 6, height: 6).fill()
        dot.unlockFocus()
        if let tiff = dot.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: root.appendingPathComponent("dot.png"))
        }
        notes.reload()
        _ = await eventually(3) { notes.index.notes["Rich.md"] != nil }
        app.openNote(rich)
        _ = await eventually(3) { editor.active?.url?.lastPathComponent == "Rich.md" }
        check("a note is a note in the editor", editor.active?.isNote == true)
        editor.toggleMarkdownPreview()
        guard let reader = editor.noteReader else { return check("the reading view is made", false) }
        check("⇧⌘V reads it", await eventually(5) { reader.renderCount > 0 && !reader.isHidden && editor.scrollView.isHidden })
        var text = ""
        reader.renderedText { text = $0 }
        _ = await eventually(3) { !text.isEmpty }
        check("its links read as their names", text.contains("Links to Welcome, the plan and Nowhere."), text)
        check("its properties are shown", text.contains("status") && text.contains("draft"), text)
        check("comments are hidden", !text.contains("hidden"), text)
        check("a callout has its title", text.contains("Careful") && !text.contains("[!warning]"), text)
        check("the embed is drawn in place", text.contains("Back to Welcome."), text)
        check("mermaid draws its diagram", await eventually(8) { reader.mermaidDrawn == 1 }, "\(reader.mermaidDrawn)")
        var hasMath = false
        reader.webView.evaluateJavaScript("document.querySelectorAll('.katex').length") { value, _ in
            hasMath = (value as? Int ?? 0) > 0
        }
        check("math is typeset", await eventually(2) { hasMath })
        // An embedded image loads, through the app's scheme and DOMPurify.
        var loaded = -1
        for _ in 0..<20 where loaded <= 0 {
            reader.webView.evaluateJavaScript("[...document.images].filter(i => i.complete && i.naturalWidth > 0).length") { value, _ in
                loaded = value as? Int ?? 0
            }
            await pause(0.15)
        }
        check("an embedded image loads", loaded >= 1, "\(loaded)")
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.5)
            app.captureWindow(to: png)
        }

        // A task ticked in the view is ticked in the text.
        let line = (editor.active?.storage.string ?? "").components(separatedBy: "\n").firstIndex { $0.hasPrefix("- [ ] first") } ?? -1
        editor.toggleNoteTask(line: line)
        check("a task ticked there is ticked in the text", editor.active?.storage.string.contains("- [x] first task") == true)
        check("as an unsaved edit", editor.document.isDirty)
        editor.saveDocument(nil)

        // Live Preview: the same note as text, its markup hidden off the
        // caret's line.
        editor.toggleMarkdownPreview()
        check("the eye again gives the text back", await eventually(2) { !editor.scrollView.isHidden })
        check("a note opens in Live Preview", editor.active?.livePreview == true && editor.lineHeight.variable)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let source = editor.textView.string as NSString
        let link = source.range(of: "[[Welcome]]").location
        check(
            "a link's brackets are hidden off the caret's line",
            await eventually(3) { editor.textView.textStorage?.attribute(.noteHidden, at: link, effectiveRange: nil) != nil })
        editor.textView.setSelectedRange(NSRange(location: link + 4, length: 0))
        check(
            "and shown on it", await eventually(2) { editor.textView.textStorage?.attribute(.noteHidden, at: link, effectiveRange: nil) == nil })
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            await pause(0.5)
            app.captureWindow(to: (png as NSString).deletingPathExtension + "-live.png")
        }
        // Ticked in the reading view above: a box drawn ticked, unticked on a click.
        let box = source.range(of: "- [x] first").location
        guard box != NSNotFound else { return check("the ticked task is in the text", false, source as String) }
        // Painted with what is on screen, a moment after.
        editor.textView.scrollRangeToVisible(NSRange(location: box, length: 0))
        check(
            "a task's box is drawn",
            await eventually(3) {
                editor.textView.textStorage?.attribute(.noteDecoration, at: box + 2, effectiveRange: nil) as? NoteDecoration == .checkbox(done: true)
            })
        check("a click on it unticks it", editor.liveClick(at: box + 2) && editor.textView.string.contains("- [ ] first task"))
        editor.toggleMarkdownPreview()
        _ = await eventually(3) { !(editor.noteReader?.isHidden ?? true) }

        // A link to a note not written yet writes it.
        editor.followNoteLink("Nowhere", anchor: nil, markdown: false)
        check("following a link opens its note", await eventually(3) { editor.active?.url?.lastPathComponent == "Nowhere.md" })
        check("a note not written yet is written", FileManager.default.fileExists(atPath: root.appendingPathComponent("Nowhere.md").path))
        check("and read, as the link was", editor.active?.showsPreview == true)
    }
}
