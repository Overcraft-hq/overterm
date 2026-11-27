import Foundation

/// What a statement gave back: its columns and rows (as text — the client
/// shows them, and every database can say each of its values as text), or
/// what it did.
package struct QueryResult: Equatable, Sendable {
    package var columns: [String] = []
    /// Each column's type as the database names it (int4, VARCHAR, STRING…).
    package var types: [String] = []
    /// nil is NULL.
    package var rows: [[String?]] = []
    /// The database had more rows than were fetched (Settings' row limit).
    package var truncated = false
    /// Rows a statement changed, when the database says.
    package var affected: Int?
    /// What it said besides: "Done", BigQuery's bytes processed…
    package var message: String?
    package var duration: TimeInterval = 0
    /// Prometheus's, Loki's, Tempo's: the series, lines or traces themselves.
    package var payload: ObservabilityPayload?

    package var hasRows: Bool { !columns.isEmpty }
}

package struct CatalogTable: Equatable, Hashable, Sendable {
    package var schema: String
    package var name: String
    package var isView = false
    /// What the tree says beside it: an index's documents, an alias's index.
    package var detail: String?
}

package struct CatalogColumn: Equatable, Hashable, Sendable {
    package var table: String
    package var name: String
    package var type: String
    package var nullable = true
}

package enum DatabaseError: LocalizedError, Equatable {
    case notConnected
    case readOnly(String)
    case failed(String)

    package var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected."
        case .readOnly(let verb): "This connection only reads: \(verb.isEmpty ? "the statement" : verb) was not sent."
        case .failed(let message): message
        }
    }
}

/// One open connection to a database. Each kind has its own (`DatabaseDrivers`);
/// they are actors — a driver holds a socket, and one statement runs at a time.
package protocol DatabaseDriver: Actor {
    func connect() async throws
    func close() async
    /// One statement; at most `limit` rows are kept.
    func execute(_ sql: String, limit: Int) async throws -> QueryResult
    /// Schemas (databases, datasets), the user's first.
    func schemas() async throws -> [String]
    func tables(in schema: String) async throws -> [CatalogTable]
    /// Every column of a schema's tables — for the tree and for completion at once.
    func columns(in schema: String) async throws -> [CatalogColumn]
    /// A statement over a window of time — Prometheus's, Loki's, Tempo's;
    /// the rest ignore it.
    func execute(_ sql: String, limit: Int, range: TimeRange) async throws -> QueryResult
}

extension DatabaseDriver {
    package func execute(_ sql: String, limit: Int, range: TimeRange) async throws -> QueryResult {
        try await execute(sql, limit: limit)
    }
}

package enum DatabaseDrivers {
    /// The driver for a connection, with its secret from the keychain.
    package static func make(_ connection: DatabaseConnection, password: String?, serviceAccount: String?) -> any DatabaseDriver {
        switch connection.kind {
        case .sqlite: SQLiteDriver(connection)
        case .postgres, .redshift: PostgresDriver(connection, password: password)
        // MariaDB speaks MySQL's protocol: the same driver, its words its own.
        case .mysql, .mariadb: MySQLDriver(connection, password: password)
        case .clickhouse: ClickHouseDriver(connection, password: password)
        case .bigquery: BigQueryDriver(connection, serviceAccount: serviceAccount)
        case .redis: RedisDriver(connection, password: password)
        case .prometheus, .loki, .tempo: ObservabilityDriver(connection, password: password)
        // Storage has its own client (StorageClient); nothing runs SQL on it.
        case .s3, .gcs: NoSQLDriver()
        // Each its own driver, written in 1.6.1.
        case .mongodb, .documentdb: MongoDriver(connection, password: password)
        case .elasticsearch, .opensearch: SearchDriver(connection, password: password)
        case .dynamodb: DynamoDBDriver(connection, password: password)
        case .influxdb: InfluxDBDriver(connection, password: password)
        case .neo4j: Neo4jDriver(connection, password: password)
        case .rabbitmq: RabbitMQDriver(connection, password: password)
        case .oracle: OracleDriver(connection, password: password)
        // DuckDB's own library, a file or memory: no secret.
        case .duckdb: DuckDBDriver(connection)
        }
    }

    /// A name inside SQL — `'it''s'` — for the catalog's queries.
    package static func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}

/// A connection that isn't a database (a bucket store): it says so.
package actor NoSQLDriver: DatabaseDriver {
    package func connect() async throws { throw DatabaseError.failed("Storage runs no SQL.") }
    package func close() async {}
    package func execute(_ sql: String, limit: Int) async throws -> QueryResult { throw DatabaseError.failed("Storage runs no SQL.") }
    package func schemas() async throws -> [String] { [] }
    package func tables(in schema: String) async throws -> [CatalogTable] { [] }
    package func columns(in schema: String) async throws -> [CatalogColumn] { [] }
}
