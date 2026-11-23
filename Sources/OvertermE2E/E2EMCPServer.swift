#if E2E
import Foundation
import Network

/// MCP servers of the tests' own, nothing leaving the machine: a stdio one
/// (a shell script answering a line a request) and a Streamable HTTP one —
/// a session id given at `initialize` and asked for after, a tool's answer
/// sent as an event stream. Both have one tool (`echo`), one resource
/// (`file:///readme`) and one prompt (`greet`).
package final class E2EMCPServer: @unchecked Sendable {
    /// The stdio server, as a script to run with /bin/sh.
    package static let script = #"""
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
          [ -z "$id" ] && continue
          case "$method" in
            initialize) r='{"protocolVersion":"2025-06-18","capabilities":{"tools":{},"resources":{},"prompts":{}},"serverInfo":{"name":"fake-stdio","version":"1.0"},"instructions":"A test server."}';;
            tools/list) r='{"tools":[{"name":"echo","description":"Says it back","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"times":{"type":"integer"}},"required":["text"]},"annotations":{"readOnlyHint":true}}]}';;
            tools/call)
              text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
              r="{\"content\":[{\"type\":\"text\",\"text\":\"echo: $text\"}]}";;
            resources/list) r='{"resources":[{"uri":"file:///readme","name":"readme","mimeType":"text/plain"}]}';;
            resources/templates/list) r='{"resourceTemplates":[{"uriTemplate":"file:///{name}","name":"a file"}]}';;
            resources/read) r='{"contents":[{"uri":"file:///readme","text":"hello from a resource"}]}';;
            prompts/list) r='{"prompts":[{"name":"greet","description":"Says hello","arguments":[{"name":"who","required":true}]}]}';;
            prompts/get) r='{"messages":[{"role":"user","content":{"type":"text","text":"Hello there"}}]}';;
            ping) r='{}';;
            *) echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"no such method: $method\"}}"; continue;;
          esac
          echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":$r}"
          echo "handled $method" >&2
        done
        """#

    /// Writes the script where a config can name it.
    package static func writeScript(in folder: URL) -> URL {
        let file = folder.appendingPathComponent("fake-mcp.sh")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? script.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: Streamable HTTP

    private let queue = DispatchQueue(label: "overterm.e2e-mcp")
    private var listener: NWListener?
    package private(set) var port: UInt16 = 0
    package static let sessionID = "test-session-1"
    /// A token it wants as `Authorization: Bearer …`, if set.
    package var token: String?

    package var url: String { "http://127.0.0.1:\(port)/mcp" }

    package func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        self.listener = listener
        self.port = port
    }

    package func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if complete || error != nil { return connection.cancel() }
                self.receive(connection, buffer: buffer)
            case .invalid:
                self.respond(connection, 400, [:], Data())
            case .complete(let request):
                self.answer(request, on: connection)
            }
        }
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ headers: [String: String], _ body: Data) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func answer(_ request: HTTPRequest, on connection: NWConnection) {
        if let token, request.headers["authorization"] != "Bearer \(token)" { return respond(connection, 401, [:], Data("unauthorized".utf8)) }
        if request.method == "DELETE" { return respond(connection, 200, [:], Data()) }
        guard request.method == "POST", let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
            let method = message["method"] as? String
        else { return respond(connection, 400, [:], Data("bad request".utf8)) }
        guard let id = message["id"] else { return respond(connection, 202, [:], Data()) }
        if method != "initialize", request.headers["mcp-session-id"] != Self.sessionID {
            return respond(connection, 400, [:], Data("no session".utf8))
        }
        func reply(_ result: Any) -> Data {
            (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "fake-http", "version": "2.0"],
            ]
            respond(connection, 200, ["Content-Type": "application/json", "Mcp-Session-Id": Self.sessionID], reply(result))
        case "tools/list":
            let tools: [[String: Any]] = [
                [
                    "name": "add", "description": "Adds two numbers",
                    "inputSchema": ["type": "object", "properties": ["a": ["type": "number"], "b": ["type": "number"]]],
                ]
            ]
            respond(connection, 200, ["Content-Type": "application/json"], reply(["tools": tools]))
        case "tools/call":
            // As an event stream: a progress notification first, then the reply.
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let sum = ((arguments["a"] as? Double) ?? 0) + ((arguments["b"] as? Double) ?? 0)
            let note = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#
            let result = String(decoding: reply(["content": [["type": "text", "text": "\(sum)"]], "structuredContent": ["sum": sum]]), as: UTF8.self)
            let body = "event: message\ndata: \(note)\n\nevent: message\ndata: \(result)\n\n"
            respond(connection, 200, ["Content-Type": "text/event-stream"], Data(body.utf8))
        default:
            let error = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no such method: \(method)"]] as [String: Any]
            respond(connection, 200, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: error)) ?? Data())
        }
    }
}
#endif
