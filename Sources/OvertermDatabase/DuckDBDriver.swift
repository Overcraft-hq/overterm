import CDuckDB
import Foundation

/// A DuckDB file — or a database in memory, nothing kept — through DuckDB's
/// own library (Scripts/fetch-duckdb.sh), read-only when the connection
/// says so, at the file's own level (`access_mode`). docs/architecture.md,
/// DuckDB.
///
/// Values come as text, as every driver gives them: one SELECT runs inside
/// `SELECT CAST(COLUMNS(*) AS VARCHAR) FROM (…) LIMIT n`, so a LIST, a
/// STRUCT or a MAP reads as `duckdb` prints it and no more rows than the
/// limit are made; its columns' names and types are the statement's own,
/// from preparing it. Anything else — or a SELECT that can't be put in a
/// subquery — runs as it is.
package actor DuckDBDriver: DatabaseDriver {
    /// The path that is no file: DuckDB's own word for a database in memory.
    package static let memory = ":memory:"
    package static func inMemory(_ path: String) -> Bool { path == memory }

    package let connection: DatabaseConnection
    // Closed by deinit, and the connection interrupted from a cancelled
    // task, outside the actor.
    nonisolated(unsafe) private var database: duckdb_database?
    nonisolated(unsafe) private var handle: duckdb_connection?

    package init(_ connection: DatabaseConnection) {
        self.connection = connection
    }

    deinit {
        if handle != nil { duckdb_disconnect(&handle) }
        if database != nil { duckdb_close(&database) }
    }

    /// What every DuckDB here opens with: no extension fetched or loaded
    /// by itself — a person's own `INSTALL`/`LOAD` still does — and a file
    /// opened read-only at the engine when the connection is.
    package static func settings(readOnly: Bool) -> [(String, String)] {
        var settings = [
            ("autoinstall_known_extensions", "false"),
            ("autoload_known_extensions", "false"),
            ("allow_community_extensions", "false"),
        ]
        if readOnly { settings.append(("access_mode", "READ_ONLY")) }
        return settings
    }

    package func connect() async throws {
        guard handle == nil else { return }
        let memory = Self.inMemory(connection.filePath)
        let path = memory ? Self.memory : (connection.filePath as NSString).expandingTildeInPath
        if !memory, connection.readOnly, !FileManager.default.fileExists(atPath: path) {
            throw DatabaseError.failed("No file at \(path).")
        }
        var config: duckdb_config?
        guard duckdb_create_config(&config) == DuckDBSuccess else { throw DatabaseError.failed("DuckDB couldn't start.") }
        defer { duckdb_destroy_config(&config) }
        // A database in memory has nothing to open read-only: DuckDB refuses it.
        for (key, value) in Self.settings(readOnly: connection.readOnly && !memory) {
            guard duckdb_set_config(config, key, value) == DuckDBSuccess else {
                throw DatabaseError.failed("DuckDB refused its setting \(key) = \(value).")
            }
        }
        var opened: duckdb_database?
        var error: UnsafeMutablePointer<CChar>?
        // A file through the app's one instance cache: DuckDB's lock is
        // fcntl's, the process's — a second open of the file here would not
        // be refused, and closing it would drop the first one's lock. The
        // cache hands every connection to a file the same database, and
        // refuses one with other settings (read-only beside writable).
        let state =
            memory
            ? duckdb_open_ext(path, &opened, config, &error)
            : duckdb_get_or_create_from_cache(Self.instances.cache, Self.canonical(path), &opened, config, &error)
        guard state == DuckDBSuccess, opened != nil else {
            let message = error.map { String(cString: $0) } ?? "DuckDB couldn't open \(path)."
            if let error { duckdb_free(error) }
            if opened != nil { duckdb_close(&opened) }
            throw DatabaseError.failed(DuckDBOps.explainOpen(message))
        }
        var connected: duckdb_connection?
        guard duckdb_connect(opened, &connected) == DuckDBSuccess, connected != nil else {
            duckdb_close(&opened)
            throw DatabaseError.failed("DuckDB opened \(path) but gave no connection to it.")
        }
        database = opened
        handle = connected
    }

    package func close() async {
        if handle != nil { duckdb_disconnect(&handle) }
        if database != nil { duckdb_close(&database) }
        handle = nil
        database = nil
    }

    /// The app's databases by file: one instance each, however many
    /// connections and Test buttons open it.
    private static let instances = Instances()
    private final class Instances: @unchecked Sendable {
        let cache = duckdb_create_instance_cache()
    }

    /// A file's path as the cache keys it: links resolved, so two spellings
    /// of one file are one database.
    package static func canonical(_ path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return path }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The library's version: v2.0.1.
    package static var version: String { String(cString: duckdb_library_version()) }

    package func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let handle else { throw DatabaseError.notConnected }
        let started = Date()
        // A long scan of a Parquet file stops when its run is cancelled.
        let stop = Interrupt(handle: handle)
        var result = try await withTaskCancellationHandler {
            try self.run(sql, limit: limit)
        } onCancel: {
            stop.fire()
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// The connection, to interrupt what it runs from the task that was
    /// cancelled: `duckdb_interrupt` is safe from any thread.
    private struct Interrupt: @unchecked Sendable {
        let handle: duckdb_connection
        func fire() { duckdb_interrupt(handle) }
    }

    private func run(_ sql: String, limit: Int) throws -> QueryResult {
        guard let handle else { throw DatabaseError.notConnected }
        if let shape = shape(of: sql) {
            // A SELECT that can be a subquery runs once, as text; one that
            // can't (DuckDB says so preparing it) runs as it is, below —
            // unless its run was cancelled meanwhile.
            if let wrapped = prepared(DuckDBOps.asText(sql, limit: limit + 1)) {
                var prepared: duckdb_prepared_statement? = wrapped
                defer { duckdb_destroy_prepare(&prepared) }
                var answer = duckdb_result()
                defer { duckdb_destroy_result(&answer) }
                guard duckdb_execute_prepared(prepared, &answer) == DuckDBSuccess else { throw Self.failure(&answer) }
                var result = QueryResult()
                // The wrapper's columns are the statement's, one for one;
                // should they not be, its own names, never a second run.
                if Int(duckdb_column_count(&answer)) == shape.columns.count {
                    result.columns = shape.columns
                    result.types = shape.types
                } else {
                    result.columns = (0..<duckdb_column_count(&answer)).map { duckdb_column_name(&answer, $0).map { String(cString: $0) } ?? "" }
                }
                (result.rows, result.truncated) = Self.rows(&answer, limit: limit)
                return result
            }
            if Task.isCancelled { throw DatabaseError.failed("Interrupted.") }
        }
        var answer = duckdb_result()
        defer { duckdb_destroy_result(&answer) }
        guard duckdb_query(handle, sql, &answer) == DuckDBSuccess else { throw Self.failure(&answer) }
        return Self.result(&answer, limit: limit)
    }

    /// A statement's columns and their types, when it is one SELECT; nil
    /// for anything else, and for what DuckDB can't prepare alone (several
    /// statements, a syntax error — which then says itself when it runs).
    private func shape(of sql: String) -> DuckDBOps.Shape? {
        guard let statement = prepared(sql) else { return nil }
        var prepared: duckdb_prepared_statement? = statement
        defer { duckdb_destroy_prepare(&prepared) }
        guard duckdb_prepared_statement_type(prepared) == DUCKDB_STATEMENT_TYPE_SELECT else { return nil }
        var shape = DuckDBOps.Shape()
        for i in 0..<duckdb_prepared_statement_column_count(prepared) {
            let name = duckdb_prepared_statement_column_name(prepared, i)
            shape.columns.append(name.map { String(cString: $0) } ?? "")
            if let name { duckdb_free(UnsafeMutableRawPointer(mutating: name)) }
            var type = duckdb_prepared_statement_column_logical_type(prepared, i)
            shape.types.append(Self.typeName(type))
            duckdb_destroy_logical_type(&type)
        }
        return shape.columns.isEmpty ? nil : shape
    }

    /// The statement prepared; nil when DuckDB can't.
    private func prepared(_ sql: String) -> duckdb_prepared_statement? {
        var statement: duckdb_prepared_statement?
        guard duckdb_prepare(handle, sql, &statement) == DuckDBSuccess, let statement else {
            duckdb_destroy_prepare(&statement)
            return nil
        }
        return statement
    }

    private static func failure(_ result: inout duckdb_result) -> DatabaseError {
        let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "DuckDB failed."
        return DatabaseError.failed(DuckDBOps.trimmed(message))
    }

    /// The rows of a result, every value as text: at most `limit`, and
    /// whether there were more.
    private static func rows(_ result: inout duckdb_result, limit: Int) -> ([[String?]], Bool) {
        let columns = duckdb_column_count(&result)
        let count = duckdb_row_count(&result)
        var rows: [[String?]] = []
        rows.reserveCapacity(Int(min(count, idx_t(limit))))
        for r in 0..<count {
            if rows.count >= limit { return (rows, true) }
            var row: [String?] = []
            row.reserveCapacity(Int(columns))
            for c in 0..<columns {
                if duckdb_value_is_null(&result, c, r) {
                    row.append(nil)
                    continue
                }
                if let text = duckdb_value_varchar(&result, c, r) {
                    row.append(String(cString: text))
                    duckdb_free(text)
                } else {
                    // Only a statement run as it is gets here with a value
                    // the C API won't say as text (a LIST, a STRUCT): its type.
                    var type = duckdb_column_logical_type(&result, c)
                    row.append("<\(typeName(type))>")
                    duckdb_destroy_logical_type(&type)
                }
            }
            rows.append(row)
        }
        return (rows, false)
    }

    /// A statement run as it is: its rows, or what it changed. DuckDB
    /// answers a write with one `Count` column, a transaction's statement
    /// or an INSTALL with one `Success` column and no row.
    private static func result(_ answer: inout duckdb_result, limit: Int) -> QueryResult {
        var result = QueryResult()
        let type = duckdb_result_statement_type(answer)
        var names: [String] = []
        for c in 0..<duckdb_column_count(&answer) {
            names.append(duckdb_column_name(&answer, c).map { String(cString: $0) } ?? "")
        }
        if type != DUCKDB_STATEMENT_TYPE_SELECT, names.isEmpty || names == ["Count"] || names == ["Success"] {
            if [DUCKDB_STATEMENT_TYPE_INSERT, DUCKDB_STATEMENT_TYPE_UPDATE, DUCKDB_STATEMENT_TYPE_DELETE, DUCKDB_STATEMENT_TYPE_MERGE_INTO]
                .contains(type)
            {
                result.affected = Int(duckdb_rows_changed(&answer))
            }
            result.message = "Done"
            return result
        }
        result.columns = names
        for c in 0..<duckdb_column_count(&answer) {
            var logical = duckdb_column_logical_type(&answer, c)
            result.types.append(typeName(logical))
            duckdb_destroy_logical_type(&logical)
        }
        (result.rows, result.truncated) = rows(&answer, limit: limit)
        return result
    }

    /// A column's type as DuckDB names it: INTEGER, DECIMAL(4,2), JSON
    /// (an alias), LIST…
    private static func typeName(_ type: duckdb_logical_type?) -> String {
        guard let type else { return "" }
        if let alias = duckdb_logical_type_get_alias(type) {
            defer { duckdb_free(alias) }
            return String(cString: alias)
        }
        let id = duckdb_get_type_id(type)
        if id == DUCKDB_TYPE_DECIMAL { return "DECIMAL(\(duckdb_decimal_width(type)),\(duckdb_decimal_scale(type)))" }
        return DuckDBOps.typeName(Int(id.rawValue))
    }

    // MARK: The catalog

    package func schemas() async throws -> [String] {
        let rows = try await execute(
            "SELECT schema_name FROM duckdb_schemas() WHERE database_name = current_database() AND (NOT internal OR schema_name = 'main') ORDER BY schema_name <> 'main', schema_name",
            limit: 10_000
        ).rows
        return rows.compactMap { $0.first ?? nil }
    }

    package func tables(in schema: String) async throws -> [CatalogTable] {
        let rows = try await execute(
            "SELECT table_name, table_type FROM information_schema.tables WHERE table_catalog = current_database() AND table_schema = \(SQLDialect.duckdb.literal(schema)) ORDER BY table_name",
            limit: 100_000
        ).rows
        return rows.map { CatalogTable(schema: schema, name: $0[0] ?? "", isView: $0[safe: 1] == "VIEW") }
    }

    package func columns(in schema: String) async throws -> [CatalogColumn] {
        let rows = try await execute(
            "SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns WHERE table_catalog = current_database() AND table_schema = \(SQLDialect.duckdb.literal(schema)) ORDER BY table_name, ordinal_position",
            limit: 1_000_000
        ).rows
        return rows.map { CatalogColumn(table: $0[0] ?? "", name: $0[1] ?? "", type: $0[2] ?? "", nullable: $0[3] == "YES") }
    }

    // MARK: Writes, together

    /// Statements in one transaction, each checked to change the rows it
    /// should; any failure rolls back all of them. No await from BEGIN to
    /// COMMIT: nothing else on this actor runs between.
    func transaction(_ statements: [EditStatement]) throws {
        guard let handle else { throw DatabaseError.notConnected }
        func exec(_ sql: String) throws -> Int {
            var answer = duckdb_result()
            defer { duckdb_destroy_result(&answer) }
            guard duckdb_query(handle, sql, &answer) == DuckDBSuccess else { throw Self.failure(&answer) }
            return Int(duckdb_rows_changed(&answer))
        }
        _ = try exec("BEGIN TRANSACTION")
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
