import XCTest

@testable import Overterm

/// A text view stand-in: NSMutableString, a selection, and undo by whole
/// snapshots per outermost group, the cursor at the change like NSTextView's.
@MainActor
final class FakeVimBuffer: VimBuffer {
    let storage: NSMutableString
    var selection = NSRange(location: 0, length: 0)
    var clipboard: String?
    var visible: NSRange?
    var scrolls: [VimScroll] = []
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var depth = 0
    private var snapshot: String?

    init(_ text: String) { storage = NSMutableString(string: text) }

    var text: NSString { storage }
    var visibleCharacterRange: NSRange { visible ?? NSRange(location: 0, length: storage.length) }
    func scroll(_ request: VimScroll) { scrolls.append(request) }
    func indentUnit() -> String { "    " }

    func replace(_ range: NSRange, with string: String) {
        beginUndoGroup()
        storage.replaceCharacters(in: range, with: string)
        selection = NSRange(location: range.location + string.utf16.count, length: 0)
        endUndoGroup()
    }

    func beginUndoGroup() {
        if depth == 0 { snapshot = storage as String }
        depth += 1
    }

    func endUndoGroup() {
        depth -= 1
        if depth == 0, let snapshot, snapshot != storage as String {
            undoStack.append(snapshot)
            redoStack = []
        }
    }

    func undo() { swapIn(from: &undoStack, to: &redoStack) }
    func redo() { swapIn(from: &redoStack, to: &undoStack) }

    private func swapIn(from: inout [String], to: inout [String]) {
        guard let restored = from.popLast() else { return }
        let current = storage as String
        to.append(current)
        let a = Array(current.utf16)
        let b = Array(restored.utf16)
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        storage.setString(restored)
        selection = NSRange(location: min(i, b.count), length: 0)
    }

    /// What the text view does with a key the engine left to it, in insert mode.
    func type(_ key: VimKey) {
        switch key.named {
        case .backspace:
            let p = selection.location
            guard p > 0 else { return }
            let r = storage.rangeOfComposedCharacterSequence(at: p - 1)
            replace(NSRange(location: r.location, length: p - r.location), with: "")
        case .enter: replace(selection, with: "\n")
        case .tab: replace(selection, with: "\t")
        case .left: selection = NSRange(location: max(0, selection.location - 1), length: 0)
        case .right: selection = NSRange(location: min(storage.length, selection.location + 1), length: 0)
        case .some: break
        case nil: replace(selection, with: key.characters)
        }
    }
}

@MainActor
final class VimEngineTests: XCTestCase {
    /// `ciwfoo<esc>` → keys; `<esc> <cr> <bs> <tab> <c-x> <left>…` are one key.
    static func keys(_ s: String) -> [VimKey] {
        var out: [VimKey] = []
        var chars = Array(s)
        while !chars.isEmpty {
            if chars[0] == "<", let end = chars.firstIndex(of: ">"), end > 1 {
                let name = String(chars[1..<end]).lowercased()
                let named: [String: VimKey.Named] = [
                    "esc": .escape, "cr": .enter, "bs": .backspace, "tab": .tab, "del": .delete,
                    "left": .left, "right": .right, "up": .up, "down": .down,
                ]
                if let n = named[name] {
                    out.append(VimKey(n))
                    chars.removeFirst(end + 1)
                    continue
                }
                if name.hasPrefix("c-"), name.count == 3 {
                    out.append(VimKey(String(name.last!), modifiers: .control))
                    chars.removeFirst(end + 1)
                    continue
                }
            }
            out.append(VimKey(String(chars.removeFirst())))
        }
        return out
    }

    /// The text with `|` at the cursor taken out, and the engine over it.
    func make(_ input: String, clipboard: String? = nil) -> (FakeVimBuffer, VimEngine) {
        let marked = input as NSString
        let at = marked.range(of: "|").location
        let buffer = FakeVimBuffer(marked.replacingOccurrences(of: "|", with: ""))
        buffer.selection = NSRange(location: at == NSNotFound ? 0 : at, length: 0)
        buffer.clipboard = clipboard
        let engine = VimEngine(buffer: buffer)
        engine.reset()
        return (buffer, engine)
    }

