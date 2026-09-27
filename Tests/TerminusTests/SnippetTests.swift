import XCTest

@testable import Terminus

final class SnippetTests: XCTestCase {
    func testPlaceholdersInOrderWithoutRepeats() {
        let s = Snippet(name: "x", command: "deploy {{service}} to {{ env }} then {{service}} again, {{bad name}} {{}}")
        XCTAssertEqual(s.placeholders, ["service", "env"])
    }

    func testFilled() {
        let s = Snippet(name: "x", command: "deploy.sh release {{service}} {{sha}}")
        XCTAssertEqual(s.filled(with: ["service": "llm-service"]), "deploy.sh release llm-service {{sha}}")
    }

    @MainActor
    func testFirstRunSeedsStartersAndChangesPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-snip-\(UUID().uuidString)/snippets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SnippetStore(url: url)
        XCTAssertEqual(store.snippets, SnippetStore.starters)
        var edited = store.snippets[0]
        edited.command = "mise run build"
        store.upsert(edited)
        store.delete(store.snippets[1])
        store.upsert(Snippet(name: "New", command: "echo hi"))

        let reopened = SnippetStore(url: url)
        XCTAssertEqual(reopened.snippets.map(\.command).first, "mise run build")
        XCTAssertEqual(reopened.snippets.count, SnippetStore.starters.count)
        XCTAssertEqual(reopened.snippets.last?.name, "New")
    }

    @MainActor
    func testAnUnreadableFileIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-snip-\(UUID().uuidString)/snippets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{broken".utf8).write(to: url)

        let store = SnippetStore(url: url)
        XCTAssertTrue(store.snippets.isEmpty)
        // The next save used to write over it: every snippet lost to a typo.
        store.upsert(Snippet(name: "new", command: "ls"))
        let aside = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("snippets.unreadable-") && $0.pathExtension == "json" }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try aside.first.map { try String(contentsOf: $0, encoding: .utf8) }, "[{broken")
        XCTAssertEqual(SnippetStore(url: url).snippets.map(\.name), ["new"])
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score("ncl", in: "New Claude Tab"))
        XCTAssertNil(FuzzyMatch.score("xyz", in: "New Claude Tab"))
        XCTAssertEqual(FuzzyMatch.score("", in: "anything"), 0)
    }

    func testWordStartsAndRunsRankHigher() {
        let wordStarts = FuzzyMatch.score("nct", in: "New Claude Tab")!
        let scattered = FuzzyMatch.score("nct", in: "announce it")!
        XCTAssertGreaterThan(wordStarts, scattered)
        XCTAssertGreaterThan(FuzzyMatch.score("dep", in: "Deploy a service")!, FuzzyMatch.score("dep", in: "Toggle dxexp") ?? Int.min)
    }
}
