import XCTest

@testable import Overterm

final class CommitGraphTests: XCTestCase {
    /// A commit is only its sha and its parents here — the rest of it says
    /// nothing about where the line goes.
    private func commit(_ sha: String, _ parents: String...) -> Commit {
        Commit(
            sha: sha, shortSHA: sha, parents: parents, author: "T", authorEmail: "t@t",
            date: Date(timeIntervalSince1970: 0), relative: "now", subject: sha, body: "", refs: [])
    }

    func testAStraightHistoryIsOneLane() {
        let rows = GraphLayout.rows(for: [commit("c", "b"), commit("b", "a"), commit("a")])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.width), [1, 1, 1])
        XCTAssertEqual(rows.map(\.through), [[], [], []])
        XCTAssertEqual(rows[0].incoming, [], "the newest commit has nothing above it")
        XCTAssertEqual(rows[0].outgoing, [0])
        XCTAssertEqual(rows[2].outgoing, [], "the root's lane ends")
    }

    /// A merge takes a second lane for its second parent, and gives it back
    /// where the two sides meet.
    func testAMergeOpensALaneAndTheBranchPointClosesIt() {
        //   m        merge of main (b) and the branch (f)
        //   |\
        //   b f
        //   |/
        //   a
        let rows = GraphLayout.rows(for: [commit("m", "b", "f"), commit("b", "a"), commit("f", "a"), commit("a")])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 1, 0])
        XCTAssertEqual(rows[0].outgoing, [0, 1], "both parents, each in its own lane")
        XCTAssertEqual(rows[1].through, [GraphEdge(from: 1, to: 1)], "the branch passes beside b")
        XCTAssertEqual(rows[2].incoming, [1])
        XCTAssertEqual(rows[2].outgoing, [1], "the branch keeps its own lane down to the branch point")
        XCTAssertEqual(rows[3].incoming, [0, 1], "both sides end at the branch point")
        XCTAssertEqual(rows.map(\.width), [2, 2, 2, 2])
    }

    /// Two tips that never meet until the root: a lane each, and the second
    /// lane is free again afterwards.
    func testALaneIsFreedAndReused() {
        //   x   y
        //   |   |
        //   a   |      (a is x's parent; y is a separate tip)
        //       b
        let rows = GraphLayout.rows(for: [commit("x", "a"), commit("y", "b"), commit("a"), commit("b")])
        XCTAssertEqual(rows.map(\.lane), [0, 1, 0, 1])
        XCTAssertEqual(rows[2].outgoing, [], "a is a root: lane 0 is free after it")
        // The next tip after a root takes the lane the root gave back.
        let reused = GraphLayout.rows(for: [commit("x"), commit("y")])
        XCTAssertEqual(reused.map(\.lane), [0, 0])
    }

    /// An octopus merge is three parents and three lanes out of one dot.
    func testAnOctopusMerge() {
        let rows = GraphLayout.rows(for: [commit("m", "a", "b", "c")])
        XCTAssertEqual(rows[0].outgoing, [0, 1, 2])
        XCTAssertEqual(rows[0].width, 3)
    }

    /// Two children of the same commit both point at it; it is one dot with
    /// two lines coming in.
    func testTwoChildrenOfOneCommitConverge() {
        let rows = GraphLayout.rows(for: [commit("x", "a"), commit("y", "a"), commit("a")])
        XCTAssertEqual(rows.map(\.lane), [0, 1, 0])
        XCTAssertEqual(rows[2].incoming, [0, 1])
    }

    /// Past the budget, lanes are drawn on top of the last one rather than
    /// widening the sidebar — the sidebar can be 180 pt.
    func testLanesAreCappedAtTheGuttersBudget() {
        let tips = (0..<10).map { commit("tip\($0)", "p\($0)") }
        let rows = GraphLayout.rows(for: tips, maxLanes: 3)
        XCTAssertEqual(rows.map(\.lane), [0, 1, 2, 2, 2, 2, 2, 2, 2, 2])
        XCTAssertEqual(GraphLayout.width(of: rows), 3)
        XCTAssertTrue(rows.allSatisfy { $0.through.allSatisfy { $0.from < 3 && $0.to < 3 } })
    }

    func testNoCommits() {
        XCTAssertEqual(GraphLayout.rows(for: []), [])
        XCTAssertEqual(GraphLayout.width(of: []), 1, "an empty gutter is still a gutter")
    }

    /// The gutter is one width for the whole list: a subject must not shift
    /// sideways as you scroll past a merge.
    func testTheWidthIsTheWidestRow() {
        let rows = GraphLayout.rows(for: [commit("c", "m"), commit("m", "b", "f"), commit("b", "a"), commit("f", "a"), commit("a")])
        XCTAssertEqual(GraphLayout.width(of: rows), 2)
    }
}