    func press(_ keys: String, _ buffer: FakeVimBuffer, _ engine: VimEngine) {
        for key in Self.keys(keys) where !engine.handle(key) {
            buffer.type(key)
        }
    }

    func render(_ buffer: FakeVimBuffer, _ engine: VimEngine) -> String {
        let s = NSMutableString(string: buffer.storage)
        s.insert("|", at: min(engine.cursor, s.length))
        return s as String
    }

    func check(_ cases: [(String, String, String)], clipboard: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        for (input, keys, expected) in cases {
            let (buffer, engine) = make(input, clipboard: clipboard)
            press(keys, buffer, engine)
            XCTAssertEqual(render(buffer, engine), expected, "\(input.debugDescription) + \(keys)", file: file, line: line)
        }
    }

    // MARK: Motions

    func testWordMotions() {
        check([
            ("|hello world", "w", "hello |world"),
            ("hello |world", "b", "|hello world"),
            ("|hello world", "e", "hell|o world"),
            ("hello |world", "ge", "hell|o world"),
            ("|foo.bar baz", "w", "foo|.bar baz"),
            ("|foo.bar baz", "W", "foo.bar |baz"),
            ("foo.bar |baz", "B", "|foo.bar baz"),
            ("|foo.bar baz", "E", "foo.ba|r baz"),
            ("|one two three", "2w", "one two |three"),
            ("|foo\n\nbar", "w", "foo\n|\nbar"),
            ("foo\n|\nbar", "w", "foo\n\n|bar"),
            ("foo\n\n|bar", "b", "foo\n|\nbar"),
            ("|foo\n  bar", "w", "foo\n  |bar"),
            ("one tw|o", "w", "one tw|o"),
            ("|ğüş İı x", "w", "ğüş |İı x"),
            ("ğüş |İı x", "e", "ğüş İ|ı x"),
            ("|a 😀 b", "ww", "a 😀 |b"),
        ])
    }

    func testLineMotions() {
        check([
            ("|abc\ndef", "j", "abc\n|def"),
            ("abc\n|def", "k", "|abc\ndef"),
            ("abcdef|g\nab\nabcdefgh", "jj", "abcdefg\nab\nabcdef|gh"),
            ("abcdef|g\nab\nabcdefgh", "j", "abcdefg\na|b\nabcdefgh"),
            ("a|bc\n\nabc", "jj", "abc\n\na|bc"),
            ("a|bc", "$", "ab|c"),
            ("|abc\nabcdef", "$j", "abc\nabcde|f"),
            ("  a|bc", "0", "|  abc"),
            ("|  abc", "^", "  |abc"),
            ("a\nb\n|c", "gg", "|a\nb\nc"),
            ("|a\n  b\n  c", "G", "a\n  b\n  |c"),
            ("|a\nb\nc", "2G", "a\n|b\nc"),
            ("|a\nb\nc", "3gg", "a\nb\n|c"),
            ("|a\n  b", "+", "a\n  |b"),
            ("a\n  |b", "-", "|a\n  b"),
            ("|a\n", "j", "a\n|"),
            ("|a", "j", "|a"),
            ("|abc", "lll", "ab|c"),
            ("a|bc", "hh", "|abc"),
            ("|a  b  ", "g_", "a  |b  "),
        ])
    }

    func testFindAndPairs() {
        check([
            ("|abcabc", "fc", "ab|cabc"),
            ("|abcabc", "fc;", "abcab|c"),
            ("|abcabc", "fc;,", "ab|cabc"),
            ("|abcabc", "tc", "a|bcabc"),
            ("|abcabc", "tc;", "abca|bc"),
            ("abcab|c", "Fa", "abc|abc"),
            ("abcab|c", "Ta", "abca|bc"),
            ("|abcabc", "2fc", "abcab|c"),
            ("|abc", "fz", "|abc"),
            ("|ağb", "fğ", "a|ğb"),
            ("|a😀b", "f😀", "a|😀b"),
            ("|(a [b] c)", "%", "(a [b] c|)"),
            ("(a [b] c|)", "%", "|(a [b] c)"),
            ("|x (y)", "%", "x (y|)"),
            ("|a\nb\n\nc\nd", "}", "a\nb\n|\nc\nd"),
            ("a\nb\n\nc\n|d", "{", "a\nb\n|\nc\nd"),
            ("|a\nb", "}", "a\n|b"),
        ])
    }

