import Foundation

// DynamoDB's Server page — its tables, as DescribeTable says them — and a
// SELECT's items edited. It has no sessions, no slow-query record and no
// users of its own (IAM's), so no Activity, Slow Queries, Locks or Users.
// docs/architecture.md, Database: Server page, Editing rows.

extension DynamoDBDriver: DatabaseMonitoring {
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .sizes] }

    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? { [] }

    /// How many tables are read for Sizes: three calls each.
    static let describedTables = 100

    func overview() async throws -> ServerOverview {
        let tables = try await names()
        let limits = try? await call("DescribeLimits", [:])
        let host = config.serverName ?? config.host
        return DynamoOps.overview(region: region, endpoint: host, onAWS: DynamoItems.isAWS(host), tables: tables.count, limits: limits)
    }

    func sizes() async throws -> Monitored<DatabaseSizes> {
        let tables = try await names()
        var sizes = DatabaseSizes()
        for table in tables.prefix(Self.describedTables) {
            guard let description = try? await describe(table) else { continue }
            let ttl = try? await call("DescribeTimeToLive", ["TableName": table])
            let backups = try? await call("DescribeContinuousBackups", ["TableName": table])
            let (entry, indexes) = DynamoOps.table(description, ttl: ttl, backups: backups)
            sizes.tables.append(entry)
            sizes.indexes += indexes
        }
        sizes.tables.sort { $0.bytes > $1.bytes }
        sizes.indexes.sort { $0.bytes > $1.bytes }
        if tables.count > Self.describedTables { sizes.notes.append("The first \(Self.describedTables) of \(tables.count) tables.") }
        sizes.notes.append(
            "DynamoDB updates a table's size and item count about every six hours. Consumed capacity and throttling are CloudWatch's metrics, not DynamoDB's API — not read here."
        )
        return .value(sizes)
    }
}

// MARK: Editing items

extension DynamoDBDriver: DatabaseTableEditing {
    func editDialect() async -> SQLDialect { .postgres }

    /// Not SQL: a SELECT's items are found by `editableResult`.
    func key(of table: TableName) async throws -> TableKey? { nil }

    func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>? {
        guard DynamoText.verb(of: statement) == "SELECT", let table = DynamoText.subject(of: statement) else {
            return .failure(.said("Items are edited in a SELECT from one table."))
        }
        if DynamoEdits.readsIndex(statement) {
            return .failure(.said("These items were read from an index, which may not hold every attribute: SELECT from the table to edit them."))
        }
        let description = try await describe(table)
        return DynamoEdits.editable(table: table, description: description, result: result)
    }

    func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try DynamoEdits.statements(edits, rows: rows, result: result)
    }

    func editSaveNote() async -> String {
        "In one transaction (ExecuteTransaction): if any statement fails — an item changed or gone since it was read, a new item's key taken — none is kept. An item already deleted elsewhere is simply gone."
    }

    func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("a write") }
        guard statements.count <= DynamoEdits.transactionLimit else {
            throw DatabaseError.failed("DynamoDB's transaction takes \(DynamoEdits.transactionLimit) statements at most — save fewer changes at a time.")
        }
        do {
            _ = try await call("ExecuteTransaction", ["TransactStatements": statements.map { ["Statement": $0.sql] }])
        } catch let error as DatabaseError {
            let said = error.localizedDescription
            guard said.contains("ConditionalCheckFailed") || said.contains("DuplicateItem") || said.contains("Transaction cancelled") else { throw error }
            throw DatabaseError.failed("\(said) — an item changed or is gone since it was read, or a new item's key is taken: nothing was kept.")
        }
    }
}

