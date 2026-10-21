import Foundation
import Network

/// An HTTP server on 127.0.0.1 that answers with what it was sent, for the
/// API client's tests and its E2E scenario — nothing leaves the machine.
///
/// - `/status/<code>`: that status.
/// - `/redirect`: 302 to `/echo`.
/// - `/cookie/set?name=value`: sets the cookie; `/cookie/get`: the Cookie header back.
/// - `/openapi.json`: a small OpenAPI document describing this server.
/// - anything else: 200 and `{method, path, query, headers, body}` as JSON.
final class E2EEchoServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "overterm.e2e-echo")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Starts listening and waits until it does.
    func start() throws {
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

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

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
                self.respond(connection, status: 400, headers: [:], body: Data())
            case .complete(let request):
                self.answer(request, on: connection)
            }
        }
    }

    private func answer(_ request: HTTPRequest, on connection: NWConnection) {
        let components = URLComponents(string: "http://x" + request.path)
        let path = components?.path ?? request.path
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        if path.hasPrefix("/status/"), let code = Int(path.dropFirst(8)) {
            return respond(connection, status: code, headers: ["Content-Type": "application/json"], body: Data("{\"status\":\(code)}".utf8))
        }
        switch path {
        case "/redirect":
            return respond(connection, status: 302, headers: ["Location": "/echo"], body: Data())
        case "/cookie/set":
            let cookie = query.first.map { "\($0.key)=\($0.value); Path=/" } ?? ""
            return respond(connection, status: 200, headers: ["Set-Cookie": cookie, "Content-Type": "text/plain"], body: Data("set".utf8))
        case "/cookie/get":
            return respond(
                connection, status: 200, headers: ["Content-Type": "text/plain"], body: Data((request.headers["cookie"] ?? "").utf8))
        case "/openapi.json":
            return respond(connection, status: 200, headers: ["Content-Type": "application/json"], body: Data(Self.openAPI.utf8))
        default:
            let echo: [String: Any] = [
                "method": request.method, "path": path, "query": query, "headers": request.headers,
                "body": String(decoding: request.body, as: UTF8.self),
            ]
            let body = (try? JSONSerialization.data(withJSONObject: echo, options: [.sortedKeys])) ?? Data()
            respond(connection, status: 200, headers: ["Content-Type": "application/json", "X-Echo": "1"], body: body)
        }
    }

    private func respond(_ connection: NWConnection, status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    static let openAPI = """
        {
          "openapi": "3.0.3",
          "info": {"title": "Echo", "version": "1.0"},
          "servers": [{"url": "/"}],
          "paths": {
            "/users": {
              "get": {"summary": "List users", "tags": ["Users"], "parameters": [{"name": "page", "in": "query", "schema": {"type": "integer"}}]},
              "post": {"summary": "Create user", "tags": ["Users"],
                "requestBody": {"content": {"application/json": {"example": {"name": "Ada"}}}}}
            },
            "/users/{id}": {
              "get": {"operationId": "getUser", "tags": ["Users"], "parameters": [{"name": "id", "in": "path", "required": true}]}
            },
            "/health": {"get": {"summary": "Health"}}
          }
        }
        """
}
