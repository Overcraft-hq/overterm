import XCTest

@testable import Overterm

/// What the Notes panel makes and shows: templates filled, today's note
/// where Obsidian's settings put it, new notes named as Obsidian names them.
@MainActor
final class NotesModelTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ path: String, _ text: String = "") throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private var date: Date { ISO8601DateFormatter().date(from: "2026-03-07T09:05:00Z")! }

    func testTemplatesFillTitleDateAndTime() {
        var settings = ObsidianSettings()
        settings.templateDateFormat = "DD.MM.YYYY"
        let utc = Locale(identifier: "en_US_POSIX")
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        defer { NSTimeZone.default = .current }
        let text = NoteTemplate.apply(
            "# {{title}}\n{{date}} {{ time }} {{date:dddd}} {{Date:[W]WW}} {{other}}", title: "Plan", date: date, settings: settings, locale: utc)
        XCTAssertEqual(text, "# Plan\n07.03.2026 09:05 Saturday W10 {{other}}")
    }

    func testTodaysNoteIsMadeFromTheTemplateOnce() throws {
        try write(".obsidian/daily-notes.json", #"{"folder": "Daily/", "format": "YYYY/MM-DD", "template": "Templates/Day"}"#)
        try write("Templates/Day.md", "# {{title}}\n- [ ] ")
        let model = NotesModel(vault: NotesVault(root: dir))
        let url = try model.dailyNote(for: date)
        XCTAssertEqual(model.vault.relativePath(of: url), "Daily/2026/03-07.md")
        XCTAssertEqual(try NoteFiles.read(url), "# 03-07\n- [ ] ")
        try NoteFiles.write("edited", to: url)
        _ = try model.dailyNote(for: date)
        XCTAssertEqual(try NoteFiles.read(url), "edited")
        XCTAssertTrue(model.expanded.contains(dir.appendingPathComponent("Daily/2026").standardizedFileURL.path))
        XCTAssertFalse(model.expanded.contains(dir.standardizedFileURL.path))
    }

    func testNewNotesAreUntitledAndNumbered() throws {
        try write(".obsidian/app.json", #"{"newFileLocation": "folder", "newFileFolderPath": "Inbox"}"#)
        try write("Inbox/Untitled.md")
        try Data().write(to: dir.appendingPathComponent("Inbox/.Untitled 1.md.icloud"))
        let model = NotesModel(vault: NotesVault(root: dir))
        XCTAssertEqual(try model.newNote(in: nil).lastPathComponent, "Untitled 2.md")
        XCTAssertEqual(try model.newNote(in: dir).deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(try model.newFolder(in: nil).lastPathComponent, "Untitled")
    }

    func testTheTreesRowsFollowWhatIsOpenAndTheFilter() throws {
        try write("A/One.md")
        try write("A/B/Two.md")
        try write("Three.md")
        let tree = NoteFiles.tree(of: NotesVault(root: dir))
        func names(_ query: String, _ expanded: Set<String>) -> [String] {
            NotesPanelView.rows(tree, query: query, expanded: expanded).map { "\($0.depth)\($0.item.name)" }
        }
        XCTAssertEqual(names("", []), ["0A", "0Three"])
        XCTAssertEqual(names("", [dir.appendingPathComponent("A").standardizedFileURL.path]), ["0A", "1B", "1One", "0Three"])
        XCTAssertEqual(names("two", []), ["0A", "1B", "2Two"])
    }
}

/// A pasted image's name and embed, as Obsidian writes them.
final class NoteAttachmentTests: XCTestCase {
    func testPastedImagesAreNamedAndEmbeddedAsObsidianDoes() throws {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute, components.second) = (2026, 3, 7, 9, 5, 1)
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        XCTAssertEqual(NoteAttachments.pastedName(at: date), "Pasted image 20260307090501.png")
        let resolver = LinkResolver(files: ["assets/Pasted image 1.png", "Notes/A.md"])
        var settings = ObsidianSettings()
        XCTAssertEqual(
            NoteAttachments.embed("assets/Pasted image 1.png", from: "Notes/A.md", resolver: resolver, settings: settings),
            "![[Pasted image 1.png]]")
        settings.useMarkdownLinks = true
        settings.newLinkFormat = "relative"
        XCTAssertEqual(
            NoteAttachments.embed("assets/Pasted image 1.png", from: "Notes/A.md", resolver: resolver, settings: settings),
            "![](../assets/Pasted%20image%201.png)")
    }
}

/// What notes say, searched: every word on a line, case and accents aside.
final class NotesSearchTests: XCTestCase {
    func testLinesWithEveryWord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "intro\nShip the Café release\nship it\nthe release ships".write(to: dir.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "nothing here".write(to: dir.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let found = NotesSearch.lines("cafe ship", in: NotesVault(root: dir), paths: ["A.md", "B.md"])
        XCTAssertEqual(found.map(\.line), [2])
        XCTAssertEqual(found.first?.text, "Ship the Café release")
        XCTAssertEqual(NotesSearch.lines("release", in: NotesVault(root: dir), paths: ["A.md"], perNote: 5).map(\.line), [2, 4])
        XCTAssertTrue(NotesSearch.lines("x", in: NotesVault(root: dir), paths: ["A.md"]).isEmpty)
    }
}
