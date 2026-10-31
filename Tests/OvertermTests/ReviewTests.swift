import XCTest

@testable import Overterm

/// A whole patch cut into files, as `gh pr diff` gives one.
final class ReviewPatchTests: XCTestCase {
    private let patch = """
        diff --git a/Sources/app.swift b/Sources/app.swift
        index 1111111..2222222 100644
        --- a/Sources/app.swift
        +++ b/Sources/app.swift
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
         let c = 4
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 4444444..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/old name.txt b/new name.txt
        similarity index 90%
        rename from old name.txt
        rename to new name.txt
        index 5555555..6666666 100644
        --- a/old name.txt
        +++ b/new name.txt
        @@ -1 +1 @@
        -x
        +y
        diff --git a/logo.png b/logo.png
        index 7777777..8888888 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """

    func testEachFileIsItsOwnPatchWithWhatItsHeaderSays() {
        let files = ReviewPatch.split(patch)
        XCTAssertEqual(files.map(\.file.path), ["Sources/app.swift", "new.txt", "gone.txt", "new name.txt", "logo.png", "run.sh"])
        XCTAssertEqual(files.map(\.file.kind), [.modified, .added, .deleted, .renamed, .modified, .modified])
        XCTAssertEqual(files[3].file.originalPath, "old name.txt")
        XCTAssertEqual(files.map(\.file.added), [1, 2, 0, 1, nil, 0])
        XCTAssertEqual(files.map(\.file.removed), [1, 0, 1, 1, nil, 0])
        XCTAssertTrue(files[0].patch.hasPrefix("diff --git a/Sources/app.swift"))
        XCTAssertTrue(files[0].patch.hasSuffix(" let c = 4\n"))
        // Each patch reads as a diff of its own.
        let parsed = DiffModel.FileDiff(parsing: files[0].patch, path: files[0].file.path)
        XCTAssertEqual(parsed.lines.filter { $0.kind == .added }.map(\.text), ["let b = 3"])
    }

    func testAQuotedNameIsUnquoted() {
        let files = ReviewPatch.split(
            """
            diff --git "a/caf\\303\\251.txt" "b/caf\\303\\251.txt"
            --- "a/caf\\303\\251.txt"
            +++ "b/caf\\303\\251.txt"
            @@ -1 +1 @@
            -a
            +b

            """)
        XCTAssertEqual(files.map(\.file.path), ["café.txt"])
    }

    func testNothingBeforeTheFirstFileIsAFile() {
        XCTAssertEqual(ReviewPatch.split("").count, 0)
        XCTAssertEqual(ReviewPatch.split("warning: something\n").count, 0)
    }
}

/// A diff side by side.
final class SplitDiffTests: XCTestCase {
    private func lines(_ diff: String) -> [DiffLine] { UnifiedDiff.parse(diff).lines.filter { $0.kind != .meta } }

    func testAChangePairsItsRemovalsWithTheAdditionsAfterThem() {
        let rows = SplitDiff.rows(
            lines(
                """
                @@ -1,5 +1,5 @@
                 same
                -old one
                -old two
                -old three
                +new one
                 tail

                """))
        XCTAssertNotNil(rows[0].full)
        XCTAssertEqual(rows[1].left?.text, "same")
        XCTAssertEqual(rows[1].right?.text, "same")
        XCTAssertEqual(rows[2].left?.text, "old one")
        XCTAssertEqual(rows[2].right?.text, "new one")
        // The longer side's rest faces nothing.
        XCTAssertEqual(rows[3].left?.text, "old two")
        XCTAssertNil(rows[3].right)
        XCTAssertEqual(rows[4].left?.text, "old three")
        XCTAssertEqual(rows[5].left?.text, "tail")
        XCTAssertEqual(rows.count, 6)
    }

    func testAnAdditionAloneHasAnEmptyLeft() {
        let rows = SplitDiff.rows(lines("@@ -1 +1,3 @@\n a\n+b\n+c\n"))
        XCTAssertEqual(rows.map { $0.left?.text }, [nil, "a", nil, nil])
        XCTAssertEqual(rows.map { $0.right?.text }, [nil, "a", "b", "c"])
        // Numbers are each side's own.
        XCTAssertEqual(rows[2].right?.newNumber, 2)
    }

    func testRowsTakeTheirFirstLinesId() {
        let parsed = lines("@@ -1,2 +1,2 @@\n-x\n+y\n")
        let rows = SplitDiff.rows(parsed)
        XCTAssertEqual(rows.map(\.id), [parsed[0].id, parsed[1].id])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}

final class ReviewSourceTests: XCTestCase {
    func testTitlesShortenShasAndKeepNames() {
        let sha = String(repeating: "a", count: 40)
        XCTAssertEqual(ReviewSource.commits(from: sha, to: sha).title, "aaaaaaa")
        XCTAssertEqual(ReviewSource.range(base: "main", head: "feat/x").title, "main…feat/x")
        XCTAssertEqual(ReviewSource.pullRequest(number: 12).title, "#12")
        XCTAssertEqual(ReviewSource.branch(mergeBase: sha, base: "origin/main", branch: "feat/x").title, "feat/x")
    }

