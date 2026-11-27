import Foundation

/// A DuckDB file's page — no sessions or users: its size, blocks, WAL and
/// memory — and its rows edited by the table's primary key, else a unique
/// key over NOT NULL columns. Never by `rowid`: DuckDB may give a row
/// another one once deleted rows are compacted. docs/architecture.md, DuckDB.
extension DuckDBDriver: DatabaseMonitoring, DatabaseTableEditing {
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview] }

    package func editDialect() async -> SQLDialect { .duckdb }

    private func first(_ sql: String) async -> ResultRow? {
        (try? await execute(sql, limit: 1)).flatMap { ResultRow.rows(of: $0).first }
    }

    package func overview() async throws -> ServerOverview {
        let memory = Self.inMemory(connection.filePath)
        let size = await first("SELECT * FROM pragma_database_size() WHERE database_name = current_database()")
        let counts = await first(
            "SELECT (SELECT count(*) FROM duckdb_tables() WHERE database_name = current_database()) AS tables, (SELECT count(*) FROM duckdb_views() WHERE database_name = current_database() AND NOT internal) AS views"
        )
        let settings = await first("SELECT current_setting('threads') AS threads, current_setting('access_mode') AS mode")
        var facts = [ServerFact(title: "DuckDB", value: Self.version, detail: "its own release's library")]
        if memory {
            facts.append(ServerFact(title: "File", value: "In memory", detail: "nothing is kept when it closes"))
        } else {
            let path = (connection.filePath as NSString).expandingTildeInPath
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            facts.append(
                ServerFact(
                    title: "File", value: (attributes?[.size] as? Int64).map(OpsText.bytes) ?? "—",
                    detail: (attributes?[.modificationDate] as? Date).map { "changed \(Self.date.string(from: $0))" }))
        }
        if let size {
            let used = size["used_blocks"] ?? "—"
            let total = size["total_blocks"] ?? "—"
            facts.append(ServerFact(title: "Database", value: size["database_size"] ?? "—", detail: "\(used) of \(total) blocks used"))
            facts.append(ServerFact(title: "WAL", value: size["wal_size"] ?? "—", detail: "written into the file at a checkpoint"))
            facts.append(ServerFact(title: "Memory", value: size["memory_usage"] ?? "—", detail: size["memory_limit"].map { "of \($0) allowed" }))
        }
        facts.append(
            ServerFact(title: "Tables", value: counts?["tables"] ?? "—", detail: counts?["views"].map { "\($0) view\($0 == "1" ? "" : "s")" }))
        facts.append(ServerFact(title: "Threads", value: settings?["threads"] ?? "—"))
        var notes: [String] = []
        if connection.readOnly, !memory { notes.append("Opened read-only.") }
        return ServerOverview(facts: facts, notes: notes)
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: Editing rows

    package func key(of table: TableName) async throws -> TableKey? {
        let dialect = SQLDialect.duckdb
        // DuckDB's names are matched without case, as an unquoted name is.
        let inSchema = table.schema.map { "lower(table_schema) = lower(\(dialect.literal($0)))" } ?? "table_schema = current_schema()"
        let found = ResultRow.rows(
            of: try await execute(
                "SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_catalog = current_database() AND \(inSchema) AND lower(table_name) = lower(\(dialect.literal(table.name)))",
                limit: 2))
        guard found.count == 1, let row = found.first, row["table_type"] == "BASE TABLE", let schema = row["table_schema"], let name = row["table_name"]
        else { return nil }
        let columns = try await execute(
            "SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_catalog = current_database() AND table_schema = \(dialect.literal(schema)) AND table_name = \(dialect.literal(name)) ORDER BY ordinal_position",
            limit: 10_000)
        // A key's columns, a row each, in the key's order.
        let constraints = try await execute(
            "SELECT constraint_index, constraint_type, constraint_name, unnest(constraint_column_names) AS column_name, generate_subscripts(constraint_column_names, 1) AS position FROM duckdb_constraints() WHERE database_name = current_database() AND schema_name = \(dialect.literal(schema)) AND table_name = \(dialect.literal(name)) AND constraint_type IN ('PRIMARY KEY', 'UNIQUE') ORDER BY constraint_index, position",
            limit: 10_000)
        return DuckDBOps.key(TableName(schema: schema, name: name), columns: columns, constraints: constraints)
    }

    package func apply(_ statements: [EditStatement]) async throws {
        guard !connection.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        try transaction(statements)
    }
}

