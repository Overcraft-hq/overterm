import Foundation

/// InfluxDB over its HTTP API, whichever version — the connection says
/// (Location: `1`, `2`, `3`) or `/ping`'s `X-Influxdb-Version` does.
///
/// - 1.x: InfluxQL at `/query` (a read a GET, anything else a POST), Basic
///   auth with the user and password; points written at `/write`.
/// - 2.x: Flux at `/api/v2/query` (annotated CSV back), a token (the
///   password field) and an organization (Project); InfluxQL through the
///   1.x compatibility API, a bucket its database; `/api/v2/write`.
/// - 3.x: SQL at `/api/v3/query_sql`, InfluxQL (SHOW…) at
///   `/api/v3/query_influxql`, a token and a database; `/api/v3/write_lp`.
///
/// Rows come back as the server gives them, series flattened (tags then
/// fields). The tree: databases (buckets) → measurements → their fields
/// and tags. A `WRITE` statement's line protocol is the only write it
/// sends outside the query languages; a read-only connection refuses it,
/// and every statement that isn't a read, before sending.
actor InfluxDBDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let password: String?
    private let http: HTTPDriverTransport
    private(set) var version: InfluxVersion?
    /// The database (a bucket on 2.x) statements run in: the connection's,
    /// until a `USE`.
    private(set) var database: String

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        http = HTTPDriverTransport(connection, timeout: 300)
        version = InfluxVersion(rawValue: connection.location)
        database = connection.database
    }

    private var organization: String { config.project.trimmingCharacters(in: .whitespaces) }

    /// 1.x: Basic with a user; 2.x: `Token`; 3.x: `Bearer`.
    private func authorize(_ request: inout URLRequest, _ version: InfluxVersion) {
        let secret = password ?? ""
        switch version {
        case .v1:
            if !config.user.isEmpty || !secret.isEmpty {
                request.setValue("Basic " + Data("\(config.user):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            }
        case .v2:
            if !secret.isEmpty { request.setValue("Token \(secret)", forHTTPHeaderField: "Authorization") }
        case .v3:
            if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        }
    }

    private func send(
        _ method: String, _ path: String, _ query: [(String, String)] = [], body: Data? = nil, contentType: String? = nil,
        accept: String = "application/json"
    ) async throws -> Data {
        let version = try await resolvedVersion()
        guard let url = http.url(path, query) else { throw DatabaseError.failed("The host isn't a valid address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        authorize(&request, version)
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403:
            let said = HTTPDriverTransport.said(data, status: response.statusCode, kind: .influxdb)
            let hint =
                switch version {
                case .v1: "the user and password"
                case .v2: "the token (in the password field), and that it may read this organization's buckets"
                case .v3: "the token (in the password field)"
                }
            throw DatabaseError.failed("InfluxDB refused the credentials (\(said)) — check \(hint).")
        default:
            throw DatabaseError.failed(HTTPDriverTransport.said(data, status: response.statusCode, kind: .influxdb))
        }
    }

    /// The connection's version, else `/ping`'s word, else a guess from
    /// what the connection has: an organization is 2.x, a token alone 3.x.
    func resolvedVersion() async throws -> InfluxVersion {
        if let version { return version }
        guard let url = http.url("/ping") else { throw DatabaseError.failed("The host isn't a valid address.") }
        var request = URLRequest(url: url)
        if let password, !password.isEmpty, config.user.isEmpty { request.setValue("Token \(password)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await http.send(request)
        let found =
            InfluxVersion.from(header: response.value(forHTTPHeaderField: "X-Influxdb-Version"))
            ?? (!organization.isEmpty ? .v2 : config.user.isEmpty && password?.isEmpty == false ? .v3 : .v1)
        version = found
        return found
    }

    func connect() async throws {
        let version = try await resolvedVersion()
        switch version {
        case .v1: _ = try await influxQL("SHOW DATABASES", database: nil, write: false)
        case .v2:
            guard !organization.isEmpty else { throw DatabaseError.failed("InfluxDB 2 needs the organization — the Organization field.") }
            _ = try await send("GET", "/api/v2/buckets", [("org", organization), ("limit", "1")])
        case .v3: _ = try await v3Databases()
        }
    }

    func close() async { http.close() }

    func execute(_ text: String, limit: Int) async throws -> QueryResult {
        var statement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { throw DatabaseError.failed("No statement.") }
        if config.readOnly, !InfluxText.onlyReads(statement) { throw DatabaseError.readOnly(InfluxText.verb(of: statement)) }
        let started = Date()
        var database = self.database
        if let use = InfluxText.use(statement) {
            database = use.database
            guard !use.rest.isEmpty else {
                self.database = use.database
                return QueryResult(message: "Using \(use.database).", duration: 0)
            }
            statement = use.rest
        }
        while statement.hasSuffix(";") { statement.removeLast() }
        let version = try await resolvedVersion()
        var result: QueryResult
        if let points = InfluxText.lineProtocol(statement) {
            try await write(points, database: database, version: version)
            let count = points.split(separator: "\n").count
            result = QueryResult(message: "\(count) point\(count == 1 ? "" : "s") written to \(database).")
        } else if version == .v2, InfluxText.isFlux(statement) {
            result = try await flux(statement, limit: limit)
        } else if version == .v3, !(InfluxText.verb(of: statement) == "SHOW") {
            result = try await v3(statement, database: database, language: "sql", limit: limit)
        } else if version == .v3 {
            result = try await v3(statement, database: database, language: "influxql", limit: limit)
        } else {
            let write = !InfluxText.onlyReads(statement)
            let statements = try await influxQL(statement, database: database, write: write)
            result = InfluxParse.rows(statements.last ?? [], limit: limit)
            if !result.hasRows { result.message = "Done" }
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    // MARK: The languages

    /// InfluxQL at `/query`: a read a GET, a write a POST (1.x refuses
    /// those as a GET). `db` the database, a bucket through 2.x's
    /// compatibility API.
    private func influxQL(_ q: String, database: String?, write: Bool) async throws -> [[InfluxParse.Series]] {
        var query: [(String, String)] = []
        if let database, !database.isEmpty { query.append(("db", database)) }
        let data: Data
        if write {
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "q", value: q)] + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            let body = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
            data = try await send("POST", "/query", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded")
        } else {
            data = try await send("GET", "/query", query + [("q", q)])
        }
        return try InfluxParse.influxQL(data)
    }

    private func flux(_ query: String, limit: Int) async throws -> QueryResult {
        let body: [String: Any] = [
            "query": query, "type": "flux",
            "dialect": ["header": true, "annotations": ["datatype", "group", "default"], "delimiter": ","] as [String: Any],
        ]
        let data = try await send(
            "POST", "/api/v2/query", [("org", organization)], body: try JSONSerialization.data(withJSONObject: body),
            contentType: "application/json", accept: "application/csv")
        var result = try InfluxParse.flux(String(decoding: data, as: UTF8.self), limit: limit)
        if !result.hasRows { result.message = "No rows." }
        return result
    }

    private func v3(_ query: String, database: String, language: String, limit: Int) async throws -> QueryResult {
        guard !database.isEmpty else { throw DatabaseError.failed("Which database? Set one on the connection, or `USE name` first.") }
        let body: [String: Any] = ["db": database, "q": query, "format": "csv"]
        let data = try await send(
            "POST", "/api/v3/query_\(language)", body: try JSONSerialization.data(withJSONObject: body), contentType: "application/json",
            accept: "text/csv")
        var result = InfluxParse.plainCSV(String(decoding: data, as: UTF8.self), limit: limit)
        if !result.hasRows { result.message = "No rows." }
        return result
    }

    /// Line protocol, nanosecond times.
    private func write(_ points: String, database: String, version: InfluxVersion) async throws {
        guard !database.isEmpty else { throw DatabaseError.failed("Which \(version == .v2 ? "bucket" : "database")? `USE name` first.") }
        let body = Data(points.utf8)
        switch version {
        case .v1: _ = try await send("POST", "/write", [("db", database), ("precision", "ns")], body: body, contentType: "text/plain; charset=utf-8")
        case .v2:
            _ = try await send(
                "POST", "/api/v2/write", [("org", organization), ("bucket", database), ("precision", "ns")], body: body,
                contentType: "text/plain; charset=utf-8")
        case .v3:
            _ = try await send("POST", "/api/v3/write_lp", [("db", database), ("precision", "nanosecond")], body: body, contentType: "text/plain; charset=utf-8")
        }
    }

    // MARK: The catalog

    /// Databases (buckets on 2.x), the connection's first, InfluxDB's own (`_…`) last.
    func schemas() async throws -> [String] {
        let names: [String]
        switch try await resolvedVersion() {
        case .v1:
            let series = try await influxQL("SHOW DATABASES", database: nil, write: false).last ?? []
            names = InfluxParse.column("name", of: InfluxParse.rows(series, limit: 100_000))
        case .v2:
            var found: [String] = []
            var offset = 0
            while true {
                let data = try await send("GET", "/api/v2/buckets", [("org", organization), ("limit", "100"), ("offset", "\(offset)")])
                let buckets = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["buckets"] as? [[String: Any]]) ?? []
                found += buckets.compactMap { $0["name"] as? String }
                if buckets.count < 100 || found.count >= 10_000 { break }
                offset += 100
            }
            names = found
        case .v3:
            names = try await v3Databases()
        }
        func rank(_ name: String) -> Int { name == database ? 0 : name.hasPrefix("_") ? 2 : 1 }
        return names.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    /// `/api/v3/configure/database`: `[{"iox::database": "name"}]`.
    private func v3Databases() async throws -> [String] {
        let data = try await send("GET", "/api/v3/configure/database", [("format", "json")])
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return rows.compactMap { ($0["iox::database"] ?? $0["database"]) as? String }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        let names: [String]
        switch try await resolvedVersion() {
        case .v1:
            let series = try await influxQL("SHOW MEASUREMENTS", database: schema, write: false).last ?? []
            names = InfluxParse.column("name", of: InfluxParse.rows(series, limit: 100_000))
        case .v2:
            let result = try await flux(
                "import \"influxdata/influxdb/schema\"\nschema.measurements(bucket: \(HTTPDriverTransport.quoted(schema)), start: -30d)",
                limit: 100_000)
            names = InfluxParse.column("_value", of: result)
        case .v3:
            let result = try await v3(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'iox' ORDER BY table_name", database: schema,
                language: "sql", limit: 100_000)
            names = InfluxParse.column("table_name", of: result)
        }
        return names.map { CatalogTable(schema: schema, name: $0) }
    }

    /// Each measurement's fields (with their types) and tags (`tag`).
    func columns(in schema: String) async throws -> [CatalogColumn] {
        switch try await resolvedVersion() {
        case .v1:
            return try await influxQLColumns(schema)
        case .v2:
            // 2.x maps every bucket for InfluxQL (2.4 and later): two
            // statements for the whole bucket; else Flux a measurement at a time.
            if let found = try? await influxQLColumns(schema), !found.isEmpty { return found }
            var columns: [CatalogColumn] = []
            for table in try await tables(in: schema).prefix(50) {
                let bucket = HTTPDriverTransport.quoted(schema)
                let measurement = HTTPDriverTransport.quoted(table.name)
                let prelude = "import \"influxdata/influxdb/schema\"\n"
                let fields = try await flux(
                    prelude + "schema.measurementFieldKeys(bucket: \(bucket), measurement: \(measurement), start: -30d)", limit: 10_000)
                columns += InfluxParse.column("_value", of: fields).map { CatalogColumn(table: table.name, name: $0, type: "field") }
                let tags = try await flux(
                    prelude + "schema.measurementTagKeys(bucket: \(bucket), measurement: \(measurement), start: -30d)", limit: 10_000)
                columns += InfluxParse.column("_value", of: tags).filter { !$0.hasPrefix("_") }.map {
                    CatalogColumn(table: table.name, name: $0, type: "tag")
                }
            }
            return columns
        case .v3:
            let result = try await v3(
                "SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = 'iox'", database: schema,
                language: "sql", limit: 1_000_000)
            return result.rows.map { row in
                let type = row[2] ?? ""
                return CatalogColumn(table: row[0] ?? "", name: row[1] ?? "", type: type.hasPrefix("Dictionary") ? "tag" : type)
            }
        }
    }

    private func influxQLColumns(_ schema: String) async throws -> [CatalogColumn] {
        var columns: [CatalogColumn] = []
        for series in try await influxQL("SHOW FIELD KEYS", database: schema, write: false).last ?? [] {
            for value in series.values {
                columns.append(CatalogColumn(table: series.name, name: value.first.flatMap { $0 } ?? "", type: value.count > 1 ? value[1] ?? "" : ""))
            }
        }
        for series in try await influxQL("SHOW TAG KEYS", database: schema, write: false).last ?? [] {
            for value in series.values { columns.append(CatalogColumn(table: series.name, name: value.first.flatMap { $0 } ?? "", type: "tag")) }
        }
        return columns
    }
}
