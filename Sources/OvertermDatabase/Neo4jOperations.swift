import CryptoKit
import Foundation

/// Neo4j's Server page (`SHOW TRANSACTIONS`, `dbms.components()`, the count
/// store), its nodes edited by `elementId`, and its users and roles
/// (`SHOW USERS`, `SHOW ROLES`, privileges — roles and privileges are
/// Enterprise's). Everything over the driver's own HTTP API.
/// docs/architecture.md, Database: Server page, Editing rows, Users and roles.
extension Neo4jDriver: DatabaseMonitoring, DatabaseTableEditing, DatabaseUserManagement {
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .slowQueries, .locks, .sizes] }

    package static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        [
            SessionStop(
                terminate: true, menu: "Terminate Transaction…", title: "Terminate \(session.id)?",
                command: "TERMINATE TRANSACTION \(Neo4jEdits.string(session.id))",
                effect: [session.user, session.database, session.client].compactMap { $0 }.joined(separator: " · ") + "\n"
                    + OpsText.statement(session.statement, limit: 400) + "\n\nIts statement stops and what it changed is rolled back.",
                button: "Terminate")
        ]
    }

    // MARK: Reading

    /// A statement's rows as records by column name, either API's.
    package func records(_ statement: String, database: String) async throws -> [[String: Any]] {
        let data = try await post(statement, database: database, graph: false)
        if let error = try Neo4jParse.answer(data, limit: 0).errors.first { throw DatabaseError.failed(Neo4jParse.explain(error.code, error.message)) }
        return Neo4jOps.records(data)
    }

    /// The edition, `community` or `enterprise` (nil when unsaid).
    package func edition() async -> String? {
        let rows = try? await records("CALL dbms.components() YIELD name, versions, edition RETURN name, versions, edition", database: "system")
        return (rows?.first?["edition"] as? String)?.lowercased()
    }

    /// The statement the page lists transactions with: its own is told by it.
    package static let showTransactions = "SHOW TRANSACTIONS YIELD *"

    private func transactions() async throws -> Monitored<[Neo4jTransaction]> {
        do {
            return .value(Neo4jOps.transactions(try await records(Self.showTransactions, database: database), user: config.user))
        } catch {
            let message = error.localizedDescription
            if message.contains("Permission denied") || message.contains("not allowed") || message.contains("Forbidden") {
                return .unavailable(
                    MonitorGap(
                        reason: "This user sees only its own transactions, or none: \(message)",
                        fix: "GRANT SHOW TRANSACTION (*) ON DATABASE * TO <role>"))
            }
            throw error
        }
    }

    package func overview() async throws -> ServerOverview {
        var facts: [ServerFact] = []
        var notes: [String] = []
        if let component = try? await records("CALL dbms.components() YIELD name, versions, edition RETURN name, versions, edition", database: "system").first {
            facts.append(
                ServerFact(
                    title: component["name"] as? String ?? "Neo4j", value: (component["versions"] as? [Any])?.compactMap(HTTPDriverTransport.text).joined(separator: ", ") ?? "—",
                    detail: (component["edition"] as? String).map { "\($0) edition" }))
        }
        if let databases = try? await records("SHOW DATABASES YIELD name, currentStatus RETURN name, currentStatus", database: "system") {
            let online = databases.filter { ($0["currentStatus"] as? String) == "online" }.count
            facts.append(ServerFact(title: "Databases", value: "\(databases.count)", detail: "\(online) online"))
        }
        let nodes = try? await records("MATCH (n) RETURN count(n) AS c", database: database).first?["c"]
        let relationships = try? await records("MATCH ()-[r]->() RETURN count(r) AS c", database: database).first?["c"]
        facts.append(ServerFact(title: "Nodes", value: nodes.flatMap(HTTPDriverTransport.text) ?? "—", detail: "in \(database)"))
        facts.append(ServerFact(title: "Relationships", value: relationships.flatMap(HTTPDriverTransport.text) ?? "—", detail: "in \(database)"))
        if case .value(let running)? = try? await transactions() {
            facts.append(ServerFact(title: "Transactions", value: "\(running.count)", detail: "open now, every database"))
        }
        if let store = await storeSize() { facts.append(ServerFact(title: "Store", value: OpsText.bytes(store), detail: "\(database) on disk")) }
        notes.append(
            "Slow Queries are the statements running now, by how long they have run: Neo4j keeps its record of finished ones in query.log on the server's disk (db.logs.query.threshold), which isn't read over HTTP."
        )
        return ServerOverview(facts: facts, notes: notes)
    }

    /// The store's size from JMX, where the server says it (4.x; 5.x only
    /// with its metrics exported to JMX).
    private func storeSize() async -> Int64? {
        guard
            let rows = try? await records(
                "CALL dbms.queryJmx('org.neo4j:*') YIELD name, attributes RETURN name, attributes", database: database)
        else { return nil }
        return Neo4jOps.storeSize(rows, database: database)
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        switch try await transactions() {
        case .value(let all): return .value(all.map(\.activity))
        case .unavailable(let gap): return .unavailable(gap)
        }
    }

    /// Neo4j's record of finished statements is a file on the server: the
    /// ones running now, longest first.
    package func slowQueries() async throws -> Monitored<[SlowQuery]> {
        switch try await transactions() {
        case .value(let all):
            return .value(
                all.filter { !$0.isOwn && !($0.query ?? "").isEmpty }.map { transaction in
                    SlowQuery(
                        id: transaction.id, statement: transaction.query ?? "", calls: 1, total: transaction.seconds ?? 0, mean: transaction.seconds ?? 0,
                        database: transaction.database, user: transaction.user)
                })
        case .unavailable(let gap): return .unavailable(gap)
        }
    }

    package func locks() async throws -> Monitored<[LockWait]> {
        switch try await transactions() {
        case .value(let all): return .value(Neo4jOps.waits(all))
        case .unavailable(let gap): return .unavailable(gap)
        }
    }

    package func sizes() async throws -> Monitored<DatabaseSizes> {
        var sizes = DatabaseSizes()
        let labels = try await records("CALL db.labels() YIELD label RETURN label ORDER BY label", database: database).compactMap { $0["label"] as? String }
        let types = try await records(
            "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType ORDER BY relationshipType", database: database
        ).compactMap { $0["relationshipType"] as? String }
        // The count store answers each of these without reading the graph.
        for label in labels.prefix(200) {
            if let count = try? await records("MATCH (n:\(CypherText.name(label))) RETURN count(n) AS c", database: database).first?["c"] as? NSNumber {
                sizes.tables.append(SizeEntry(name: label, bytes: count.int64Value, detail: "label", unit: "nodes"))
            }
        }
        for type in types.prefix(200) {
            if let count = try? await records("MATCH ()-[r:\(CypherText.name(type))]->() RETURN count(r) AS c", database: database).first?["c"] as? NSNumber {
                sizes.tables.append(SizeEntry(name: "[:\(type)]", bytes: count.int64Value, detail: "relationship type", unit: "relationships"))
            }
        }
        sizes.tables.sort { $0.bytes > $1.bytes }
        if labels.count > 200 || types.count > 200 { sizes.notes.append("The first 200 labels and 200 types are counted.") }
        if let store = await storeSize() {
            sizes.databases.append(SizeEntry(name: database, bytes: store, detail: "store"))
        } else {
            sizes.notes.append("Counts, not bytes: Neo4j 5 says a store's size in its metrics (server.metrics.jmx.enabled), not over HTTP.")
        }
        return .value(sizes)
    }

    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("TERMINATE TRANSACTION") }
        if case .value(let all) = try await transactions(), all.contains(where: { $0.id == session && $0.isOwn }) {
            throw DatabaseError.failed("That is this page's own transaction.")
        }
        let rows = try await records("TERMINATE TRANSACTION \(Neo4jEdits.string(session))", database: database)
        if let message = rows.first?["message"] as? String, message.lowercased() != "transaction terminated." {
            throw DatabaseError.failed(message)
        }
    }

    // MARK: Editing nodes

    package func editDialect() async -> SQLDialect { .postgres }  // never read: its statements are Cypher, `editStatements`

    package func key(of table: TableName) async throws -> TableKey? { nil }

    package func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>? {
        let columns = result.columns
        guard let query = Neo4jEdits.nodeQuery(statement) else { return .failure(.said(Neo4jEdits.refusal)) }
        guard api == .transactional else { return .failure(.said("Nodes are edited over Neo4j's transactional HTTP API, which this server has off.")) }
        let keyColumn = Neo4jEdits.keyColumn(query.variable)
        guard columns.first == keyColumn else { return .failure(.said("Only a result whose every row is a node is edited.")) }
        let database = query.database ?? self.database
        let types: [String: [String]]
        do {
            types = try await propertyTypes(label: query.label, database: database)
        } catch {
            return .failure(.said(error.localizedDescription))
        }
        var readOnly: Set<String> = [keyColumn]
        for column in columns.dropFirst() where Neo4jEdits.writable(types[column]) == nil { readOnly.insert(column) }
        let key = TableKey(
            table: TableName(schema: database, name: query.label), kind: .identity("elementId"), columns: [keyColumn], readOnlyColumns: readOnly)
        return .success(EditableResult(key: key, columns: columns, keyIndexes: [0]))
    }

    /// Each property's types as the catalog has seen them on nodes with the label.
    private func propertyTypes(label: String, database: String) async throws -> [String: [String]] {
        let key = database + "\u{1}" + label
        if let known = editTypes[key] { return known }
        let rows = try await records(
            "CALL db.schema.nodeTypeProperties() YIELD nodeLabels, propertyName, propertyTypes RETURN nodeLabels, propertyName, propertyTypes",
            database: database)
        let types = Neo4jEdits.types(rows, label: label)
        editTypes[key] = types
        return types
    }

    package func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        let database = result.key.table.schema ?? self.database
        let types = try await propertyTypes(label: result.key.table.name, database: database)
        return try Neo4jEdits.statements(edits, rows: rows, result: result, types: types, use: database == self.database ? nil : database)
    }

    /// In one explicit transaction (`/tx`): every statement must count the
    /// one node it names, else it is rolled back; then committed.
    package func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        guard api == .transactional else { throw DatabaseError.failed("Nodes are edited over Neo4j's transactional HTTP API.") }
        guard !statements.isEmpty else { return }
        var database = self.database
        var cypher: [String] = []
        for statement in statements {
            if let use = CypherText.use(statement.sql) {
                database = use.database
                cypher.append(use.rest)
            } else {
                cypher.append(statement.sql)
            }
        }
        let name = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? database
        let opened = try await transaction("POST", "/db/\(name)/tx", statements: cypher)
        guard let id = opened.id else { throw DatabaseError.failed(opened.error ?? "Neo4j didn't open a transaction. Nothing was saved.") }
        func rollback() async { _ = try? await transaction("DELETE", "/db/\(name)/tx/\(id)", statements: nil) }
        if let error = opened.error {
            await rollback()
            throw DatabaseError.failed(error + " — nothing was saved.")
        }
        for (index, statement) in statements.enumerated() {
            let changed = opened.counts[safe: index] ?? 0
            guard changed == statement.expectedRows else {
                await rollback()
                throw DatabaseError.failed(EditApplyError.wrongCount(index: index, changed: changed, sql: statement.sql))
            }
        }
        let committed = try await transaction("POST", "/db/\(name)/tx/\(id)/commit", statements: [])
        if let error = committed.error { throw DatabaseError.failed(error + " — nothing was saved.") }
    }

    /// A request on an explicit transaction: its id, each statement's first
    /// number (`RETURN count(n)`), the first error.
    private func transaction(_ method: String, _ path: String, statements: [String]?) async throws -> (id: String?, counts: [Int], error: String?) {
        guard let url = http.url(path) else { throw DatabaseError.failed("The host isn't a valid address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.user.isEmpty || password?.isEmpty == false {
            request.setValue("Basic " + Data("\(config.user):\(password ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        if let statements {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["statements": statements.map { ["statement": $0] }])
        }
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DatabaseError.failed(HTTPDriverTransport.said(data, status: response.statusCode, kind: .neo4j))
        }
        return Neo4jOps.transactionAnswer(data)
    }

    // MARK: Users and roles

    package func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own

    package func userStatements() async -> any UserStatementMaking { Neo4jUserStatements(enterprise: await edition() == "enterprise") }

    package func users() async throws -> Monitored<[DatabaseUser]> {
        let users: [[String: Any]]
        do {
            users = try await records("SHOW USERS", database: "system")
        } catch {
            return .unavailable(
                MonitorGap(
                    reason: "This user may not list users: \(error.localizedDescription)", fix: "GRANT SHOW USER ON DBMS TO <role>  (Enterprise; an admin's)"))
        }
        var listed = users.compactMap(Neo4jOps.user)
        if await edition() == "enterprise", let roles = try? await records("SHOW ROLES YIELD role RETURN role", database: "system") {
            listed += roles.compactMap { ($0["role"] as? String).map { DatabaseUser(name: $0, isRole: true, canLogin: false, superuser: $0 == "admin") } }
        }
        return .value(listed)
    }

    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        guard await edition() == "enterprise" else {
            return .unavailable(MonitorGap(reason: "Neo4j Community has no roles or privileges: every user may do everything."))
        }
        let name = CypherText.name(user.name)
        var grants: [DatabaseGrant] = []
        if !user.isRole {
            grants += user.memberOf.map { DatabaseGrant(kind: "role", object: $0, privileges: ["member"]) }
        }
        do {
            let rows = try await records("SHOW \(user.isRole ? "ROLE" : "USER") \(name) PRIVILEGES AS COMMANDS", database: "system")
            grants += rows.compactMap { $0["command"] as? String }.map { command in
                DatabaseGrant(
                    kind: user.isRole ? "privilege" : "via a role", object: command, privileges: [],
                    target: user.isRole ? .named(kind: "command", name: command) : nil)
            }
        } catch {
            if grants.isEmpty { return .unavailable(MonitorGap(reason: error.localizedDescription, fix: "GRANT SHOW PRIVILEGE ON DBMS TO <role>")) }
        }
        return .value(grants)
    }

    /// Each statement (one or several, split as the console splits them)
    /// on `system`, sent once, nothing kept.
    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        for statement in statements {
            let ns = statement.sql as NSString
            for range in CypherText.statements(in: statement.sql) {
                do {
                    _ = try await records(ns.substring(with: range), database: "system")
                } catch {
                    throw DatabaseError.failed(statement.scrub(error.localizedDescription))
                }
            }
        }
    }
}

