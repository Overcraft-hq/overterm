import XCTest

@testable import Overterm

/// P05 (Overcraft-hq/issue-tracker#15), GIT-G11: New Task's text goes to
/// its agent once the agent is up and its screen has settled — never into
/// a shell whose agent didn't start.
final class TaskPromptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testTheTextWaitsForTheAgentAndASettledScreen() {
        var wait = TaskPromptWait(started: start)
        XCTAssertEqual(wait.step(now: at(0.4), agentRunning: false, screen: "% claude"), .wait, "the shell still")
        XCTAssertEqual(wait.step(now: at(0.8), agentRunning: true, screen: ""), .wait, "the agent's screen not drawn yet")
        XCTAssertEqual(wait.step(now: at(1.2), agentRunning: true, screen: "╭ Welcome"), .wait)
        XCTAssertEqual(wait.step(now: at(1.6), agentRunning: true, screen: "╭ Welcome\n> "), .wait, "still drawing")
        XCTAssertEqual(wait.step(now: at(2.4), agentRunning: true, screen: "╭ Welcome\n> "), .wait, "not settled for long enough")
        XCTAssertEqual(wait.step(now: at(3.2), agentRunning: true, screen: "╭ Welcome\n> "), .deliver)
    }

    func testAnAgentThatGoesStartsTheWaitOver() {
        var wait = TaskPromptWait(started: start)
        _ = wait.step(now: at(1), agentRunning: true, screen: "> ")
        XCTAssertEqual(wait.step(now: at(2), agentRunning: false, screen: "% "), .wait, "it exited: back to the shell")
        XCTAssertEqual(wait.step(now: at(3), agentRunning: true, screen: "> "), .wait)
        XCTAssertEqual(wait.step(now: at(3.8), agentRunning: true, screen: "> "), .wait, "its own time counts from its return")
        XCTAssertEqual(wait.step(now: at(4.6), agentRunning: true, screen: "> "), .deliver)
    }

    func testAnAgentThatNeverStartsIsGivenUp() {
        var wait = TaskPromptWait(started: start, timeout: 5)
        XCTAssertEqual(wait.step(now: at(4), agentRunning: false, screen: "% "), .wait)
        XCTAssertEqual(wait.step(now: at(5.1), agentRunning: false, screen: "% "), .giveUp, "never typed into the shell")
        var still = TaskPromptWait(started: start, timeout: 5)
        XCTAssertEqual(still.step(now: at(6), agentRunning: true, screen: "> "), .giveUp, "too late even with the agent there")
    }

    func testTheTextIsTheSheetsWithoutItsTrailingBlank() {
        XCTAssertEqual(TaskPromptWait.text("Sepete kupon kodu alanı ekle\n\n  "), "Sepete kupon kodu alanı ekle")
        XCTAssertEqual(TaskPromptWait.text("  first line\nsecond line\n"), "  first line\nsecond line", "its own lines kept")
        XCTAssertNil(TaskPromptWait.text(""), "no task: today's New Task")
        XCTAssertNil(TaskPromptWait.text(" \n\t"))
    }
}