    func testScreenMotions() {
        check([
            ("a\nb\n|c", "H", "|a\nb\nc"),
            ("|a\nb\nc", "L", "a\nb\n|c"),
            ("|a\nb\nc\nd\ne", "M", "a\nb\n|c\nd\ne"),
            ("|a\nb\nc\nd", "<c-d>", "a\nb\n|c\nd"),
            ("a\nb\n|c\nd", "<c-u>", "|a\nb\nc\nd"),
        ])
        let (buffer, engine) = make("|a\nb\nc")
        press("zz", buffer, engine)
        press("zt", buffer, engine)
        XCTAssertEqual(buffer.scrolls, [.cursorToCenter, .cursorToTop])
    }

    // MARK: Operators

    func testDelete() {
        check([
            ("|one two three", "dw", "|two three"),
            ("|a b c d", "3dw", "|d"),
            ("|a b c d", "d3w", "|d"),
            ("foo |bar\nbaz", "dw", "foo| \nbaz"),
            ("|hello world", "de", "| world"),
            ("hello |world", "db", "|world"),
            ("a|bc", "d$", "|a"),
            ("a|bc", "D", "|a"),
            ("|abc\ndef\nghi", "dd", "|def\nghi"),
            ("abc\ndef\n|ghi", "dd", "abc\n|def"),
            ("a\n|b\n", "dd", "a\n|"),
            ("|a\nb\nc\nd", "3dd", "|d"),
            ("|a\nb\nc", "dj", "|c"),
            ("a\nb\n|c", "dk", "|a"),
            ("|a\nb\nc", "ggdG", "|"),
            ("x\n  |a\n  b", "dd", "x\n  |b"),
            ("a|bc", "x", "a|c"),
            ("ab|c", "x", "a|b"),
            ("a|bcd", "2x", "a|d"),
            ("a|bc", "X", "|bc"),
            ("|", "dd", "|"),
            ("|", "x", "|"),
            ("|abc", "dfb", "|c"),
            ("|abc", "dtc", "|c"),
            ("|abc\n\nx", "d}", "|\nx"),
            ("|(a b)", "d%", "|"),
            ("|😀a", "x", "|a"),
            ("a|😀", "x", "|a"),
            ("|e\u{301}x", "x", "|x"),
            ("|ğüş", "x", "|üş"),
        ])
    }

    func testChange() {
        check([
            ("foo |bar baz", "ciwqux<esc>", "foo qu|x baz"),
            ("foo |bar baz", "cwqux<esc>", "foo qu|x baz"),
            ("foo b|ar baz", "cwX<esc>", "foo b|X baz"),
            ("foo |b baz", "cwX<esc>", "foo |X baz"),
            ("a|bc", "Cxy<esc>", "ax|y"),
            ("a|bc", "sX<esc>", "a|Xc"),
            ("  a|bc\nd", "ccxy<esc>", "  x|y\nd"),
            ("a|bc", "Sxy<esc>", "x|y"),
            ("|", "sx<esc>", "|x"),
            ("|ab cd", "c2wX<esc>", "|X"),
        ])
    }

    func testReplaceAndCase() {
        check([
            ("a|bc", "rX", "a|Xc"),
            ("|abc", "3rX", "XX|X"),
            ("|abc", "4rX", "|abc"),
            ("a|bc", "r<cr>", "a\n|c"),
            ("|abc", "~~~", "AB|C"),
            ("|ı", "~", "|I"),
            ("|abc def", "gUiw", "|ABC def"),
            ("|Abc", "g~~", "|aBC"),
            ("|ABC Def", "guu", "|abc def"),
            ("|abc def", "gUw", "|ABC def"),
            ("|abcd", "Rxy<esc>", "x|ycd"),
            ("|ab", "Rxyz<esc>", "xy|z"),
            ("|abcd", "Rxy<bs><esc>", "|xbcd"),
        ])
    }

