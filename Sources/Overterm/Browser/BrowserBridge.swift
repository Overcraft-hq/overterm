import Foundation
import Network

/// The browser's door for agents: an MCP server on 127.0.0.1 (a random
/// port, a random token — nothing off this machine, nothing without the
/// token), at one path per pane, `/mcp/<the pane's tag>`, so an agent
/// reaches its own tab's browser and no other.
///
/// A pane learns its address from `OVERTERM_MCP_CONFIG`, a Claude Code
/// MCP config file written for it; Overterm starts `claude` with
/// `--mcp-config "$OVERTERM_MCP_CONFIG"` (Settings.arguments).
@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()
    static let configVariable = "OVERTERM_MCP_CONFIG"

    /// The browser of the tab a pane is in — the window answers.
    var resolve: ((String) -> AgentBrowser?)?
    /// The API client of the checkout a pane's tab is in — the window answers.
    var resolveAPI: ((String) -> AgentAPI?)?

    /// Agents get the browser, the API client, or both.
    private var wanted: Bool { Settings.shared.browserAgentControl || Settings.shared.apiAgentControl }

    private var server: BridgeServer?
    private(set) var port: UInt16?
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private var configDirectory: URL { AppEnvironment.supportDirectory.appendingPathComponent("mcp", isDirectory: true) }

    /// Serving, as Settings ▸ Browser asks.
    var isServing: Bool { port != nil && wanted }

    /// Starts listening (once); the config files of an earlier run go.
    func start() {
        guard server == nil, wanted else { return }
        try? FileManager.default.removeItem(at: configDirectory)
        let server = BridgeServer(token: token) { [weak self] tag, message in
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
        await BrowserMCP.handle(message, browser: { [weak self] in self?.resolve?(tag) }, api: { [weak self] in self?.resolveAPI?(tag) })
    }

    /// The config file for a new pane — written now, while the server is
    /// up — or nil when agents don't get the browser.
    func configPath(forPane tag: String) -> String? {
        guard isServing, let port else { return nil }
        let config: [String: Any] = [
            "mcpServers": [
                "overterm-browser": [
                    "type": "http",
                    "url": "http://127.0.0.1:\(port)/mcp/\(tag)",
                    "headers": ["Authorization": "Bearer \(token)"],
                ]
            ]
        ]
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let file = configDirectory.appendingPathComponent("\(tag).json")
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            // The token is a key to the browser: the user's alone.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            return nil
        }
    }

    func removeConfig(forPane tag: String) {
        try? FileManager.default.removeItem(at: configDirectory.appendingPathComponent("\(tag).json"))
    }
}

/// HTTP/1.1 on a Network.framework listener, just enough for MCP's
/// streamable HTTP: POST a JSON-RPC message, get JSON back (202 for a
/// notification); GET (a server-sent stream) is declined with 405, which
/// the protocol allows. One request per connection.
final class BridgeServer: @unchecked Sendable {
    typealias Handler = @MainActor (String, [String: Any]) async -> [String: Any]?
    private let token: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "overterm.browser-bridge")
    private var listener: NWListener?

    init(token: String, handler: @escaping Handler) {
        self.token = token
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

    private func serve(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.headers["authorization"] == "Bearer \(token)" else { return respond(connection, status: 401, body: nil) }
        let parts = request.path.split(separator: "?")[0].split(separator: "/")
        guard parts.count == 2, parts[0] == "mcp" else { return respond(connection, status: 404, body: nil) }
        let tag = String(parts[1])
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
