import XCTest

@testable import Overterm

/// Onboarding 7.2: a fresh install, an update, or the same version again —
/// decided from what is on disk before anything is written.
final class FirstRunTests: XCTestCase {
    private func decide(
        _ last: String?, session: Bool = false, settings: Bool = false, checked: Date? = nil, current: String = "1.6.9"
    ) -> FirstRun.Launch {
        FirstRun.decide(lastRunVersion: last, hasSession: session, hasSettingsFile: settings, lastUpdateCheck: checked, current: current)
    }

    func testNothingOfOvertermsIsAFreshInstall() {
        XCTAssertEqual(decide(nil), .fresh)
        XCTAssertEqual(decide(""), .fresh, "an empty value is none")
    }

    /// 1.6.2 had none of the new keys, but an update check and, usually, a session.
    func testAnUpdateFromBeforeTheKeyIsAnUpdateFromNobodyKnowsWhat() {
        XCTAssertEqual(decide(nil, session: true), .upgraded(from: nil))
        XCTAssertEqual(decide(nil, checked: Date()), .upgraded(from: nil), "only the update check")
        XCTAssertEqual(decide(nil, settings: true), .upgraded(from: nil), "only settings.json")
    }

    func testTheSameVersionAgain() {
        XCTAssertEqual(decide("1.6.9", session: true, checked: Date()), .same)
        XCTAssertEqual(decide("1.6.9"), .same, "its own key is enough")
    }

    func testAnotherVersionIsAnUpdateFromIt() {
        XCTAssertEqual(decide("1.6.8", session: true), .upgraded(from: "1.6.8"))
        XCTAssertEqual(decide("1.7.0", current: "1.6.9"), .upgraded(from: "1.7.0"), "a downgrade is a change of version too")
    }

    func testAnUpdateIsNeverFresh() {
        for last in [nil, "1.6.2", "1.6.9"] as [String?] {
            for session in [false, true] {
                for checked in [nil, Date()] as [Date?] {
                    guard last != nil || session || checked != nil else { continue }
                    XCTAssertNotEqual(decide(last, session: session, checked: checked), .fresh, "\(last ?? "none") \(session) \(checked != nil)")
                }
            }
        }
    }

    /// The facts as they are read: files' existence and the two keys.
    func testReadAndRemember() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("firstrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "overterm.tests.firstrun.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = folder.appendingPathComponent("session.json")
        let settings = folder.appendingPathComponent("settings.json")
        func read() -> FirstRun.Launch { FirstRun.read(defaults: defaults, sessionURL: session, settingsURL: settings, current: "1.6.9") }

        XCTAssertEqual(read(), .fresh)
        defaults.set(Date(), forKey: FirstRun.lastUpdateCheckKey)
        XCTAssertEqual(read(), .upgraded(from: nil), "the update check's own key")
        defaults.removeObject(forKey: FirstRun.lastUpdateCheckKey)
        try Data("{}".utf8).write(to: session)
        XCTAssertEqual(read(), .upgraded(from: nil))
        FirstRun.remember("1.6.9", in: defaults)
        XCTAssertEqual(defaults.string(forKey: "onboarding.lastRunVersion"), "1.6.9")
        XCTAssertEqual(read(), .same)
        FirstRun.remember("1.6.8", in: defaults)
        XCTAssertEqual(read(), .upgraded(from: "1.6.8"))
    }

    func testTheUpdateCheckWritesTheKeyFirstRunReads() {
        XCTAssertEqual(FirstRun.lastUpdateCheckKey, "updates.lastCheck")
    }
}