    func testYankAndPut() {
        check(
            [
                ("|abc\ndef", "yyp", "abc\n|abc\ndef"),
                ("|abc\ndef", "yyP", "|abc\nabc\ndef"),
                ("abc\n|def", "yyp", "abc\ndef\n|def"),
                ("|abc\ndef", "Yjp", "abc\ndef\n|abc"),
                ("|abc", "ylp", "a|abc"),
                ("|abc def", "yiwP", "ab|cabc def"),
                ("|abc", "yl3p", "aaa|abc"),
                ("|abc def", "dwP", "abc| def"),
                ("|a\nb", "ddp", "b\n|a"),
                ("|a\nb\nc", "yj2jp", "a\nb\nc\n|a\nb"),
                ("|ab cd", "\"ayiwwdiw\"aP", "aba|b "),
                ("|ab cd", "\"_dwP", "|Xcd"),
                ("|ab", "p", "a|Xb"),
                ("|", "p", "|X"),
            ], clipboard: "X")
        // A clipboard of more than one character: the cursor on its last.
        check([("|ab", "p", "aX|Yb")], clipboard: "XY")

        let (buffer, engine) = make("|hello world")
        press("yiw", buffer, engine)
        XCTAssertEqual(buffer.clipboard, "hello")
        press("dd", buffer, engine)
        XCTAssertEqual(buffer.clipboard, "hello world\n")
        // Clipboard set elsewhere is charwise; the engine's own line yank is linewise.
        buffer.clipboard = "x\n"
        press("p", buffer, engine)
        XCTAssertEqual(buffer.storage as String, "x\n")
    }

    // MARK: Text objects

    func testTextObjects() {
        check([
            ("f(a, |b)", "di(", "f(|)"),
            ("f(a, |b)", "da(", "|f"),
            ("f(a, |b)", "dib", "f(|)"),
            ("|f(a, b)", "f(ci(x<esc>", "f(|x)"),
            ("x |(a)", "di(", "x (|)"),
            ("|f(a)", "ci(z<esc>", "f(|z)"),
            ("(a (b|) c)", "di(", "(a (|) c)"),
            ("(a (b|) c)", "2di(", "(|)"),
            ("{\n    fo|o\n}", "di{", "{\n|}"),
            ("{\n    fo|o\n}", "ci{x<esc>", "{\n|x\n}"),
            ("[1, |2]", "di[", "[|]"),
            ("<a|b>", "di<", "<|>"),
            ("say \"hel|lo\" now", "di\"", "say \"|\" now"),
            ("say \"hel|lo\" now", "da\"", "say |now"),
            ("a \"b\" |c \"d\"", "ci\"X<esc>", "a \"b\" c \"|X\""),
            ("x = 'a|b'", "ci'z<esc>", "x = '|z'"),
            ("a `b|c` d", "di`", "a `|` d"),
            ("foo b|ar baz", "diw", "foo | baz"),
            ("foo b|ar baz", "daw", "foo |baz"),
            ("foo b|ar", "daw", "fo|o"),
            ("a.b|.c d", "diW", "| d"),
            ("a.b|.c d", "daW", "|d"),
            ("|a b c", "d2aw", "|c"),
            ("a\nb|b\n\nc", "dap", "|c"),
            ("a\nb|b\n\nc", "dip", "|\nc"),
            ("x\n\n|a\nb", "dap", "|x"),
        ])
        let (buffer, engine) = make("a\n\n|b\nc")
        press("yip", buffer, engine)
        XCTAssertEqual(buffer.clipboard, "b\nc\n")
    }

    // MARK: Visual

