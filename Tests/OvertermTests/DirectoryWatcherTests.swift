import XCTest

@testable import Overterm

final class DirectoryWatcherTests: XCTestCase {
    /// End to end through FSEvents: the C callback, the unretained context
    /// pointer and the main-queue hop all have to work for this to fire.
    @MainActor
    func testReportsTheChangedDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fired = expectation(description: "change reported for sub/")
        fired.assertForOverFulfill = false
        // What FSEvents reports: the real path (/private/var/…), as a string.
        let resolved = FileTreeModel.realPath(dir.appendingPathComponent("sub"))
        let watcher = try XCTUnwrap(
            DirectoryWatcher(root: dir, latency: 0.05) { urls in
                if urls.contains(where: { $0 == resolved || $0 == resolved + "/" }) { fired.fulfill() }
            })
        defer { watcher.stop() }

        // FSEvents only reports events after the stream is live.
        try await Task.sleep(nanoseconds: 200_000_000)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("sub/new.txt").path, contents: Data())
        await fulfillment(of: [fired], timeout: 5)
    }

    /// With file events: each file, with what happened to it — created,
    /// modified, removed — at FSEvents' real path.
    @MainActor
    func testFileEventsNameEachFileAndWhatHappened() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overterm-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("envs/prod"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = FileTreeModel.realPath(dir.appendingPathComponent("envs/prod")) + "/main.tf"

        var seen: [DirectoryWatcher.Event] = []
        let watcher = try XCTUnwrap(DirectoryWatcher(roots: [dir], latency: 0.05, fileEvents: { seen.append(contentsOf: $0) }))
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)

        func flags() -> DirectoryWatcher.Flags {
            seen.filter { $0.path == file }.reduce(into: DirectoryWatcher.Flags()) { $0.formUnion($1.flags) }
        }
        func eventually(_ condition: () -> Bool) async throws {
            for _ in 0..<250 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        // Written in place (an atomic write is a rename: `.renamed`).
        try Data("terraform {}\n".utf8).write(to: URL(fileURLWithPath: file))
        try await eventually { flags().contains(.created) }
        XCTAssertTrue(flags().contains([.created, .isFile]), "\(seen)")

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("# more\n".utf8))
        try handle.close()
        try await eventually { flags().contains(.modified) }
        XCTAssertTrue(flags().contains(.modified), "\(seen)")

        try FileManager.default.removeItem(atPath: file)
        try await eventually { flags().contains(.removed) }
        XCTAssertTrue(flags().contains(.removed), "\(seen)")
    }
}
