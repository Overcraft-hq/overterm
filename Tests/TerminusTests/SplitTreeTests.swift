import CoreGraphics
import XCTest

@testable import Terminus

private final class Pane: CustomStringConvertible {
    let name: String
    init(_ name: String) { self.name = name }
    var description: String { name }
}

final class SplitTreeTests: XCTestCase {
    private typealias Tree = SplitTree<Pane>
    private let a = Pane("a"), b = Pane("b"), c = Pane("c")

    private func names(_ tree: Tree?) -> [String] { tree?.leaves.map(\.name) ?? [] }

    /// a | b, with c below b:  ┌───┬───┐
    ///                         │ a │ b │
    ///                         │   ├───┤
    ///                         │   │ c │
    ///                         └───┴───┘
    private var threePanes: Tree {
        Tree.leaf(a).inserting(b, at: a, .right).inserting(c, at: b, .down)
    }

    func testInsertingKeepsReadingOrder() {
        XCTAssertEqual(names(Tree.leaf(a).inserting(b, at: a, .right)), ["a", "b"])
        XCTAssertEqual(names(Tree.leaf(a).inserting(b, at: a, .left)), ["b", "a"])
        XCTAssertEqual(names(Tree.leaf(a).inserting(b, at: a, .up)), ["b", "a"])
        XCTAssertEqual(names(threePanes), ["a", "b", "c"])
    }

    func testRemovingCollapsesTheParent() {
        let tree = threePanes.removing(b)
        XCTAssertEqual(names(tree), ["a", "c"])
        guard case .split(let axis, _, _, _) = tree else { return XCTFail("still a split") }
        XCTAssertEqual(axis, .horizontal, "c takes b's place beside a")
        XCTAssertNil(Tree.leaf(a).removing(a), "the last pane leaves nothing")
    }

    func testLayoutSplitsTheSpace() {
        let (panes, dividers) = threePanes.layout(in: CGRect(x: 0, y: 0, width: 201, height: 101))
        let frames = Dictionary(uniqueKeysWithValues: panes.map { ($0.0.name, $0.1) })
        XCTAssertEqual(frames["a"], CGRect(x: 0, y: 0, width: 100, height: 101))
        XCTAssertEqual(frames["b"], CGRect(x: 101, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames["c"], CGRect(x: 101, y: 51, width: 100, height: 50))
        XCTAssertEqual(dividers.map(\.path), [[], [true]])
    }

    func testNeighboursBySide() {
        let tree = threePanes
        XCTAssertTrue(tree.neighbor(of: a, .right) === b, "b and c overlap a equally: the first in reading order")
        XCTAssertTrue(tree.neighbor(of: c, .left) === a)
        XCTAssertTrue(tree.neighbor(of: b, .down) === c)
        XCTAssertTrue(tree.neighbor(of: c, .up) === b)
        XCTAssertNil(tree.neighbor(of: a, .left))
        XCTAssertNil(tree.neighbor(of: b, .right))
    }

    func testPreviousAndNextWrap() {
        let tree = threePanes
        XCTAssertTrue(tree.neighbor(of: c, .next) === a)
        XCTAssertTrue(tree.neighbor(of: a, .previous) === c)
        XCTAssertNil(Tree.leaf(a).neighbor(of: a, .next), "nowhere to go with one pane")
    }

    func testEqualizeCountsPanesAlongTheAxis() {
        // a | (b | c): a gets a third, not a half.
        let tree = Tree.leaf(a).inserting(b, at: a, .right).inserting(c, at: b, .right).equalized()
        guard case .split(_, let ratio, _, _) = tree else { return XCTFail() }
        XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.001)
        // A stacked pair beside a counts once across: still halves.
        guard case .split(_, let across, _, _) = threePanes.equalized() else { return XCTFail() }
        XCTAssertEqual(across, 0.5, accuracy: 0.001)
    }

    func testResizeMovesTheNearestDividerOnThatAxis() {
        // From c, "up" moves the b/c divider (vertical axis), not a's.
        let tree = threePanes.resizing(c, toward: .up, by: 0.1)
        guard case .split(_, let outer, _, .split(_, let inner, _, _)) = tree else { return XCTFail() }
        XCTAssertEqual(outer, 0.5, accuracy: 0.001)
        XCTAssertEqual(inner, 0.4, accuracy: 0.001)
        // From c, "right" moves the a/(b,c) divider.
        guard case .split(_, let moved, _, _) = threePanes.resizing(c, toward: .right, by: 0.1) else { return XCTFail() }
        XCTAssertEqual(moved, 0.6, accuracy: 0.001)
        // Clamped: no pane disappears.
        guard case .split(_, let clamped, _, _) = threePanes.resizing(a, toward: .left, by: 5) else { return XCTFail() }
        XCTAssertEqual(clamped, 0.05, accuracy: 0.001)
    }

    func testSettingARatioByPath() {
        let tree = threePanes.settingRatio(0.3, at: [true])
        guard case .split(_, let outer, _, .split(_, let inner, _, _)) = tree else { return XCTFail() }
        XCTAssertEqual(outer, 0.5)
        XCTAssertEqual(inner, 0.3)
    }
}
