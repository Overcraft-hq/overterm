import CryptoKit
import Foundation

/// ClickHouse's Server page, rows edited, users and roles — from its
/// `system` tables, over the driver's HTTP interface (each read a request of
/// its own: HTTP has no session to share). docs/architecture.md, Database:
/// Server page.
///
/// No Locks tab: ClickHouse takes no row locks for anyone to wait on. A query
/// is cancelled (`KILL QUERY`); there is no session to end. Rows are edited
/// as mutations — ALTER TABLE … UPDATE and a lightweight DELETE — only in a
/// plain MergeTree table found by its primary key, which ClickHouse doesn't
/// keep unique: each change counts the key's rows first and runs only when
/// that is one, and they run one at a time, not in a transaction.
extension ClickHouseDriver: DatabaseMonitoring, DatabaseTableEditing, DatabaseUserManagement {
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .slowQueries, .sizes] }

    /// KILL QUERY alone: over HTTP there is no session to end.
    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        guard !session.id.isEmpty else { return [] }
        return [
            SessionStop(
                terminate: false, menu: "Kill Query…", title: "Kill query \(session.id)?", command: ClickHouseOps.kill(session.id),
                effect: SessionStop.said(session) + "\n\nThe query stops; ClickHouse has no transaction to roll back — what an INSERT had written stays.",
                button: "Kill Query")
        ]
    }

    func editDialect() async -> SQLDialect { .clickhouse }
    func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own
    func userStatements() async -> any UserStatementMaking { ClickHouseUserStatements() }

    /// Mutations: ALTER TABLE … UPDATE, a lightweight DELETE, an INSERT —
    /// each UPDATE and DELETE counting its key's rows first.
    func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try ClickHouseOps.editStatements(edits, rows: rows, result: result)
    }

    func editSaveNote() async -> String { ClickHouseOps.mutationNote }

    /// A read of the page's, marked so its own record of statements leaves it out.
    private func read(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        try await execute(ClickHouseOps.marker + sql, limit: limit)
    }

    // MARK: Monitoring

    func overview() async throws -> ServerOverview {
        let result = try await read(ClickHouseOps.overviewSQL, limit: 1)
        let maxConnections = try? await read("SELECT value FROM system.server_settings WHERE name = 'max_connections'", limit: 1)
        let replicas = try? await read("SELECT count() AS replicas, max(absolute_delay) AS delay FROM system.replicas", limit: 1)
        return ClickHouseOps.overview(result, maxConnections: maxConnections, replicas: replicas, readOnly: config.readOnly)
    }

    func activity() async throws -> Monitored<[DatabaseActivity]> {
        do {
            return .value(ClickHouseOps.activity(try await read(ClickHouseOps.activitySQL)))
        } catch  where ClickHouseOps.isPrivilege(error) {
            return .unavailable(MonitorGap(reason: "This user can't read system.processes: \(error.localizedDescription)", fix: "GRANT SHOW PROCESSLIST ON *.* TO <this user>;"))
        }
    }

    /// system.query_log, the last seven days grouped by the normalized query.
    func slowQueries() async throws -> Monitored<[SlowQuery]> {
        do {
            let byTotal = try await read(ClickHouseOps.slowSQL(byMean: false), limit: 100)
            let byMean = try await read(ClickHouseOps.slowSQL(byMean: true), limit: 100)
            return .value(ClickHouseOps.slowQueries([byTotal, byMean]))
        } catch {
            if ClickHouseOps.isMissing(error) { return .unavailable(ClickHouseOps.queryLogMissing) }
            if ClickHouseOps.isPrivilege(error) {
                return .unavailable(
                    MonitorGap(reason: "This user can't read system.query_log: \(error.localizedDescription)", fix: "GRANT SELECT ON system.query_log TO <this user>;"))
            }
            throw error
        }
    }

    func sizes() async throws -> Monitored<DatabaseSizes> {
        var sizes = DatabaseSizes()
        do {
            sizes.databases = PostgresOps.sizes(try await read(ClickHouseOps.databaseSizesSQL, limit: 200))
            sizes.tables = PostgresOps.sizes(try await read(ClickHouseOps.tableSizesSQL, limit: 50))
        } catch  where ClickHouseOps.isPrivilege(error) {
            return .unavailable(MonitorGap(reason: "This user can't read system.parts: \(error.localizedDescription)"))
        }
        do {
            sizes.indexes = PostgresOps.sizes(try await read(ClickHouseOps.skipIndexSizesSQL, limit: 50))
        } catch {
            sizes.notes.append("Data-skipping indexes: \(error.localizedDescription)")
        }
        sizes.notes.append("Active parts on disk, compressed. ClickHouse's indexes are its data-skipping ones; the primary key lives in the parts.")
        return .value(sizes)
    }

    /// `KILL QUERY` — a query is cancelled; HTTP has no session to end.
    func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("KILL QUERY") }
        guard !terminate else { throw DatabaseError.failed("ClickHouse ends no session: a query is cancelled (KILL QUERY).") }
        guard !session.isEmpty else { throw DatabaseError.failed("No query \(session).") }
        let statement = ClickHouseOps.kill(session)
        // The page's own read is the one query it never cancels.
        let killed = try await execute(statement, limit: 10)
        guard killed.hasRows else { throw DatabaseError.failed("\(session) has finished — nothing to cancel.") }
    }

    // MARK: Editing rows

    /// A plain MergeTree table's primary key, its columns plain names. Why
    /// another table's rows aren't edited is thrown, as the edit bar says it.
    func key(of table: TableName) async throws -> TableKey? {
        let dialect = SQLDialect.clickhouse
        let database = table.schema.map(dialect.literal) ?? "currentDatabase()"
        let found = try await read(
            "SELECT database, name, engine, primary_key, sorting_key, partition_key FROM system.tables WHERE database = \(database) AND name = \(dialect.literal(table.name))",
            limit: 1)
        guard let row = ResultRow.rows(of: found).first else { return nil }
        let columns = try await read(
            "SELECT name, type, default_kind, is_in_sorting_key, is_in_partition_key FROM system.columns WHERE database = \(database) AND table = \(dialect.literal(table.name)) ORDER BY position"
        )
        switch ClickHouseOps.key(row, columns: columns) {
        case .success(let key): return key
        case .failure(let refusal): throw DatabaseError.failed(refusal.message)
        }
    }

    /// One at a time, each waited for (`mutations_sync`): an UPDATE or DELETE
    /// only once its key finds exactly one row. ClickHouse has no transaction
    /// to roll back: one that fails stops the rest, and says which ran.
    func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        for (index, statement) in statements.enumerated() {
            if let countSQL = statement.countSQL {
                let found = try await execute(countSQL, limit: 1).rows.first?.first.flatMap { $0.flatMap { Int($0) } } ?? 0
                guard found == statement.expectedRows else {
                    throw DatabaseError.failed(ClickHouseOps.stopped(index: index, found: found, sql: statement.sql))
                }
            }
            do {
                _ = try await send(statement.sql, limit: 1, settings: ["mutations_sync": "1"])
            } catch {
                throw DatabaseError.failed(ClickHouseOps.failed(index: index, error: error.localizedDescription, sql: statement.sql))
            }
        }
    }

    // MARK: Users and roles

    /// system.users and system.roles — never `auth_params`; a user from the
    /// server's users.xml marked: SQL can't change it.
    func users() async throws -> Monitored<[DatabaseUser]> {
        do {
            let users = try await read(ClickHouseOps.usersSQL)
            let roles = try await read("SELECT name, storage FROM system.roles ORDER BY name")
            let memberships = (try? await read("SELECT user_name, role_name, granted_role_name FROM system.role_grants")) ?? QueryResult()
            return .value(ClickHouseOps.users(users, roles: roles, memberships: memberships))
        } catch  where ClickHouseOps.isPrivilege(error) {
            return .unavailable(
                MonitorGap(
                    reason: "This user may not list users and roles: \(error.localizedDescription)",
                    fix: "GRANT SHOW USERS, SHOW ROLES ON *.* TO <this user>; (or ACCESS MANAGEMENT)"))
        }
    }

    func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        let who = SQLDialect.clickhouse.literal(user.name)
        do {
            let result = try await read(
                "SELECT access_type, database, table, column, is_partial_revoke, grant_option FROM system.grants WHERE \(user.isRole ? "role_name" : "user_name") = \(who)"
            )
            let roles = try await read("SELECT granted_role_name, with_admin_option FROM system.role_grants WHERE \(user.isRole ? "role_name" : "user_name") = \(who)")
            return .value(ClickHouseOps.grants(result, roles: roles))
        } catch  where ClickHouseOps.isPrivilege(error) {
            return .unavailable(MonitorGap(reason: "This user may not read grants: \(error.localizedDescription)", fix: "GRANT SHOW USERS ON *.* TO <this user>;"))
        }
    }

    func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        for statement in statements {
            do {
                _ = try await execute(statement.sql, limit: 1)
            } catch {
                throw DatabaseError.failed(statement.scrub(error.localizedDescription))
            }
        }
    }
}

