import XCTest

@testable import Overterm

final class DiffHighlightTests: XCTestCase {
    /// `git diff` output for `path` with these hunk lines, as loadDiffs reads it.
    private func diff(_ path: String, _ hunks: [String]) -> DiffModel.FileDiff {
        let header = ["diff --git a/\(path) b/\(path)", "index 1111111..2222222 100644", "--- a/\(path)", "+++ b/\(path)"]
        return DiffModel.FileDiff(parsing: (header + hunks).joined(separator: "\n") + "\n", path: path)
    }

    private func line(_ diff: DiffModel.FileDiff, _ kind: DiffLine.Kind, _ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> DiffLine {
        try XCTUnwrap(diff.lines.first { $0.kind == kind && $0.text == text }, "no \(kind) line “\(text)”", file: file, line: line)
    }

    /// A line's syntax colours, as "kind: text".
    private func tokens(_ diff: DiffModel.FileDiff, _ line: DiffLine) -> [String] {
        diff.style(of: line).tokens.map { "\($0.kind): \((line.text as NSString).substring(with: $0.range))" }
    }

    /// The part of a line marked as changed.
    private func changed(_ diff: DiffModel.FileDiff, _ line: DiffLine) -> String? {
        diff.style(of: line).changed.map { (line.text as NSString).substring(with: $0) }
    }

    // MARK: Syntax colours

    /// Each side of a hunk is tokenized as one text, so a comment opened on
    /// one line and closed lines later is a comment on every line of it —
    /// context lines, which carry no colour of their own, too.
    func testABlockCommentSpanningContextLinesIsACommentOnEveryLine() throws {
        let d = diff(
            "Greeter.swift",
            [
                "@@ -1,4 +1,4 @@",
                " /* Greets",
                "    the user,",
                "    politely. */",
                "-let greeting = 1",
                "+let greeting = 2",
            ])
        XCTAssertEqual(tokens(d, try line(d, .context, "/* Greets")), ["comment: /* Greets"])
        XCTAssertEqual(tokens(d, try line(d, .context, "   the user,")), ["comment:    the user,"])
        XCTAssertEqual(tokens(d, try line(d, .context, "   politely. */")), ["comment:    politely. */"])
        XCTAssertEqual(tokens(d, try line(d, .removed, "let greeting = 1")), ["keyword: let", "number: 1"], "closed: code again")
        XCTAssertEqual(tokens(d, try line(d, .added, "let greeting = 2")), ["keyword: let", "number: 2"])
    }

    /// The old side (context and removed lines) and the new (context and
    /// added) are separate texts. A removed line that opened a comment
    /// leaves the context after it code: context reads as the file now does.
    func testEachSideOfAHunkIsItsOwnText() throws {
        let d = diff(
            "a.swift",
            [
                "@@ -1,3 +1 @@",
                "-/* disabled",
                " let answer = 42",
                "-*/",
            ])
        XCTAssertEqual(tokens(d, try line(d, .removed, "/* disabled")), ["comment: /* disabled"])
        XCTAssertEqual(tokens(d, try line(d, .removed, "*/")), ["comment: */"])
        XCTAssertEqual(tokens(d, try line(d, .context, "let answer = 42")), ["keyword: let", "number: 42"])
    }

    func testAKeywordOnARemovedLine() throws {
        let d = diff(
            "a.swift",
            [
                "@@ -1,3 +1,3 @@",
                " func answer() -> Int? {",
                "-    return nil",
                "+    fatalError()",
                " }",
            ])
        XCTAssertEqual(tokens(d, try line(d, .removed, "    return nil")), ["keyword: return", "keyword: nil"])
        XCTAssertEqual(tokens(d, try line(d, .added, "    fatalError()")), [])
        XCTAssertEqual(tokens(d, try line(d, .context, "func answer() -> Int? {")), ["keyword: func"])
    }

    func testAStringOnAnAddedLine() throws {
        let d = diff(
            "a.py",
            [
                "@@ -1,2 +1,4 @@",
                " def greet():",
                "-    return hello",
                "+    return \"hello, world\"",
                "+    doc = \"\"\"spans",
                "+    lines\"\"\"",
            ])
        XCTAssertEqual(tokens(d, try line(d, .added, "    return \"hello, world\"")), ["keyword: return", "string: \"hello, world\""])
        XCTAssertEqual(tokens(d, try line(d, .added, "    doc = \"\"\"spans")), ["string: \"\"\"spans"])
        XCTAssertEqual(tokens(d, try line(d, .added, "    lines\"\"\"")), ["string:     lines\"\"\""], "a string spanning added lines")
        XCTAssertEqual(tokens(d, try line(d, .removed, "    return hello")), ["keyword: return"])
    }

    /// No colours for a file the highlighter doesn't know; what changed in a
    /// line is marked all the same — that is not about the language.
    func testAnUnknownLanguageStaysPlain() throws {
        let d = diff(
            "notes.xyz",
            [
                "@@ -1,2 +1,2 @@",
                " /* not a comment here */",
                "-let x = \"one\" // 1",
                "+let x = \"two\" // 1",
            ])
        XCTAssertEqual(d.lines.flatMap { d.style(of: $0).tokens }, [])
        XCTAssertEqual(changed(d, try line(d, .removed, "let x = \"one\" // 1")), "one")
        XCTAssertEqual(changed(d, try line(d, .added, "let x = \"two\" // 1")), "two")
    }

    // MARK: What changed in a line

    /// The changed part of a line against its pair: UTF-16 for drawing, and
    /// cut only between characters — never inside an emoji or a flag, nor
    /// between a letter and its combining accent.
    func testChangedRangesAreUTF16AndNeverSplitACharacter() {
        func ranges(_ old: String, _ new: String) -> [NSRange]? {
            DiffHighlight.changedRanges(old: old, new: new).map { [$0.old, $0.new] }
        }
        func at(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
        XCTAssertEqual(ranges("let count = 1", "let count = 2"), [at(12, 1), at(12, 1)])
        XCTAssertEqual(ranges("😀 x = 1", "😀 x = 2"), [at(7, 1), at(7, 1)], "an emoji before it is two UTF-16 units")
        XCTAssertEqual(ranges("ok 👍 go", "ok 👍🏽 go"), [at(3, 2), at(3, 4)], "a skin tone changes the whole emoji, not half of it")
        XCTAssertEqual(ranges("home 👨‍👩‍👧 now", "home 👨‍👩‍👦 now"), [at(5, 8), at(5, 8)], "a family is one character")
        XCTAssertEqual(ranges("🇹🇷 ok", "🇺🇸 ok"), [at(0, 4), at(0, 4)], "a flag is one character, not two halves")
        XCTAssertEqual(ranges("cafe au lait", "cafe\u{301} au lait"), [at(3, 1), at(3, 2)], "an accent changes its letter")
        XCTAssertEqual(ranges("caf\u{E9}!", "cafe\u{301}!"), [at(3, 1), at(3, 2)], "é written another way is a change")
        XCTAssertEqual(ranges("abc", "abXc"), [at(2, 0), at(2, 1)], "an insertion: nothing on the old side")
        XCTAssertNil(ranges("same", "same"), "nothing changed")
    }

    /// Lines that share little were replaced, not edited: marking most of
    /// both would be noise.
    func testNoHighlightForDissimilarLines() throws {
        XCTAssertNil(DiffHighlight.changedRanges(old: "let a = 1", new: "return b"))
        XCTAssertNil(DiffHighlight.changedRanges(old: "abcdefghij", new: "abcXXXXXXX"), "30% shared")
        XCTAssertNotNil(DiffHighlight.changedRanges(old: "abcdefghij", new: "abcdXXXXXX"), "40% shared")
        XCTAssertNil(DiffHighlight.changedRanges(old: "", new: "something new"))

        let d = diff("a.swift", ["@@ -1 +1 @@", "-    let a = 1", "+    return compute(b)"])
        XCTAssertNil(d.style(of: try line(d, .removed, "    let a = 1")).changed)
        XCTAssertNil(d.style(of: try line(d, .added, "    return compute(b)")).changed)
    }

    /// Removed lines pair with the added lines right after them, in order;
    /// what is left of the longer run has nothing to be compared with.
    func testUnequalRunsPairInOrder() throws {
        let d = diff(
            "a.swift",
            [
                "@@ -1,4 +1,3 @@",
                "-let a = 1",
                "-let b = 2",
                "-let c = 3",
                "+let a = 5",
                "+let b = 6",
                " end()",
            ])
        XCTAssertEqual(changed(d, try line(d, .removed, "let a = 1")), "1")
        XCTAssertEqual(changed(d, try line(d, .added, "let a = 5")), "5")
        XCTAssertEqual(changed(d, try line(d, .removed, "let b = 2")), "2")
        XCTAssertEqual(changed(d, try line(d, .added, "let b = 6")), "6")
        XCTAssertNil(changed(d, try line(d, .removed, "let c = 3")), "no pair left for it")

        func pairs(_ hunk: [String]) -> [[Int]] { DiffHighlight.pairs(in: diff("a.swift", hunk).lines).map { [$0.removed, $0.added] } }
        XCTAssertEqual(pairs(["@@ -1,4 +1,3 @@", "-a = 1", "-b = 2", "-c = 3", "+a = 5", "+b = 6", " end()"]), [[1, 4], [2, 5]])
        XCTAssertEqual(pairs(["@@ -1 +1,3 @@", "-x = 1", "+x = 2", "+y = 3", "+z = 4"]), [[1, 2]], "more added than removed")
        XCTAssertEqual(pairs(["@@ -1,4 +1,4 @@", "-a = 1", "+a = 2", " mid", "-b = 1", "+b = 2"]), [[1, 2], [4, 5]], "two changes in a hunk")
        XCTAssertEqual(pairs(["@@ -1,2 +1,2 @@", "-a = 1", " between", "+a = 2"]), [], "not adjacent")
        XCTAssertEqual(pairs(["@@ -1 +1 @@", "+a = 2", "-a = 1"]), [], "an addition is no pair for a removal after it")
        XCTAssertEqual(pairs(["@@ -1 +1 @@", "-a = 1", "@@ -9 +9 @@", "+a = 2"]), [], "another hunk")
        XCTAssertEqual(
            pairs(["@@ -1 +1 @@", "-last = 1", "\\ No newline at end of file", "+last = 2"]), [[1, 3]], "the missing newline's note between them")
    }

    // MARK: Cost

    /// A capped file (3,000 lines, a third of them changed, every change
    /// paired) is styled in well under a frame in a release build — and off
    /// the main thread anyway (DiffModel.fileDiff). A debug build is several
    /// times slower; the bound only catches something going quadratic.
    func testStylingACappedDiffIsQuick() {
        var hunk = ["@@ -1,2500 +1,2500 @@"]
        for i in 0..<500 {
            hunk += [
                "     /// The value for key \(i), or nil when it is \"missing\".",
                "     func value\(i)(for key: String) -> Int? {",
                "-        let result = cache[\"key\(i)\"] ?? 0 // old path",
                "+        let result = store[\"key\(i)\", default: 0] // new path",
                "         return result > \(i) ? result : nil",
                "     }",
            ]
        }
        let text = hunk.joined(separator: "\n") + "\n"
        let clock = ContinuousClock()
        var styled: DiffModel.FileDiff?
        let elapsed = clock.measure { styled = DiffModel.FileDiff(parsing: text, path: "Big.swift") }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("styled a 3,000-line diff (\(text.utf16.count / 1024) KB) in \(Int(seconds * 1000)) ms")
        XCTAssertEqual(styled?.lines.count, DiffModel.maxDiffLines, "the cap: the hunk header and 2,999 of its lines")
        XCTAssertEqual(styled.map { d in d.lines.filter { d.style(of: $0).changed != nil }.count }, 1_000, "every change marked")
        XCTAssertLessThan(seconds, 1.5)
    }
}
