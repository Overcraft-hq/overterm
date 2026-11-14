import Foundation
import Network

/// The browser's door for agents: an MCP server on 127.0.0.1 (a random
/// port — nothing off this machine), at one path per pane,
/// `/mcp/<the pane's tag>`, so an agent reaches its own tab's tools and no
/// other's. Each pane has a token of its own (`PaneTokens`), good only at
/// its own path, and kept out of every file: the config files sit in one
/// folder any of the user's processes can list, so a token written there
/// let an agent in worktree A read B's and call B's tools — the window's
/// confirmation then naming B's checkout (analysis D-15).
///
/// A pane learns its address from `OVERTERM_MCP_CONFIG`, a Claude Code
/// MCP config file written for it, and its token from
/// `OVERTERM_MCP_TOKEN`, in that pane's environment only: the file's header
/// is `Bearer ${OVERTERM_MCP_TOKEN}`, which Claude Code expands. Overterm
/// starts `claude` with `--mcp-config "$OVERTERM_MCP_CONFIG"`
/// (Settings.arguments). What is left: another of the user's processes,
/// not sandboxed, can read a process's environment (KERN_PROCARGS2) — the
/// confirmations name the asking tab and agent for that (`MCPAsker`).
@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()
    static let configVariable = "OVERTERM_MCP_CONFIG"
    /// The pane's token: in its environment, never in a file.
    nonisolated static let tokenVariable = "OVERTERM_MCP_TOKEN"

    /// The browser of the tab a pane is in — the window answers.
    var resolve: ((String) -> AgentBrowser?)?
    /// The API client of the checkout a pane's tab is in — the window answers.
    var resolveAPI: ((String) -> AgentAPI?)?

    /// Agents get the browser, the API client, the notes, the databases,
    /// Docker, Kubernetes, Terraform — any of them: the server serves
    /// whenever `BrowserMCP.offered` would list a tool.
    private var wanted: Bool { Self.wanted(in: .shared) }

    static func wanted(in settings: Settings) -> Bool {
        settings.browserAgentControl || settings.apiAgentControl || settings.notesAgentAccess || settings.databaseAgentAccess
            || settings.dockerAgentAccess || settings.kubernetesAgentAccess || settings.terraformAgentAccess
    }

    private var server: BridgeServer?
    private(set) var port: UInt16?
    /// Every pane's token, read by the server on its own queue.
    let tokens = PaneTokens()

    /// The token that opens `tag`'s tools, and only them.
    func token(forPane tag: String) -> String { tokens.token(for: tag) }

    private var configDirectory: URL { AppEnvironment.supportDirectory.appendingPathComponent("mcp", isDirectory: true) }

    /// Serving, as Settings ▸ Browser asks.
    var isServing: Bool { port != nil && wanted }

    /// Starts listening (once); the config files of an earlier run go.
    func start() {
        guard server == nil, wanted else { return }
        try? FileManager.default.removeItem(at: configDirectory)
        let server = BridgeServer(tokens: tokens) { [weak self] tag, message in
            await self?.handle(tag: tag, message: message)
        }
        self.server = server
        server.start { [weak self] port in
            MainActor.assumeIsolated { self?.port = port }
        }
    }

    /// Serving exactly while Settings gives agents something.
    func update() {
        if wanted { start() } else { stop() }
    }

    func stop() {
        server?.stop()
        server = nil
        port = nil
    }

    private func handle(tag: String, message: [String: Any]) async -> [String: Any]? {
        await BrowserMCP.handle(message, browser: { [weak self] in self?.resolve?(tag) }, api: { [weak self] in self?.resolveAPI?(tag) }, pane: tag)
    }

    /// What a new pane's environment gets — its config file's path and its
    /// token — or nil when agents don't get the bridge.
    func environment(forPane tag: String) -> [String: String]? {
        guard let path = configPath(forPane: tag) else { return nil }
        return [Self.configVariable: path, Self.tokenVariable: tokens.token(for: tag)]
    }

    /// A pane's Claude Code config: its path, and the token by name only —
    /// Claude Code expands `${OVERTERM_MCP_TOKEN}` in a header from the
    /// environment it was started in, the pane's.
    nonisolated static func config(port: UInt16, tag: String) -> [String: Any] {
        [
            "mcpServers": [
                "overterm-browser": [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)/mcp/\(tag)",
                    "headers": ["Authorization": "Bearer ${\(tokenVariable)}"],
                ]
            ]
        ]
    }

    /// The config file for a new pane — written now, while the server is
    /// up — or nil when agents don't get the browser.
    func configPath(forPane tag: String) -> String? {
        guard isServing, let port else { return nil }
        let config = Self.config(port: port, tag: tag)
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let file = configDirectory.appendingPathComponent("\(tag).json")
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            // No secret in it, but where this pane's tools are: the user's alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }

    /// The pane is gone: its file, and its token with it.
    func removeConfig(forPane tag: String) {
        tokens.revoke(tag)
        try? FileManager.default.removeItem(at: configDirectory.appendingPathComponent("\(tag).json"))
    }
}

