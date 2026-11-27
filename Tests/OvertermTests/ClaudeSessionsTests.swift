import SQLite3
import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermDocker
@testable import OvertermKubernetes
@testable import OvertermTerraform
@testable import OvertermShell
@testable import OvertermOvergit
@testable import OvertermAPI
@testable import OvertermNotes
@testable import OvertermSimulator
@testable import OvertermUsage
@testable import OvertermSettingsPage
@testable import OvertermAgents
@testable import OvertermActivity
@testable import OvertermE2E

final class ClaudeSessionsTests: XCTestCase {
    func testResumeCommandOnlyForARealSessionID() {
        XCTAssertEqual(Agent.claudeResume(session: "8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33"), "claude --resume 8f2c1e0a-1b2c-4d3e-9f00-aa11bb22cc33")
        XCTAssertNil(Agent.claudeResume(session: "x; rm -rf ~"), "typed into a shell: nothing but a UUID")
        XCTAssertNil(Agent.claudeResume(session: ""))
    }

    private func session(_ id: String, _ directory: String) -> AgentSession {
        AgentSession(ClaudeSession(id: id, file: URL(fileURLWithPath: "/tmp/\(id).jsonl"), directory: directory, updated: Date(), activity: ClaudeActivity()))
    }

    func testARunningClaudeIsItsResumedSessionElseTheNewestThere() {
        let tabA = UUID(), tabB = UUID()
        let sessions = [session("aa", "/r"), session("bb", "/r"), session("cc", "/wt")]  // newest first
        let running = SessionsModel.running(
            sessions,
            [
                .init(tab: tabA, directory: "/r", resumes: "bb"),
                .init(tab: tabB, directory: "/wt", resumes: nil),
            ])
        XCTAssertEqual(running, ["bb": tabA, "cc": tabB])
        let unknown = SessionsModel.running(sessions, [.init(tab: tabA, directory: "/r", resumes: nil)])
        XCTAssertEqual(unknown, ["aa": tabA], "without --resume: the newest in its directory")
    }
}