/// ClickHouse's statements for the Server and Users pages, and their answers
/// read. Pure.
enum ClickHouseOps {
    /// What the page's own reads start with: system.query_log keeps it, and
    /// Slow Queries leaves those out.
    static let marker = "/* overterm server page */ "

    /// `KILL QUERY WHERE query_id = '…'` — the id a literal.
    static func kill(_ queryID: String) -> String { "KILL QUERY WHERE query_id = \(SQLDialect.clickhouse.literal(queryID))" }

    static let mutationNote =
        "ClickHouse: each change is a mutation (ALTER TABLE … UPDATE, a lightweight DELETE) that rewrites the parts it touches. Its primary key isn't unique, so each counts the key's rows first and runs only when that is one; they run one at a time, each waited for — not in a transaction: one that fails stops the rest, and those before it stay."

    /// A Save's statements: deletes, updates, inserts, as SQL's are ordered —
    /// an UPDATE as `ALTER TABLE … UPDATE`, never of a sorting or partition
    /// key's column; a DELETE lightweight; each counted by its key first. Pure.
    static func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) throws -> [EditStatement] {
        let dialect = SQLDialect.clickhouse
        let table = dialect.qualified(result.key.table)
        func whereKey(_ row: Int) throws -> String {
            guard rows.indices.contains(row) else { throw EditRefusal.truncatedKey }
            return try zip(result.key.columns, result.keyIndexes).map { column, at in
                guard let value = rows[row][safe: at] ?? nil else { throw EditRefusal.truncatedKey }
                return dialect.identifier(column) + " = " + dialect.literal(value)
            }.joined(separator: " AND ")
        }
        func counted(_ sql: String, _ condition: String) -> EditStatement {
            EditStatement(sql: sql, countSQL: "SELECT count() FROM \(table) WHERE \(condition)")
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            let condition = try whereKey(row)
            statements.append(counted("DELETE FROM \(table) WHERE \(condition)", condition))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            let condition = try whereKey(row)
            let sets = try cells.keys.sorted().map { column -> String in
                let name = result.columns[safe: column] ?? "?"
                guard result.isEditable(column) else { throw EditRefusal.unknownColumn(name) }
                guard result.isUpdatable(column) else {
                    throw EditRefusal.said("“\(name)” is in the table's sorting or partition key: a row's can't be changed — delete the row and add it again.")
                }
                return dialect.identifier(name) + " = " + dialect.value(cells[column] ?? .null)
            }
            statements.append(counted("ALTER TABLE \(table) UPDATE \(sets.joined(separator: ", ")) WHERE \(condition)", condition))
        }
        for values in edits.inserted {
            let columns = values.keys.sorted().filter { result.isEditable($0) }
            guard !columns.isEmpty else { throw EditRefusal.said("A new row needs a value in one column at least.") }
            let names = columns.map { dialect.identifier(result.columns[$0]) }.joined(separator: ", ")
            let literals = columns.map { dialect.value(values[$0] ?? .null) }.joined(separator: ", ")
            statements.append(EditStatement(sql: "INSERT INTO \(table) (\(names)) VALUES (\(literals))"))
        }
        return statements
    }

    static func isPrivilege(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("ACCESS_DENIED") || text.contains("Not enough privileges")
    }

    static func isMissing(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.contains("UNKNOWN_TABLE") || text.contains("does not exist") || text.contains("doesn't exist")
    }

    static let queryLogMissing = MonitorGap(
        reason: "There is no system.query_log — this server keeps no record of its queries (it is written every 7.5 s, so a new server's appears after its first queries).",
        fix: "<query_log> in the server's config.xml (on by default), and the log_queries setting = 1 (on by default)")

    // MARK: Statements

    /// Aggregates only: a scalar subquery over no rows would fail.
    static let overviewSQL = """
        SELECT version() AS version, uptime() AS uptime, hostName() AS host, currentDatabase() AS db,
          (SELECT count() FROM system.processes) AS running,
          (SELECT sum(value) FROM system.metrics WHERE metric IN ('TCPConnection', 'HTTPConnection', 'MySQLConnection', 'PostgreSQLConnection')) AS connections,
          (SELECT sum(value) FROM system.asynchronous_metrics WHERE metric = 'MemoryResident') AS memory,
          (SELECT sum(value) FROM system.asynchronous_metrics WHERE metric = 'OSMemoryTotal') AS memory_total,
          (SELECT sumIf(value, event = 'MarkCacheHits') FROM system.events) AS mark_hits,
          (SELECT sumIf(value, event = 'MarkCacheMisses') FROM system.events) AS mark_misses,
          (SELECT sumIf(value, event = 'Query') FROM system.events) AS queries,
          (SELECT sumIf(value, event = 'FailedQuery') FROM system.events) AS failed,
          (SELECT count() FROM system.merges) AS merges,
          (SELECT countIf(NOT is_done) FROM system.mutations) AS mutations,
          (SELECT sum(rows) FROM system.parts WHERE active) AS total_rows,
          (SELECT sum(bytes_on_disk) FROM system.parts WHERE active) AS total_bytes
        """

    /// Every running query; the page's own read marked.
    static let activitySQL = """
        SELECT query_id AS id, user, current_database AS db, toString(address) AS client, client_name, http_user_agent, elapsed AS seconds,
          query, is_cancelled, read_rows, formatReadableSize(memory_usage) AS memory, query_id = queryID() AS own
        FROM system.processes ORDER BY elapsed DESC
        """

    /// Aliases unlike any column: ClickHouse's aliases are the whole
    /// statement's, so `any(user) AS user` would read itself.
    static func slowSQL(byMean: Bool) -> String {
        """
        SELECT toString(normalized_query_hash) AS hash, any(current_database) AS db, any(user) AS who, count() AS calls,
          sum(query_duration_ms) / 1000 AS total, avg(query_duration_ms) / 1000 AS mean, sum(result_rows) AS result_count,
          formatReadableSize(sum(read_bytes)) AS read_size, any(query) AS text
        FROM system.query_log
        WHERE type = 'QueryFinish' AND event_date >= today() - 7 AND NOT startsWith(query, \(SQLDialect.clickhouse.literal(marker.trimmingCharacters(in: .whitespaces))))
        GROUP BY normalized_query_hash ORDER BY \(byMean ? "mean" : "total") DESC LIMIT 100
        """
    }

    static let databaseSizesSQL = """
        SELECT database AS name, sum(bytes_on_disk) AS size, concat(toString(sum(rows)), ' rows, ', toString(count()), ' parts') AS detail
        FROM system.parts WHERE active GROUP BY database ORDER BY size DESC
        """

    static let tableSizesSQL = """
        SELECT database AS schema, table AS name, sum(bytes_on_disk) AS size,
          concat('rows ', toString(sum(rows)), ', ', toString(count()), ' parts, ', formatReadableSize(sum(data_uncompressed_bytes)), ' raw') AS detail
        FROM system.parts WHERE active GROUP BY database, table ORDER BY size DESC LIMIT 50
        """

    static let skipIndexSizesSQL = """
        SELECT database AS schema, name, data_compressed_bytes AS size, concat('on ', table, ', ', type) AS detail
        FROM system.data_skipping_indices WHERE data_compressed_bytes > 0 ORDER BY size DESC LIMIT 50
        """

    static let usersSQL = """
        SELECT name, storage, toString(auth_type) AS auth, arrayStringConcat(arrayConcat(host_ip, host_names, host_names_like), ', ') AS hosts,
          default_database
        FROM system.users ORDER BY name
        """

    // MARK: Answers

    static func overview(_ result: QueryResult, maxConnections: QueryResult?, replicas: QueryResult?, readOnly: Bool) -> ServerOverview {
        guard let row = ResultRow.rows(of: result).first else { return ServerOverview() }
        var facts: [ServerFact] = []
        facts.append(ServerFact(title: "Version", value: row["version"] ?? "—", detail: row["host"].map { "on \($0)" }))
        facts.append(ServerFact(title: "Uptime", value: row.double("uptime").map(OpsText.duration) ?? "—"))
        let max = maxConnections?.rows.first?.first.flatMap { $0.flatMap { Int($0) } }
        if let used = row.int("connections") {
            facts.append(
                ServerFact(
                    title: "Connections", value: max.map { "\(used) / \($0)" } ?? "\(used)",
                    detail: max.map { OpsText.percent(Double(used) / Double(Swift.max($0, 1))) + " used" } ?? "TCP, HTTP, MySQL and PostgreSQL"))
        }
        facts.append(ServerFact(title: "Running", value: row["running"] ?? "—", detail: "queries now"))
        if let memory = row.int64("memory") {
            facts.append(ServerFact(title: "Memory", value: OpsText.bytes(memory), detail: row.int64("memory_total").map { "of \(OpsText.bytes($0))" }))
        }
        if let hits = row.double("mark_hits"), let misses = row.double("mark_misses"), hits + misses > 0 {
            facts.append(ServerFact(title: "Mark cache hit", value: OpsText.percent(hits / (hits + misses)), detail: "since start"))
        }
        facts.append(ServerFact(title: "Queries", value: row["queries"] ?? "—", detail: row["failed"].map { "\($0) failed, since start" }))
        if let bytes = row.int64("total_bytes") {
            facts.append(ServerFact(title: "Data", value: OpsText.bytes(bytes), detail: row["total_rows"].map { "\($0) rows in active parts" }))
        }
        facts.append(
            ServerFact(title: "Background", value: "\(row["merges"] ?? "0") merges", detail: "\(row["mutations"] ?? "0") mutations not done"))
        if let replica = replicas.flatMap({ ResultRow.rows(of: $0).first }), let count = replica.int("replicas"), count > 0 {
            facts.append(
                ServerFact(title: "Replicated tables", value: "\(count)", detail: replica.double("delay").map { "at most \(OpsText.duration($0)) behind" }))
        }
        return ServerOverview(facts: facts, notes: readOnly ? ["Read-only: ClickHouse's readonly = 1."] : [])
    }

    static func activity(_ result: QueryResult) -> [DatabaseActivity] {
        ResultRow.rows(of: result).map { row in
            let agent = [row["client_name"], row["http_user_agent"]].compactMap { $0 }.first { !$0.isEmpty }
            let doing = [row["memory"].map { "\($0) memory" }, row["read_rows"].map { "\($0) rows read" }].compactMap { $0 }.joined(separator: ", ")
            return DatabaseActivity(
                id: row["id"] ?? "", user: row["user"], database: row["db"].flatMap { $0.isEmpty ? nil : $0 },
                client: row["client"].map { $0.replacingOccurrences(of: "::ffff:", with: "") },
                application: [agent, doing.isEmpty ? nil : doing].compactMap { $0 }.joined(separator: " · "),
                state: row.bool("is_cancelled") ? "cancelling" : "running", statement: row["query"].map { $0.replacingOccurrences(of: marker, with: "") },
                seconds: row.double("seconds"), isOwn: row.bool("own"))
        }
    }

    static func slowQueries(_ results: [QueryResult]) -> [SlowQuery] {
        var seen: Set<String> = []
        var out: [SlowQuery] = []
        for result in results {
            for row in ResultRow.rows(of: result) {
                guard let id = row["hash"], seen.insert(id).inserted else { continue }
                out.append(
                    SlowQuery(
                        id: id, statement: row["text"] ?? "", calls: row.int("calls") ?? 0, total: row.double("total") ?? 0, mean: row.double("mean") ?? 0,
                        rows: row.int("result_count"), database: row["db"].flatMap { $0.isEmpty ? nil : $0 }, user: row["who"],
                        detail: row["read_size"].map { "\($0) read" }))
            }
        }
        return out.sorted { $0.total > $1.total }
    }

    /// Engines whose rows a mutation finds by their key as a person expects:
    /// the plain MergeTree. Replacing, Collapsing, Summing… merge rows on
    /// their own terms.
    static let editableEngines: Set<String> = ["MergeTree", "ReplicatedMergeTree", "SharedMergeTree"]

    /// A key's columns as plain names: `id, ts` → ["id", "ts"]; nil for an
    /// expression (`toDate(ts)`), which no cell holds.
    static func plainColumns(_ expression: String) -> [String]? {
        let parts = expression.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var names: [String] = []
        for part in parts {
            var name = part
            if name.hasPrefix("`"), name.hasSuffix("`"), name.count >= 2 { name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\`", with: "`") }
            guard !name.isEmpty, !name.contains("("), !name.contains(" ") else { return nil }
            names.append(name)
        }
        return names
    }

    /// Types whose grid text isn't a literal ClickHouse reads back as the value.
    static func isUnwritable(_ type: String) -> Bool {
        let bare = type.hasPrefix("LowCardinality(") ? String(type.dropFirst(15).dropLast()) : type
        let inner = bare.hasPrefix("Nullable(") ? String(bare.dropFirst(9).dropLast()) : bare
        return ["Array(", "Map(", "Tuple(", "Nested(", "Object(", "JSON", "AggregateFunction(", "SimpleAggregateFunction(", "Variant(", "Dynamic"]
            .contains { inner.hasPrefix($0) }
    }

    static func key(_ table: ResultRow, columns: QueryResult) -> Result<TableKey, EditRefusal> {
        let name = table["name"] ?? ""
        let engine = table["engine"] ?? ""
        guard editableEngines.contains(engine) else {
            return .failure(
                .said(
                    "\(name) is a \(engine.isEmpty ? "table of no engine" : engine) table: rows are edited only in a plain MergeTree, whose mutations find them by its key."))
        }
        let primary = (table["primary_key"] ?? "").isEmpty ? (table["sorting_key"] ?? "") : (table["primary_key"] ?? "")
        guard !primary.isEmpty else { return .failure(.noKey(name)) }
        guard let keyColumns = plainColumns(primary) else {
            return .failure(.said("\(name)'s primary key is an expression (\(primary)): no column holds it, so a row couldn't be found again."))
        }
        var readOnly: Set<String> = []
        var fixed: Set<String> = []
        var types: [String: String] = [:]
        for row in ResultRow.rows(of: columns) {
            guard let column = row["name"] else { continue }
            let type = row["type"] ?? ""
            types[column] = type
            if ["MATERIALIZED", "ALIAS", "EPHEMERAL"].contains(row["default_kind"] ?? "") || isUnwritable(type) { readOnly.insert(column) }
            if row.bool("is_in_sorting_key") || row.bool("is_in_partition_key") { fixed.insert(column) }
        }
        for column in keyColumns where (types[column] ?? "").hasPrefix("Nullable(") {
            return .failure(.said("\(name)'s key column \(column) may be NULL: a row couldn't be found again."))
        }
        var key = TableKey(
            table: TableName(schema: table["database"], name: name), kind: .primary, columns: keyColumns, readOnlyColumns: readOnly, fixedColumns: fixed)
        key.label = "mutations"
        key.note = mutationNote
        return .success(key)
    }

    static func stopped(index: Int, found: Int, sql: String) -> String {
        "Statement \(index + 1)'s key finds \(found) rows, not 1 — the row has changed or gone since it was read, or the key isn't unique. "
            + (index == 0 ? "Nothing was changed." : "The \(index) before it were applied (ClickHouse has no transaction); none after it ran.") + "\n\(sql)"
    }

    static func failed(index: Int, error: String, sql: String) -> String {
        "Statement \(index + 1) failed: \(error) — "
            + (index == 0 ? "nothing was changed." : "the \(index) before it were applied (ClickHouse has no transaction); none after it ran.") + "\n\(sql)"
    }

    /// What a user from the server's config files says among its
    /// attributes; the page offers no write on it.
    static let configUser = "from users.xml — SQL can't change it, its config file does"
    static let ldapUser = "from LDAP — changed there, not here"

    static func users(_ users: QueryResult, roles: QueryResult, memberships: QueryResult) -> [DatabaseUser] {
        var memberOf: [String: [String]] = [:]
        for row in ResultRow.rows(of: memberships) {
            guard let role = row["granted_role_name"], let member = row["user_name"] ?? row["role_name"] else { continue }
            memberOf[member, default: []].append(role)
        }
        func elsewhere(_ storage: String?) -> String? {
            switch storage {
            case "users_xml"?: configUser
            case "ldap"?: ldapUser
            default: nil
            }
        }
        let people = ResultRow.rows(of: users).map { row -> DatabaseUser in
            let name = row["name"] ?? ""
            var attributes: [String] = []
            if let elsewhere = elsewhere(row["storage"]) { attributes.append(elsewhere) }
            if let auth = row["auth"], !auth.isEmpty { attributes.append(auth) }
            if let hosts = row["hosts"], !hosts.isEmpty, hosts != "::/0" { attributes.append("from \(hosts)") }
            if let database = row["default_database"], !database.isEmpty { attributes.append("default \(database)") }
            return DatabaseUser(name: name, attributes: attributes, memberOf: (memberOf[name] ?? []).sorted())
        }
        let groups = ResultRow.rows(of: roles).map { row -> DatabaseUser in
            let name = row["name"] ?? ""
            return DatabaseUser(
                name: name, isRole: true, canLogin: false, attributes: elsewhere(row["storage"]).map { [$0] } ?? [],
                memberOf: (memberOf[name] ?? []).sorted())
        }
        return people + groups
    }

    /// system.grants by object — `*.*`, `db.*`, `db.table` (a column's,
    /// and a partial revoke, said in the privilege) — and the roles granted.
    static func grants(_ result: QueryResult, roles: QueryResult) -> [DatabaseGrant] {
        var out: [DatabaseGrant] = []
        var at: [String: Int] = [:]
        for row in ResultRow.rows(of: result) {
            guard var privilege = row["access_type"] else { continue }
            let database = row["database"].flatMap { $0.isEmpty ? nil : $0 }
            let table = row["table"].flatMap { $0.isEmpty ? nil : $0 }
            if let column = row["column"], !column.isEmpty { privilege += "(\(column))" }
            if row.bool("is_partial_revoke") { privilege = "revoked " + privilege }
            let kind: String
            let object: String
            let target: GrantTarget
            switch (database, table) {
            case (nil, _):
                (kind, object, target) = ("server", "*.*", .server)
            case (let database?, nil):
                (kind, object, target) = ("database", "\(database).*", .database(database))
            case (let database?, let table?):
                (kind, object, target) = ("table", "\(database).\(table)", .table(TableName(schema: database, name: table)))
            }
            let grantable = row.bool("grant_option")
            if let index = at["\(kind) \(object)"] {
                out[index].privileges.append(privilege)
                out[index].grantable = out[index].grantable || grantable
            } else {
                at["\(kind) \(object)"] = out.count
                out.append(DatabaseGrant(kind: kind, object: object, privileges: [privilege], grantable: grantable, target: target))
            }
        }
        for row in ResultRow.rows(of: roles) {
            guard let role = row["granted_role_name"] else { continue }
            out.append(DatabaseGrant(kind: "role", object: role, privileges: ["MEMBER"], grantable: row.bool("with_admin_option")))
        }
        return out
    }
}

