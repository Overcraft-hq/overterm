import XCTest

@testable import Overterm

/// A note read as Obsidian reads it: properties, links, tags, headings,
/// tasks — and nothing taken from code.
final class NoteParserTests: XCTestCase {
    func testFrontmatterBecomesProperties() {
        let doc = NoteParser.parse(
            """
            ---
            title: Plan
            tags: [work, project/overterm]
            aliases:
              - The plan
            done: false
            count: 3
            ---
            # Heading
            """)
        XCTAssertEqual(doc.properties["title"], .text("Plan"))
        XCTAssertEqual(doc.properties["done"], .bool(false))
        XCTAssertEqual(doc.properties["count"], .number(3))
        XCTAssertEqual(doc.allTags, ["work", "project/overterm"])
        XCTAssertEqual(doc.aliases, ["The plan"])
        XCTAssertEqual(doc.headings.first?.line, 8)
        XCTAssertEqual(doc.title, "Heading")
    }

    func testWikilinksWithHeadingsBlocksAliasesAndEmbeds() {
        let text = "See [[Folder/Note#Part|this]], [[Other#^abc]] and ![[image.png]]."
        let doc = NoteParser.parse(text)
        XCTAssertEqual(doc.links.count, 3)
        XCTAssertEqual(doc.links[0].target, "Folder/Note")
        XCTAssertEqual(doc.links[0].heading, "Part")
        XCTAssertEqual(doc.links[0].alias, "this")
        XCTAssertEqual((text as NSString).substring(with: doc.links[0].range), "[[Folder/Note#Part|this]]")
        XCTAssertEqual(doc.links[1].block, "abc")
        XCTAssertTrue(doc.links[2].isEmbed)
        XCTAssertEqual(doc.links[2].target, "image.png")
    }

    func testMarkdownLinksToTheVaultButNotTheWeb() {
        let doc = NoteParser.parse("[a](My%20Note.md#Top) [b](https://x.dev) ![c](assets/p.png) [d](#local)")
        XCTAssertEqual(doc.links.map(\.target), ["My Note.md", "assets/p.png"])
        XCTAssertEqual(doc.links[0].heading, "Top")
        XCTAssertTrue(doc.links[1].isEmbed && doc.links[1].isMarkdown)
    }

    func testTagsFollowObsidiansRules() {
        let doc = NoteParser.parse("#todo and #área/sub, not a#b, not #123, (#paren) `#code`\n# Heading")
        XCTAssertEqual(doc.allTags, ["todo", "área/sub", "paren"])
    }

    func testNothingIsReadFromCode() {
        let doc = NoteParser.parse(
            """
            ```swift
            // [[NotALink]] #nottag
            # not a heading
            - [ ] not a task
            ```
            `[[inline]]` [[Real]]
            ~~~
            unterminated #x
            """)
        XCTAssertEqual(doc.links.map(\.target), ["Real"])
        XCTAssertTrue(doc.tags.isEmpty)
        XCTAssertTrue(doc.headings.isEmpty)
        XCTAssertTrue(doc.tasks.isEmpty)
    }

    func testTasksKnowWhereTheirStatusIs() {
        let text = "intro\n- [ ] one\n  * [x] two ^blk\n1. [/] three\n- [] not"
        let doc = NoteParser.parse(text)
        XCTAssertEqual(doc.tasks.map(\.text), ["one", "two ^blk", "three"])
        XCTAssertEqual(doc.tasks.map(\.isDone), [false, true, false])
        XCTAssertEqual(doc.tasks.map(\.line), [1, 2, 3])
        for task in doc.tasks { XCTAssertEqual((text as NSString).substring(with: task.statusRange), String(task.status)) }
        XCTAssertEqual(doc.blockIDs, ["blk"])
    }

    func testHeadingsAndCRLF() {
        let doc = NoteParser.parse("---\r\na: 1\r\n---\r\n## Two ##\r\n#Not\r\n###### Six\r\n")
        XCTAssertEqual(doc.properties["a"], .number(1))
        XCTAssertEqual(doc.headings.map(\.text), ["Two", "Six"])
        XCTAssertEqual(doc.headings.map(\.level), [2, 6])
        XCTAssertNil(doc.title)
    }

    func testAnUnclosedFrontmatterIsText() {
        let doc = NoteParser.parse("---\nnot: closed\n# Heading")
        XCTAssertNil(doc.frontmatter)
        XCTAssertEqual(doc.headings.map(\.text), ["Heading"])
    }

    /// Every note of the vault on this Mac, if there is one: read, nothing written.
    func testEveryNoteOfAVaultOnThisMacParses() throws {
        guard let root = ObsidianVaults.known().first else { throw XCTSkip("No Obsidian vault on this Mac") }
        let notes = NoteFiles.tree(of: NotesVault(root: root)).allNotes.filter { !$0.isEvicted }
        for note in notes {
            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
            let doc = NoteParser.parse(text)
            let ns = text as NSString
            for link in doc.links { XCTAssertLessThanOrEqual(NSMaxRange(link.range), ns.length) }
            for task in doc.tasks { XCTAssertEqual(ns.substring(with: task.statusRange), String(task.status), note.url.path) }
        }
        XCTAssertFalse(notes.isEmpty)
    }
}
