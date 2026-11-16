import AppKit

/// The API panel's MCP servers: a checkout's `.mcp.json` read (a stdio
/// server and an HTTP one, both the scenario's own), one inspected in the
/// right-hand pane — its tools listed, one called — and a server added.
extension E2ERunner {
    func apiMCPScenario() async {
        let http = E2EMCPServer()
        do { try http.start() } catch { return check("the HTTP server starts", false, "\(error)") }
        defer { http.stop() }
        let checkout = out("mcp-shop")
        let script = E2EMCPServer.writeScript(in: checkout)
        let config = """
            {"mcpServers": {
              "local": {"command": "/bin/sh", "args": ["\(script.path)"]},
              "remote": {"type": "http", "url": "\(http.url)"}
            }}
            """
        try? config.write(to: checkout.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let api = app.apiWorkspace
        api.setRoot(checkout)
        app.showAPIClient(nil)
        let inspector = api.mcp
        check("the checkout's .mcp.json servers are listed", await eventually(3) { inspector.servers.map(\.name) == ["local", "remote"] }, "\(inspector.servers.map(\.id))")
        check("from the project", inspector.servers.allSatisfy { $0.source == .project })

        guard let local = inspector.servers.first(where: { $0.name == "local" }) else { return }
        app.inspectMCP(local)
        check("a server opens in the right-hand pane", app.rightPane.mode == .mcp && app.diffItem?.isCollapsed == false)
        check("and connects", await eventually(5) { inspector.state == .connected }, "\(inspector.state)")
        check("its tools are listed", await eventually(3) { inspector.tools.map(\.name) == ["echo"] })
        check("its resources and prompts too", inspector.resources.count == 2 && inspector.prompts.map(\.name) == ["greet"], "\(inspector.resources.map(\.uri)) \(inspector.prompts.map(\.name))")
        if let tool = inspector.tools.first { inspector.pick(tool: tool) }
        check("a tool's arguments start from its schema", inspector.toolArguments.contains("\"text\" : \"\""), inspector.toolArguments)
        inspector.toolArguments = #"{"text": "from overterm"}"#
        inspector.call()
        check(
            "calling it shows what came back",
            await eventually(5) { inspector.outcome.map { MCPContent.parts($0.value) == [.text("echo: from overterm")] } == true },
            "\(String(describing: inspector.outcome)) \(inspector.error ?? "")")
        check("every message is in its log", inspector.log.contains { $0.direction == .sent && $0.text.contains("tools/call") })
        await pause(0.6)
        if let png = ProcessInfo.processInfo.environment["OVERTERM_DUMP_PNG"], !png.isEmpty {
            app.editorItem?.isCollapsed = true
            await pause(0.3)
            app.captureWindow(to: (png as NSString).appendingPathComponent("mcp.png"))
        }

        guard let remote = inspector.servers.first(where: { $0.name == "remote" }) else { return }
        app.inspectMCP(remote)
        check("an HTTP server connects too", await eventually(5) { inspector.state == .connected && inspector.tools.map(\.name) == ["add"] }, "\(inspector.state)")
        if let tool = inspector.tools.first { inspector.pick(tool: tool) }
        inspector.toolArguments = #"{"a": 2, "b": 40}"#
        inspector.call()
        check(
            "its answer, sent as an event stream, is read",
            await eventually(5) { inspector.outcome?.value["structuredContent"]["sum"].int == 42 }, "\(String(describing: inspector.outcome))")

        // One added here: in Overterm's folder, its header's value not in the file.
        let added = MCPServerConfig(name: "mine", source: .overterm, transport: .http(url: http.url, headers: ["Authorization": "Bearer secret-value"]))
        try? inspector.add(added)
        check("an added server joins the list", inspector.servers.contains { $0.id == "overterm:mine" })
        let file = AppEnvironment.supportDirectory.appendingPathComponent("API/MCPServers.json")
        let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("kept in Overterm's folder, its secret not in the file", written.contains("mine") && !written.contains("secret-value"), written)
        check("nothing written into the checkout", (try? FileManager.default.contentsOfDirectory(atPath: checkout.path).sorted()) == [".mcp.json", "fake-mcp.sh"])
        inspector.disconnectAll()
    }
}
