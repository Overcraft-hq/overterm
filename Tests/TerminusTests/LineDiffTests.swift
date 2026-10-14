import XCTest

@testable import Terminus

final class LineDiffTests: XCTestCase {
    private func hunks(_ base: [String], _ current: [String]) -> [GutterHunk] {
        func text(_ lines: [String]) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }
        return LineDiff.hunks(base: text(base), current: text(current))
    }

    func testTheGutterMarks() {
        XCTAssertEqual(hunks(["a", "b", "c"], ["a", "b", "c"]), [])
        XCTAssertEqual(hunks(["a", "b", "c"], ["a", "x", "b", "c"]), [GutterHunk(kind: .added, lines: 1..<2)])
        XCTAssertEqual(hunks(["a", "b", "c"], ["x", "y", "a", "b", "c"]), [GutterHunk(kind: .added, lines: 0..<2)])
        XCTAssertEqual(hunks(["a", "b", "c"], ["a", "c"]), [GutterHunk(kind: .deleted, lines: 1..<1)])
        XCTAssertEqual(hunks(["a", "b", "c"], ["b", "c"]), [GutterHunk(kind: .deleted, lines: 0..<0)])
        XCTAssertEqual(hunks(["a", "b", "c"], ["a", "b"]), [GutterHunk(kind: .deleted, lines: 2..<2)], "after the last line")
        XCTAssertEqual(hunks(["a", "b", "c"], ["a", "B", "c"]), [GutterHunk(kind: .modified, lines: 1..<2)])
        XCTAssertEqual(hunks(["a", "b", "c"], ["a", "B", "B2", "c"]), [GutterHunk(kind: .modified, lines: 1..<3)])
        XCTAssertEqual(hunks(["a", "b", "c", "d"], ["a", "X", "d"]), [GutterHunk(kind: .modified, lines: 1..<2)])
        XCTAssertEqual(
            hunks(["1", "2", "3", "4", "5", "6", "7"], ["0", "1", "2", "x", "4", "5", "7", "8"]),
            [
                GutterHunk(kind: .added, lines: 0..<1), GutterHunk(kind: .modified, lines: 3..<4), GutterHunk(kind: .deleted, lines: 6..<6),
                GutterHunk(kind: .added, lines: 7..<8),
            ])
    }

    func testEdges() {
        XCTAssertEqual(LineDiff.hunks(base: "", current: ""), [])
        XCTAssertEqual(LineDiff.hunks(base: "", current: "a\nb\n"), [GutterHunk(kind: .added, lines: 0..<2)])
        XCTAssertEqual(LineDiff.hunks(base: "a\nb\n", current: ""), [GutterHunk(kind: .deleted, lines: 0..<0)])
        // A missing trailing newline is no line of its own.
        XCTAssertEqual(LineDiff.hunks(base: "a\nb\n", current: "a\nb"), [])
        XCTAssertEqual(LineDiff.hunks(base: "a\nb", current: "a\nb\nc"), [GutterHunk(kind: .added, lines: 2..<3)])
        // Line endings are part of the line.
        XCTAssertEqual(LineDiff.hunks(base: "a\r\nb\r\n", current: "a\r\nb\n"), [GutterHunk(kind: .modified, lines: 1..<2)])
        XCTAssertEqual(LineDiff.hunks(base: "şey\n😀\n", current: "şey\n😀!\n"), [GutterHunk(kind: .modified, lines: 1..<2)])
        XCTAssertEqual(LineDiff.hunks(base: "a\n\n\nb\n", current: "a\n\nb\n"), [GutterHunk(kind: .deleted, lines: 2..<2)])
    }

    /// Myers finds a shortest edit: the lines it leaves unmarked are as many
    /// as the longest common subsequence has, on random small texts.
    func testUnmarkedLinesAreALongestCommonSubsequence() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let a = (0..<Int.random(in: 0...25, using: &generator)).map { _ in ["a", "b", "c", "d"].randomElement(using: &generator)! }
            let b = (0..<Int.random(in: 0...25, using: &generator)).map { _ in ["a", "b", "c", "d"].randomElement(using: &generator)! }
            let marked = hunks(a, b).filter { $0.kind != .deleted }.reduce(0) { $0 + $1.lines.count }
            XCTAssertEqual(b.count - marked, lcs(a, b), "\(a) → \(b)")
            // Hunks are in order and don't overlap.
            var end = 0
            for hunk in hunks(a, b) {
                XCTAssertGreaterThanOrEqual(hunk.lines.lowerBound, end)
                end = hunk.lines.upperBound
            }
        }
    }

    private func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }

    /// A 50 000-line file with a few edits: well under a frame in release
    /// (asserted there; a debug build is only bounded loosely).
    func testFiftyThousandLinesWithAFewEditsIsFast() {
        let base = (0..<50_000).map { "    let line\($0) = compute(\($0)) // some comment" }
        var current = base
        current[100] = "changed"
        current.insert("added", at: 20_000)
        current.remove(at: 30_000)
        current[45_000] = "changed too"
        current.insert(contentsOf: ["x", "y", "z"], at: 49_000)
        let baseText = base.joined(separator: "\n") + "\n"
        let currentText = current.joined(separator: "\n") + "\n"
        var result: [GutterHunk] = []
        let elapsed = ContinuousClock().measure { result = LineDiff.hunks(base: baseText, current: currentText) }
        print("LineDiff, 50 000 lines, 5 edits: \(elapsed)")
        XCTAssertEqual(
            result,
            [
                GutterHunk(kind: .modified, lines: 100..<101), GutterHunk(kind: .added, lines: 20_000..<20_001),
                GutterHunk(kind: .deleted, lines: 30_000..<30_000), GutterHunk(kind: .modified, lines: 45_000..<45_001),
                GutterHunk(kind: .added, lines: 49_000..<49_003),
            ])
        #if DEBUG
            XCTAssertLessThan(elapsed, .milliseconds(500))
        #else
            XCTAssertLessThan(elapsed, .milliseconds(15))
        #endif
    }

    /// Two unrelated texts: past the edit-distance cap, the middle is one
    /// modified block — quickly, rather than an exact diff slowly.
    func testAnExplodingEditDistanceDegradesToOneModifiedBlock() {
        let base = (0..<20_000).map { "base \($0)" }
        let current = ["same"] + (0..<20_000).map { "current \($0)" } + ["end"]
        var result: [GutterHunk] = []
        let elapsed = ContinuousClock().measure {
            result = hunks(["same"] + base + ["end"], current)
        }
        print("LineDiff, 20 000 lines all changed: \(elapsed)")
        XCTAssertEqual(result, [GutterHunk(kind: .modified, lines: 1..<20_001)])
        XCTAssertLessThan(elapsed, .seconds(5))
    }
}
