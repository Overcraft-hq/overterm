import XCTest

@testable import Terminus

final class DiffModelTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    /// Refreshes run on file events too and a newer one supersedes an older
    /// one's results by design — wait for the model to settle.
    @MainActor
    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private func git(_ args: String...) async throws {
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t"] + args, in: repo)
    }

    @MainActor
    private func write(_ name: String, _ text: String) throws {
        try text.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @MainActor
    func testCountsAndDiffsEveryFile() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\ntwo\nthree\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try write("a.txt", "one\nTWO\nthree\nfour\n")
        try write("new file.txt", "fresh\nlines\n")

        let model = DiffModel()
        model.panelVisible = true
        model.setRoot(repo)
        try await eventually { model.diffs.count == 2 }

        XCTAssertEqual(model.branch, "main")
        XCTAssertEqual(model.files.map(\.path), ["a.txt", "new file.txt"])
        XCTAssertEqual([model.files[0].added, model.files[0].removed], [2, 1])
        XCTAssertEqual([model.files[1].added, model.files[1].removed], [2, 0], "untracked lines count as added")
        XCTAssertEqual(model.totals.added, 4)
        XCTAssertEqual(model.diffs["a.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["TWO", "four"])
        XCTAssertEqual(model.diffs["new file.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["fresh", "lines"])
        XCTAssertFalse(model.diffs["a.txt"]!.lines.contains { $0.text.hasPrefix("diff --git") }, "headers are the card's job")
    }

    /// The scenario from the first real use: git init, add, edit — no HEAD.
    @MainActor
    func testWorksBeforeTheFirstCommit() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "ddd\n")
        try await git("add", "a.txt")
        try write("a.txt", "ddd\neee\n")

        let model = DiffModel()
        model.panelVisible = true
        model.setRoot(repo)
        try await eventually { model.diffs["a.txt"]?.lines.isEmpty == false }

        XCTAssertNil(model.error)
        XCTAssertEqual(model.files.first?.kind, .added)
        XCTAssertEqual(model.files.first?.added, 2)
        XCTAssertEqual(model.diffs["a.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["ddd", "eee"])

        // Unstaging an added file needs rm --cached (restore --staged needs HEAD).
        await model.unstage(model.files[0])
        try await eventually { model.files.first?.kind == .untracked }
        XCTAssertEqual(model.files.first?.kind, .untracked)
    }

    @MainActor
    func testCountsStayLiveWithThePanelClosed() async throws {
        try await git("init", "-q", "-b", "main")
        let model = DiffModel()
        model.setRoot(repo)
        try write("x.txt", "1\n2\n3\n")
        try await eventually { model.totals.added == 3 }
        XCTAssertEqual(model.totals.added, 3, "the badge needs counts without the panel")
        XCTAssertTrue(model.diffs.isEmpty, "diff text only loads while the panel is open")
    }

    @MainActor
    func testStageCommitAndDiscard() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.email", "t@t")
        try await git("config", "user.name", "t")
        for name in ["keep.txt", "throw.txt"] { try write(name, "v1\n") }
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        for name in ["keep.txt", "throw.txt"] { try write(name, "v2\n") }

        let model = DiffModel()
        model.setRoot(repo)
        try await eventually { model.files.count == 2 }

        await model.toggleStaged(try XCTUnwrap(model.files.first { $0.path == "keep.txt" }))
        try await eventually { model.stagedCount == 1 }
        XCTAssertEqual(model.files.first { $0.path == "keep.txt" }?.stageState, .full)

        await model.discard(try XCTUnwrap(model.files.first { $0.path == "throw.txt" }))
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("throw.txt"), encoding: .utf8), "v1\n")

        let committed = await model.commit(message: "keep v2")
        XCTAssertTrue(committed)
        try await eventually { model.files.isEmpty }
        let log = try await Git.run(["log", "--format=%s", "-1"], in: repo)
        XCTAssertEqual(log.trimmingCharacters(in: .newlines), "keep v2")

        let nothing = await model.commit(message: "empty")
        XCTAssertFalse(nothing, "nothing staged: git refuses")
        XCTAssertNotNil(model.actionError)
    }

    @MainActor
    func testCommitAllStagesEverything() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.email", "t@t")
        try await git("config", "user.name", "t")
        try write("a.txt", "a\n")
        let model = DiffModel()
        model.setRoot(repo)
        try await eventually { model.files.count == 1 }
        let ok = await model.commitAll(message: "first")
        XCTAssertTrue(ok)
        let log = try await Git.run(["log", "--format=%s"], in: repo)
        XCTAssertEqual(log.trimmingCharacters(in: .newlines), "first")
    }

    /// A linked worktree's index and HEAD live in the main repository's
    /// .git/worktrees/<name>, its branch in .git/refs — outside the checkout.
    /// A commit there (what an agent does) must still clear the pane.
    @MainActor
    func testACommitInALinkedWorktreeClearsIt() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        let worktree = URL(fileURLWithPath: repo.path + "-wt")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try await git("worktree", "add", "-q", "-b", "feat", worktree.path)
        try "two\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let model = DiffModel()
        model.setRoot(worktree)
        try await eventually { model.files.count == 1 }
        XCTAssertEqual(model.files.map(\.path), ["a.txt"])
        // Let any event from before settle, and the watchers go live.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-am", "edit"], in: worktree)
        try await eventually { model.files.isEmpty }
        XCTAssertEqual(model.files.map(\.path), [], "the commit is seen without anything else touching the checkout")
    }

    /// What the second watcher covers: nothing for a main checkout (its .git
    /// is inside it), the worktree's git dir and the refs for a linked one.
    @MainActor
    func testGitDirectoriesOutsideTheCheckout() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("commit", "-q", "--allow-empty", "-m", "init")
        let worktree = URL(fileURLWithPath: repo.path + "-wt")
        defer { try? FileManager.default.removeItem(at: worktree) }
        try await git("worktree", "add", "-q", "-b", "feat", worktree.path)

        let none = await DiffModel.gitDirectories(outside: repo)
        XCTAssertEqual(none, [])
        let linked = await DiffModel.gitDirectories(outside: worktree).map { $0.resolvingSymlinksInPath().path }
        let dotGit = repo.appendingPathComponent(".git").resolvingSymlinksInPath().path
        XCTAssertEqual(linked, ["\(dotGit)/worktrees/\(worktree.lastPathComponent)", "\(dotGit)/refs"])
    }

    @MainActor
    func testOutsideARepositorySaysSo() async throws {
        let model = DiffModel()
        model.setRoot(repo)
        try await eventually { model.error != nil }
        XCTAssertEqual(model.error, "Not a git repository")
    }

    func testLineCount() throws {
        let url = repo.appendingPathComponent("n.txt")
        try "a\nb".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiffModel.lineCount(url), 2)
        try "".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(DiffModel.lineCount(url), 0)
        try Data([0x00, 0x01]).write(to: url)
        XCTAssertNil(DiffModel.lineCount(url))
    }
}