/// A transaction as `SHOW TRANSACTIONS` lists it.
package struct Neo4jTransaction: Equatable {
    package var id: String
    package var database: String?
    package var user: String?
    package var client: String?
    package var query: String?
    package var status: String?
    package var seconds: Double?
    package var application: String?
    package var isOwn = false

    /// `Blocked by: [neo4j-transaction-3, …]`'s ids.
    package var blockedBy: [String] {
        guard let status, status.hasPrefix("Blocked by") else { return [] }
        guard let open = status.firstIndex(of: "["), let close = status.lastIndex(of: "]"), open < close else { return [] }
        return status[status.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    package var activity: DatabaseActivity {
        let blockers = blockedBy
        return DatabaseActivity(
            id: id, user: user, database: database, client: client, application: application,
            state: blockers.isEmpty ? (status ?? "Running") : "Blocked", statement: query, seconds: seconds,
            waiting: blockers.isEmpty ? nil : blockers.joined(separator: ", "), isOwn: isOwn)
    }
}

/// Neo4j's answers read. Pure.
package enum Neo4jOps {
    /// Either API's rows as records by column name, raw values.
    package static func records(_ data: Data) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let query = object["data"] as? [String: Any] {
            let fields = query["fields"] as? [String] ?? []
            return (query["values"] as? [[Any]] ?? []).map { Dictionary(zip(fields, $0), uniquingKeysWith: { first, _ in first }) }
        }
        guard let result = (object["results"] as? [[String: Any]])?.first else { return [] }
        let columns = result["columns"] as? [String] ?? []
        return (result["data"] as? [[String: Any]] ?? []).map { entry in
            Dictionary(zip(columns, entry["row"] as? [Any] ?? []), uniquingKeysWith: { first, _ in first })
        }
    }

    /// `SHOW TRANSACTIONS YIELD *`'s rows; the one that ran it (by this
    /// user, its own statement) is the page's own.
    package static func transactions(_ rows: [[String: Any]], user: String) -> [Neo4jTransaction] {
        rows.compactMap { row in
            guard let id = row["transactionId"] as? String else { return nil }
            let query = row["currentQuery"] as? String
            let username = row["username"] as? String
            let metadata = row["metaData"] as? [String: Any]
            return Neo4jTransaction(
                id: id, database: row["database"] as? String, user: username, client: row["clientAddress"] as? String,
                query: query?.isEmpty == true ? nil : query, status: row["status"] as? String,
                seconds: (row["elapsedTime"]).flatMap(duration) ?? (row["elapsedTimeMillis"] as? NSNumber).map { $0.doubleValue / 1000 },
                application: (metadata?["app"] as? String) ?? (row["protocol"] as? String),
                isOwn: (username ?? "") == user && query?.trimmingCharacters(in: .whitespacesAndNewlines) == Neo4jDriver.showTransactions)
        }
    }

    /// A Duration as the HTTP API writes it: `PT1M3.5S`, `P1DT2H`; or seconds as a number.
    package static func duration(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String, text.hasPrefix("P") else { return nil }
        var total = 0.0
        var number = ""
        var inTime = false
        for c in text.dropFirst() {
            if c == "T" {
                inTime = true
            } else if c.isNumber || c == "." || c == "-" {
                number.append(c)
            } else {
                let n = Double(number) ?? 0
                number = ""
                switch (c, inTime) {
                case ("Y", false): total += n * 365 * 86400
                case ("M", false): total += n * 30 * 86400
                case ("W", false): total += n * 7 * 86400
                case ("D", false): total += n * 86400
                case ("H", true): total += n * 3600
                case ("M", true): total += n * 60
                case ("S", true): total += n
                default: return nil
                }
            }
        }
        return total
    }

    /// Who waits on whom, from each transaction's `Blocked by:`.
    package static func waits(_ transactions: [Neo4jTransaction]) -> [LockWait] {
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return transactions.flatMap { waiting in
            waiting.blockedBy.map { blocking in
                let blocker = byID[blocking]
                return LockWait(
                    waiting: waiting.id, waitingUser: waiting.user, waitingStatement: waiting.query, blocking: blocking, blockingUser: blocker?.user,
                    blockingStatement: blocker?.query, lock: waiting.database.map { "a lock in \($0)" }, seconds: waiting.seconds)
            }
        }
    }

    /// JMX's "Store sizes" (4.x: TotalStoreSize) or the store's size metric (5.x).
    package static func storeSize(_ rows: [[String: Any]], database: String) -> Int64? {
        for row in rows {
            let name = row["name"] as? String ?? ""
            guard let attributes = row["attributes"] as? [String: Any] else { continue }
            if name.contains("Store sizes"), name.contains(database) || !name.contains("database="),
                let total = (attributes["TotalStoreSize"] as? [String: Any])?["value"] as? NSNumber
            {
                return total.int64Value
            }
            if name.lowercased().contains("\(database).store.size.total"), let value = (attributes["Value"] as? [String: Any])?["value"] as? NSNumber {
                return value.int64Value
            }
        }
        return nil
    }

    /// `SHOW USERS`' row: Community's has `user` and
    /// `passwordChangeRequired`; Enterprise's `roles`, `suspended`, `home`.
    package static func user(_ row: [String: Any]) -> DatabaseUser? {
        guard let name = row["user"] as? String else { return nil }
        let roles = (row["roles"] as? [Any])?.compactMap { $0 as? String } ?? []
        var attributes: [String] = []
        if row["passwordChangeRequired"] as? Bool == true { attributes.append("must change password") }
        if let home = row["home"] as? String { attributes.append("home \(home)") }
        let suspended = row["suspended"] as? Bool == true
        if suspended { attributes.append("suspended") }
        return DatabaseUser(
            name: name, canLogin: !suspended, superuser: roles.contains("admin"), attributes: attributes, memberOf: roles.filter { $0 != "PUBLIC" })
    }

    /// An explicit transaction's answer: the id in its `commit` URL, each
    /// statement's first value as a number, the first error.
    package static func transactionAnswer(_ data: Data) -> (id: String?, counts: [Int], error: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, [], nil) }
        var id: String?
        if let commit = object["commit"] as? String, let url = URL(string: commit) {
            let parts = url.pathComponents
            if let at = parts.lastIndex(of: "tx"), parts.indices.contains(at + 1) { id = parts[at + 1] }
        }
        let counts = (object["results"] as? [[String: Any]] ?? []).map { result -> Int in
            let first = ((result["data"] as? [[String: Any]])?.first?["row"] as? [Any])?.first
            return (first as? NSNumber)?.intValue ?? 0
        }
        let error = (object["errors"] as? [[String: Any]])?.first.map { Neo4jParse.explain($0["code"] as? String ?? "", $0["message"] as? String ?? "") }
        return (id, counts, error)
    }
}

