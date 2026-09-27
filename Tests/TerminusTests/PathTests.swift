import XCTest

@testable import Terminus

final class PathTests: XCTestCase {
    func testShellQuotedLeavesPlainPathsBare() {
        XCTAssertEqual(TerminalWindowController.shellQuoted("Sources/Terminus/main.swift"), "Sources/Terminus/main.swift")
        XCTAssertEqual(TerminalWindowController.shellQuoted("a-b_c.d+e,f:g@h%i"), "a-b_c.d+e,f:g@h%i")
    }

    func testShellQuotedQuotesMetacharacters() {
        XCTAssertEqual(TerminalWindowController.shellQuoted("My Notes.md"), "'My Notes.md'")
        XCTAssertEqual(TerminalWindowController.shellQuoted("a$(rm -rf).txt"), "'a$(rm -rf).txt'")
    }

    func testShellQuotedEscapesSingleQuotes() {
        // it's → 'it'\''s' — close, escaped quote, reopen.
        XCTAssertEqual(TerminalWindowController.shellQuoted("it's"), "'it'\\''s'")
    }

    func testRelativePathInsideCwd() {
        let url = URL(fileURLWithPath: "/repo/Sources/a.swift")
        XCTAssertEqual(TerminalWindowController.relativePath(url, cwd: "/repo"), "Sources/a.swift")
        XCTAssertEqual(TerminalWindowController.relativePath(url, cwd: "/repo/Sources/"), "a.swift")
    }

    func testRelativePathOfCwdItself() {
        XCTAssertEqual(TerminalWindowController.relativePath(URL(fileURLWithPath: "/repo"), cwd: "/repo"), ".")
    }

    func testRelativePathOutsideCwdIsAbsolute() {
        let url = URL(fileURLWithPath: "/other/a.swift")
        XCTAssertEqual(TerminalWindowController.relativePath(url, cwd: "/repo"), "/other/a.swift")
        // A sibling sharing the prefix is not inside.
        XCTAssertEqual(TerminalWindowController.relativePath(URL(fileURLWithPath: "/repo2/a"), cwd: "/repo"), "/repo2/a")
        XCTAssertEqual(TerminalWindowController.relativePath(url, cwd: nil), "/other/a.swift")
    }

    func testPastedFilesAreQuotedAsDropsAre() {
        let urls = ["/tmp/shot.png", "/tmp/My Shot.png", "/tmp/x;$(touch pwned)", "/tmp/it's"].map(URL.init(fileURLWithPath:))
        XCTAssertEqual(
            TerminalView.pastedPaths(urls),
            #"/tmp/shot.png '/tmp/My Shot.png' '/tmp/x;$(touch pwned)' '/tmp/it'\''s'"#)
    }
}
