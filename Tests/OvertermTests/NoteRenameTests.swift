import XCTest

@testable import Overterm

/// A rename's links written again — only the ones that would break, with
/// everything else about them kept.
final class NoteRenameTests: XCTestCase {
    private func run(
        _ notes: [String: String], rename old: String, to new: String, settings: ObsidianSettings = ObsidianSettings()
    ) -> [String: String] {
        var index = NotesIndex()
        for (path, text) in notes { index.set(path, text: text, modified: Date()) }
        let moves = NoteRename.moves(of: old, to: new, files: index.resolver.files)
        return NoteRename.rewrites(index: index, moves: moves, settings: settings) { notes[$0] }
    }

    func testARenamedNotesLinksFollowIt() {
        let result = run(
            [
                "Plan.md": "",
                "A.md": "See [[Plan]], [[Plan#Goals|the goals]], [[plan#^b1]], ![[Plan]] and [[Other]].",
                "B.md": "No links here to it: [[A]]",
            ], rename: "Plan.md", to: "Roadmap.md")
        XCTAssertEqual(result.keys.sorted(), ["A.md"])
        XCTAssertEqual(result["A.md"], "See [[Roadmap]], [[Roadmap#Goals|the goals]], [[Roadmap#^b1]], ![[Roadmap]] and [[Other]].")
    }

    func testAMoveThatStillResolvesChangesNothing() {
        let result = run(["Plan.md": "", "A.md": "[[Plan]]"], rename: "Plan.md", to: "Archive/Plan.md")
        XCTAssertTrue(result.isEmpty, "\(result)")
    }

    func testAMoveIntoAmbiguityWritesThePath() {
        let result = run(
            ["Work/Plan.md": "", "Home/Plan.md": "", "Home/A.md": "[[Work/Plan]] and [[Plan]]"], rename: "Work/Plan.md",
            to: "Other/Plan.md")
        // `[[Plan]]` meant Home/Plan.md (its own folder): untouched.
        XCTAssertEqual(result["Home/A.md"], "[[Other/Plan]] and [[Plan]]")
    }

    func testAFolderRenameMovesEveryLinkIntoIt() {
        let result = run(
            ["Old/One.md": "[[Two]]", "Old/Two.md": "", "Old/Sub/Three.md": "", "A.md": "[[Old/One]] [[Old/Sub/Three|3]] [[One]]"],
            rename: "Old", to: "New")
        // "Shortest": a name no other file has is written bare, as Obsidian does.
        XCTAssertEqual(result["A.md"], "[[One]] [[Three|3]] [[One]]")
        XCTAssertNil(result["Old/One.md"], "[[Two]] still finds Two beside it")
    }

    func testMarkdownLinksKeepTheirShape() {
        let result = run(
            ["My Plan.md": "", "Notes/A.md": "[the plan](../My%20Plan.md#Top) ![](../img.png) [web](https://x.dev)", "img.png": ""],
            rename: "My Plan.md", to: "Projects/Big Plan.md",
            settings: {
                var s = ObsidianSettings(); s.newLinkFormat = "relative"; return s
            }())
        XCTAssertEqual(result["Notes/A.md"], "[the plan](../Projects/Big%20Plan.md#Top) ![](../img.png) [web](https://x.dev)")
    }

    func testEmbedsOfFilesAndTableBars() {
        let result = run(
            ["img.png": "", "A.md": "![[img.png|200]]\n| a | [[B\\|bee]] |", "B.md": ""], rename: "img.png", to: "assets/diagram.png")
        XCTAssertEqual(result["A.md"], "![[diagram.png|200]]\n| a | [[B\\|bee]] |")
        let table = run(["A.md": "| [[B\\|bee]] |", "B.md": ""], rename: "B.md", to: "C.md")
        XCTAssertEqual(table["A.md"], "| [[C\\|bee]] |")
    }

    func testCodeIsNeverRewritten() {
        let result = run(["Plan.md": "", "A.md": "`[[Plan]]` [[Plan]]\n```\n[[Plan]]\n```"], rename: "Plan.md", to: "X.md")
        XCTAssertEqual(result["A.md"], "`[[Plan]]` [[X]]\n```\n[[Plan]]\n```")
    }

    func testAbsoluteFormatAndExtensionsAsWritten() {
        var settings = ObsidianSettings()
        settings.newLinkFormat = "absolute"
        let result = run(["Plan.md": "", "A.md": "[[Plan.md]] [[Plan]]"], rename: "Plan.md", to: "Work/Roadmap.md", settings: settings)
        XCTAssertEqual(result["A.md"], "[[Work/Roadmap.md]] [[Work/Roadmap]]")
    }

    /// Codex: a link typed and not saved yet is followed by a rename too.
    func testUnsavedLinksAreRewritten() {
        var index = NotesIndex()
        index.set("Plan.md", text: "", modified: Date())
        index.set("A.md", text: "nothing yet", modified: Date())
        let moves = NoteRename.moves(of: "Plan.md", to: "Roadmap.md", files: index.resolver.files)
        let result = NoteRename.rewrites(index: index, moves: moves, settings: ObsidianSettings(), unsaved: ["A.md": "now [[Plan]]"]) { _ in
            "nothing yet"
        }
        XCTAssertEqual(result["A.md"], "now [[Roadmap]]")
    }
}
