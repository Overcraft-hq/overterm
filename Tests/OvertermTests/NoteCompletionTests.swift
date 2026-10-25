import XCTest

@testable import Overterm

/// What typing in a note completes, and with what.
final class NoteCompletionTests: XCTestCase {
    func testTheContextIsReadFromTheLine() {
        XCTAssertEqual(NoteCompletion.context(before: "See [[Pla"), .link(query: "Pla", start: 6))
        XCTAssertEqual(NoteCompletion.context(before: "See [["), .link(query: "", start: 6))
        XCTAssertEqual(NoteCompletion.context(before: "[[My Note#Go"), .heading(target: "My Note", query: "Go", start: 10))
        XCTAssertEqual(NoteCompletion.context(before: "[[#"), .heading(target: "", query: "", start: 3))
        XCTAssertNil(NoteCompletion.context(before: "[[Done]] and more"))
        XCTAssertNil(NoteCompletion.context(before: "[[Note|ali"))
        XCTAssertEqual(NoteCompletion.context(before: "text #pro"), .tag(query: "pro", start: 6))
        // `#` alone at a line's start begins a heading, not a tag.
        XCTAssertNil(NoteCompletion.context(before: "#"))
        XCTAssertNil(NoteCompletion.context(before: "# Heading"))
        XCTAssertNil(NoteCompletion.context(before: "a#b"))
    }

    func testCandidatesComeFromTheIndex() {
        var index = NotesIndex()
        index.set("Projects/Plan.md", text: "# Goals\n## Risks\n#work #work/overterm", modified: Date())
        index.set("Home/Plan.md", text: "#work", modified: Date())
        index.set("Ideas.md", text: "", modified: Date())
        // An attachment is a file of the vault, not a note.
        index = NotesIndex(notes: index.notes, files: index.resolver.files + ["img/plan.png"])
        let settings = ObsidianSettings()
        let links = NoteCompletion.candidates(.link(query: "plan", start: 0), index: index, source: "Ideas.md", settings: settings)
        XCTAssertEqual(links.map(\.insert), ["Home/Plan", "Projects/Plan", "plan.png"])
        let headings = NoteCompletion.candidates(
            .heading(target: "Projects/Plan", query: "ri", start: 0), index: index, source: "Ideas.md", settings: settings)
        XCTAssertEqual(headings.map(\.insert), ["Risks"])
        let tags = NoteCompletion.candidates(.tag(query: "wo", start: 0), index: index, source: "Ideas.md", settings: settings)
        XCTAssertEqual(tags.map(\.insert), ["work", "work/overterm"])
    }
}
