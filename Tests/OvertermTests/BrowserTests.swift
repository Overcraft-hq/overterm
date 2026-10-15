import XCTest

@testable import Overterm

final class BrowserLinksTests: XCTestCase {
    func testWhatIsLocal() {
        for local in [
            "http://localhost:3000", "http://127.0.0.1:8080/x", "http://0.0.0.0:5173", "http://[::1]:3000", "http://app.localhost",
            "http://192.168.1.20:3000", "http://10.0.0.5", "http://172.20.1.1", "https://myapp.test",
        ] {
            XCTAssertTrue(BrowserLinks.isLocal(URL(string: local)!), local)
        }
        for remote in ["https://github.com", "http://172.32.0.1", "http://8.8.8.8", "https://localhost.example.com"] {
            XCTAssertFalse(BrowserLinks.isLocal(URL(string: remote)!), remote)
        }
    }

    func testPolicies() {
        let local = URL(string: "http://localhost:3000")!
        let remote = URL(string: "https://github.com")!
        XCTAssertTrue(BrowserLinks.opensInside(local, policy: .local))
        XCTAssertFalse(BrowserLinks.opensInside(remote, policy: .local))
        XCTAssertTrue(BrowserLinks.opensInside(remote, policy: .all))
        XCTAssertFalse(BrowserLinks.opensInside(local, policy: .none))
        XCTAssertFalse(BrowserLinks.opensInside(URL(string: "mailto:a@b.c")!, policy: .all), "not a web page")
    }

    func testTypedAddresses() {
        XCTAssertEqual(BrowserLinks.url(fromTyped: "localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserLinks.url(fromTyped: ":5173")?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(BrowserLinks.url(fromTyped: "github.com/x")?.absoluteString, "https://github.com/x")
        XCTAssertEqual(BrowserLinks.url(fromTyped: "https://a.dev")?.absoluteString, "https://a.dev")
        XCTAssertEqual(BrowserLinks.url(fromTyped: "how to swift")?.host, "duckduckgo.com")
        XCTAssertNil(BrowserLinks.url(fromTyped: "  "))
    }
}

final class HTTPRequestTests: XCTestCase {
    func testParsesAPostInPieces() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp/abc HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer t\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = Data(raw.utf8)
        XCTAssertEqual(HTTPRequest.parse(data.prefix(20)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(data.dropLast(3)), .incomplete, "the body isn't all in")
        guard case .complete(let request) = HTTPRequest.parse(data) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp/abc")
        XCTAssertEqual(request.headers["authorization"], "Bearer t")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), body)
    }