/// DynamoDB's descriptions read for the Server page. Pure.
enum DynamoOps {
    static func overview(region: String, endpoint: String, onAWS: Bool, tables: Int, limits: [String: Any]?) -> ServerOverview {
        var facts = [
            ServerFact(title: "Region", value: region, detail: onAWS ? "AWS" : "DynamoDB Local or another endpoint"),
            ServerFact(title: "Tables", value: "\(tables)", detail: endpoint),
        ]
        if let limits {
            func number(_ key: String) -> Int? { (limits[key] as? NSNumber)?.intValue }
            if let read = number("AccountMaxReadCapacityUnits"), let write = number("AccountMaxWriteCapacityUnits") {
                facts.append(ServerFact(title: "Account capacity", value: "\(read) / \(write)", detail: "read / write units, provisioned tables together"))
            }
            if let read = number("TableMaxReadCapacityUnits"), let write = number("TableMaxWriteCapacityUnits") {
                facts.append(ServerFact(title: "A table's capacity", value: "\(read) / \(write)", detail: "read / write units at most"))
            }
        }
        return ServerOverview(
            facts: facts,
            notes: [
                "DynamoDB has no sessions, no record of slow requests and no users of its own (IAM's) — Sizes lists each table: items, size, billing, capacity, indexes, TTL and point-in-time recovery."
            ])
    }

    /// A table as Sizes lists it, and its indexes.
    static func table(_ description: [String: Any], ttl: [String: Any]?, backups: [String: Any]?) -> (SizeEntry, [SizeEntry]) {
        func number(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
        func capacity(_ value: Any?) -> String? {
            guard let throughput = value as? [String: Any], let read = throughput["ReadCapacityUnits"] as? NSNumber,
                let write = throughput["WriteCapacityUnits"] as? NSNumber, read.intValue + write.intValue > 0
            else { return nil }
            return "\(read)/\(write) RCU/WCU"
        }
        let name = description["TableName"] as? String ?? "?"
        let items = number(description["ItemCount"])
        let billing = (description["BillingModeSummary"] as? [String: Any])?["BillingMode"] as? String ?? "PROVISIONED"
        var detail = ["\(items) item\(items == 1 ? "" : "s")", billing == "PAY_PER_REQUEST" ? "on-demand" : capacity(description["ProvisionedThroughput"]) ?? "provisioned"]
        if let status = description["TableStatus"] as? String, status != "ACTIVE" { detail.append(status.lowercased()) }
        let global = description["GlobalSecondaryIndexes"] as? [[String: Any]] ?? []
        let local = description["LocalSecondaryIndexes"] as? [[String: Any]] ?? []
        if !global.isEmpty { detail.append("\(global.count) GSI\(global.count == 1 ? "" : "s")") }
        if !local.isEmpty { detail.append("\(local.count) LSI\(local.count == 1 ? "" : "s")") }
        if let ttl = ttl?["TimeToLiveDescription"] as? [String: Any] {
            let status = ttl["TimeToLiveStatus"] as? String ?? "DISABLED"
            detail.append(status == "ENABLED" ? "TTL on \(ttl["AttributeName"] as? String ?? "?")" : "TTL \(status.lowercased())")
        }
        if let pitr = ((backups?["ContinuousBackupsDescription"] as? [String: Any])?["PointInTimeRecoveryDescription"] as? [String: Any])?[
            "PointInTimeRecoveryStatus"] as? String
        {
            detail.append("PITR \(pitr == "ENABLED" ? "on" : "off")")
        }
        let entry = SizeEntry(name: name, bytes: number(description["TableSizeBytes"]), detail: detail.joined(separator: " · "))
        var indexes: [SizeEntry] = []
        for (list, label) in [(global, "GSI"), (local, "LSI")] {
            for index in list {
                let count = number(index["ItemCount"])
                let keys = (index["KeySchema"] as? [[String: Any]] ?? []).compactMap { $0["AttributeName"] as? String }.joined(separator: ", ")
                var said = ["\(label) on \(keys)", "\(count) item\(count == 1 ? "" : "s")"]
                if let capacity = capacity(index["ProvisionedThroughput"]) { said.append(capacity) }
                if let status = index["IndexStatus"] as? String, status != "ACTIVE" { said.append(status.lowercased()) }
                indexes.append(SizeEntry(name: index["IndexName"] as? String ?? "?", schema: name, bytes: number(index["IndexSizeBytes"]), detail: said.joined(separator: " · ")))
            }
        }
        return (entry, indexes)
    }
}

/// A SELECT's items as rows edited, in PartiQL — the console's language —
/// run together by ExecuteTransaction: each found by its partition (and
/// sort) key, which the statement's WHERE must match or the whole Save
/// fails. An UPDATE sets attributes (`SET`) and removes them (`REMOVE`),
/// on the condition that each edited value is still what was read; an
/// INSERT fails where the key is taken; a DELETE of an item already gone
/// is a no-op (PartiQL checks no condition of a missing item).
/// A value is typed by its attribute's type: S as text, N a number, BOOL,
/// NULL, a map or list (and a set) as JSON. Pure.
enum DynamoEdits {
    static let transactionLimit = 100