// MARK: Users' statements

/// ClickHouse's user statements (SQL-driven access control): CREATE USER …
/// IDENTIFIED WITH sha256_hash BY the salted hash — the password never on
/// the wire — and VALID UNTIL, or CREATE ROLE for one that doesn't log in;
/// GRANT/REVOKE on `*.*`, a database, a table; roles; DROP USER/ROLE. A user
/// from users.xml or LDAP is offered nothing. Pure.
struct ClickHouseUserStatements: UserStatementMaking {
    static let mask = "'••••••••'"
    private var dialect: SQLDialect { .clickhouse }

    var form: UserForm {
        UserForm(
            login: true, superuser: nil, validUntil: true,
            passwordNote: "The password is sent as its salted SHA-256 hash (sha256_hash) — never in the clear, and never kept here.",
            grantKinds: [
                GrantKind(title: "Server"), GrantKind(title: "Database", fields: [GrantField(title: "Database", fill: .database)]),
                GrantKind(title: "Table", fields: [GrantField(title: "Database", fill: .database), GrantField(title: "Table")]),
            ],
            grantOption: true, grantsNote: "As system.grants says them; “revoked” is a partial revoke.",
            noGrants: "None of its own — it may still have its roles'.", sql: true)
    }

    /// ClickHouse's `sha256_hash`: SHA-256 of the password then the salt, in hex.
    static func hash(_ password: String, salt: String) -> String {
        SHA256.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// ` IDENTIFIED WITH sha256_hash BY '<hash>' SALT '<salt>'`; `salt` the tests'.
    func identified(_ password: String, salt: Data? = nil) throws -> (sql: String, shown: String) {
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        let salt = (salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })).map { String(format: "%02x", $0) }.joined()
        let tail = " SALT " + dialect.literal(salt)
        return (" IDENTIFIED WITH sha256_hash BY " + dialect.literal(Self.hash(password, salt: salt)) + tail, " IDENTIFIED WITH sha256_hash BY " + Self.mask + tail)
    }

    func create(_ user: NewUser) throws -> [UserStatement] { try create(user, salt: nil) }

    func create(_ user: NewUser, salt: Data?) throws -> [UserStatement] {
        let name = dialect.identifier(try checked(user.name.trimmingCharacters(in: .whitespaces)))
        guard user.login else {
            guard user.password.isEmpty else { throw Self.refusal("A role has no password — or tick Logs in.") }
            return [UserStatement("CREATE ROLE \(name)")]
        }
        let identified = try identified(user.password, salt: salt)
        let until = try Self.validUntil(user.validUntil).map { " VALID UNTIL " + dialect.literal($0) } ?? ""
        return [UserStatement("CREATE USER \(name)" + identified.sql + until, shown: "CREATE USER \(name)" + identified.shown + until)]
    }

    func password(of user: DatabaseUser, to password: String) throws -> UserStatement { try self.password(of: user, to: password, salt: nil) }

    func password(of user: DatabaseUser, to password: String, salt: Data?) throws -> UserStatement {
        let head = "ALTER USER " + dialect.identifier(try checked(user.name))
        let identified = try identified(password, salt: salt)
        return UserStatement(head + identified.sql, shown: head + identified.shown)
    }

    /// `yyyy-MM-dd`, checked to be a date; nil when empty.
    static func validUntil(_ text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard formatter.date(from: trimmed) != nil else { throw refusal("Valid until is a date: 2027-01-31.") }
        return trimmed
    }

    /// Not a user the server's config files or LDAP keep.
    static func isSQLs(_ user: DatabaseUser) -> Bool {
        !user.attributes.contains(ClickHouseOps.configUser) && !user.attributes.contains(ClickHouseOps.ldapUser)
    }

    func offers(_ action: UserAction, on user: DatabaseUser) -> Bool {
        guard Self.isSQLs(user) else { return false }
        return action != .password || !user.isRole
    }

    func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        func field(_ at: Int) -> String { fields.indices.contains(at) ? fields[at] : "" }
        switch kind.title {
        case "Server": return .server
        case "Table": return .table(TableName(schema: field(0), name: field(1)))
        default: return .database(field(0))
        }
    }

    func privileges(on target: GrantTarget) -> [String] {
        let tables = ["SELECT", "INSERT", "ALTER", "DROP", "TRUNCATE", "OPTIMIZE", "SHOW"]
        switch target {
        case .server: return ["ALL"] + tables + ["CREATE", "KILL QUERY", "ACCESS MANAGEMENT", "SYSTEM", "dictGet"]
        case .database: return ["ALL"] + tables + ["CREATE", "dictGet"]
        case .table: return ["ALL"] + tables
        default: return []
        }
    }

    /// `*.*`, `` `db`.* ``, `` `db`.`t` ``.
    private func on(_ target: GrantTarget) throws -> String {
        switch target {
        case .server: return "*.*"
        case .database(let name): return dialect.identifier(try checked(name, "A database")) + ".*"
        case .table(let table):
            let name = dialect.identifier(try checked(table.name, "A table"))
            guard let database = table.schema, !database.trimmingCharacters(in: .whitespaces).isEmpty else { return name }
            return dialect.identifier(database) + "." + name
        default: throw Self.refusal("ClickHouse grants on the server, a database or a table.")
        }
    }

    func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        let allowed = self.privileges(on: target)
        guard !privileges.isEmpty else { throw Self.refusal("Pick a privilege.") }
        for privilege in privileges where !allowed.contains(privilege) {
            throw Self.refusal("\(privilege) isn't a privilege on \(target.title.lowercased()).")
        }
        let words = privileges.contains("ALL") ? "ALL" : privileges.joined(separator: ", ")
        return UserStatement(
            "GRANT \(words) ON \(try on(target)) TO \(dialect.identifier(try checked(user.name)))" + (grantOption ? " WITH GRANT OPTION" : ""))
    }

    /// An access type as system.grants names it: words (`ALTER UPDATE`, `dictGet`).
    private static func isWord(_ privilege: String) -> Bool {
        privilege.range(of: #"^[A-Za-z][A-Za-z ]*$"#, options: .regularExpression) != nil
    }

    /// The listed grant back: its privileges on its object (a column's or a
    /// partial revoke's left alone), or a role.
    func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard Self.isSQLs(user), let who = try? checked(user.name) else { return nil }
        if grant.kind == "role" {
            guard let role = try? checked(grant.object) else { return nil }
            return UserStatement("REVOKE \(dialect.identifier(role)) FROM \(dialect.identifier(who))")
        }
        guard let target = grant.target, let on = try? on(target) else { return nil }
        let privileges = grant.privileges.filter { !$0.hasPrefix("revoked ") && Self.isWord($0) }
        guard !privileges.isEmpty else { return nil }
        return UserStatement("REVOKE \(privileges.joined(separator: ", ")) ON \(on) FROM \(dialect.identifier(who))")
    }

    /// Roles only: ClickHouse grants a role, never a user.
    func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] {
        users.filter { $0.isRole && $0.id != user.id && !user.memberOf.contains($0.name) }
    }

    func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement {
        UserStatement("GRANT \(dialect.identifier(try checked(role.name, "A role"))) TO \(dialect.identifier(try checked(user.name)))")
    }

    func drop(_ user: DatabaseUser) throws -> UserStatement {
        UserStatement((user.isRole ? "DROP ROLE " : "DROP USER ") + dialect.identifier(try checked(user.name)))
    }
}
