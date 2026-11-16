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
    private let lock = NSLock()
    private var connected = 0
    /// How many connections it has taken: a test's "nothing was asked".
    var connections: Int { lock.withLock { connected } }

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
        lock.withLock { connected += 1 }
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
        case "/graphql":
            // Introspection answers the schema; any other query, a user.
            let isIntrospection = String(decoding: request.body, as: UTF8.self).contains("__schema")
            let answer = isIntrospection ? Self.graphQLSchema : #"{"data":{"user":{"name":"Ada","posts":[{"title":"Hello"}]}}}"#
            return respond(connection, status: 200, headers: ["Content-Type": "application/json"], body: Data(answer.utf8))
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

    /// A small schema, as a server's introspection answers: Query.user(id)
    /// → User { name, posts → [Post!]! }, Mutation.rename, a Role enum.
    static let graphQLSchema: String = {
        func named(_ kind: String, _ name: String) -> [String: Any] { ["kind": kind, "name": name, "ofType": NSNull()] }
        func nonNull(_ inner: [String: Any]) -> [String: Any] { ["kind": "NON_NULL", "name": NSNull(), "ofType": inner] }
        func list(_ inner: [String: Any]) -> [String: Any] { ["kind": "LIST", "name": NSNull(), "ofType": inner] }
        func field(_ name: String, _ type: [String: Any], args: [[String: Any]] = [], description: String? = nil) -> [String: Any] {
            ["name": name, "type": type, "args": args, "description": description ?? NSNull(), "isDeprecated": false, "deprecationReason": NSNull()]
        }
        func argument(_ name: String, _ type: [String: Any]) -> [String: Any] {
            ["name": name, "type": type, "description": NSNull(), "defaultValue": NSNull()]
        }
        func object(_ name: String, _ fields: [[String: Any]], description: String? = nil) -> [String: Any] {
            [
                "kind": "OBJECT", "name": name, "description": description ?? NSNull(), "fields": fields, "inputFields": NSNull(),
                "interfaces": [], "enumValues": NSNull(), "possibleTypes": NSNull(),
            ]
        }
        let id = nonNull(named("SCALAR", "ID"))
        let string = named("SCALAR", "String")
        let types: [[String: Any]] = [
            object("Query", [field("user", named("OBJECT", "User"), args: [argument("id", id)], description: "One user, by id"), field("users", nonNull(list(nonNull(named("OBJECT", "User")))))]),
            object("Mutation", [field("rename", named("OBJECT", "User"), args: [argument("id", id), argument("name", nonNull(string))])]),
            object("User", [field("id", id), field("name", string), field("role", named("ENUM", "Role")), field("posts", nonNull(list(nonNull(named("OBJECT", "Post")))))]),
            object("Post", [field("title", string), field("author", named("OBJECT", "User"))]),
            [
                "kind": "ENUM", "name": "Role", "description": NSNull(), "fields": NSNull(), "inputFields": NSNull(), "interfaces": NSNull(),
                "enumValues": [["name": "ADMIN"], ["name": "MEMBER"]], "possibleTypes": NSNull(),
            ],
            ["kind": "SCALAR", "name": "ID", "description": NSNull(), "fields": NSNull(), "inputFields": NSNull(), "interfaces": NSNull(), "enumValues": NSNull(), "possibleTypes": NSNull()],
            ["kind": "SCALAR", "name": "String", "description": NSNull(), "fields": NSNull(), "inputFields": NSNull(), "interfaces": NSNull(), "enumValues": NSNull(), "possibleTypes": NSNull()],
            object("__Schema", []),
        ]
        let schema: [String: Any] = [
            "data": [
                "__schema": [
                    "queryType": ["name": "Query"], "mutationType": ["name": "Mutation"], "subscriptionType": NSNull(), "types": types,
                ]
            ]
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data(), as: UTF8.self)
    }()

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
