import XCTest

@testable import Terminus

final class DiskUsageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-disk-\(UUID().uuidString)")
        for sub in ["node_modules/a", "src", ".git"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data(count: 400_000).write(to: dir.appendingPathComponent("node_modules/a/big.js"))
        try Data(count: 50_000).write(to: dir.appendingPathComponent("src/main.swift"))
        try Data(count: 120_000).write(to: dir.appendingPathComponent(".git/pack"))
        try Data(count: 1_000).write(to: dir.appendingPathComponent("README.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTotalsAndLargestEntries() throws {
        let report = try XCTUnwrap(DiskUsage.measure(dir))
        XCTAssertEqual(report.files, 4)
        XCTAssertGreaterThanOrEqual(report.total, 571_000, "allocated size is at least the bytes written")
        XCTAssertEqual(report.largest.map(\.name).prefix(3), ["node_modules", ".git", "src"])
        XCTAssertFalse(report.partial)
    }

    func testDoesNotFollowSymlinks() throws {
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("loop"), withDestinationURL: dir)
        let report = try XCTUnwrap(DiskUsage.measure(dir))
        XCTAssertEqual(report.files, 4, "a symlink back to the root is not walked")
    }

    func testCancellation() {
        let cancellation = Cancellation()
        cancellation.cancel()
        XCTAssertNil(DiskUsage.measure(dir, cancellation: cancellation))
    }
}
