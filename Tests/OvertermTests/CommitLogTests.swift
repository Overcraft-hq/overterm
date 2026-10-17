import XCTest

@testable import Overterm

final class CommitLogTests: XCTestCase {
    private let sha1 = String(repeating: "1", count: 40)
    private let sha2 = String(repeating: "2", count: 40)
    private let sha3 = String(repeating: "3", count: 40)

    /// One record as `git log -z` prints CommitLog's format: an empty field,
    /// then the ten fields, then the `-z` terminator.
    private func record(
        _ sha: String, short: String, parents: String, author: String = "Ada", email: String = "ada@example.com",
        at: String = "1700000000", relative: String = "2 hours ago", decoration: String = "", subject: String,
        body: String = ""
    ) -> String {
        "\0\(sha)\0\(short)\0\(parents)\0\(author)\0\(email)\0\(at)\0\(relative)\0\(decoration)\0\(subject)\0\(body)\0"
    }

    func testParsesCommitsWithTheirParentsAndMessages() {
        let output =
            record(sha1, short: "1111111", parents: "\(sha2) \(sha3)", decoration: "HEAD -> refs/heads/main", subject: "Merge the branch")
            + record(sha2, short: "2222222", parents: "\(sha3)", subject: "Change a", body: "Why: because.\nAnd more.\n")
            + record(sha3, short: "3333333", parents: "", subject: "init")
        let commits = CommitLog.parse(output)
        XCTAssertEqual(commits.map(\.sha), [sha1, sha2, sha3])
        XCTAssertEqual(commits[0].parents, [sha2, sha3])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(commits[1].body, "Why: because.\nAnd more.")
        XCTAssertEqual(commits[1].author, "Ada")
        XCTAssertEqual(commits[1].authorEmail, "ada@example.com")
        XCTAssertEqual(commits[1].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(commits[1].relative, "2 hours ago")
        // A root commit has no parents, and that is not a parse failure.
        XCTAssertEqual(commits[2].parents, [])
        XCTAssertFalse(commits[2].isMerge)
    }

    /// A body holds newlines and a subject holds tabs; neither may be read
    /// as the end of a record.
    func testAMessageCanHoldAnythingButNul() {
        let output =
            record(sha1, short: "1111111", parents: "", subject: "tab\there and \0 is the only thing it cannot hold".replacingOccurrences(of: "\0", with: "NUL"), body: "\n\nline\n\nline\n")
            + record(sha2, short: "2222222", parents: "", subject: "after it")
        let commits = CommitLog.parse(output)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "tab\there and NUL is the only thing it cannot hold")
        XCTAssertEqual(commits[0].body, "line\n\nline")
        XCTAssertEqual(commits[1].subject, "after it")
    }

    func testNoCommits() {
        XCTAssertEqual(CommitLog.parse(""), [])
    }

    /// `--decorate=full` is what makes `feature/x` (a local branch) and
    /// `origin/x` (not) tellable apart.
    func testRefsOffTheFullDecoration() {
        let refs = CommitLog.refs(
            "HEAD -> refs/heads/feature/x, refs/remotes/origin/feature/x, tag: refs/tags/v1.2.0, refs/heads/other")
        XCTAssertEqual(refs.map(\.kind), [.branch, .remote, .tag, .branch])
        XCTAssertEqual(refs.map(\.name), ["feature/x", "origin/feature/x", "v1.2.0", "other"])
        XCTAssertEqual(refs.map(\.isHead), [true, false, false, false])
    }

    /// A detached HEAD decorates as plain `HEAD`.
    func testADetachedHead() {
        XCTAssertEqual(CommitLog.refs("HEAD"), [CommitRef(kind: .head, name: "HEAD", isHead: true)])
        XCTAssertEqual(CommitLog.refs(""), [])
    }

    func testTheLimitIsAlwaysAtLeastOne() {
        XCTAssertTrue(CommitLog.arguments(limit: 0).contains("--max-count=1"))
        XCTAssertTrue(CommitLog.arguments(limit: 300).contains("--max-count=300"))
        XCTAssertTrue(CommitLog.arguments(limit: 10).contains("HEAD"))
        XCTAssertTrue(CommitLog.arguments(limit: 10, allRefs: true).contains("--all"))
    }

    /// The formats are only right if git agrees: a real repository with a
    /// merge in it, read the way Overgit reads one.
    func testReadsARealRepository() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        func git(_ arguments: [String]) async throws {
            _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=T"] + arguments, in: repo)
        }
        try await git(["init", "-q", "-b", "main"])
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "Add a", "-m", "Why: it was missing."])
        try await git(["tag", "v1.0"])
        try await git(["checkout", "-q", "-b", "feature/x"])
        try "two\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "Add b"])
        try await git(["checkout", "-q", "main"])
        try await git(["merge", "-q", "--no-ff", "feature/x", "-m", "Merge feature/x"])
        try await git(["stash", "list"])

        let commits = CommitLog.parse(try await Git.run(CommitLog.arguments(limit: 50), in: repo))
        XCTAssertEqual(commits.map(\.subject), ["Merge feature/x", "Add b", "Add a"])
        XCTAssertEqual(commits[0].parents.count, 2, "the merge keeps both parents")
        XCTAssertEqual(commits[0].refs.filter(\.isHead).map(\.name), ["main"])
        XCTAssertEqual(commits[2].refs.map(\.name), ["v1.0"])
        XCTAssertEqual(commits[2].body, "Why: it was missing.")
        XCTAssertEqual(commits[1].author, "T")
        XCTAssertFalse(commits[1].relative.isEmpty, "git's own relative date")

        // The merge's own diff, against its first parent.
        let header = CommitLog.parse(try await Git.run(CommitShow.headerArguments(commits[0].sha), in: repo))
        XCTAssertEqual(header.map(\.sha), [commits[0].sha])
        let files = GitStatus.parse(nameStatusZ: try await Git.run(CommitShow.filesArguments(commits[0].sha), in: repo))
        XCTAssertEqual(files.map(\.path), ["b.txt"], "what the merge brought in")
        let numbers = GitStatus.parse(numstatZ: try await Git.run(CommitShow.numstatArguments(commits[0].sha), in: repo))
        XCTAssertEqual(numbers["b.txt"]?.added, 1)
        let diff = try await Git.run(CommitShow.diffArguments(commits[1].sha, path: "b.txt"), in: repo)
        XCTAssertTrue(diff.contains("+two"), diff)
    }
}
