import XCTest

@testable import Overterm

/// Overgit ▸ Branches ▸ Filter branches.
final class BranchSearchTests: XCTestCase {
    private func branch(_ name: String, remote: Bool = false) -> BranchRef {
        BranchRef(name: name, isRemote: remote, sha: "abc", upstream: nil, ahead: 0, behind: 0, isGone: false, date: Date(), subject: "")
    }

    func testEveryWordInAnyOrderAndCase() {
        let all = [branch("main"), branch("fix/payments"), branch("feature/PAY-12-refunds"), branch("origin/fix/payments", remote: true)]
        XCTAssertEqual(BranchTree.matching(all, query: "pay fix").map(\.name), ["fix/payments", "origin/fix/payments"])
        XCTAssertEqual(BranchTree.matching(all, query: "pay").count, 3)
        XCTAssertEqual(BranchTree.matching(all, query: "  ").count, 4, "empty: all")
        XCTAssertTrue(BranchTree.matching(all, query: "nothing").isEmpty)
    }

    func testTheFoldersOfTheMatchesOpen() {
        let found = [branch("fix/payments"), branch("origin/team/fix/x", remote: true)]
        XCTAssertEqual(BranchTree.folders(of: found), ["fix", "origin", "origin/team", "origin/team/fix"])
        let rows = BranchTree.rows(found, expanded: BranchTree.folders(of: found))
        XCTAssertEqual(rows.compactMap(\.branch?.name), ["fix/payments", "origin/team/fix/x"], "both shown, under their folders")
    }
}
