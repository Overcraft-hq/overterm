import XCTest

@testable import Terminus

final class SessionStateTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("terminus-session-\(UUID().uuidString)/session.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testRoundTrips() throws {
        let state = SessionState(
            tabs: [
                .init(workingDirectory: "/repo", customTitle: "main", color: "blue", isPinned: true, agent: nil),
                .init(workingDirectory: "/repo-wt-x", customTitle: nil, color: nil, isPinned: false, agent: .claude, attachedCheckout: "/repo-wt-y"),
            ],
            selectedIndex: 1)
        try state.save(to: url)
        XCTAssertEqual(SessionState.load(from: url), state)
    }

    func testASessionFromBeforeAttachingStillLoads() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"selectedIndex":0,"tabs":[{"workingDirectory":"/repo","isPinned":false}]}"#.utf8).write(to: url)
        XCTAssertEqual(SessionState.load(from: url)?.tabs.first?.attachedCheckout, nil)
        XCTAssertEqual(SessionState.load(from: url)?.tabs.count, 1)
    }

    func testMissingOrCorruptFileIsNil() throws {
        XCTAssertNil(SessionState.load(from: url))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(SessionState.load(from: url))
    }

    func testUnknownAgentIsACorruptFileNotACrash() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"tabs":[{"isPinned":false,"agent":"gemini"}]}"#.utf8).write(to: url)
        XCTAssertNil(SessionState.load(from: url))
    }
}
