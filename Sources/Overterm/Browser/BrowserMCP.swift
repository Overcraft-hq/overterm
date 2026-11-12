import Foundation

/// What an agent can do with a tab's browser — BrowserSession does it; the
/// tests hand in a fake.
@MainActor
protocol AgentBrowser: AnyObject {
    func navigate(_ url: URL, timeout: TimeInterval) async throws
    func snapshot() async throws -> String
    func click(ref: String) async throws
    func type(ref: String, text: String, submit: Bool) async throws
    func evaluate(_ script: String) async throws -> String
    func screenshot() async throws -> Data
    func consoleText(onlyErrors: Bool, limit: Int) -> String
    func goBack()
    func reload()
    func waitForLoad(timeout: TimeInterval) async throws
    /// The browser's own tabs: `[index] title — url`, `*` on the one showing.
    func tabsDescription() -> String
    func openTab(_ url: URL?, timeout: TimeInterval) async throws
    func selectTab(_ index: Int) throws
    func closeTab(_ index: Int) throws
}

/// The Model Context Protocol, as Overterm's browser server speaks it:
/// JSON-RPC over HTTP POST (streamable HTTP, answering in JSON, no
/// streams), one server per pane so a call reaches its own tab's browser.
/// Pure of any transport: BrowserBridge carries the bytes.
@MainActor
enum BrowserMCP {
    static let protocolVersion = "2025-06-18"

    /// The answer to one JSON-RPC message; nil for a notification. A
    /// pane's call runs with `MCPAsker.pane` set: every confirmation it
    /// asks names that pane's tab and agent.
    static func handle(
        _ message: [String: Any], browser: () -> AgentBrowser?, api: () -> AgentAPI? = { nil }, pane: String? = nil, settings: Settings = .shared,
        kubernetes: KubernetesModel = .shared
    ) async -> [String: Any]? {
        guard let pane else { return await answer(message, browser: browser, api: api, pane: nil, settings: settings, kubernetes: kubernetes) }
        return await MCPAsker.$pane.withValue(pane) {
            await answer(message, browser: browser, api: api, pane: pane, settings: settings, kubernetes: kubernetes)
        }
    }

    private static func answer(
        _ message: [String: Any], browser: () -> AgentBrowser?, api: () -> AgentAPI?, pane: String?, settings: Settings, kubernetes: KubernetesModel
    ) async -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        guard let id, !(id is NSNull) else { return nil }
        func reply(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func failure(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return reply([
                "protocolVersion": asked ?? protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "overterm-browser", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"],
                "instructions": instructions(in: settings),
            ])
        case "ping":
            return reply([String: Any]())
        case "tools/list":
            var tools = offered(in: settings)
            // Kubernetes' writes while kubernetes.agentWrites names a context —
            // a setting, not the contexts' state now, which changes after the
            // list was read (it isn't announced again): each call is refused
            // where the context isn't writable for agents.
            if settings.kubernetesAgentAccess, !kubernetes.agentWrites.isEmpty { tools += KubeMCP.writeTools }
            return reply(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "No tool name.") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if name.hasPrefix("notes_") {
                guard settings.notesAgentAccess else {
                    return reply(errorResult("The notes aren't available to agents — Settings ▸ Notes."))
                }
                do {
                    return reply(try await NotesMCP.call(name, arguments, notes: NotesModel.shared))
                } catch let error as ToolError {
                    return failure(-32602, error.message)
                } catch {
                    return reply(errorResult(error.localizedDescription))
                }
            }
            if name.hasPrefix("db_") || name.hasPrefix("storage_") {
                guard settings.databaseAgentAccess else {
                    return reply(errorResult("The databases aren't available to agents — Settings ▸ Database."))
                }
                do {
                    return reply(try await DatabaseMCP.call(name, arguments, model: DatabaseModel.shared))
                } catch let error as ToolError {
                    return failure(-32602, error.message)
                } catch {
                    return reply(errorResult(error.localizedDescription))
                }
            }
            if name.hasPrefix("docker_") {
                guard settings.dockerAgentAccess else {
                    return reply(errorResult("Docker isn't available to agents — Settings ▸ Docker."))
                }
                do {
                    return reply(try await DockerMCP.call(name, arguments, docker: DockerModel.shared))
                } catch let error as ToolError {
                    return failure(-32602, error.message)
                } catch {
                    return reply(errorResult(error.localizedDescription))
                }
            }
            if name.hasPrefix(KubeMCP.prefix) {
                guard settings.kubernetesAgentAccess else {
                    return reply(errorResult("Kubernetes isn't available to agents — Settings ▸ Kubernetes."))
                }
                do {
                    return reply(try await KubeMCP.call(name, arguments, kubernetes: kubernetes, pane: pane))
                } catch let error as ToolError {
                    return failure(-32602, error.message)
                } catch {
                    return reply(errorResult(KubeMCPText.scrubbed(KubernetesModel.said(error))))
                }
            }
            if name.hasPrefix(TerraformMCP.prefix) {
                guard settings.terraformAgentAccess else {
                    return reply(errorResult("Terraform isn't available to agents — Settings ▸ Terraform."))
                }
                do {
                    return reply(try await TerraformMCP.call(name, arguments, pane: pane))
                } catch let error as ToolError {
                    return failure(-32602, error.message)
                } catch {
                    return reply(errorResult(TerraformMCP.scrubbed(error.localizedDescription)))
                }
            }
            if name.hasPrefix("api_") {
                guard settings.apiAgentControl, let api = api() else {
                    return reply(errorResult("The API client isn't available to agents — Settings ▸ API Client."))
                }
                do {
                    return reply(try await APIMCP.call(name, arguments, api: api))
                } catch let error as ToolError {
                    return failure(-32602, error.message)
                } catch {
                    return reply(errorResult(error.localizedDescription))
                }
            }
            guard settings.browserAgentControl, let browser = browser() else {
                return reply(errorResult(BrowserError.noBrowser.localizedDescription))
            }
            do {
                return reply(try await call(name, arguments, browser))
            } catch let error as ToolError {
                return failure(-32602, error.message)
            } catch {
                return reply(errorResult(error.localizedDescription))
            }
        default:
            return failure(-32601, "Method not found: \(method)")
        }
    }

