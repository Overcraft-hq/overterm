import UserNotifications
import XCTest

@testable import Overterm

final class AttentionNotifierTests: XCTestCase {
    /// UserNotifications answers the permission request on a queue of its
    /// own. The completion the notifier hands it must run there: written
    /// main-actor-isolated, it trapped and took the app down.
    func testTheAuthorizationCompletionRunsOffTheMainThread() {
        let request = UNNotificationRequest(identifier: "t", content: UNMutableNotificationContent(), trigger: nil)
        let added = expectation(description: "added once granted")
        let handler = AttentionNotifier.authorized(then: request) {
            added.fulfill(); XCTAssertEqual($0.identifier, "t")
        }
        DispatchQueue.global().async { handler(true, nil) }
        wait(for: [added], timeout: 2)
        // Refused: nothing is added.
        let refused = AttentionNotifier.authorized(then: request) { _ in XCTFail("added though refused") }
        let done = expectation(description: "refused ran")
        DispatchQueue.global().async {
            refused(false, nil)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
