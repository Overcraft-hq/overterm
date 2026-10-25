import XCTest

@testable import Overterm

/// A vault as Obsidian keeps one: its settings read from `.obsidian/`, its
/// tree in Obsidian's order, iCloud's placeholders under their real names.
final class NotesVaultTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
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

    func testObsidiansSettingsAreRead() throws {
        try write(
            ".obsidian/app.json",
            #"{"attachmentFolderPath": "./assets", "newFileLocation": "folder", "newFileFolderPath": "Inbox", "useMarkdownLinks": true, "userIgnoreFilters": ["Archive/"]}"#
        )
        try write(".obsidian/daily-notes.json", #"{"folder": "Daily", "format": "YYYY/MM/DD", "template": "Templates/Day"}"#)
        try write(".obsidian/templates.json", #"{"folder": "Templates"}"#)
        let vault = NotesVault(root: dir)
        XCTAssertEqual(vault.settings.attachmentFolderPath, "./assets")
        XCTAssertEqual(vault.settings.newFileLocation, .folder)
        XCTAssertTrue(vault.settings.useMarkdownLinks)
        XCTAssertEqual(vault.settings.dailyFolder, "Daily")
        XCTAssertEqual(vault.settings.dailyFormat, "YYYY/MM/DD")
        XCTAssertEqual(vault.settings.templatesFolder, "Templates")
        let note = dir.appendingPathComponent("Projects/Plan.md")
        XCTAssertEqual(vault.folderForAttachment(of: note).path, dir.appendingPathComponent("Projects/assets").path)
        XCTAssertEqual(vault.folderForNewNote(beside: note).lastPathComponent, "Inbox")
        XCTAssertTrue(vault.isHidden(dir.appendingPathComponent("Archive/Old.md")))
        XCTAssertTrue(vault.isHidden(dir.appendingPathComponent(".obsidian")))
    }

    func testAVaultWithoutObsidianHasObsidiansDefaults() {
        let vault = NotesVault(root: dir)
        XCTAssertEqual(vault.settings, ObsidianSettings())
        XCTAssertEqual(vault.folderForAttachment(of: dir.appendingPathComponent("a/b.md")).path, dir.path)
    }

    func testTheTreeIsInObsidiansOrderWithPlaceholdersByTheirNames() throws {
        try write("b.md")
        try write("Note 10.md")
        try write("Note 2.md")
        try write("Zeta/inner.md")
        try write("Alpha/x.md")
        try write(".obsidian/app.json", "{}")
        try write(".Evicted.md.icloud")
        try write("image.png")
        let tree = NoteFiles.tree(of: NotesVault(root: dir))
        XCTAssertEqual(tree.children?.map(\.name), ["Alpha", "Zeta", "b", "Evicted", "image.png", "Note 2", "Note 10"])
        let evicted = try XCTUnwrap(tree.children?.first { $0.name == "Evicted" })
        XCTAssertTrue(evicted.isEvicted)
        XCTAssertEqual(evicted.kind, .note)
        XCTAssertEqual(tree.allNotes.count, 6)
        XCTAssertTrue(NoteFiles.isEvicted(evicted.url))
    }

    func testCoordinatedReadAndWrite() throws {
        let url = dir.appendingPathComponent("Deep/Note.md")
        try NoteFiles.write("# Hi\n", to: url)
        XCTAssertEqual(try NoteFiles.read(url), "# Hi\n")
        try NoteFiles.move(url, to: dir.appendingPathComponent("Moved.md"))
        XCTAssertEqual(try NoteFiles.read(dir.appendingPathComponent("Moved.md")), "# Hi\n")
    }

    func testMomentFormats() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-07T09:05:00Z"))
        func format(_ moment: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = MomentFormat.pattern(moment)
            return formatter.string(from: date)
        }
        XCTAssertEqual(format("YYYY-MM-DD"), "2026-03-07")
        XCTAssertEqual(format("dddd, MMMM Do YYYY"), "Saturday, March 7 2026")
        XCTAssertEqual(format("YYYY/MM/[Week] WW"), "2026/03/Week 10")
        XCTAssertEqual(format("HH:mm"), "09:05")
    }

    func testObsidiansVaultListIsRead() throws {
        try write("vaults/One/.obsidian/app.json", "{}")
        try write(
            "obsidian.json",
            #"{"vaults": {"a": {"path": "\#(dir.appendingPathComponent("vaults/One").path)", "ts": 2}, "b": {"path": "/nowhere/Gone", "ts": 3}}}"#)
        XCTAssertEqual(ObsidianVaults.known(listFile: dir.appendingPathComponent("obsidian.json")).map(\.lastPathComponent), ["One"])
    }

    func testThePathSettingExpandsTheHomeFolder() {
        XCTAssertEqual(NotesVault.root(fromSetting: "~/Notes").path, NSHomeDirectory() + "/Notes")
        XCTAssertEqual(NotesVault.root(fromSetting: "  ").path, NotesVault.defaultRoot.path)
    }

    /// The vault of whoever runs this, if it has one: read, nothing written.
    func testAnObsidianVaultOnThisMacIsListed() throws {
        guard let vault = ObsidianVaults.known().first else { throw XCTSkip("No Obsidian vault on this Mac") }
        let tree = NoteFiles.tree(of: NotesVault(root: vault))
        XCTAssertFalse(tree.allNotes.isEmpty, "\(vault.path)")
        XCTAssertFalse(tree.allFiles.contains { $0.url.path.contains("/.obsidian/") })
    }

    /// Codex: a note is never created over one that is there.
    func testCreatingNeverOverwrites() throws {
        let url = dir.appendingPathComponent("Note.md")
        try write("Note.md", "keep me")
        XCTAssertThrowsError(try NoteFiles.create(url))
        XCTAssertEqual(try NoteFiles.read(url), "keep me")
        try write(".Evicted.md.icloud")
        XCTAssertThrowsError(try NoteFiles.create(dir.appendingPathComponent("Evicted.md")))
        try NoteFiles.create(dir.appendingPathComponent("Sub/New.md"))
        XCTAssertEqual(try NoteFiles.read(dir.appendingPathComponent("Sub/New.md")), "")
    }
}
