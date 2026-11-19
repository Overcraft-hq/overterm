import Foundation
import SQLite3

/// A SQLite file's page — no sessions, no users: the file's numbers and
/// `integrity_check` on request — and its rows edited, by primary key, a
/// unique NOT NULL key, else the rowid. docs/architecture.md, Database.
extension SQLiteDriver: DatabaseMonitoring, DatabaseTableEditing {
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview] }

    func editDialect() async -> SQLDialect { .sqlite }

    private func pragma(_ name: String, schema: String = "main") async -> String? {
        (try? await execute("PRAGMA \(SQLDialect.sqlite.identifier(schema)).\(name)", limit: 1))?.rows.first?.first ?? nil
    }

    func overview() async throws -> ServerOverview {
        let path = (connection.filePath as NSString).expandingTildeInPath
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let pages = await pragma("page_count").flatMap { Int64($0) } ?? 0
        let pageSize = await pragma("page_size").flatMap { Int64($0) } ?? 0
        let free = await pragma("freelist_count").flatMap { Int64($0) } ?? 0
        var facts = [
            ServerFact(title: "SQLite", value: String(cString: sqlite3_libversion()), detail: "the system's library"),
            ServerFact(
                title: "File", value: (attributes?[.size] as? Int64).map(OpsText.bytes) ?? "—",
                detail: (attributes?[.modificationDate] as? Date).map { "changed \(Self.date.string(from: $0))" }),
            ServerFact(title: "Pages", value: "\(pages)", detail: "of \(OpsText.bytes(pageSize))"),
            ServerFact(title: "Free pages", value: "\(free)", detail: pages > 0 ? OpsText.percent(Double(free) / Double(pages)) + " — VACUUM gives them back" : nil),
            ServerFact(title: "Journal", value: await pragma("journal_mode") ?? "—", detail: "journal_mode"),
            ServerFact(title: "Encoding", value: await pragma("encoding") ?? "—"),
        ]
        let tables =
            (try? await execute("SELECT count(*) FROM main.sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", limit: 1))?
            .rows.first?.first ?? nil
        facts.append(ServerFact(title: "Tables", value: tables ?? "—", detail: await pragma("user_version").map { "user_version \($0)" }))
        return ServerOverview(facts: facts, notes: connection.readOnly ? ["Opened read-only."] : [])
    }

    func integrityCheck() async throws -> String? {
        let result = try await execute("PRAGMA integrity_check", limit: 100)
        let lines = result.rows.compactMap { $0.first ?? nil }
        return lines == ["ok"] ? "ok — no problems found." : lines.joined(separator: "\n") + (result.truncated ? "\n…" : "")
    }

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: Editing rows

    func key(of table: TableName) async throws -> TableKey? {
        let schema = table.schema ?? "main"
        let dialect = SQLDialect.sqlite
        let kind = try await execute(
            "SELECT type, sql FROM \(dialect.identifier(schema)).sqlite_master WHERE name = \(dialect.literal(table.name)) COLLATE NOCASE", limit: 1)
        guard let row = kind.rows.first, row.first == "table" else { return nil }
        let withoutRowid = (row[safe: 1] ?? nil)?.uppercased().range(of: #"WITHOUT\s+ROWID"#, options: .regularExpression) != nil
        let info = try await execute("PRAGMA \(dialect.identifier(schema)).table_xinfo(\(dialect.literal(table.name)))", limit: 10_000)
        var indexes: [(name: String, columns: [String])] = []
        let list = try await execute("PRAGMA \(dialect.identifier(schema)).index_list(\(dialect.literal(table.name)))", limit: 1000)
        for index in ResultRow.rows(of: list) where index.bool("unique") && !index.bool("partial") && index["origin"] != "pk" {
            guard let name = index["name"] else { continue }
            let columns = try await execute("PRAGMA \(dialect.identifier(schema)).index_info(\(dialect.literal(name)))", limit: 100)
            indexes.append((name, ResultRow.rows(of: columns).map { $0["name"] }.compactMap { $0 }))
        }
        return SQLiteOps.key(TableName(schema: schema, name: table.name), info: info, uniqueIndexes: indexes, withoutRowid: withoutRowid)
    }

    func apply(_ statements: [EditStatement]) async throws {
        guard !connection.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        guard let db else { throw DatabaseError.notConnected }
        // No await from BEGIN to COMMIT: nothing else on this actor runs between.
        func exec(_ sql: String) throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw DatabaseError.failed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW { step = sqlite3_step(statement) }
            guard step == SQLITE_DONE else { throw DatabaseError.failed(String(cString: sqlite3_errmsg(db))) }
            return Int(sqlite3_changes(db))
        }
        _ = try exec("BEGIN")
        do {
            for (index, statement) in statements.enumerated() {
                let changed = try exec(statement.sql)
                guard changed == statement.expectedRows else {
                    throw DatabaseError.failed(EditApplyError.wrongCount(index: index, changed: changed, sql: statement.sql))
                }
            }
            _ = try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            if case DatabaseError.failed(let message) = error, !message.contains("Nothing was saved") {
                throw DatabaseError.failed(message + " — nothing was saved.")
            }
            throw error
        }
    }
}

/// SQLite's answers read. Pure.
enum SQLiteOps {
    /// From `table_xinfo` (cid, name, type, notnull, dflt_value, pk, hidden)
    /// and the unique indexes: the primary key, else a unique key over NOT
    /// NULL columns, else the rowid (a WITHOUT ROWID table always has a key).
    static func key(_ table: TableName, info: QueryResult, uniqueIndexes: [(name: String, columns: [String])], withoutRowid: Bool) -> TableKey? {
        let rows = ResultRow.rows(of: info)
        var readOnly: Set<String> = []
        var notNull: Set<String> = []
        var primary: [(Int, String)] = []
        for row in rows {
            guard let name = row["name"] else { continue }
            // hidden 2 and 3: generated columns; a BLOB is shown as its size, not its bytes.
            if (row.int("hidden") ?? 0) >= 2 || (row["type"] ?? "").uppercased().contains("BLOB") { readOnly.insert(name) }
            if row.bool("notnull") { notNull.insert(name) }
            if let pk = row.int("pk"), pk > 0 { primary.append((pk, name)) }
        }
        if !primary.isEmpty {
            return TableKey(table: table, kind: .primary, columns: primary.sorted { $0.0 < $1.0 }.map(\.1), readOnlyColumns: readOnly)
        }
        for index in uniqueIndexes where !index.columns.isEmpty && index.columns.allSatisfy(notNull.contains) {
            return TableKey(table: table, kind: .unique(index.name), columns: index.columns, readOnlyColumns: readOnly)
        }
        guard !withoutRowid else { return nil }
        return TableKey(table: table, kind: .rowid, columns: ["rowid"], readOnlyColumns: readOnly)
    }
}
