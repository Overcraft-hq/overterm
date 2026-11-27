import XCTest

@testable import Overterm
@testable import OvertermCore

/// One hunk staged, unstaged or discarded from the changes pane (GIT-G1),
/// and a card's diff read when it opens (GIT-G10) — the patches pure, then
/// against real repositories.
final class HunkStagingTests: XCTestCase {
    private var repo: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-hunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        suite = "overterm-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: The patch, pure

    func testAHunkIsAPatchOfItsOwn() {
        let diff = """
            diff --git a/a.txt b/a.txt
            index 1111111..2222222 100644
            --- a/a.txt
            +++ b/a.txt
            @@ -1,3 +1,3 @@
             one
            -two
            +TWO
             three
            @@ -10,3 +10,3 @@
             ten
            -eleven
            +ELEVEN
             twelve

            """
        let (header, hunks) = DiffPatch.split(diff)
        XCTAssertTrue(header.hasPrefix("diff --git a/a.txt b/a.txt\n") && header.hasSuffix("+++ b/a.txt\n"), header)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertTrue(hunks[1].hasPrefix("@@ -10,3 +10,3 @@\n") && hunks[1].contains("+ELEVEN\n"))
        let patches = DiffPatch.patches(diff)
        XCTAssertEqual(patches.count, 2)
        XCTAssertTrue(patches[1].hasPrefix(header) && !patches[1].contains("+TWO"), patches[1])
    }

    func testEveryByteOfAHunkIsKept() {
        // A CRLF file, and a last line with no newline.
        let diff =
            "diff --git a/w.txt b/w.txt\r\n".replacingOccurrences(of: "\r\n", with: "\n")
            + "--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,2 @@\n a\r\n-b\r\n+B\r\n@@ -9 +9 @@\n-last\n\\ No newline at end of file\n+LAST\n\\ No newline at end of file\n"
        let hunks = DiffPatch.split(diff).hunks
        XCTAssertEqual(hunks.count, 2)
        XCTAssertTrue(hunks[0].contains("-b\r\n+B\r\n"), hunks[0].debugDescription)
        XCTAssertTrue(hunks[1].hasSuffix("+LAST\n\\ No newline at end of file\n"), hunks[1].debugDescription)
        // A rename's lines stay in the header.
        let renamed = "diff --git a/old.txt b/new.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-x\n+y\n"
        XCTAssertTrue(DiffPatch.patches(renamed).first?.contains("rename from old.txt\nrename to new.txt\n") == true)
        // A binary file has no hunk to stage.
        XCTAssertEqual(DiffPatch.patches("diff --git a/i.png b/i.png\nindex 1..2 100644\nBinary files a/i.png and b/i.png differ\n"), [])
        XCTAssertEqual(DiffModel.applyArguments(.unstage, patch: "/tmp/p"), ["apply", "--cached", "--reverse", "--whitespace=nowarn", "/tmp/p"])
    }

    // MARK: Against a repository