// MARK: Editing nodes

/// A label's nodes edited: `MATCH (n:Label) [WHERE …] RETURN n …` shown as
/// rows of their properties (`flatten`), each found again by its
/// `elementId`; a cell written as the type the catalog has seen for its
/// property, NULL as REMOVE; a node added with CREATE, deleted with DETACH
/// DELETE (its relationships with it — said). Pure.
package enum Neo4jEdits {
    package static let refusal = "Nodes are edited in MATCH (n:Label) [WHERE …] RETURN n [ORDER BY …] [SKIP …] [LIMIT …] — one label, the node itself returned."

    package struct NodeQuery: Equatable {
        package var variable: String
        package var label: String
        /// `:use db`'s.
        package var database: String?
    }

    /// The key column's name in a flattened result.
    package static func keyColumn(_ variable: String) -> String { "elementId(\(variable))" }

    /// Words that, after the pattern, make the rows something else.
    private static let otherClauses = #"\b(MATCH|OPTIONAL|WITH|UNWIND|CALL|UNION|RETURN|CREATE|MERGE|SET|DELETE|DETACH|REMOVE|FOREACH|LOAD|USE)\b"#

    package static func nodeQuery(_ statement: String) -> NodeQuery? {
        let use = CypherText.use(statement)
        let body = use?.rest ?? statement
        let upper = CypherText.stripped(body)
        let pattern =
            #"^\s*MATCH\s*\(\s*(\w+)\s*:\s*(\w+|\s*X+)\s*(\{[^}]*\})?\s*\)\s*(WHERE\s(.*?))?\s*RETURN\s+(\w+)\s*(ORDER\s+BY\s(.*?))?\s*(SKIP\s+\S+\s*)?(LIMIT\s+\S+\s*)?;?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = upper as NSString
        guard let match = regex.firstMatch(in: upper, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ at: Int) -> String? { match.range(at: at).location == NSNotFound ? nil : ns.substring(with: match.range(at: at)) }
        guard group(1) == group(6) else { return nil }
        // STARTS WITH and ENDS WITH are operators, not WITH clauses.
        for clause in [group(5), group(8)].compactMap({ $0 })
        where clause.replacingOccurrences(of: #"\b(STARTS|ENDS)\s+WITH\b"#, with: " ", options: .regularExpression)
            .range(of: otherClauses, options: .regularExpression) != nil
        {
            return nil
        }
        // The variable as written (stripped is upper-cased), the label as named.
        let original = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let variable = original.range(of: #"(?i)^MATCH\s*\(\s*(\w+)"#, options: .regularExpression).map({ range -> String in
                String(original[range]).replacingOccurrences(of: #"(?i)^MATCH\s*\(\s*"#, with: "", options: .regularExpression)
            }),
            let label = CypherText.subject(of: body)
        else { return nil }
        return NodeQuery(variable: variable, label: label, database: use?.database)
    }

    /// A one-column answer whose every value is a node with an elementId,
    /// as rows: `elementId(n)`, then each property (sorted). Either API's
    /// answer; nil for anything else, so it is shown as it was.
    package static func flatten(_ data: Data, variable: String, limit: Int) -> QueryResult? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let errors = object["errors"] as? [Any], !errors.isEmpty { return nil }
        var nodes: [(id: String, properties: [String: Any])] = []
        var total = 0
        if let query = object["data"] as? [String: Any] {
            guard query["fields"] as? [String] == [variable] else { return nil }
            let values = query["values"] as? [[Any]] ?? []
            total = values.count
            for row in values.prefix(limit) {
                guard row.count == 1, let node = row[0] as? [String: Any], node["labels"] != nil, let id = node["elementId"] as? String else { return nil }
                nodes.append((id, node["properties"] as? [String: Any] ?? [:]))
            }
        } else {
            guard let result = (object["results"] as? [[String: Any]])?.last, result["columns"] as? [String] == [variable] else { return nil }
            let data = result["data"] as? [[String: Any]] ?? []
            total = data.count
            for entry in data.prefix(limit) {
                guard let row = entry["row"] as? [Any], row.count == 1, let meta = (entry["meta"] as? [Any])?.first as? [String: Any],
                    meta["type"] as? String == "node", let id = meta["elementId"] as? String
                else { return nil }
                nodes.append((id, row[0] as? [String: Any] ?? [:]))
            }
        }
        guard !nodes.isEmpty else { return nil }
        let key = keyColumn(variable)
        let names = Set(nodes.flatMap(\.properties.keys)).sorted()
        guard !names.contains(key) else { return nil }
        var result = QueryResult()
        result.columns = [key] + names
        result.types =
            ["elementId"]
            + names.map { name in
                let kinds = Set(nodes.compactMap { $0.properties[name] }.map(jsonType))
                return kinds.count == 1 ? kinds.first ?? "" : "mixed"
            }
        result.rows = nodes.map { node in [node.id] + names.map { HTTPDriverTransport.text(node.properties[$0]) } }
        result.truncated = total > limit
        return result
    }

    package static func jsonType(_ value: Any) -> String {
        switch value {
        case is String: return "String"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "Boolean" }
            return CFNumberIsFloatType(number) ? "Float" : "Integer"
        case is [Any]: return "List"
        case is [String: Any]: return "Map"
        default: return "?"
        }
    }

    /// `nodeTypeProperties`' rows for a label: each property's types on the
    /// nodes that have it (whatever their other labels).
    package static func types(_ rows: [[String: Any]], label: String) -> [String: [String]] {
        var types: [String: [String]] = [:]
        for row in rows {
            guard let labels = row["nodeLabels"] as? [String], labels.contains(label), let property = row["propertyName"] as? String else { continue }
            for type in row["propertyTypes"] as? [String] ?? [] where !(types[property]?.contains(type) ?? false) {
                types[property, default: []].append(type)
            }
        }
        return types
    }

    /// What a cell of the property is written as: one simple type —
    /// String, Long, Double, Boolean, or a list of one — else nil (a date,
    /// a point, several types: not edited, its text isn't its value).
    package static func writable(_ types: [String]?) -> String? {
        guard let types, types.count == 1, let type = types.first else { return nil }
        let short = type.hasSuffix("Value") ? String(type.dropLast(5)) : type
        let simple = ["String", "Long", "Double", "Boolean", "StringArray", "LongArray", "DoubleArray", "BooleanArray", "Integer", "Float"]
        return simple.contains(short) ? short : nil
    }

    /// A Cypher string literal: `'it\'s'`, backslashes doubled.
    package static func string(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// A property name: bare when it can be, else in backticks.
    package static func property(_ name: String) -> String { CypherText.name(name) }

    /// A cell's text as a literal of its property's type.
    package static func literal(_ text: String, type: String, property name: String) throws -> String {
        func refuse(_ what: String) -> EditRefusal { .said("“\(text)” isn't \(what) — \(name) holds \(what)s.") }
        switch type {
        case "String": return string(text)
        case "Long", "Integer":
            guard let value = Int64(text.trimmingCharacters(in: .whitespaces)) else { throw refuse("an integer") }
            return String(value)
        case "Double", "Float":
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { throw refuse("a number") }
            return String(value)
        case "Boolean":
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return "true"
            case "false": return "false"
            default: throw refuse("true or false")
            }
        default:
            // A list: its text as JSON, each element of the list's type.
            guard type.hasSuffix("Array"), let data = text.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw EditRefusal.said("“\(text)” isn't a list like [1, 2] — \(name) holds lists.")
            }
            let element = String(type.dropLast(5))
            let items = try list.map { item -> String in
                guard let item = HTTPDriverTransport.text(item) else { throw EditRefusal.said("A list in Neo4j holds no NULL.") }
                return try literal(item, type: element, property: name)
            }
            return "[" + items.joined(separator: ", ") + "]"
        }
    }

    /// A Save's statements: deletes, updates, creates, each counting its node.
    package static func statements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult, types: [String: [String]], use: String?) throws
        -> [EditStatement]
    {
        let prefix = use.map { ":use \($0)\n" } ?? ""
        let label = CypherText.name(result.key.table.name)
        let keyAt = result.keyIndexes.first ?? 0
        func node(_ row: Int) throws -> String {
            guard rows.indices.contains(row), let id = rows[row][safe: keyAt] ?? nil else { throw EditRefusal.truncatedKey }
            return "MATCH (n) WHERE elementId(n) = \(string(id))"
        }
        func value(_ column: Int, _ text: String) throws -> String {
            let name = result.columns[column]
            guard result.isEditable(column), let type = writable(types[name]) else { throw EditRefusal.unknownColumn(name) }
            return try literal(text, type: type, property: name)
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            statements.append(
                EditStatement(
                    sql: prefix + "\(try node(row)) DETACH DELETE n RETURN count(n)",
                    note: "DETACH DELETE deletes a node's relationships with it."))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            var sets: [String] = []
            var removes: [String] = []
            for column in cells.keys.sorted() {
                let target = "n." + property(result.columns[column])
                switch cells[column] ?? .null {
                case .null, .absent:  // a property is null by being absent
                    guard result.isEditable(column) else { throw EditRefusal.unknownColumn(result.columns[column]) }
                    removes.append(target)
                case .text(let text): sets.append(target + " = " + (try value(column, text)))
                }
            }
            var sql = try node(row)
            if !sets.isEmpty { sql += " SET " + sets.joined(separator: ", ") }
            if !removes.isEmpty { sql += " REMOVE " + removes.joined(separator: ", ") }
            statements.append(EditStatement(sql: prefix + sql + " RETURN count(n)"))
        }
        for values in edits.inserted {
            var properties: [String] = []
            for column in values.keys.sorted() where result.isEditable(column) {
                guard case .text(let text) = values[column] ?? .null else { continue }
                properties.append(property(result.columns[column]) + ": " + (try value(column, text)))
            }
            let map = properties.isEmpty ? "" : " {" + properties.joined(separator: ", ") + "}"
            statements.append(EditStatement(sql: prefix + "CREATE (n:\(label)\(map)) RETURN count(n)"))
        }
        return statements
    }
}

