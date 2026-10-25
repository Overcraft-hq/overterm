import Foundation
import SQLite3

/// A SQLite file, through the system's libsqlite3 — read-only when the
/// connection says so, at the file's own level.
actor SQLiteDriver: DatabaseDriver {
    private let connection: DatabaseConnection
    nonisolated(unsafe) private var db: OpaquePointer?

    init(_ connection: DatabaseConnection) {
        self.connection = connection
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    func connect() async throws {
        guard db == nil else { return }
        let path = (connection.filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) || !connection.readOnly else {
            throw DatabaseError.failed("No file at \(path).")
        }
        var handle: OpaquePointer?
        let flags = connection.readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open \(path)."
            if let handle { sqlite3_close_v2(handle) }
            throw DatabaseError.failed(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        db = handle
    }

    func close() async {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let db else { throw DatabaseError.notConnected }
        let started = Date()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.failed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result = QueryResult()
        let count = Int(sqlite3_column_count(statement))
        for i in 0..<count {
            result.columns.append(String(cString: sqlite3_column_name(statement, Int32(i))))
            result.types.append(sqlite3_column_decltype(statement, Int32(i)).map { String(cString: $0) } ?? "")
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw DatabaseError.failed(String(cString: sqlite3_errmsg(db))) }
            if result.rows.count >= limit {
                result.truncated = true
                break
            }
            var row: [String?] = []
            row.reserveCapacity(count)
            for i in 0..<Int32(count) {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_NULL: row.append(nil)
                case SQLITE_BLOB: row.append("<\(sqlite3_column_bytes(statement, i)) bytes>")
                default: row.append(sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "")
                }
            }
            result.rows.append(row)
        }
        if count == 0 {
            result.affected = Int(sqlite3_changes(db))
            result.message = "Done"
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    func schemas() async throws -> [String] {
        let attached = try await execute("PRAGMA database_list", limit: 100)
        return attached.rows.compactMap { $0.count > 1 ? $0[1] : nil }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        let quoted = "\"" + schema.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        let rows = try await execute(
            "SELECT name, type FROM \(quoted).sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
            limit: 100_000
        ).rows
        return rows.map { CatalogTable(schema: schema, name: $0[0] ?? "", isView: $0[1] == "view") }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] {
        var columns: [CatalogColumn] = []
        for table in try await tables(in: schema) {
            let quoted = "\"" + table.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let info = try await execute("PRAGMA \"\(schema)\".table_info(\(quoted))", limit: 10_000)
            // cid, name, type, notnull, dflt_value, pk
            columns += info.rows.map {
                CatalogColumn(table: table.name, name: $0[1] ?? "", type: $0[2] ?? "", nullable: $0[3] == "0")
            }
        }
        return columns
    }
}
