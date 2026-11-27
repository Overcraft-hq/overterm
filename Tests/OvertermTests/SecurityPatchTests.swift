import XCTest

@testable import Overterm
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermNotes
@testable import OvertermAPI
@testable import OvertermShell
@testable import OvertermSettingsPage

/// P01's fixes (Overcraft-hq/issue-tracker#11), each held by a check: a
/// text that reaches an agent or a file of the app's carries no secret, and
/// a rule kept in one place is kept where the same thing is done elsewhere.
@MainActor
final class SecurityPatchTests: XCTestCase {
    // MARK: DB-U2

    /// The console's question says which connection, where, and the whole
    /// statement — two consoles side by side, it says which one.
    func testADestroyingStatementIsAskedByItsConnection() {
        var connection = DatabaseConnection(name: "orders-prod", kind: .postgres)
        connection.host = "db.example.internal"
        connection.user = "shop"
        connection.database = "orders"
        let statement = "DELETE FROM orders WHERE note = '" + String(repeating: "x", count: 500) + "' OR 1 = 1"
        let question = SQLConsole.destructiveQuestion(statement, why: "Every row it matches goes.", on: connection)
        XCTAssertEqual(question.title, "Run this on “orders-prod”?")
        XCTAssertEqual(question.scope, "PostgreSQL · shop@db.example.internal:5432/orders")
        XCTAssertTrue(question.detail.contains("OR 1 = 1"), "the whole statement, past 400 characters")
        XCTAssertTrue(question.detail.hasSuffix("Every row it matches goes."))
        XCTAssertTrue(question.destroys, "Return is Don't Run's (D-1)")
    }

    // MARK: NOTE-G6