    @MainActor
    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    @discardableResult
    private func git(_ args: String...) async throws -> String {
        try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "-c", "core.autocrlf=false"] + args, in: repo)
    }

    @MainActor
    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(name))
    }

    private func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: repo.appendingPathComponent(name)), as: UTF8.self)
    }

    private static let twenty = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"

    @MainActor
    private func model(_ path: String) async throws -> DiffModel {
        let model = DiffModel(defaults: defaults)
        model.panelVisible = true
        model.setRoot(repo)
        try await eventually { model.diffs[path] != nil }
        return model
    }

    @MainActor
    func testOneHunkIsStagedUnstagedAndDiscarded() async throws {
        try await git("init", "-q", "-b", "main")
        try write("f.txt", Self.twenty)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try write("f.txt", Self.twenty.replacingOccurrences(of: "line 2\n", with: "line two\n").replacingOccurrences(of: "line 18\n", with: "line eighteen\n"))

        let model = try await model("f.txt")
        let diff = try XCTUnwrap(model.diffs["f.txt"])
        let hunks = diff.lines.compactMap { diff.hunks[$0.id] }
        XCTAssertEqual(hunks.map(\.side), [.unstaged, .unstaged])
        XCTAssertNil(diff.unstagedFrom, "nothing staged: one part")

        // Stage the first: only it in the index, the file partly staged.
        let applied1 = await model.apply(hunks[0], .stage)
        XCTAssertTrue(applied1, model.actionError ?? "")
        try await eventually { model.files.first?.stageState == .partial && model.diffs["f.txt"]?.unstagedFrom != nil }
        XCTAssertEqual(model.files.first?.stageState, .partial)
        let cached = try await git("diff", "--cached")
        XCTAssertTrue(cached.contains("+line two") && !cached.contains("eighteen"), cached)
        let split = try XCTUnwrap(model.diffs["f.txt"])
        XCTAssertTrue(split.startsStaged)
        let sides = split.lines.compactMap { split.hunks[$0.id]?.side }
        XCTAssertEqual(sides, [.staged, .unstaged], "the card shows what is staged, then what isn't")

        // Unstage it again.
        let staged = try XCTUnwrap(split.lines.compactMap { split.hunks[$0.id] }.first { $0.side == .staged })
        let applied2 = await model.apply(staged, .unstage)
        XCTAssertTrue(applied2, model.actionError ?? "")
        try await eventually { model.files.first?.stageState == ChangedFile.StageState.none }
        let emptyCached = try await git("diff", "--cached")
        XCTAssertEqual(emptyCached, "")

        // Discard the second: that part of the file goes back, the rest stays.
        try await eventually { model.diffs["f.txt"].map { $0.hunks.count == 2 && $0.unstagedFrom == nil } == true }
        let again = try XCTUnwrap(model.diffs["f.txt"])
        let second = try XCTUnwrap(again.lines.compactMap { again.hunks[$0.id] }.last)
        let applied3 = await model.apply(second, .discard)
        XCTAssertTrue(applied3, model.actionError ?? "")
        let text = try read("f.txt")
        XCTAssertTrue(text.contains("line two\n") && text.contains("line 18\n") && !text.contains("eighteen"), text)
    }

    @MainActor
    func testAHunkOfACRLFFileOrOneWithNoLastNewlineStages() async throws {
        try await git("init", "-q", "-b", "main")
        let crlf = (1...20).map { "row \($0)\r\n" }.joined()
        try write("w.txt", crlf)
        try write("n.txt", "a\nb\nc")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try write("w.txt", crlf.replacingOccurrences(of: "row 2\r\n", with: "ROW 2\r\n").replacingOccurrences(of: "row 19\r\n", with: "ROW 19\r\n"))
        try write("n.txt", "a\nb\nC")

        let model = try await model("w.txt")
        try await eventually { model.diffs["n.txt"] != nil }
        let crlfDiff = try XCTUnwrap(model.diffs["w.txt"])
        let crlfHunks = crlfDiff.lines.compactMap { crlfDiff.hunks[$0.id] }
        XCTAssertEqual(crlfHunks.count, 2)
        let applied4 = await model.apply(crlfHunks[1], .stage)
        XCTAssertTrue(applied4, model.actionError ?? "")
        let cached = try await git("diff", "--cached", "--", "w.txt")
        XCTAssertTrue(cached.contains("+ROW 19\r\n") && !cached.contains("ROW 2\r\n"), cached.debugDescription)

        let noEnd = try XCTUnwrap(model.diffs["n.txt"])
        let hunk = try XCTUnwrap(noEnd.lines.compactMap { noEnd.hunks[$0.id] }.first)
        let applied5 = await model.apply(hunk, .stage)
        XCTAssertTrue(applied5, model.actionError ?? "")
        let staged = try await git("diff", "--cached", "--", "n.txt")
        XCTAssertTrue(staged.contains("+C\n\\ No newline at end of file"), staged)
    }

    /// 80 files changed: the cards start folded and nothing is read for
    /// them; the 75th's diff comes when it is opened (GIT-G10).
    @MainActor
    func testACardsDiffIsReadWhenItOpensWhateverTheCount() async throws {
        try await git("init", "-q", "-b", "main")
        for i in 1...80 { try write(String(format: "f%02d.txt", i), "one\n") }
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        for i in 1...80 { try write(String(format: "f%02d.txt", i), "two\n") }

        let model = DiffModel(defaults: defaults)
        model.panelVisible = true
        model.setRoot(repo)
        try await eventually { model.files.count == 80 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.isFolded("f75.txt"))
        XCTAssertTrue(model.diffs.isEmpty, "folded cards read nothing: \(model.diffs.count)")
        model.toggleFold("f75.txt")
        try await eventually { model.diffs["f75.txt"] != nil }
        XCTAssertEqual(model.diffs["f75.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["two"])
        XCTAssertEqual(model.diffs.count, 1)
    }

    // MARK: The review's findings (pull request #56)

    func testAnUncommittedDiffNamesItsFilesPlainlyWithItsPrefixes() {
        XCTAssertEqual(
            DiffModel.uncommittedDiffArguments(staged: true, paths: ["old.txt", "new.txt"]),
            ["--literal-pathspecs", "diff", "--no-color", "--default-prefix", "--cached", "-M", "--", "old.txt", "new.txt"])
        XCTAssertEqual(
            DiffModel.uncommittedDiffArguments(staged: false, paths: ["page[1].txt"]),
            ["--literal-pathspecs", "diff", "--no-color", "--default-prefix", "--", "page[1].txt"])
    }

    /// `page[1].txt` is a glob that matches `page1.txt`: read as one, the
    /// card held both files' hunks under the first's header.
    @MainActor
    func testAFileNamedLikeAGlobIsOnlyItself() async throws {
        try await git("init", "-q", "-b", "main")
        try write("page[1].txt", Self.twenty)
        try write("page1.txt", Self.twenty)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try write("page[1].txt", Self.twenty.replacingOccurrences(of: "line 2\n", with: "line two\n"))
        try write("page1.txt", Self.twenty.replacingOccurrences(of: "line 18\n", with: "line eighteen\n"))

        let model = try await model("page[1].txt")
        let diff = try XCTUnwrap(model.diffs["page[1].txt"])
        let hunks = diff.lines.compactMap { diff.hunks[$0.id] }
        XCTAssertEqual(hunks.count, 1, "only its own hunk")
        let applied = await model.apply(try XCTUnwrap(hunks.first), .stage)
        XCTAssertTrue(applied, model.actionError ?? "")
        let cached = try await git("diff", "--cached", "--name-only")
        XCTAssertEqual(cached.trimmingCharacters(in: .whitespacesAndNewlines), "page[1].txt")
    }

    /// With `diff.noprefix`, a hunk's header was `--- src/f.txt`: `git
    /// apply` strips one component and patched the root's `f.txt`.
    @MainActor
    func testAHunkGoesToItsOwnFileWhateverThePrefixSetting() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "diff.noprefix", "true")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try write("src/f.txt", Self.twenty)
        try write("f.txt", Self.twenty)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        let edited = Self.twenty.replacingOccurrences(of: "line 2\n", with: "line two\n")
        try write("src/f.txt", edited)
        try write("f.txt", edited)

        let model = try await model("src/f.txt")
        let diff = try XCTUnwrap(model.diffs["src/f.txt"])
        let hunk = try XCTUnwrap(diff.lines.compactMap { diff.hunks[$0.id] }.first)
        XCTAssertTrue(hunk.patch.contains("--- a/src/f.txt\n+++ b/src/f.txt\n"), hunk.patch)
        let applied = await model.apply(hunk, .discard)
        XCTAssertTrue(applied, model.actionError ?? "")
        XCTAssertEqual(try read("src/f.txt"), Self.twenty, "its own file went back")
        XCTAssertEqual(try read("f.txt"), edited, "the root's file is untouched")
    }

    /// A Discard is asked; while it is, the panel moves to another
    /// checkout: the answer discards nothing there.
    @MainActor
    func testADiscardAskedInOneCheckoutIsNotAppliedInAnother() async throws {
        try await git("init", "-q", "-b", "main")
        try write("f.txt", Self.twenty)
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        let edited = Self.twenty.replacingOccurrences(of: "line 2\n", with: "line two\n")
        try write("f.txt", edited)

        let model = try await model("f.txt")
        let diff = try XCTUnwrap(model.diffs["f.txt"])
        let hunk = try XCTUnwrap(diff.lines.compactMap { diff.hunks[$0.id] }.first)
        let elsewhere = repo.appendingPathComponent("other", isDirectory: true)
        let applied = await model.apply(hunk, .discard, in: elsewhere)
        XCTAssertFalse(applied)
        XCTAssertNotNil(model.actionError)
        XCTAssertEqual(try read("f.txt"), edited, "nothing discarded")
        let here = await model.apply(hunk, .discard, in: model.root)
        XCTAssertTrue(here, model.actionError ?? "")
        XCTAssertEqual(try read("f.txt"), Self.twenty)
    }
}
