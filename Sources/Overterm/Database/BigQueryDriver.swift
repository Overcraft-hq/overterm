import Foundation
import _CryptoExtras

/// BigQuery over its REST API: `jobs.query`, then the job's results until it
/// is done. Signed in with a service account's key (a JWT it signs, traded
/// for a token) or with whoever `gcloud` is signed in as on this Mac.
actor BigQueryDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let serviceAccount: String?
    private var token: (value: String, expires: Date)?
    private let session = URLSession(configuration: .ephemeral)

    init(_ connection: DatabaseConnection, serviceAccount: String?) {
        config = connection
        self.serviceAccount = serviceAccount
    }

    private var base: String { "https://bigquery.googleapis.com/bigquery/v2/projects/\(config.project)" }

    func connect() async throws {
        _ = try await accessToken()
        _ = try await get("\(base)/datasets?maxResults=1")
    }

    func close() async {
        token = nil
    }

    // MARK: Signing in

    private func accessToken() async throws -> String {
        if let token, token.expires > Date().addingTimeInterval(60) { return token.value }
        let fresh: (String, Date)
        switch config.bigQueryAuth {
        case .serviceAccount:
            guard let serviceAccount, !serviceAccount.isEmpty else { throw DatabaseError.failed("No service account key — Edit Connection to add it.") }
            fresh = try await Self.token(serviceAccount: serviceAccount, session: session)
        case .gcloud:
            fresh = (try await Self.gcloudToken(), Date().addingTimeInterval(45 * 60))
        }
        token = fresh
        return fresh.0
    }

    /// The service account signs a JWT (RS256) that Google trades for a token.
    static func token(
        serviceAccount json: String, session: URLSession, scope: String = "https://www.googleapis.com/auth/bigquery"
    ) async throws -> (String, Date) {
        guard let key = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
            let email = key["client_email"] as? String, let pem = key["private_key"] as? String
        else { throw DatabaseError.failed("That isn't a service account key: it has no client_email or private_key.") }
        let audience = key["token_uri"] as? String ?? "https://oauth2.googleapis.com/token"
        let assertion = try jwt(email: email, privateKey: pem, audience: audience, now: Date(), scope: scope)
        var request = URLRequest(url: URL(string: audience)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, _) = try await session.data(for: request)
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let token = answer["access_token"] as? String else {
            let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error_description"] as? String
            throw DatabaseError.failed("Google refused the service account: \(reason ?? String(decoding: data, as: UTF8.self))")
        }
        return (token, Date().addingTimeInterval(TimeInterval(answer["expires_in"] as? Int ?? 3600)))
    }

    /// `header.claims.signature`, each base64url.
    static func jwt(
        email: String, privateKey pem: String, audience: String, now: Date, scope: String = "https://www.googleapis.com/auth/bigquery"
    ) throws -> String {
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let issued = Int(now.timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"], options: .sortedKeys)
        let claims = try JSONSerialization.data(
            withJSONObject: [
                "iss": email, "scope": scope, "aud": audience, "iat": issued, "exp": issued + 3600,
            ], options: .sortedKeys)
        let signing = encode(header) + "." + encode(claims)
        let key: _RSA.Signing.PrivateKey
        do {
            key = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw DatabaseError.failed("The service account's private key can't be read.")
        }
        let signature = try key.signature(for: Data(signing.utf8), padding: .insecurePKCS1v1_5)
        return signing + "." + encode(signature.rawRepresentation)
    }

    /// `gcloud auth print-access-token`, from where gcloud is installed (a
    /// GUI app's PATH has no Homebrew).
    static func gcloudToken() async throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", home.appendingPathComponent("google-cloud-sdk/bin/gcloud").path,
            "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
        ]
        guard let gcloud = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DatabaseError.failed("gcloud isn't installed — or use a service account key.")
        }
        do {
            let token = try await Git.run(URL(fileURLWithPath: gcloud), ["auth", "print-access-token"], in: home, timeout: 30)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw DatabaseError.failed("gcloud gave no token — run gcloud auth login.") }
            return token
        } catch let error as GitError {
            throw DatabaseError.failed("gcloud: \(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    // MARK: Requests

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw DatabaseError.failed(message ?? "BigQuery answered \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return json
    }

    private func get(_ address: String) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw DatabaseError.failed("Not a valid project.") }
        return try await send(URLRequest(url: url))
    }

    private func post(_ address: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw DatabaseError.failed("Not a valid project.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    // MARK: Queries

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        let started = Date()
        var body: [String: Any] = ["query": sql, "useLegacySql": false, "maxResults": limit, "timeoutMs": 30_000]
        if !config.location.isEmpty { body["location"] = config.location }
        if !config.database.isEmpty { body["defaultDataset"] = ["projectId": config.project, "datasetId": config.database] }
        var answer = try await post("\(base)/queries", body)
        // Not done in time: its results, asked for until it is.
        while answer["jobComplete"] as? Bool == false, let job = answer["jobReference"] as? [String: Any], let id = job["jobId"] as? String {
            try Task.checkCancellation()
            var address = "\(base)/queries/\(id)?maxResults=\(limit)&timeoutMs=10000"
            if let location = job["location"] as? String { address += "&location=\(location)" }
            answer = try await get(address)
        }
        var result = Self.parse(answer, limit: limit)
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// `schema.fields` and `rows[].f[].v`; nested and repeated fields as JSON.
    static func parse(_ answer: [String: Any], limit: Int) -> QueryResult {
        var result = QueryResult()
        let fields = (answer["schema"] as? [String: Any])?["fields"] as? [[String: Any]] ?? []
        result.columns = fields.map { $0["name"] as? String ?? "" }
        result.types = fields.map { field in
            let type = field["type"] as? String ?? ""
            return field["mode"] as? String == "REPEATED" ? "ARRAY<\(type)>" : type
        }
        let rows = answer["rows"] as? [[String: Any]] ?? []
        result.rows = rows.prefix(limit).map { row in
            let cells = row["f"] as? [[String: Any]] ?? []
            return cells.enumerated().map { index, cell in value(cell["v"], type: index < result.types.count ? result.types[index] : "") }
        }
        let total = Int(answer["totalRows"] as? String ?? "") ?? rows.count
        result.truncated = total > result.rows.count
        if let affected = answer["numDmlAffectedRows"] as? String { result.affected = Int(affected) }
        var notes: [String] = []
        if let bytes = Int64(answer["totalBytesProcessed"] as? String ?? "") {
            notes.append("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) processed")
        }
        if answer["cacheHit"] as? Bool == true { notes.append("from cache") }
        result.message = notes.isEmpty ? (result.hasRows ? nil : "Done") : notes.joined(separator: " · ")
        return result
    }

    static func value(_ v: Any?, type: String) -> String? {
        switch v {
        case nil, is NSNull: return nil
        case let text as String:
            // TIMESTAMP comes as seconds since 1970.
            if type == "TIMESTAMP", let seconds = Double(text) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: Date(timeIntervalSince1970: seconds))
            }
            return text
        case let array as [Any]:
            return ClickHouseDriver.text(array.map { ($0 as? [String: Any])?["v"] ?? $0 })
        case let object as [String: Any]:
            if let fields = object["f"] as? [[String: Any]] { return ClickHouseDriver.text(fields.map { $0["v"] ?? NSNull() }) }
            return ClickHouseDriver.text(object)
        default: return "\(v!)"
        }
    }

    // MARK: The catalog

    func schemas() async throws -> [String] {
        let answer = try await get("\(base)/datasets?maxResults=1000")
        let names = (answer["datasets"] as? [[String: Any]] ?? []).compactMap { ($0["datasetReference"] as? [String: Any])?["datasetId"] as? String }
        return names.sorted { ($0 == config.database ? 0 : 1, $0) < ($1 == config.database ? 0 : 1, $1) }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        let answer = try await get("\(base)/datasets/\(schema)/tables?maxResults=1000")
        return (answer["tables"] as? [[String: Any]] ?? []).compactMap { table in
            guard let name = (table["tableReference"] as? [String: Any])?["tableId"] as? String else { return nil }
            return CatalogTable(schema: schema, name: name, isView: (table["type"] as? String) == "VIEW")
        }.sorted { $0.name < $1.name }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] {
        let result = try await execute(
            """
            SELECT table_name, column_name, data_type, is_nullable FROM `\(config.project).\(schema)`.INFORMATION_SCHEMA.COLUMNS
            ORDER BY table_name, ordinal_position
            """, limit: 1_000_000)
        return result.rows.map { CatalogColumn(table: $0[0] ?? "", name: $0[1] ?? "", type: $0[2] ?? "", nullable: $0[3] == "YES") }
    }
}
