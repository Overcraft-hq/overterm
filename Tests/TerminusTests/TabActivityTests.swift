import XCTest

@testable import Terminus

final class TabActivityTests: XCTestCase {
    func testBellInABackgroundTabFlagsItOnce() {
        var activity = TabActivity()
        XCTAssertTrue(activity.handle(.bell, visible: false))
        XCTAssertTrue(activity.needsAttention)
        XCTAssertFalse(activity.handle(.bell, visible: false), "already flagged: no second notification")
    }

    func testNothingIsFlaggedWhileYouAreLooking() {
        var activity = TabActivity()
        XCTAssertFalse(activity.handle(.bell, visible: true))
        XCTAssertFalse(activity.handle(.notification(title: "Claude", body: "Waiting"), visible: true))
        XCTAssertFalse(activity.needsAttention)
    }

    func testNotificationCarriesItsText() {
        var activity = TabActivity()
        activity.handle(.notification(title: "Claude Code", body: "needs your permission"), visible: false)
        XCTAssertEqual(activity.note, "Claude Code — needs your permission")
    }

    func testWorkFinishingInTheBackgroundFlags() {
        var activity = TabActivity()
        activity.handle(.progress(active: true, failed: false), visible: false)
        XCTAssertTrue(activity.isWorking)
        XCTAssertFalse(activity.needsAttention, "starting work is not news")
        XCTAssertTrue(activity.handle(.progress(active: false, failed: false), visible: false))
        XCTAssertFalse(activity.isWorking)
    }

    func testProgressRemovedWithoutWorkIsNotNews() {
        var activity = TabActivity()
        XCTAssertFalse(activity.handle(.progress(active: false, failed: false), visible: false))
    }

    func testFailedProgressFlags() {
        var activity = TabActivity()
        XCTAssertTrue(activity.handle(.progress(active: false, failed: true), visible: false))
        XCTAssertEqual(activity.note, "Failed")
    }

    func testOnlyLongCommandsFlag() {
        var activity = TabActivity()
        XCTAssertFalse(activity.handle(.commandFinished(exitCode: 0, seconds: 2), visible: false))
        XCTAssertTrue(activity.handle(.commandFinished(exitCode: 1, seconds: 42), visible: false))
        XCTAssertEqual(activity.note, "Command failed (exit 1)")
    }

    func testSeenClears() {
        var activity = TabActivity()
        activity.handle(.bell, visible: false)
        activity.seen()
        XCTAssertFalse(activity.needsAttention)
        XCTAssertNil(activity.note)
        XCTAssertTrue(activity.handle(.bell, visible: false), "can be flagged again after being seen")
    }
}
