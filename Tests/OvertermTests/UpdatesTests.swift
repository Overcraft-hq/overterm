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

    // MARK: What's new (SET-G2, onboarding 7.9)

    private let changelog = """
        # Changelog

        ## 1.6.9 — 2026-11-28

        - this one
        - and more

        ## 1.6.8 — 2026-11-26

        - skipped

        ## 1.6.7 — 2026-11-20

        ## 1.6.6 — 2026-11-18

        - skipped too

        ## 1.6.5 — 2026-11-10

        - ran before
        """

    func testEntriesAfterTheLastRunThroughThisOne() {
        let since = Changelog.entries(after: "1.6.5", through: "1.6.9", in: changelog)
        XCTAssertEqual(since.map(\.version), ["1.6.9", "1.6.8", "1.6.6"], "newest first; one with no lines left out")
        XCTAssertEqual(since.first?.lines, ["this one", "and more"])
        XCTAssertEqual(Changelog.entries(after: "1.6.8", through: "1.6.9", in: changelog).map(\.version), ["1.6.9"])
        XCTAssertEqual(Changelog.entries(after: "1.6.6", through: "1.6.8", in: changelog).map(\.version), ["1.6.8"], "nothing past this one")
    }

    func testEntriesAfterAVersionTheFileDoesntName() {
        XCTAssertEqual(Changelog.entries(after: "1.6.4", through: "1.6.9", in: changelog).map(\.version), ["1.6.9", "1.6.8", "1.6.6", "1.6.5"])
        XCTAssertEqual(Changelog.entries(after: "1.0.0", through: "1.6.9", in: changelog).count, 4)
        XCTAssertEqual(Changelog.entries(after: nil, through: "1.6.9", in: changelog).map(\.version), ["1.6.9"], "none remembered: this one's alone")
    }

    func testNoEntries() {
        XCTAssertEqual(Changelog.entries(after: "1.6.9", through: "1.6.9", in: changelog), [], "the same version")
        XCTAssertEqual(Changelog.entries(after: "1.7.0", through: "1.6.9", in: changelog), [], "an older one run after a newer")
        XCTAssertEqual(Changelog.entries(after: "1.6.5", through: "1.6.9", in: "# Changelog\n"), [])
        XCTAssertEqual(Changelog.entries(after: nil, through: "2.0.0", in: changelog), [], "this version not in the file")
    }

    func testTheChipOnlyAfterAnUpdateWithSomethingToSay() {
        func chip(_ launch: FirstRun.Launch, seen: String? = nil, text: String? = nil, enabled: Bool = true) -> String? {
            UpdateChecker.whatsNew(launch: launch, seen: seen, changelog: text ?? changelog, current: "1.6.9", enabled: enabled)
        }
        XCTAssertEqual(chip(.upgraded(from: "1.6.5")), "1.6.9")
        XCTAssertEqual(chip(.upgraded(from: "1.6.8")), "1.6.9", "after a patch version too (D-15)")
        XCTAssertEqual(chip(.upgraded(from: nil)), "1.6.9", "an update from before the key")
        XCTAssertNil(chip(.fresh), "a new install says nothing")
        XCTAssertNil(chip(.same))
        XCTAssertNil(chip(.upgraded(from: "1.7.0")), "an older one run after a newer")
        XCTAssertNil(chip(.upgraded(from: "1.6.5"), enabled: false), "updates.whatsNew off")
        XCTAssertNil(chip(.upgraded(from: "1.6.5"), seen: "1.6.9"), "opened or put away once")
        XCTAssertEqual(chip(.upgraded(from: "1.6.5"), seen: "1.6.8"), "1.6.9", "an older version's seen says nothing of this one")
        XCTAssertNil(chip(.upgraded(from: "1.6.8"), text: "# Changelog\n"), "no lines since the last run")
        XCTAssertNil(UpdateChecker.whatsNew(launch: .upgraded(from: "1.6.5"), seen: nil, changelog: nil, current: "1.6.9", enabled: true), "no changelog")
    }

    @MainActor
    func testTheChipUntilPutAwayAndAboutsVersions() throws {
        let suite = "overterm.tests.whatsNew.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker()
        let current = checker.currentVersion
        try XCTSkipUnless(UpdateChecker.isNewer(current, than: "1.6.2"), "the test bundle's version \(current) is not past 1.6.2")
        let text = "## \(current) — today\n\n- this one\n\n## 1.6.2 — then\n\n- skipped\n\n## 1.6.1 — before\n\n- ran before\n"

        checker.noteLaunch(.fresh, changelog: text, enabled: true, defaults: defaults)
        XCTAssertNil(checker.whatsNew, "a fresh install: nothing")
        XCTAssertEqual(checker.changes.map(\.version), [current], "About: this version's alone")
        checker.noteLaunch(.upgraded(from: "1.6.1"), changelog: text, enabled: true, defaults: defaults)
        XCTAssertEqual(checker.whatsNew, current)
        XCTAssertEqual(checker.changes.map(\.version), [current, "1.6.2"], "About: the versions skipped too")
        XCTAssertNil(defaults.string(forKey: UpdateChecker.whatsNewSeenKey), "nothing written until it is opened or put away")
        checker.dismissWhatsNew(defaults: defaults)
        XCTAssertNil(checker.whatsNew)
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.whatsNewSeenKey), current)
        XCTAssertEqual(checker.changes.map(\.version), [current, "1.6.2"], "About still lists them")
        checker.noteLaunch(.upgraded(from: "1.6.1"), changelog: text, enabled: true, defaults: defaults)
        XCTAssertNil(checker.whatsNew, "not again for this version")
        checker.noteLaunch(.upgraded(from: nil), changelog: text, enabled: true, defaults: defaults)
        XCTAssertEqual(checker.changes.map(\.version), [current], "none remembered: this version's alone")
    }

    /// Quit with the chip neither opened nor put away: it is there at the
    /// next launch (`.same`), About still listing the versions skipped.
    @MainActor
    func testTheChipWaitsThroughTheNextLaunch() throws {
        let suite = "overterm.tests.whatsNewFrom.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker()
        let current = checker.currentVersion
        try XCTSkipUnless(UpdateChecker.isNewer(current, than: "1.6.2"), "the test bundle's version \(current) is not past 1.6.2")
        let text = "## \(current) — today\n\n- this one\n\n## 1.6.2 — then\n\n- skipped\n\n## 1.6.1 — before\n\n- ran before\n"

        checker.noteLaunch(.upgraded(from: "1.6.1"), changelog: text, enabled: true, defaults: defaults)
        XCTAssertEqual(checker.whatsNew, current)
        XCTAssertEqual(defaults.string(forKey: UpdateChecker.whatsNewFromKey), "1.6.1", "the version it came from, kept")
        // Quit and launched again: the same version.
        let next = UpdateChecker()
        next.noteLaunch(.same, changelog: text, enabled: true, defaults: defaults)
        XCTAssertEqual(next.whatsNew, current, "still there")
        XCTAssertEqual(next.changes.map(\.version), [current, "1.6.2"], "About and Help ▸ What's New list the skipped versions")
        next.dismissWhatsNew(defaults: defaults)
        let after = UpdateChecker()
        after.noteLaunch(.same, changelog: text, enabled: true, defaults: defaults)
        XCTAssertNil(after.whatsNew, "put away: gone for this version")
        XCTAssertEqual(after.changes.map(\.version), [current, "1.6.2"])
        after.noteLaunch(.fresh, changelog: text, enabled: true, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: UpdateChecker.whatsNewFromKey), "a fresh install keeps none")
    }

    func testTheVersionAnUpdateCameFrom() {
        func from(_ launch: FirstRun.Launch, remembered: String? = nil, seen: String? = nil) -> String? {
            UpdateChecker.pendingFrom(launch: launch, remembered: remembered, seen: seen)
        }
        XCTAssertNil(from(.fresh, remembered: "1.6.1"))
        XCTAssertNil(from(.same), "no update known")
        XCTAssertEqual(from(.same, remembered: "1.6.1"), "1.6.1", "a later launch keeps it")
        XCTAssertEqual(from(.upgraded(from: "1.6.5")), "1.6.5")
        XCTAssertEqual(from(.upgraded(from: nil), remembered: "1.6.1"), "", "from before the keys: none known")
        XCTAssertEqual(
            from(.upgraded(from: "1.6.8"), remembered: "1.6.5", seen: "1.6.5"), "1.6.5",
            "1.6.8's chip never opened: the versions since 1.6.5 still unsaid")
        XCTAssertEqual(from(.upgraded(from: "1.6.8"), remembered: "1.6.5", seen: "1.6.8"), "1.6.8", "1.6.8's seen: from there")
        XCTAssertEqual(from(.upgraded(from: "1.6.5"), remembered: "1.6.8", seen: nil), "1.6.5", "a newer one remembered: the update's own")
        XCTAssertEqual(
            UpdateChecker.whatsNew(from: "", seen: nil, changelog: changelog, current: "1.6.9", enabled: true), "1.6.9", "none known: this version's lines")
        XCTAssertNil(UpdateChecker.whatsNew(from: nil, seen: nil, changelog: changelog, current: "1.6.9", enabled: true))
    }

    @MainActor
    func testTheKeysOnboardingWrites() {
        XCTAssertEqual(UpdateChecker.whatsNewSeenKey, "onboarding.whatsNewSeen")
        XCTAssertEqual(UpdateChecker.whatsNewFromKey, "onboarding.whatsNewFrom")
        XCTAssertEqual(FirstRun.formerLastRunVersionKey, "app.lastVersionRun")
    }
}
