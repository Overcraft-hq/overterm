import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermNotes

final class NoteWritingTests: XCTestCase {
    private func enter(_ text: String) -> String? {
        let caret = (text as NSString).range(of: "|").location
        let plain = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "")
        guard let edit = NoteWriting.newline(in: plain as NSString, selection: NSRange(location: caret, length: 0)) else { return nil }
        let applied = NSMutableString(string: edit.applied(to: plain))
        applied.insert("|", at: edit.selections[0].location)
        return applied as String
    }

    func testReturnCarriesAListOn() {
        XCTAssertEqual(enter("- milk|"), "- milk\n- |")
        XCTAssertEqual(enter("  * eggs|"), "  * eggs\n  * |")
        XCTAssertEqual(enter("9. nine|"), "9. nine\n10. |")
        XCTAssertEqual(enter("1) one|"), "1) one\n2) |")
        XCTAssertEqual(enter("- [x] shipped|"), "- [x] shipped\n- [ ] |", "a task's box starts empty")
        XCTAssertEqual(enter("> said|"), "> said\n> |")
        XCTAssertEqual(enter("- split| here"), "- split\n- | here")
    }

    func testAnEmptyItemEndsTheList() {
        XCTAssertEqual(enter("- a\n- |"), "- a\n|")
        XCTAssertEqual(enter("- a\n- [ ] |"), "- a\n|")
        XCTAssertEqual(enter("> a\n> |"), "> a\n|")
    }

    func testOtherLinesAreLeftToReturn() {
        XCTAssertNil(enter("plain|"))
        XCTAssertNil(enter("-|"), "no space: not a list")
        XCTAssertNil(enter("|- a"), "the caret before the marker")
        XCTAssertNil(enter("```\n- in code|\n```"), "inside a fence")
        XCTAssertEqual(enter("```\ncode\n```\n- after|"), "```\ncode\n```\n- after\n- |")
    }

    func testAURLPastedOverASelectionIsALink() {
        let text = "see the docs here" as NSString
        let docs = text.range(of: "docs")
        let edit = NoteWriting.linkPaste("https://example.com/a?b=1 ", over: docs, in: text)
        XCTAssertEqual(edit?.applied(to: text as String), "see the [docs](https://example.com/a?b=1) here")
        XCTAssertNil(NoteWriting.linkPaste("not a url", over: docs, in: text))
        XCTAssertNil(NoteWriting.linkPaste("https://x.y", over: NSRange(location: 3, length: 0), in: text), "no selection")
    }

    func testSlashCommands() {
        XCTAssertEqual(NoteSlashCommands.matching("tab").first?.label, "Table")
        XCTAssertTrue(NoteSlashCommands.matching("run").contains { $0.label == "Runnable Shell Block" })
        XCTAssertTrue(NoteSlashCommands.matching("dataview").contains { $0.label == "Notes Table" })
        XCTAssertEqual(NoteSlashCommands.matching("").count, NoteSlashCommands.all().count)
        let (text, caret) = NoteSlashCommands.expand("```bash\n$0\n```")
        XCTAssertEqual(text, "```bash\n\n```")
        XCTAssertEqual(caret, 8)
    }

    func testHeadingsFold() {
        let text = "# A\nintro\n## B\nb text\n## C\nc\n# D\nd" as NSString
        let sections = NoteFolding.sections(in: text)
        XCTAssertEqual(sections.map(\.key), ["1|A|0", "2|B|0", "2|C|0", "1|D|0"])
        XCTAssertEqual(text.substring(with: sections[0].body), "intro\n## B\nb text\n## C\nc\n", "to the next heading as high")
        XCTAssertEqual(text.substring(with: sections[1].body), "b text\n")
        XCTAssertEqual(NoteFolding.section(at: text.range(of: "b text").location, in: sections)?.key, "2|B|0", "the nearest heading above")
        XCTAssertEqual(NoteFolding.section(at: 1, in: sections)?.key, "1|A|0", "on the heading line")
    }

    func testRunbookCommands() {
        let note = "# Deploy\n```bash\nmake build\nmake ship\n```\n\n```console\n$ ls -la\ntotal 0\n$ echo hi\nhi\n```\n```python\nprint(1)\n```"
        XCTAssertEqual(NoteRunbook.command(in: note, openingAt: 1), "make build\nmake ship")
        XCTAssertEqual(NoteRunbook.command(in: note, openingAt: 6), "ls -la\necho hi", "console: its $ lines")
        XCTAssertNil(NoteRunbook.command(in: note, openingAt: 12), "not a shell block")
        XCTAssertNil(NoteRunbook.command(in: note, openingAt: 0))
        XCTAssertEqual(NoteRunbook.command(in: note, around: 3), "make build\nmake ship", "the caret inside the block")
        XCTAssertNil(NoteRunbook.command(in: note, around: 0), "outside any block")
    }

    func testNotesTable() throws {
        var index = NotesIndex()
        let now = Date()
        index.set("Projects/Alpha.md", text: "---\nstatus: open\npriority: 2\ntags: [work]\n---\nA", modified: now)
        index.set("Projects/Beta.md", text: "---\nstatus: done\npriority: 1\n---\nB", modified: now)
        index.set("Projects/Gamma.md", text: "---\nstatus: open\npriority: 10\n---\nG", modified: now)
        index.set("Home/Delta.md", text: "---\nstatus: open\n---\nD #work", modified: now)
        let table = NoteQuery.table(for: "TABLE status, priority AS \"P\"\nFROM \"Projects\"\nWHERE status = \"open\"\nSORT priority DESC", over: index)
        XCTAssertNil(table.error)
        XCTAssertEqual(table.columns, ["File", "status", "P"])
        XCTAssertEqual(table.rows.map { $0.map(\.text) }, [["Gamma", "open", "10"], ["Alpha", "open", "2"]], "numbers sort as numbers")
        XCTAssertEqual(table.rows.first?.first?.path, "Projects/Gamma.md")
        let tagged = NoteQuery.table(for: "LIST FROM #work SORT file.name", over: index)
        XCTAssertEqual(tagged.rows.map { $0[0].text }, ["Alpha", "Delta"], "frontmatter's tags and inline ones")
        let either = NoteQuery.table(for: "TABLE WITHOUT ID file.name WHERE priority > 1 OR !priority SORT file.name ASC", over: index)
        XCTAssertEqual(either.columns, ["file.name"])
        XCTAssertEqual(either.rows.map { $0[0].text }, ["Alpha", "Delta", "Gamma"])
        let contained = NoteQuery.table(for: "LIST WHERE contains(tags, \"work\")", over: index)
        XCTAssertEqual(contained.rows.map { $0[0].text }, ["Alpha"])
        let limited = NoteQuery.table(for: "LIST SORT file.name LIMIT 2", over: index)
        XCTAssertEqual(limited.rows.count, 2)
        XCTAssertNotNil(NoteQuery.table(for: "SELECT * FROM notes", over: index).error, "not Dataview: said")
        XCTAssertNotNil(NoteQuery.table(for: "TABLE x WHERE (a = 1", over: index).error)
        XCTAssertEqual(NoteQuery.blocks(in: "x\n```dataview\nLIST\n```\n```\ndataview\n```\n").map(\.line), [1])
    }

    /// The page draws a table by the fence's line in the file — the line
    /// markdown-it gives it plus the frontmatter's — the same key here.
    func testThePayloadCarriesNotesTablesByTheirLine() {
        var index = NotesIndex()
        index.set("A.md", text: "---\nstatus: open\n---\n", modified: Date())
        let text = "---\ntitle: x\n---\n# T\n```dataview\nLIST\n```\n"
        let payload = NoteRenderPayload.make(path: "T.md", text: text, index: index, read: { _ in nil })
        XCTAssertEqual(payload.lineOffset, 3)
        XCTAssertEqual(Array(payload.queries.keys), [4])
        XCTAssertEqual(payload.queries[4]?.rows.map { $0[0].text }.contains("A"), true)
        let json = payload.json(vaultBase: "v", base: "b", breaks: false, dark: true, colors: [:])
        XCTAssertTrue(json.contains("\"queries\":{\"4\""), json)
    }

    /// A note can't take the app down: a LIMIT past Int, a WHERE nesting
    /// ten thousand deep, each a table that says so or stops at 500.
    func testANotesTableCantCrashTheApp() {
        var index = NotesIndex()
        index.set("A.md", text: "x", modified: Date())
        XCTAssertNil(NoteQuery.table(for: "LIST LIMIT 99999999999999999999", over: index).error)
        XCTAssertEqual(try NoteQuery.parse("LIST LIMIT 99999999999999999999").limit, NoteQuery.maxRows)
        let deep = "LIST WHERE " + String(repeating: "(", count: 10_000) + "a"
        XCTAssertEqual(NoteQuery.table(for: deep, over: index).error, "WHERE nests too deep.")
        XCTAssertNotNil(NoteQuery.table(for: "LIST WHERE " + String(repeating: "!", count: 10_000) + "a", over: index).error)
    }

    func testARunGoesToNoTabThatWouldTakeItAsAnAnswer() {
        XCTAssertNotNil(NoteRunbook.refusal(kind: .agent, terraformAsking: false), "an agent's tab: it would be a prompt")
        XCTAssertNotNil(NoteRunbook.refusal(kind: .shell, terraformAsking: true), "Terraform asking: it would be the answer")
        XCTAssertNil(NoteRunbook.refusal(kind: .shell, terraformAsking: false))
        XCTAssertNil(NoteRunbook.refusal(kind: .ssh, terraformAsking: false), "a remote shell: asked, named so")
    }

    func testSlashIsNotOfferedInCode() {
        let text = "```bash\n/usr" as NSString
        XCTAssertTrue(NoteWriting.isInFence(text, at: 8))
        XCTAssertFalse(NoteWriting.isInFence("text\n/tab" as NSString, at: 5))
    }
}
