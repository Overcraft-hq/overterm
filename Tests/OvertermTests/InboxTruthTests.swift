import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// #31's Inbox patch: a wait counted from when it began (AGT-U7), a
/// finished entry let go of (AGT-U6).
@MainActor
final class InboxTruthTests: XCTestCase {
    func testTheWaitIsSaidInWholeUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(InboxModel.waited(since: now.addingTimeInterval(-20), now: now), "waiting <1 min")
        XCTAssertEqual(InboxModel.waited(since: now.addingTimeInterval(-4 * 60 - 30), now: now), "waiting 4 min")
        XCTAssertEqual(InboxModel.waited(since: now.addingTimeInterval(-(2 * 3600 + 5 * 60)), now: now), "waiting 2 h 5 min")
        XCTAssertEqual(InboxModel.waited(since: now.addingTimeInterval(-3 * 86400), now: now), "waiting 3 d")
        XCTAssertEqual(InboxModel.waited(since: now.addingTimeInterval(60), now: now), "waiting <1 min", "a clock that moved back says nothing odd")
    }

    func testSinceIsWhenTheTabBeganToWaitNotWhenTheListWasRead() throws {
        let tab = Tab(terminal: TerminalView())
        tab.activity.handle(.bell, visible: false)
        let began = try XCTUnwrap(tab.activity.waitingSince)
        let inbox = InboxModel()
        inbox.refresh(tabs: [tab], group: { _ in nil }, screen: { _ in nil }, now: began.addingTimeInterval(600))
        XCTAssertEqual(inbox.entries.first?.since, began)
    }

    func testOnlyAFinishedOrFailedEntryCanBeDismissed() {
        let waiting = Tab(terminal: TerminalView())
        waiting.customTitle = "agent"
        waiting.activity.handle(.bell, visible: false)
        let failed = Tab(terminal: TerminalView())
        failed.customTitle = "build"
        failed.activity.handle(.commandFinished(exitCode: 1, seconds: 30), visible: false)
        let done = Tab(terminal: TerminalView())
        done.customTitle = "tests"
        done.activity.handle(.commandFinished(exitCode: 0, seconds: 30), visible: false)
        let inbox = InboxModel()
        inbox.refresh(tabs: [waiting, failed, done], group: { _ in nil }, screen: { _ in nil })
        let dismissable = Dictionary(uniqueKeysWithValues: inbox.entries.map { ($0.title, InboxModel.dismissable($0)) })
        XCTAssertEqual(dismissable, ["agent": false, "build": true, "tests": true])
        XCTAssertNil(inbox.entries.first { $0.title == "build" }?.since, "only a waiting entry has a wait")
    }
}
