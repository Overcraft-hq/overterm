import UserNotifications
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

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

    /// Onboarding D-6: the lazy ask is held only on a fresh install's first
    /// launch, with tips on, T1 not seen and macOS not asked yet — then
    /// T1's button asks. Every other case asks as it always did.
    func testTheLazyAskIsHeldOnlyForT1OnAFreshFirstLaunch() {
        XCTAssertFalse(AttentionNotifier.asksLazily(state: .notAsked, tipsOn: true, t1Seen: false, firstLaunch: true))
        XCTAssertTrue(AttentionNotifier.asksLazily(state: .notAsked, tipsOn: false, t1Seen: false, firstLaunch: true), "tips off")
        XCTAssertTrue(AttentionNotifier.asksLazily(state: .notAsked, tipsOn: true, t1Seen: true, firstLaunch: true), "T1 seen")
        XCTAssertTrue(AttentionNotifier.asksLazily(state: .notAsked, tipsOn: true, t1Seen: false, firstLaunch: false), "the second launch on")
        for state in [NotificationPermission.allowed, .denied] {
            XCTAssertTrue(AttentionNotifier.asksLazily(state: state, tipsOn: true, t1Seen: false, firstLaunch: true), "already answered: \(state)")
        }
        XCTAssertEqual(NotificationPermission(.notDetermined), .notAsked)
        XCTAssertEqual(NotificationPermission(.denied), .denied)
        XCTAssertEqual(NotificationPermission(.authorized), .allowed)
        XCTAssertEqual(NotificationPermission(.provisional), .allowed)
    }

    /// A unit test is an isolated run: macOS is never asked, a request is counted.
    @MainActor
    func testAnIsolatedRunAsksMacOSNothing() async {
        AttentionNotifier.permissionOverride = nil
        let before = AttentionNotifier.requestedNow
        let state = await AttentionNotifier.authorizationState()
        XCTAssertEqual(state, .notAsked)
        AttentionNotifier.permissionOverride = .allowed
        let after = await AttentionNotifier.requestNow()
        XCTAssertEqual(after, .allowed)
        XCTAssertEqual(AttentionNotifier.requestedNow, before + 1)
        AttentionNotifier.permissionOverride = nil
    }
}
