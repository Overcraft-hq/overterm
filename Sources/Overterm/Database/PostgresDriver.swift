import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

/// PostgreSQL — and Redshift, which speaks its protocol — through
/// PostgresNIO. Statements go as simple queries: every value comes back as
/// text, whatever its type, which is what a client that can't know the
/// types in advance wants.
actor PostgresDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let password: String?
    private var connection: PostgresConnection?

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
    }

    /// libpq's modes: prefer and require encrypt without checking whose
    /// certificate it is; verify-full checks it and the host's name.
    static func tls(_ mode: DatabaseSSLMode) throws -> PostgresConnection.Configuration.TLS {
        switch mode {
        case .disable: return .disable
        case .prefer, .require:
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            let context = try NIOSSLContext(configuration: tls)
            return mode == .prefer ? .prefer(context) : .require(context)
        case .verifyFull:
            return .require(try NIOSSLContext(configuration: .makeClientConfiguration()))
        }
    }

    func connect() async throws {
        guard connection == nil else { return }
        var configuration = PostgresConnection.Configuration(
            host: config.host, port: config.port ?? config.kind.defaultPort ?? 5432, username: config.user, password: password,
            database: config.database.isEmpty ? nil : config.database, tls: try Self.tls(config.sslMode))
        // Through a tunnel the host is 127.0.0.1: the certificate is the database's.
        if let name = config.serverName { configuration.options.tlsServerName = name }
        do {
            let opened = try await PostgresConnection.connect(
                on: MultiThreadedEventLoopGroup.singleton.next(), configuration: configuration, id: 1,
                logger: Logger(label: "overterm.database")
            ).get()
            connection = opened
            if config.readOnly {
                _ = try? await opened.simpleQuery("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY").get()
            }
        } catch {
            throw DatabaseError.failed(Self.describe(error))
        }
    }

    func close() async {
        try? await connection?.close()
        connection = nil
    }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        let started = Date()
        let collected = Collected(limit: limit)
        do {
            try await connection.simpleQuery(sql) { row in collected.add(row) }.get()
        } catch {
            throw DatabaseError.failed(Self.describe(error))
        }
        var result = collected.result
        // No rows, no row description to read the columns from: for a read,
        // ask for them by making it a view for a moment.
        if result.rows.isEmpty, SQLText.onlyReads(sql), ["SELECT", "WITH", "VALUES", "TABLE"].contains(SQLText.verb(of: sql)) {
            let (columns, types) = await describe(sql)
            result.columns = columns
            result.types = types
        }
        if !result.hasRows { result.message = "Done" }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// A read's columns, without its rows: a temporary view's attributes.
    private func describe(_ sql: String) async -> ([String], [String]) {
        guard let connection, config.kind == .postgres else { return ([], []) }
        let name = "overterm_describe_\(UInt32.random(in: 0...UInt32.max))"
        let body = sql.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
        guard (try? await connection.simpleQuery("CREATE TEMP VIEW \(name) AS \(body)").get()) != nil else { return ([], []) }
        defer { Task { _ = try? await connection.simpleQuery("DROP VIEW IF EXISTS \(name)").get() } }
        let collected = Collected(limit: 10_000)
        _ = try? await connection.simpleQuery(
            "SELECT attname, format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = '\(name)'::regclass AND attnum > 0 ORDER BY attnum"
        ) { collected.add($0) }.get()
        let rows = collected.result.rows
        return (rows.map { $0[0] ?? "" }, rows.map { $0[1] ?? "" })
    }

    func schemas() async throws -> [String] {
        try await execute(
            """
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name NOT IN ('pg_catalog', 'information_schema') AND schema_name NOT LIKE 'pg\\_%'
            ORDER BY schema_name = 'public' DESC, schema_name
            """, limit: 10_000
        ).rows.compactMap { $0.first ?? nil }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        try await execute(
            """
            SELECT table_name, table_type FROM information_schema.tables
            WHERE table_schema = \(DatabaseDrivers.literal(schema)) ORDER BY table_name
            """, limit: 100_000
        ).rows.map { CatalogTable(schema: schema, name: $0[0] ?? "", isView: $0[1] == "VIEW") }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] {
        try await execute(
            """
            SELECT table_name, column_name, data_type, is_nullable FROM information_schema.columns
            WHERE table_schema = \(DatabaseDrivers.literal(schema)) ORDER BY table_name, ordinal_position
            """, limit: 1_000_000
        ).rows.map { CatalogColumn(table: $0[0] ?? "", name: $0[1] ?? "", type: $0[2] ?? "", nullable: $0[3] == "YES") }
    }

    /// What PostgresNIO threw, as the server said it.
    static func describe(_ error: Error) -> String {
        if let psql = error as? PSQLError {
            if let message = psql.serverInfo?[.message] {
                let detail = psql.serverInfo?[.detail].map { " — \($0)" } ?? ""
                let hint = psql.serverInfo?[.hint].map { " (\($0))" } ?? ""
                return message + detail + hint
            }
            return String(reflecting: psql.code)
                .replacingOccurrences(of: "PSQLError.Code.", with: "")
                + (psql.underlying.map { ": \($0)" } ?? "")
        }
        return String(describing: error)
    }
}

