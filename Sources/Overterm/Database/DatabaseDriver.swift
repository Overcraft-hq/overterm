import Foundation

/// What a statement gave back: its columns and rows (as text — the client
/// shows them, and every database can say each of its values as text), or
/// what it did.
struct QueryResult: Equatable, Sendable {
    var columns: [String] = []
    /// Each column's type as the database names it (int4, VARCHAR, STRING…).
    var types: [String] = []
    /// nil is NULL.
    var rows: [[String?]] = []
    /// The database had more rows than were fetched (Settings' row limit).
    var truncated = false
    /// Rows a statement changed, when the database says.
    var affected: Int?
    /// What it said besides: "Done", BigQuery's bytes processed…
    var message: String?
    var duration: TimeInterval = 0

    var hasRows: Bool { !columns.isEmpty }
}

struct CatalogTable: Equatable, Hashable, Sendable {
    var schema: String
    var name: String
    var isView = false
}

struct CatalogColumn: Equatable, Hashable, Sendable {
    var table: String
    var name: String
    var type: String
    var nullable = true
}

enum DatabaseError: LocalizedError, Equatable {
    case notConnected
    case readOnly(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected."
        case .readOnly(let verb): "This connection only reads: \(verb.isEmpty ? "the statement" : verb) was not sent."
        case .failed(let message): message
        }
    }
}

/// One open connection to a database. Each kind has its own (`DatabaseDrivers`);
/// they are actors — a driver holds a socket, and one statement runs at a time.
protocol DatabaseDriver: Actor {
    func connect() async throws
    func close() async
    /// One statement; at most `limit` rows are kept.
    func execute(_ sql: String, limit: Int) async throws -> QueryResult
    /// Schemas (databases, datasets), the user's first.
    func schemas() async throws -> [String]
    func tables(in schema: String) async throws -> [CatalogTable]
    /// Every column of a schema's tables — for the tree and for completion at once.
    func columns(in schema: String) async throws -> [CatalogColumn]
}

enum DatabaseDrivers {
    /// The driver for a connection, with its secret from the keychain.
    static func make(_ connection: DatabaseConnection, password: String?, serviceAccount: String?) -> any DatabaseDriver {
        switch connection.kind {
        case .sqlite: SQLiteDriver(connection)
        case .postgres, .redshift: PostgresDriver(connection, password: password)
        case .mysql: MySQLDriver(connection, password: password)
        case .clickhouse: ClickHouseDriver(connection, password: password)
        case .bigquery: BigQueryDriver(connection, serviceAccount: serviceAccount)
        }
    }

    /// A name inside SQL — `'it''s'` — for the catalog's queries.
    static func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}
