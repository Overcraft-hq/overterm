import XCTest

@testable import Terminus

final class BundleIdentifierTests: XCTestCase {
    /// The app's constant (defaults domain, logs, caches) and the bundle id
    /// make-app.sh writes into Info.plist must be the same id.
    func testTheAppAndItsInfoPlistAgree() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/make-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains(#"BUNDLE_ID="\#(AppEnvironment.bundleIdentifier)""#), "make-app.sh's BUNDLE_ID")
        XCTAssertNotEqual(AppEnvironment.bundleIdentifier, AppEnvironment.formerBundleIdentifier)
    }

    func testFormerSettingsCarryOverWithoutOverwritingNewOnes() throws {
        let suite = "terminus-carry-over-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("new", forKey: "openWithApp")
        AppEnvironment.carryOver(
            ["openWithApp": "old", "sidebarPanel": "worktrees", "NSWindow Frame TerminusMainWindow": "0 0 800 600 0 0 1440 900 "],
            into: defaults)
        XCTAssertEqual(defaults.string(forKey: "openWithApp"), "new", "set under the new id: kept")
        XCTAssertEqual(defaults.string(forKey: "sidebarPanel"), "worktrees")
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame TerminusMainWindow"), "0 0 800 600 0 0 1440 900 ")
    }
}
