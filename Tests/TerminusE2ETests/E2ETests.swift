import Foundation
import XCTest

/// End-to-end: launches the built Terminus.app once per scenario
/// (TERMINUS_E2E=<name>, see Sources/Terminus/E2E/E2ERunner.swift) and
/// fails with whatever checks the app reported failing.
///
/// Opt-in — each scenario opens a real window for a few seconds:
///     make e2e      (= make app && TERMINUS_E2E_TESTS=1 swift test --filter TerminusE2ETests)
/// The runs are isolated from the real app's state (AppEnvironment): own
/// defaults suite, temp support dir, no notifications, never activated.
final class E2ETests: XCTestCase {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Terminus.app/Contents/MacOS/Terminus")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TERMINUS_E2E_TESTS"] == "1", "E2E is opt-in: make e2e")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.app.path), "build the app first: make app")
    }

    private func run(_ scenario: String, env extra: [String: String] = [:], timeout: TimeInterval = 120) throws {
        let process = Process()
        process.executableURL = Self.app
        var env = ProcessInfo.processInfo.environment
        env["TERMINUS_E2E"] = scenario
        env.removeValue(forKey: "TERMINUS_E2E_TESTS")
        extra.forEach { env[$0.key] = $0.value }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            XCTFail("\(scenario): timed out after \(Int(timeout)) s")
        }
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("E2E ") }
        let passed = lines.filter { $0.hasPrefix("E2E PASS") }
        let failed = lines.filter { $0.hasPrefix("E2E FAIL") }
        for failure in failed { XCTFail("\(scenario): \(failure.dropFirst("E2E FAIL ".count))") }
        XCTAssertTrue(lines.contains { $0.hasPrefix("E2E DONE") }, "\(scenario): never finished — crashed? exit \(process.terminationStatus)")
        XCTAssertFalse(passed.isEmpty, "\(scenario): no checks ran")
        print("\(scenario): \(passed.count) checks passed")
    }

    func testTerminal() throws { try run("terminal") }
    func testTabs() throws { try run("tabs") }
    func testRename() throws { try run("rename") }
    func testPin() throws { try run("pin") }
    func testClose() throws { try run("close") }
    func testEditor() throws { try run("editor") }
    func testDiff() throws { try run("diff") }
    func testBranchDiff() throws { try run("branchDiff") }
    func testWhy() throws { try run("why") }
    func testDiffStyle() throws { try run("diffStyle") }
    func testLayout() throws { try run("layout") }
    func testTask() throws { try run("task") }
    func testSnippets() throws { try run("snippets") }
    func testAttention() throws { try run("attention") }
    func testMarks() throws { try run("marks") }
    func testPalette() throws { try run("palette") }
    func testReorder() throws { try run("reorder") }
    func testInfo() throws { try run("info") }
    func testClaudeInfo() throws { try run("claude") }
    func testDiskInfo() throws { try run("disk") }
    func testFollow() throws { try run("follow") }
    func testSpotlight() throws { try run("spotlight") }
    func testLink() throws { try run("link") }
    func testCleanup() throws { try run("cleanup") }
    func testSplits() throws { try run("splits") }
    func testPullRequest() throws { try run("pullRequest") }
    func testOverview() throws { try run("overview") }
    func testPeek() throws { try run("peek") }
    func testScrollback() throws { try run("scrollback") }
    func testOpenFromFinder() throws { try run("openFromFinder") }
    func testSessions() throws { try run("sessions") }
    func testSettings() throws { try run("settings") }
    func testUpdates() throws { try run("updates") }
    func testPerformance() throws { try run("performance") }
    func testBigFiles() throws { try run("bigFiles") }
    func testClipboard() throws { try run("clipboard") }
    func testOpenWith() throws { try run("openWith") }
    func testDropFiles() throws { try run("dropFiles") }
    func testGroups() throws { try run("groups") }
    func testBlocks() throws { try run("blocks") }

    /// A prepared session.json comes back (pin, colour, names, selection,
    /// directories, a split tab's panes) and changes are autosaved to it.
    func testSession() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-e2e-session-\(UUID().uuidString)")
        let dir = support.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let session = """
            {"selectedIndex":1,"tabs":[
              {"workingDirectory":"\(support.path)","customTitle":"pinned one","color":"green","isPinned":true},
              {"workingDirectory":"\(dir.path)","isPinned":false,"focusedPane":1,"panes":{"split":{"axis":"horizontal","ratio":0.3,
                "first":{"pane":{"directory":"\(support.path)"}},"second":{"pane":{"directory":"\(dir.path)"}}}}}
            ]}
            """
        try Data(session.utf8).write(to: support.appendingPathComponent("session.json"))
        try run("session", env: ["TERMINUS_SUPPORT_DIR": support.path, "TERMINUS_E2E_CWD": dir.path])
    }
}