    /// `FROM "orders"."byStatus"` — an index, not the table.
    static func readsIndex(_ statement: String) -> Bool {
        statement.range(of: #"(?i)\bFROM\s+(?:"(?:[^"]|"")+"|[A-Za-z0-9_\-]+)\s*\.\s*(?:"|[A-Za-z0-9_])"#, options: .regularExpression) != nil
    }

    static func editable(table: String, description: [String: Any], result: QueryResult) -> Result<EditableResult, EditRefusal> {
        let keys = DynamoItems.keyNames(description)
        guard !keys.isEmpty else { return .failure(.noKey(table)) }
        let definitions = Dictionary(
            ((description["AttributeDefinitions"] as? [[String: Any]]) ?? []).compactMap { d -> (String, String)? in
                guard let name = d["AttributeName"] as? String, let type = d["AttributeType"] as? String else { return nil }
                return (name, type)
            }, uniquingKeysWith: { a, _ in a })
        var indexes: [Int] = []
        var missing: [String] = []
        for key in keys {
            if let at = result.columns.firstIndex(of: key) { indexes.append(at) } else { missing.append(key) }
        }
        guard missing.isEmpty else { return .failure(.keyNotShown(missing)) }
        if keys.contains(where: { definitions[$0] == "B" }) { return .failure(.said("\(table)'s key is binary, which PartiQL can't write.")) }
        var types = result.types
        while types.count < result.columns.count { types.append("") }
        for (key, at) in zip(keys, indexes) { types[at] = definitions[key] ?? types[at] }
        // Binary has no PartiQL literal: those cells are read only.
        let binary = Set(result.columns.indices.filter { ["B", "BS"].contains(types[$0]) }.map { result.columns[$0] })
        let said = keys.count == 2 ? "partition key \(keys[0]) and sort key \(keys[1])" : "partition key \(keys[0])"
        let key = TableKey(table: TableName(schema: nil, name: table), kind: .identity(said), columns: keys, readOnlyColumns: binary)
        return .success(EditableResult(key: key, columns: result.columns, keyIndexes: indexes, removesFields: true, types: types))
    }

    static func statements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) throws -> [EditStatement] {
        let table = DynamoText.quote(result.key.table.name)
        let keyColumns = Set(result.keyIndexes)
        func type(_ at: Int) -> String { result.types[safe: at] ?? "" }
        func name(_ at: Int) -> String { DynamoText.quote(result.columns[safe: at] ?? "") }
        func whereKey(_ row: Int) throws -> String {
            try result.keyIndexes.map { at in
                guard let text = rows[safe: row]?[safe: at] ?? nil else { throw EditRefusal.truncatedKey }
                return "\(name(at)) = \(try literal(text, type: type(at)))"
            }.joined(separator: " AND ")
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            // PartiQL checks no condition of an item that isn't there: one
            // already gone is deleted again, a no-op — the end the same.
            statements.append(EditStatement(sql: "DELETE FROM \(table) WHERE \(try whereKey(row))"))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            var clauses: [String] = []
            var unchanged: [String] = []
            for at in cells.keys.sorted() {
                guard !keyColumns.contains(at) else {
                    throw EditRefusal.said("A key can't be changed — duplicate the item with a new key, then delete this one.")
                }
                switch cells[at] ?? .null {
                case .absent: clauses.append("REMOVE \(name(at))")
                case .null: clauses.append("SET \(name(at)) = NULL")
                case .text(let text): clauses.append("SET \(name(at)) = \(try literal(text, type: type(at)))")
                }
                // Still what was read — a scalar compared; a map, list or set isn't.
                if let original = rows[safe: row]?[safe: at] ?? nil, ["S", "N", "BOOL"].contains(type(at)) {
                    unchanged.append("\(name(at)) = \(try literal(original, type: type(at)))")
                }
            }
            let condition = ([try whereKey(row)] + unchanged).joined(separator: " AND ")
            statements.append(EditStatement(sql: "UPDATE \(table) \(clauses.joined(separator: " ")) WHERE \(condition)"))
        }
        for values in edits.inserted {
            var fields: [String] = []
            for at in values.keys.sorted() {
                switch values[at] ?? .absent {
                case .absent: continue
                case .null: fields.append("\(literalString(result.columns[safe: at] ?? "")): NULL")
                case .text(let text): fields.append("\(literalString(result.columns[safe: at] ?? "")): \(try literal(text, type: type(at)))")
                }
            }
            let missing = result.keyIndexes.filter { at in values[at] == nil || values[at] == .absent || values[at] == .null }
            guard missing.isEmpty else {
                throw EditRefusal.said("A new item needs its \(missing.map { result.columns[$0] }.joined(separator: " and ")).")
            }
            statements.append(EditStatement(sql: "INSERT INTO \(table) VALUE {\(fields.joined(separator: ", "))}"))
        }
        guard statements.count <= transactionLimit else {
            throw EditRefusal.said("DynamoDB's transaction takes \(transactionLimit) statements at most — this Save has \(statements.count).")
        }
        return statements
    }

