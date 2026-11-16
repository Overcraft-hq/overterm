import Foundation

/// RabbitMQ over its management HTTP API (the management plugin, 15672;
/// 15671 with TLS): Basic auth, TLS as the other HTTP kinds. The console
/// is `RabbitText`'s language; the tree is vhosts → queues (ready, unacked,
/// consumers) and `exchange:`s, their bindings below them. A read-only
/// connection refuses PUBLISH, PURGE and any method but GET before sending.
/// AMQP itself is never spoken: PEEK and PUBLISH are the API's own.
actor RabbitMQDriver: DatabaseDriver {
    let config: DatabaseConnection
    private let password: String?
    private let http: HTTPDriverTransport
    /// Where queue and exchange names are looked up: the connection's vhost (else `/`), until a `USE`.
    private(set) var vhost: String

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        http = HTTPDriverTransport(connection, timeout: 60)
        vhost = connection.database.isEmpty ? "/" : connection.database
    }

    /// How many messages a PEEK reads unless told.
    static let defaultPeek = 10
    /// A payload longer than this is cut by the server.
    static let payloadCut = 50_000

    // MARK: HTTP

    /// `path` is already percent-encoded (the vhost `/` is `%2F`).
    func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        guard let base = http.url(""), let url = URL(string: base.absoluteString + path) else {
            throw DatabaseError.failed("\(path) isn't a valid address — percent-encode what isn't (a vhost's / is %2F).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // No Accept: RabbitMQ answers JSON anyway, and refuses a purge
        // asked to (406 — its answer has no body).
        request.setValue("Basic " + Data("\(config.user):\(password ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch let error as DatabaseError {
            // An HTTP request to the AMQP port is answered with AMQP's header, then closed.
            if [5672, 5671].contains(url.port) {
                throw DatabaseError.failed(
                    "\(url.port ?? 0) is AMQP's port — the panel speaks the management API, on 15672 (15671 with TLS).")
            }
            throw error
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw DatabaseError.failed("RabbitMQ refused \(config.user.isEmpty ? "the user" : config.user) — check the user and the password.")
        case 403 where path == "/api/overview" || path.hasPrefix("/api/vhosts"):
            throw DatabaseError.failed(
                "\(config.user) may not use the management API: RabbitMQ lets in only users tagged management, monitoring or administrator.")
        case 404 where path == "/api/overview":
            throw DatabaseError.failed(
                "No management API at \(url.host ?? ""):\(url.port ?? 0) — is the management plugin on (the -management image, or rabbitmq-plugins enable rabbitmq_management), and is that its port?"
            )
        case 404:
            throw NotFound(said: RabbitText.said(data, status: 404))
        default:
            throw DatabaseError.failed(RabbitText.said(data, status: response.statusCode))
        }
    }

    /// A 404, said by whoever knows what was looked for.
    private struct NotFound: LocalizedError {
        let said: String
        var errorDescription: String? { said }
    }

    func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        let data = try await request(method, path, body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        guard !data.isEmpty else { return [String: Any]() }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DatabaseError.failed("RabbitMQ's answer wasn't JSON: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    private func queuePath(_ queue: String, in vhost: String) -> String {
        "/api/queues/\(RabbitText.segment(vhost))/\(RabbitText.segment(queue))"
    }

    // MARK: DatabaseDriver

    func connect() async throws {
        _ = try await json("GET", "/api/overview")
    }

    func close() async { http.close() }

    func execute(_ text: String, limit: Int) async throws -> QueryResult {
        let statement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { throw DatabaseError.failed("No statement.") }
        let command: RabbitText.Command
        do {
            command = try RabbitText.parse(statement)
        } catch let problem as RabbitText.Problem {
            throw DatabaseError.failed(problem.message)
        }
        if config.readOnly, !RabbitText.onlyReads(statement) { throw DatabaseError.readOnly(RabbitText.verb(of: statement)) }
        let started = Date()
        var result: QueryResult
        do {
            result = try await run(command, limit: limit)
        } catch let missing as NotFound {
            switch command {
            case .use(let name): throw DatabaseError.failed("There's no vhost \(name).")
            case .peek(let queue, _), .purge(let queue): throw DatabaseError.failed("There's no queue \(queue) in vhost \(vhost).")
            case .publish(let exchange, _, _): throw DatabaseError.failed("There's no exchange \(RabbitText.exchangeName(exchange)) in vhost \(vhost).")
            case .api(_, let path, _): throw DatabaseError.failed("Nothing at \(path) (\(missing.said)).")
            }
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private func run(_ command: RabbitText.Command, limit: Int) async throws -> QueryResult {
        var result: QueryResult
        switch command {
        case .use(let name):
            _ = try await json("GET", "/api/vhosts/\(RabbitText.segment(name))")
            vhost = name
            result = QueryResult(message: "Using vhost \(name).")
        case .peek(let queue, let count):
            result = try await peek(queue, count: min(count ?? Self.defaultPeek, max(limit, 1)))
        case .publish(let exchange, let key, let payload):
            result = try await publish(payload, to: exchange, key: key)
        case .purge(let queue):
            // The API doesn't say how many went, and its counts are sampled: none said.
            _ = try await request("DELETE", queuePath(queue, in: vhost) + "/contents")
            result = QueryResult(message: "Purged \(queue): its ready messages are deleted.")
        case .api(let method, let path, let body):
            var data: Data?
            if let body {
                guard (try? JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])) != nil else {
                    throw DatabaseError.failed("The body isn't JSON.")
                }
                data = Data(body.utf8)
            }
            let answer = try await request(method, path, body: data)
            do {
                result = try RabbitText.rows(answer, limit: limit)
            } catch {
                result = QueryResult(columns: ["answer"], rows: [[String(decoding: answer.prefix(100_000), as: UTF8.self)]])
            }
        }
        return result
    }

    /// `n` messages read and put back (`reject_requeue_true`), said so —
    /// with the queue's count, and what a quorum queue counts.
    private func peek(_ queue: String, count: Int) async throws -> QueryResult {
        let info =
            try await json("GET", queuePath(queue, in: vhost) + "?columns=type")
            as? [String: Any] ?? [:]
        let type = info["type"] as? String ?? "classic"
        if type == "stream" {
            throw DatabaseError.failed("\(queue) is a stream: the management API can't read one — a stream client (offsets) can.")
        }
        let body: [String: Any] = ["count": count, "ackmode": "reject_requeue_true", "encoding": "auto", "truncate": Self.payloadCut]
        let data = try await request("POST", queuePath(queue, in: vhost) + "/get", body: try JSONSerialization.data(withJSONObject: body))
        var result: QueryResult
        do {
            result = try RabbitText.messages(data, limit: count)
        } catch let problem as RabbitText.Problem {
            throw DatabaseError.failed(problem.message)
        }
        // The last message's count is what was left behind it — live, where
        // the queue's own count is sampled every few seconds.
        let ready = RabbitText.readyCount(data).map { $0 + result.rows.count }
        var said = result.rows.isEmpty ? "\(queue) has no ready messages." : "Read \(result.rows.count)\(ready.map { " of \($0)" } ?? "") ready messages — put back, marked redelivered."
        if type == "quorum", !result.rows.isEmpty {
            said += " On a quorum queue each peek counts as a delivery: a delivery limit dead-letters or drops a message peeked that often."
        }
        if result.rows.contains(where: { row in Int(row[7] ?? "") ?? 0 > Self.payloadCut }) {
            said += " Payloads over \(Self.payloadCut) bytes are cut."
        }
        result.message = said
        return result
    }

    private func publish(_ payload: String, to exchange: String, key: String) async throws -> QueryResult {
        let name = RabbitText.exchangeName(exchange)
        let body: [String: Any] = ["properties": [String: Any](), "routing_key": key, "payload": payload, "payload_encoding": "string"]
        let answer = try await json("POST", "/api/exchanges/\(RabbitText.segment(vhost))/\(RabbitText.segment(name))/publish", body: body)
        let routed = (answer as? [String: Any])?["routed"] as? Bool ?? false
        return QueryResult(
            affected: routed ? 1 : 0,
            message: routed
                ? "Published to \(name) with key \(key.isEmpty ? "\"\"" : key)."
                : "Published to \(name), but no queue is bound for key \(key.isEmpty ? "\"\"" : key): RabbitMQ dropped it.")
    }

    // MARK: The catalog

    /// The vhosts this user may see, the current one first.
    func schemas() async throws -> [String] {
        let list = try await json("GET", "/api/vhosts?columns=name") as? [[String: Any]] ?? []
        var names = list.compactMap { $0["name"] as? String }
        if !names.contains(vhost) { names.append(vhost) }
        return names.sorted { ($0 == vhost ? 0 : 1, $0) < ($1 == vhost ? 0 : 1, $1) }
    }

    /// Queues, then exchanges as `exchange:<name>` (the default one as `amq.default`).
    func tables(in schema: String) async throws -> [CatalogTable] {
        let v = RabbitText.segment(schema)
        let queues =
            try await json("GET", "/api/queues/\(v)?columns=name,type,messages_ready,messages_unacknowledged,consumers,state") as? [[String: Any]] ?? []
        let exchanges = try await json("GET", "/api/exchanges/\(v)?columns=name,type,internal") as? [[String: Any]] ?? []
        let queueRows = queues.compactMap { queue -> CatalogTable? in
            guard let name = queue["name"] as? String else { return nil }
            return CatalogTable(schema: schema, name: name, detail: RabbitText.queueDetail(queue))
        }
        let exchangeRows = exchanges.compactMap { exchange -> CatalogTable? in
            guard let name = exchange["name"] as? String else { return nil }
            let type = exchange["type"] as? String ?? ""
            return CatalogTable(
                schema: schema, name: RabbitText.exchangePrefix + RabbitText.exchangeName(name),
                detail: exchange["internal"] as? Bool == true ? "\(type) · internal" : type)
        }
        return queueRows.sorted { $0.name < $1.name } + exchangeRows.sorted { $0.name < $1.name }
    }

    /// Bindings: a queue's sources, an exchange's destinations, each with its key.
    func columns(in schema: String) async throws -> [CatalogColumn] {
        let bindings = try await json("GET", "/api/bindings/\(RabbitText.segment(schema))") as? [[String: Any]] ?? []
        return RabbitText.bindingColumns(bindings)
    }
}