// MARK: Users and roles

/// Neo4j's user statements, on `system`: CREATE USER … SET ENCRYPTED
/// PASSWORD (its SHA-256 form, so the password is never in the clear on
/// the wire or in the query log), ALTER USER, DROP USER; Enterprise's
/// roles — CREATE ROLE, GRANT ROLE, privileges granted to a role — and
/// REVOKE of a privilege as the server words it. Pure.
package struct Neo4jUserStatements: UserStatementMaking {
    package var enterprise: Bool

    package static let databasePrivileges = [
        "ACCESS", "START", "STOP", "INDEX MANAGEMENT", "CONSTRAINT MANAGEMENT", "NAME MANAGEMENT", "TRANSACTION MANAGEMENT", "ALL DATABASE PRIVILEGES",
    ]
    package static let graphPrivileges = ["TRAVERSE", "READ {*}", "MATCH {*}", "WRITE", "ALL GRAPH PRIVILEGES"]

    package var form: UserForm {
        UserForm(
            login: enterprise, superuser: enterprise ? "Admin (the admin role)" : nil,
            passwordNote: "The password goes as its salted SHA-256 (SET ENCRYPTED PASSWORD), never in the clear, and is never kept here.",
            grantKinds: enterprise
                ? [
                    GrantKind(title: "Database", fields: [GrantField(title: "Database (* for all)", fill: .database)]),
                    GrantKind(title: "Graph", fields: [GrantField(title: "Graph (* for all)", fill: .database)]),
                ] : [],
            grantsNote: enterprise ? "A user's privileges are its roles': grant to a role, and the role to the user." : nil,
            noGrants: enterprise ? "No roles, no privileges." : "Community has no roles or privileges.")
    }

    /// Neo4j's stored form of a password (version 1): SHA-256 over the salt
    /// then the password, hashed again until 1024 times — `1,<hash>,<salt>`.
    package static func encrypted(_ password: String, salt: Data? = nil) -> String {
        let salt = salt ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        var hash = Data(SHA256.hash(data: salt + Data(password.utf8)))
        for _ in 1..<1024 { hash = Data(SHA256.hash(data: hash)) }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        return "1,\(hex(hash)),\(hex(salt))"
    }

    private static let mask = "'••••••••'"

    package func create(_ user: NewUser) throws -> [UserStatement] {
        let name = CypherText.name(try checked(user.name))
        if enterprise, !user.login {
            return [UserStatement("CREATE ROLE \(name)")]
        }
        guard !user.password.isEmpty else { throw Self.refusal("A password, please.") }
        let head = "CREATE USER \(name) SET ENCRYPTED PASSWORD "
        let tail = " CHANGE NOT REQUIRED"
        var statements = [UserStatement(head + Neo4jEdits.string(Self.encrypted(user.password)) + tail, shown: head + Self.mask + tail)]
        if enterprise, user.superuser { statements.append(UserStatement("GRANT ROLE admin TO \(name)")) }
        return statements
    }

    package func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        let name = CypherText.name(try checked(user.name))
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        let head = "ALTER USER \(name) SET ENCRYPTED PASSWORD "
        let tail = " CHANGE NOT REQUIRED"
        return UserStatement(head + Neo4jEdits.string(Self.encrypted(password)) + tail, shown: head + Self.mask + tail)
    }

    package func offers(_ action: UserAction, on user: DatabaseUser) -> Bool {
        switch action {
        case .password: !user.isRole
        case .grant: enterprise && user.isRole
        case .grantRole: enterprise && !user.isRole
        case .drop: true
        }
    }

    package func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        .named(kind: kind.title == "Graph" ? "GRAPH" : "DATABASE", name: fields.first?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    package func privileges(on target: GrantTarget) -> [String] {
        if case .named("GRAPH", _) = target { return Self.graphPrivileges }
        return Self.databasePrivileges
    }

    /// One GRANT a privilege, on `*` or a named database or graph.
    package func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        guard case .named(let kind, let rawName) = target else { throw Self.refusal("Neo4j grants on a database or a graph.") }
        guard !privileges.isEmpty else { throw Self.refusal("Pick a privilege.") }
        let allowed = self.privileges(on: target)
        for privilege in privileges where !allowed.contains(privilege) { throw Self.refusal("\(privilege) isn't a privilege on a \(kind.lowercased()).") }
        let name = try checked(rawName, "A \(kind.lowercased())")
        let on = name == "*" ? "\(kind) *" : "\(kind) \(CypherText.name(name))"
        let role = CypherText.name(try checked(user.name))
        return UserStatement(privileges.map { "GRANT \($0) ON \(on) TO \(role)" }.joined(separator: ";\n"))
    }

    package func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard let name = try? checked(user.name) else { return nil }
        if grant.kind == "role" {
            return UserStatement("REVOKE ROLE \(CypherText.name(grant.object)) FROM \(CypherText.name(name))")
        }
        // The server's own words, `GRANT … TO role` → `REVOKE GRANT … FROM role`.
        guard case .named("command", let command)? = grant.target, user.isRole else { return nil }
        let suffix = " TO " + CypherText.name(name)
        guard command.hasPrefix("GRANT ") || command.hasPrefix("DENY "), command.hasSuffix(suffix) else { return nil }
        return UserStatement("REVOKE " + command.dropLast(suffix.count) + " FROM " + CypherText.name(name))
    }

    package func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] {
        users.filter { $0.isRole && $0.name != "PUBLIC" && !user.memberOf.contains($0.name) }
    }

    package func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement {
        UserStatement("GRANT ROLE \(CypherText.name(try checked(role.name, "A role"))) TO \(CypherText.name(try checked(user.name)))")
    }

    package func drop(_ user: DatabaseUser) throws -> UserStatement {
        UserStatement("DROP \(user.isRole ? "ROLE" : "USER") \(CypherText.name(try checked(user.name)))")
    }
}