/// DuckDB's answers read, and the text Overterm gives it. Pure.
package enum DuckDBOps {
    /// A SELECT's columns, as preparing it says them.
    package struct Shape: Equatable, Sendable {
        package var columns: [String] = []
        package var types: [String] = []
    }

    /// One SELECT with every value cast to text, at most `limit` rows made:
    /// its own text inside a subquery, a `;` at its end left out and a
    /// comment on its last line kept off the closing parenthesis.
    package static func asText(_ statement: String, limit: Int) -> String {
        var body = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body = String(body.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return "SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (\n\(body)\n) LIMIT \(max(limit, 0))"
    }

    /// DuckDB's message — which names the program holding the file — and,
    /// when it is the file's lock, what to do about it.
    package static func explainOpen(_ message: String) -> String {
        let text = trimmed(message)
        if text.localizedCaseInsensitiveContains("different configuration") {
            return text + "\n\nThe file is open in Overterm already, read-only in one connection and writable in the other. Close that one, then connect again."
        }
        guard text.contains("Could not set lock") || text.contains("Conflicting lock") else { return text }
        return text + "\n\nDuckDB lets one program at a time open a file that can be written. Close it there, then connect again."
    }

    package static func trimmed(_ message: String) -> String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A type's name by its `duckdb_type` number (duckdb.h); "" for one
    /// this list doesn't know.
    package static func typeName(_ id: Int) -> String {
        let names: [Int: String] = [
            1: "BOOLEAN", 2: "TINYINT", 3: "SMALLINT", 4: "INTEGER", 5: "BIGINT", 6: "UTINYINT", 7: "USMALLINT", 8: "UINTEGER", 9: "UBIGINT",
            10: "FLOAT", 11: "DOUBLE", 12: "TIMESTAMP", 13: "DATE", 14: "TIME", 15: "INTERVAL", 16: "HUGEINT", 17: "VARCHAR", 18: "BLOB",
            19: "DECIMAL", 20: "TIMESTAMP_S", 21: "TIMESTAMP_MS", 22: "TIMESTAMP_NS", 23: "ENUM", 24: "LIST", 25: "STRUCT", 26: "MAP",
            27: "UUID", 28: "UNION", 29: "BIT", 30: "TIME WITH TIME ZONE", 31: "TIMESTAMP WITH TIME ZONE", 32: "UHUGEINT", 33: "ARRAY",
            35: "BIGNUM", 36: "NULL", 39: "TIME_NS", 40: "GEOMETRY", 41: "VARIANT", 42: "TIMESTAMP_NS WITH TIME ZONE",
        ]
        return names[id] ?? ""
    }

    /// A column whose text isn't written back: a LIST, an ARRAY, a STRUCT,
    /// a MAP or a UNION reads as `duckdb` prints it, not as a value to set.
    package static func isNested(_ type: String) -> Bool {
        let upper = type.uppercased()
        return upper.hasSuffix("]") || ["STRUCT", "MAP", "UNION", "LIST", "VARIANT"].contains { upper.hasPrefix($0) }
    }

    /// From the table's columns (column_name, data_type, is_nullable) and
    /// its keys' columns a row each (constraint_index, constraint_type,
    /// constraint_name, column_name, position): the primary key, else the
    /// first unique key whose columns can't be NULL; nil without either.
    package static func key(_ table: TableName, columns: QueryResult, constraints: QueryResult) -> TableKey? {
        var notNull: Set<String> = []
        var readOnly: Set<String> = []
        for column in ResultRow.rows(of: columns) {
            guard let name = column["column_name"] else { continue }
            if column["is_nullable"] == "NO" { notNull.insert(name) }
            if isNested(column["data_type"] ?? "") { readOnly.insert(name) }
        }
        var keys: [(index: Int, type: String, name: String, columns: [String])] = []
        for row in ResultRow.rows(of: constraints) {
            guard let index = row.int("constraint_index"), let column = row["column_name"] else { continue }
            if let last = keys.indices.last, keys[last].index == index {
                keys[last].columns.append(column)
            } else {
                keys.append((index, row["constraint_type"] ?? "", row["constraint_name"] ?? "", [column]))
            }
        }
        if let primary = keys.first(where: { $0.type == "PRIMARY KEY" }) {
            return TableKey(table: table, kind: .primary, columns: primary.columns, readOnlyColumns: readOnly)
        }
        for unique in keys where unique.type == "UNIQUE" && unique.columns.allSatisfy(notNull.contains) {
            return TableKey(table: table, kind: .unique(unique.name), columns: unique.columns, readOnlyColumns: readOnly)
        }
        return nil
    }
}
