import XCTest

@testable import Overterm
@testable import OvertermAPI
@testable import OvertermCore
@testable import OvertermDatabase
@testable import OvertermKubernetes
@testable import OvertermNotes

/// SEC-N1: every text an agent is handed leaves through one gate
/// (`AgentText`) — a tool's answer over the MCP bridge, an Ask Agent prompt,
/// a brief. Each path below gets a planted token and a planted password
/// field; neither may reach the agent. A new tool is caught too: whatever
/// it returns goes out through the same gate (`testANewToolThatForgetsSecretsHandsOnNothing`).
@MainActor
final class AgentTextGateTests: XCTestCase {
    /// Fictional, shaped as a GitHub token is.
    private let token = "ghp_" + "Q7uokkaR9tVw2XyZ4bC6dE8fG0hJ"
    private let password = "hunter2-Quokka-77"
    private var planted: String { "export GITHUB_TOKEN=\(token)\n{\"password\": \"\(password)\"}" }

    private func assertClean(_ text: String?, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let text else { return XCTFail("\(path): nothing came back", file: file, line: line) }
        XCTAssertFalse(text.contains(token.dropFirst(4)), "\(path) handed on the token:\n\(text)", file: file, line: line)
        XCTAssertFalse(text.contains(password), "\(path) handed on the password:\n\(text)", file: file, line: line)
    }

    // MARK: The bridge

