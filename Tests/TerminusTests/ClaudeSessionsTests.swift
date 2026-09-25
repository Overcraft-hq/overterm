import XCTest

@testable import Terminus

final class ClaudeSessionsTests: XCTestCase {
    func testResumeCommandOnlyForARealSessionID() {
        XCTAssertEqual(Agent.claudeResume(session: "8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33"), "claude --resume 8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33")
        XCTAssertNil(Agent.claudeResume(session: "x; rm -rf ~"), "typed into a shell: nothing but a UUID")
        XCTAssertNil(Agent.claudeResume(session: ""))
    }

    private func session(_ id: String, _ directory: String) -> ClaudeSession {
        ClaudeSession(id: id, file: URL(fileURLWithPath: "/tmp/\(id).jsonl"), directory: directory, updated: Date(), activity: ClaudeActivity())
    }

    func testARunningClaudeIsItsResumedSessionElseTheNewestThere() {
        let tabA = UUID(), tabB = UUID()
        let sessions = [session("aa", "/r"), session("bb", "/r"), session("cc", "/wt")]  // newest first
        let running = SessionsModel.running(
            sessions,
            [
                .init(tab: tabA, directory: "/r", command: "claude --resume bb"),
                .init(tab: tabB, directory: "/wt", command: "claude"),
            ])
        XCTAssertEqual(running, ["bb": tabA, "cc": tabB])
        let unknown = SessionsModel.running(sessions, [.init(tab: tabA, directory: "/r", command: "claude")])
        XCTAssertEqual(unknown, ["aa": tabA], "without --resume: the newest in its directory")
    }
}