    func testVisual() {
        check(
            [
                ("|abc def", "vlld", "| def"),
                ("|abc\ndef\nghi", "vjd", "|ef\nghi"),
                ("|abc\ndef\nghi", "Vjd", "|ghi"),
                ("|abc\ndef", "Vyp", "abc\n|abc\ndef"),
                ("|abc def", "veU", "|ABC def"),
                ("|ABC", "vlu", "|abC"),
                ("|abc", "vlohd", "|c"),
                ("|ab\ncd", "Vj>", "    |ab\n    cd"),
                ("|abc\ndef", "v$d", "|def"),
                ("|abc", "vlrx", "|xxc"),
                ("|a\nb\nc", "VjjJ", "a b| c"),
                ("|abc def", "vlywgvd", "|c def"),
                ("a|bc", "vlp", "a|X"),
                ("((a|b))", "vi(i(d", "(|)"),
                ("foo b|ar baz", "viwd", "foo | baz"),
                ("|abc def", "vwc<esc>", "|ef"),
                ("|a\nb\nc", "VjD", "|c"),
                ("|ab\ncd", "Vjcx<esc>", "|x"),
                ("|abc", "vl<esc>", "a|bc"),
                ("|abc\nd", "Vx", "|d"),
                ("a|bc", "vy", "a|bc"),
            ], clipboard: "X")

        let (buffer, engine) = make("|abc")
        XCTAssertEqual(engine.mode, .normal)
        press("v", buffer, engine)
        XCTAssertEqual(engine.mode, .visual)
        XCTAssertEqual(engine.statusText, "-- VISUAL --")
        press("l", buffer, engine)
        XCTAssertEqual(buffer.selection, NSRange(location: 0, length: 2))
        press("V", buffer, engine)
        XCTAssertEqual(engine.mode, .visualLine)
        XCTAssertEqual(engine.statusText, "-- VISUAL LINE --")
        press("<esc>", buffer, engine)
        XCTAssertEqual(engine.mode, .normal)
    }

    // MARK: Repeat and undo

    func testDotRepeat() {
        check([
            ("|a b c d", "dw.", "|c d"),
            ("|a b c d", "dw2.", "|d"),
            ("|abc\nabc", "ciwX<esc>j.", "X\n|X"),
            ("|a\nb\nc", "Ax<esc>j.", "ax\nb|x\nc"),
            ("|a\nb", ">>.", "        |a\nb"),
            ("|abc def", "x.", "|c def"),
            ("|aa\nbb", "ix<esc>j.", "xaa\n|xbb"),
            ("|ab\ncd\nef", "ddj.", "|cd"),
            ("|abc\nabc", "vlUj.", "ABc\n|ABc"),
            ("|abc", "3ix<esc>", "xx|xabc"),
            ("|a\nb", "ix<esc>j3.", "xa\nxx|xb"),
            ("|abc\nabc", "Rxy<esc>j0.", "xyc\nx|yc"),
            ("|a\nb", "ox<esc>.", "a\nx\n|x\nb"),
        ])
    }

    func testUndoRedo() {
        check([
            ("|abc", "ix<esc>u", "|abc"),
            ("|abc", "ix<esc>u<c-r>", "|xabc"),
            ("|a b c", "dwdwuu", "|a b c"),
            ("|a b c", "dwdw2u", "|a b c"),
            ("|a\nb\nc", "3ddu", "|a\nb\nc"),
            ("|abc def", "ciwxyz<esc>u", "|abc def"),
            ("|a b c", "dw.u", "|b c"),
            ("|ab", "ox<cr>y<esc>u", "a|b"),
        ])
    }

    // MARK: Insert

    func testInsertCommands() {
        check([
            ("a|bc", "iX<esc>", "a|Xbc"),
            ("a|bc", "aX<esc>", "ab|Xc"),
            ("  a|bc", "IX<esc>", "  |Xabc"),
            ("  a|bc", "gIX<esc>", "|X  abc"),
            ("a|bc", "AX<esc>", "abc|X"),
            ("|  ab\ncd", "oxy<esc>", "  ab\n  x|y\ncd"),
            ("a|b", "Oxy<esc>", "x|y\nab"),
            ("|f {", "ox<esc>", "f {\n    |x"),
            ("|a", "3ox<esc>", "a\nx\nx\n|x"),
            ("  |a", "o<esc>", "  a\n|"),
            ("|", "ix<esc>", "|x"),
            ("|", "o<esc>", "\n|"),
            ("|abc", "i<esc>", "|abc"),
            ("a|bc", "i<esc>", "|abc"),
            ("|abc", "ax<bs>y<esc>", "a|ybc"),
        ])
        let (buffer, engine) = make("|abc")
        XCTAssertTrue(engine.handle(VimKey("i")))
        XCTAssertEqual(engine.mode, .insert)
        XCTAssertEqual(engine.statusText, "-- INSERT --")
        XCTAssertFalse(engine.handle(VimKey("x")), "insert-mode typing is the text view's")
        XCTAssertFalse(engine.handle(VimKey("s", modifiers: .command)), "⌘ shortcuts stay the app's")
        XCTAssertTrue(engine.handle(VimKey("[", modifiers: .control)))
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertFalse(engine.handle(VimKey("s", modifiers: .command)))
        _ = buffer
    }

