import XCTest

@testable import Overterm

/// Onboarding 7.7, 7.10: the Setup page reads only while it shows, and
/// drops what it read when it goes — nothing kept, nothing written.
@MainActor
final class SetupPageModelTests: XCTestCase {
    override func tearDown() async throws {
        SetupProbe.override = nil
        SetupProbe.panelsOverride = nil
        try await super.tearDown()
    }

    private func settle(_ model: SetupPageModel) async throws {
        for _ in 0..<200 where model.facts == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testReadsOnlyWhileShownAndDropsWhenHidden() async throws {
        let facts = SetupFacts(shellAnswered: true, developerTools: false, notifications: .notAsked)
        SetupProbe.override = facts
        let model = SetupPageModel()
        XCTAssertNil(model.facts, "nothing read before it shows")
        XCTAssertNil(model.rows, "asking, until the facts come")

        model.checkAgain()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(model.facts, "Check Again reads nothing while hidden")

        model.visible = true
        try await settle(model)
        XCTAssertEqual(model.facts, facts)
        XCTAssertEqual(model.rows, SetupCheck.rows(facts: facts))

        model.visible = false
        XCTAssertNil(model.facts, "dropped when the page goes")
    }

    func testCheckAgainReadsAnew() async throws {
        SetupProbe.override = SetupFacts(shellAnswered: true, gh: nil)
        let model = SetupPageModel()
        model.visible = true
        try await settle(model)
        XCTAssertNil(model.facts?.gh)

        let gh = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
        SetupProbe.override = SetupFacts(shellAnswered: true, gh: gh)
        model.checkAgain()
        XCTAssertNil(model.facts, "asking again")
        try await settle(model)
        XCTAssertEqual(model.facts?.gh, gh)
        model.visible = false
    }

    /// "Tools the panels use": nothing read until opened, then the panels' facts; folded, dropped.
    func testThePanelsAreReadOnlyOnceOpened() async throws {
        SetupProbe.override = SetupFacts(shellAnswered: true)
        let panels = SetupPanelFacts(simulator: SetupPanelFacts.Simulator(xcode: true, coreSimulator: true), ghosttyConfig: false)
        SetupProbe.panelsOverride = panels
        let model = SetupPageModel()
        model.readPanels = {
            XCTFail("a scenario's facts stand in for the finders")
            return nil
        }
        model.visible = true
        try await settle(model)
        XCTAssertEqual(model.panels, .closed, "folded: not read")
        XCTAssertNil(model.panelRows)

        model.setPanelsOpen(true)
        for _ in 0..<200 where model.panels == .reading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.panels, .read(panels))
        XCTAssertEqual(model.panelRows, SetupCheck.panelRows(panels))

        model.setPanelsOpen(false)
        XCTAssertEqual(model.panels, .closed)
        model.visible = false
    }

    /// Folded and opened again while a read is out: the read from before
    /// the fold is thrown away, even when it comes first; the new one shows.
    func testAReadFromBeforeAFoldIsThrownAway() async throws {
        SetupProbe.override = SetupFacts(shellAnswered: true)
        let old = SetupPanelFacts(simulator: SetupPanelFacts.Simulator(xcode: false, coreSimulator: false), ghosttyConfig: false)
        let new = SetupPanelFacts(simulator: SetupPanelFacts.Simulator(xcode: true, coreSimulator: true), ghosttyConfig: false)
        let reads = HeldReads()
        let model = SetupPageModel()
        model.readPanels = {
            reads.started += 1
            let read = reads.started
            while !reads.released.contains(read) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return read == 1 ? old : new
        }
        model.visible = true
        try await settle(model)

        model.setPanelsOpen(true)
        for _ in 0..<200 where reads.started < 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        model.setPanelsOpen(false)
        model.setPanelsOpen(true)
        for _ in 0..<200 where reads.started < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(reads.started, 2)

        reads.released.insert(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.panels, .reading, "the read from before the fold isn't shown")
        reads.released.insert(2)
        for _ in 0..<200 where model.panels == .reading {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(model.panels, .read(new))
        model.visible = false
    }
}

/// The panels' reads a test holds until it lets each go.
@MainActor
private final class HeldReads {
    var started = 0
    var released: Set<Int> = []
}
