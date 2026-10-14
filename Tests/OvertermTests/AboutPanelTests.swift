import XCTest

@testable import Overterm

/// About Overterm: the standard panel shows "Version 1.10.0 (103)" itself;
/// the credits under it say which commit the app was built from, and when.
final class AboutPanelTests: XCTestCase {
    func testTheCreditsNameTheCommitAndTheDay() {
        XCTAssertEqual(AboutPanel.credits(commit: "7e68283", date: "2026-09-26"), "commit 7e68283 · 26 Sep 2026")
    }

    func testABuildWithUncommittedChangesSaysSo() {
        XCTAssertEqual(AboutPanel.credits(commit: "7e68283-dirty", date: "2026-09-26"), "commit 7e68283-dirty · 26 Sep 2026")
    }

    /// English like the rest of the app, whatever the Mac's language: no
    /// "26 Eyl 2026" in a Turkish locale, no leading zero.
    func testTheDayReadsTheSameEverywhere() {
        XCTAssertEqual(AboutPanel.credits(commit: "abc1234", date: "2027-01-05"), "commit abc1234 · 5 Jan 2027")
        XCTAssertEqual(AboutPanel.credits(commit: "abc1234", date: "2026-12-31"), "commit abc1234 · 31 Dec 2026")
    }

    /// Built without git (make-app.sh writes "unknown"), or a bundle missing
    /// a key: what there is, and no credits at all when there is nothing.
    func testWhatIsMissingIsLeftOut() {
        XCTAssertEqual(AboutPanel.credits(commit: "unknown", date: "2026-09-26"), "commit unknown · 26 Sep 2026")
        XCTAssertEqual(AboutPanel.credits(commit: "7e68283", date: nil), "commit 7e68283")
        XCTAssertEqual(AboutPanel.credits(commit: nil, date: "2026-09-26"), "26 Sep 2026")
        XCTAssertEqual(AboutPanel.credits(commit: "7e68283", date: "tomorrow"), "commit 7e68283 · tomorrow", "not a day: as written")
        XCTAssertNil(AboutPanel.credits(commit: nil, date: nil))
        XCTAssertNil(AboutPanel.credits(commit: " ", date: ""))
    }
}
