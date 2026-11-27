import XCTest

@testable import OvertermUsage

/// `claude -p "/usage"` without a session left behind (D-15), and the one
/// failure that drops the flag.
final class AgentUsageCommandTests: XCTestCase {
    func testAsksWithoutPersistingASession() {
        XCTAssertEqual(AgentUsageCommand.arguments(persisting: false), ["-p", "/usage", "--no-session-persistence"])
        XCTAssertEqual(AgentUsageCommand.arguments(persisting: true), ["-p", "/usage"])
    }

    func testOnlyAnUnknownFlagDropsIt() {
        // Claude Code 2.1's words for a flag it doesn't know.
        XCTAssertTrue(AgentUsageCommand.refusesFlag(status: 1, stderr: "error: unknown option '--no-session-persistence'\n"))
        // Anything else keeps the flag: a network error, a timeout, another option.
        XCTAssertFalse(AgentUsageCommand.refusesFlag(status: 1, stderr: "API Error: Connection error."))
        XCTAssertFalse(AgentUsageCommand.refusesFlag(status: 15, stderr: ""))
        XCTAssertFalse(AgentUsageCommand.refusesFlag(status: 1, stderr: "error: unknown option '--verbose'"))
        XCTAssertFalse(AgentUsageCommand.refusesFlag(status: 0, stderr: "error: unknown option '--no-session-persistence'"))
    }
}
