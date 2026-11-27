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

final class UpdatesTests: XCTestCase {
    func testVersionsCompareAsNumbers() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.3"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("1.14.1", than: "1.14.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.14.0", than: "1.14.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    func testLatestReleaseParses() throws {
        let data = Data(
            #"{"tag_name":"v1.15.0","html_url":"https://github.com/Overcraft-hq/overterm/releases/tag/v1.15.0","assets":[{"name":"notes.txt"},{"name":"Overterm-1.15.0.dmg"}]}"#
                .utf8)
        let release = try UpdateChecker.parse(latest: data)
        XCTAssertEqual(release.version, "1.15.0")
        XCTAssertEqual(release.dmgName, "Overterm-1.15.0.dmg")
        XCTAssertEqual(release.url?.lastPathComponent, "v1.15.0")
    }

    func testAVersionsChangelogEntry() {
        let text = """
            # Changelog

            Preamble.

            ## 1.14.0 — 2026-09-26

            - settings: Keyboard Shortcuts
            - diff: something

            ## 1.13.0 — 2026-09-26

            - settings: Agents
            """
        XCTAssertEqual(Changelog.entry(for: "1.14.0", in: text), ["settings: Keyboard Shortcuts", "diff: something"])
        XCTAssertEqual(Changelog.entry(for: "1.13.0", in: text), ["settings: Agents"])
        XCTAssertEqual(Changelog.entry(for: "9.9.9", in: text), [])
    }

    // MARK: What's new (SET-G2)

    func testWhatsNewOnlyAfterAnOlderVersion() {
        XCTAssertNil(UpdateChecker.whatsNew(lastRun: nil, current: "1.6.8"), "the first run ever says nothing")
        XCTAssertNil(UpdateChecker.whatsNew(lastRun: "1.6.8", current: "1.6.8"))
        XCTAssertNil(UpdateChecker.whatsNew(lastRun: "1.7.0", current: "1.6.8"), "an older one run after a newer")
        XCTAssertEqual(UpdateChecker.whatsNew(lastRun: "1.6.7", current: "1.6.8"), "1.6.8")
        XCTAssertEqual(UpdateChecker.whatsNew(lastRun: "1.9.0", current: "1.10.0"), "1.10.0")
    }

    @MainActor
    func testLaunchRemembersTheVersionAndTheChipUntilPutAway() throws {
        let suite = "overterm.tests.whatsNew.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker()
        let current = checker.currentVersion

        checker.noteLaunch(defaults: defaults)
        XCTAssertNil(checker.whatsNew, "nothing stored: nothing shown")
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.lastRunKey), current, "and this version remembered")

        try XCTSkipUnless(UpdateChecker.isNewer(current, than: "0.0.1"), "the test bundle's version \(current) is not past 0.0.1")
        defaults.set("0.0.1", forKey: UpdateChecker.lastRunKey)
        checker.noteLaunch(defaults: defaults)
        XCTAssertEqual(checker.whatsNew, current)
        checker.noteLaunch(defaults: defaults)
        XCTAssertEqual(checker.whatsNew, current, "not seen yet: offered at the next launch too")
        checker.dismissWhatsNew(defaults: defaults)
        XCTAssertNil(checker.whatsNew)
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.lastRunKey), current)
        checker.noteLaunch(defaults: defaults)
        XCTAssertNil(checker.whatsNew, "put away for good")
    }
}
