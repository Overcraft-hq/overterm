#if E2E
import AppKit

/// P11: an agent's browser keeps to `browser.agentHosts` — the machine's
/// own by default — and asks for any other host, once a run, through the
/// card that names the tab and the agent. Pages are an echo server's on
/// 127.0.0.1, the list narrowed to `localhost` for the scenario, so
/// 127.0.0.1 is "another host" that still answers; the host declined is one
/// never opened, so nothing leaves the machine.
extension E2ERunner {
    package func browserHostsScenario() async {
        let server = E2EEchoServer()
        do { try server.start() } catch { return check("the echo server starts", false, "\(error)") }
        defer { server.stop() }
        let port = server.port
        AgentHostGate.shared.reset()
        Settings.shared.set("browser.agentHosts", .list(["localhost"]))
        MCPApprovals.shared.inFront = { _ in false }
        defer {
            Settings.shared.set("browser.agentHosts", nil)
            MCPApprovals.shared.inFront = nil
            AgentHostGate.shared.reset()
        }

        app.newTab(nil)
        guard let tab = app.store.selected else { return check("a tab", false) }
        let pane = tab.terminal.processTag
        app.openInBrowser(URL(string: "http://localhost:\(port)/echo")!, for: tab)
        guard let workspace = app.browserWorkspaces[tab.id], let session = workspace.active else { return check("the tab has a browser", false) }
        check("its page loads", await eventually(5) { session.url?.host == "localhost" && !session.isLoading })

        // As the agent in that pane calls the tools (the bridge's path, MCPAsker's pane set).
        func tool(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, error: Bool) {
            let answer = await BrowserMCP.handle(
                ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]], browser: { workspace }, pane: pane)
            let result = answer?["result"] as? [String: Any]
            return ((result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? "", result?["isError"] as? Bool ?? (answer?["error"] != nil))
        }
        func started(_ name: String, _ arguments: [String: Any]) -> Task<(text: String, error: Bool), Never> {
            Task { @MainActor in await tool(name, arguments) }
        }
        func card(_ host: String) async -> MCPApprovals.Request? {
            _ = await eventually(10) { MCPApprovals.shared.pending.contains { $0.confirmation.title.contains(host) } }
            return MCPApprovals.shared.pending.first { $0.confirmation.title.contains(host) }
        }

        // A listed host: nothing asked, as today.
        let listed = await tool("browser_navigate", ["url": "http://localhost:\(port)/echo?x=1"])
        check("a listed host opens without a question", !listed.error && MCPApprovals.shared.pending.isEmpty, listed.text)

        // Another host: asked on the tab's card, naming the tab; declined, never opened.
        let refused = started("browser_navigate", ["url": "https://admin.shop.example/orders?token=abc"])
        guard let asked = await card("admin.shop.example") else {
            return check("another host is asked", false, "\(MCPApprovals.shared.pending.map(\.summary))")
        }
        check("the question names the tab", asked.confirmation.asker?.contains("Asked through MCP") == true, asked.confirmation.asker ?? "-")
        check("…and shows no query", !asked.confirmation.detail.contains("token=abc"), asked.confirmation.detail)
        MCPApprovals.shared.answer(asked.id, typed: nil)
        let declined = await refused.value
        check("declined, the agent reads it", declined.error && declined.text.contains("didn't allow admin.shop.example"), declined.text)
        check("…and nothing was opened", session.url?.host == "localhost", session.url?.absoluteString ?? "-")
        let again = await tool("browser_navigate", ["url": "https://admin.shop.example/"])
        check("declined holds for the run: refused, not asked again", again.error && MCPApprovals.shared.pending.isEmpty, again.text)

        // The person's own browsing is never asked: 127.0.0.1 isn't listed.
        app.openInBrowser(URL(string: "http://127.0.0.1:\(port)/echo?own=1")!, for: tab)
        let yours = await eventually(5) { session.url?.host == "127.0.0.1" && !session.isLoading }
        check("your own navigation isn't held", yours && MCPApprovals.shared.pending.isEmpty, session.url?.absoluteString ?? "-")
        app.openInBrowser(URL(string: "http://localhost:\(port)/echo")!, for: tab)
        _ = await eventually(5) { session.url?.host == "localhost" && !session.isLoading }

        // The page's own navigation, set off by the agent's script: stopped
        // before it is sent, asked, loaded once allowed.
        let before = server.connections
        let sent = started("browser_evaluate", ["script": "location.href = 'http://127.0.0.1:\(port)/echo?y=2'; 1"])
        guard let redirect = await card("127.0.0.1") else { return check("a page sent to another host is asked", false) }
        check("…before the page left", session.url?.host == "localhost" && server.connections == before, session.url?.absoluteString ?? "-")
        MCPApprovals.shared.answer(redirect.id, typed: "")
        let followed = await sent.value
        let arrived = await eventually(5) { session.url?.host == "127.0.0.1" }
        check("allowed, the page goes there", !followed.error && arrived, followed.text)
        let read = await tool("browser_snapshot")
        check("…and is read without a second question", !read.error && MCPApprovals.shared.pending.isEmpty, read.text)
        app.closeTabsWithoutAsking([tab])
    }
}
#endif
