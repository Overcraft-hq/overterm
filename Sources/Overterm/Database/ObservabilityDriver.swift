import Foundation

/// Prometheus, Loki and Tempo over their HTTP APIs — one driver, as the
/// three share what matters: a base URL (TLS or not, a path behind a proxy,
/// an SSH tunnel's local end), Basic auth or a bearer token, a tenant
/// (`X-Scope-OrgID`, in the connection's Database field), and a window of
/// time every query looks at.
///
/// A console's query: PromQL as a range query (a graph; an instant one for
/// what can't be graphed), LogQL backwards from now (lines, or series for a
/// metric query), TraceQL as a search — or a trace's id, the trace. `.targets`,
/// `.alerts` and `.rules` are Prometheus's own pages, read as tables.
actor ObservabilityDriver: DatabaseDriver {
    let config: DatabaseConnection
    private let password: String?
    private let session: URLSession

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: ClickHouseTrust(config: connection), delegateQueue: nil)
    }

    nonisolated var kind: DatabaseKind { config.kind }

    /// `https://host:port/base/path?query`.
    nonisolated func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = config.sslMode == .disable || config.sslMode == .prefer ? "http" : "https"
        components.host = config.host
        components.port = config.port ?? kind.defaultPort
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (base.isEmpty ? "" : "/" + base) + path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        // `+` is a space to these servers' form decoding: a PromQL `a + b` must arrive as one.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Basic auth with a user, a bearer token without one; the tenant.
    func request(_ url: URL, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let password, !password.isEmpty {
            if config.user.isEmpty {
                request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue("Basic " + Data("\(config.user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            }
        } else if !config.user.isEmpty {
            request.setValue("Basic " + Data("\(config.user):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let tenant = config.database.trimmingCharacters(in: .whitespaces)
        if !tenant.isEmpty { request.setValue(tenant, forHTTPHeaderField: "X-Scope-OrgID") }
        return request
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard let url = url(path, query) else { throw DatabaseError.failed("The host isn't a valid address.") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request(url))
        } catch {
            throw DatabaseError.failed("Couldn't reach \(kind.title) at \(url.host ?? ""):\(url.port ?? 0) — \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403:
            throw DatabaseError.failed("\(kind.title) refused the credentials (\(status)) — a user and password for Basic auth, or only a token for Bearer.")
        case 404 where path.hasSuffix("/status/buildinfo") || path == "/api/echo":
            return data
        default:
            // The server's own words: Prometheus's JSON `error`, Loki's and Tempo's text.
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? String {
                message = error
            } else {
                let text = String(decoding: data.prefix(1000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                message = text.isEmpty ? "\(kind.title) answered \(status)." : text
            }
            throw HTTPFailure(status: status, message: message)
        }
    }

    /// A status the server answered with, and what it said.
    struct HTTPFailure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    func connect() async throws {
        switch kind {
        case .prometheus: _ = try await get("/api/v1/status/buildinfo")
        case .loki: _ = try await get("/loki/api/v1/labels")
        default: _ = try await get("/api/echo")
        }
    }

    func close() async { session.invalidateAndCancel() }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        try await execute(sql, limit: limit, range: .h1)
    }

    func execute(_ text: String, limit: Int, range: TimeRange) async throws -> QueryResult {
        let query = ObservabilityText.clean(text)
        guard !query.isEmpty else { throw DatabaseError.failed("No query.") }
        let started = Date()
        var result: QueryResult
        switch kind {
        case .prometheus: result = try await prometheus(query, limit: limit, range: range)
        case .loki: result = try await loki(query, limit: limit, range: range)
        default: result = try await tempo(query, limit: limit, range: range)
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    // MARK: Prometheus

    private func prometheus(_ query: String, limit: Int, range: TimeRange) async throws -> QueryResult {
        switch query {
        case ".targets": return try ObservabilityParse.targets(await get("/api/v1/targets", ["state": "active"]))
        case ".alerts": return try ObservabilityParse.alerts(await get("/api/v1/alerts"))
        case ".rules": return try rules(await get("/api/v1/rules"))
        default: break
        }
        let (start, end) = range.window()
        do {
            let data = try await get(
                "/api/v1/query_range",
                ["query": query, "start": seconds(start), "end": seconds(end), "step": "\(range.step)"])
            return ObservabilityRows.result(.series(try ObservabilityParse.prometheus(data)), limit: limit)
        } catch {
            // `x[5m]`, a string: not a graph — what it is now, then.
            guard error.localizedDescription.contains("range vector") || error.localizedDescription.contains("string") else { throw error }
            let data = try await get("/api/v1/query", ["query": query, "time": seconds(end)])
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any] ?? [:]
            if object["resultType"] as? String == "matrix" {
                // Each sample of each series a row.
                var rows: [[String?]] = []
                for series in ObservabilityParse.series(object) {
                    for point in series.points { rows.append([MetricSeries.signature(series.labels), ObservabilityRows.timestamp(point.time), ObservabilityRows.format(point.value)]) }
                }
                return QueryResult(
                    columns: ["series", "time", "value"], types: ["", "", ""], rows: Array(rows.prefix(limit)), truncated: rows.count > limit)
            }
            return ObservabilityRows.result(.series(ObservabilityParse.series(object)), limit: limit)
        }
    }

    private func rules(_ data: Data) throws -> QueryResult {
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let groups = (object["data"] as? [String: Any])?["groups"] as? [[String: Any]] ?? []
        var rows: [[String?]] = []
        for group in groups {
            for rule in group["rules"] as? [[String: Any]] ?? [] {
                rows.append([
                    group["name"] as? String, rule["name"] as? String, rule["type"] as? String, rule["health"] as? String,
                    rule["state"] as? String, rule["query"] as? String,
                ])
            }
        }
        return QueryResult(columns: ["group", "rule", "type", "health", "state", "query"], types: Array(repeating: "", count: 6), rows: rows)
    }

    private func seconds(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }
    private func nanos(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970 * 1e9)) }

    // MARK: Loki

    private func loki(_ query: String, limit: Int, range: TimeRange) async throws -> QueryResult {
        let (start, end) = range.window()
        let data = try await get(
            "/loki/api/v1/query_range",
            [
                "query": query, "start": nanos(start), "end": nanos(end), "limit": "\(limit)", "direction": "backward",
                "step": "\(range.step)",
            ])
        return ObservabilityRows.result(try ObservabilityParse.loki(data), limit: limit)
    }

    /// Lines after `after` (nanoseconds), oldest first — the live tail, polled.
    func tail(_ text: String, after: Int64, limit: Int) async throws -> [LogLine] {
        let query = ObservabilityText.clean(text)
        let data = try await get(
            "/loki/api/v1/query_range",
            ["query": query, "start": String(after + 1), "end": nanos(Date()), "limit": "\(limit)", "direction": "forward"])
        guard case .logs(let lines) = try ObservabilityParse.loki(data) else {
            throw DatabaseError.failed("Live follows log lines — a metric query isn't one.")
        }
        return lines
    }

    // MARK: Tempo

    private func tempo(_ query: String, limit: Int, range: TimeRange) async throws -> QueryResult {
        if LogLine.isTraceID(query) {
            return ObservabilityRows.result(.trace(try await trace(query)), limit: 10_000)
        }
        let (start, end) = range.window()
        let data = try await get(
            "/api/search",
            ["q": query, "start": "\(Int(start.timeIntervalSince1970))", "end": "\(Int(end.timeIntervalSince1970))", "limit": "\(min(limit, 500))"])
        var result = ObservabilityRows.result(.traces(try ObservabilityParse.tempoSearch(data)), limit: limit)
        if result.rows.isEmpty { result.message = "No traces in the \(range.title.lowercased())." }
        return result
    }

    func trace(_ id: String) async throws -> TraceDetail {
        do {
            return try ObservabilityParse.tempoTrace(await get("/api/v2/traces/\(id)"), id: id)
        } catch let error as HTTPFailure where error.status == 404 {
            // Tempo before 2.5 has only v1 — or there is no such trace, which v1 says too.
            _ = error
            return try ObservabilityParse.tempoTrace(await get("/api/traces/\(id)"), id: id)
        }
    }

    // MARK: The catalog

    /// The tree's folders: Prometheus's metrics; Loki's labels; Tempo's tags.
    func schemas() async throws -> [String] {
        switch kind {
        case .prometheus: ["metrics"]
        case .loki: ["labels"]
        default: ["tags"]
        }
    }

    /// Metric names, label names, tag names.
    func tables(in schema: String) async throws -> [CatalogTable] {
        try await names().map { CatalogTable(schema: schema, name: $0) }
    }

    func names() async throws -> [String] {
        let (start, end) = TimeRange.h6.window()
        switch kind {
        case .prometheus:
            return try ObservabilityParse.names(await get("/api/v1/label/__name__/values"))
        case .loki:
            return try ObservabilityParse.names(await get("/loki/api/v1/labels", ["start": nanos(start), "end": nanos(end)]))
        default:
            do {
                return try ObservabilityParse.tempoTags(await get("/api/v2/search/tags"))
            } catch {
                return try ObservabilityParse.tempoTags(await get("/api/search/tags"))
            }
        }
    }

    /// A label's values (Loki), a tag's (Tempo), a metric's labels (Prometheus).
    func values(of name: String) async throws -> [String] {
        let (start, end) = TimeRange.h6.window()
        switch kind {
        case .prometheus:
            let data = try await get("/api/v1/labels", ["match[]": name, "start": seconds(start), "end": seconds(end)])
            return try ObservabilityParse.names(data).filter { $0 != "__name__" }
        case .loki:
            let path = "/loki/api/v1/label/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/values"
            return try ObservabilityParse.names(await get(path, ["start": nanos(start), "end": nanos(end)]))
        default:
            let tag = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            do {
                return try ObservabilityParse.tempoValues(await get("/api/v2/search/tag/\(tag)/values"))
            } catch {
                return try ObservabilityParse.tempoValues(await get("/api/search/tag/\(tag)/values"))
            }
        }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] { [] }
}
