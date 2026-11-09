import XCTest

@testable import Overterm

/// A drop in the Notes panel: what moves where.
final class NoteMoveTests: XCTestCase {
    private let vault = URL(fileURLWithPath: "/v")
    private func url(_ path: String) -> URL { URL(fileURLWithPath: "/v/" + path) }

    func testIntoAFolder() {
        XCTAssertEqual(NoteMove.target(of: url("Inbox/Plan.md"), into: url("Projects"), vault: vault), url("Projects/Plan.md"))
        XCTAssertEqual(NoteMove.target(of: url("Archive"), into: url("Projects"), vault: vault), url("Projects/Archive"), "a folder too")
        XCTAssertEqual(NoteMove.target(of: url("Projects/Plan.md"), into: vault, vault: vault), url("Plan.md"), "to the top")
    }

    func testNotWhereItCant() {
        XCTAssertNil(NoteMove.target(of: url("Projects"), into: url("Projects"), vault: vault), "onto itself")
        XCTAssertNil(NoteMove.target(of: url("Projects"), into: url("Projects/Old"), vault: vault), "into its own folder")
        XCTAssertNil(NoteMove.target(of: url("Projects/Plan.md"), into: url("Projects"), vault: vault), "already there")
        XCTAssertNil(NoteMove.target(of: URL(fileURLWithPath: "/elsewhere/a.md"), into: url("Projects"), vault: vault), "not of the vault")
        XCTAssertNil(NoteMove.target(of: vault, into: url("Projects"), vault: vault), "the vault itself")
        XCTAssertNil(NoteMove.target(of: url("Projects2/a.md"), into: url("Projects2"), vault: vault), "a sibling's prefix isn't the folder")
    }
}
