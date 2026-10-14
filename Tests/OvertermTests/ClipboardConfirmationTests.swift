import GhosttyKit
import XCTest

@testable import Overterm

final class ClipboardConfirmationTests: XCTestCase {
    /// libghostty asks again about a request completed unconfirmed — Overterm
    /// once answered that way and looped until the stack overflowed.
    func testEveryAnswerCompletesTheRequestConfirmed() throws {
        for request in [GHOSTTY_CLIPBOARD_REQUEST_PASTE, GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ] {
            let confirmation = try XCTUnwrap(ClipboardConfirmation(request: request, text: "secret"))
            XCTAssertEqual(confirmation.reply(allowed: true), .init(text: "secret", confirmed: true))
            XCTAssertEqual(confirmation.reply(allowed: false), .init(text: "", confirmed: true), "denied: nothing handed over, still confirmed")
        }
    }

    func testOnlyPastesAndClipboardReadsAreAskedAboutHere() {
        XCTAssertEqual(ClipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_PASTE, text: "x")?.kind, .paste)
        XCTAssertEqual(ClipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, text: "x")?.kind, .read)
        XCTAssertNil(ClipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, text: "x"), "writes are confirmed through write_clipboard_cb")
    }

    /// What a paste hides is the reason to ask: control characters show,
    /// line breaks and tabs stay as they are.
    func testThePreviewShowsControlCharacters() throws {
        let paste = try XCTUnwrap(ClipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_PASTE, text: "ls\u{1b}[201~echo injected\r\n\tdone\u{7f}"))
        XCTAssertEqual(paste.preview(), "ls␛[201~echo injected␍\n\tdone␡")
    }

    func testTheFullTextIsShownUpToTheLimit() throws {
        let read = try XCTUnwrap(ClipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, text: "abcdefgh"))
        XCTAssertEqual(read.preview(limit: 8), "abcdefgh")
        XCTAssertEqual(read.preview(limit: 5), "abcde\n… 3 more characters")
    }

    /// The tab's title is often the running command line: a long one is cut,
    /// keeping its start — the program's name.
    func testALongTabTitleIsCutInTheMessage() throws {
        let read = try XCTUnwrap(ClipboardConfirmation(request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, text: "x"))
        let long = "nvim " + String(repeating: "a", count: 100)
        let message = read.message(tab: long)
        XCTAssertFalse(message.contains(long))
        XCTAssertTrue(message.contains("“nvim aaa"), message)
        XCTAssertTrue(message.contains("…”"), message)
        XCTAssertTrue(read.message(tab: "zsh").contains("“zsh”"), "a short title stays whole")
    }

    /// A background tab, or a program asking again while a sheet is up, is
    /// refused without asking: only the tab you look at asks, one at a time.
    func testOnlyTheSelectedTabAsksAndOneAtATime() {
        XCTAssertTrue(ClipboardConfirmation.shouldAsk(fromSelectedTab: true, alreadyAsking: false))
        XCTAssertFalse(ClipboardConfirmation.shouldAsk(fromSelectedTab: false, alreadyAsking: false))
        XCTAssertFalse(ClipboardConfirmation.shouldAsk(fromSelectedTab: true, alreadyAsking: true))
    }
}
