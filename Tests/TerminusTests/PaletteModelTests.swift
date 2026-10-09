import XCTest

@testable import Terminus

final class PaletteModelTests: XCTestCase {
    @MainActor
    private func item(_ title: String, _ subtitle: String? = nil, group: PaletteItem.Group = .action) -> PaletteItem {
        PaletteItem(id: title, group: group, title: title, subtitle: subtitle, symbol: "circle", perform: { _, _ in })
    }

    @MainActor
    func testEmptyQueryKeepsTheGivenOrder() {
        let model = PaletteModel()
        model.reset(with: [item("New Tab"), item("Toggle Diff"), item("monorepo", group: .tab)])
        XCTAssertEqual(model.results.map(\.title), ["New Tab", "Toggle Diff", "monorepo"])
    }

    @MainActor
    func testRanksAndFilters() {
        let model = PaletteModel()
        model.reset(with: [item("Toggle Diff"), item("New Claude Tab"), item("Deploy a service", "deploy.sh release {{service}}", group: .snippet)])
        model.query = "ncl"
        XCTAssertEqual(model.results.map(\.title), ["New Claude Tab"])
        model.query = "release"
        XCTAssertEqual(model.results.map(\.title), ["Deploy a service"], "subtitles are searched too")
    }

    @MainActor
    func testTitleMatchesOutrankSubtitleMatches() {
        let model = PaletteModel()
        model.reset(with: [item("Worktrees", "diff things"), item("Toggle Diff")])
        model.query = "diff"
        XCTAssertEqual(model.results.first?.title, "Toggle Diff")
    }

    @MainActor
    func testMoveWrapsAndQueryResetsSelection() {
        let model = PaletteModel()
        model.reset(with: [item("a"), item("b"), item("c")])
        model.move(-1)
        XCTAssertEqual(model.selected?.title, "c")
        model.move(1)
        XCTAssertEqual(model.selected?.title, "a")
        model.move(1)
        model.query = "c"
        XCTAssertEqual(model.selectedIndex, 0)
    }
}
