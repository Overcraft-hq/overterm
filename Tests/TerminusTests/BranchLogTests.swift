import XCTest

@testable import Terminus

final class BranchLogTests: XCTestCase {
    private let sha1 = String(repeating: "1", count: 40)
    private let sha2 = String(repeating: "2", count: 40)
    private let sha3 = String(repeating: "3", count: 40)

    /// What `git log -z --name-only` prints for BranchLog's format, newest
    /// first (taken from a real run): every commit led by an empty field, the
    /// message's fields NUL-separated, the files after a newline.
    func testParsesCommitsWithTheirMessagesAndFiles() {
        let output =
            "\0\(sha1)\01111111\02 minutes ago\0Empty one\0\0"
            + "\0\(sha2)\02222222\03 minutes ago\0Rename a\0\0\nz.txt\0"
            + "\0\(sha3)\03333333\04 hours ago\0Add a and b\0Body line 1\nBody line 2 with\ttab\n\0\na.txt\0b c.txt\0"
        XCTAssertEqual(
            BranchLog.parse(output),
            [
                BranchCommit(sha: sha1, shortSHA: "1111111", date: "2 minutes ago", subject: "Empty one", body: "", files: []),
                BranchCommit(sha: sha2, shortSHA: "2222222", date: "3 minutes ago", subject: "Rename a", body: "", files: ["z.txt"]),
                BranchCommit(
                    sha: sha3, shortSHA: "3333333", date: "4 hours ago", subject: "Add a and b",
                    body: "Body line 1\nBody line 2 with\ttab", files: ["a.txt", "b c.txt"]),
            ])
    }

    /// A path can hold anything but NUL — a newline, a tab, text that looks
    /// like a hash — and still stays one of the commit's files.
    func testPathsAreTakenWhole() {
        let output = "\0\(sha1)\01111111\0now\0Odd names\0\0\n\nstarts with a newline\0\(sha2)\0tab\there\0"
        XCTAssertEqual(BranchLog.parse(output).map(\.files), [["\nstarts with a newline", sha2, "tab\there"]])
    }

    func testNoCommits() {
        XCTAssertEqual(BranchLog.parse(""), [])
    }
}
