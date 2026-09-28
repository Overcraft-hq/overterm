import XCTest

@testable import Terminus

final class DirectoryWatcherTests: XCTestCase {
    /// End to end through FSEvents: the C callback, the unretained context
    /// pointer and the main-queue hop all have to work for this to fire.
    @MainActor
    func testReportsTheChangedDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-watch-\(UUID().uuidString)")
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
}
