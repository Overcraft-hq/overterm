import Foundation

/// What an agent can do with a tab's browser — BrowserSession does it; the
/// tests hand in a fake.
@MainActor
package protocol AgentBrowser: AnyObject {
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
    /// The browser's own tabs: `[index] title — url`, `*` on the one
    /// showing, each address as `showing` gives it (P11: an unlisted host's
    /// without its query).
    func tabsDescription(showing: (URL) -> String) -> String
    /// A tab's address, by its index in `tabsDescription`.
    func url(ofTab index: Int) -> URL?
    func openTab(_ url: URL?, timeout: TimeInterval) async throws
    func selectTab(_ index: Int) throws
    func closeTab(_ index: Int) throws
    /// The address of the page the tools act on now (P11: its host checked
    /// before an agent reads it or acts on it).
    var currentURL: URL? { get }
    /// Held while an agent's call runs, on the page it acts on and the
    /// pages that one opens: a main-frame navigation `allows` says no to is
    /// stopped before it is sent, and kept for `takeBlockedNavigation` — a
    /// click, a form, a script, a redirect. A load the person asked for is
    /// never held. Holds nest: concurrent calls keep it until the last ends.
    func holdAgentGuard(_ allows: @escaping (URL) -> Bool)
    /// One hold ends, `after` seconds from now.
    func releaseAgentGuard(after seconds: TimeInterval)
    /// The navigation the guard stopped last, once.
    func takeBlockedNavigation() -> BlockedNavigation?
    /// Loads a stopped GET once allowed, in the page it came from — still
    /// under the guard while held.
    func follow(_ blocked: BlockedNavigation, timeout: TimeInterval) async throws
}

