import Foundation

/// Neo4j over its HTTP transactional API: a statement is a POST to
/// `/db/<database>/tx/commit` with Basic auth, its rows and graph back as
/// JSON (`Neo4jParse`). A read-only connection is Neo4j's own read access
/// mode (`access-mode: READ`) — and a clause that writes is refused before
/// it is sent. The tree: databases (`SHOW DATABASES`) → labels and
/// relationship types (`[:TYPE]`) → their property keys with their types.
package actor Neo4jDriver: DatabaseDriver {
    package let config: DatabaseConnection
    package let password: String?
    package let http: HTTPDriverTransport
    /// Where statements run: the connection's database (else `neo4j`), until a `:use`.
    package private(set) var database: String

    package init(_ connection: DatabaseConnection, password: String?, api: API = .transactional) {
        self.api = api
        config = connection
        self.password = password
        http = HTTPDriverTransport(connection, timeout: 300)
        database = connection.database.isEmpty ? "neo4j" : connection.database
    }

    /// Which HTTP API answers: the transactional one (every Neo4j 4 and 5
    /// server), else the Query API (5.19 and later, Aura) where the first
    /// is off.
    package enum API: Sendable { case transactional, query }
    package private(set) var api: API
    /// The property types of a label's nodes, from the catalog, by database and label — what an edited cell is written as.
    package var editTypes: [String: [String: [String]]] = [:]

    /// One statement in its own transaction, the raw answer.
    package func post(_ statement: String, database: String, graph: Bool) async throws -> Data {
        do {
            return try await post(statement, database: database, graph: graph, api: api)
        } catch let missing as Missing where api == .transactional {
            // No transactional API: the Query API, if it is there.
            do {
                let data = try await post(statement, database: database, graph: graph, api: .query)
                api = .query
                return data
            } catch is Missing {
                throw DatabaseError.failed(missing.message)
            }
        } catch let missing as Missing {
            throw DatabaseError.failed(missing.message)
        }
    }

    private struct Missing: Error {
        let message: String
    }

    private func post(_ statement: String, database: String, graph: Bool, api: API) async throws -> Data {
        let name = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? database
        let path = api == .transactional ? "/db/\(name)/tx/commit" : "/db/\(name)/query/v2"
        guard let url = http.url(path) else { throw DatabaseError.failed("The host isn't a valid address.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.user.isEmpty || password?.isEmpty == false {
            request.setValue("Basic " + Data("\(config.user):\(password ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any]
        switch api {
        case .transactional:
            if config.readOnly { request.setValue("READ", forHTTPHeaderField: "access-mode") }
            body = [
                "statements": [
                    ["statement": statement, "resultDataContents": graph ? ["row", "graph"] : ["row"], "includeStats": true] as [String: Any]
                ]
            ]
        case .query:
            body = ["statement": statement, "accessMode": config.readOnly ? "Read" : "Write", "includeCounters": true]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403:
            let said = (try? Neo4jParse.answer(data, limit: 0).errors.first).flatMap { $0 }
            throw DatabaseError.failed(Neo4jParse.explain(said?.code ?? "Neo.ClientError.Security.Unauthorized", said?.message ?? "\(response.statusCode)"))
        case 404 where (try? Neo4jParse.answer(data, limit: 0).errors.first).flatMap({ $0 }) == nil:
            throw Missing(message: "Neo4j has no HTTP API at \(url.host ?? ""):\(url.port ?? 0) — its HTTP port (7474, 7473 with TLS), not Bolt's (7687)?")
        default:
            if let said = try? Neo4jParse.answer(data, limit: 0).errors.first { throw DatabaseError.failed(Neo4jParse.explain(said.code, said.message)) }
            throw DatabaseError.failed(HTTPDriverTransport.said(data, status: response.statusCode, kind: .neo4j))
        }
    }

    private func run(_ statement: String, database: String, limit: Int, nodes: String? = nil) async throws -> QueryResult {
        let data = try await post(statement, database: database, graph: true)
        // `MATCH (n:Label) RETURN n`: its nodes as rows of their properties, to be edited.
        if let nodes, let flat = Neo4jEdits.flatten(data, variable: nodes, limit: limit) { return flat }
        let answer = try Neo4jParse.answer(data, limit: limit)
        if let error = answer.errors.first { throw DatabaseError.failed(Neo4jParse.explain(error.code, error.message)) }
        return answer.result
    }

    /// The rows' raw values, for the catalog.
    package func rows(_ statement: String, database: String) async throws -> [[Any]] {
        let data = try await post(statement, database: database, graph: false)
        if let error = try Neo4jParse.answer(data, limit: 0).errors.first { throw DatabaseError.failed(Neo4jParse.explain(error.code, error.message)) }
        return Neo4jParse.rawRows(data)
    }

    package func connect() async throws {
        _ = try await rows("RETURN 1", database: database)
    }

    package func close() async { http.close() }

    package func execute(_ text: String, limit: Int) async throws -> QueryResult {
        var statement = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { throw DatabaseError.failed("No statement.") }
        if config.readOnly, !CypherText.onlyReads(statement) { throw DatabaseError.readOnly(CypherText.verb(of: statement)) }
        let started = Date()
        var database = self.database
        if let use = CypherText.use(statement) {
            database = use.database
            guard !use.rest.isEmpty else {
                _ = try await rows("RETURN 1", database: use.database)
                self.database = use.database
                return QueryResult(message: "Using \(use.database).")
            }
            statement = use.rest
        }
        while statement.hasSuffix(";") { statement.removeLast() }
        var result = try await run(statement, database: database, limit: limit, nodes: Neo4jEdits.nodeQuery(statement)?.variable)
        if !result.hasRows, result.message == nil { result.message = "Done" }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    // MARK: The catalog

    /// The databases this user sees, the connection's first; `system` left out.
    package func schemas() async throws -> [String] {
        var names: [String] = []
        if let found = try? await rows("SHOW DATABASES YIELD name RETURN DISTINCT name ORDER BY name", database: "system") {
            names = found.compactMap { $0.first as? String }.filter { $0 != "system" }
        }
        if !names.contains(database) { names.insert(database, at: 0) }
        return names.sorted { ($0 == database ? 0 : 1, $0) < ($1 == database ? 0 : 1, $1) }
    }

    /// Labels, then relationship types as `[:TYPE]`.
    package func tables(in schema: String) async throws -> [CatalogTable] {
        let labels = try await rows("CALL db.labels() YIELD label RETURN label ORDER BY label", database: schema).compactMap { $0.first as? String }
        let types = try await rows(
            "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType ORDER BY relationshipType", database: schema
        ).compactMap { $0.first as? String }
        return labels.map { CatalogTable(schema: schema, name: $0) } + types.map { CatalogTable(schema: schema, name: "[:\($0)]") }
    }

    /// Each label's and type's property keys, with the types Neo4j has seen.
    package func columns(in schema: String) async throws -> [CatalogColumn] {
        var columns: [CatalogColumn] = []
        for row in try await rows(
            "CALL db.schema.nodeTypeProperties() YIELD nodeLabels, propertyName, propertyTypes, mandatory RETURN nodeLabels, propertyName, propertyTypes, mandatory",
            database: schema)
        {
            guard row.count >= 4, let property = row[1] as? String else { continue }
            let type = (row[2] as? [String] ?? []).map(Self.short).joined(separator: " | ")
            for label in row[0] as? [String] ?? [] {
                columns.append(CatalogColumn(table: label, name: property, type: type, nullable: row[3] as? Bool != true))
            }
        }
        for row in try await rows(
            "CALL db.schema.relTypeProperties() YIELD relType, propertyName, propertyTypes, mandatory RETURN relType, propertyName, propertyTypes, mandatory",
            database: schema)
        {
            guard row.count >= 4, let property = row[1] as? String, let relType = row[0] as? String else { continue }
            // `:`KNOWS`` → [:KNOWS]
            let type = relType.trimmingCharacters(in: CharacterSet(charactersIn: ":")).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                .replacingOccurrences(of: "``", with: "`")
            columns.append(
                CatalogColumn(
                    table: "[:\(type)]", name: property, type: (row[2] as? [String] ?? []).map(Self.short).joined(separator: " | "),
                    nullable: row[3] as? Bool != true))
        }
        return columns
    }

    /// `String`, `Long`, `StringArray` — `Value` dropped.
    private static func short(_ type: String) -> String { type.hasSuffix("Value") ? String(type.dropLast(5)) : type }
}