    func testARemoteImageIsAnImageOrNothing() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(NoteRemoteImage.accept(png, mimeType: "image/png", status: 200)?.dataURL, "data:image/png;base64,iVBORw==")
        XCTAssertNil(NoteRemoteImage.accept(png, mimeType: "text/html", status: 200), "a page is not an image")
        XCTAssertNil(NoteRemoteImage.accept(png, mimeType: "image/png", status: 404))
        XCTAssertNil(NoteRemoteImage.accept(Data(count: NoteRemoteImage.limit + 1), mimeType: "image/png", status: 200))
    }

    func testTheReadingViewLoadsNothingRemoteByItself() throws {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/notes/reader.html")
        let html = try String(contentsOf: page, encoding: .utf8)
        let policy = try XCTUnwrap(html.split(separator: "\n").first { $0.contains("Content-Security-Policy") })
        XCTAssertFalse(policy.contains("https:"), "no remote image, medium or anything else: \(policy)")
        XCTAssertFalse(policy.contains("http:"))
        XCTAssertEqual(SettingsSchema.all.first { $0.key == "notes.remoteImages" }?.defaultValue, .bool(false))
    }

    func testAnIsolatedRunFetchesNoRemoteImage() async {
        let image = await NoteRemoteImage.fetch(URL(string: "https://example.com/a.png")!)
        XCTAssertNil(image, "a test reaches no server")
    }

    // MARK: MCP-G6

    /// Every setting that lets an agent do something is held when the file
    /// changes outside the page: the agent can write settings.json from its
    /// own shell.
    func testEveryAgentSettingIsHeld() {
        let agentKeys = SettingsSchema.all.map(\.key).filter { key in
            key.split(separator: ".").last.map { $0.hasPrefix("agent") } == true
        }
        XCTAssertGreaterThanOrEqual(agentKeys.count, 13)
        for key in agentKeys {
            XCTAssertTrue(SettingsSchema.heldKeys.contains(key), "\(key) isn't held")
        }
        for key in ["browser.agentControl", "api.agentControl", "notes.agentAccess", "notes.agentDrawings", "database.agentAccess", "database.agentWrites", "docker.agentAccess", "docker.agentWrites"]
        {
            XCTAssertTrue(SettingsSchema.heldKeys.contains(key), key)
        }
    }

    // MARK: API-G2

    func testWhatAnAgentIsToldOfARequestHidesItsCredentials() {
        XCTAssertEqual(APIMCP.maskedHeader("Authorization", "Bearer abc.def.ghi"), "••••••")
        XCTAssertEqual(APIMCP.maskedHeader("Set-Cookie", "session=s3cr3t; Path=/"), "••••••")
        XCTAssertEqual(APIMCP.maskedHeader("X-Api-Key", "k-123456"), "••••••")
        XCTAssertEqual(APIMCP.maskedHeader("Content-Type", "application/json"), "application/json")
        let url = URL(string: "https://user:pa55word@api.example.test/v1/orders?page=2&api_key=k-123456&sig=abc")!
        let said = APIMCP.maskedURL(url)
        XCTAssertFalse(said.contains("pa55word") || said.contains("k-123456") || said.contains("sig=abc"), said)
        XCTAssertTrue(said.contains("page=2") && said.contains("/v1/orders"), said)
        // The keychain's values, as the agent's own tools take them out.
        XCTAssertEqual(APIMCP.redact("token k-123456 here", ["k-123456"]), "token ‹secret› here")
    }

    // MARK: DB-G1

    func testHistoryKeepsNoPassword() {
        let cases = [
            ("CREATE USER shop_app PASSWORD 's3cr3t-pw'", "s3cr3t-pw"),
            ("ALTER USER 'app'@'%' IDENTIFIED BY 's3cr3t-pw'", "s3cr3t-pw"),
            ("AUTH s3cr3t-pw", "s3cr3t-pw"),
            ("AUTH default s3cr3t-pw", "s3cr3t-pw"),
            ("HELLO 3 AUTH default s3cr3t-pw", "s3cr3t-pw"),
            ("CONFIG SET requirepass s3cr3t-pw", "s3cr3t-pw"),
            ("ACL SETUSER shop on >s3cr3t-pw ~orders:* +get", "s3cr3t-pw"),
            ("MIGRATE 10.0.0.2 6379 key 0 5000 AUTH s3cr3t-pw", "s3cr3t-pw"),
            (#"db.createUser({ user: "shop", pwd: "s3cr3t-pw", roles: [] })"#, "s3cr3t-pw"),
            (#"db.auth("shop", "s3cr3t-pw")"#, "s3cr3t-pw"),
        ]
        for (statement, password) in cases {
            let masked = OpsText.maskSecrets(statement)
            XCTAssertFalse(masked.contains(password), "\(statement) → \(masked)")
        }
        XCTAssertEqual(OpsText.maskSecrets("SELECT * FROM users WHERE password IS NULL"), "SELECT * FROM users WHERE password IS NULL")
        XCTAssertEqual(OpsText.maskSecrets("GET auth:sessions"), "GET auth:sessions", "a key named auth stays")
    }

    func testTheHistoryFileIsTheUsersAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ot-history-\(UUID().uuidString)/history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        DatabaseModel.write([DatabaseModel.HistoryItem(connection: UUID(), sql: "SELECT 1", date: Date())], to: file)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: EDIT-G11

    func testACommandWithASecretIsNeverKept() async throws {
        for command in [
            "mysql -u root -ps3cr3t-pw shop", "export API_TOKEN=s3cr3t-pw", "curl -H 'Authorization: Bearer abc.def' https://api.example.test",
            "psql postgres://app:s3cr3t-pw@db.example.test/shop", "redis-cli -a s3cr3t-pw ping", "vault login -password=s3cr3t-pw",
        ] {
            XCTAssertTrue(CommandHistory.carriesSecret(command), command)
        }
        for command in ["git status", "make test", "ls -la ~/Downloads", "kubectl get pods -n shop", "echo $TOKEN"] {
            XCTAssertFalse(CommandHistory.carriesSecret(command), command)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ot-cmdhistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = folder.appendingPathComponent("zsh_history")
        try ": 1700000000:0;git status\n: 1700000001:0;export TOKEN=s3cr3t-pw\n: 1700000002:0;make test\n".write(to: shell, atomically: true, encoding: .utf8)
        XCTAssertEqual(CommandHistory.fromShellHistory(file: shell).map(\.command), ["make test", "git status"])

        let history = CommandHistory(url: folder.appendingPathComponent("history.json"))
        history.clear()
        history.record(CommandBlock(id: 1, command: "make test", startRow: 0, endRow: 1, exit: 0), folder: nil)
        history.record(CommandBlock(id: 2, command: "export TOKEN=s3cr3t-pw", startRow: 1, endRow: 2, exit: 0), folder: nil)
        history.record(CommandBlock(id: 3, command: " git push --force", startRow: 2, endRow: 3, exit: 0), folder: nil)
        XCTAssertEqual(history.entries.map(\.command), ["make test"], "a secret, and a line typed with a space first, are left out")
        history.forget("make test")
        XCTAssertTrue(history.entries.isEmpty)
        history.record(CommandBlock(id: 4, command: "make e2e", startRow: 3, endRow: 4, exit: 0), folder: nil)
        await history.saveNow()
        let file = folder.appendingPathComponent("history.json")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("s3cr3t"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    // MARK: MCP-G2

    func testASnapshotSaysOnlyWhetherASecretFieldIsFilled() {
        let page: [String: Any] = [
            "title": "Sign in", "url": "http://localhost:3000/login", "text": "Sign in",
            "elements": [
                ["ref": "e1", "role": "input[email]", "name": "Email", "value": "dev@example.test"],
                ["ref": "e2", "role": "input[password]", "name": "Password", "value": "hunter2-pw"],
                ["ref": "e3", "role": "input[text]", "name": "One-time code", "value": "123456"],
                ["ref": "e4", "role": "input[text]", "name": "Notes", "value": "fine", "secret": true],
            ],
        ]
        let said = BrowserSession.describe(page)
        XCTAssertTrue(said.contains("dev@example.test"))
        XCTAssertFalse(said.contains("hunter2-pw") || said.contains("123456") || said.contains("“fine”"), said)
        XCTAssertEqual(said.components(separatedBy: BrowserSession.secretMask).count - 1, 3)
        XCTAssertTrue(BrowserSession.snapshotScript.contains("el.type === 'password'"))
    }

    // MARK: AGT-G1

    func testAnAnswerEndingInAListIsNoQuestion() {
        let answer = """
            I'd do it in three steps:
            1. Move the parser into Core.
            2. Point the callers at it.
            3. Delete the old copy.

            ╭────────────────────────────────────────╮
            │ >                                      │
            ╰────────────────────────────────────────╯
            """
        XCTAssertNil(AgentPrompt.question(in: answer))
        let asked = """
            Do you want to make this edit to Parser.swift?
            ❯ 1. Yes
              2. Yes, and don't ask again this session
              3. No, and tell Claude what to do differently
            """
        XCTAssertEqual(AgentPrompt.question(in: asked)?.choices.count, 3)
        let codex = """
            Would you like to run the following command?
            $ make test
            › 1. Yes, proceed (y)
              2. No, and tell Codex what to do differently (esc)
              Press enter to confirm or esc to cancel
            """
        XCTAssertNotNil(AgentPrompt.question(in: codex), "a footer after the choices is still a question")
        // One asked earlier, scrolled out of the last 40 lines: none.
        XCTAssertNil(AgentPrompt.question(in: asked + String(repeating: "\noutput", count: 50)))
    }

    // MARK: TERM-G6

    func testSuspendOtherTabsSaysWhatItPassesOver() {
        let a = Tab(terminal: TerminalView())
        a.customTitle = "api"
        let plan = Tab(terminal: TerminalView())
        plan.customTitle = "infra"
        let said = TerminalWindowController.suspendQuestion([a], passedOver: [plan])
        XCTAssertTrue(said.contains("Left running: “infra”."), said)
        XCTAssertTrue(said.hasSuffix(ActivitySignalCheck.terraformSuspend), said)
    }

    // MARK: TERM-G1

    func testABroadcastLeavesOutWhatWouldTakeAReturn() {
        let group = TabGroup(name: "shop", color: .blue)
        let tabs = ["api", "prod", "asks", "held"].map { name -> Tab in
            let tab = Tab(terminal: TerminalView())
            tab.customTitle = name
            return tab
        }
        var holds: [String: BroadcastModel.Held] = ["prod": .production(context: "shop-prod"), "asks": .asking]
        let broadcast = BroadcastModel()
        broadcast.hold = { holds[$0.title] }
        broadcast.members = { _ in tabs }
        broadcast.begin(group: group, tabs: tabs)
        XCTAssertEqual(broadcast.targets.map(\.title), ["api", "held"])
        XCTAssertEqual(broadcast.summary, "Broadcasting to 2 tabs in shop — not to “prod” (production · shop-prod), “asks” (its agent asks)")
        XCTAssertEqual(broadcast.heldProduction, ["shop-prod"])
        // Read again at the send: one suspended since is left out too.
        holds["held"] = .suspended
        broadcast.text = "git pull"
        broadcast.refresh()
        XCTAssertEqual(broadcast.targets.map(\.title), ["api"])
        broadcast.includeProduction("shop-prod")
        XCTAssertEqual(broadcast.targets.map(\.title), ["api", "prod"], "its name typed, a production context is let in")
    }

    // MARK: SET-U1

    func testAStaleDraftIsNeverSavedOverTheFile() {
        let old = "{ \"a\": 1 }", new = "{ \"a\": 2 }", typed = "{ \"a\": 3 }"
        // Untouched: it follows the file.
        XCTAssertTrue(SettingsPageModel.reconcile(draft: old, base: old, saved: new) == (new, new, false))
        // Edited, the file unchanged: kept.
        XCTAssertTrue(SettingsPageModel.reconcile(draft: typed, base: old, saved: old) == (typed, old, false))
        // Edited, and the file changed under it: asked, the draft kept.
        XCTAssertTrue(SettingsPageModel.reconcile(draft: typed, base: old, saved: new) == (typed, old, true))
        // Its own save landing: settled.
        XCTAssertTrue(SettingsPageModel.reconcile(draft: typed, base: typed, saved: typed) == (typed, typed, false))
        XCTAssertTrue(SettingsPageModel.reconcile(draft: nil, base: nil, saved: new) == (new, new, false))
    }
}
