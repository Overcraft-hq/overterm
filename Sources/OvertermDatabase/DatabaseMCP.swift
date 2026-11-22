import AppKit

/// The database client's MCP tools, beside the browser's, the API client's
/// and the notes' on the same server (BrowserBridge): an agent lists the
/// saved connections, reads a schema, runs a query, and browses a bucket
/// and reads a file in it. Reads only, unless Settings ▸ Database lets
/// agents write — and then each write is asked about in the window first.
/// No secret is ever in an answer: the tools name connections, never
/// their passwords or keys.
@MainActor
package enum DatabaseMCP {
    package static func call(_ name: String, _ arguments: [String: Any], model: DatabaseModel) async throws -> [String: Any] {
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func connection(storage: Bool) throws -> DatabaseConnection {
            let candidates = model.store.connections.filter { $0.kind.isStorage == storage }
            guard let wanted = string("connection") else {
                if candidates.count == 1 { return candidates[0] }
                throw BrowserMCP.ToolError(message: "\(name) needs “connection” — \(storage ? "storage_connections" : "db_connections") lists them.")
            }
            guard let found = candidates.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame || $0.id.uuidString == wanted })
            else {
                throw BrowserMCP.ToolError(
                    message: "No \(storage ? "storage" : "database") connection “\(wanted)”. There are: "
                        + (candidates.isEmpty ? "none." : candidates.map(\.name).joined(separator: ", ") + "."))
            }
            return found
        }
        switch name {
        case "db_connections":
            return BrowserMCP.textResult(describe(model.store.connections.filter { !$0.kind.isStorage }, storage: false))
        case "db_schema":
            let session = model.session(try connection(storage: false))
            await session.open()
            if case .failed(let message) = session.state { throw BrowserMCP.ToolError(message: message) }
            guard let schema = string("schema") ?? session.schema else { return BrowserMCP.textResult("Schemas: " + session.schemas.joined(separator: ", ")) }
            await session.loadTables(schema)
            if let table = string("table") {
                await session.loadColumns(schema)
                let columns = session.columns(of: table, in: schema)
                guard !columns.isEmpty else { throw BrowserMCP.ToolError(message: "No table “\(table)” in \(schema).") }
                return BrowserMCP.textResult("\(schema).\(table):\n" + columns.map { "- \($0.name) \($0.type)" }.joined(separator: "\n"))
            }
            await session.loadColumns(schema)
            return BrowserMCP.textResult(describeSchema(schema, session: session))
        case "db_query":
            let target = try connection(storage: false)
            guard let sql = string("sql") else { throw BrowserMCP.ToolError(message: "db_query needs “sql”.") }
            let statements = target.kind.statements(in: sql).map { (sql as NSString).substring(with: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard statements.count == 1, let statement = statements.first else {
                throw BrowserMCP.ToolError(message: "One statement at a time — this has \(statements.count).")
            }
            if !target.kind.agentReads(statement) {
                guard Settings.shared.databaseAgentWrites else {
                    throw BrowserMCP.ToolError(
                        message: "Agents only read here: \(target.kind.verb(of: statement)) writes. The user can allow writes in Settings ▸ Database.")
                }
                guard !target.readOnly else { throw BrowserMCP.ToolError(message: "“\(target.name)” is read-only.") }
                guard await allow(statement, on: target) else { throw BrowserMCP.ToolError(message: "The user declined to run it.") }
            }
            let limit = min(max(arguments["limit"] as? Int ?? 100, 1), 1000)
            var answer: Result<QueryResult, Error>?
            await model.session(target).run([statement], limit: limit) { _, result in answer = result }
            switch answer {
            case .success(let result):
                model.record(statement, on: target.id, rows: result.hasRows ? result.rows.count : result.affected, error: nil)
                return BrowserMCP.textResult(report(result))
            case .failure(let error):
                model.record(statement, on: target.id, rows: nil, error: error.localizedDescription)
                return BrowserMCP.errorResult(error.localizedDescription)
            case nil:
                return BrowserMCP.errorResult("Nothing ran.")
            }
        case "db_server", "db_activity", "db_slow_queries", "db_locks":
            let target = try connection(storage: false)
            return BrowserMCP.textResult(try await monitor(name, on: target, model: model, arguments: arguments))
        case "storage_connections":
            return BrowserMCP.textResult(describe(model.store.connections.filter(\.kind.isStorage), storage: true))
        case "storage_list":
            let session = model.storage(try connection(storage: true))
            await session.open()
            if case .failed(let message) = session.state { throw BrowserMCP.ToolError(message: message) }
            guard let bucket = string("bucket") ?? (session.connection.database.isEmpty ? nil : session.connection.database) else {
                return BrowserMCP.textResult("Buckets:\n" + session.buckets.map { "- \($0.name)" }.joined(separator: "\n"))
            }
            var prefix = string("prefix") ?? ""
            if !prefix.isEmpty, !prefix.hasSuffix("/") { prefix += "/" }
            let page = try await session.client.list(bucket: bucket, prefix: prefix, after: string("after"))
            return BrowserMCP.textResult(describe(page, bucket: bucket, prefix: prefix))
        case "storage_read":
            let session = model.storage(try connection(storage: true))
            guard let bucket = string("bucket") ?? (session.connection.database.isEmpty ? nil : session.connection.database),
                let key = string("key")
            else { throw BrowserMCP.ToolError(message: "storage_read needs “bucket” and “key” — storage_list finds them.") }
            let metadata = try await session.client.head(bucket: bucket, key: key)
            let limit = Int64(min(max(arguments["max_bytes"] as? Int ?? 100_000, 100), 2_000_000))
            var out = "\(session.client.path(bucket: bucket, key: key)) — \(FilePreview.size(metadata.size))"
            if let type = metadata.contentType { out += ", \(type)" }
            guard metadata.size > 0 else { return BrowserMCP.textResult(out + "\n(empty)") }
            let range: ClosedRange<Int64>? = metadata.size > limit ? 0...(limit - 1) : nil
            let data = try await session.client.read(bucket: bucket, key: key, range: range)
            guard let text = String(data: data, encoding: .utf8) ?? (range != nil ? String(decoding: data.dropLast(4), as: UTF8.self) : nil),
                !text.contains("\0")
            else { return BrowserMCP.textResult(out + "\nNot text — nothing to show.") }
            return BrowserMCP.textResult(
                out + "\n\n" + text + (range != nil ? "\n… (the first \(FilePreview.size(limit)); max_bytes for more)" : ""))
        default:
            throw BrowserMCP.ToolError(message: "No tool \(name).")
        }
    }

    // MARK: The Server page's reads

    /// The Server page's reads, as text: Markdown tables, statements cut to
    /// a line. Reads only — no tool cancels a session, edits a row or
    /// changes a user — and never a password or its hash (none is read).
    package static func monitor(_ tool: String, on connection: DatabaseConnection, model: DatabaseModel, arguments: [String: Any]) async throws -> String {
        guard connection.kind.features.contains(.monitoring) else {
            let kinds = DatabaseKind.allCases.filter { $0.features.contains(.monitoring) }.map(\.title)
            throw BrowserMCP.ToolError(message: "\(connection.kind.title) has no server page here — \(tool) reads \(kinds.joined(separator: ", ")).")
        }
        let session = model.session(connection)
        await session.open()
        if case .failed(let message) = session.state { throw BrowserMCP.ToolError(message: message) }
        guard let driver = session.monitoring else { throw BrowserMCP.ToolError(message: "Not connected.") }
        let type = DatabaseDrivers.driverType(of: connection.kind) as? any DatabaseMonitoring.Type
        let parts = type?.monitorParts(for: connection.kind) ?? []
        let limit = min(max(arguments["limit"] as? Int ?? 50, 1), 200)
        switch tool {
        case "db_server":
            var out = "\(connection.name) (\(connection.kind.title))\n" + ServerText.overview(try await driver.overview())
            if parts.contains(.sizes), let sizes = try await driver.sizes().value { out += "\n\n" + ServerText.sizes(sizes, limit: limit) }
            return out
        case "db_activity":
            guard parts.contains(.activity) else { return "\(connection.kind.title) has no sessions to list." }
            switch try await driver.activity() {
            case .value(let sessions):
                let idle = arguments["idle"] as? Bool ?? false
                return ServerText.activity(idle ? sessions : sessions.filter { $0.isActive || $0.isOwn }, of: sessions.count, limit: limit)
            case .unavailable(let gap): return ServerText.gap(gap)
            }
        case "db_slow_queries":
            guard parts.contains(.slowQueries) else { return "\(connection.kind.title) keeps no record of slow queries." }
            switch try await driver.slowQueries() {
            case .value(let queries):
                let byMean = (arguments["order"] as? String)?.lowercased() == "mean"
                return ServerText.slowQueries(queries, byMean: byMean, limit: limit)
            case .unavailable(let gap): return ServerText.gap(gap)
            }
        default:
            guard parts.contains(.locks) else { return "\(connection.kind.title) doesn't say who waits on whom." }
            switch try await driver.locks() {
            case .value(let waits): return ServerText.locks(waits)
            case .unavailable(let gap): return ServerText.gap(gap)
            }
        }
    }

    // MARK: Asking

    /// A write an agent wants, put to the user in the window. Nothing runs
    /// unless they say so.
    package static func allow(_ statement: String, on connection: DatabaseConnection) async -> Bool {
        if let answer = askOverride { return answer(statement) }
        // The one confirmation every write is asked with: all of the
        // statement, every character visible, and who asks (MCPAsker) —
        // in the calling pane's window.
        let confirmation = WriteConfirmation(
            title: "An agent wants to run this on “\(connection.name)”",
            detail: VisibleText.displayed(statement) + (connection.kind.danger(of: statement).map { "\n\n\($0)" } ?? ""), button: "Run It",
            cancel: "Don't Run", asker: await MCPAsker.current())
        let window = MCPAsker.window(forPane: MCPAsker.pane) ?? NSApp.windows.first(where: \.isVisible)
        if window != nil { NSApp.activate(ignoringOtherApps: true) }
        return await confirmation.ask(on: window) != nil
    }

    /// Set by tests and the E2E runner: answers instead of the alert.
    package static var askOverride: ((String) -> Bool)?

    // MARK: Answers

    package static func describe(_ connections: [DatabaseConnection], storage: Bool) -> String {
        guard !connections.isEmpty else {
            return storage ? "No storage connections — the user adds them in the Database panel (⌥⌘B)." : "No database connections — the user adds them in the Database panel (⌥⌘B)."
        }
        return connections.map { connection in
            var line = "- \(connection.name): \(connection.kind.title)"
            if !connection.database.isEmpty { line += storage ? ", bucket \(connection.database)" : ", \(connection.database)" }
            if connection.readOnly { line += " (read-only)" }
            return line
        }.joined(separator: "\n")
    }

    package static func describeSchema(_ schema: String, session: DatabaseSession) -> String {
        let tables = session.tables[schema] ?? []
        if session.connection.kind.isObservability {
            let what = session.connection.kind == .prometheus ? "Metrics" : session.connection.kind == .loki ? "Labels" : "Tags"
            guard !tables.isEmpty else { return "No \(what.lowercased()) in the last 6 hours." }
            return "\(what) (\(tables.count)):\n" + tables.prefix(2000).map { "- \($0.name)" }.joined(separator: "\n")
        }
        if session.connection.kind.isSearch {
            guard !tables.isEmpty else { return "No \(schema). Folders: \(session.schemas.joined(separator: ", "))" }
            var out = "\(schema.prefix(1).uppercased() + schema.dropFirst()) (\(tables.count); others: \(session.schemas.filter { $0 != schema }.joined(separator: ", ")))\n"
            for table in tables.prefix(300) {
                let fields = session.columns(of: table.name, in: schema).prefix(100).map { "\($0.name) \($0.type)" }
                out += "\n\(table.name)\(table.detail.map { " [\($0)]" } ?? "")(\(fields.joined(separator: ", ")))"
            }
            if tables.count > 300 { out += "\n… \(tables.count - 300) more; db_schema with “table” for one." }
            return out
        }
        if session.connection.kind == .rabbitmq {
            guard !tables.isEmpty else { return "Vhost \(schema) has no queues or exchanges. Vhosts: \(session.schemas.joined(separator: ", "))" }
            var out = "Vhost \(schema) (others: \(session.schemas.filter { $0 != schema }.joined(separator: ", "))); `PEEK <queue> [n]` reads a queue's messages\n"
            for table in tables.prefix(500) {
                let bindings = session.columns(of: table.name, in: schema).prefix(50).map { "\($0.name) key \($0.type)" }
                out += "\n- \(table.name) [\(table.detail ?? "")]\(bindings.isEmpty ? "" : " " + bindings.joined(separator: ", "))"
            }
            if tables.count > 500 { out += "\n… \(tables.count - 500) more." }
            return out
        }
        if session.connection.kind.isRedis {
            guard !tables.isEmpty else { return "\(schema) has no keys. Databases with keys: \(session.schemas.joined(separator: ", "))" }
            return "Keys in \(schema) (first \(tables.count), by SCAN; `VIEW key` reads one):\n" + tables.map { "- \($0.name)" }.joined(separator: "\n")
        }
        if session.connection.kind.isMongo {
            guard !tables.isEmpty else { return "\(schema) has no collections. Databases: \(session.schemas.joined(separator: ", "))" }
            var out = "Database \(schema) (others: \(session.schemas.filter { $0 != schema }.joined(separator: ", "))) — fields from the first \(MongoDriver.sampleSize) documents of each collection\n"
            for table in tables.prefix(300) {
                let fields = session.columns(of: table.name, in: schema).map { "\($0.name) \($0.type)" }
                out += "\n\(table.isView ? "view" : "collection") \(table.name)(\(fields.joined(separator: ", ")))"
            }
            if tables.count > 300 { out += "\n… \(tables.count - 300) more; db_schema with “table” for one." }
            return out
        }
        guard !tables.isEmpty else { return "\(schema) has no tables. Schemas: \(session.schemas.joined(separator: ", "))" }
        var out = "Schema \(schema) (others: \(session.schemas.filter { $0 != schema }.joined(separator: ", ")))\n"
        for table in tables.prefix(300) {
            let columns = session.columns(of: table.name, in: schema).map { "\($0.name) \($0.type)" }
            out += "\n\(table.isView ? "view" : "table") \(table.name)(\(columns.joined(separator: ", ")))"
        }
        if tables.count > 300 { out += "\n… \(tables.count - 300) more; db_schema with “table” for one." }
        return out
    }

    /// A result as an agent reads it best: a Markdown table, bounded.
    package static func report(_ result: QueryResult, maxChars: Int = 60_000) -> String {
        guard result.hasRows else {
            return [result.affected.map { "\($0) row\($0 == 1 ? "" : "s") affected." }, result.message].compactMap { $0 }.joined(separator: " ")
                .nonEmpty ?? "Done."
        }
        var text = ResultExport.text(.markdown, columns: result.columns, rows: result.rows)
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n… (cut at \(maxChars) characters)" }
        let more = result.truncated ? " — there are more; add a LIMIT, or raise “limit”" : ""
        return text + "\n\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")\(more)."
    }

    package static func describe(_ page: StorageListing, bucket: String, prefix: String) -> String {
        var lines = ["\(bucket)/\(prefix)"]
        lines += page.folders.map { "- \($0)" }
        lines += page.objects.map { "- \($0.key)  \(FilePreview.size($0.size))" }
        if page.folders.isEmpty, page.objects.isEmpty { lines.append("(empty)") }
        if let next = page.next { lines.append("More: storage_list with after = \(next)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Tools

    package static let tools: [[String: Any]] = [
        tool("db_connections", "The user's saved database connections (Overterm's Database panel): name, kind, database, read-only.", [:]),
        tool(
            "db_schema",
            "A database's schema: its tables with their columns — or, with “table”, one table's columns. Without “schema”, the connection's default.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "schema": [
                    "type": "string",
                    "description":
                        "The schema (dataset in BigQuery, database in MySQL/MariaDB/ClickHouse/MongoDB, db0… in Redis — its keys, up to 1000; indices, data streams or aliases in Elasticsearch/OpenSearch, each with its mapping's fields; the region in DynamoDB — tables with their keys and indexes; a database or bucket in InfluxDB — measurements with fields and tags; a database in Neo4j — labels and [:TYPES] with their properties; a vhost in RabbitMQ — queues with their messages and consumers, exchanges, their bindings).",
                ],
                "table": ["type": "string", "description": "One table's columns."],
            ]),
        tool(
            "db_query",
            "Run one SQL statement — or, on a Redis connection, one Redis command as redis-cli takes it (`HGETALL user:1`, `SCAN 0 MATCH user:* COUNT 100`; `VIEW key` reads any key whatever its type), on MongoDB or DocumentDB one mongo shell statement (`db.orders.find({ status: \"open\" }).sort({ at: -1 })`, `db.orders.aggregate([…])`, `db.orders.countDocuments({})`, `db.getSiblingDB(\"other\").c.findOne({})`, `db.runCommand({ … })`, `show collections` — values only, no JavaScript), or on Elasticsearch / OpenSearch one request as Kibana's Dev Tools writes it (`GET /orders/_search` then its JSON body on the lines below; a search's hits come back as rows, `_cat/indices` too; `POST /_sql` and ES|QL `POST /_query` as their columns), or PromQL / LogQL / TraceQL on Prometheus, Loki, Tempo (over the window the user picked in the console, an hour unless changed; a 32-hex trace id reads that trace; `.targets` and `.alerts` on Prometheus), PartiQL on DynamoDB (`SELECT * FROM \"orders\" WHERE pk = 'a'`), InfluxQL, Flux (2.x) or SQL (3.x) on InfluxDB, Cypher on Neo4j (`MATCH (n:Person) RETURN n LIMIT 10`), on RabbitMQ `PEEK <queue> [n]` (messages read and put back — they stay, marked redelivered; asked first), `PUBLISH <exchange> <routing key> <payload>`, `PURGE <queue>`, `USE <vhost>` or any management API path (`GET /api/queues/%2F?columns=name,messages`) — on a saved connection and get its rows as a Markdown table. Reads only, unless the user allows agents to write in Settings — then they are asked each time.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "sql": ["type": "string", "description": "One statement, one Redis command, one mongo shell statement, or one Elasticsearch/OpenSearch request."],
                "limit": ["type": "integer", "description": "Rows to return (default 100, at most 1000)."],
            ], required: ["sql"]),
        tool(
            "db_server",
            "A database server's headline numbers (version, uptime, connections used of max, cache hit rate, replication) and its sizes (databases, the biggest tables and indexes) — PostgreSQL, MySQL, MariaDB; a SQLite file's pages and journal; Redis's INFO; Neo4j's version, nodes and relationships, each label's and type's count; InfluxDB's version, series, memory, each database's (1.x) or bucket's (2.x) disk and retention; RabbitMQ's nodes (memory, disk, file descriptors, alarms), totals and rates, its queues by size; MongoDB's serverStatus and collections; a search cluster's health, heap and indices; DynamoDB's tables (items, size, billing, capacity, indexes, TTL, PITR); Oracle's instance (schemas as its databases, by dba_segments); ClickHouse's (parts on disk, merges, mutations); BigQuery's project — its jobs and its datasets' storage.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "limit": ["type": "integer", "description": "Tables and indexes listed (default 50, at most 200)."],
            ]),
        tool(
            "db_activity",
            "What a database server is running now: each session's id, user, database, client, state, how long, and its statement (cut to a line) — Redis's clients (their last command), Neo4j's transactions, InfluxDB 1's queries, RabbitMQ's connections (their channels, consumers, unacked messages), MongoDB's operations ($currentOp), a search cluster's tasks, Oracle's v$session, ClickHouse's running queries, BigQuery's running and pending jobs. Idle sessions left out unless “idle” is true. Reads only: no tool cancels a session.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "idle": ["type": "boolean", "description": "Idle sessions too."],
                "limit": ["type": "integer", "description": "Sessions listed (default 50, at most 200)."],
            ]),
        tool(
            "db_slow_queries",
            "A database server's own record of its statements, costliest first — PostgreSQL's pg_stat_statements, MySQL's and MariaDB's performance_schema (or MariaDB's slow log table), Redis's SLOWLOG (the same command line together), Neo4j's statements running now by how long (its record is a file on the server), MongoDB's profiler (values left out) or $queryStats, OpenSearch's Query Insights, Oracle's v$sqlstats, ClickHouse's system.query_log (the last 7 days), BigQuery's INFORMATION_SCHEMA.JOBS_BY_PROJECT (the last 7 days; a billed query, with bytes processed and slot time as “cost”): calls, total and mean time, rows. Says what to turn on when the record is off.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "order": ["type": "string", "description": "“total” (default) or “mean” time."],
                "limit": ["type": "integer", "description": "Statements listed (default 50, at most 200)."],
            ]),
        tool(
            "db_locks",
            "Who waits on whom on a database server: the waiting session, the one blocking it, the lock, how long, both statements — PostgreSQL, MySQL, MariaDB, Neo4j (its transactions' “Blocked by”), MongoDB (operations waiting for a lock), Oracle (v$session's blocking_session).",
            ["connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."]]),
        tool("storage_connections", "The user's saved S3 / GCS connections: name, kind, bucket.", [:]),
        tool(
            "storage_list",
            "A bucket's folders and files under a prefix — or, without a bucket, the buckets.",
            [
                "connection": ["type": "string", "description": "Its name, from storage_connections (optional when there is one)."],
                "bucket": ["type": "string", "description": "The bucket."],
                "prefix": ["type": "string", "description": "A folder, like logs/2026/."],
                "after": ["type": "string", "description": "The next page, as a previous answer gave it."],
            ]),
        tool(
            "storage_read",
            "Read a text file from a bucket (CSV, JSON, logs…): its size and type, then its first part.",
            [
                "connection": ["type": "string", "description": "Its name, from storage_connections (optional when there is one)."],
                "bucket": ["type": "string", "description": "The bucket."],
                "key": ["type": "string", "description": "The file's key, from storage_list."],
                "max_bytes": ["type": "integer", "description": "How much of it (default 100000)."],
            ], required: ["key"]),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
        ]
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// The Server page's reads as an agent reads them: Markdown tables
/// (`ResultExport`), every statement on one line and cut. Pure.
package enum ServerText {
    package static let statementLimit = 300

    package static func gap(_ gap: MonitorGap) -> String {
        gap.reason + (gap.fix.map { "\nTo turn it on: \($0)" } ?? "")
    }

    package static func overview(_ overview: ServerOverview) -> String {
        let rows = overview.facts.map { [$0.title, $0.value, $0.detail] as [String?] }
        return ResultExport.text(.markdown, columns: ["", "value", "detail"], rows: rows) + overview.notes.map { "\n\($0)" }.joined()
    }

    package static func sizes(_ sizes: DatabaseSizes, limit: Int) -> String {
        var parts: [String] = []
        for (title, entries) in [("Databases", sizes.databases), ("Biggest tables", sizes.tables), ("Biggest indexes", sizes.indexes)] where !entries.isEmpty {
            let rows = entries.prefix(limit).map { entry -> [String?] in
                [entry.schema.map { "\($0).\(entry.name)" } ?? entry.name, entry.size, entry.detail]
            }
            parts.append("\(title):\n" + ResultExport.text(.markdown, columns: ["name", "size", "detail"], rows: rows))
        }
        parts += sizes.notes
        return parts.joined(separator: "\n\n")
    }

    package static func activity(_ sessions: [DatabaseActivity], of total: Int, limit: Int) -> String {
        guard !sessions.isEmpty else { return "Nothing running: \(total) session\(total == 1 ? "" : "s"), all idle (“idle”: true lists them)." }
        let rows = sessions.prefix(limit).map { session -> [String?] in
            [
                session.id + (session.isOwn ? " (this connection)" : ""), session.user, session.database, session.client, session.state,
                session.seconds.map(OpsText.duration), session.waiting, OpsText.statement(session.statement, limit: statementLimit),
            ]
        }
        let more = sessions.count > limit ? "\n… \(sessions.count - limit) more." : ""
        return ResultExport.text(.markdown, columns: ["session", "user", "database", "client", "state", "for", "waits on", "statement"], rows: rows)
            + "\n\(sessions.count) of \(total) sessions." + more
    }

    package static func slowQueries(_ queries: [SlowQuery], byMean: Bool, limit: Int) -> String {
        guard !queries.isEmpty else { return "No statements recorded yet." }
        let sorted = byMean ? queries.sorted { $0.mean > $1.mean } : queries.sorted { $0.total > $1.total }
        // What else the record says (BigQuery's bytes and slots), when it says it.
        let detail = sorted.contains { $0.detail != nil }
        let rows = sorted.prefix(limit).map { query -> [String?] in
            [
                "\(query.calls)", OpsText.duration(query.total), OpsText.duration(query.mean), query.rows.map(String.init), query.database,
            ] + (detail ? [query.detail] : []) + [OpsText.statement(query.statement, limit: statementLimit)]
        }
        let columns = ["calls", "total", "mean", "rows", "database"] + (detail ? ["cost"] : []) + ["statement"]
        return ResultExport.text(.markdown, columns: columns, rows: rows)
            + "\nBy \(byMean ? "mean" : "total") time; \(min(limit, sorted.count)) of \(sorted.count)."
    }

    package static func locks(_ waits: [LockWait]) -> String {
        guard !waits.isEmpty else { return "Nobody is waiting on a lock." }
        let rows = waits.map { wait -> [String?] in
            [
                wait.waiting + (wait.waitingUser.map { " (\($0))" } ?? ""), wait.blocking + (wait.blockingUser.map { " (\($0))" } ?? ""), wait.lock,
                wait.seconds.map(OpsText.duration), OpsText.statement(wait.waitingStatement, limit: statementLimit),
                OpsText.statement(wait.blockingStatement, limit: statementLimit),
            ]
        }
        return ResultExport.text(.markdown, columns: ["waiting", "blocked by", "lock", "for", "waiting statement", "blocking statement"], rows: rows)
    }
}
