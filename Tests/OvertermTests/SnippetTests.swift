import XCTest

@testable import Overterm

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
    func testFirstRunIsEmptyAndChangesPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-snip-\(UUID().uuidString)/snippets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SnippetStore(url: url)
        XCTAssertTrue(store.snippets.isEmpty)
        // Nothing written before there is something to write.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.upsert(Snippet(name: "New", command: "echo hi"))

        let reopened = SnippetStore(url: url)
        XCTAssertEqual(reopened.snippets.map(\.name), ["New"])
    }

    /// The five commands a first run used to be planted with went on showing
    /// up in everyone's list; they are dropped from the file now, and only
    /// the ones nobody touched.
    @MainActor
    func testThePlantedSnippetsAreDroppedButEditedOnesStay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-snip-\(UUID().uuidString)/snippets.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = [
            Snippet(name: "Validate everything", command: "mise run validate"),
            Snippet(name: "Worktrees", command: "git worktree list"),
            // The same name, a command of the user's own.
            Snippet(name: "Rollout status", command: "kubectl rollout status deploy/api"),
            Snippet(name: "Mine", command: "make test"),
        ]
        try JSONEncoder().encode(saved).write(to: url)

        let store = SnippetStore(url: url)
        XCTAssertEqual(store.snippets.map(\.name), ["Rollout status", "Mine"])
        // Written back, so they don't come again.
        XCTAssertEqual(SnippetStore(url: url).snippets.map(\.name), ["Rollout status", "Mine"])
    }

    @MainActor
    func testAnUnreadableFileIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-snip-\(UUID().uuidString)/snippets.json")
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
