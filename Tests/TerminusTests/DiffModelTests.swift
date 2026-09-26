import XCTest

@testable import Terminus

final class DiffModelTests: XCTestCase {
    private var repo: URL!
    /// The scope is remembered: tests that pick one get their own suite.
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        suite = "terminus-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: repo.path + "-wt"))
        defaults.removePersistentDomain(forName: suite)
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

    // MARK: Branch scope

    /// A repository on main with `files` committed, and a linked worktree
    /// next to it on a new branch `feat` — New Task's layout.
    @MainActor
    private func featureWorktree(_ files: [String: String]) async throws -> URL {
        try await git("init", "-q", "-b", "main")
        for (name, text) in files { try write(name, text) }
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        let worktree = URL(fileURLWithPath: repo.path + "-wt")
        try await git("worktree", "add", "-q", "-b", "feat", worktree.path)
        return worktree
    }

    @MainActor
    private func git(in dir: URL, _ args: String...) async throws {
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t"] + args, in: dir)
    }

    /// The agent committed one change and has another under way. Uncommitted
    /// shows only the latter; Branch shows both, from where the branch left
    /// main, and the commit — and keeps showing it once everything is committed.
    @MainActor
    func testTheBranchScopeKeepsWhatWasCommitted() async throws {
        let worktree = try await featureWorktree(["a.txt": "one\n", "b.txt": "one\n"])
        try "two\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(in: worktree, "commit", "-q", "-am", "Change a", "-m", "Because the test says so.")
        try "one\nmore\n".write(to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let mainTip = try await Git.run(["rev-parse", "main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)

        let model = DiffModel(defaults: defaults)
        model.panelVisible = true
        model.setRoot(worktree)
        try await eventually { model.branchFiles.count == 2 && model.diffs.count == 1 }

        XCTAssertEqual(model.comparison, .since(mergeBase: mainTip, base: "main"))
        XCTAssertEqual(model.files.map(\.path), ["b.txt"], "uncommitted: the edit under way")
        XCTAssertEqual(model.branchFiles.map(\.path), ["a.txt", "b.txt"], "the branch: the committed file too")
        XCTAssertEqual(model.branchFiles.map { [$0.added, $0.removed] }, [[1, 1], [1, 0]])
        XCTAssertEqual(model.commits.map(\.subject), ["Change a"])
        XCTAssertEqual(model.commits.first?.body, "Because the test says so.")
        XCTAssertEqual(model.commits.first?.files, ["a.txt"])
        XCTAssertEqual(model.scope, .uncommitted, "Uncommitted until Branch is picked")
        XCTAssertEqual(model.shownFiles.map(\.path), ["b.txt"])
        XCTAssertNil(model.scopeNote)
        XCTAssertEqual(model.badge, .uncommitted(added: 1, removed: 0), "the badge: what is uncommitted, while there is some")

        model.choose(.branch)
        try await eventually { model.diffs.count == 2 }
        XCTAssertEqual(model.shownScope, .branch)
        XCTAssertEqual(model.shownFiles.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(model.diffs["a.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["two"], "diffed from the merge-base")
        XCTAssertEqual(model.diffs["b.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["more"])
        XCTAssertEqual(model.scopeNote, "Since main · 1 commit")
        XCTAssertEqual(defaults.string(forKey: DiffModel.scopeKey), "branch", "the pick is remembered")
        XCTAssertEqual(DiffModel(defaults: defaults).scope, .branch)

        // The rest is committed too: nothing uncommitted, the branch keeps it all.
        try await Task.sleep(nanoseconds: 500_000_000)
        try await git(in: worktree, "commit", "-q", "-am", "More b")
        try await eventually { model.files.isEmpty && model.commits.count == 2 }
        XCTAssertEqual(model.files, [])
        XCTAssertEqual(model.branchFiles.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(model.commits.map(\.subject), ["More b", "Change a"], "newest first")
        XCTAssertEqual(model.badge, .branch(added: 2, removed: 1), "then the branch's totals")
        XCTAssertEqual(model.scopeNote, "Since main · 2 commits")
    }

    @MainActor
    func testOnTheBaseBranchThereIsNothingToCompareWith() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try write("a.txt", "two\n")

        let model = DiffModel(defaults: defaults)
        model.choose(.branch)
        model.panelVisible = true
        model.setRoot(repo)
        try await eventually { model.comparison != nil && model.diffs.count == 1 }
        XCTAssertEqual(model.comparison, .onBase("main"))
        XCTAssertEqual(model.scope, .branch, "the pick stays")
        XCTAssertEqual(model.shownScope, .uncommitted, "but Uncommitted is shown")
        XCTAssertEqual(model.shownFiles.map(\.path), ["a.txt"])
        XCTAssertEqual(model.diffs["a.txt"]?.lines.filter { $0.kind == .added }.map(\.text), ["two"])
        XCTAssertEqual(model.branchFiles, [])
        XCTAssertEqual(model.scopeNote, "On main — nothing to compare with")
    }

    @MainActor
    func testWithNoCommitYetThereIsNothingToCompareWith() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        let model = DiffModel(defaults: defaults)
        model.choose(.branch)
        model.setRoot(repo)
        try await eventually { model.comparison != nil }
        XCTAssertEqual(model.comparison, .noCommits)
        XCTAssertEqual(model.shownScope, .uncommitted)
        XCTAssertEqual(model.shownFiles.map(\.path), ["a.txt"])
        XCTAssertEqual(model.scopeNote, "No commits yet — nothing to compare with")
    }

    /// A branch with no history in common with main (an orphan) can't be
    /// compared with it.
    @MainActor
    func testUnrelatedHistoryHasNothingToCompareWith() async throws {
        let worktree = try await featureWorktree(["a.txt": "one\n"])
        try await git(in: worktree, "checkout", "-q", "--orphan", "lonely")
        try await git(in: worktree, "commit", "-q", "-m", "alone")
        let model = DiffModel(defaults: defaults)
        model.choose(.branch)
        model.setRoot(worktree)
        try await eventually { model.comparison != nil }
        XCTAssertEqual(model.comparison, .unrelated("main"))
        XCTAssertEqual(model.shownScope, .uncommitted)
        XCTAssertEqual(model.scopeNote, "No history shared with main — nothing to compare with")
    }

    /// origin/HEAD is the base when there is one, so a feature branch in the
    /// main checkout itself has something to compare with.
    @MainActor
    func testTheRemotesDefaultBranchIsTheBase() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try await git("update-ref", "refs/remotes/origin/main", "HEAD")
        try await git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        try await git("checkout", "-q", "-b", "feat")
        try write("c.txt", "new\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "Add c")
        let base = try await Git.run(["rev-parse", "origin/main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)

        let model = DiffModel(defaults: defaults)
        model.setRoot(repo)
        try await eventually { model.comparison != nil }
        XCTAssertEqual(model.comparison, .since(mergeBase: base, base: "origin/main"))
        XCTAssertEqual(model.branchFiles.map(\.path), ["c.txt"])
        XCTAssertEqual(model.commits.map(\.subject), ["Add c"])
    }

    /// A repository pushed from a local `git init` has no origin/HEAD, and
    /// its main checkout may be on a feature branch: the main worktree's
    /// branch is then the branch itself. Branch falls back to main.
    @MainActor
    func testWithoutOriginAFeatureBranchInTheMainCheckoutComparesWithMain() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        let mainTip = try await Git.run(["rev-parse", "main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try await git("checkout", "-q", "-b", "feat")
        try write("c.txt", "new\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "Add c")

        let model = DiffModel(defaults: defaults)
        model.setRoot(repo)
        try await eventually { model.comparison != nil }
        XCTAssertEqual(model.comparison, .since(mergeBase: mainTip, base: "main"))
        XCTAssertEqual(model.branchFiles.map(\.path), ["c.txt"])
        XCTAssertEqual(model.commits.map(\.subject), ["Add c"])
    }

    /// Pushed, but origin/HEAD never set (only a clone sets it): the
    /// remote's main comes first.
    @MainActor
    func testWithoutOriginHeadTheRemotesMainComesFirst() async throws {
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "init")
        try await git("update-ref", "refs/remotes/origin/main", "HEAD")
        try await git("commit", "-q", "--allow-empty", "-m", "unpushed on main")
        try await git("checkout", "-q", "-b", "feat")
        try await git("commit", "-q", "--allow-empty", "-m", "on feat")
        let pushed = try await Git.run(["rev-parse", "origin/main"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)

        let model = DiffModel(defaults: defaults)
        model.setRoot(repo)
        try await eventually { model.comparison != nil }
        XCTAssertEqual(model.comparison, .since(mergeBase: pushed, base: "origin/main"))
        XCTAssertEqual(model.commits.map(\.subject), ["on feat", "unpushed on main"])
    }

    /// On main itself there is still nothing to compare with — its own
    /// origin/main is not another branch.
    @MainActor
    func testOnMainWithoutOriginHeadThereIsStillNothingToCompareWith() async throws {
        try await git("init", "-q", "-b", "main")
        try await git("commit", "-q", "--allow-empty", "-m", "init")
        try await git("update-ref", "refs/remotes/origin/main", "HEAD")
        try await git("commit", "-q", "--allow-empty", "-m", "unpushed")

        let model = DiffModel(defaults: defaults)
        model.choose(.branch)
        model.setRoot(repo)
        try await eventually { model.comparison != nil }
        XCTAssertEqual(model.comparison, .onBase("main"))
        XCTAssertEqual(model.shownScope, .uncommitted)
        XCTAssertEqual(model.scopeNote, "On main — nothing to compare with")
    }

    /// The fallback's order, and never the branch itself.
    func testTheBranchBaseFallsBackToTheFirstOtherDefaultBranch() {
        let all: Set<String> = ["origin/main", "origin/master", "main", "master"]
        XCTAssertEqual(DiffModel.branchBase(default: "origin/develop", current: "feat", existing: all), "origin/develop", "origin/HEAD, as merged worktrees use it")
        XCTAssertEqual(DiffModel.branchBase(default: "main", current: "feat", existing: all), "main")
        XCTAssertEqual(DiffModel.branchBase(default: "feat", current: "feat", existing: all), "origin/main", "the main checkout is on this branch")
        XCTAssertEqual(DiffModel.branchBase(default: nil, current: "feat", existing: ["master", "origin/master"]), "origin/master")
        XCTAssertEqual(DiffModel.branchBase(default: nil, current: "feat", existing: ["master"]), "master")
        XCTAssertEqual(DiffModel.branchBase(default: nil, current: nil, existing: ["main"]), "main", "a detached HEAD compares with main")
        XCTAssertNil(DiffModel.branchBase(default: "main", current: "main", existing: ["origin/main", "main"]), "main and its own origin/main")
        XCTAssertEqual(DiffModel.branchBase(default: "main", current: "main", existing: ["origin/main", "master"]), "master")
        XCTAssertNil(DiffModel.branchBase(default: nil, current: "feat", existing: []))
    }

    @MainActor
    func testARenameOnTheBranchIsReportedAsARename() async throws {
        let worktree = try await featureWorktree(["old.txt": "1\n2\n3\n4\n5\n"])
        try await git(in: worktree, "mv", "old.txt", "new.txt")
        try await git(in: worktree, "commit", "-q", "-m", "Rename")

        let model = DiffModel(defaults: defaults)
        model.choose(.branch)
        model.panelVisible = true
        model.setRoot(worktree)
        try await eventually { model.diffs["new.txt"] != nil }
        XCTAssertEqual(model.branchFiles.map(\.path), ["new.txt"], "one file, not a deletion and an addition")
        XCTAssertEqual(model.branchFiles.first?.kind, .renamed)
        XCTAssertEqual(model.branchFiles.first?.originalPath, "old.txt")
        XCTAssertEqual(model.branchFiles.first.map { [$0.added, $0.removed] }, [0, 0])
        XCTAssertEqual(model.diffs["new.txt"]?.lines.filter { $0.kind == .added || $0.kind == .removed }.count, 0)
        XCTAssertEqual(model.commits.first?.files, ["new.txt"])
    }

    /// The ± badge: in any repository, so the pane is always one click away —
    /// the uncommitted totals, else the branch's, else a plain ±.
    func testTheBadgeShowsInAnyRepository() {
        let edit = ChangedFile(path: "a.txt", originalPath: nil, kind: .modified, isStaged: false, hasUnstaged: true, added: 2, removed: 1)
        let committed = ChangedFile(path: "b.txt", originalPath: nil, kind: .added, isStaged: false, hasUnstaged: false, added: 5, removed: 0)
        XCTAssertEqual(DiffModel.badge(isRepository: true, uncommitted: [edit], branch: [committed, edit]), .uncommitted(added: 2, removed: 1))
        XCTAssertEqual(DiffModel.badge(isRepository: true, uncommitted: [], branch: [committed]), .branch(added: 5, removed: 0))
        XCTAssertEqual(DiffModel.badge(isRepository: true, uncommitted: [], branch: []), .plain, "nothing changed: still there, to open the pane")
        XCTAssertNil(DiffModel.badge(isRepository: false, uncommitted: [], branch: []), "not in a repository: nothing to open")
        // A click opens the scope it counts; the plain ± the one picked last.
        XCTAssertEqual(DiffModel.Badge.uncommitted(added: 2, removed: 1).scope, .uncommitted)
        XCTAssertEqual(DiffModel.Badge.branch(added: 5, removed: 0).scope, .branch)
        XCTAssertNil(DiffModel.Badge.plain.scope)
    }

    @MainActor
    func testOutsideARepositorySaysSo() async throws {
        let model = DiffModel()
        model.setRoot(repo)
        try await eventually { model.error != nil }
        XCTAssertEqual(model.error, "Not a git repository")
    }

    // MARK: Why

    /// Why each file changed, from the checkout's Claude sessions (a scratch
    /// projects directory, never ~/.claude), read only while the pane is
    /// open. A linked worktree's include those started in the main checkout:
    /// Claude Code keeps a transcript where the session started, also after
    /// EnterWorktree moved it.
    @MainActor
    func testWhyEachFileChangedFromTheCheckoutsClaudeSessions() async throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        let worktree = try await featureWorktree(["a.txt": "one\n", "b.txt": "one\n", "c.txt": "one\n"])
        try "two\n".write(to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(in: worktree, "commit", "-q", "-am", "Teach a to count")
        for name in ["b.txt", "c.txt"] {
            try "one\nmore\n".write(to: worktree.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var inWorktree = TranscriptFixture()
        inWorktree.base = Date()
        try inWorktree.write(
            [
                inWorktree.prompt("count in b", at: 1), inWorktree.said("b.txt needs a second line.", at: 2),
                inWorktree.edit("toolu_1", worktree.path + "/b.txt", at: 3), inWorktree.result("toolu_1", at: 4),
            ], to: projects, for: worktree.path)
        var moved = inWorktree
        moved.session = "11111111-2222-3333-4444-555555555555"
        try moved.write(
            [
                moved.prompt("and a", at: 5), moved.said("a.txt counts too.", at: 6),
                moved.edit("toolu_2", worktree.path + "/a.txt", at: 7), moved.result("toolu_2", at: 8),
            ], to: projects, for: repo.path)

        let model = DiffModel(defaults: defaults, transcripts: ClaudeEditsReader(projects: { projects }))
        model.setRoot(worktree)
        try await eventually { model.files.count == 2 && model.commits.count == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(model.reasons.isEmpty, "not read while the pane is closed")

        model.panelVisible = true
        try await eventually { model.reasons.count == 2 }
        XCTAssertEqual(model.reasons["b.txt"]?.map(\.reason?.text), ["b.txt needs a second line."])
        XCTAssertEqual(model.reasons["a.txt"]?.map(\.reason?.text), ["a.txt counts too."], "a session started in the main checkout")
        XCTAssertNil(model.reasons["c.txt"], "no session edited it: nothing to say")
        XCTAssertEqual(model.commitsByFile["a.txt"]?.map(\.subject), ["Teach a to count"])
        XCTAssertNil(model.commitsByFile["b.txt"])

        // What the cards show: commits in Branch only; the newest reason until opened.
        XCTAssertEqual(model.why(for: "a.txt").commits, [], "Uncommitted")
        XCTAssertTrue(model.why(for: "c.txt").isEmpty, "no strip at all")
        model.choose(.branch)
        try await eventually { model.shownScope == .branch }
        XCTAssertEqual(model.why(for: "a.txt").commits.map(\.subject), ["Teach a to count"])
        XCTAssertEqual(model.why(for: "a.txt").shownReasons.map(\.reason?.text), ["a.txt counts too."])
        XCTAssertEqual(model.why(for: "b.txt").commits, [], "no commit touched it")
        XCTAssertFalse(model.why(for: "b.txt").isEmpty, "but Claude said why")
    }

    /// A card's why shows the newest reason, and all of them once clicked.
    @MainActor
    func testAClickOnAWhyShowsItAll() async throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        try await git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        var t = TranscriptFixture()
        t.base = Date()
        let path = repo.path + "/a.txt"
        try t.write(
            [
                t.prompt("start", at: 1), t.said("First pass.", at: 2), t.edit("toolu_1", path, at: 3), t.result("toolu_1", at: 4),
                t.said("Second pass.", at: 5), t.edit("toolu_2", path, at: 6), t.result("toolu_2", at: 7),
            ], to: projects, for: repo.path)
        let model = DiffModel(defaults: defaults, transcripts: ClaudeEditsReader(projects: { projects }))
        model.panelVisible = true
        model.setRoot(repo)
        try await eventually { model.reasons["a.txt"]?.count == 2 }
        XCTAssertEqual(model.why(for: "a.txt").shownReasons.map(\.reason?.text), ["Second pass."])
        XCTAssertEqual(model.why(for: "a.txt").hiddenReasons, 1)
        model.toggleWhy("a.txt")
        XCTAssertEqual(model.why(for: "a.txt").shownReasons.map(\.reason?.text), ["Second pass.", "First pass."])
        XCTAssertEqual(model.why(for: "a.txt").hiddenReasons, 0)
        model.toggleWhy("a.txt")
        XCTAssertEqual(model.why(for: "a.txt").shownReasons.count, 1)
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
