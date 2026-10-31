import AppKit

/// Notes ▸ New Drawing: an Excalidraw canvas in the editor, written as
/// Obsidian Excalidraw writes it — elements drawn are in the file, the
/// file reopened shows them, and one changed on disk is redrawn.
extension E2ERunner {
    func drawingScenario() async {
        let notes = app.notes
        let root = notes.vault.root
        check("an isolated run has a vault of its own", root.path.contains(AppEnvironment.supportDirectory.path), root.path)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian/plugins/obsidian-excalidraw-plugin"), withIntermediateDirectories: true)
        try? #"{"folder": "Sketches", "drawingFilenamePrefix": "Sketch ", "compress": true}"#
            .write(to: root.appendingPathComponent(".obsidian/plugins/obsidian-excalidraw-plugin/data.json"), atomically: true, encoding: .utf8)
        notes.settingsChanged()
        app.showNotes(nil)
        _ = await eventually(5) { notes.tree != nil }

        app.newDrawing(in: nil)
        guard let editor = app.editor else { return check("editor exists", false) }
        check(
            "New Drawing makes one where the plugin's settings say, named as it names them",
            await eventually(3) {
                guard let url = editor.active?.url else { return false }
                return url.deletingLastPathComponent().lastPathComponent == "Sketches" && url.lastPathComponent.hasPrefix("Sketch ")
                    && url.lastPathComponent.hasSuffix(".excalidraw.md")
            }, editor.active?.url?.path ?? "nothing open")
        guard let buffer = editor.active, let url = buffer.url, let drawing = buffer.drawing else {
            return check("it opens as a drawing", false)
        }
        check("with the plugin's frontmatter", (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix(DrawingFile.frontmatter) == true)
        check(
            "and shows as one in the tree",
            await eventually(3) { notes.tree?.allFiles.first { $0.url.standardizedFileURL == url.standardizedFileURL }?.kind == .drawing })
        check("its canvas is on screen", await eventually(3) { editor.shownDrawing === drawing.view && drawing.view.window != nil })

        var ready = false
        for _ in 0..<50 {
            if await drawing.view.state().ready {
                ready = true
                break
            }
            await pause(0.2)
        }
        let last = await drawing.view.state()
        check("Excalidraw runs in it", ready, "\(last) \(drawing.view.lastLog ?? "")")

        let skeletons: [[String: Any]] = [
            ["type": "rectangle", "x": 100, "y": 100, "width": 200, "height": 100, "label": ["text": "Login service"]],
            ["type": "ellipse", "x": 400, "y": 100, "width": 120, "height": 120],
        ]
        let added = await withCheckedContinuation { done in drawing.view.call("add", skeletons) { done.resume(returning: $0 as? Int ?? 0) } }
        check("elements can be added to it", added >= 2, "\(added)")
        check(
            "they are written into the file, saved, compressed as the plugin's settings say",
            await eventually(5) {
                guard let text = try? String(contentsOf: url, encoding: .utf8), let file = DrawingFile.parse(text, markdown: true) else { return false }
                return file.encoding == .compressed && file.texts.map(\.text) == ["Login service"] && !buffer.document.isDirty
            }, (try? String(contentsOf: url, encoding: .utf8)).map { String($0.suffix(300)) } ?? "")

        // Reopened: the canvas reads what was written.
        let index = editor.buffers.firstIndex { $0 === buffer } ?? 0
        editor.removeBuffer(at: index)
        app.openNote(url)
        guard let reopened = editor.active?.drawing else { return check("it reopens as a drawing", false) }
        var count = 0
        for _ in 0..<50 {
            count = await reopened.view.state().count
            if count >= 3 { break }
            await pause(0.2)
        }
        check("reopened, the canvas shows what was drawn", count >= 3, "\(count) elements")

        // Somebody else's edit (Obsidian, an agent): the canvas follows it.
        if let text = try? String(contentsOf: url, encoding: .utf8), let file = DrawingFile.parse(text, markdown: true) {
            let plain = file.updated(scene: DrawingFile.emptyScene, encoding: .json, texts: [])
            try? plain.text.write(to: url, atomically: true, encoding: .utf8)
            editor.reloadIfChangedOnDisk()
            var after = -1
            for _ in 0..<30 {
                after = await reopened.view.state().count
                if after == 0 { break }
                await pause(0.2)
            }
            check("a change on disk is redrawn", after == 0, "\(after) elements")
        }

        // An agent's diagram (notes_draw): a new drawing, its labels in the file.
        let made = try? await NotesMCP.call(
            "notes_draw",
            [
                "title": "Architecture",
                "elements": [
                    ["type": "rectangle", "id": "api", "x": 0, "y": 0, "width": 200, "height": 80, "label": ["text": "API"]],
                    ["type": "rectangle", "id": "db", "x": 320, "y": 0, "width": 200, "height": 80, "label": ["text": "Postgres"]],
                    ["type": "arrow", "x": 200, "y": 40, "width": 120, "height": 0, "start": ["id": "api"], "end": ["id": "db"]],
                ] as [[String: Any]],
            ], notes: notes)
        let architecture = root.appendingPathComponent("Sketches/Architecture.excalidraw.md")
        let written = (try? String(contentsOf: architecture, encoding: .utf8)).flatMap { DrawingFile.parse($0, markdown: true) }
        check("notes_draw writes an agent's diagram as a new drawing", made != nil && written != nil, "\(made ?? [:])")
        check("with its labels as text elements", Set(written?.texts.map(\.text) ?? []) == ["API", "Postgres"], "\(written?.texts ?? [])")
        check("and opens it", await eventually(3) { editor.active?.url?.lastPathComponent == "Architecture.excalidraw.md" })
        let again = try? await NotesMCP.call("notes_draw", ["title": "Architecture", "elements": [["type": "ellipse", "x": 0, "y": 0]]], notes: notes)
        check(
            "never over a drawing that is there",
            again != nil && FileManager.default.fileExists(atPath: root.appendingPathComponent("Sketches/Architecture 1.excalidraw.md").path)
                && (try? String(contentsOf: architecture, encoding: .utf8)).flatMap { DrawingFile.parse($0, markdown: true) } == written)

        // Embedded in a note: drawn as its picture in the reading view.
        let board = root.appendingPathComponent("Board.md")
        try? "# Board\n\n![[Architecture.excalidraw]]\n".write(to: board, atomically: true, encoding: .utf8)
        notes.reload()
        _ = await eventually(3) { notes.index.notes["Board.md"] != nil }
        app.openNote(board)
        _ = await eventually(3) { editor.active?.url?.lastPathComponent == "Board.md" }
        if editor.active?.showsPreview == false { editor.toggleMarkdownPreview() }
        check(
            "a note embedding a drawing shows its picture",
            await eventually(10) { (editor.noteReader?.drawingsDrawn ?? 0) >= 1 }, "\(editor.noteReader?.drawingsDrawn ?? -1)")
    }
}
