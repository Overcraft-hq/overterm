import XCTest

@testable import Terminus

final class MergedWorktreesTests: XCTestCase {
    // MARK: Pure

    func testParsesRefs() {
        let output = "main\0origin/main\0\nfeat/a\0origin/feat/a\0[gone]\nfeat/b\0origin/feat/b\0[ahead 2]\nlocal\0\0\n"
        XCTAssertEqual(
            MergedWorktrees.parse(refs: output),
            [
                .init(name: "main", hasUpstream: true, upstreamGone: false),
                .init(name: "feat/a", hasUpstream: true, upstreamGone: true),
                .init(name: "feat/b", hasUpstream: true, upstreamGone: false),
                .init(name: "local", hasUpstream: false, upstreamGone: false),
            ])
    }

    func testDecision() {
        let branches: [MergedWorktrees.Branch] = [
            .init(name: "main", hasUpstream: true, upstreamGone: false),
            .init(name: "gone", hasUpstream: true, upstreamGone: true),
            // Gone, but its tip is on no remote: commits made after a squash
            // merge, never pushed. Deleting the branch would lose them.
            .init(name: "goneUnpushed", hasUpstream: true, upstreamGone: true),
            .init(name: "merged", hasUpstream: true, upstreamGone: false),
            .init(name: "open", hasUpstream: true, upstreamGone: false),
            // Reachable from main but never pushed: a New Task with no commits yet.
            .init(name: "fresh", hasUpstream: false, upstreamGone: false),
        ]
        let result = MergedWorktrees.merged(
            branches: branches, reachable: ["main", "merged", "fresh"], pushed: ["main", "gone", "merged", "open"], base: "origin/main",
            protected: ["main"])
        XCTAssertEqual(result, ["gone": .upstreamGone, "merged": .mergedInto("origin/main")])
    }

    // MARK: Against real git

    private func git(_ args: [String], in dir: URL) async throws {
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t"] + args, in: dir)
    }

    /// A repo with a bare `origin` and six linked worktrees:
    /// merged (merge commit, pushed), mergedGone (merged and pushed, then its
    /// remote branch deleted), squashed (remote branch deleted, its commits
    /// on no remote — as after a squash merge), open (pushed, not merged),
    /// fresh (no commits, never pushed), local (merged locally, never pushed).
    private func makeRepo() async throws -> (base: URL, repo: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-merged-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let remote = base.appendingPathComponent("remote.git")
        let repo = base.appendingPathComponent("repo")
        for dir in [remote, repo] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try await git(["init", "-q", "--bare", "-b", "main"], in: remote)
        try await git(["init", "-q", "-b", "main"], in: repo)
        try await git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try await git(["remote", "add", "origin", remote.path], in: repo)
        try await git(["push", "-q", "-u", "origin", "main"], in: repo)
        try await git(["remote", "set-head", "origin", "main"], in: repo)

        func worktree(_ branch: String, commit: Bool, push: Bool) async throws -> URL {
            let path = base.appendingPathComponent("wt-\(branch)")
            try await git(["worktree", "add", "-q", "-b", branch, path.path], in: repo)
            if commit { try await git(["commit", "-q", "--allow-empty", "-m", branch], in: path) }
            if push { try await git(["push", "-q", "-u", "origin", branch], in: path) }
            return path
        }
        _ = try await worktree("merged", commit: true, push: true)
        try await git(["merge", "-q", "--no-ff", "-m", "Merge merged", "merged"], in: repo)
        try await git(["push", "-q", "origin", "main"], in: repo)
        _ = try await worktree("mergedGone", commit: true, push: true)
        try await git(["merge", "-q", "--no-ff", "-m", "Merge mergedGone", "mergedGone"], in: repo)
        try await git(["push", "-q", "origin", "main"], in: repo)
        try await git(["push", "-q", "origin", "--delete", "mergedGone"], in: repo)
        _ = try await worktree("squashed", commit: true, push: true)
        try await git(["push", "-q", "origin", "--delete", "squashed"], in: repo)
        _ = try await worktree("open", commit: true, push: true)
        _ = try await worktree("fresh", commit: false, push: false)
        _ = try await worktree("local", commit: true, push: false)
        try await git(["merge", "-q", "--no-ff", "-m", "Merge local", "local"], in: repo)
        return (base, repo)
    }

    func testFindsMergedAndGoneButNotFreshOrUnpushed() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        await MergedWorktrees.fetch(in: repo)
        let listed = Worktree.parse(porcelain: try await Git.run(["worktree", "list", "--porcelain"], in: repo))
        let merged = await MergedWorktrees.find(in: repo, worktrees: listed)
        XCTAssertEqual(
            merged, ["merged": .mergedInto("origin/main"), "mergedGone": .upstreamGone],
            "squashed is gone but its commits are on no remote: without a merged PR at its tip it stays")
    }

    func testAFolderDeletedByHandIsPrunable() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.removeItem(at: base.appendingPathComponent("wt-open"))
        let listed = Worktree.parse(porcelain: try await Git.run(["worktree", "list", "--porcelain"], in: repo))
        XCTAssertEqual(listed.filter(\.isPrunable).map(\.branch), ["open"])
    }
}
