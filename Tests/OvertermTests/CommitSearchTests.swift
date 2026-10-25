import XCTest

@testable import Overterm

/// Overgit's commit search: the query read, git asked, a commit matched.
final class CommitSearchTests: XCTestCase {
    func testTheQueryIsReadIntoWordsAndFilters() {
        let search = CommitSearch(#"fix login author:"Ada L" path:src/auth since:2.weeks branch:main code:charge"#)
        XCTAssertEqual(search.words, ["fix", "login"])
        XCTAssertEqual(search.author, "Ada L")
        XCTAssertEqual(search.path, "src/auth")
        XCTAssertEqual(search.since, "2.weeks")
        XCTAssertEqual(search.ref, "main")
        XCTAssertEqual(search.code, "charge")
        XCTAssertTrue(CommitSearch("  ").isEmpty)
        XCTAssertEqual(CommitSearch("http://x").words, ["http://x"], "an unknown key is a word")
    }

    func testGitIsAskedWithItsOwnOptions() {
        let arguments = CommitSearch("fix login author:ada path:src").arguments(limit: 50, allRefs: false)
        XCTAssertTrue(arguments.contains("--all-match"))
        XCTAssertTrue(arguments.contains("--grep=fix") && arguments.contains("--grep=login"))
        XCTAssertTrue(arguments.contains("--author=ada"))
        XCTAssertEqual(Array(arguments.suffix(3)), ["HEAD", "--", "src"])
        XCTAssertEqual(Array(CommitSearch("x branch:dev").arguments(limit: 1, allRefs: true).suffix(2)), ["dev", "--"])
        XCTAssertEqual(CommitSearch("x").arguments(limit: 1, allRefs: true).suffix(2), ["--all", "--"])
        XCTAssertFalse(CommitSearch("abc1234").arguments(limit: 1, allRefs: false).contains { $0.hasPrefix("--grep") })
    }

    func testAHashOrWordsMatchACommitRead() {
        let commit = Commit(
            sha: "abc1234def", shortSHA: "abc1234", parents: [], author: "Ada", authorEmail: "ada@example.com", date: Date(),
            relative: "now", subject: "Fix the Login", body: "Cafe", refs: [])
        XCTAssertTrue(CommitSearch("login fix").matches(commit))
        XCTAssertTrue(CommitSearch("café").matches(commit))
        XCTAssertTrue(CommitSearch("abc12").matches(commit))
        XCTAssertTrue(CommitSearch("author:ada").matches(commit))
        XCTAssertFalse(CommitSearch("login author:grace").matches(commit))
        XCTAssertFalse(CommitSearch("path:x").matches(commit), "only git knows a commit's files")
        XCTAssertEqual(CommitSearch("abcd").possibleSHA, "abcd")
        XCTAssertNil(CommitSearch("abc").possibleSHA)
        XCTAssertNil(CommitSearch("login").possibleSHA)
    }

    func testCompareCounts() {
        XCTAssertTrue(CompareModel.counts("3\t7\n") == (3, 7))
        XCTAssertTrue(CompareModel.counts("") == (0, 0))
    }
}
