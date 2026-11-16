import XCTest

@testable import Overterm

/// A compose project's folder in its checkout's spelling: the checkout
/// scope compares paths as strings (6.5).
final class ActivityContainerFolderTests: XCTestCase {
    func testAProjectsFolderTakesItsCheckoutsSpelling() {
        let real: (String) -> String = { $0.hasPrefix("/var/") ? "/private" + $0 : $0 }
        let checkouts = ["/var/folders/fake/acme-shop", "/Users/fake/src/globex"]
        XCTAssertEqual(
            TerminalWindowController.activityFolder("/private/var/folders/fake/acme-shop", checkouts: checkouts, real: real),
            "/var/folders/fake/acme-shop", "the same folder by its real path")
        XCTAssertEqual(TerminalWindowController.activityFolder("/Users/fake/src/globex", checkouts: checkouts, real: real), "/Users/fake/src/globex")
        XCTAssertEqual(
            TerminalWindowController.activityFolder("/Users/fake/src/initech", checkouts: checkouts, real: real), "/Users/fake/src/initech",
            "no checkout's: as it is")
        var asked = 0
        _ = TerminalWindowController.activityFolder("/Users/fake/src/globex", checkouts: checkouts) {
            asked += 1; return $0
        }
        XCTAssertEqual(asked, 0, "a checkout's own spelling reads nothing")
    }
}
