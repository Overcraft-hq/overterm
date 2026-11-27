import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// P08 (Overcraft-hq/issue-tracker#18), AGT-G2: the Inbox reads and
/// answers the pane that asks.
@MainActor
final class AskingPaneTests: XCTestCase {
    private let asked = """
        Do you want to make this edit to Parser.swift?
        ❯ 1. Yes
          2. Yes, and don't ask again this session
          3. No, and tell Claude what to do differently
        """

    // MARK: AGT-G2

    /// The pane that asked is the one read, whichever has the keyboard;
    /// once it is gone from the tab, the focused one.
    func testTheAskingPaneIsReadNotTheFocusedOne() {
        let first = TerminalView()
        let tab = Tab(terminal: first)
        let second = TerminalView()
        tab.setSplits(.split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second)))
        tab.focus(first)
        XCTAssertTrue(tab.askingTerminal === first, "nothing asked: the focused pane")
        tab.askingPane = second
        XCTAssertTrue(tab.askingTerminal === second)
        tab.askingPane = TerminalView()
        XCTAssertTrue(tab.askingTerminal === first, "a pane no longer the tab's isn't read")
    }

    /// An answer is typed only while the card's question is still on the
    /// screen, the choice one of its own.
    func testAnAnswerStandsOnlyWhileItsQuestionDoes() throws {
        let card = try XCTUnwrap(AgentPrompt.question(in: asked))
        let yes = try XCTUnwrap(card.default)
        XCTAssertTrue(TerminalWindowController.answerStands(yes, card: card, screen: asked))
        XCTAssertFalse(TerminalWindowController.answerStands(yes, card: card, screen: "$ "), "the question left")
        XCTAssertFalse(TerminalWindowController.answerStands(yes, card: nil, screen: asked), "no card, no answer")
        let other = asked.replacingOccurrences(of: "Parser.swift", with: "Lexer.swift")
        XCTAssertFalse(TerminalWindowController.answerStands(yes, card: card, screen: other), "another question now")
        let made = AgentPrompt.Choice(key: "9", label: "Something else", isDefault: false)
        XCTAssertFalse(TerminalWindowController.answerStands(made, card: card, screen: asked), "a choice it doesn't offer")
    }
}
