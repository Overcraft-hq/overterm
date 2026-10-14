import XCTest

@testable import Terminus

/// Texts with their selections written in: `|` a caret, `«…»` a selection.
/// (Not `[…]`: brackets are what half of these tests type.)
enum Marked {
    static func parse(_ marked: String) -> (text: NSString, selections: [NSRange]) {
        let text = NSMutableString()
        var selections: [NSRange] = []
        var open: Int? = nil
        for character in marked {
            switch character {
            case "|": selections.append(NSRange(location: text.length, length: 0))
            case "«": open = text.length
            case "»":
                selections.append(NSRange(location: open!, length: text.length - open!))
                open = nil
            default: text.append(String(character))
            }
        }
        return (text, selections.sorted { $0.location < $1.location })
    }

    static func render(_ text: String, _ selections: [NSRange]) -> String {
        let result = NSMutableString(string: text)
        for selection in selections.sorted(by: { $0.location > $1.location }) {
            if selection.length == 0 {
                result.insert("|", at: selection.location)
            } else {
                result.insert("»", at: selection.upperBound)
                result.insert("«", at: selection.location)
            }
        }
        return result as String
    }
}

final class EditCommandsTests: XCTestCase {
    typealias Command = (NSString, [NSRange]) -> TextEdit?

    /// Runs `command` on `before` and compares text and selections with
    /// `after`; nil `after`: the command does nothing.
    private func check(_ before: String, _ after: String?, file: StaticString = #filePath, line: UInt = #line, _ command: Command) {
        let (text, selections) = Marked.parse(before)
        let edit = command(text, selections)
        guard let after else {
            XCTAssertNil(edit, "expected no edit, got \(String(describing: edit.map { Marked.render($0.applied(to: text as String), $0.selections) }))", file: file, line: line)
            return
        }
        guard let edit else { return XCTFail("no edit", file: file, line: line) }
        var end = 0
        for change in edit.changes {
            XCTAssertGreaterThanOrEqual(change.range.location, end, "changes overlap or are out of order", file: file, line: line)
            end = NSMaxRange(change.range)
        }
        XCTAssertEqual(Marked.render(edit.applied(to: text as String), edit.selections), after, file: file, line: line)
    }

    private func checkSelections(_ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line, _ command: (NSString, [NSRange]) -> [NSRange]) {
        let (text, selections) = Marked.parse(before)
        XCTAssertEqual(Marked.render(text as String, command(text, selections)), after, file: file, line: line)
    }

    // MARK: Indent style

    func testIndentStyleIsDetectedFromTheFile() {
        let cases: [(String, String?, IndentStyle)] = [
            ("a {\n  b {\n    c\n  }\n}\n", nil, .spaces(2)),
            ("def f():\n    if x:\n        y\n    z\n", "python", .spaces(4)),
            ("func a() {\n\tb()\n\tif c {\n\t\td()\n\t}\n}\n", "swift", .tabs),
            ("a:\n   b:\n      c\n", "yaml", .spaces(3)),
            // A doc comment's single space is not a level.
            ("/**\n * Doc\n * more\n */\nfunc a() {\n    b\n}\n", "swift", .spaces(4)),
            ("", nil, .spaces(4)),
            ("", "go", .tabs),
            ("all:\nbuild\n", "make", .tabs),
            ("no indentation\nat all\n", "swift", .spaces(4)),
            // Closing two levels at once (a step of 4) in a 2-space file.
            ("a\n  b\n    c\n      d\n  e\n    f\n", nil, .spaces(2)),
        ]
        for (text, language, expected) in cases {
            XCTAssertEqual(IndentStyle.detect(in: text as NSString, languageID: language), expected, text)
        }
        XCTAssertEqual(IndentStyle.tabs.unit, "\t")
        XCTAssertEqual(IndentStyle.spaces(2).unit, "  ")
        XCTAssertEqual(IndentStyle.tabs.width(tabWidth: 8), 8)
    }