    struct ToolError: Error {
        let message: String
    }

    private static func call(_ name: String, _ arguments: [String: Any], _ browser: AgentBrowser) async throws -> [String: Any] {
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else { throw ToolError(message: "\(name) needs “\(key)”.") }
            return value
        }
        /// After an action the page may navigate or re-render: what it shows then.
        func settledSnapshot() async throws -> [String: Any] {
            try await Task.sleep(nanoseconds: 250_000_000)
            try? await browser.waitForLoad(timeout: 10)
            return textResult(try await browser.snapshot())
        }
        switch name {
        case "browser_navigate":
            let typed = try string("url")
            guard let url = BrowserLinks.url(fromTyped: typed) else { throw ToolError(message: "Not a URL: \(typed)") }
            try await browser.navigate(url, timeout: 20)
            return textResult(try await browser.snapshot())
        case "browser_snapshot":
            return textResult(try await browser.snapshot())
        case "browser_click":
            try await browser.click(ref: try string("ref"))
            return try await settledSnapshot()
        case "browser_type":
            let submit = arguments["submit"] as? Bool ?? false
            guard let text = arguments["text"] as? String else { throw ToolError(message: "browser_type needs “text”.") }
            try await browser.type(ref: try string("ref"), text: text, submit: submit)
            return try await settledSnapshot()
        case "browser_screenshot":
            let png = try await browser.screenshot()
            return ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]]
        case "browser_console":
            let onlyErrors = arguments["errors_only"] as? Bool ?? false
            let text = browser.consoleText(onlyErrors: onlyErrors, limit: 200)
            return textResult(text.isEmpty ? "(nothing logged)" : text)
        case "browser_evaluate":
            return textResult(try await browser.evaluate(try string("script")))
        case "browser_back":
            browser.goBack()
            return try await settledSnapshot()
        case "browser_reload":
            browser.reload()
            return try await settledSnapshot()
        case "browser_tabs":
            return textResult(browser.tabsDescription())
        case "browser_tab_new":
            let url = (arguments["url"] as? String).flatMap { $0.isEmpty ? nil : BrowserLinks.url(fromTyped: $0) }
            try await browser.openTab(url, timeout: 20)
            return textResult(url == nil ? browser.tabsDescription() : try await browser.snapshot())
        case "browser_tab_select":
            guard let index = arguments["index"] as? Int else { throw ToolError(message: "browser_tab_select needs “index”.") }
            try browser.selectTab(index)
            return textResult(try await browser.snapshot())
        case "browser_tab_close":
            guard let index = arguments["index"] as? Int else { throw ToolError(message: "browser_tab_close needs “index”.") }
            try browser.closeTab(index)
            return textResult(browser.tabsDescription())
        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    /// The tools of what Settings gives agents: the browser's, the API client's, the notes', the databases', Docker's, Kubernetes', Terraform's.
    static var offered: [[String: Any]] { offered(in: .shared) }

    static func offered(in settings: Settings) -> [[String: Any]] {
        var offered: [[String: Any]] = []
        if settings.browserAgentControl { offered += tools }
        if settings.apiAgentControl { offered += APIMCP.tools }
        if settings.notesAgentAccess { offered += NotesMCP.tools }
        if settings.databaseAgentAccess { offered += DatabaseMCP.tools }
        if settings.dockerAgentAccess { offered += DockerMCP.tools }
        if settings.kubernetesAgentAccess { offered += KubeMCP.tools }
        if settings.terraformAgentAccess { offered += TerraformMCP.tools }
        return offered
    }

    static var instructions: String { instructions(in: .shared) }

    static func instructions(in settings: Settings) -> String {
        var parts: [String] = []
        if settings.browserAgentControl {
            parts.append(
                "The browser beside your terminal in Overterm (the user sees it). Open a page with browser_navigate, read it with browser_snapshot, act with the refs it lists; browser_console shows the page's errors."
            )
        }
        if settings.apiAgentControl {
            parts.append(
                "The API client of your checkout's Bruno collection: api_collections lists its requests, api_send runs one with its tests, api_request sends a one-off, api_run runs the collection — use it to check an endpoint you changed."
            )
        }
        if settings.notesAgentAccess {
            parts.append(
                "The user's notes (an Obsidian vault): notes_search finds notes by name, #tag or what they say, notes_read reads one with its links — for context the user keeps there. Read-only."
                    + (settings.notesAgentDrawings
                        ? " notes_draw makes a new Excalidraw drawing from boxes, arrows and text — a diagram the user asked for, opened beside the terminal."
                        : "")
            )
        }
        if settings.databaseAgentAccess {
            parts.append(
                "The user's databases and buckets (Overterm's Database panel): db_connections and db_schema show what is there, db_query runs one statement and returns rows — reads; storage_list and storage_read browse S3/GCS. Check real data instead of guessing a schema."
            )
        }
        if settings.dockerAgentAccess { parts.append(DockerMCP.instructions) }
        if settings.kubernetesAgentAccess { parts.append(KubeMCP.instructions) }
        if settings.terraformAgentAccess { parts.append(TerraformMCP.instructions) }
        return parts.joined(separator: " ")
    }

    static func textResult(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
    static func errorResult(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }

    static let tools: [[String: Any]] = [
        tool(
            "browser_navigate", "Open a URL (or localhost:3000, :3000) in the browser and return the page's snapshot.",
            ["url": ["type": "string", "description": "The address, as you'd type it in a browser."]], required: ["url"]),
        tool(
            "browser_snapshot",
            "The page now: title, URL, visible text, and the controls you can act on, each with a ref (e1, e2…) for browser_click and browser_type.",
            [:]),
        tool(
            "browser_click", "Click a control by its ref from the latest snapshot; returns the snapshot after.",
            ["ref": ["type": "string", "description": "A ref from browser_snapshot, like e3."]], required: ["ref"]),
        tool(
            "browser_type", "Type into a field (replacing its value) by ref; submit: press Enter / submit its form after.",
            [
                "ref": ["type": "string", "description": "A ref from browser_snapshot."],
                "text": ["type": "string", "description": "What to type."],
                "submit": ["type": "boolean", "description": "Press Enter after typing."],
            ], required: ["ref", "text"]),
        tool("browser_screenshot", "A screenshot of what the browser shows (PNG).", [:]),
        tool(
            "browser_console", "What the page logged: console calls, uncaught errors, failed loads.",
            ["errors_only": ["type": "boolean", "description": "Only errors and warnings."]]),
        tool(
            "browser_evaluate", "Run JavaScript in the page and return its value (await works).",
            ["script": ["type": "string", "description": "An expression or statements; the last value is returned."]],
            required: ["script"]),
        tool("browser_back", "Go back a page.", [:]),
        tool("browser_reload", "Reload the page.", [:]),
        tool("browser_tabs", "The browser's tabs: index, title and address; * marks the one the other tools act on.", [:]),
        tool(
            "browser_tab_new", "Open a new tab (and a URL in it, if given); it becomes the one the tools act on.",
            ["url": ["type": "string", "description": "What to open, as typed in a browser. Optional."]]),
        tool(
            "browser_tab_select", "Switch to a tab by its index from browser_tabs; returns its snapshot.",
            ["index": ["type": "integer", "description": "The tab's index."]], required: ["index"]),
        tool(
            "browser_tab_close", "Close a tab by its index from browser_tabs.",
            ["index": ["type": "integer", "description": "The tab's index."]], required: ["index"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }
}