    func testRejectsGarbage() {
        XCTAssertEqual(HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8)), .invalid)
        XCTAssertEqual(HTTPRequest.parse(Data("GET / HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)), .invalid)
    }
}

/// A browser that records what it was asked.
@MainActor
private final class FakeBrowser: AgentBrowser {
    var log: [String] = []
    var page = "Page: Home\nURL: http://localhost:3000/\n\nControls (use the ref):\n- [e1] button “Save”"

    func navigate(_ url: URL, timeout: TimeInterval) async throws { log.append("navigate \(url.absoluteString)") }
    func snapshot() async throws -> String { page }
    func click(ref: String) async throws {
        guard ref == "e1" else { throw BrowserError.noElement(ref) }
        log.append("click \(ref)")
        page = page.replacingOccurrences(of: "Save", with: "Saved")
    }
    func type(ref: String, text: String, submit: Bool) async throws { log.append("type \(ref) \(text) \(submit)") }
    func evaluate(_ script: String) async throws -> String { "42" }
    func screenshot() async throws -> Data { Data([0x89, 0x50, 0x4E, 0x47]) }
    func consoleText(onlyErrors: Bool, limit: Int) -> String { onlyErrors ? "[error] boom" : "[log] hi\n[error] boom" }
    func goBack() { log.append("back") }
    func reload() { log.append("reload") }
    func waitForLoad(timeout: TimeInterval) async throws {}
    var tabs = ["Home"]
    var current = 0
    func tabsDescription() -> String { tabs.enumerated().map { "\($0 == current ? "*" : " ") [\($0)] \($1)" }.joined(separator: "\n") }
    func openTab(_ url: URL?, timeout: TimeInterval) async throws {
        tabs.append(url?.absoluteString ?? "new")
        current = tabs.count - 1
    }
    func selectTab(_ index: Int) throws {
        guard tabs.indices.contains(index) else { throw BrowserError.noTab(index) }
        current = index
    }
    func closeTab(_ index: Int) throws {
        guard tabs.indices.contains(index) else { throw BrowserError.noTab(index) }
        tabs.remove(at: index)
        current = min(current, tabs.count - 1)
    }
}

@MainActor
final class BrowserMCPTests: XCTestCase {
    private let browser = FakeBrowser()

    private func call(_ method: String, _ params: [String: Any] = [:], id: Any = 1) async -> [String: Any]? {
        await BrowserMCP.handle(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) { self.browser }
    }

    private func text(_ answer: [String: Any]?) -> String? {
        ((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    func testInitializeAndList() async {
        let initialize = await call("initialize", ["protocolVersion": "2025-03-26"])
        let result = initialize?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26", "the client's version, echoed")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "overterm-browser")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        let names = ((await call("tools/list"))?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(
            Set(names?.compactMap { $0["name"] as? String } ?? []),
            [
                "browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_screenshot", "browser_console",
                "browser_evaluate", "browser_back", "browser_reload", "browser_tabs", "browser_tab_new", "browser_tab_select",
                "browser_tab_close",
            ])
    }

    func testNotificationsGetNoAnswer() async {
        let answer = await BrowserMCP.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) { self.browser }
        XCTAssertNil(answer)
    }

    func testTools() async {
        let navigated = await call("tools/call", ["name": "browser_navigate", "arguments": ["url": ":3000"]])
        XCTAssertEqual(browser.log.first, "navigate http://localhost:3000")
        XCTAssertTrue(text(navigated)?.contains("[e1]") == true)
        let clicked = await call("tools/call", ["name": "browser_click", "arguments": ["ref": "e1"]])
        XCTAssertTrue(text(clicked)?.contains("Saved") == true, "the snapshot after the click")
        _ = await call("tools/call", ["name": "browser_type", "arguments": ["ref": "e2", "text": "hello", "submit": true]])
        XCTAssertTrue(browser.log.contains("type e2 hello true"))
        let console = await call("tools/call", ["name": "browser_console", "arguments": ["errors_only": true]])
        XCTAssertEqual(text(console), "[error] boom")
        let shot = await call("tools/call", ["name": "browser_screenshot"])
        let image = ((shot?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(image?["type"] as? String, "image")
        XCTAssertEqual(image?["mimeType"] as? String, "image/png")
        XCTAssertEqual(image?["data"] as? String, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
    }

    func testTabs() async {
        _ = await call("tools/call", ["name": "browser_tab_new", "arguments": ["url": "localhost:5173"]])
        let tabs = text(await call("tools/call", ["name": "browser_tabs"]))
        XCTAssertEqual(tabs, "  [0] Home\n* [1] http://localhost:5173", tabs ?? "nil")
        _ = await call("tools/call", ["name": "browser_tab_select", "arguments": ["index": 0]])
        XCTAssertEqual(browser.current, 0)
        let closed = await call("tools/call", ["name": "browser_tab_close", "arguments": ["index": 7]])
        XCTAssertEqual((closed?["result"] as? [String: Any])?["isError"] as? Bool, true, "no such tab, said")
    }

    func testFailuresAreSaid() async {
        let missing = await call("tools/call", ["name": "browser_click", "arguments": ["ref": "e9"]])
        let result = missing?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertTrue(text(missing)?.contains("e9") == true)
        let noArgument = await call("tools/call", ["name": "browser_click", "arguments": [:]])
        XCTAssertEqual((noArgument?["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknown = await call("bogus/method")
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let noBrowser = await BrowserMCP.handle(
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "browser_snapshot"]]) { nil }
        XCTAssertEqual((noBrowser?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
}

final class SessionBrowserTests: XCTestCase {
    /// A session file from before the browser still reads; a page is kept.
    func testTheBrowserPageIsSavedAndOldFilesStillRead() throws {
        let old = #"{"tabs":[{"isPinned":false,"workingDirectory":"/tmp"}],"selectedIndex":0}"#
        let decoded = try JSONDecoder().decode(SessionState.self, from: Data(old.utf8))
        XCTAssertNil(decoded.tabs.first?.browserURL)
        var state = decoded
        state.tabs[0].browserURL = "http://localhost:3000/"
        state.tabs[0].browserPages = ["http://localhost:3000/", "https://docs.dev/"]
        state.tabs[0].browserPage = 1
        let again = try JSONDecoder().decode(SessionState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(again.tabs.first?.browserURL, "http://localhost:3000/")
        XCTAssertEqual(again.tabs.first?.browserPages, ["http://localhost:3000/", "https://docs.dev/"])
        XCTAssertEqual(again.tabs.first?.browserPage, 1)
    }
}
