import Foundation

/// ClickHouse over its HTTP interface: a statement is a POST, a result is
/// JSONCompact (its columns, their types, the rows). The server stops at the
/// row limit itself (`max_result_rows`, `result_overflow_mode=break`), and
/// a read-only connection is ClickHouse's own `readonly=1`.
actor ClickHouseDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let password: String?
    private let session: URLSession

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        session = URLSession(configuration: configuration, delegate: ClickHouseTrust(config: connection), delegateQueue: nil)
    }

    /// `http://host:8123/` — https unless SSL is off.
    func url(database: String?, limit: Int?) -> URL? {
        var components = URLComponents()
        components.scheme = config.sslMode == .disable ? "http" : "https"
        components.host = config.host
        components.port = config.port ?? (config.sslMode == .disable ? 8123 : 8443)
        components.path = "/"
        var items = [URLQueryItem(name: "default_format", value: "JSONCompact")]
        if let database, !database.isEmpty { items.append(URLQueryItem(name: "database", value: database)) }
        if let limit {
            items.append(URLQueryItem(name: "max_result_rows", value: "\(limit + 1)"))
            items.append(URLQueryItem(name: "result_overflow_mode", value: "break"))
        }
        if config.readOnly { items.append(URLQueryItem(name: "readonly", value: "1")) }
        components.queryItems = items
        return components.url
    }

    func connect() async throws {
        _ = try await execute("SELECT 1", limit: 1)
    }

    func close() async { session.invalidateAndCancel() }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let url = url(database: config.database, limit: SQLText.onlyReads(sql) ? limit : nil) else {
            throw DatabaseError.failed("The host isn't a valid address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(sql.utf8)
        request.setValue(config.user.isEmpty ? "default" : config.user, forHTTPHeaderField: "X-ClickHouse-User")
        if let password, !password.isEmpty { request.setValue(password, forHTTPHeaderField: "X-ClickHouse-Key") }
        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DatabaseError.failed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DatabaseError.failed(Self.message(text))
        }
        var result = try Self.parse(data, limit: limit)
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// JSONCompact: `{"meta": [{"name", "type"}], "data": [[…]], "rows": n}`;
    /// an empty body for a statement that returns nothing.
    static func parse(_ data: Data, limit: Int) throws -> QueryResult {
        var result = QueryResult()
        guard !data.isEmpty, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            result.message = "Done"
            return result
        }
        let meta = json["meta"] as? [[String: Any]] ?? []
        result.columns = meta.map { $0["name"] as? String ?? "" }
        result.types = meta.map { $0["type"] as? String ?? "" }
        let rows = json["data"] as? [[Any]] ?? []
        result.rows = rows.prefix(limit).map { $0.map(Self.text) }
        result.truncated = rows.count > limit || (json["rows_before_limit_at_least"] as? Int).map { $0 > limit } == true
        if let statistics = json["statistics"] as? [String: Any], let read = statistics["rows_read"] as? Int {
            result.message = "\(read) rows read"
        }
        return result
    }

    /// A JSON value as the grid shows it.
    static func text(_ value: Any) -> String? {
        switch value {
        case is NSNull: return nil
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default:
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }
    }

    /// `Code: 60. DB::Exception: Table shop.x does not exist. (UNKNOWN_TABLE) (version …)` → the sentence.
    static func message(_ text: String) -> String {
        guard let range = text.range(of: "DB::Exception: ") else { return text.isEmpty ? "ClickHouse refused it." : text }
        var message = String(text[range.upperBound...])
        if let version = message.range(of: " (version") { message = String(message[..<version.lowerBound]) }
        return message
    }

    func schemas() async throws -> [String] {
        let names = try await execute(
            "SELECT name FROM system.databases WHERE name NOT IN ('system', 'INFORMATION_SCHEMA', 'information_schema') ORDER BY name",
            limit: 10_000
        ).rows.compactMap { $0.first ?? nil }
        return names.sorted { ($0 == config.database ? 0 : 1, $0) < ($1 == config.database ? 0 : 1, $1) }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        try await execute(
            "SELECT name, engine FROM system.tables WHERE database = \(DatabaseDrivers.literal(schema)) ORDER BY name", limit: 100_000
        ).rows.map { CatalogTable(schema: schema, name: $0[0] ?? "", isView: ($0[1] ?? "").hasSuffix("View")) }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] {
        try await execute(
            "SELECT table, name, type FROM system.columns WHERE database = \(DatabaseDrivers.literal(schema)) ORDER BY table, position",
            limit: 1_000_000
        ).rows.map {
            CatalogColumn(table: $0[0] ?? "", name: $0[1] ?? "", type: $0[2] ?? "", nullable: ($0[2] ?? "").hasPrefix("Nullable"))
        }
    }
}

/// SSL's modes over HTTPS: prefer and require take any certificate, as
/// libpq's do; verify-full leaves it to the system.
private final class ClickHouseTrust: NSObject, URLSessionDelegate, Sendable {
    let verify: Bool

    init(config: DatabaseConnection) { verify = config.sslMode == .verifyFull }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard !verify, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
