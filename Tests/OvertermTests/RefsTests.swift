import XCTest

@testable import Overterm

final class RefsTests: XCTestCase {
    private func line(_ refname: String, _ sha: String, _ upstream: String, _ track: String, _ at: String, _ subject: String) -> String {
        [refname, sha, upstream, track, at, subject].joined(separator: "\0")
    }

    func testParsesBranchesLocalAndRemote() {
        let output = [
            line("refs/heads/main", "1a2b3c4", "origin/main", "", "1700000000", "Add a"),
            line("refs/heads/feature/x", "2b3c4d5", "origin/feature/x", "[ahead 2, behind 1]", "1700000100", "Work"),
            line("refs/heads/old", "3c4d5e6", "origin/old", "[gone]", "1699000000", "Done"),
            line("refs/remotes/origin/main", "1a2b3c4", "", "", "1700000000", "Add a"),
            // origin/HEAD is a pointer, not a branch anybody works on.
            line("refs/remotes/origin/HEAD", "1a2b3c4", "", "", "1700000000", ""),
        ].joined(separator: "\n")
        let branches = Refs.parse(branches: output)
        XCTAssertEqual(branches.map(\.name), ["main", "feature/x", "old", "origin/main"])
        XCTAssertEqual(branches.map(\.isRemote), [false, false, false, true])
        XCTAssertEqual(branches[1].ahead, 2)
        XCTAssertEqual(branches[1].behind, 1)
        XCTAssertTrue(branches[2].isGone)
        XCTAssertEqual(branches[2].ahead, 0, "gone says nothing about ahead")
        XCTAssertEqual(branches[0].upstream, "origin/main")
        XCTAssertNil(branches[3].upstream)
        XCTAssertEqual(branches[1].leaf, "x")
        XCTAssertEqual(branches[0].date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testTrack() {
        XCTAssertEqual(Refs.track("").ahead, 0)
        XCTAssertEqual(Refs.track("[ahead 3]").ahead, 3)
        XCTAssertEqual(Refs.track("[ahead 3]").behind, 0)
        XCTAssertEqual(Refs.track("[behind 12]").behind, 12)
        let both = Refs.track("[ahead 1, behind 20]")
        XCTAssertEqual(both.ahead, 1)
        XCTAssertEqual(both.behind, 20)
        XCTAssertTrue(Refs.track("[gone]").gone)
    }

    func testParsesTags() {
        let output = "v1.2.0\0abc1234\01700000000\0The release\nv1.1.0\0def5678\01699000000\0"
        XCTAssertEqual(Refs.parse(tags: output).map(\.name), ["v1.2.0", "v1.1.0"])
        XCTAssertEqual(Refs.parse(tags: output)[0].subject, "The release")
        XCTAssertEqual(Refs.parse(tags: output)[1].subject, "", "a lightweight tag has no message")
    }

    func testParsesRemotes() {
        let output = """
            origin\thttps://github.com/owner/repo.git\t(fetch)
            origin\thttps://github.com/owner/repo.git\t(push)
            fork\tgit@gitlab.com:me/repo.git\t(fetch)
            fork\tgit@gitlab.com:me/repo.git\t(push)
            """
        let remotes = Refs.parse(remotes: output)
        XCTAssertEqual(remotes.map(\.name), ["origin", "fork"], "each remote once, in the order git lists them")
        XCTAssertEqual(remotes[0].host, "github.com")
        XCTAssertEqual(remotes[1].host, "gitlab.com", "an ssh URL is not a URL")
    }

    // MARK: The tree

    private func branch(_ name: String, remote: Bool = false) -> BranchRef {
        BranchRef(
            name: name, isRemote: remote, sha: "abc1234", upstream: nil, ahead: 0, behind: 0, isGone: false,
            date: Date(timeIntervalSince1970: 0), subject: "")
    }

    func testAFlatListStaysFlat() {
        let rows = BranchTree.rows([branch("main"), branch("develop")], expanded: [])
        XCTAssertEqual(rows.map(\.name), ["develop", "main"])
        XCTAssertTrue(rows.allSatisfy { !$0.isFolder && $0.depth == 0 })
    }

    func testSlashesMakeFolders() {
        let branches = [branch("main"), branch("feature/a"), branch("feature/b"), branch("fix/one")]
        let shut = BranchTree.rows(branches, expanded: [])
        XCTAssertEqual(shut.map(\.name), ["feature", "fix", "main"], "folders first, then the plain ones")
        XCTAssertEqual(shut[0].count, 2)
        XCTAssertTrue(shut[0].isFolder)

        let open = BranchTree.rows(branches, expanded: ["feature"])
        XCTAssertEqual(open.map(\.name), ["feature", "a", "b", "fix", "main"])
        XCTAssertEqual(open.map(\.depth), [0, 1, 1, 0, 0])
        XCTAssertEqual(open[1].branch?.name, "feature/a", "a row knows its whole branch")
    }

    /// `release/2024/01` nests twice, and the inner folder's id is its whole
    /// path — two folders named `01` must not share one disclosure.
    func testFoldersNestAndTheirIdsArePaths() {
        let branches = [branch("release/2024/01"), branch("release/2025/01")]
        let rows = BranchTree.rows(branches, expanded: ["release", "release/2024", "release/2025"])
        XCTAssertEqual(rows.map(\.id), ["release", "release/2024", "local:release/2024/01", "release/2025", "local:release/2025/01"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 2])
    }

    /// Remote branches group under their remote for free — that is what the
    /// first component of `origin/main` is.
    func testRemotesGroupUnderTheirRemote() {
        let rows = BranchTree.rows([branch("origin/main", remote: true), branch("origin/feature/x", remote: true)], expanded: ["origin"])
        XCTAssertEqual(rows.map(\.name), ["origin", "feature", "main"])
        XCTAssertEqual(rows[0].count, 2)
    }

    // MARK: Stashes

    func testParsesStashes() {
        let output =
            "\0stash@{0}\0aaaa111\02 hours ago\0WIP on main: 1a2b3c4 Add a\0"
            + "\0stash@{1}\0bbbb222\03 days ago\0On feature/x: a message with\ta tab\0"
        let stashes = Stashes.parse(output)
        XCTAssertEqual(stashes.map(\.ref), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(stashes.map(\.index), [0, 1])
        XCTAssertEqual(stashes[1].subject, "On feature/x: a message with\ta tab")
        XCTAssertEqual(stashes[0].relative, "2 hours ago")
        XCTAssertEqual(Stashes.parse(""), [])
    }

    /// The formats are only right if git agrees.
    func testReadsARealRepository() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: [String]) async throws {
            _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=T"] + arguments, in: repo)
        }
        try await git(["init", "-q", "-b", "main"])
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "Add a"])
        try await git(["tag", "-a", "v1.0", "-m", "The first"])
        try await git(["checkout", "-q", "-b", "feature/x"])
        try await git(["remote", "add", "origin", "https://example.com/r.git"])
        try "two\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["stash", "push", "-q", "-m", "work in progress"])

        let branches = Refs.parse(branches: try await Git.run(Refs.branchArguments(), in: repo))
        XCTAssertEqual(Set(branches.map(\.name)), ["main", "feature/x"])
        XCTAssertEqual(branches.first { $0.name == "main" }?.subject, "Add a")
        let tags = Refs.parse(tags: try await Git.run(Refs.tagArguments(), in: repo))
        XCTAssertEqual(tags.map(\.name), ["v1.0"])
        XCTAssertEqual(tags[0].subject, "The first")
        let remotes = Refs.parse(remotes: try await Git.run(Refs.remoteArguments, in: repo))
        XCTAssertEqual(remotes.map(\.name), ["origin"])
        let stashes = Stashes.parse(try await Git.run(Stashes.arguments, in: repo))
        XCTAssertEqual(stashes.map(\.ref), ["stash@{0}"])
        XCTAssertTrue(stashes[0].subject.contains("work in progress"), stashes[0].subject)
    }
}
