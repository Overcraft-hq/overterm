import XCTest

@testable import Terminus

final class DiffModelTests: XCTestCase {
    /// Opening the panel starts its own refresh, and a newer refresh
    /// supersedes an older one's results by design — so wait for the model
    /// to settle rather than for one particular call.
    @MainActor
    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func testReportsChangesAndDiffsTheSelectedFile() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Git.run(["add", "."], in: repo)
        _ = try await Git.run(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], in: repo)

        try "one\nTWO\nthree\nfour\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: repo.appendingPathComponent("new file.txt"), atomically: true, encoding: .utf8)

        let model = DiffModel()
        model.setRoot(repo)
        model.isActive = true
        defer { model.isActive = false }
        await model.refresh()
        try await eventually { !model.lines.isEmpty }

        XCTAssertEqual(model.branch, "main")
        XCTAssertEqual(model.files.map(\.path), ["a.txt", "new file.txt"])
        let a = try XCTUnwrap(model.files.first)
        XCTAssertEqual(a.kind, .modified)
        XCTAssertEqual([a.added, a.removed], [2, 1])
        XCTAssertEqual(model.files[1].kind, .untracked)

        // The first file is selected and diffed.
        XCTAssertEqual(model.selectedPath, "a.txt")
        XCTAssertEqual(model.lines.filter { $0.kind == .added }.map(\.text), ["TWO", "four"])
        XCTAssertEqual(model.lines.filter { $0.kind == .removed }.map(\.text), ["two"])

        // An untracked file diffs against /dev/null (git exits 1 for that).
        model.select("new file.txt")
        try await eventually { model.lines.contains { $0.text == "fresh" } }
        XCTAssertEqual(model.lines.filter { $0.kind == .added }.map(\.text), ["fresh"])
    }

    @MainActor
    func testOutsideARepositorySaysSo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-nodiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DiffModel()
        model.setRoot(dir)
        model.isActive = true
        defer { model.isActive = false }
        await model.refresh()
        try await eventually { model.error != nil }
        XCTAssertEqual(model.error, "Not a git repository")
        XCTAssertTrue(model.files.isEmpty)
    }

    @MainActor
    func testStageCommitAndDiscard() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try await Git.run(["config", "user.email", "t@t"], in: repo)
        _ = try await Git.run(["config", "user.name", "t"], in: repo)
        for name in ["keep.txt", "throw.txt"] {
            try "v1\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        _ = try await Git.run(["add", "."], in: repo)
        _ = try await Git.run(["commit", "-q", "-m", "init"], in: repo)
        for name in ["keep.txt", "throw.txt"] {
            try "v2\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let model = DiffModel()
        model.setRoot(repo)
        model.isActive = true
        defer { model.isActive = false }
        await model.refresh()
        try await eventually { model.files.count == 2 }

        let keep = try XCTUnwrap(model.files.first { $0.path == "keep.txt" })
        await model.toggleStaged(keep)
        try await eventually { model.stagedCount == 1 }
        XCTAssertEqual(model.files.first { $0.path == "keep.txt" }?.stageState, .full)

        let throwAway = try XCTUnwrap(model.files.first { $0.path == "throw.txt" })
        await model.discard(throwAway)
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
}
