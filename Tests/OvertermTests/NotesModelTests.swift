import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

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

    func testNewNoteTakesTheNameAskedWhereObsidianPutsNewNotes() throws {
        try write(".obsidian/app.json", #"{"newFileLocation": "folder", "newFileFolderPath": "Inbox"}"#)
        try write("Inbox/Untitled.md")
        let model = NotesModel(vault: NotesVault(root: dir))
        let folder = model.newNoteFolder(in: nil)
        XCTAssertEqual(folder.standardizedFileURL.path, dir.appendingPathComponent("Inbox").standardizedFileURL.path)
        XCTAssertEqual(model.suggestedNoteName(in: folder), "Untitled 1")
        let url = try model.newNote(named: "Ideas", in: folder)
        XCTAssertEqual(url.lastPathComponent, "Ideas.md")
        XCTAssertEqual(try NoteFiles.read(url), "")
        XCTAssertEqual(try model.newNote(named: "Plan.md", in: folder).lastPathComponent, "Plan.md")
        // Never over a note that is there, never outside the vault.
        XCTAssertThrowsError(try model.newNote(named: "Ideas", in: folder))
        XCTAssertThrowsError(try model.newNote(named: "Away", in: dir.deletingLastPathComponent()))
    }

    func testANewNotesNameIsRefusedAsObsidianRefusesIt() throws {
        try write("Taken.md")
        XCTAssertNil(NoteNaming.problem("Fresh", in: dir))
        XCTAssertNil(NoteNaming.problem("  Fresh idea.md ", in: dir))
        XCTAssertEqual(NoteNaming.problem("   ", in: dir), "A name, please.")
        XCTAssertEqual(NoteNaming.problem(".md", in: dir), "A name, please.")
        XCTAssertEqual(NoteNaming.problem("Ideas: one", in: dir), "A note's name can't have “:” in it.")
        XCTAssertNotNil(NoteNaming.problem("a/b", in: dir))
        XCTAssertNotNil(NoteNaming.problem("Link [x]", in: dir))
        XCTAssertNotNil(NoteNaming.problem(".hidden", in: dir))
        XCTAssertEqual(NoteNaming.problem("Taken", in: dir), "There is a note named “Taken” here already.")
        XCTAssertEqual(NoteNaming.problem("Taken.md", in: dir), "There is a note named “Taken” here already.")
        XCTAssertEqual(NoteNaming.fileName(" Fresh "), "Fresh.md")
        XCTAssertEqual(NoteNaming.fileName("Fresh.MD"), "Fresh.MD")
    }

    func testThePanesStayOnTheLastNoteWhileTheEditorShowsSomethingElse() throws {
        try write("A.md")
        try write("B.md")
        let model = NotesModel(vault: NotesVault(root: dir))
        XCTAssertNil(model.subject)
        let a = dir.appendingPathComponent("A.md")
        let b = dir.appendingPathComponent("B.md")
        model.current = a
        XCTAssertEqual(model.subject, a)
        // A file that isn't a note: the tree marks nothing, the panes keep A.
        model.current = nil
        XCTAssertEqual(model.subject, a)
        model.current = b
        XCTAssertEqual(model.subject, b)
        // A note outside this vault is never the panes' subject.
        let other = NotesVault(root: dir.appendingPathComponent("Other", isDirectory: true))
        XCTAssertNil(NotesModel.subject(current: nil, previous: b, in: other))
        XCTAssertEqual(NotesModel.subject(current: nil, previous: b, in: model.vault), b)
        XCTAssertEqual(NotesModel.subject(current: a, previous: b, in: other), a)
    }

    func testAFilterNamingNoNoteOffersTheContentsSearch() throws {
        try write("Plan.md", "ship it")
        let tree = NoteItem(url: dir, kind: .folder, children: [NoteItem(url: dir.appendingPathComponent("Plan.md"), kind: .note)])
        XCTAssertTrue(NotesPanelView.rows(tree, query: "ship it", expanded: []).isEmpty)
        let said = NotesPanelView.noMatch("ship it")
        XCTAssertEqual(said.text, "No note is named “ship it”")
        XCTAssertEqual(said.search, "Search Contents for “ship it”")
        XCTAssertTrue(NotesPanelView.filterHelp.contains("⌘F"))
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

/// Terminal text in a note: under its time and command, fenced.
final class NoteAppendTests: XCTestCase {
    func testAnEntryIsFencedUnderItsCommand() throws {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour, components.minute) = (2026, 3, 7, 9, 5)
        let date = try XCTUnwrap(Calendar.current.date(from: components))
        let entry = NoteAppend.entry("a\n```inner```\n", command: "make `x`", folder: nil, date: date, settings: ObsidianSettings())
        XCTAssertEqual(entry, "#### 09:05 — `make 'x'`\n````\na\n```inner```\n````\n")
        XCTAssertEqual(NoteAppend.append("E\n", to: ""), "E\n")
        XCTAssertEqual(NoteAppend.append("E\n", to: "# Day"), "# Day\n\nE\n")
        XCTAssertEqual(NoteAppend.append("E\n", to: "# Day\n\n"), "# Day\n\nE\n")
    }
}

/// A branch's note: where it goes, and what it starts with.
final class BranchNoteTests: XCTestCase {
    func testABranchsNoteIsFiledByRepoAndBranch() {
        XCTAssertEqual(BranchNote.path(repo: "overterm", branch: "feat/release-v03"), "Branches/overterm/feat-release-v03.md")
        let text = BranchNote.text(repo: "overterm", branch: "feat/x", checkout: NSHomeDirectory() + "/p", date: Date())
        let doc = NoteParser.parse(text)
        XCTAssertEqual(doc.properties["branch"], .text("feat/x"))
        XCTAssertEqual(doc.properties["checkout"], .text("~/p"))
        XCTAssertEqual(doc.allTags, ["branch"])
        XCTAssertEqual(doc.title, "feat/x")
    }
}

/// The Tasks pane's vault list: notes with open tasks, newest first, by title.
final class NotesTaskGroupsTests: XCTestCase {
    func testGroupsAreNewestFirstByTitleWithOpenTasksOnly() {
        var index = NotesIndex()
        index.set("Old.md", text: "# Old plan\n- [ ] a", modified: Date(timeIntervalSince1970: 1))
        index.set("Work/New.md", text: "- [ ] b\n- [x] done\n- [-] dropped", modified: Date(timeIntervalSince1970: 2))
        index.set("Done.md", text: "- [x] all done", modified: Date(timeIntervalSince1970: 3))
        let groups = NotesTaskGroups.make(index)
        XCTAssertEqual(groups.map(\.path), ["Work/New.md", "Old.md"])
        XCTAssertEqual(groups.map(\.title), ["New", "Old plan"])
        XCTAssertEqual(groups.first?.folder, "Work")
        XCTAssertEqual(groups.first?.tasks.map(\.text), ["b"])
    }

    func testATasksMarkdownReadsAsText() {
        XCTAssertEqual(String(NotesTaskGroups.inline("Click **Run now** in `app` for [[Plan|the plan]]").characters), "Click Run now in app for the plan")
        XCTAssertEqual(String(NotesTaskGroups.inline("see [[Plan]]").characters), "see Plan")
    }
}