/// opencode's sessions in the Sessions panel: read from its own database,
/// read-only, picked back up with `opencode --session <id>`.
final class OpencodeSessionsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A database with opencode 1.x's tables, as far as the list reads them.
    private func database(_ statements: [String]) throws -> URL {
        let file = folder.appendingPathComponent("opencode.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            "CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text, slug text NOT NULL, directory text NOT NULL, title text NOT NULL, version text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer)",
            "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
            "CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL)",
        ]
        for sql in schema + statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        return file
    }

    private func session(_ id: String, _ directory: String, _ title: String, updated: Int, parent: String? = nil, archived: Bool = false) -> String {
        "INSERT INTO session VALUES ('\(id)', 'p', \(parent.map { "'\($0)'" } ?? "NULL"), 's', '\(directory)', '\(title)', '1', 0, \(updated), \(archived ? "1" : "NULL"))"
    }

    private func typed(_ session: String, _ text: String, at time: Int) -> [String] {
        [
            "INSERT INTO message VALUES ('m\(time)', '\(session)', \(time), \(time), '{\"role\":\"user\"}')",
            "INSERT INTO part VALUES ('p\(time)', 'm\(time)', '\(session)', \(time), \(time), '{\"type\":\"text\",\"text\":\"\(text)\"}')",
        ]
    }

    func testItsSessionsInTheCheckoutNewestFirst() throws {
        let db = try database(
            [
                session("ses_aaa1", "/work/acme", "Fix the login", updated: 3_000),
                session("ses_bbb2", "/work/acme/api", "New session - 2026-11-27T10:00:00.000Z", updated: 5_000),
                session("ses_ccc3", "/work/other", "Elsewhere", updated: 9_000),
                session("ses_ddd4", "/work/acme", "A subagent", updated: 8_000, parent: "ses_aaa1"),
                session("ses_eee5", "/work/acme", "Archived", updated: 7_000, archived: true),
                session("ses_fff6", "/work/acme-other", "A look-alike", updated: 6_000),
            ] + typed("ses_bbb2", "first", at: 4_100) + typed("ses_bbb2", "add the test", at: 4_900))
        let listed = OpencodeSessions.list(in: ["/work/acme"], database: db)
        XCTAssertEqual(listed.map(\.id), ["ses_bbb2", "ses_aaa1"], "below the checkout, top-level, not archived, newest first")
        XCTAssertEqual(listed.first?.agent, .opencode)
        XCTAssertNil(listed.first?.title, "opencode's placeholder isn't a title")
        XCTAssertEqual(listed.first?.lastPrompt, "add the test", "the newest thing typed")
        XCTAssertEqual(listed.first?.updated, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(listed.last?.title, "Fix the login")
        XCTAssertNil(listed.first?.file)
    }

    func testWhatWasTypedNotWhatOpencodeAddedAndNoEmptyOnes() throws {
        let db = try database(
            [
                session("ses_typed", "/w", "New session - x", updated: 2_000),
                session("ses_empty", "/w", "New session - y", updated: 3_000),
                "INSERT INTO message VALUES ('m1', 'ses_typed', 1000, 1000, '{\"role\":\"user\"}')",
                "INSERT INTO part VALUES ('p1', 'm1', 'ses_typed', 1000, 1000, '{\"type\":\"text\",\"text\":\"read @main.go\"}')",
                "INSERT INTO part VALUES ('p2', 'm1', 'ses_typed', 1001, 1001, '{\"type\":\"text\",\"synthetic\":true,\"text\":\"Called the Read tool\"}')",
            ])
        let listed = OpencodeSessions.list(in: ["/w"], database: db)
        XCTAssertEqual(listed.map(\.id), ["ses_typed"], "nothing typed and no title: not a conversation to go back to")
        XCTAssertEqual(listed.first?.lastPrompt, "read @main.go", "opencode's synthetic part isn't what was typed")
    }

    func testARunningOpencodesSessionIsReadOffItsArgv() {
        XCTAssertEqual(ProcessArguments.opencodeSession(in: ["opencode", "--session", "ses_abc123"]), "ses_abc123")
        XCTAssertEqual(ProcessArguments.opencodeSession(in: ["/bin/opencode", "-m", "x", "-s", "ses_abc123"]), "ses_abc123")
        XCTAssertEqual(ProcessArguments.opencodeSession(in: ["opencode", "--session=ses_abc123"]), "ses_abc123")
        XCTAssertNil(ProcessArguments.opencodeSession(in: ["opencode", "--session", "x; rm"]))
        XCTAssertNil(ProcessArguments.opencodeSession(in: ["opencode", "--continue"]))
    }

    func testAnUnreadableDatabaseListsNothing() throws {
        let file = folder.appendingPathComponent("opencode.db")
        try Data("not a database".utf8).write(to: file)
        XCTAssertTrue(OpencodeSessions.list(in: ["/work"], database: file).isEmpty)
        XCTAssertTrue(OpencodeSessions.list(in: ["/work"], database: folder.appendingPathComponent("missing.db")).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("missing.db").path), "read-only: never created")
    }

    func testResumedWithItsOwnFlagAndOnlyARealID() {
        let launch = AgentLaunch(arguments: "-m anthropic/claude-sonnet-4-5")
        let session = AgentSession(agent: .opencode, id: "ses_f47979f00ffexnNN51IyzFMSTG", directory: "/w", updated: Date(), title: nil, lastPrompt: nil, file: nil)
        XCTAssertEqual(session.resumeCommand(launch), "opencode --session ses_f47979f00ffexnNN51IyzFMSTG -m anthropic/claude-sonnet-4-5")
        let bad = AgentSession(agent: .opencode, id: "ses_x; rm -rf ~", directory: "/w", updated: Date(), title: nil, lastPrompt: nil, file: nil)
        XCTAssertNil(bad.resumeCommand(launch), "typed into a shell: ses_ and letters and digits only")
    }

    func testARunningOpencodeIsItsNewestSessionThere() {
        let tab = UUID()
        let sessions = [
            AgentSession(agent: .opencode, id: "ses_new1", directory: "/r", updated: Date(), title: nil, lastPrompt: nil, file: nil),
            AgentSession(agent: .claude, id: "aa", directory: "/r", updated: Date(), title: nil, lastPrompt: nil, file: nil),
        ]
        let running = SessionsModel.running(sessions, [.init(tab: tab, directory: "/r", resumes: nil, agent: .opencode)])
        XCTAssertEqual(running, ["ses_new1": tab], "its own agent's, not the Claude session beside it")
    }
}
