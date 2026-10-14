import XCTest

@testable import Overterm

final class FileTreeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private func touch(_ path: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(path).path, contents: Data())
    }

    // MARK: treeRoot

    func testTreeRootIsTheEnclosingCheckout() throws {
        try mkdir("repo/.git")
        try mkdir("repo/Sources/Deep")
        XCTAssertEqual(FileTreeModel.treeRoot(for: dir.appendingPathComponent("repo/Sources/Deep").path).path, dir.appendingPathComponent("repo").standardizedFileURL.path)
    }

    func testTreeRootFindsAWorktreeByItsGitFile() throws {
        // A linked worktree's .git is a file pointing at the main repo.
        try mkdir("wt/src")
        touch("wt/.git")
        XCTAssertEqual(FileTreeModel.treeRoot(for: dir.appendingPathComponent("wt/src").path).path, dir.appendingPathComponent("wt").standardizedFileURL.path)
    }

    func testTreeRootOutsideACheckoutIsTheCwd() throws {
        try mkdir("plain/sub")
        let cwd = dir.appendingPathComponent("plain/sub")
        XCTAssertEqual(FileTreeModel.treeRoot(for: cwd.path).path, cwd.standardizedFileURL.path)
    }

    // MARK: Model

    @MainActor
    func testRowsListFoldersFirstAndHideGitNoise() throws {
        try mkdir("b-dir")
        try mkdir(".git")
        touch("a-file.txt")
        touch("file10.txt")
        touch("file2.txt")
        touch(".DS_Store")
        let tree = FileTreeModel()
        tree.setRoot(dir)
        XCTAssertEqual(tree.rows.map(\.entry.name), ["b-dir", "a-file.txt", "file2.txt", "file10.txt"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 0, 0, 0])
    }

    @MainActor
    func testToggleExpandsAndCollapsesInPlace() throws {
        try mkdir("src")
        touch("src/main.swift")
        touch("README.md")
        let tree = FileTreeModel()
        tree.setRoot(dir)
        let src = try XCTUnwrap(tree.rows.first { $0.entry.name == "src" })

        tree.toggle(src)
        XCTAssertEqual(tree.rows.map(\.entry.name), ["src", "main.swift", "README.md"])
        XCTAssertEqual(tree.rows.map(\.depth), [0, 1, 0])
        XCTAssertTrue(tree.rows[0].isExpanded)

        tree.toggle(tree.rows[0])
        XCTAssertEqual(tree.rows.map(\.entry.name), ["src", "README.md"])
    }

    @MainActor
    func testExpandedFoldersSurviveSwitchingRoots() throws {
        try mkdir("one/src")
        try mkdir("two")
        let tree = FileTreeModel()
        let one = dir.appendingPathComponent("one")
        tree.setRoot(one)
        tree.toggle(try XCTUnwrap(tree.rows.first))
        XCTAssertTrue(tree.rows[0].isExpanded)

        tree.setRoot(dir.appendingPathComponent("two"))
        tree.setRoot(one)
        XCTAssertTrue(tree.rows[0].isExpanded)
    }

    @MainActor
    func testReloadPicksUpNewFiles() throws {
        let tree = FileTreeModel()
        tree.setRoot(dir)
        XCTAssertTrue(tree.rows.isEmpty)
        touch("new.txt")
        XCTAssertTrue(tree.rows.isEmpty, "listings are cached until reload")
        tree.reload()
        XCTAssertEqual(tree.rows.map(\.entry.name), ["new.txt"])
    }
}

extension FileTreeTests {
    @MainActor
    func testInvalidateRefreshesOnlyThatFolder() throws {
        try mkdir("src")
        let tree = FileTreeModel()
        tree.setRoot(dir)
        tree.toggle(try XCTUnwrap(tree.rows.first))
        touch("src/new.swift")
        touch("top.txt")

        tree.invalidate([dir.appendingPathComponent("src")])
        XCTAssertEqual(tree.rows.map(\.entry.name), ["src", "new.swift"], "root listing is still cached")
    }

    /// FSEvents reports real paths (/private/var/…, symlinks resolved),
    /// not the URL the tree was given.
    @MainActor
    func testInvalidateMatchesTheRealPathFSEventsReports() throws {
        try mkdir("src")
        let tree = FileTreeModel()
        tree.setRoot(dir)
        tree.toggle(try XCTUnwrap(tree.rows.first))
        touch("src/new.swift")
        // As the watcher hands it over: a string, with a trailing slash.
        let reported = FileTreeModel.realPath(dir.appendingPathComponent("src")) + "/"
        XCTAssertTrue(reported.hasPrefix("/private/"), reported)
        tree.invalidate(paths: [reported])
        XCTAssertEqual(tree.rows.map(\.entry.name), ["src", "new.swift"])
    }

    @MainActor
    func testInvalidateIgnoresGitAndUnlistedFolders() throws {
        try mkdir("src")
        let tree = FileTreeModel()
        tree.setRoot(dir)
        touch("late.txt")
        tree.invalidate([dir.appendingPathComponent(".git/objects"), dir.appendingPathComponent("src")])
        XCTAssertEqual(tree.rows.map(\.entry.name), ["src"], "src was never listed, .git is ignored")
    }

    @MainActor
    func testDeletedExpandedFolderDisappears() throws {
        try mkdir("gone/inner")
        let tree = FileTreeModel()
        tree.setRoot(dir)
        tree.toggle(try XCTUnwrap(tree.rows.first))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone"))
        tree.invalidate([dir])
        XCTAssertTrue(tree.rows.isEmpty)
    }
}

extension FileTreeTests {
    @MainActor
    func testGitignoredEntriesAreFlagged() async throws {
        _ = try await Git.run(["init", "-q"], in: dir)
        try "node_modules/\n*.log\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try mkdir("node_modules/pkg")
        try mkdir("src")
        touch("debug.log")
        touch("README.md")

        let tree = FileTreeModel()
        tree.setRoot(dir)
        let deadline = Date().addingTimeInterval(5)
        while !tree.rows.contains(where: \.isIgnored), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let flags = Dictionary(uniqueKeysWithValues: tree.rows.map { ($0.entry.name, $0.isIgnored) })
        XCTAssertEqual(flags["node_modules"], true)
        XCTAssertEqual(flags["debug.log"], true)
        XCTAssertEqual(flags["src"], false)
        XCTAssertEqual(flags["README.md"], false)
        XCTAssertEqual(flags[".gitignore"], false)
    }
}
