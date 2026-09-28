import XCTest

@testable import Terminus

final class RecentlyUsedTests: XCTestCase {
    func testKeepsOnlyTheMostRecentlySet() {
        var cache = RecentlyUsed<Int, String>(capacity: 3)
        for i in 1...3 { cache[i] = "\(i)" }
        cache[1] = "one again"  // 1 is recent now; 2 is the oldest
        cache[4] = "4"
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache[2])
        XCTAssertEqual(cache[1], "one again")
        XCTAssertEqual(cache[3], "3")
        XCTAssertEqual(cache[4], "4")
        cache[3] = nil
        XCTAssertEqual(cache.count, 2)
    }
}

extension RecentlyUsedTests {
    /// The reader itself, not just the type: 130 transcripts read, 120 kept.
    func testTheUsageReaderKeepsTheLatestTranscriptsOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-lru-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let reader = ClaudeUsageReader()
        for i in 0..<130 {
            let file = dir.appendingPathComponent("s\(i).jsonl")
            try Data("{}\n".utf8).write(to: file)
            _ = reader.usage(of: file)
        }
        XCTAssertEqual(reader.trackedTranscripts, 120)
    }
}
