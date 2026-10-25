import XCTest

@testable import Overterm

/// What an agent can do with the notes: find them, read them — nothing else.
@MainActor
final class NotesMCPTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try "---\ntags: [work]\n---\n# Plan\nShip the notes.\n## Risks\nNone [[Ideas]]".write(
            to: dir.appendingPathComponent("Projects/Plan.md"), atomically: true, encoding: .utf8)
        try "See [[Plan]].".write(to: dir.appendingPathComponent("Ideas.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "{}".write(to: dir.appendingPathComponent(".obsidian/app.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testSearchFindsNamesTagsAndLines() async throws {
        let notes = NotesModel(vault: NotesVault(root: dir))
        let byName = text(try await NotesMCP.call("notes_search", ["query": "plan"], notes: notes))
        XCTAssertTrue(byName.contains("- Projects/Plan.md"), byName)
        let byLine = text(try await NotesMCP.call("notes_search", ["query": "ship notes"], notes: notes))
        XCTAssertTrue(byLine.contains("Projects/Plan.md:5: Ship the notes."), byLine)
        let byTag = text(try await NotesMCP.call("notes_search", ["query": "#work"], notes: notes))
        XCTAssertTrue(byTag.contains("Projects/Plan.md"), byTag)
    }

    func testReadGivesTheNoteItsLinksAndBacklinks() async throws {
        let notes = NotesModel(vault: NotesVault(root: dir))
        let plan = text(try await NotesMCP.call("notes_read", ["note": "Plan"], notes: notes))
        XCTAssertTrue(plan.hasPrefix("# Projects/Plan.md\n\n---\ntags: [work]"), plan)
        XCTAssertTrue(plan.contains("Links to: Ideas.md"), plan)
        XCTAssertTrue(plan.contains("Linked from: Ideas.md"), plan)
        let section = text(try await NotesMCP.call("notes_read", ["note": "Plan#Risks"], notes: notes))
        XCTAssertTrue(section.contains("## Risks\nNone") && !section.contains("Ship"), section)
    }

    func testNothingOutsideTheVaultIsRead() async {
        let notes = NotesModel(vault: NotesVault(root: dir))
        for target in ["../../etc/passwd", ".obsidian/app.json", "/etc/hosts", "Missing"] {
            do {
                _ = try await NotesMCP.call("notes_read", ["note": target], notes: notes)
                XCTFail("read \(target)")
            } catch {}
        }
    }

    /// Codex: a negative max_chars once trapped the whole app.
    func testAnyMaxCharsIsSafe() async throws {
        let notes = NotesModel(vault: NotesVault(root: dir))
        for limit in [-1, 0, Int.max] {
            let result = text(try await NotesMCP.call("notes_read", ["note": "Plan", "max_chars": limit], notes: notes))
            XCTAssertTrue(result.hasPrefix("# Projects/Plan.md"), "\(limit)")
        }
    }
}
