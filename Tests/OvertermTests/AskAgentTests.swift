import XCTest

@testable import Overterm

/// What actually gets typed into an agent. The sheet's job is to build one
/// string; everything else about it is layout.
@MainActor
final class AskAgentTests: XCTestCase {
    private func model(command: CommandBlock? = nil) -> AskAgentModel {
        let model = AskAgentModel()
        model.begin(
            selection: "AssertionError: expected 200 to be 401\n  at bank.test.ts:58", command: command,
            folder: "/src/app",
            targets: [
                .init(id: UUID(), title: "api · claude", detail: "idle", color: .purple, agent: .claude),
                .init(id: nil, title: "New agent tab in this folder", detail: "", color: nil, agent: .claude),
            ], diff: false)
        return model
    }

    private let failed = CommandBlock(
        id: 0, command: "pnpm --filter api test", startRow: 0, endRow: 10, exit: 1, seconds: 4)

    func testItSendsTheSelectionOnItsOwnWhenThereIsNothingElse() {
        let model = model()
        XCTAssertEqual(model.prompt(), "AssertionError: expected 200 to be 401\n  at bank.test.ts:58")
    }

    /// The command that produced it is the context the agent cannot see,
    /// and the exit code is the part of it that matters.
    func testTheCommandAndItsExitComeWithIt() {
        let model = model(command: failed)
        let prompt = model.prompt()
        XCTAssertTrue(prompt.contains("$ pnpm --filter api test   (exit 1)"))
        XCTAssertTrue(prompt.contains("AssertionError"))
    }

    func testEachExtraCanBeLeftOut() {
        let model = model(command: failed)
        model.extras.exit = false
        XCTAssertTrue(model.prompt().contains("$ pnpm --filter api test"))
        XCTAssertFalse(model.prompt().contains("exit 1"))
        model.extras.command = false
        XCTAssertFalse(model.prompt().contains("pnpm"))
    }

    /// A command that succeeded has no exit worth saying.
    func testASuccessfulCommandDoesNotAnnounceItsExit() {
        let ok = CommandBlock(id: 1, command: "pnpm build", startRow: 0, endRow: 1, exit: 0, seconds: 1)
        let model = model(command: ok)
        XCTAssertEqual(model.prompt().contains("exit"), false)
    }

    func testWhatYouTypeGoesFirst() {
        let model = model(command: failed)
        model.message = "Fix this failing test"
        XCTAssertTrue(model.prompt().hasPrefix("Fix this failing test"))
    }

    func testTheDiffIsOnlyThereWhenAskedFor() {
        let model = model()
        XCTAssertFalse(model.prompt(diff: "diff --git a/x b/x").contains("git diff"))
        model.extras.diff = true
        XCTAssertTrue(model.prompt(diff: "diff --git a/x b/x").contains("git diff:"))
    }

    func testItCountsTheLinesItIsSending() {
        XCTAssertEqual(model().lines, 2)
    }

    /// An agent tab is picked by default; "a new tab" is the fallback, not
    /// the first thing.
    func testAnExistingAgentIsChosenFirst() {
        XCTAssertNotNil(model().chosen)
    }

    func testNothingSelectedIsNotAQuestion() {
        let model = AskAgentModel()
        model.begin(selection: "", command: nil, folder: nil, targets: [], diff: false)
        XCTAssertFalse(model.isOpen)
    }
}
