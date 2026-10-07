import CoreGraphics
import QuartzCore
import XCTest

@testable import Terminus

final class TabPeekTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let ids = (0..<4).map { _ in UUID() }

    private func cards(_ progress: Double, tabs: [UUID]? = nil, selected: UUID? = nil) -> [TabPeek.Card] {
        let tabs = tabs ?? ids
        return TabPeek.placements(tabs: tabs, selected: selected ?? tabs[0], progress: progress, in: bounds)
    }

    private func card(_ id: UUID, _ cards: [TabPeek.Card]) -> TabPeek.Card {
        cards.first { $0.id == id }!
    }

    // MARK: Closed

    func testClosedPlacesNothing() {
        XCTAssertTrue(cards(0).isEmpty)
        XCTAssertTrue(TabPeek.placements(tabs: [], selected: nil, progress: 2, in: bounds).isEmpty)
        XCTAssertTrue(TabPeek.placements(tabs: ids, selected: ids[0], progress: 2, in: .zero).isEmpty)
    }

    // MARK: The strip

    func testTheSelectedTerminalIsPushedDownWholeAndUnscaled() {
        let selected = card(ids[0], cards(1))
        XCTAssertEqual(selected.content.size, bounds.size, "the terminal must never be resized")
        XCTAssertEqual(selected.content.minY, (bounds.height * TabPeek.pushFraction).rounded())
        XCTAssertFalse(selected.hasHeader, "the pushed-down terminal is not a card")
    }

    func testThePushGrowsWithTheGesture() {
        let quarter = card(ids[0], cards(0.25)).content.minY
        let half = card(ids[0], cards(0.5)).content.minY
        XCTAssertGreaterThan(half, quarter)
        XCTAssertEqual(quarter, 0, accuracy: 0.001 + (bounds.height * TabPeek.pushFraction) / 4)
    }

    func testTheOthersSlideInFromAboveAsOneRow() {
        let closed = cards(0.001).filter { !$0.isSelected }
        XCTAssertTrue(closed.allSatisfy { $0.frame.maxY <= 1 }, "they start above the top edge")

        let open = cards(1).filter { !$0.isSelected }
        XCTAssertEqual(open.count, ids.count - 1)
        XCTAssertTrue(open.allSatisfy { $0.frame.minY == TabPeek.margin }, "one row, all at the same height")
        XCTAssertEqual(Set(open.map(\.frame.height)).count, 1, "all the same size")

        for (left, right) in zip(open, open.dropFirst()) {
            XCTAssertEqual(right.frame.minX - left.frame.maxX, TabPeek.gap, accuracy: 0.001)
        }
    }

    func testStripCardsKeepTheTerminalShape() {
        let one = cards(1).first { !$0.isSelected }!
        XCTAssertEqual(
            one.content.width / one.content.height, bounds.width / bounds.height, accuracy: 0.02,
            "a preview that doesn't keep its shape is not a preview of that terminal")
        XCTAssertTrue(one.hasHeader)
        XCTAssertEqual(one.frame.height - one.content.height, TabPeek.headerHeight)
    }

    // MARK: The grid

    func testTheGridHoldsEveryTabSelectedIncluded() {
        let grid = cards(2)
        XCTAssertEqual(grid.map(\.id), ids, "order follows the tab strip")
        XCTAssertEqual(grid.filter(\.isSelected).count, 1)
        XCTAssertTrue(grid.allSatisfy { $0.hasHeader }, "in the grid every tab is a card")
    }

    func testGridCardsDoNotOverlapAndStayInside() {
        for count in 1...9 {
            let tabs = (0..<count).map { _ in UUID() }
            let grid = TabPeek.placements(tabs: tabs, selected: tabs[0], progress: 2, in: bounds)
            XCTAssertEqual(grid.count, count)
            for c in grid {
                XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(c.frame), "\(count) tabs: \(c.frame) left \(bounds)")
            }
            for (i, a) in grid.enumerated() {
                for b in grid[(i + 1)...] {
                    XCTAssertFalse(a.frame.insetBy(dx: 1, dy: 1).intersects(b.frame.insetBy(dx: 1, dy: 1)), "\(count) tabs overlap")
                }
            }
        }
    }

    func testGridCardsAllShareOneSize() {
        let grid = cards(2)
        XCTAssertEqual(Set(grid.map(\.frame.width)).count, 1)
        XCTAssertEqual(Set(grid.map(\.frame.height)).count, 1)
    }

    func testTheGridPicksTheColumnsThatMakeTheCardsBiggest() {
        let area = CGSize(width: 1000, height: 700)
        let shape = CGSize(width: 1000, height: 700)
        XCTAssertEqual(TabPeek.grid(count: 1, in: area, shape: shape).columns, 1)
        XCTAssertEqual(TabPeek.grid(count: 4, in: area, shape: shape).columns, 2)
        // Whatever it picks, nothing else fits bigger.
        for count in 1...12 {
            let (columns, scale) = TabPeek.grid(count: count, in: area, shape: shape)
            for other in 1...count {
                let rows = Int((Double(count) / Double(other)).rounded(.up))
                let w = (area.width - TabPeek.gap * CGFloat(other - 1)) / CGFloat(other)
                let h = (area.height - TabPeek.gap * CGFloat(rows - 1)) / CGFloat(rows) - TabPeek.headerHeight
                guard w > 0, h > 0 else { continue }
                XCTAssertLessThanOrEqual(min(w / shape.width, h / shape.height), scale + 0.0001, "\(count) tabs: \(other) columns beat \(columns)")
            }
        }
    }

    // MARK: The two stages meet

    func testTheStagesMeetWithoutAJump() {
        let before = cards(0.999)
        let after = cards(1.001)
        for a in before {
            let b = card(a.id, after)
            XCTAssertEqual(a.frame.minX, b.frame.minX, accuracy: 4, "x jumps at the stage boundary")
            XCTAssertEqual(a.frame.minY, b.frame.minY, accuracy: 4, "y jumps at the stage boundary")
            XCTAssertEqual(a.frame.width, b.frame.width, accuracy: 4, "width jumps at the stage boundary")
            XCTAssertEqual(a.frame.height, b.frame.height, accuracy: 4, "height jumps at the stage boundary")
        }
    }

    func testPastTheGridNothingMoves() {
        XCTAssertEqual(cards(2), cards(5), "progress is clamped")
    }

    // MARK: The transform

    func testTheTransformLandsTheHostOnItsCard() {
        let target = CGRect(x: 120, y: 60, width: 300, height: 200)
        let t = TabPeek.transform(from: bounds, to: target)
        let topLeft = TabPeek.place(CGPoint(x: bounds.minX, y: bounds.minY), from: bounds, by: t)
        let bottomRight = TabPeek.place(CGPoint(x: bounds.maxX, y: bounds.maxY), from: bounds, by: t)
        XCTAssertEqual(topLeft.x, target.minX, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, target.minY, accuracy: 0.001)
        XCTAssertEqual(bottomRight.x, target.maxX, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, target.maxY, accuracy: 0.001)
    }

    /// The host's layer is flipped, its superlayer is not: a transform that
    /// forgets it mirrors every preview about the middle of the window.
    func testTheTransformMirrorsYForTheFlippedHost() {
        let top = CGRect(x: 0, y: 0, width: 300, height: 200)
        let t = TabPeek.transform(from: bounds, to: top)
        XCTAssertEqual(t.m42, bounds.height - top.maxY, accuracy: 0.001)
        XCTAssertEqual(TabPeek.place(.zero, from: bounds, by: t).y, 0, accuracy: 0.001, "a card at the top stays at the top")
    }

    func testTheTransformIsIdentityForTheWholeArea() {
        let t = TabPeek.transform(from: bounds, to: bounds)
        XCTAssertTrue(CATransform3DIsIdentity(t))
    }

    // MARK: Moving the highlight

    /// A 2 × 2 grid: 0 1
    ///               2 3
    func testArrowKeysMoveThroughTheGrid() {
        let grid = cards(2)
        XCTAssertEqual(TabPeek.move(.right, from: ids[0], in: grid), ids[1])
        XCTAssertEqual(TabPeek.move(.down, from: ids[0], in: grid), ids[2])
        XCTAssertEqual(TabPeek.move(.left, from: ids[3], in: grid), ids[2])
        XCTAssertEqual(TabPeek.move(.up, from: ids[3], in: grid), ids[1])
    }

    func testAnArrowAtTheEdgeStaysPut() {
        let grid = cards(2)
        XCTAssertEqual(TabPeek.move(.left, from: ids[0], in: grid), ids[0])
        XCTAssertEqual(TabPeek.move(.up, from: ids[0], in: grid), ids[0])
        XCTAssertEqual(TabPeek.move(.right, from: ids[3], in: grid), ids[3])
        XCTAssertEqual(TabPeek.move(.down, from: ids[3], in: grid), ids[3])
    }

    func testOneTabHasNowhereToGo() {
        let one = [UUID()]
        let grid = TabPeek.placements(tabs: one, selected: one[0], progress: 2, in: bounds)
        XCTAssertEqual(TabPeek.move(.right, from: one[0], in: grid), one[0])
        XCTAssertEqual(TabPeek.step(1, from: one[0], in: grid), one[0])
    }

    func testTabStepsThroughAndWraps() {
        let grid = cards(2)
        XCTAssertEqual(TabPeek.step(1, from: ids[0], in: grid), ids[1])
        XCTAssertEqual(TabPeek.step(1, from: ids[3], in: grid), ids[0])
        XCTAssertEqual(TabPeek.step(-1, from: ids[0], in: grid), ids[3])
    }

    func testMovingFromATabThatIsGoneFallsBackToTheFirst() {
        XCTAssertEqual(TabPeek.move(.right, from: UUID(), in: cards(2)), ids[0])
    }
}
