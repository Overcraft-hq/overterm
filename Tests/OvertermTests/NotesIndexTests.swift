import XCTest

@testable import Overterm

/// Links resolved as Obsidian resolves them, and what the index answers.
final class NotesIndexTests: XCTestCase {
    private let resolver = LinkResolver(files: [
        "Plan.md", "Work/Plan.md", "Work/Deep/Notes.md", "Home/Notes.md", "assets/diagram.png", "Work/Spec.v2.md",
    ])

    func testANameMeansTheClosestFile() {
        XCTAssertEqual(resolver.resolve("Plan", from: "Inbox/Today.md"), "Plan.md")
        XCTAssertEqual(resolver.resolve("plan", from: "Work/Today.md"), "Work/Plan.md")
        XCTAssertEqual(resolver.resolve("Notes", from: "Inbox.md"), "Home/Notes.md")
        XCTAssertEqual(resolver.resolve("Notes", from: "Work/Deep/X.md"), "Work/Deep/Notes.md")
    }

    func testPathsFromTheRootTheFolderOrTheirEnd() {
        XCTAssertEqual(resolver.resolve("Work/Plan", from: "Home/Notes.md"), "Work/Plan.md")
        XCTAssertEqual(resolver.resolve("/Work/Plan.md", from: "x.md"), "Work/Plan.md")
        XCTAssertEqual(resolver.resolve("Deep/Notes", from: "Work/Plan.md"), "Work/Deep/Notes.md")
        XCTAssertEqual(resolver.resolve("../Plan", from: "Work/Deep/Notes.md"), "Work/Plan.md")
        XCTAssertEqual(resolver.resolve("diagram.png", from: "Plan.md"), "assets/diagram.png")
        XCTAssertEqual(resolver.resolve("Spec.v2", from: "Plan.md"), "Work/Spec.v2.md")
        XCTAssertEqual(resolver.resolve("", from: "Plan.md"), "Plan.md")
        XCTAssertNil(resolver.resolve("Nothing", from: "Plan.md"))
        XCTAssertNil(resolver.resolve("../../Plan", from: "Work/Plan.md"))
    }

    func testNewLinksNameAFileAsShortlyAsTheyCan() {
        XCTAssertEqual(resolver.linkText(for: "Work/Spec.v2.md", from: "Plan.md"), "Spec.v2")
        XCTAssertEqual(resolver.linkText(for: "Work/Plan.md", from: "x.md"), "Work/Plan")
        XCTAssertEqual(resolver.linkText(for: "assets/diagram.png", from: "x.md"), "diagram.png")
        XCTAssertEqual(resolver.linkText(for: "Work/Plan.md", from: "x.md", format: "absolute"), "Work/Plan")
        XCTAssertEqual(resolver.linkText(for: "Work/Deep/Notes.md", from: "Work/Plan.md", format: "relative"), "Deep/Notes")
        XCTAssertEqual(resolver.linkText(for: "Plan.md", from: "Work/Deep/Notes.md", format: "relative"), "../../Plan")
    }

    func testBacklinksTagsAndTasks() {
        var index = NotesIndex()
        let now = Date()
        index.set("A.md", text: "---\ntags: [work]\n---\nSee [[B]] and [[Missing]]. #work/overterm\n- [ ] do it", modified: now)
        index.set("B.md", text: "Back to [[A#Top]], [[B]] itself. #home\n- [x] done", modified: now)
        XCTAssertEqual(index.backlinks(of: "B.md").map(\.source), ["A.md"])
        XCTAssertEqual(index.backlinks(of: "A.md").first?.link.heading, "Top")
        XCTAssertEqual(index.unresolved["Missing"]?.map(\.source), ["A.md"])
        XCTAssertEqual(index.tags, ["work": 1, "work/overterm": 1, "home": 1])
        XCTAssertEqual(index.notes(tagged: "work"), ["A.md"])
        XCTAssertEqual(index.tasks.map(\.task.text), ["do it", "done"])

        // Missing.md written: the link resolves, and isn't unresolved any more.
        index.set("Missing.md", text: "", modified: now)
        XCTAssertEqual(index.backlinks(of: "Missing.md").map(\.source), ["A.md"])
        XCTAssertNil(index.unresolved["Missing"])
        index.remove("A.md")
        XCTAssertTrue(index.backlinks(of: "B.md").isEmpty)
    }

    func testSearchRanksNamesFirst() {
        var index = NotesIndex()
        index.set("Projects/Overterm.md", text: "", modified: Date())
        index.set("Overview.md", text: "", modified: Date())
        index.set("Old/Plan.md", text: "---\naliases: [Overterm plan]\n---", modified: Date())
        XCTAssertEqual(index.notes(matching: "over"), ["Overview.md", "Projects/Overterm.md", "Old/Plan.md"])
        XCTAssertEqual(index.notes(matching: "old"), ["Old/Plan.md"])
    }

    func testABuildKeepsWhatDidNotChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try "[[Two]]".write(to: dir.appendingPathComponent("One.md"), atomically: true, encoding: .utf8)
        try "#tag".write(to: dir.appendingPathComponent("Sub/Two.md"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent(".Three.md.icloud"))
        let vault = NotesVault(root: dir)
        let first = NotesIndex.build(vault)
        XCTAssertEqual(first.paths, ["One.md", "Sub/Two.md", "Three.md"])
        XCTAssertTrue(first.notes["Three.md"]!.isEvicted)
        XCTAssertEqual(first.backlinks(of: "Sub/Two.md").map(\.source), ["One.md"])

        // An entry whose date matches is kept, not read again.
        var stale = first
        stale.set("One.md", text: "kept", modified: first.notes["One.md"]!.modified)
        XCTAssertTrue(NotesIndex.build(vault, previous: stale).backlinks(of: "Sub/Two.md").isEmpty)
    }

    /// The vault on this Mac, if any: every link that resolves names a file of it.
    func testAVaultOnThisMacIndexes() throws {
        guard let root = ObsidianVaults.known().first else { throw XCTSkip("No Obsidian vault on this Mac") }
        let index = NotesIndex.build(NotesVault(root: root))
        XCTAssertFalse(index.notes.isEmpty)
        let files = Set(index.resolver.files)
        for (target, _) in index.incoming { XCTAssertTrue(files.contains(target), target) }
    }
}