/// A random token per pane, bound to its tag: a token opens its own pane's
/// path and no other (analysis D-15). Made when a pane's config is written
/// (or first asked for), dropped when the pane closes.
final class PaneTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var byTag: [String: String] = [:]

    /// `tag`'s token, made now if it has none.
    func token(for tag: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let token = byTag[tag] { return token }
        // The system's generator: arc4random, cryptographically secure.
        var random = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }.map { String(format: "%02x", $0) }.joined()
        byTag[tag] = token
        return token
    }

    func revoke(_ tag: String) {
        lock.lock()
        defer { lock.unlock() }
        byTag[tag] = nil
    }

    /// Whether `header` (the request's Authorization) is `tag`'s own bearer token.
    func authorizes(_ header: String?, tag: String) -> Bool {
        lock.lock()
        let expected = byTag[tag]
        lock.unlock()
        guard let expected, let header, header.hasPrefix("Bearer ") else { return false }
        return Self.equal(Array(header.utf8.dropFirst(7)), Array(expected.utf8))
    }

    /// Compared in time that doesn't depend on where they differ.
    private static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// HTTP/1.1 on a Network.framework listener, just enough for MCP's
/// streamable HTTP: POST a JSON-RPC message, get JSON back (202 for a
/// notification); GET (a server-sent stream) is declined with 405, which
/// the protocol allows. One request per connection.
final class BridgeServer: @unchecked Sendable {
    typealias Handler = @MainActor (String, [String: Any]) async -> [String: Any]?
    private let tokens: PaneTokens
    private let handler: Handler
    private let queue = DispatchQueue(label: "overterm.browser-bridge")
    private var listener: NWListener?

    init(tokens: PaneTokens, handler: @escaping Handler) {
        self.tokens = tokens
        self.handler = handler
    }

    func start(ready: @escaping @Sendable (UInt16) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue {
                DispatchQueue.main.async { ready(port) }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Reads until the headers and a Content-Length body are in.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 16 << 20 { return self.respond(connection, status: 413, body: nil) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if complete || error != nil { return connection.cancel() }
                self.receive(connection, buffer: buffer)
            case .invalid:
                self.respond(connection, status: 400, body: nil)
            case .complete(let request):
                self.serve(request, on: connection)
            }
        }
    }

    enum Route: Equatable {
        /// The pane whose tools the request may reach.
        case pane(String)
        case refused(status: Int)
    }

    /// Which pane a request is for, if its token is that pane's: any other
    /// token — another pane's included — is a 401, before anything is read.
    static func route(_ request: HTTPRequest, tokens: PaneTokens) -> Route {
        let parts = request.path.split(separator: "?", omittingEmptySubsequences: false)[0].split(separator: "/")
        guard parts.count == 2, parts[0] == "mcp" else { return .refused(status: 404) }
        let tag = String(parts[1])
        guard tokens.authorizes(request.headers["authorization"], tag: tag) else { return .refused(status: 401) }
        return .pane(tag)
    }

    private func serve(_ request: HTTPRequest, on connection: NWConnection) {
        let tag: String
        switch Self.route(request, tokens: tokens) {
        case .refused(let status): return respond(connection, status: status, body: nil)
        case .pane(let pane): tag = pane
        }
        switch request.method {
        case "POST": break
        case "DELETE": return respond(connection, status: 200, body: nil)
        default: return respond(connection, status: 405, body: nil)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            let error: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]
            return respond(connection, status: 400, body: try? JSONSerialization.data(withJSONObject: error))
        }
        let handler = self.handler
        // A JSON object, read on this queue and then only on the main actor.
        nonisolated(unsafe) let message = parsed
        Task { @MainActor [weak self] in
            let answer = await handler(tag, message)
            let body = answer.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            self?.queue.async { self?.respond(connection, status: body == nil ? 202 : 200, body: body) }
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data?) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 413: "Too Large"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        var data = Data((head + "\r\n").utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One HTTP request, from the bytes received so far.
struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    /// Lowercased names.
    let headers: [String: String]
    let body: Data

    enum Parsed: Equatable {
        case incomplete, invalid
        case complete(HTTPRequest)
    }

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 * 1024 ? .invalid : .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body)))
    }
}
