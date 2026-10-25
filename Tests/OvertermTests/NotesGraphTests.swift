import XCTest

@testable import Overterm

/// The graph: which notes are in it, which lines join them, and a layout
/// that keeps linked notes together.
final class NotesGraphTests: XCTestCase {
    private var index: NotesIndex {
        var index = NotesIndex()
        index.set("A.md", text: "[[B]] [[C]]", modified: Date())
        index.set("B.md", text: "[[A]] [[D]]", modified: Date())
        index.set("C.md", text: "", modified: Date())
        index.set("D.md", text: "[[Missing]]", modified: Date())
        index.set("Lonely.md", text: "", modified: Date())
        return index
    }

    func testTheWholeVaultAndAnOrphansOption() {
        let graph = NotesGraph.make(from: index)
        XCTAssertEqual(graph.nodes.map(\.path), ["A.md", "B.md", "C.md", "D.md", "Lonely.md"])
        // A–B once, though both link the other; no edge to a missing note.
        XCTAssertEqual(graph.edges.count, 3)
        XCTAssertEqual(graph.nodes.first { $0.path == "A.md" }?.degree, 2)
        XCTAssertEqual(NotesGraph.make(from: index, orphans: false).nodes.count, 4)
    }

    func testALocalGraphGoesAsFarAsAsked() {
        XCTAssertEqual(NotesGraph.make(from: index, center: "C.md", depth: 1).nodes.map(\.path), ["A.md", "C.md"])
        XCTAssertEqual(NotesGraph.make(from: index, center: "C.md", depth: 2).nodes.map(\.path), ["A.md", "B.md", "C.md"])
    }

    func testLinkedNotesLayOutCloserThanTheUnlinked() {
        let graph = NotesGraph.make(from: index)
        func distance(_ a: String, _ b: String) -> CGFloat {
            let p = graph.nodes.first { $0.path == a }!.position
            let q = graph.nodes.first { $0.path == b }!.position
            return hypot(p.x - q.x, p.y - q.y)
        }
        XCTAssertLessThan(distance("A.md", "B.md"), distance("C.md", "Lonely.md"))
        XCTAssertEqual(graph, NotesGraph.make(from: index), "the same vault lays out the same way")
    }
}

extension NotesGraphTests {
    /// The vault on this Mac, if any, lays out in a moment.
    func testAVaultOnThisMacLaysOutQuickly() throws {
        guard let root = ObsidianVaults.known().first else { throw XCTSkip("No Obsidian vault on this Mac") }
        let index = NotesIndex.build(NotesVault(root: root))
        let start = Date()
        let graph = NotesGraph.make(from: index)
        XCTAssertEqual(graph.nodes.count, index.notes.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "\(graph.nodes.count) notes")
    }
}