/// The Model Context Protocol, as Overterm's browser server speaks it:
/// JSON-RPC over HTTP POST (streamable HTTP, answering in JSON, no
/// streams), one server per pane so a call reaches its own tab's browser.
/// Pure of any transport: BrowserBridge carries the bytes.
@MainActor
package enum BrowserMCP {
    package static let protocolVersion = "2025-06-18"

    /// The answer to one JSON-RPC message; nil for a notification. A
    /// pane's call runs with `MCPAsker.pane` set: every confirmation it
    /// asks names that pane's tab and agent.
    package static func handle(
        _ message: [String: Any], browser: () -> AgentBrowser?, api: () -> AnyObject? = { nil }, pane: String? = nil, settings: Settings = .shared,
        kubernetes: (any Sendable)? = nil
    ) async -> [String: Any]? {
        guard let pane else { return await answer(message, browser: browser, api: api, pane: nil, settings: settings, kubernetes: kubernetes) }
        return await MCPAsker.$pane.withValue(pane) {
            await answer(message, browser: browser, api: api, pane: pane, settings: settings, kubernetes: kubernetes)
        }
    }

    private static func answer(
        _ message: [String: Any], browser: () -> AgentBrowser?, api: () -> AnyObject?, pane: String?, settings: Settings, kubernetes: (any Sendable)?
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
            for provider in features where provider.enabled(settings) { tools += await provider.listed(settings, kubernetes) }
            return reply(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "No tool name.") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            // The pane's call, in its log (MCP-U3): memory only.
            guard let pane else { return await callTool(name, arguments, reply: reply, failure: failure, browser: browser, api: api, pane: nil, settings: settings, kubernetes: kubernetes) }
            let logged = MCPCallLog.shared.begin(pane: pane, tool: name, arguments: arguments)
            nonisolated(unsafe) let given = arguments
            let answered = await MCPCallLog.$current.withValue((pane, logged)) {
                await callTool(name, given, reply: reply, failure: failure, browser: browser, api: api, pane: pane, settings: settings, kubernetes: kubernetes)
            }
            MCPCallLog.shared.end(pane: pane, id: logged, reply: answered)
            return answered
        default:
            return failure(-32601, "Method not found: \(method)")
        }
    }

    /// One tool's call: a feature's, else the browser's.
    private static func callTool(
        _ name: String, _ arguments: [String: Any], reply: (Any) -> [String: Any], failure: (Int, String) -> [String: Any],
        browser: () -> AgentBrowser?, api: () -> AnyObject?, pane: String?, settings: Settings, kubernetes: (any Sendable)?
    ) async -> [String: Any] {
        if let provider = features.first(where: { $0.handles(name) }) {
            guard provider.enabled(settings) else { return reply(errorResult(provider.unavailable)) }
            // Read by the one call it is handed to, then dropped.
            nonisolated(unsafe) let arguments = arguments
            do {
                return reply(try await provider.call(name, arguments, Provider.Context(pane: pane, kubernetes: kubernetes, api: api())))
            } catch let error as ToolError {
                return failure(-32602, error.message)
            } catch {
                return reply(errorResult(provider.said(error)))
            }
        }
        guard settings.browserAgentControl, let browser = browser() else {
            return reply(errorResult(BrowserError.noBrowser.localizedDescription))
        }
        do {
            return reply(try await call(name, arguments, browser, hosts: settings.browserAgentHosts))
        } catch let error as ToolError {
            return failure(-32602, error.message)
        } catch {
            return reply(errorResult(error.localizedDescription))
        }
    }

    package struct ToolError: Error {
        package let message: String

        package init(message: String) {
            self.message = message
        }
    }

    private static func call(
        _ name: String, _ arguments: [String: Any], _ browser: AgentBrowser, hosts: [String], gate: AgentHostGate = .shared
    ) async throws -> [String: Any] {
        func string(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else { throw ToolError(message: "\(name) needs “\(key)”.") }
            return value
        }
        /// An address as the agent reads it in a list: whole on a host it
        /// may use, else without its query, fragment or credentials.
        func shown(_ url: URL) -> String { gate.allows(url, list: hosts) ? url.absoluteString : AgentHosts.shown(url) }
        /// P11: the page's host, before the agent reads it or acts on it.
        func onAllowedHost(_ doing: String) async throws {
            if let url = browser.currentURL { try await gate.check(url, list: hosts, doing: doing) }
        }
        /// `body` with the page's own navigations held to the hosts: one the
        /// agent's step sets off to another host is stopped, then asked;
        /// allowed, a GET is loaded, anything else is the agent's to do again.
        /// Nil when the page is where the step left it; else what the agent reads.
        func holding(_ body: () async throws -> Void) async throws -> String? {
            browser.holdAgentGuard { [weak gate] url in gate?.allows(url, list: hosts) ?? false }
            // Held a moment past the call: a page that sends itself elsewhere
            // just after (a handler that awaits first) is stopped too.
            defer { browser.releaseAgentGuard(after: AgentHosts.guardTail) }
            try await body()
            // Stopped, asked, followed — still held, so where it goes from
            // there (a redirect to a third host) is stopped and asked too.
            for _ in 0..<3 {
                guard let blocked = browser.takeBlockedNavigation() else { return nil }
                try await gate.check(blocked.url, list: hosts, doing: "follow the page where its step sent it")
                guard blocked.method.uppercased() == "GET" else {
                    return AgentHosts.repeatAfterAllowing(AgentHosts.host(of: blocked.url) ?? "", method: blocked.method.uppercased())
                }
                try await browser.follow(blocked, timeout: 20)
            }
            return browser.takeBlockedNavigation() == nil ? nil : "The page kept sending itself to other hosts: stopped after three."
        }
        /// After an action the page may navigate or re-render: what it shows then.
        func settledSnapshot(_ action: () async throws -> Void) async throws -> [String: Any] {
            if let said = try await holding({
                try await action()
                try await Task.sleep(nanoseconds: 250_000_000)
                try? await browser.waitForLoad(timeout: 10)
            }) {
                return textResult(said)
            }
            try await onAllowedHost("read the page")
            return textResult(try await browser.snapshot())
        }
        switch name {
        case "browser_navigate":
            let typed = try string("url")
            guard let url = BrowserLinks.url(fromTyped: typed) else { throw ToolError(message: "Not a URL: \(typed)") }
            try await gate.check(url, list: hosts, doing: "open a page")
            if let said = try await holding({ try await browser.navigate(url, timeout: 20) }) { return textResult(said) }
            try await onAllowedHost("read the page")
            return textResult(try await browser.snapshot())
        case "browser_snapshot":
            try await onAllowedHost("read the page")
            return textResult(try await browser.snapshot())
        case "browser_click":
            let ref = try string("ref")
            try await onAllowedHost("click on the page")
            return try await settledSnapshot { try await browser.click(ref: ref) }
        case "browser_type":
            let submit = arguments["submit"] as? Bool ?? false
            guard let text = arguments["text"] as? String else { throw ToolError(message: "browser_type needs “text”.") }
            let ref = try string("ref")
            try await onAllowedHost(submit ? "type into the page and submit it" : "type into the page")
            return try await settledSnapshot { try await browser.type(ref: ref, text: text, submit: submit) }
        case "browser_screenshot":
            try await onAllowedHost("take a screenshot of the page")
            let png = try await browser.screenshot()
            return ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]]
        case "browser_console":
            try await onAllowedHost("read the page's console")
            let onlyErrors = arguments["errors_only"] as? Bool ?? false
            let text = browser.consoleText(onlyErrors: onlyErrors, limit: 200)
            return textResult(text.isEmpty ? "(nothing logged)" : text)
        case "browser_evaluate":
            let script = try string("script")
            try await onAllowedHost("run JavaScript in the page")
            var value = ""
            // Held past the script's return, as a click is: `location.href = …`
            // asks WebKit's policy after the script is done.
            if let said = try await holding({
                value = try await browser.evaluate(script)
                try await Task.sleep(nanoseconds: 250_000_000)
                try? await browser.waitForLoad(timeout: 10)
            }) {
                return textResult(said)
            }
            // A script that sent the page elsewhere: what it said is that page's no more.
            try await onAllowedHost("read the page")
            return textResult(value)
        case "browser_back":
            return try await settledSnapshot { browser.goBack() }
        case "browser_reload":
            try await onAllowedHost("reload the page")
            return try await settledSnapshot { browser.reload() }
        case "browser_tabs":
            return textResult(browser.tabsDescription(showing: shown))
        case "browser_tab_new":
            let url = (arguments["url"] as? String).flatMap { $0.isEmpty ? nil : BrowserLinks.url(fromTyped: $0) }
            if let url { try await gate.check(url, list: hosts, doing: "open a page") }
            if let said = try await holding({ try await browser.openTab(url, timeout: 20) }) { return textResult(said) }
            guard url != nil else { return textResult(browser.tabsDescription(showing: shown)) }
            try await onAllowedHost("read the page")
            return textResult(try await browser.snapshot())
        case "browser_tab_select":
            guard let index = arguments["index"] as? Int else { throw ToolError(message: "browser_tab_select needs “index”.") }
            try browser.selectTab(index)
            try await onAllowedHost("read the page")
            return textResult(try await browser.snapshot())
        case "browser_tab_close":
            guard let index = arguments["index"] as? Int else { throw ToolError(message: "browser_tab_close needs “index”.") }
            if let url = browser.url(ofTab: index) { try await gate.check(url, list: hosts, doing: "close a page") }
            try browser.closeTab(index)
            return textResult(browser.tabsDescription(showing: shown))
        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    /// The tools of what Settings gives agents: the browser's, the API client's, the notes', the databases', Docker's, Kubernetes', Terraform's, Activity's.
    package static var offered: [[String: Any]] { offered(in: .shared) }

    package static func offered(in settings: Settings) -> [[String: Any]] {
        var offered: [[String: Any]] = []
        if settings.browserAgentControl { offered += tools }
        for provider in features where provider.enabled(settings) { offered += provider.tools }
        return offered
    }

    package static var instructions: String { instructions(in: .shared) }

    package static func instructions(in settings: Settings) -> String {
        var parts: [String] = []
        if settings.browserAgentControl {
            parts.append(
                "The browser beside your terminal in Overterm (the user sees it). Open a page with browser_navigate, read it with browser_snapshot, act with the refs it lists; browser_console shows the page's errors."
            )
        }
        for provider in features where provider.enabled(settings) { parts.append(provider.instructionText(settings)) }
        return parts.joined(separator: " ")
    }

    /// A feature's agent tools (the databases', Docker's, Kubernetes',
    /// Terraform's, Activity's), in the order they are offered and asked: each its own
    /// prefix, its setting, its words. Set at install (`OvertermFeatures`).
    package struct Provider: Sendable {
        package var handles: @MainActor @Sendable (String) -> Bool
        package var enabled: @MainActor @Sendable (Settings) -> Bool
        /// Said when its setting is off.
        package var unavailable: String
        @MainActor package var tools: [[String: Any]] { toolList() }
        package var toolList: @MainActor @Sendable () -> [[String: Any]]
        /// What `tools/list` adds now (Kubernetes' writes while a context allows them).
        package var listed: @MainActor @Sendable (Settings, (any Sendable)?) async -> [[String: Any]] = { _, _ in [] }
        package var instructionText: @MainActor @Sendable (Settings) -> String
        /// What a call is handed besides its arguments.
        package struct Context {
            /// The calling pane's tag.
            package var pane: String?
            /// A test's Kubernetes model, else the app's.
            package var kubernetes: (any Sendable)?
            /// The pane's API client (`AgentAPI`), where it has one.
            package var api: AnyObject?
        }

        /// The call: its name, arguments and context.
        package var call: @MainActor @Sendable (String, [String: Any], Context) async throws -> Any
        /// An error as the agent reads it.
        package var said: @MainActor @Sendable (Error) -> String = { $0.localizedDescription }

        package init(
            handles: @escaping @MainActor @Sendable (String) -> Bool, enabled: @escaping @MainActor @Sendable (Settings) -> Bool, unavailable: String,
            tools: @escaping @MainActor @Sendable () -> [[String: Any]], instructions: @escaping @MainActor @Sendable (Settings) -> String,
            listed: @escaping @MainActor @Sendable (Settings, (any Sendable)?) async -> [[String: Any]] = { _, _ in [] },
            call: @escaping @MainActor @Sendable (String, [String: Any], Context) async throws -> Any,
            said: @escaping @MainActor @Sendable (Error) -> String = { $0.localizedDescription }
        ) {
            self.handles = handles
            self.enabled = enabled
            self.unavailable = unavailable
            self.toolList = tools
            self.instructionText = instructions
            self.listed = listed
            self.call = call
            self.said = said
        }
    }

    package static var features: [Provider] {
        FeatureHooks.ensure()
        return featuresStorage
    }
    package nonisolated(unsafe) static var featuresStorage: [Provider] = []

    package static func textResult(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]]] }
    package static func errorResult(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }

    package static let tools: [[String: Any]] = [
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
