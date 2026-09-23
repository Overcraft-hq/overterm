import XCTest

@testable import Terminus

final class TabActivityTests: XCTestCase {
    func testBellInABackgroundTabMarksItWaitingOnce() {
        var activity = TabActivity()
        XCTAssertTrue(activity.handle(.bell, visible: false))
        XCTAssertEqual(activity.mark, .waiting)
        XCTAssertTrue(activity.needsAttention)
        XCTAssertFalse(activity.handle(.bell, visible: false), "already waiting: no second notification")
    }

    func testNothingIsMarkedWhileYouAreLooking() {
        var activity = TabActivity()
        XCTAssertFalse(activity.handle(.bell, visible: true))
        XCTAssertFalse(activity.handle(.notification(title: "Claude", body: "Waiting"), visible: true))
        XCTAssertEqual(activity.mark, .none)
    }

    func testWorkingIsTrackedEvenWhileVisible() {
        var activity = TabActivity()
        activity.handle(.progress(active: true, failed: false), visible: true)
        XCTAssertTrue(activity.isWorking, "the working animation shows on the tab you're looking at too")
        activity.handle(.progress(active: false, failed: false), visible: true)
        XCTAssertFalse(activity.isWorking)
        XCTAssertEqual(activity.mark, .none, "you saw it finish")
    }

    func testNotificationCarriesItsText() {
        var activity = TabActivity()
        activity.handle(.notification(title: "Claude Code", body: "needs your permission"), visible: false)
        XCTAssertEqual(activity.note, "Claude Code — needs your permission")
    }

    func testFinishingOutOfSightMarksDone() {
        var activity = TabActivity()
        activity.handle(.progress(active: true, failed: false), visible: false)
        XCTAssertEqual(activity.mark, .none, "starting work is not news")
        XCTAssertTrue(activity.handle(.progress(active: false, failed: false), visible: false))
        XCTAssertEqual(activity.mark, .done)
        XCTAssertFalse(activity.isWorking)
    }

    func testProgressRemovedWithoutWorkIsNotNews() {
        var activity = TabActivity()
        XCTAssertFalse(activity.handle(.progress(active: false, failed: false), visible: false))
    }

    func testFailures() {
        var activity = TabActivity()
        XCTAssertTrue(activity.handle(.progress(active: false, failed: true), visible: false))
        XCTAssertEqual(activity.mark, .failed)
        var command = TabActivity()
        XCTAssertFalse(command.handle(.commandFinished(exitCode: 0, seconds: 2), visible: false), "short commands are not news")
        XCTAssertTrue(command.handle(.commandFinished(exitCode: 1, seconds: 42), visible: false))
        XCTAssertEqual(command.mark, .failed)
        XCTAssertEqual(command.note, "Command failed (exit 1)")
        var ok = TabActivity()
        ok.handle(.commandFinished(exitCode: 0, seconds: 42), visible: false)
        XCTAssertEqual(ok.mark, .done)
    }

    func testMarksOnlyGoUpUntilSeen() {
        var activity = TabActivity()
        activity.handle(.notification(title: "Claude Code", body: "?"), visible: false)
        activity.handle(.progress(active: true, failed: false), visible: false)
        XCTAssertEqual(activity.mark, .none, "work resumed: the question was answered")
        activity.handle(.bell, visible: false)
        activity.handle(.progress(active: false, failed: false), visible: false)
        XCTAssertEqual(activity.mark, .waiting, "done doesn't hide that it wants you")
        activity.handle(.progress(active: false, failed: true), visible: false)
        XCTAssertEqual(activity.mark, .waiting, "nor does failed")
    }

    func testSeenClears() {
        var activity = TabActivity()
        activity.handle(.bell, visible: false)
        activity.seen()
        XCTAssertEqual(activity.mark, .none)
        XCTAssertNil(activity.note)
        XCTAssertTrue(activity.handle(.bell, visible: false), "can be marked again after being seen")
    }
}
