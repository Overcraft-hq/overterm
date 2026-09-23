import XCTest

@testable import Terminus

final class GitStatusTests: XCTestCase {
    func testParsesKindsAndStaging() {
        let output = " M src/a.swift\0M  staged.swift\0A  new.swift\0 D gone.swift\0?? scratch.txt\0UU conflict.swift\0"
        let files = GitStatus.parse(porcelainZ: output)
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["src/a.swift"]?.kind, .modified)
        XCTAssertEqual(byPath["src/a.swift"]?.isStaged, false)
        XCTAssertEqual(byPath["staged.swift"]?.isStaged, true)
        XCTAssertEqual(byPath["new.swift"]?.kind, .added)
        XCTAssertEqual(byPath["gone.swift"]?.kind, .deleted)
        XCTAssertEqual(byPath["scratch.txt"]?.kind, .untracked)
        XCTAssertEqual(byPath["scratch.txt"]?.isStaged, false)
        XCTAssertEqual(byPath["conflict.swift"]?.kind, .conflicted)
    }

    func testStageState() {
        let files = GitStatus.parse(porcelainZ: "M  full.swift\0MM partial.swift\0 M none.swift\0?? new.txt\0")
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.stageState) })
        XCTAssertEqual(byPath["full.swift"], .full)
        XCTAssertEqual(byPath["partial.swift"], .partial)
        XCTAssertEqual(byPath["none.swift"], ChangedFile.StageState.none)
        XCTAssertEqual(byPath["new.txt"], ChangedFile.StageState.none)
    }

    func testRenameConsumesItsOriginalPath() {
        let files = GitStatus.parse(porcelainZ: "R  new name.swift\0old name.swift\0 M after.swift\0")
        XCTAssertEqual(files.map(\.path), ["after.swift", "new name.swift"])
        XCTAssertEqual(files.first { $0.kind == .renamed }?.originalPath, "old name.swift")
    }

    func testNumstat() {
        let stats = GitStatus.parse(numstatZ: "3\t1\tsrc/a.swift\0-\t-\tlogo.png\0" + "2\t0\t\0old.swift\0new.swift\0")
        XCTAssertEqual(stats["src/a.swift"]?.added, 3)
        XCTAssertEqual(stats["src/a.swift"]?.removed, 1)
        XCTAssertNotNil(stats["logo.png"])
        XCTAssertNil(stats["logo.png"]?.added ?? nil, "binary has no counts")
        XCTAssertEqual(stats["new.swift"]?.added, 2)
    }
}

final class UnifiedDiffTests: XCTestCase {
    private let diff = """
        diff --git a/a.swift b/a.swift
        index 111..222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -10,4 +10,5 @@ struct A {
         let x = 1
        -let y = 2
        +let y = 3
        +let z = 4
         }
        \\ No newline at end of file

        """

    func testClassifiesAndNumbersLines() {
        let (lines, truncated) = UnifiedDiff.parse(diff)
        XCTAssertFalse(truncated)
        XCTAssertEqual(lines.map(\.kind), [.meta, .meta, .meta, .meta, .hunk, .context, .removed, .added, .added, .context, .meta])
        let context = lines[5]
        XCTAssertEqual(context.text, "let x = 1")
        XCTAssertEqual([context.oldNumber, context.newNumber], [10, 10])
        XCTAssertEqual(lines[6].oldNumber, 11)
        XCTAssertNil(lines[6].newNumber)
        XCTAssertEqual([lines[7].newNumber, lines[8].newNumber], [11, 12])
        XCTAssertEqual([lines[9].oldNumber, lines[9].newNumber], [12, 13])
    }

    func testHunkStarts() {
        XCTAssertEqual(UnifiedDiff.hunkStarts("@@ -1 +1 @@").0, 1)
        XCTAssertEqual(UnifiedDiff.hunkStarts("@@ -0,0 +1,3 @@").1, 1)
        XCTAssertEqual(UnifiedDiff.hunkStarts("@@ -120,7 +130,9 @@ x").0, 120)
        XCTAssertEqual(UnifiedDiff.hunkStarts("@@ -120,7 +130,9 @@ x").1, 130)
    }

    func testTruncatesHugeDiffs() {
        let (lines, truncated) = UnifiedDiff.parse(diff, limit: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(truncated)
    }
}