    private func call(_ name: String, _ arguments: [String: Any] = [:], browser: AgentBrowser? = nil) async -> [String: Any]? {
        await BrowserMCP.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]], browser: { browser })
    }

    private func text(_ answer: [String: Any]?) -> String? {
        if let error = answer?["error"] as? [String: Any] { return error["message"] as? String }
        return ((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A feature's tool for the length of `body`, as `OvertermFeatures`
    /// installs one.
    private func withTool(_ name: String, _ call: @escaping @MainActor @Sendable ([String: Any]) async throws -> Any, _ body: () async -> Void) async {
        _ = BrowserMCP.features
        let saved = BrowserMCP.featuresStorage
        BrowserMCP.featuresStorage.append(
            BrowserMCP.Provider(
                handles: { $0 == name }, enabled: { _ in true }, unavailable: "", tools: { [] }, instructions: { _ in "" },
                call: { _, arguments, _ in try await call(arguments) }))
        defer { BrowserMCP.featuresStorage = saved }
        await body()
    }

    func testANewToolThatForgetsSecretsHandsOnNothing() async {
        let planted = planted
        await withTool("gate_new", { _ in BrowserMCP.textResult(planted) }) {
            assertClean(text(await call("gate_new")), "a tool's answer")
        }
        await withTool("gate_failing", { _ in throw BrowserMCP.ToolError(message: planted) }) {
            assertClean(text(await call("gate_failing")), "a tool's error")
        }
        await withTool("gate_said", { _ in BrowserMCP.errorResult(planted) }) {
            assertClean(text(await call("gate_said")), "a tool's error result")
        }
    }

    /// DB-G3: a query's rows, a `password_hash` and an `api_token` column
    /// among them, and a token in a plain one.
    func testADatabaseQueryAnswer() async {
        let result = QueryResult(
            columns: ["id", "author", "password_hash", "api_token", "note", "token_count"],
            rows: [["1", "Ada Quokka", "$2b$12$" + password, "tok-" + password, "uses \(token)", "42"]])
        await withTool("gate_db", { _ in BrowserMCP.textResult(DatabaseMCP.report(result)) }) {
            let answer = text(await call("gate_db"))
            assertClean(answer, "db_query")
            XCTAssertTrue(answer?.contains("Ada Quokka") == true && answer?.contains("| 42") == true, answer ?? "")
        }
    }

    /// NOTE-G5: a note read by `notes_read`.
    func testANoteRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gate-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Deploy\n\n\(planted)\n".write(to: dir.appendingPathComponent("Deploy.md"), atomically: true, encoding: .utf8)
        let notes = NotesModel(vault: NotesVault(root: dir))
        await withTool("gate_notes", { arguments in try await NotesMCP.call("notes_read", arguments, notes: notes) }) {
            let answer = text(await call("gate_notes", ["note": "Deploy"]))
            assertClean(answer, "notes_read")
            XCTAssertTrue(answer?.contains("# Deploy") == true, answer ?? "")
        }
    }

    /// MCP-G2: a page's snapshot, its text holding a token and a password.
    func testABrowserSnapshot() async throws {
        try XCTSkipUnless(Settings.shared.browserAgentControl, "the browser's agent control is off in this run's settings")
        let browser = GateBrowser(page: "Page: Settings\nURL: http://localhost:3000/\n\n\(planted)\nAuthorization: Bearer \(token)")
        assertClean(text(await call("browser_snapshot", browser: browser)), "browser_snapshot")
    }

    // MARK: Ask Agent

    private func prompt(_ selection: String, parts: [AskAgentModel.Part] = [], diff: String? = nil) -> String {
        let model = AskAgentModel()
        model.begin(selection: selection, command: nil, folder: nil, targets: [], diff: diff != nil, parts: parts)
        if diff != nil { model.extras.diff = true }
        return model.agentText(diff: diff).text
    }

    /// AGT-G4: ⌘L over a plain shell tab — no pod, no pinned context.
    func testAPlainTabsSelection() {
        let selection = AskSelection.text(planted, kind: .shell, pinned: false)
        assertClean(prompt(selection), "a shell tab's selection")
        let model = AskAgentModel()
        model.begin(selection: selection, command: nil, folder: nil, targets: [], diff: false)
        assertClean(model.prompt(diff: nil), "the sheet's preview")
    }

    /// API-G2: Ask an Agent over a response, as `APIRequestModel.askAgent`
    /// hands it to the sheet.
    func testAnAPIResponseHandedOn() {
        let body = Data("{\"user\": \"ada\", \"password\": \"\(password)\", \"token\": \"\(token)\"}".utf8)
        var result = APIExecution.Result()
        result.response = APIResponse(status: 200, headers: [], body: body, duration: 12)
        let handed = "Request: Login — /api/login.bru\n\n" + APIMCP.forAgent(result, secrets: [], limit: 8000)
        assertClean(prompt(handed), "an API response")
    }

    /// A brief's parts and the git diff chip go through the same gate.
    func testABriefsPartsAndTheDiff() {
        let parts = [AskAgentModel.Part(title: "logs", text: "Its last lines:\n\(planted)")]
        assertClean(prompt("Container shop-worker-1", parts: parts, diff: "+  token: \(token)\n+  password=\(password)"), "a brief")
    }

    // MARK: What the features already masked stays as it was

    func testTheGateLeavesMaskedTextAsItWas() {
        let samples = [
            KubeMCPText.scrubbed("env: DB_URL=postgres://app:\(password)@db:5432/app token=\(token)"),
            TerraformValidation.scrub("Error: auth failed: password = \"\(password)\""),
            Secrets.scrub("POSTGRES_PASSWORD=\(password) started", env: [("POSTGRES_PASSWORD", password)]),
            "NAME READY STATUS\nshop-worker-1 1/1 Running\nsha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "-----BEGIN PRIVATE KEY----- •••••• -----END PRIVATE KEY-----",
        ]
        for sample in samples {
            XCTAssertEqual(AgentText.scrub(sample), sample)
            XCTAssertEqual(AgentText.scrub(AgentText.scrub(sample)), AgentText.scrub(sample))
        }
    }

    func testSecretColumnsByTheirWords() {
        for name in ["password_hash", "passwd", "api_token", "apiKey", "client_secret", "salt", "privateKey", "refresh_token", "session_key"] {
            XCTAssertTrue(Secrets.isSecretColumn(name), name)
        }
        for name in ["author", "primary_key", "keyword", "token_count", "password_changed_at", "api_key_id", "monkey", "id", "authored_at"] {
            XCTAssertFalse(Secrets.isSecretColumn(name), name)
        }
    }
}

/// A page with one snapshot: what the bridge's browser tools read.
private final class GateBrowser: AgentBrowser {
    let page: String
    init(page: String) { self.page = page }
    var currentURL: URL? { URL(string: "http://localhost:3000/") }
    func navigate(_ url: URL, timeout: TimeInterval) async throws {}
    func snapshot() async throws -> String { page }
    func click(ref: String) async throws {}
    func type(ref: String, text: String, submit: Bool) async throws {}
    func evaluate(_ script: String) async throws -> String { page }
    func screenshot() async throws -> Data { Data() }
    func consoleText(onlyErrors: Bool, limit: Int) -> String { page }
    func goBack() {}
    func reload() {}
    func waitForLoad(timeout: TimeInterval) async throws {}
    func tabsDescription(showing: (URL) -> String) -> String { "" }
    func url(ofTab index: Int) -> URL? { nil }
    func openTab(_ url: URL?, timeout: TimeInterval) async throws {}
    func selectTab(_ index: Int) throws {}
    func closeTab(_ index: Int) throws {}
    func holdAgentGuard(_ allows: @escaping (URL) -> Bool) {}
    func releaseAgentGuard(after seconds: TimeInterval) {}
    func takeBlockedNavigation() -> BlockedNavigation? { nil }
    func follow(_ blocked: BlockedNavigation, timeout: TimeInterval) async throws {}
}