    // MARK: Indent and join

    func testIndentAndJoin() {
        check([
            ("|a\nb", ">>", "    |a\nb"),
            ("    |a", "<<", "|a"),
            ("\t|a", "<<", "|a"),
            ("  |a", "<<", "|a"),
            ("|a\nb", "2>>", "    |a\n    b"),
            ("|a\n\nb", ">2j", "    |a\n\n    b"),
            ("|a\nb", "==", "|a\nb"),
            ("|a\n  b", "J", "a| b"),
            ("|a\nb\nc", "3J", "a b| c"),
            ("|a\nb", "gJ", "a|b"),
            ("|a\n)", "J", "a|)"),
            ("|a \nb", "J", "a |b"),
            ("|a", "J", "|a"),
            ("|a\n\nb", "J", "|a\nb"),
        ])
    }

    // MARK: Search

    func testSearch() {
        check([
            ("|foo bar foo baz foo", "/foo<cr>", "foo bar |foo baz foo"),
            ("|foo bar foo baz foo", "/foo<cr>n", "foo bar foo baz |foo"),
            ("|foo bar foo baz foo", "/foo<cr>nn", "|foo bar foo baz foo"),
            ("|foo bar foo baz foo", "/foo<cr>N", "|foo bar foo baz foo"),
            ("foo bar |baz", "?foo<cr>", "|foo bar baz"),
            ("foo bar |baz", "?foo<cr>N", "|foo bar baz"),
            ("|foo bar foo", "*", "foo bar |foo"),
            ("foo bar |foo", "#", "|foo bar foo"),
            ("|foobar foo", "*", "|foobar foo"),
            ("f|oo foo", "*", "foo |foo"),
            ("|Foo foo", "/foo<cr>", "Foo |foo"),
            ("|x Foo foo", "/Foo<cr>n", "x |Foo foo"),
            ("|a1 b22", "/\\d+<cr>", "a|1 b22"),
            ("|ab x", "/x<cr>0dn", "|x"),
            ("|abc", "/zz<cr>", "|abc"),
            ("|a\nfoo", "/fo<bs><bs><bs>", "|a\nfoo"),
            ("|ab ab", "/ab<cr>/<cr>", "|ab ab"),
            ("|ğüş x ğüş", "*", "ğüş x |ğüş"),
        ])
        let (buffer, engine) = make("|abc")
        press("/z", buffer, engine)
        XCTAssertEqual(engine.mode, .commandLine)
        XCTAssertEqual(engine.statusText, "/z")
        press("z<cr>", buffer, engine)
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(engine.statusText, "Pattern not found: zz")
        press("l", buffer, engine)
        XCTAssertEqual(engine.statusText, "")
    }

    // MARK: Ex