    func testFilesAreListedByFolderThenName() {
        func file(_ path: String) -> ChangedFile { ChangedFile(path: path, originalPath: nil, kind: .modified, isStaged: false, hasUnstaged: false) }
        let ordered = ReviewModel.ordered(["src/ab.swift", "src/a/x.swift", "src/a.swift", "README.md"].map(file))
        XCTAssertEqual(ordered.map(\.path), ["README.md", "src/a.swift", "src/ab.swift", "src/a/x.swift"])
    }
}

/// Every git source, read from a real repository.
@MainActor
final class ReviewModelTests: XCTestCase {
    private var repo: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "overterm-review-tests")
        defaults.removePersistentDomain(forName: "overterm-review-tests")
        try await git(["init", "-q", "-b", "main"])
        try write("a.txt", "one\ntwo\nthree\n")
        try write("b.txt", "keep\n")
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "init"])
        try await git(["checkout", "-q", "-b", "feat"])
        try write("a.txt", "one\nTWO\nthree\n")
        try await git(["commit", "-q", "-am", "first"])
        try write("c.txt", "new\n")
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "second"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
        defaults.removePersistentDomain(forName: "overterm-review-tests")
    }

    private func git(_ arguments: [String]) async throws {
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=T"] + arguments, in: repo)
    }

    private func sha(_ ref: String) async throws -> String {
        try await Git.run(["rev-parse", ref], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func loaded(_ source: ReviewSource) async -> ReviewModel {
        let model = ReviewModel(root: repo, source: source, defaults: defaults)
        await model.load()
        for _ in 0..<100 where model.selected.map({ model.diffs[$0] == nil }) ?? false {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return model
    }

    func testABranchIsEverythingSinceItsBaseWithWhatIsntCommitted() async throws {
        try write("b.txt", "changed\n")
        try write("untracked.txt", "u1\nu2\n")
        let model = await loaded(.branch(mergeBase: try await sha("main"), base: "main", branch: "feat"))
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.files.map(\.path), ["a.txt", "b.txt", "c.txt", "untracked.txt"])
        XCTAssertEqual(model.files.first?.added, 1)
        model.select("untracked.txt")
        for _ in 0..<100 where model.diffs["untracked.txt"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.diffs["untracked.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["u1", "u2"])
        XCTAssertEqual(model.files.last?.added, 2, "an untracked file is counted once read")
    }

    func testARangeIsWhatHeadHasThatBaseDoesnt() async throws {
        // main moving on doesn't show as removals.
        try await git(["checkout", "-q", "main"])
        try write("b.txt", "main moved\n")
        try await git(["commit", "-q", "-am", "main"])
        let model = await loaded(.range(base: "main", head: "feat"))
        XCTAssertEqual(model.files.map(\.path), ["a.txt", "c.txt"])
        XCTAssertEqual(model.diffs["a.txt"]?.lines.filter { $0.kind == .removed }.map(\.text), ["two"])
    }

    func testCommitsAreAgainstTheFirstsParent() async throws {
        let first = try await sha("HEAD~1")
        let second = try await sha("HEAD")
        let one = await loaded(.commits(from: second, to: second))
        XCTAssertEqual(one.files.map(\.path), ["c.txt"])
        let both = await loaded(.commits(from: first, to: second))
        XCTAssertEqual(both.files.map(\.path), ["a.txt", "c.txt"])
        // The very first commit has no parent: against the empty tree.
        let root = await loaded(.commits(from: try await sha("main"), to: try await sha("main")))
        XCTAssertEqual(root.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(root.files.map(\.kind), [.added, .added])
    }

    func testMovingThroughFilesChangesAndViewed() async throws {
        let model = await loaded(.range(base: "main", head: "feat"))
        XCTAssertEqual(model.selected, "a.txt")
        model.moveToChange(by: 1)
        XCTAssertEqual(model.scrollTarget, model.changes.first)
        // Past the file's last change: the next file.
        model.moveToChange(by: 1)
        XCTAssertEqual(model.selected, "c.txt")
        model.selectFile(by: -1)
        XCTAssertEqual(model.selected, "a.txt")
        // Viewed moves on to the next one not viewed.
        model.toggleViewed()
        XCTAssertEqual(model.viewed, ["a.txt"])
        XCTAssertEqual(model.selected, "c.txt")
        model.toggleViewed("a.txt")
        XCTAssertEqual(model.viewed, [])
    }

    func testTheLayoutIsRemembered() {
        let model = ReviewModel(root: repo, source: .range(base: "main", head: "feat"), defaults: defaults)
        XCTAssertEqual(model.layout, .split)
        model.layout = .unified
        XCTAssertEqual(ReviewModel(root: repo, source: .pullRequest(number: 1), defaults: defaults).layout, .unified)
    }

    func testABadRevisionSaysWhy() async {
        let model = await loaded(.range(base: "main", head: "nope"))
        guard case .failed(let message) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertFalse(message.isEmpty)
    }
}
