import AppKit

/// The database client's MCP tools, beside the browser's, the API client's
/// and the notes' on the same server (BrowserBridge): an agent lists the
/// saved connections, reads a schema, runs a query, and browses a bucket
/// and reads a file in it. Reads only, unless Settings ▸ Database lets
/// agents write — and then each write is asked about in the window first.
/// No secret is ever in an answer: the tools name connections, never
/// their passwords or keys.
@MainActor
enum DatabaseMCP {
    static func call(_ name: String, _ arguments: [String: Any], model: DatabaseModel) async throws -> [String: Any] {
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
            let statements = SQLText.statements(in: sql).map { (sql as NSString).substring(with: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard statements.count == 1, let statement = statements.first else {
                throw BrowserMCP.ToolError(message: "One statement at a time — this has \(statements.count).")
            }
            if !SQLText.agentReads(statement) {
                guard Settings.shared.databaseAgentWrites else {
                    throw BrowserMCP.ToolError(
                        message: "Agents only read here: \(SQLText.verb(of: statement)) writes. The user can allow writes in Settings ▸ Database.")
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

    // MARK: Asking

    /// A write an agent wants, put to the user in the window. Nothing runs
    /// unless they say so.
    static func allow(_ statement: String, on connection: DatabaseConnection) async -> Bool {
        if let answer = askOverride { return answer(statement) }
        let alert = NSAlert()
        alert.messageText = "An agent wants to run this on “\(connection.name)”"
        alert.informativeText = String(statement.prefix(2000)) + (SQLText.danger(of: statement).map { "\n\n\($0)" } ?? "")
        alert.addButton(withTitle: "Run It")
        alert.addButton(withTitle: "Don't Run")
        alert.alertStyle = .warning
        guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { return alert.runModal() == .alertFirstButtonReturn }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    /// Set by tests and the E2E runner: answers instead of the alert.
    static var askOverride: ((String) -> Bool)?

    // MARK: Answers

    static func describe(_ connections: [DatabaseConnection], storage: Bool) -> String {
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

    static func describeSchema(_ schema: String, session: DatabaseSession) -> String {
        let tables = session.tables[schema] ?? []
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
    static func report(_ result: QueryResult, maxChars: Int = 60_000) -> String {
        guard result.hasRows else {
            return [result.affected.map { "\($0) row\($0 == 1 ? "" : "s") affected." }, result.message].compactMap { $0 }.joined(separator: " ")
                .nonEmpty ?? "Done."
        }
        var text = ResultExport.text(.markdown, columns: result.columns, rows: result.rows)
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n… (cut at \(maxChars) characters)" }
        let more = result.truncated ? " — there are more; add a LIMIT, or raise “limit”" : ""
        return text + "\n\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")\(more)."
    }

    static func describe(_ page: StorageListing, bucket: String, prefix: String) -> String {
        var lines = ["\(bucket)/\(prefix)"]
        lines += page.folders.map { "- \($0)" }
        lines += page.objects.map { "- \($0.key)  \(FilePreview.size($0.size))" }
        if page.folders.isEmpty, page.objects.isEmpty { lines.append("(empty)") }
        if let next = page.next { lines.append("More: storage_list with after = \(next)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        tool("db_connections", "The user's saved database connections (Overterm's Database panel): name, kind, database, read-only.", [:]),
        tool(
            "db_schema",
            "A database's schema: its tables with their columns — or, with “table”, one table's columns. Without “schema”, the connection's default.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "schema": ["type": "string", "description": "The schema (dataset in BigQuery, database in MySQL/ClickHouse)."],
                "table": ["type": "string", "description": "One table's columns."],
            ]),
        tool(
            "db_query",
            "Run one SQL statement on a saved connection and get its rows as a Markdown table. Reads only, unless the user allows agents to write in Settings — then they are asked each time.",
            [
                "connection": ["type": "string", "description": "Its name, from db_connections (optional when there is one)."],
                "sql": ["type": "string", "description": "One statement."],
                "limit": ["type": "integer", "description": "Rows to return (default 100, at most 1000)."],
            ], required: ["sql"]),
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
