import AppKit
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
        let listed = Set(names?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertEqual(
            Set(listed.filter { $0.hasPrefix("browser_") }),
            Set<String>([
                "browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_screenshot", "browser_console",
                "browser_evaluate", "browser_back", "browser_reload", "browser_tabs", "browser_tab_new", "browser_tab_select",
                "browser_tab_close",
            ]))
        // The API client's, on the same server, while Settings gives them.
        let api: Set<String> = Settings.shared.apiAgentControl ? ["api_collections", "api_send", "api_request", "api_run"] : []
        XCTAssertEqual(Set(listed.filter { $0.hasPrefix("api_") }), api)
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

/// The bridge's per-pane tokens (analysis D-15): a pane's token opens its
/// own path and no other, for every tool group the bridge carries.
final class PaneTokenTests: XCTestCase {
    private func request(_ path: String, bearer: String?) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: bearer.map { ["authorization": "Bearer \($0)"] } ?? [:], body: Data())
    }

    func testEachPaneHasItsOwnToken() {
        let tokens = PaneTokens()
        let a = tokens.token(for: "pane-a")
        let b = tokens.token(for: "pane-b")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(tokens.token(for: "pane-a"), a, "asked again, the same token")
        XCTAssertEqual(a.count, 64)
    }

    func testAPanesTokenOnAnotherPanesPathIsRefused() {
        let tokens = PaneTokens()
        let a = tokens.token(for: "pane-a")
        let b = tokens.token(for: "pane-b")
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a", bearer: a), tokens: tokens), .pane("pane-a"))
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-b", bearer: b), tokens: tokens), .pane("pane-b"))
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-b", bearer: a), tokens: tokens), .refused(status: 401))
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a", bearer: b), tokens: tokens), .refused(status: 401))
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a?x=1", bearer: a), tokens: tokens), .pane("pane-a"))
    }

    func testNoTokenAWrongOneAndAnUnknownPaneAreRefused() {
        let tokens = PaneTokens()
        let a = tokens.token(for: "pane-a")
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a", bearer: nil), tokens: tokens), .refused(status: 401))
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a", bearer: "wrong"), tokens: tokens), .refused(status: 401))
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a", bearer: String(a.dropLast()) + "0"), tokens: tokens).isRefused, true)
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-z", bearer: a), tokens: tokens), .refused(status: 401), "a pane with no token")
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a/extra", bearer: a), tokens: tokens), .refused(status: 404))
        let bare = HTTPRequest(method: "POST", path: "/mcp/pane-a", headers: ["authorization": a], body: Data())
        XCTAssertEqual(BridgeServer.route(bare, tokens: tokens), .refused(status: 401), "not a bearer")
    }

    func testAClosedPanesTokenIsDropped() {
        let tokens = PaneTokens()
        let a = tokens.token(for: "pane-a")
        tokens.revoke("pane-a")
        XCTAssertEqual(BridgeServer.route(request("/mcp/pane-a", bearer: a), tokens: tokens), .refused(status: 401))
        XCTAssertNotEqual(tokens.token(for: "pane-a"), a, "a new token, never the old one again")
    }

    /// Over the server's real HTTP on loopback, as an agent would call it.
    @MainActor
    func testOverHTTPOnlyTheOwnPaneIsServed() async throws {
        let tokens = PaneTokens()
        let a = tokens.token(for: "pane-a")
        let b = tokens.token(for: "pane-b")
        var served: [String] = []
        let server = BridgeServer(tokens: tokens) { tag, message in
            served.append(tag)
            return ["jsonrpc": "2.0", "id": message["id"] ?? NSNull(), "result": [:] as [String: Any]]
        }
        let ready = expectation(description: "listening")
        nonisolated(unsafe) var port: UInt16 = 0
        server.start { listening in
            port = listening
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }
        func status(_ tag: String, _ token: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp/\(tag)")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let crossed = try await status("pane-b", a)
        XCTAssertEqual(crossed, 401, "pane A's token on B's tag")
        let own = try await status("pane-a", a)
        XCTAssertEqual(own, 200)
        let other = try await status("pane-b", b)
        XCTAssertEqual(other, 200)
        XCTAssertEqual(served, ["pane-a", "pane-b"], "the refused request reached no tool")
    }
}

/// The token stays out of the config files (analysis D-15): an agent in
/// worktree A that lists the folder and reads B's file gets B's address and
/// the name of a variable, nothing that opens B's tools.
final class PaneConfigTests: XCTestCase {
    private func written(_ tag: String, port: UInt16, in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("\(tag).json")
        let config = BrowserBridge.config(port: port, tag: tag)
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
        return file
    }

