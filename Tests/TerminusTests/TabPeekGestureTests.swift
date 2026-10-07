import CoreGraphics
import XCTest

@testable import Terminus

final class TabPeekGestureTests: XCTestCase {
    /// Fingers on the trackpad: normalized y, 1 at the top. Swiping down
    /// lowers it.
    private func swipe(_ gesture: inout TabPeekGesture, from: CGFloat, to: CGFloat, fingers: Int = 3, required: Int = 3) -> TabPeekGesture.Outcome {
        var last = gesture.touched(count: fingers, y: from, required: required)
        for step in stride(from: 0.0, through: 1.0, by: 0.2) {
            let y = from + (to - from) * CGFloat(step)
            last = gesture.touched(count: fingers, y: y, required: required)
        }
        return last
    }

    func testTwoFingersNeverStart() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.8, to: 0.2, fingers: 2)
        XCTAssertFalse(gesture.isTracking)
        XCTAssertEqual(gesture.progress, 0)
        XCTAssertEqual(gesture.ended(), .none)
    }

    func testOffTakesNothing() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.8, to: 0.2, required: 0)
        XCTAssertEqual(gesture.progress, 0)
    }

    func testARestingHandIsNotASwipe() {
        var gesture = TabPeekGesture()
        _ = gesture.touched(count: 3, y: 0.5, required: 3)
        XCTAssertEqual(gesture.touched(count: 3, y: 0.4995, required: 3), .none)
        XCTAssertFalse(gesture.isTracking)
    }

    func testThreeFingersDownOpenTheStrip() {
        var gesture = TabPeekGesture()
        let outcome = swipe(&gesture, from: 0.8, to: 0.8 - TabPeekGesture.travel)
        XCTAssertTrue(gesture.isTracking)
        XCTAssertEqual(outcome, .update(1))
        XCTAssertEqual(gesture.ended(), .settle(.peek))
        XCTAssertEqual(gesture.progress, 1)
    }

    func testCarryingOnOpensTheGrid() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.9, to: 0.9 - TabPeekGesture.travel * 2)
        XCTAssertEqual(gesture.progress, 2, accuracy: 0.001)
        XCTAssertEqual(gesture.ended(), .settle(.overview))
    }

    func testASecondSwipeCarriesOnFromWhereItIs() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.9, to: 0.9 - TabPeekGesture.travel)
        _ = gesture.ended()
        _ = swipe(&gesture, from: 0.9, to: 0.9 - TabPeekGesture.travel)
        XCTAssertEqual(gesture.progress, 2, accuracy: 0.001, "it must not snap back to the strip")
    }

    func testSwipingBackUpCloses() {
        var gesture = TabPeekGesture()
        gesture.settled(at: .peek)
        _ = swipe(&gesture, from: 0.3, to: 0.3 + TabPeekGesture.travel)
        XCTAssertEqual(gesture.progress, 0, accuracy: 0.001)
        XCTAssertEqual(gesture.ended(), .settle(.closed))
    }

    func testHalfASwipeSettlesBackClosed() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.8, to: 0.8 - TabPeekGesture.travel * 0.3)
        XCTAssertEqual(gesture.ended(), .settle(.closed))
    }

    func testMostOfASwipeSettlesOpen() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.8, to: 0.8 - TabPeekGesture.travel * 0.7)
        XCTAssertEqual(gesture.ended(), .settle(.peek))
    }

    func testAFingerLiftedEndsTheSwipe() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.8, to: 0.8 - TabPeekGesture.travel)
        XCTAssertEqual(gesture.touched(count: 2, y: 0.5, required: 3), .settle(.peek))
        XCTAssertFalse(gesture.isTracking)
    }

    func testTheProgressNeverLeavesTheTwoStages() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.95, to: 0.95 - TabPeekGesture.travel * 9)
        XCTAssertEqual(gesture.progress, 2)
        gesture.settled(at: .closed)
        _ = swipe(&gesture, from: 0.1, to: 0.1 + TabPeekGesture.travel * 9)
        XCTAssertEqual(gesture.progress, 0)
    }

    func testTheKeyboardAndTheFingersStayInStep() {
        var gesture = TabPeekGesture()
        gesture.settled(at: .overview)
        XCTAssertEqual(gesture.progress, 2)
        _ = swipe(&gesture, from: 0.6, to: 0.6 - TabPeekGesture.travel)
        XCTAssertEqual(gesture.progress, 1, accuracy: 0.001, "a fresh swipe down steps back out of the grid")
    }

    /// macOS takes three (and four) fingers up for Mission Control before
    /// any app sees a touch, so the way back out is down too: a fresh swipe
    /// that starts at the grid runs the other way.
    func testAFreshSwipeDownAtTheGridClosesIt() {
        var gesture = TabPeekGesture()
        gesture.settled(at: .overview)
        _ = swipe(&gesture, from: 0.9, to: 0.9 - TabPeekGesture.travel * 2)
        XCTAssertEqual(gesture.progress, 0, accuracy: 0.001)
        XCTAssertEqual(gesture.ended(), .settle(.closed))
    }

    func testOneSwipeStillGoesAllTheWayIn() {
        var gesture = TabPeekGesture()
        // One unbroken gesture: strip, then grid. Only a *new* one reverses.
        _ = swipe(&gesture, from: 0.95, to: 0.95 - TabPeekGesture.travel * 2)
        XCTAssertEqual(gesture.progress, 2, accuracy: 0.001)
    }

    func testAtTheStripDownStillGoesDeeper() {
        var gesture = TabPeekGesture()
        gesture.settled(at: .peek)
        _ = swipe(&gesture, from: 0.9, to: 0.9 - TabPeekGesture.travel)
        XCTAssertEqual(gesture.progress, 2, accuracy: 0.001)
    }

    func testFourFingerMode() {
        var gesture = TabPeekGesture()
        _ = swipe(&gesture, from: 0.8, to: 0.8 - TabPeekGesture.travel, fingers: 3, required: 4)
        XCTAssertEqual(gesture.progress, 0)
        _ = swipe(&gesture, from: 0.8, to: 0.8 - TabPeekGesture.travel, fingers: 4, required: 4)
        XCTAssertEqual(gesture.progress, 1, accuracy: 0.001)
    }

    func testFingersSettings() {
        XCTAssertEqual(TabPeekGesture.Fingers.off.count, 0)
        XCTAssertEqual(TabPeekGesture.Fingers.three.count, 3)
        XCTAssertEqual(TabPeekGesture.Fingers.four.count, 4)
    }
}
