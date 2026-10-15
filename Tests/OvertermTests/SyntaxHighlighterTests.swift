import XCTest

@testable import Overterm

final class SyntaxHighlighterTests: XCTestCase {
    private func tokens(_ text: String, _ file: String) -> [(String, SyntaxHighlighter.Kind)] {
        let language = SyntaxHighlighter.language(for: URL(fileURLWithPath: file))!
        return SyntaxHighlighter.tokens(in: text, language: language).map { ((text as NSString).substring(with: $0.0), $0.1) }
    }

    func testSwift() {
        let found = tokens("let x = \"a // not a comment\" // real 42\nfunc f() { return 3.5 }", "a.swift")
        XCTAssertTrue(found.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(found.contains { $0 == ("\"a // not a comment\"", .string) })
        XCTAssertTrue(found.contains { $0 == ("// real 42", .comment) })
        XCTAssertTrue(found.contains { $0 == ("3.5", .number) })
        XCTAssertFalse(found.contains { $0.0 == "42" }, "numbers inside comments are not numbers")
    }

    func testBlockCommentsAndTemplateStringsSpanLines() {
        let found = tokens("/* a\nb */ const s = `x\ny`", "a.ts")
        XCTAssertEqual(found.first?.1, .comment)
        XCTAssertEqual(found.first?.0, "/* a\nb */")
        XCTAssertTrue(found.contains { $0 == ("`x\ny`", .string) })
        XCTAssertTrue(found.contains { $0 == ("const", .keyword) })
    }

    func testUnterminatedStringStopsAtLineEnd() {
        let found = tokens("s = \"open\nx = 1", "a.py")
        XCTAssertTrue(found.contains { $0 == ("\"open", .string) })
        XCTAssertTrue(found.contains { $0 == ("1", .number) })
    }

    func testByFileName() {
        XCTAssertNotNil(SyntaxHighlighter.language(for: URL(fileURLWithPath: "/r/Dockerfile")))
        XCTAssertNotNil(SyntaxHighlighter.language(for: URL(fileURLWithPath: "/r/Makefile")))
        XCTAssertNil(SyntaxHighlighter.language(for: URL(fileURLWithPath: "/r/notes.xyz")))
        let found = tokens("# comment\nkey: true", "a.yaml")
        XCTAssertEqual(found.map(\.1), [.comment, .keyword])
    }
}
