import XCTest

@testable import Overterm

/// Reading an agent's question off the screen. The inbox answers these by
/// typing a number, so a wrong parse is a wrong answer sent to a running
/// agent — the one place in the app where guessing is not allowed.
final class AgentPromptTests: XCTestCase {
    private let edit = """
        ⏺ Read apps/api/src/webhooks/bank.ts (142 lines)
        ⏺ Webhook payloads are parsed without signature verification.

        Edit file  apps/api/src/webhooks/bank.ts
         41 -   const event = JSON.parse(body)
         41 +   const event = verifySignature(body, headers)

        Do you want to make this edit?
        ❯ 1. Yes
          2. Yes, and don't ask again this session
          3. No, and tell Claude what to do differently
        """

    func testItReadsTheQuestionAndEveryChoice() {
        guard let prompt = AgentPrompt.parse(edit) else { return XCTFail("no prompt") }
        XCTAssertEqual(prompt.question, "Do you want to make this edit?")
        XCTAssertEqual(prompt.choices.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(prompt.choices[0].label, "Yes")
        XCTAssertEqual(prompt.default?.key, "1")
    }

    /// The marked one is what Return takes, and it is not always the first.
    func testTheMarkedChoiceIsTheDefault() {
        let text = """
            Run this command?
              1. Yes
            ❯ 2. No
            """
        XCTAssertEqual(AgentPrompt.parse(text)?.default?.key, "2")
    }

    /// "Don't ask again" is not a yes and not a no; it gets its own button
    /// so neither of the others is pressed by position.
    func testDenyAndAlwaysAreFoundByTheirWords() {
        guard let prompt = AgentPrompt.parse(edit) else { return XCTFail("no prompt") }
        XCTAssertEqual(prompt.deny?.key, "3")
        XCTAssertEqual(prompt.always?.key, "2")
    }

    /// The lines above the question are what you need to judge it.
    func testThePreviewIsTheBlockAboveTheQuestion() {
        guard let prompt = AgentPrompt.parse(edit) else { return XCTFail("no prompt") }
        XCTAssertEqual(prompt.preview.first, "Edit file  apps/api/src/webhooks/bank.ts")
        XCTAssertTrue(prompt.preview.contains { $0.contains("verifySignature") })
        XCTAssertFalse(prompt.preview.contains { $0.contains("Read apps/api") })
    }

    /// Output that happens to be a numbered list is not a question, and
    /// neither is a single choice.
    func testOrdinaryOutputIsNotAPrompt() {
        XCTAssertNil(AgentPrompt.parse("Tests  1 failed | 20 passed (21)"))
        XCTAssertNil(AgentPrompt.parse("Steps:\n  1. install\n"))
        XCTAssertNil(AgentPrompt.parse(""))
    }

    /// An older list further up must not be taken for the question: the
    /// one being asked is always the newest thing on screen.
    func testTheNewestListWins() {
        let text = """
            Pick one:
              1. apples
              2. pears

            Do you want to run this command?
            ❯ 1. Yes
              2. No
            """
        guard let prompt = AgentPrompt.parse(text) else { return XCTFail("no prompt") }
        XCTAssertEqual(prompt.question, "Do you want to run this command?")
        XCTAssertEqual(prompt.choices.map(\.label), ["Yes", "No"])
    }

    func testTheSummaryReadsAsASentenceAboutTheAgent() {
        XCTAssertEqual(AgentPrompt.parse(edit)?.summary, "wants to make this edit")
    }

    /// Codex numbers its choices with a bracket and does not always mark
    /// one.
    func testOtherAgentsPunctuateDifferently() {
        let text = """
            Allow running xcodebuild clean -scheme App?
            1) Yes
            2) No
            """
        guard let prompt = AgentPrompt.parse(text) else { return XCTFail("no prompt") }
        XCTAssertEqual(prompt.choices.map(\.key), ["1", "2"])
        XCTAssertEqual(prompt.default?.key, "1")
        XCTAssertEqual(prompt.deny?.key, "2")
    }
}
