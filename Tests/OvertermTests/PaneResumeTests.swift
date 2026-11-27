import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermShell

/// P08 (Overcraft-hq/issue-tracker#18), TERM-G2: every pane comes back
/// with its own agent and — a Claude's — its own conversation.
@MainActor
final class PaneResumeTests: XCTestCase {
    // MARK: TERM-G2

    /// Claude's file says the conversation; an earlier process's file with
    /// the same pid, another pid's, or a name that isn't an id says none.
    func testAClaudeProcessSessionFileNamesItsConversation() {
        let id = "0b3c4d5e-1111-4222-8333-944445555666"
        func file(pid: Int, session: String = id, startedAt: Double = 1_700_000_100_000) -> Data {
            Data(#"{"pid":\#(pid),"sessionId":"\#(session)","cwd":"/tmp/x","startedAt":\#(startedAt)}"#.utf8)
        }
        let started: UInt64 = 1_700_000_099_000_000  // µs, a second before it wrote
        XCTAssertEqual(ClaudeProcessSession.sessionID(in: file(pid: 42), pid: 42, started: started), id)
        XCTAssertNil(ClaudeProcessSession.sessionID(in: file(pid: 43), pid: 42, started: started), "another pid's")
        XCTAssertNil(
            ClaudeProcessSession.sessionID(in: file(pid: 42, startedAt: 1_600_000_000_000), pid: 42, started: started),
            "begun before this process: an earlier one with the same pid")
        XCTAssertNil(ClaudeProcessSession.sessionID(in: file(pid: 42, session: "x; rm -rf ~"), pid: 42), "not an id")
        XCTAssertNil(ClaudeProcessSession.sessionID(in: Data("nope".utf8), pid: 42))
    }

    func testTheFileIsReadFromTheSessionsFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = "0b3c4d5e-1111-4222-8333-944445555666"
        try Data(#"{"pid":4242,"sessionId":"\#(id)"}"#.utf8).write(to: folder.appendingPathComponent("4242.json"))
        XCTAssertEqual(ClaudeProcessSession.sessionID(pid: 4242, in: folder), id)
        XCTAssertNil(ClaudeProcessSession.sessionID(pid: 4243, in: folder))
    }

    /// Claude by its conversation's id; without one, and every other
    /// agent, the folder's last conversation.
    func testAResumeTypesItsOwnConversation() {
        let id = "0b3c4d5e-1111-4222-8333-944445555666"
        let launch = AgentLaunch()
        XCTAssertEqual(AgentResume(agent: .claude, session: id).command(launch), "claude --resume \(id)")
        XCTAssertEqual(AgentResume(agent: .claude).command(launch), "claude --continue")
        XCTAssertEqual(AgentResume(agent: .claude, session: "$(boom)").command(launch), "claude --continue")
        XCTAssertEqual(AgentResume(agent: .codex, session: id).command(launch), "codex resume --last")
    }

    /// Each pane says its own; a file from before says the tab's agent,
    /// in its first pane alone — and reads as it did.
    func testEachPaneResumesItsOwnAgent() throws {
        let id = "0b3c4d5e-1111-4222-8333-944445555666"
        let state = SessionState.TabState(
            isPinned: false, agent: .claude,
            panes: .split(axis: "horizontal", ratio: 0.5, first: .pane(directory: "/a"), second: .pane(directory: "/a")),
            paneAgents: [AgentResume(agent: .claude, session: id), AgentResume(agent: .codex)])
        XCTAssertEqual(state.resume(ofPane: 0), AgentResume(agent: .claude, session: id))
        XCTAssertEqual(state.resume(ofPane: 1), AgentResume(agent: .codex))
        XCTAssertNil(state.resume(ofPane: 2))

        let older = try JSONDecoder().decode(SessionState.TabState.self, from: Data(#"{"isPinned":false,"agent":"claude"}"#.utf8))
        XCTAssertEqual(older.resume(ofPane: 0), AgentResume(agent: .claude))
        XCTAssertNil(older.resume(ofPane: 1), "only the first pane resumed it")

        let decoded = try JSONDecoder().decode(SessionState.TabState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    /// What a tab saves: its panes' records, in reading order, or nothing
    /// when none was read (the file then says what older ones said).
    func testATabSavesItsPanesAgents() {
        let first = TerminalView()
        let tab = Tab(terminal: first)
        let second = TerminalView()
        tab.setSplits(.split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second)))
        XCTAssertNil(TerminalWindowController.savedPaneAgents(tab))
        tab.paneResumes[ObjectIdentifier(second)] = AgentResume(agent: .codex)
        XCTAssertEqual(TerminalWindowController.savedPaneAgents(tab), [nil, AgentResume(agent: .codex)])
    }
}
