import XCTest

@testable import Overterm

@MainActor
final class OvergitModelTests: XCTestCase {
    private var repo: URL!
    /// A plain `swift test` run shares the app's real defaults, and
    /// `toggle` writes which sections are open. Put it back.
    private var savedSections: [String]?

    override func setUp() async throws {
        savedSections = AppEnvironment.defaults.stringArray(forKey: "overgitSections")
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-overgit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"])
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", "Add a"])
        try await git(["tag", "v1.0"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repo)
        if let savedSections {
            AppEnvironment.defaults.set(savedSections, forKey: "overgitSections")
        } else {
            AppEnvironment.defaults.removeObject(forKey: "overgitSections")
        }
    }

    private func git(_ arguments: [String]) async throws {
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=T"] + arguments, in: repo)
    }

    func testReadsTheOpenSectionsOfARealRepository() async {
        let model = OvergitModel()
        model.visible = true
        model.setRoot(repo)
        await model.refresh()
        XCTAssertTrue(model.isRepository)
        XCTAssertEqual(model.commits.map(\.subject), ["Add a"])
        XCTAssertEqual(model.graph.count, 1)
        XCTAssertEqual(model.branches.map(\.name), ["main"])
        XCTAssertNil(model.error)
    }

    /// The point of the whole design: a section nobody opened costs
    /// nothing.
    func testAShutSectionIsNotRead() async {
        let model = OvergitModel()
        model.visible = true
        model.setRoot(repo)
        await model.refresh()
        XCTAssertTrue(model.tags.isEmpty, "Tags is shut by default")

        model.toggle(.tags)
        await model.refresh()
        XCTAssertEqual(model.tags.map(\.name), ["v1.0"])

        // Shutting it keeps what it read — reopening should not blink.
        model.toggle(.tags)
        XCTAssertEqual(model.tags.map(\.name), ["v1.0"])
    }

    /// Nothing is read at all while the panel is not the one on screen.
    func testAPanelThatIsNotShowingReadsNothing() async {
        let model = OvergitModel()
        model.setRoot(repo)
        await model.refresh()
        XCTAssertTrue(model.commits.isEmpty)
        XCTAssertFalse(model.isRepository)

        model.visible = true
        await model.refresh()
        XCTAssertEqual(model.commits.count, 1)
    }

    func testOutsideARepository() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let model = OvergitModel()
        model.visible = true
        model.setRoot(plain)
        await model.refresh()
        XCTAssertFalse(model.isRepository)
        XCTAssertTrue(model.commits.isEmpty)
        XCTAssertNil(model.error, "not being a repository is not an error to show")
    }

    /// A tab switch moves the root; what the old one's git said must not
    /// land in the new one's panel.
    func testTheRootIsClearedWhenItMoves() async {
        let model = OvergitModel()
        model.visible = true
        model.setRoot(repo)
        await model.refresh()
        XCTAssertFalse(model.commits.isEmpty)
        model.setRoot(FileManager.default.temporaryDirectory)
        XCTAssertTrue(model.commits.isEmpty, "the old checkout's history goes with it")
        XCTAssertNil(model.selected)
    }

    /// `worktrees` and `pullRequests` are the window's, not git's: the
    /// panel shows them but never reads them.
    func testTheSectionsThatAreNotRead() {
        XCTAssertFalse(OvergitModel.Section.worktrees.isRead)
        XCTAssertFalse(OvergitModel.Section.pullRequests.isRead)
        XCTAssertTrue(OvergitModel.Section.commits.isRead)
    }

    /// `worktrees` was a panel of its own; somebody who left the sidebar
    /// there lands in Overgit, where their worktrees went.
    func testTheOldWorktreesPanelMapsToOvergit() {
        XCTAssertEqual(SidebarPanel(stored: "worktrees"), .git)
        XCTAssertEqual(SidebarPanel(stored: "snippets"), .snippets)
        XCTAssertEqual(SidebarPanel(stored: nil), .files)
        XCTAssertEqual(SidebarPanel(stored: "nonsense"), .files)
    }
}