    func testTheConfigNamesTheTokenAndHoldsNone() throws {
        let config = BrowserBridge.config(port: 4242, tag: "pane-a")
        let server = (config["mcpServers"] as? [String: Any])?["overterm-browser"] as? [String: Any]
        XCTAssertEqual(server?["url"] as? String, "http://127.0.0.1:4242/mcp/pane-a")
        XCTAssertEqual((server?["headers"] as? [String: String])?["Authorization"], "Bearer ${OVERTERM_MCP_TOKEN}")
        XCTAssertEqual(BrowserBridge.tokenVariable, "OVERTERM_MCP_TOKEN")
    }

    func testReadingEveryPanesFileGivesNoWorkingCredential() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tokens = PaneTokens()
        let a = tokens.token(for: "pane-a")
        let b = tokens.token(for: "pane-b")
        _ = try written("pane-a", port: 4242, in: folder)
        _ = try written("pane-b", port: 4242, in: folder)
        // A, as `cat mcp/*.json` would.
        var headers: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(a) || text.contains(b), "\(file.lastPathComponent) holds a token")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            let server = (json?["mcpServers"] as? [String: Any])?["overterm-browser"] as? [String: Any]
            if let header = (server?["headers"] as? [String: String])?["Authorization"] { headers.append(header) }
        }
        XCTAssertEqual(headers.count, 2)
        for header in headers {
            for tag in ["pane-a", "pane-b"] {
                let request = HTTPRequest(method: "POST", path: "/mcp/\(tag)", headers: ["authorization": header], body: Data())
                XCTAssertEqual(BridgeServer.route(request, tokens: tokens), .refused(status: 401), "\(header) on \(tag)")
            }
        }
    }
}

/// What a write's confirmation says of who asks, when an agent's MCP call
/// does (analysis D-15).
@MainActor
final class MCPAskerTests: XCTestCase {
    func testTheLineNamesTheTabAndTheAgent() {
        XCTAssertEqual(MCPAsker.line(tab: "acme-api", agent: "Claude"), "Asked through MCP by Claude in the tab “acme-api”")
        XCTAssertEqual(
            MCPAsker.line(tab: "server", checkout: "globex-web", agent: nil), "Asked through MCP by an agent in the tab “server” (globex-web)")
        XCTAssertEqual(MCPAsker.line(tab: "acme-api", checkout: "acme-api", agent: "Codex"), "Asked through MCP by Codex in the tab “acme-api”")
        XCTAssertEqual(MCPAsker.line(tab: nil, agent: "Claude"), "Asked through MCP by a pane that is no longer open")
    }

    func testATitleCannotHideWhatItIs() {
        // A shell sets its own title: a direction override or a newline is shown as its code.
        let line = MCPAsker.line(tab: "acme\u{202E}ipa\nprod", agent: nil)
        XCTAssertFalse(line.contains("\u{202E}"))
        XCTAssertFalse(line.contains("\n"))
    }

    func testOutsideACallNobodyIsNamed() async {
        let none = await MCPAsker.current()
        XCTAssertNil(none)
        let closed = await MCPAsker.$pane.withValue("no-such-pane") { await MCPAsker.current() }
        XCTAssertEqual(closed, "Asked through MCP by a pane that is no longer open")
    }

    func testTheConfirmationShowsWhoAsks() {
        let confirmation = WriteConfirmation(
            title: "An agent wants to stop “acme-web-1”", detail: "nginx — Up 2 hours", button: "Allow", cancel: "Don't",
            asker: "Asked through MCP by Claude in the tab “acme-api”")
        let (alert, _) = confirmation.alert()
        func labels(_ view: NSView?) -> [NSTextField] {
            guard let view else { return [] }
            let own = (view as? NSTextField).map { [$0] } ?? []
            return own + view.subviews.flatMap(labels)
        }
        let shown = labels(alert.accessoryView)
        let asker = shown.first { $0.accessibilityIdentifier() == WriteConfirmation.askerLabel }
        XCTAssertEqual(asker?.stringValue, "Asked through MCP by Claude in the tab “acme-api”")
        XCTAssertTrue(shown.contains { $0.stringValue == "nginx — Up 2 hours" }, "the detail under it")
        let plain = WriteConfirmation(title: "Stop?", detail: "nginx", button: "Allow").alert().0
        XCTAssertNil(plain.accessoryView, "nobody named when the user asked")
    }
}

extension BridgeServer.Route {
    fileprivate var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }
}
