import XCTest

@testable import Terminus

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
            #"{"tag_name":"v1.15.0","html_url":"https://github.com/Overcraft-hq/overterm/releases/tag/v1.15.0","assets":[{"name":"notes.txt"},{"name":"Terminus-1.15.0.dmg"}]}"#
                .utf8)
        let release = try UpdateChecker.parse(latest: data)
        XCTAssertEqual(release.version, "1.15.0")
        XCTAssertEqual(release.dmgName, "Terminus-1.15.0.dmg")
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
}
