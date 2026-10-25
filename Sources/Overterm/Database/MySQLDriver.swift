import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

/// MySQL (and MariaDB) through MySQLNIO. A read goes as a simple query —
/// its values come back as text, whatever their types; a write as a query,
/// which is what says how many rows it changed.
actor MySQLDriver: DatabaseDriver {
    private let config: DatabaseConnection
    private let password: String?
    private var connection: MySQLConnection?

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
    }

    static func tls(_ mode: DatabaseSSLMode) -> TLSConfiguration? {
        switch mode {
        case .disable: return nil
        case .prefer, .require:
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            return tls
        case .verifyFull: return .makeClientConfiguration()
        }
    }

    func connect() async throws {
        guard connection == nil else { return }
        do {
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port ?? 3306)
            let opened = try await MySQLConnection.connect(
                to: address, username: config.user, database: config.database, password: password,
                tlsConfiguration: Self.tls(config.sslMode), serverHostname: config.host, logger: Logger(label: "overterm.database"),
                on: MultiThreadedEventLoopGroup.singleton.next()
            ).get()
            connection = opened
            if config.readOnly { _ = try? await opened.simpleQuery("SET SESSION TRANSACTION READ ONLY").get() }
        } catch {
            throw DatabaseError.failed(Self.describe(error))
        }
    }

    func close() async {
        try? await connection?.close().get()
        connection = nil
    }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        let started = Date()
        let collected = MySQLCollected(limit: limit)
        do {
            if SQLText.onlyReads(sql) {
                try await connection.simpleQuery(sql, onRow: { collected.add($0) }).get()
            } else {
                do {
                    try await connection.query(sql, [], onRow: { collected.add($0) }, onMetadata: { collected.affected = Int($0.affectedRows) }).get()
                } catch let MySQLError.server(packet) where packet.errorCode.rawValue == 1295 {
                    // "not supported in the prepared statement protocol yet"
                    try await connection.simpleQuery(sql, onRow: { collected.add($0) }).get()
                }
            }
        } catch {
            throw DatabaseError.failed(Self.describe(error))
        }
        var result = collected.result
        if !result.hasRows { result.message = "Done" }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    func schemas() async throws -> [String] {
        let system: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]
        let names = try await execute("SHOW DATABASES", limit: 10_000).rows.compactMap { $0.first ?? nil }
        let user = names.filter { !system.contains($0) }
        // The connection's own database first.
        return user.sorted { ($0 == config.database ? 0 : 1, $0) < ($1 == config.database ? 0 : 1, $1) }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        try await execute(
            "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = \(DatabaseDrivers.literal(schema)) ORDER BY table_name",
            limit: 100_000
        ).rows.map { CatalogTable(schema: schema, name: $0[0] ?? "", isView: $0[1] == "VIEW") }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] {
        try await execute(
            """
            SELECT table_name, column_name, column_type, is_nullable FROM information_schema.columns
            WHERE table_schema = \(DatabaseDrivers.literal(schema)) ORDER BY table_name, ordinal_position
            """, limit: 1_000_000
        ).rows.map { CatalogColumn(table: $0[0] ?? "", name: $0[1] ?? "", type: $0[2] ?? "", nullable: $0[3] == "YES") }
    }

    static func describe(_ error: Error) -> String {
        if case MySQLError.server(let packet) = error { return packet.errorMessage }
        if let error = error as? MySQLError { return error.description }
        return String(describing: error)
    }
}

private final class MySQLCollected: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var value = QueryResult()

    init(limit: Int) { self.limit = limit }

    var result: QueryResult { lock.withLock { value } }

    var affected: Int? {
        get { lock.withLock { value.affected } }
        set { lock.withLock { value.affected = newValue } }
    }

    func add(_ row: MySQLRow) {
        lock.withLock {
            if value.columns.isEmpty {
                value.columns = row.columnDefinitions.map(\.name)
                value.types = row.columnDefinitions.map { "\($0.columnType)" }
            }
            guard value.rows.count < limit else {
                value.truncated = true
                return
            }
            if row.format == .text {
                value.rows.append(row.values.map { $0.map { String(buffer: $0) } })
            } else {
                // A prepared statement's rows are binary: MySQLData reads them.
                value.rows.append(
                    row.columnDefinitions.indices.map { index in
                        let data = MySQLData(
                            type: row.columnDefinitions[index].columnType, format: row.format, buffer: row.values[index],
                            isUnsigned: row.columnDefinitions[index].flags.contains(.COLUMN_UNSIGNED))
                        return row.values[index] == nil ? nil : (data.string ?? data.description)
                    })
            }
        }
    }
}
