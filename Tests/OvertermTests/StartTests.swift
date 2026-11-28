import XCTest

@testable import Overterm

/// Onboarding 7.10: `Start` keeps its state in the defaults it is given —
/// never settings.json —, writes only the settings a press names, and does
/// nothing at all while inert: every isolated run but the `onboarding`
/// scenario (risk 3).
@MainActor
final class StartTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-start-\(UUID().uuidString)")
    private var settings: Settings!

    override func setUpWithError() throws {
        suite = "overterm-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = Settings(url: dir.appendingPathComponent("settings.json"), watch: false)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func start(active: Bool = true) -> Start {
        Start(defaults: defaults, active: active, settings: settings)
    }

    func testOnlyTheOnboardingScenarioWakesItInAnIsolatedRun() {
        XCTAssertTrue(Start.isActive(isolated: false, scenario: nil), "the person's app")
        XCTAssertFalse(Start.isActive(isolated: true, scenario: nil), "a unit test, the layout dump")
        XCTAssertFalse(Start.isActive(isolated: true, scenario: "task"), "every other scenario")
        XCTAssertTrue(Start.isActive(isolated: true, scenario: "onboarding"))
        XCTAssertFalse(Start.shared.active, "a unit test's own is inert")
    }

    /// Inert, nothing happens and nothing is kept.
    func testInertDoesNothing() {
        let start = start(active: false)
        start.begin(.fresh)
        start.gettingStarted()
        start.note(.taskCreated)
        start.chooseAgent("shell")
        start.turnOffTips()
        XCTAssertEqual(start.state, StartState(tips: true))
        XCTAssertFalse(start.state.isShown)
        XCTAssertNil(defaults.object(forKey: Start.cardKey))
        XCTAssertNil(defaults.object(forKey: Start.stepsKey))
        XCTAssertTrue(settings.tips)
        XCTAssertEqual(settings.taskAgent, "claude", "no setting written")
    }

    /// Kept in the defaults: a second `Start` reads what the first left.
    func testItsStateIsKeptInTheDefaults() throws {
        let first = start()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        first.now = { t0 }
        first.begin(.fresh)
        XCTAssertEqual(defaults.string(forKey: Start.cardKey), "open")
        XCTAssertTrue(first.state.isShown)
        first.note(.inRepository)
        XCTAssertEqual(defaults.dictionary(forKey: Start.stepsKey) as? [String: Date], ["repository": t0])

        let second = start()
        XCTAssertEqual(second.state.steps, [.repository: t0])
        second.begin(.same)
        XCTAssertEqual(second.state.card, .collapsed, "collapsed from the second launch on")
        XCTAssertEqual(defaults.string(forKey: Start.cardKey), "collapsed")

        second.close()
        XCTAssertEqual(defaults.string(forKey: Start.cardKey), "closed")
        let third = start()
        third.begin(.same)
        XCTAssertFalse(third.state.isShown, "put away for good")
        third.gettingStarted()
        XCTAssertTrue(third.state.isShown, "Help ▸ Getting Started brings it back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.url.path), "nothing of it in settings.json")
    }

    /// An update gets no card, and nothing is written for it.
    func testAnUpdateGetsNoCard() {
        let start = start()
        start.begin(.upgraded(from: "1.6.2"))
        XCTAssertFalse(start.state.isShown)
        XCTAssertNil(defaults.object(forKey: Start.cardKey))
    }

    /// Turn Off Tips: `general.tips` off, the card gone; on again, back.
    func testTurnOffTips() {
        let start = start()
        start.begin(.fresh)
        start.turnOffTips()
        XCTAssertFalse(settings.tips)
        XCTAssertFalse(start.state.isShown)
        start.note(.taskCreated)
        XCTAssertFalse(start.state.isShown, "later events show nothing")
        settings.set("general.tips", .bool(true))
        XCTAssertTrue(start.state.isShown, "the setting's change is followed")
    }

    /// The menu writes where Settings ▸ Agents does, and does the step.
    func testChoosingAnAgentWritesTheSetting() {
        let start = start()
        start.chooseAgent("shell")
        XCTAssertEqual(settings.taskAgent, "shell")
        XCTAssertEqual(start.taskAgent, "shell")
        XCTAssertTrue(start.state.isDone(.agent))
    }

    /// The done state's ticks are the panels' own settings (DISC-N4).
    func testAPanelsTickIsItsSetting() {
        let start = start()
        XCTAssertEqual(Set(start.panels.keys), Set(SidebarPanel.allCases.filter { $0.toggleKey != nil }))
        XCTAssertEqual(start.panels.count, 8)
        XCTAssertTrue(start.panels.values.allSatisfy { $0 }, "every panel on: none is unticked for the person (D-8)")
        start.setPanel(.kubernetes, false)
        XCTAssertFalse(settings.bool("kubernetes.enabled"))
        XCTAssertEqual(start.panels[.kubernetes], false)
        settings.set("kubernetes.enabled", .bool(true))
        XCTAssertEqual(start.panels[.kubernetes], true, "followed when changed elsewhere")
        start.setPanel(.files, false)
        XCTAssertNil(start.panels[.files], "Files has no switch")
    }

    func testNeedsYouIsFollowedOnlyWhileActive() {
        let inert = start(active: false)
        inert.noteNeedsYou(true)
        XCTAssertFalse(inert.anyNeedsYou)
        let start = start()
        start.noteNeedsYou(true)
        XCTAssertTrue(start.anyNeedsYou)
    }
}