/// Rows as the event loop hands them over, kept to the limit.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var value = QueryResult()

    init(limit: Int) { self.limit = limit }

    var result: QueryResult { lock.withLock { value } }

    func add(_ row: PostgresRow) {
        lock.withLock {
            if value.columns.isEmpty {
                for cell in row {
                    value.columns.append(cell.columnName)
                    value.types.append(cell.dataType.knownSQLName ?? "\(cell.dataType.rawValue)")
                }
            }
            guard value.rows.count < limit else {
                value.truncated = true
                return
            }
            value.rows.append(row.map(PostgresText.text))
        }
    }
}

/// A cell as text. PostgresNIO asks for binary results even for a simple
/// query, so each type is read as what it is and said as psql would.
enum PostgresText {
    static func text(_ cell: PostgresCell) -> String? {
        guard var bytes = cell.bytes else { return nil }
        if cell.format == .text { return String(buffer: bytes) }
        switch cell.dataType {
        case .bool: return (try? cell.decode(Bool.self)).map { $0 ? "t" : "f" }
        case .int2, .int4, .int8, .oid: return (try? cell.decode(Int64.self)).map(String.init)
        case .float4, .float8: return (try? cell.decode(Double.self)).map { String($0) }
        case .numeric: return (try? cell.decode(Decimal.self)).map { "\($0)" }
        case .uuid: return (try? cell.decode(UUID.self)).map { $0.uuidString.lowercased() }
        case .date: return (try? cell.decode(Date.self)).map { format($0, "yyyy-MM-dd") }
        case .timestamp: return (try? cell.decode(Date.self)).map { format($0, "yyyy-MM-dd HH:mm:ss.SSSSSS", trim: true) }
        case .timestamptz: return (try? cell.decode(Date.self)).map { format($0, "yyyy-MM-dd HH:mm:ss.SSSSSS", trim: true) + "+00" }
        case .jsonb:
            // A version byte, then the JSON's text.
            _ = bytes.readInteger(as: UInt8.self)
            return String(buffer: bytes)
        case .bytea: return "\\x" + bytes.readableBytesView.map { String(format: "%02x", $0) }.joined()
        default:
            // An array: `{1,2}`, as psql writes one.
            if let items = try? cell.decode([Int64].self) { return "{" + items.map(String.init).joined(separator: ",") + "}" }
            if let items = try? cell.decode([Double].self) { return "{" + items.map { String($0) }.joined(separator: ",") + "}" }
            if let items = try? cell.decode([Bool].self) { return "{" + items.map { $0 ? "t" : "f" }.joined(separator: ",") + "}" }
            if let items = try? cell.decode([String].self) {
                return "{" + items.map { $0.contains(where: { ",{}\" ".contains($0) }) ? "\"\($0)\"" : $0 }.joined(separator: ",") + "}"
            }
            if let text = try? cell.decode(String.self) { return text }
            if let text = bytes.readString(length: bytes.readableBytes), !text.contains("\0") { return text }
            return "\\x" + (cell.bytes?.readableBytesView.map { String(format: "%02x", $0) }.joined() ?? "")
        }
    }

    private static func format(_ date: Date, _ pattern: String, trim: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        var text = formatter.string(from: date)
        // psql's: no fraction when there is none.
        if trim, text.hasSuffix(".000000") { text.removeLast(7) }
        return text
    }
}
