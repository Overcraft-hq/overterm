import XCTest

@testable import Overterm

final class BundleIdentifierTests: XCTestCase {
    /// The app's constant (defaults domain, logs, caches) and the bundle id
    /// make-app.sh writes into Info.plist must be the same id.
    func testTheAppAndItsInfoPlistAgree() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/make-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains(#"BUNDLE_ID="\#(AppEnvironment.bundleIdentifier)""#), "make-app.sh's BUNDLE_ID")
        XCTAssertFalse(AppEnvironment.formerBundleIdentifiers.contains(AppEnvironment.bundleIdentifier), "an id it has had")
    }

    func testFormerSettingsCarryOverWithoutOverwritingNewOnes() throws {
        let suite = "overterm-carry-over-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("new", forKey: "openWithApp")
        AppEnvironment.carryOver(
            ["openWithApp": "old", "sidebarPanel": "worktrees", "NSWindow Frame TerminusMainWindow": "0 0 800 600 0 0 1440 900 "],
            into: defaults)
        XCTAssertEqual(defaults.string(forKey: "openWithApp"), "new", "set under the new id: kept")
        XCTAssertEqual(defaults.string(forKey: "sidebarPanel"), "worktrees")
        // The window and the dividers were saved under the old name; the
        // key is renamed with the app, or the window opens where it never was.
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame OvertermMainWindow"), "0 0 800 600 0 0 1440 900 ")
        XCTAssertNil(defaults.string(forKey: "NSWindow Frame TerminusMainWindow"))
    }
}
