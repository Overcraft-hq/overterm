import XCTest

@testable import Overterm

/// Where a tab dragged over a pane lands. Five targets in one rectangle
/// with no modifier to remember, which only works if the thresholds are
/// where your hand expects them.
final class DropZoneTests: XCTestCase {
    private let pane = CGRect(x: 100, y: 50, width: 400, height: 200)

    private func zone(_ x: CGFloat, _ y: CGFloat) -> DropZone? {
        DropZone.at(CGPoint(x: pane.minX + pane.width * x, y: pane.minY + pane.height * y), in: pane)
    }

    func testTheMiddleIsTheEasyTarget() {
        XCTAssertEqual(zone(0.5, 0.5), .into)
    }

    func testEachEdgeSplitsItsWay() {
        XCTAssertEqual(zone(0.5, 0.05), .up)
        XCTAssertEqual(zone(0.5, 0.95), .down)
        XCTAssertEqual(zone(0.05, 0.5), .left)
        XCTAssertEqual(zone(0.95, 0.5), .right)
    }

    /// A pane is wider than it is tall, so the bands you cross by accident
    /// are the horizontal ones — they take the corners.
    func testTopAndBottomTakeTheCorners() {
        XCTAssertEqual(zone(0.02, 0.02), .up)
        XCTAssertEqual(zone(0.98, 0.98), .down)
    }

    func testOutsideThePaneIsNowhere() {
        XCTAssertNil(DropZone.at(CGPoint(x: 0, y: 0), in: pane))
        XCTAssertNil(DropZone.at(CGPoint(x: 600, y: 100), in: pane))
        XCTAssertNil(DropZone.at(CGPoint(x: 200, y: 100), in: .zero))
    }

    /// Every zone is inside the pane, and together they cover it with no
    /// gap you could drop into and hit nothing.
    func testTheZonesTileThePane() {
        var area: CGFloat = 0
        for zone in DropZone.allCases {
            let frame = zone.frame(in: pane)
            XCTAssertTrue(pane.contains(frame), "\(zone) at \(frame)")
            area += frame.width * frame.height
        }
        XCTAssertEqual(area, pane.width * pane.height, accuracy: 0.5)
    }

    /// Each drawn zone contains the point that chooses it.
    func testADrawnZoneAnswersForItsOwnMiddle() {
        for zone in DropZone.allCases {
            let middle = CGPoint(x: zone.frame(in: pane).midX, y: zone.frame(in: pane).midY)
            XCTAssertEqual(DropZone.at(middle, in: pane), zone)
        }
    }

    /// The middle is not a fifth way to split — it is the forgiving
    /// version of the one you mean most often.
    func testTheMiddleSplitsRight() {
        XCTAssertEqual(DropZone.into.direction, .right)
        XCTAssertEqual(DropZone.right.direction, .right)
        XCTAssertEqual(DropZone.up.direction, .up)
    }
}