    func testExCommands() {
        check([
            ("a a\n|a a", ":s/a/b/g<cr>", "a a\n|b b"),
            ("a a\n|a a", ":s/a/b<cr>", "a a\n|b a"),
            ("|a a\na a", ":%s/a/b/g<cr>", "b b\n|b b"),
            ("|x\na a\nx", ":%s/a/b/g<cr>", "x\n|b b\nx"),
            ("|ab cd", ":s/(\\w+) (\\w+)/\\2 \\1/<cr>", "|cd ab"),
            ("|ab", ":s/b/[&]/<cr>", "|a[b]"),
            ("|a/b", ":s/\\//-/<cr>", "|a-b"),
            ("|a\na\na", "Vj:s/a/b/<cr>", "b\n|b\na"),
            ("|a\na\na", ":1,2s/a/c/<cr>", "c\n|c\na"),
            ("|A a", ":s/a/x/gi<cr>", "|x x"),
            ("|a\nb\nc\nd", ":3<cr>", "a\nb\n|c\nd"),
            ("|a\nb\nc\nd", ":$<cr>", "a\nb\nc\n|d"),
            ("|a\nb", ":99<cr>", "a\n|b"),
            ("|abc", ":s/x/y/<cr>", "|abc"),
            ("|a\nb", ":%s/a/x\\ny/<cr>", "|x\ny\nb"),
            ("|cost", ":s/cost/$5/<cr>", "|$5"),
        ])
        var seen: [String] = []
        let (buffer, engine) = make("|abc")
        engine.exCommand = { command in
            seen.append(command)
            return command == "nope" ? "Not an editor command: nope" : nil
        }
        press(":w<cr>:wq<cr>:x<cr>:q<cr>", buffer, engine)
        XCTAssertEqual(seen, ["w", "wq", "x", "q"])
        press(":nope<cr>", buffer, engine)
        XCTAssertEqual(engine.statusText, "Not an editor command: nope")
        press(":abc<bs><bs><bs><bs>", buffer, engine)
        XCTAssertEqual(engine.mode, .normal)
        XCTAssertEqual(seen.count, 5)
    }

    // MARK: Marks, counts, status

    func testMarksAndStatus() {
        check([
            ("a|bc\ndef", "majj`a", "a|bc\ndef"),
            ("  a|bc\ndef", "maj'a", "  |abc\ndef"),
            ("|a\nb\nc", "G``", "|a\nb\nc"),
            ("a|bc\ndef", "mbjd`b", "a|ef"),
        ])
        let (buffer, engine) = make("|a b c")
        var statuses: [String] = []
        var modes: [VimMode] = []
        engine.onStatusChange = { statuses.append($0) }
        engine.onModeChange = { modes.append($0) }
        press("2d", buffer, engine)
        XCTAssertEqual(engine.statusText, "2d")
        press("<esc>", buffer, engine)
        XCTAssertEqual(engine.statusText, "")
        XCTAssertEqual(buffer.storage as String, "a b c")
        press("\"a", buffer, engine)
        XCTAssertEqual(engine.pendingKeys, "\"a")
        press("<esc>i", buffer, engine)
        XCTAssertEqual(statuses, ["2", "2d", "", "\"", "\"a", "", "-- INSERT --"])
        XCTAssertEqual(modes, [.insert])
    }

    func testSelectionFromOutside() {
        let (buffer, engine) = make("|abc def")
        buffer.selection = NSRange(location: 0, length: 3)
        engine.selectionDidChange()
        XCTAssertEqual(engine.mode, .visual)
        press("d", buffer, engine)
        XCTAssertEqual(buffer.storage as String, " def")
        buffer.selection = NSRange(location: 4, length: 0)  // past the end: a click
        engine.selectionDidChange()
        XCTAssertEqual(buffer.selection.location, 3)
    }

    /// Every scan is local: a 4 MB file takes the big moves in no time.
    func testLargeFileStaysFast() {
        var line = String(repeating: "lorem ipsum dolor sit amet ", count: 3) + "\n"
        line += "\n"
        let big = String(repeating: line, count: 50_000) + "needle\n"
        let (buffer, engine) = make("|" + big)
        XCTAssertGreaterThan(buffer.storage.length, 4_000_000)
        buffer.visible = NSRange(location: 0, length: 2000)
        let start = Date()
        press("G", buffer, engine)
        XCTAssertEqual(engine.cursor, buffer.storage.length)
        press("gg/needle<cr>", buffer, engine)
        XCTAssertEqual(buffer.storage.substring(with: NSRange(location: engine.cursor, length: 6)), "needle")
        press("?amet<cr>n}{jjkk<c-d><c-u>Hwwbe%dd", buffer, engine)
        press("u", buffer, engine)
        press("gg50000Gdip", buffer, engine)
        press(":20000<cr>", buffer, engine)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
