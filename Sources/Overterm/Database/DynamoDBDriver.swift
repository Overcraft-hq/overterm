import Foundation

/// Amazon DynamoDB over its JSON API (`X-Amz-Target: DynamoDB_20120810.*`),
/// each request signed with SigV4 (`S3Signer`, service `dynamodb`). AWS's
/// endpoint for a region, or DynamoDB Local's (any credentials will do
/// there; Overterm signs with placeholder ones when none are given).
/// Credentials as the S3 kind takes them: an AWS profile, or an access key
/// (the connection's User) and its secret (the keychain's password).
///
/// The console is PartiQL (`ExecuteStatement`), followed page by page to
/// the row limit; items come back as rows — the table's keys first, then
/// every attribute by name, each value as text (`DynamoItems`). The tree is
/// the region's tables, and a table's keys and indexes as its columns.
actor DynamoDBDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let password: String?
    private let http: HTTPDriverTransport
    /// Each table's keys, partition then sort — read once, for a result's order.
    private var keys: [String: [String]] = [:]
    private var tableNames: [String]?

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        http = HTTPDriverTransport(connection)
    }

    var region: String {
        let region = config.location.trimmingCharacters(in: .whitespaces)
        if !region.isEmpty { return region }
        if !config.awsProfile.isEmpty, let profile = AWSProfile.load(config.awsProfile), let own = profile.region { return own }
        return "us-east-1"
    }

    /// The profile's, the key's, or — only off AWS — placeholders.
    func signer() throws -> S3Signer {
        let host = config.serverName ?? config.host
        if !config.awsProfile.isEmpty {
            guard let profile = AWSProfile.load(config.awsProfile) else {
                throw DatabaseError.failed("No profile “\(config.awsProfile)” in ~/.aws/credentials.")
            }
            return S3Signer(
                accessKey: profile.accessKey, secretKey: profile.secretKey, sessionToken: profile.sessionToken, region: region, service: "dynamodb")
        }
        if !config.user.isEmpty, let password, !password.isEmpty {
            return S3Signer(accessKey: config.user, secretKey: password, sessionToken: nil, region: region, service: "dynamodb")
        }
        guard !DynamoItems.isAWS(host) else {
            throw DatabaseError.failed(
                config.user.isEmpty ? "No credentials — an access key and its secret, or an AWS profile." : "No secret key — Edit Connection to add it.")
        }
        // DynamoDB Local checks that a request is signed, not by whom.
        return S3Signer(accessKey: config.user.isEmpty ? "overterm" : config.user, secretKey: "overterm", sessionToken: nil, region: region, service: "dynamodb")
    }

    /// One API call: `operation`'s JSON in, its JSON out — or the error AWS said.
    func call(_ operation: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = http.url("/") else { throw DatabaseError.failed("The endpoint isn't a valid address.") }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        let headers = try signer().sign(
            method: "POST", url: url,
            headers: ["content-type": "application/x-amz-json-1.0", "x-amz-target": "DynamoDB_20120810.\(operation)"],
            payloadHash: S3Signer.sha256(payload), date: Date())
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            if let (type, message) = DynamoItems.errorType(data) { throw DatabaseError.failed(DynamoItems.explain(type, message)) }
            throw DatabaseError.failed(HTTPDriverTransport.said(data, status: response.statusCode, kind: .dynamodb))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// An operation's JSON as text, its answer as text: a call from
    /// outside the actor (the tests make and drop their tables so).
    func call(_ operation: String, json: String) async throws -> String {
        let body = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        let answer = try await call(operation, body)
        return String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }

    func connect() async throws {
        _ = try await call("ListTables", ["Limit": 1])
    }

    func close() async { http.close() }

    func execute(_ text: String, limit: Int) async throws -> QueryResult {
        var statement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") { statement = String(statement.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !statement.isEmpty else { throw DatabaseError.failed("No statement.") }
        if config.readOnly, !DynamoText.onlyReads(statement) { throw DatabaseError.readOnly(DynamoText.verb(of: statement)) }
        let started = Date()
        let reads = DynamoText.onlyReads(statement)
        var items: [[String: Any]] = []
        var token: String?
        var pages = 0
        repeat {
            var body: [String: Any] = ["Statement": statement]
            if let token { body["NextToken"] = token }
            // Items looked at a page: no more than the rows still wanted
            // need, nor so few that a filter makes a crawl of it.
            if reads { body["Limit"] = min(max(limit + 1 - items.count, 100), 1000) }
            let answer = try await call("ExecuteStatement", body)
            items += (answer["Items"] as? [[String: Any]]) ?? []
            token = answer["NextToken"] as? String
            pages += 1
        } while token != nil && items.count <= limit && pages < 100
        var result = QueryResult()
        if reads {
            var order: [String]?
            if let table = DynamoText.subject(of: statement) { order = try? await keyNames(table) }
            let (columns, types, rows) = DynamoItems.rows(Array(items.prefix(limit)), keys: order ?? [])
            result.columns = columns.isEmpty ? (order ?? []).nonEmptyOr(["item"]) : columns
            result.types = types.isEmpty ? Array(repeating: "", count: result.columns.count) : types
            result.rows = rows
            result.truncated = items.count > limit || token != nil
            if token != nil, items.count <= limit {
                result.message = "Stopped after \(pages) pages — a WHERE on the partition key reads less."
            }
        } else {
            result.message = "Done"
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private func keyNames(_ table: String) async throws -> [String] {
        if let known = keys[table] { return known }
        let description = try await describe(table)
        let names = DynamoItems.keyNames(description)
        keys[table] = names
        return names
    }

    private func describe(_ table: String) async throws -> [String: Any] {
        (try await call("DescribeTable", ["TableName": table]))["Table"] as? [String: Any] ?? [:]
    }

    // MARK: The catalog

    /// One folder: the region (DynamoDB has no databases).
    func schemas() async throws -> [String] { [region] }

    func tables(in schema: String) async throws -> [CatalogTable] {
        try await names().map { CatalogTable(schema: schema, name: $0) }
    }

    private func names() async throws -> [String] {
        var names: [String] = []
        var after: String?
        repeat {
            var body: [String: Any] = ["Limit": 100]
            if let after { body["ExclusiveStartTableName"] = after }
            let answer = try await call("ListTables", body)
            names += (answer["TableNames"] as? [String]) ?? []
            after = answer["LastEvaluatedTableName"] as? String
        } while after != nil && names.count < 10_000
        tableNames = names
        return names
    }

    /// Each table's keys and indexes — the first 200 tables.
    func columns(in schema: String) async throws -> [CatalogColumn] {
        var tables = tableNames ?? []
        if tableNames == nil { tables = try await names() }
        var columns: [CatalogColumn] = []
        for table in tables.prefix(200) {
            guard let description = try? await describe(table) else { continue }
            keys[table] = DynamoItems.keyNames(description)
            columns += DynamoItems.columns(of: table, description: description)
        }
        return columns
    }
}

extension Array {
    fileprivate func nonEmptyOr(_ other: [Element]) -> [Element] { isEmpty ? other : self }
}
