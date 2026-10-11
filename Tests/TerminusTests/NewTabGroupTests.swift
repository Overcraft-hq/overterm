import XCTest

@testable import Terminus

/// The rule for which island a new tab joins. Pure, and the reason it
/// exists is a bug: inheriting the selected tab's island meant one group
/// over a checkout quietly swallowed every tab afterwards.
final class NewTabGroupTests: XCTestCase {
    private let island = UUID()
    private let other = UUID()

    private func placement(
        anchor: UUID? = nil, focused: UUID? = nil, bound: UUID? = nil, takesNewTabs: Bool? = nil,
        hasTabOutside: Bool = true
    ) -> NewTabGroup.Placement {
        NewTabGroup.placement(
            anchor: anchor, focused: focused, bound: bound, takesNewTabs: takesNewTabs, hasTabOutside: hasTabOutside)
    }

    func testATabFromALooseTabIsLoose() {
        XCTAssertEqual(placement(), .loose)
    }

    func testATabFromAGroupedTabIsStillLoose() {
        XCTAssertEqual(
            placement(anchor: island), .loose,
            "the selected tab being in an island is not a decision about the new one")
    }

    func testFocusAlwaysJoins() {
        // Focus shows one island and nothing else: a loose tab would open
        // out of sight.
        XCTAssertEqual(placement(anchor: island, focused: island), .join(island))
        XCTAssertEqual(placement(anchor: nil, focused: other, hasTabOutside: true), .join(other))
    }

    func testATickedFolderJoins() {
        XCTAssertEqual(placement(anchor: nil, bound: island), .join(island))
        XCTAssertEqual(placement(anchor: other, bound: island), .join(island))
    }

    func testAnIslandToldNotToTakeTabsOverridesItsOwnFolder() {
        XCTAssertEqual(placement(anchor: island, bound: island, takesNewTabs: false), .loose)
        XCTAssertEqual(
            placement(anchor: island, bound: other, takesNewTabs: false), .join(other),
            "the answer was about this island, not the one the folder is bound to")
    }

    func testAnAnsweredIslandIsNeverAskedAgain() {
        XCTAssertEqual(placement(anchor: island, takesNewTabs: true, hasTabOutside: false), .join(island))
        XCTAssertEqual(placement(anchor: island, takesNewTabs: false, hasTabOutside: false), .loose)
    }

    func testItAsksOnlyWhenTheIslandIsTheWholeStrip() {
        XCTAssertEqual(
            placement(anchor: island, hasTabOutside: false), .ask(island),
            "with no tab outside it, nothing in the strip says which the new tab is")
        XCTAssertEqual(placement(anchor: island, hasTabOutside: true), .loose)
    }

    func testItNeverAsksAboutNoIsland() {
        XCTAssertEqual(placement(anchor: nil, hasTabOutside: false), .loose)
    }
}
