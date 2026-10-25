import XCTest

@testable import Overterm

/// What the reading view is handed: links resolved, embeds cut to their
/// heading or block, properties in order — and a ticked task's place.
final class NoteRenderingTests: XCTestCase {
    private func index(_ notes: [String: String]) -> NotesIndex {
        var index = NotesIndex()
        for (path, text) in notes { index.set(path, text: text, modified: Date()) }
        return index
    }

    func testThePayloadResolvesLinksAndEmbeds() {
        let notes = [
            "A.md": "---\nzeta: 1\nalpha: [x, y]\n---\nSee [[B]], [[Missing]]\n![[B#Part]]\n![[img.png|200]]",
            "B.md": "# Intro\nskip\n## Part\nin part [[C]]\n## Next\nnot",
            "C.md": "",
            "img.png": "",
        ]
        let payload = NoteRenderPayload.make(path: "A.md", text: notes["A.md"]!, index: index(notes)) { notes[$0] }
        XCTAssertEqual(payload.lineOffset, 4)
        XCTAssertTrue(payload.text.hasPrefix("See [[B]]"))
        XCTAssertEqual(payload.properties.map(\.0), ["zeta", "alpha"])
        XCTAssertEqual(payload.properties[1].2, ["x", "y"])
        XCTAssertEqual(payload.links["B"]?.path, "B.md")
        XCTAssertEqual(payload.links["img.png"]?.kind, .image)
        XCTAssertNil(payload.links["Missing"])
        // Its links by their paths, read as they were written.
        XCTAssertEqual(payload.embeds["B#Part"], "## Part\nin part [[C|C]]")
        // A link inside the embed resolves too.
        XCTAssertEqual(payload.links["C"]?.path, "C.md")
    }

    func testANoteEmbeddingItselfEnds() {
        let notes = ["A.md": "![[B]]", "B.md": "![[A]]"]
        let payload = NoteRenderPayload.make(path: "A.md", text: notes["A.md"]!, index: index(notes)) { notes[$0] }
        XCTAssertEqual(payload.embeds["B"], "![[A]]")
        XCTAssertEqual(payload.embeds["A"], "")
    }

    func testSectionsAndBlocks() {
        let text = "# A\nx\n## B\ny\n### C\nz\n## D\nw\n\npara one\npara two ^p1\n\n- item ^i1\n- other\n\n| t |\n|---|\n^tbl"
        XCTAssertEqual(NoteSections.extract(text, anchor: "B"), "## B\ny\n### C\nz")
        XCTAssertEqual(NoteSections.extract(text, anchor: "A#B"), "## B\ny\n### C\nz")
        XCTAssertEqual(NoteSections.extract(text, anchor: "^p1"), "para one\npara two")
        XCTAssertEqual(NoteSections.extract(text, anchor: "^i1"), "- item")
        XCTAssertEqual(NoteSections.extract(text, anchor: "^tbl"), "| t |\n|---|")
        XCTAssertEqual(NoteSections.extract(text, anchor: "Nope"), "")
        XCTAssertEqual(NoteSections.extract("---\na: 1\n---\nbody", anchor: nil), "body")
    }

    func testATaskTicksAndUnticks() throws {
        let text = "---\nx: 1\n---\n- [ ] a\n- [x] b\n- [/] c"
        func toggled(_ line: Int) throws -> String {
            let edit = try XCTUnwrap(NoteEdits.toggleTask(in: text, line: line))
            return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        }
        XCTAssertTrue(try toggled(3).contains("- [x] a"))
        XCTAssertTrue(try toggled(4).contains("- [ ] b"))
        XCTAssertTrue(try toggled(5).contains("- [x] c"))
        XCTAssertNil(NoteEdits.toggleTask(in: text, line: 0))
    }

    @MainActor func testTheVaultsFilesAreServedAndNothingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("res-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a b"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("a b/p.png"))
        let resources = NoteResources()
        resources.vaultRoot = dir
        XCTAssertEqual(
            resources.file(for: URL(string: "overterm-note://vault/a%20b/p.png")!)?.lastPathComponent, "p.png")
        XCTAssertNil(resources.file(for: URL(string: "overterm-note://vault/../../etc/passwd")!))
        XCTAssertNil(resources.file(for: URL(string: "overterm-note://elsewhere/p.png")!))
        XCTAssertEqual(NoteReaderView.encode("a b/c#d"), "a%20b/c%23d")
    }

    /// Codex: a name in an embedded note means the file closest to that
    /// note, not to the one embedding it.
    func testAnEmbedsLinksKeepTheirOwnFolder() {
        let notes = [
            "A/Main.md": "![[Child]] ![[Local]]", "A/Local.md": "main's local", "B/Child.md": "![[Local]] and [[Local#Top|top]] | [[Local\\|x]] |",
            "B/Local.md": "child's local", "A/Child.md": "",
        ]
        var index = NotesIndex()
        for (path, text) in notes { index.set(path, text: text, modified: Date()) }
        let payload = NoteRenderPayload.make(path: "A/Main.md", text: notes["A/Main.md"]!, index: index) { notes[$0] }
        XCTAssertEqual(payload.embeds["Local"], "main's local")
        // A/Child.md is the closer Child: empty; B's own is reached by path.
        let child = NoteRenderPayload.absolute(notes["B/Child.md"]!, from: "B/Child.md", resolver: index.resolver)
        XCTAssertEqual(child, "![[B/Local]] and [[B/Local#Top|top]] | [[B/Local\\|x]] |")
    }

    /// Codex: `![](assets/x.png)` written from Projects/ means the vault's
    /// assets/ when the note's folder has none.
    func testMarkdownImagesResolveByTheVaultsRules() {
        var index = NotesIndex()
        index.set("Projects/Plan.md", text: "![](assets/x.png) ![](../assets/x.png)", modified: Date())
        index = NotesIndex(notes: index.notes, files: index.resolver.files + ["assets/x.png"])
        let payload = NoteRenderPayload.make(path: "Projects/Plan.md", text: "![](assets/x.png) ![](../assets/x.png)", index: index) { _ in nil }
        XCTAssertEqual(payload.links["md:assets/x.png"]?.path, "assets/x.png")
        XCTAssertEqual(payload.links["md:../assets/x.png"]?.path, "assets/x.png")
    }
}
