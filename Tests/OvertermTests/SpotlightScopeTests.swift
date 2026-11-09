import XCTest

@testable import Overterm

/// ⌘F's tabs: All shows a few of each kind, the others one kind in full.
final class SpotlightScopeTests: XCTestCase {
    private let names = (1...8).map { "src/file\($0).swift" }
    private let contents = (1...20).map { ContentMatch(path: "src/a.swift", line: $0, text: "match") }
    private let notes = (1...3).map { ContentMatch(path: "Note\($0).md", line: $0, text: "match") }

    private func rows(_ scope: SpotlightModel.Scope) -> [SpotlightModel.Row] {
        SpotlightModel.rows(scope: scope, query: "match", terminalTotal: 4, names: names, contents: contents, notes: notes)
    }

    func testAllShowsAFewOfEachAndTheNotesBeforeTheEnd() {
        let all = rows(.all)
        XCTAssertEqual(all.first, .terminal(total: 4))
        XCTAssertEqual(all.filter { if case .file = $0 { true } else { false } }.count, 5, "five of the files")
        XCTAssertTrue(all.contains(.more(.files, count: 28)), "and the rest behind Files")
        XCTAssertEqual(all.filter { if case .note = $0 { true } else { false } }.count, 3, "every note: there are three")
        XCTAssertFalse(all.contains { if case .more(.notes, _) = $0 { true } else { false } })
        XCTAssertLessThanOrEqual(all.count, 1 + 5 + 1 + 3, "no long scroll to the notes")
    }

    func testEachTabItsKindInFull() {
        XCTAssertEqual(rows(.files).count, 28)
        XCTAssertEqual(rows(.notes).count, 3)
        XCTAssertEqual(rows(.terminal), [.terminal(total: 4)])
        XCTAssertTrue(SpotlightModel.rows(scope: .all, query: "", terminalTotal: nil, names: [], contents: [], notes: []).isEmpty)
    }
}