    func testLanguageHelpers() {
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "swift"), .line("// "))
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "jsonc"), .line("// "))
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "python"), .line("# "))
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "dockerfile"), .line("# "))
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "lua"), .line("-- "))
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "markdown"), .block(open: "<!--", close: "-->"))
        XCTAssertEqual(EditCommands.commentPrefix(forLanguageID: "css"), .block(open: "/*", close: "*/"))
        XCTAssertNil(EditCommands.commentPrefix(forLanguageID: nil))
        XCTAssertEqual(EditCommands.languageID(forFileName: "main.rs"), "rust")
        XCTAssertEqual(EditCommands.languageID(forFileName: "Makefile"), "make")
        XCTAssertEqual(EditCommands.languageID(forFileName: "Dockerfile.dev"), "dockerfile")
        XCTAssertEqual(EditCommands.languageID(forFileName: "App.TSX"), "tsx")
        XCTAssertNil(EditCommands.languageID(forFileName: "notes.txt"))
        XCTAssertEqual(EditCommands.lineEnding(of: "a\r\nb\n"), "\r\n")
        XCTAssertEqual(EditCommands.lineEnding(of: "a\nb\r\n"), "\n")
        XCTAssertEqual(EditCommands.lineEnding(of: "a"), "\n")
    }

    // MARK: Return

    private func newline(_ language: String? = nil, _ style: IndentStyle = .spaces(4)) -> Command {
        { EditCommands.newline(in: $0, selections: $1, style: style, languageID: language) }
    }

    func testReturnIndents() {
        let cases: [(String, String, String?)] = [
            ("    foo|", "    foo\n    |", nil),
            ("if x {|", "if x {\n    |", nil),
            ("if x {   |", "if x {   \n    |", nil),
            ("func a() {|}", "func a() {\n    |\n}", nil),
            ("  call(|)", "  call(\n      |\n  )", nil),
            ("[|]", "[\n    |\n]", nil),
            ("{| }", "{\n    |\n}", nil),
            ("def f():|", "def f():\n    |", "python"),
            ("key:|", "key:\n    |", "yaml"),
            ("key:|", "key:\n|", "swift"),
            ("for x in y; do|", "for x in y; do\n    |", "shell"),
            ("if a then|", "if a then\n    |", "lua"),
            ("undo|", "undo\n|", "shell"),
            ("foo|   bar", "foo\n|bar", nil),
            ("a«bc»d", "a\n|d", nil),
            // A line of only whitespace is left empty.
            ("    |", "\n    |", nil),
            ("  |  x", "\n  |x", nil),
            ("|", "\n|", nil),
            ("😀 {|}", "😀 {\n    |\n}", nil),
            ("x {|\r\ny", "x {\r\n    |\r\ny", nil),
            ("a|\nb|", "a\n|\nb\n|", nil),
        ]
        for (before, after, language) in cases { check(before, after, newline(language)) }
        check("\tif x {|}", "\tif x {\n\t\t|\n\t}", newline(nil, .tabs))
    }

    func testInsertLineBelowAndAbove() {
        let below: Command = { EditCommands.insertLineBelow(in: $0, selections: $1, style: .spaces(4)) }
        let above: Command = { EditCommands.insertLineAbove(in: $0, selections: $1) }
        check("fo|o {\nbar", "foo {\n    |\nbar", below)
        check("  a|b", "  ab\n  |", below)
        check("a|b|\nc|", "ab\n|\nc\n|", below)
        check("a|\r\nb", "a\r\n|\r\nb", below)
        check("    fo|o", "    |\n    foo", above)
        check("x\n  «y»", "x\n  |\n  y", above)
        check("a|\r\nb", "|\r\na\r\nb", above)
    }

    // MARK: Pairs

    private func type(_ c: String, _ language: String? = "swift") -> Command {
        { EditCommands.typeCharacter(c, in: $0, selections: $1, languageID: language) }
    }

    func testTypingOpensPairs() {
        check("foo|", "foo(|)", type("("))
        check("foo| bar", "foo(|) bar", type("("))
        check("a(|)", "a((|))", type("("))
        check("a|;", "a[|];", type("["))
        check("x = |", "x = {|}", type("{"))
        // Before a word, an opener is just itself: the view types it.
        check("|bar", nil, type("("))
        check("x = |", "x = \"|\"", type("\""))
        check("x = |", "x = '|'", type("'", "python"))
        check("`|", nil, type("`", "markdown"))
        check("a |", "a `|`", type("`", "markdown"))
        // Not after a word character: an apostrophe, a suffix.
        check("abc|", nil, type("\""))
        check("ş|", nil, type("\""))
        check("it|", nil, type("'", "python"))
        // No ' pairs in plain text, Markdown, Rust.
        check(" |", nil, type("'", nil))
        check(" |", nil, type("'", "markdown"))
        check("<|", nil, type("'", "rust"))
        check("😀|", "😀\"|\"", type("\""))
        check("a|", nil, type("x"))
        check("a|\nb|", "a(|)\nb(|)", type("("))
        check("a|b\nc|", "a(|b\nc(|)", type("("))
    }

    func testTypingAroundASelectionWrapsIt() {
        check("«abc»", "(«abc»)", type("("))
        check("x «a😀» y", "x \"«a😀»\" y", type("\""))
        check("«a» «b»", "[«a»] [«b»]", type("["))
        check("«abc»", nil, type(")"))
    }

    func testTypingACloserStepsOverTheOneThere() {
        check("foo(|)", "foo()|", type(")"))
        check("[a, b|]", "[a, b]|", type("]"))
        check("\"abc|\"", "\"abc\"|", type("\""))
        // The line is short of a closer: this one is new.
        check("foo(bar(|)", nil, type(")"))
        check("a|", nil, type(")"))
        check("f(|)\ng(|)", "f()|\ng()|", type(")"))
    }

    func testBackspaceInsideAnEmptyPairDeletesBoth() {
        let delete: Command = { EditCommands.deleteBackward(in: $0, selections: $1) }
        check("(|)", "|", delete)
        check("x\"|\"", "x|", delete)
        check("a[|]b", "a|b", delete)
        check("a|", nil, delete)
        check("(|x)", nil, delete)
        check("a(|)\nb|", "a|\n|", delete)
        check("😀|\n(|)", "|\n|", delete)
        check("«ab»\n{|}", "|\n|", delete)
    }

    // MARK: Comments

    private func comment(_ style: CommentStyle = .line("// ")) -> Command {
        { EditCommands.toggleLineComment(in: $0, selections: $1, style: style) }
    }

    func testToggleLineComment() {
        check("fo|o", "// fo|o", comment())
        check("|foo", "// |foo", comment())
        check("// fo|o", "fo|o", comment())
        check("//fo|o", "fo|o", comment())
        check("    a|\n", "    // a|\n", comment())
        check("    // a|\n", "    a|\n", comment())
        // Lined up at the least indentation; the line after a selection
        // ending at its start isn't touched.
        check("«  a\n    b\n»c", "«  // a\n  //   b\n»c", comment())
        // Mixed: comments everything (again).
        check("«// a\nb»", "«// // a\n// b»", comment())
        check("«a\n\nb»", "«// a\n\n// b»", comment())
        check("«// a\n\n  // b»", "«a\n\n  b»", comment())
        check("|", "// |", comment())
        check("a|\nb\nc|", "// a|\nb\n// c|", comment())
        check("x = 1 # y|", "# x = 1 # y|", comment(.line("# ")))
        check("# x|", "x|", comment(.line("# ")))
        check("-- select|", "select|", comment(.line("-- ")))
        check("a|\r\nb", "// a|\r\nb", comment())
        check("şey 😀|", "// şey 😀|", comment())
    }

    func testToggleBlockComment() {
        let html = comment(.block(open: "<!--", close: "-->"))
        check("  <p>|</p>", "  <!-- <p>|</p> -->", html)
        check("  <!-- <p>|</p> -->", "  <p>|</p>", html)
        check("<!--x|-->", "x|", html)
        check("«a\nb»", "«<!-- a -->\n<!-- b -->»", html)
        check("a {}|", "/* a {}| */", comment(.block(open: "/*", close: "*/")))
        check("/* a {} */|", "a {}|", comment(.block(open: "/*", close: "*/")))
    }

    // MARK: Indentation

    func testIndentAndOutdent() {
        let indent: Command = { EditCommands.indent(in: $0, selections: $1, style: .spaces(4)) }
        let outdent: Command = { EditCommands.outdent(in: $0, selections: $1, style: .spaces(4)) }
        check("a|", "    a|", indent)
        check("«a\nb»", "«    a\n    b»", indent)
        check("«a\n\nb»", "«    a\n\n    b»", indent)
        check("|", "    |", indent)
        check("    a|", "a|", outdent)
        check("  a|", "a|", outdent)
        check("      a|", "  a|", outdent)
        check("\t\ta|", "\ta|", outdent)
        check("  |  a", "|a", outdent)
        check("a|", nil, outdent)
        check("«    a\n  b\nc»", "«a\nb\nc»", outdent)
        check("\ta|", "\t\ta|", { EditCommands.indent(in: $0, selections: $1, style: .tabs) })
    }

    func testTab() {
        let tab: Command = { EditCommands.insertTab(in: $0, selections: $1, style: .spaces(4)) }
        check("|", "    |", tab)
        check("a|", "a   |", tab)
        check("\t|", "\t    |", tab)
        check("a«b»c", "a   |c", tab)
        check("«a\nb»", "«    a\n    b»", tab)
        check("a|", "a\t|", { EditCommands.insertTab(in: $0, selections: $1, style: .tabs) })
    }

    // MARK: Lines

    private func move(_ direction: EditCommands.Direction) -> Command {
        { EditCommands.moveLines(direction, in: $0, selections: $1) }
    }

    func testMoveLines() {
        check("a\nb|\nc", "b|\na\nc", move(.up))
        check("a\nb|\nc", "a\nc\nb|", move(.down))
        check("a|\nb", nil, move(.up))
        check("a\nb|", nil, move(.down))
        check("a\nb\nc|\n", "a\nb\n\nc|", move(.down))
        check("a\n«b\nc»\nd", "«b\nc»\na\nd", move(.up))
        check("a\n«b\nc»\nd", "a\nd\n«b\nc»", move(.down))
        // A selection ending at a line's start doesn't take that line.
        check("a\n«b\n»c\nd", "a\nc\n«b\n»d", move(.down))
        check("a\r\nb|", "b|\r\na", move(.up))
        // Carets on adjacent lines move as one block.
        check("a\nb|\nc|\nd", "b|\nc|\na\nd", move(.up))
        check("a\nb|\nc|\nd", "a\nd\nb|\nc|", move(.down))
        // A block at the edge stays; the others move.
        check("a|\nb\nc|", "a|\nc|\nb", move(.up))
        check("şey\n😀|x", "😀|x\nşey", move(.up))
        check("|", nil, move(.up))
    }

    func testDuplicateLines() {
        let down: Command = { EditCommands.duplicateLines(.down, in: $0, selections: $1) }
        let up: Command = { EditCommands.duplicateLines(.up, in: $0, selections: $1) }
        check("a|b\nc", "ab\na|b\nc", down)
        check("a|b\nc", "a|b\nab\nc", up)
        check("x\nab|", "x\nab\nab|", down)
        check("ab|\r\nc", "ab\r\nab|\r\nc", down)
        check("c\r\nab|", "c\r\nab\r\nab|", down)
        check("«a\nb»\nc", "a\nb\n«a\nb»\nc", down)
        check("a|\nb|", "a\na|\nb\nb|", down)
        check("|", "\n|", down)
    }

    func testDeleteLines() {
        let delete: Command = { EditCommands.deleteLines(in: $0, selections: $1) }
        check("a\nb|c\nd", "a\nd|", delete)
        check("a\nbc|", "a|", delete)
        check("only|", "|", delete)
        check("ab|\n", "|", delete)
        check("a|\nb\nc|\nd", "b|\nd|", delete)
        check("«a\nb»\nc", "|c", delete)
        check("😀😀|\nab😀", "ab😀|", delete)
        // The column would split an emoji: the caret goes before it.
        check("a😀|\n😀😀", "😀|😀", delete)
        check("a\r\nb|\r\nc", "a\r\nc|", delete)
    }

    func testSelectLine() {
        checkSelections("a|b\ncd", "«ab\n»cd") { EditCommands.expandLineSelection(in: $0, selections: $1) }
        checkSelections("«ab\n»cd", "«ab\ncd»") { EditCommands.expandLineSelection(in: $0, selections: $1) }
        checkSelections("ab\nc|d", "ab\n«cd»") { EditCommands.expandLineSelection(in: $0, selections: $1) }
        checkSelections("ab\n«cd»", "ab\n«cd»") { EditCommands.expandLineSelection(in: $0, selections: $1) }
        checkSelections("a|b\nc|d\ne", "«ab\ncd\n»e") { EditCommands.expandLineSelection(in: $0, selections: $1) }
        checkSelections("«ab\n»cd", "«ab\n»cd") { EditCommands.selectLine(in: $0, selections: $1) }
        checkSelections("a«b\nc»d", "«ab\ncd»") { EditCommands.selectLine(in: $0, selections: $1) }
    }

    func testJoinLines() {
        let join: Command = { EditCommands.joinLines(in: $0, selections: $1) }
        check("a|\n  b", "a| b", join)
        check("a  |  \n   b", "a| b", join)
        check("a\nb|", nil, join)
        check("a|\n\nb", "a|\nb", join)
        check("«a\nb\nc»", "«a b c»", join)
        check("a|\r\nb", "a| b", join)
        check("x|\n}\ny|\nz", "x| }\ny| z", join)
        check("şey|\n😀", "şey| 😀", join)
    }

    // MARK: Occurrences

    private func next(_ marked: String, wholeWord: Bool) -> (String, Bool)? {
        let (text, selections) = Marked.parse(marked)
        return EditCommands.selectNextOccurrence(in: text, selections: selections, wholeWord: wholeWord).map {
            (Marked.render(text as String, $0.selections), $0.wholeWord)
        }
    }

    func testSelectNextOccurrence() {
        XCTAssertEqual(next("foo b|ar foo bar", wholeWord: false)?.0, "foo «bar» foo bar")
        XCTAssertEqual(next("foo b|ar foo bar", wholeWord: false)?.1, true)
        XCTAssertEqual(next("foo «bar» foo bar", wholeWord: true)?.0, "foo «bar» foo «bar»")
        XCTAssertNil(next("foo «bar» foo «bar»", wholeWord: true))
        // Wraps past the end.
        XCTAssertEqual(next("x bar «bar»", wholeWord: true)?.0, "x «bar» «bar»")
        XCTAssertEqual(next("bar «bar» x bar", wholeWord: true)?.0, "bar «bar» x «bar»")
        // Started from a caret: whole words only.
        XCTAssertEqual(next("foo foobar «foo»", wholeWord: true)?.0, "«foo» foobar «foo»")
        XCTAssertEqual(next("«foo» foobar", wholeWord: false)?.0, "«foo» «foo»bar")
        XCTAssertEqual(next("«Foo» foo Foo", wholeWord: false)?.0, "«Foo» foo «Foo»")
        XCTAssertNil(next("a | b", wholeWord: false))
        XCTAssertEqual(next("|şey şey", wholeWord: false)?.0, "«şey» şey")
        XCTAssertEqual(next("«şey» şey", wholeWord: true)?.0, "«şey» «şey»")
        XCTAssertEqual(next("😀«ab» ab", wholeWord: false)?.0, "😀«ab» «ab»")
    }

    func testSelectAllOccurrences() {
        let (text, selections) = Marked.parse("a |foo b foo foofoo")
        let all = EditCommands.selectAllOccurrences(in: text, selections: selections, wholeWord: false)
        XCTAssertEqual(all.map { Marked.render(text as String, $0.selections) }, "a «foo» b «foo» foofoo")
        let (text2, selections2) = Marked.parse("«oo» foo")
        let parts = EditCommands.selectAllOccurrences(in: text2, selections: selections2, wholeWord: false)
        XCTAssertEqual(parts.map { Marked.render(text2 as String, $0.selections) }, "«oo» f«oo»")
        XCTAssertNil(EditCommands.selectAllOccurrences(in: "  ", selections: [NSRange(location: 1, length: 0)], wholeWord: false))
    }

    // MARK: Brackets

    func testMatchingBracket() {
        let text = "f(a[b]c)" as NSString
        XCTAssertEqual(EditCommands.matchingBracket(at: 2, in: text), BracketMatch(bracket: 1, partner: 7))
        XCTAssertEqual(EditCommands.matchingBracket(at: 1, in: text), BracketMatch(bracket: 1, partner: 7), "the one at the caret")
        XCTAssertEqual(EditCommands.matchingBracket(at: 8, in: text), BracketMatch(bracket: 7, partner: 1))
        XCTAssertEqual(EditCommands.matchingBracket(at: 6, in: text), BracketMatch(bracket: 5, partner: 3))
        XCTAssertNil(EditCommands.matchingBracket(at: 0, in: "abc"))
        XCTAssertNil(EditCommands.matchingBracket(at: 1, in: "(abc"))
        // Brackets in strings don't count.
        let quoted = "(\")\")" as NSString
        XCTAssertEqual(EditCommands.matchingBracket(at: 0, in: quoted, skip: { (1...3).contains($0) }), BracketMatch(bracket: 0, partner: 4))
        XCTAssertNil(EditCommands.matchingBracket(at: 3, in: quoted, skip: { (1...3).contains($0) }))
        let emoji = "{😀[😀]}" as NSString
        XCTAssertEqual(EditCommands.matchingBracket(at: 0, in: emoji), BracketMatch(bracket: 0, partner: emoji.length - 1))
        // Past the scan limit, no partner.
        let far = ("(" + String(repeating: "x", count: EditCommands.maxBracketScan + 10) + ")") as NSString
        XCTAssertNil(EditCommands.matchingBracket(at: 1, in: far))
        XCTAssertEqual(EditCommands.matchingBracket(at: far.length, in: far, skip: { _ in false })?.partner, nil)
        let near = ("(" + String(repeating: "x", count: 50_000) + ")") as NSString
        XCTAssertEqual(EditCommands.matchingBracket(at: near.length, in: near), BracketMatch(bracket: near.length - 1, partner: 0))
    }

    // MARK: Indent guides

    func testIndentGuides() {
        let text =
            """
            a {
                b {
                    c

                    d

                }

            }
            \tx
            """ as NSString
        let starts = LineIndex.starts(of: text)
        XCTAssertEqual(
            EditCommands.indentGuides(in: text, lineStarts: starts, lines: 0..<starts.count, indentWidth: 4),
            [0, 1, 2, 2, 2, 1, 1, 0, 0, 1])
        // Seen from the middle: the blank line looks outside the range.
        XCTAssertEqual(EditCommands.indentGuides(in: text, lineStarts: starts, lines: 3..<4, indentWidth: 4), [2])
        XCTAssertEqual(EditCommands.indentGuides(in: text, lineStarts: starts, lines: 7..<9, indentWidth: 4), [0, 0])
        XCTAssertEqual(EditCommands.indentGuides(in: text, lineStarts: starts, lines: 8..<20, indentWidth: 4), [0, 1])
        let two = "a\n  b\n    c\r\n\r\n  d" as NSString
        XCTAssertEqual(EditCommands.indentGuides(in: two, lineStarts: LineIndex.starts(of: two), lines: 0..<5, indentWidth: 2), [0, 1, 2, 1, 1])
    }

    // MARK: Big files

    /// Commands read the lines they touch, not the file: each on a 4 MB file
    /// costs next to nothing.
    func testCommandsOnA4MBFileStayFast() {
        let line = "    let value = compute(12345) // a comment of some length\n"
        let text = String(repeating: line, count: 4_000_000 / line.utf16.count) as NSString
        let middle = NSRange(location: text.length / 2 + 10, length: 0)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = IndentStyle.detect(in: text)
            _ = EditCommands.newline(in: text, selections: [middle], style: .spaces(4))
            _ = EditCommands.moveLines(.up, in: text, selections: [middle])
            _ = EditCommands.duplicateLines(.down, in: text, selections: [middle])
            _ = EditCommands.toggleLineComment(in: text, selections: [middle], style: .line("// "))
            _ = EditCommands.deleteLines(in: text, selections: [middle])
            _ = EditCommands.joinLines(in: text, selections: [middle])
            _ = EditCommands.typeCharacter("(", in: text, selections: [middle])
            _ = EditCommands.matchingBracket(at: middle.location, in: text)
        }
        print("EditCommands on 4 MB: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(500))
    }
}
