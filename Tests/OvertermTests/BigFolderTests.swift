import XCTest

@testable import Overterm

/// A folder with more entries than a process may take arguments: listing it
/// crashed the app (13 041 entries in the temporary folder).
@MainActor
final class BigFolderTests: XCTestCase {
    func testAHugeFolderListsAndDimsItsIgnoredFilesInBatches() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-big-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        try "*.log\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for i in 0..<4500 {
            FileManager.default.createFile(atPath: repo.appendingPathComponent(String(format: "f%05d.txt", i)).path, contents: nil)
        }
        // Sorted last: in the fifth batch.
        FileManager.default.createFile(atPath: repo.appendingPathComponent("zz-late.log").path, contents: nil)

        let tree = FileTreeModel()
        tree.setRoot(repo)
        XCTAssertEqual(tree.rows.count, 4502, "every entry, and the app still here")
        let deadline = Date().addingTimeInterval(20)
        while !(tree.rows.last { $0.entry.name == "zz-late.log" }?.isIgnored ?? false), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(tree.rows.first { $0.entry.name == "zz-late.log" }?.isIgnored, true, "ignored, found past the first batch")
        XCTAssertEqual(tree.rows.first { $0.entry.name == "f00000.txt" }?.isIgnored, false)
    }

    func testGitRefusesTooManyArgumentsInsteadOfCrashing() async {
        let arguments = ["status", "--"] + (0...Git.maxArguments).map { "p\($0)" }
        do {
            _ = try await Git.run(arguments, in: FileManager.default.temporaryDirectory)
            XCTFail("expected a GitError")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("too many arguments"))
        } catch {
            XCTFail("\(error)")
        }
    }
}