    /// `'it''s'` — PartiQL's string.
    static func literalString(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    private static let numberPattern = #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#

    /// A cell's text as a PartiQL value of its attribute's type.
    static func literal(_ text: String, type: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch type {
        case "S": return literalString(text)
        case "N":
            guard trimmed.range(of: numberPattern, options: .regularExpression) != nil else { throw EditRefusal.said("“\(text)” isn't a number.") }
            return trimmed
        case "BOOL":
            guard trimmed == "true" || trimmed == "false" else { throw EditRefusal.said("“\(text)” isn't true or false.") }
            return trimmed
        case "SS", "NS":
            guard let array = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [Any], !array.isEmpty else {
                throw EditRefusal.said("A set is a JSON array that isn't empty: [\"a\", \"b\"].")
            }
            let items = try array.map { item -> String in
                if type == "SS", let s = item as? String { return literalString(s) }
                if type == "NS", let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
                throw EditRefusal.said("A \(type == "SS" ? "string" : "number") set holds only \(type == "SS" ? "strings" : "numbers").")
            }
            return "<<" + items.joined(separator: ", ") + ">>"
        case "M", "L":
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)), type == "M" ? parsed is [String: Any] : parsed is [Any] else {
                throw EditRefusal.said("“\(text)” isn't a\(type == "M" ? " map" : " list") — write it as JSON.")
            }
            return try partiQL(parsed)
        default:
            // A new attribute, or one of several types: JSON when it reads as JSON, else text.
            if let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]), !(parsed is NSNull) {
                return try partiQL(parsed)
            }
            return literalString(text)
        }
    }

    /// JSON as PartiQL: strings quoted, maps `{'k': v}`, lists `[v]`.
    static func partiQL(_ value: Any) throws -> String {
        switch value {
        case is NSNull: return "NULL"
        case let text as String: return literalString(text)
        case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let array as [Any]: return "[" + (try array.map(partiQL)).joined(separator: ", ") + "]"
        case let object as [String: Any]:
            return "{" + (try object.keys.sorted().map { "\(literalString($0)): \(try partiQL(object[$0]!))" }).joined(separator: ", ") + "}"
        default: throw EditRefusal.said("A value JSON can't say.")
        }
    }
}
