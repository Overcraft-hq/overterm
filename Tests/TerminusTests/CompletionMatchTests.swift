import XCTest

@testable import Terminus

final class CompletionMatchTests: XCTestCase {
    private func score(_ candidate: String, _ query: String) -> Int? {
        CompletionMatch.score(candidate: candidate, query: query)?.score
    }

    /// `query` ranks the candidates in this order (best first).
    private func assertRanking(_ query: String, _ candidates: [String], file: StaticString = #filePath, line: UInt = #line) {
        let ranked = candidates.shuffled().sorted { (score($0, query) ?? .min) > (score($1, query) ?? .min) }
        XCTAssertEqual(ranked, candidates, file: file, line: line)
    }

    func testMatching() {
        XCTAssertNil(CompletionMatch.score(candidate: "goToLine", query: "xyz"))
        XCTAssertNil(CompletionMatch.score(candidate: "ab", query: "abc"))
        XCTAssertNil(CompletionMatch.score(candidate: "abc", query: "cb"), "in order only")
        XCTAssertEqual(CompletionMatch.score(candidate: "anything", query: "")?.score, 0)
        XCTAssertEqual(CompletionMatch.score(candidate: "goToLine", query: "gtl")?.matched, [0, 2, 4])
        XCTAssertEqual(CompletionMatch.score(candidate: "GOTOLINE", query: "gtl")?.matched, [0, 2, 4])
        XCTAssertEqual(CompletionMatch.score(candidate: "get_user_name", query: "gun")?.matched, [0, 4, 9])
        // UTF-16 offsets: an emoji is two.
        XCTAssertEqual(CompletionMatch.score(candidate: "😀ab", query: "ab")?.matched, [2, 3])
        // Turkish: İ is an i, Ş an ş.
        XCTAssertEqual(CompletionMatch.score(candidate: "İstanbul", query: "ist")?.matched, [0, 1, 2])
        XCTAssertNotNil(CompletionMatch.score(candidate: "Şehir", query: "şeh"))
    }

    func testRanking() {
        assertRanking("gtl", ["goToLine", "getTitleLabel", "gotoline"])
        assertRanking("con", ["console", "constructor", "reconnect"])
        assertRanking("fb", ["fooBar", "fab"])
        assertRanking("main", ["main.swift", "Sources/main.swift", "domain.swift"])
        assertRanking("gu", ["get_user", "gaugeUnit"])
        // The case typed wins a tie; then the shorter.
        assertRanking("Foo", ["Foo", "foo"])
        assertRanking("abc", ["abc", "abcdef", "abcdefghijkl"])
        // A run beats scattered letters.
        assertRanking("line", ["lineNumber", "lastInputEvent"])
    }

    func testLongCandidatesAreLeftOut() {
        XCTAssertNil(CompletionMatch.score(candidate: String(repeating: "a", count: CompletionMatch.maxCandidateLength + 1), query: "a"))
    }

    // MARK: Buffer words

    func testBufferWordsNearestFirst() {
        let (text, selections) = Marked.parse("alpha beta gam| delta epsilon beta")
        XCTAssertEqual(CompletionMatch.bufferWords(in: text, near: selections[0].location), ["delta", "beta", "epsilon", "alpha"])
    }

    func testBufferWordsAreIdentifiers() {
        let (text, selections) = Marked.parse("ab 12abc snake_case $scope|\n😀 şeyler değişken x1y2 abc-def a.b.c")
        XCTAssertEqual(
            CompletionMatch.bufferWords(in: text, near: selections[0].location),
            ["şeyler", "snake_case", "değişken", "x1y2", "abc", "def"])
        XCTAssertEqual(CompletionMatch.bufferWords(in: "", near: 0), [])
        XCTAssertEqual(CompletionMatch.bufferWords(in: "word", near: 99), [], "the word at the cursor")
    }

    func testBufferWordsOnABigFileAreCappedAndQuick() {
        let text = (0..<200_000).map { "identifier\($0)" }.joined(separator: " ") as NSString
        var words: [String] = []
        let elapsed = ContinuousClock().measure { words = CompletionMatch.bufferWords(in: text, near: text.length / 2) }
        print("bufferWords on \(text.length / 1024) KB: \(elapsed)")
        XCTAssertEqual(words.count, CompletionMatch.maxWords)
        XCTAssertLessThan(elapsed, .seconds(1))
    }
}
