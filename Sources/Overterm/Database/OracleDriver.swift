import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import OracleNIO

/// Oracle Database through OracleNIO (TNS on SwiftNIO, no Instant Client).
/// The connection's Database field is the service name — a SID when
/// `location` is `sid` (`OracleDriver.sidMarker`). TLS is TCPS from the
/// first byte: Oracle doesn't negotiate, so Prefer is plain.
///
/// Each statement commits on its own (`autoCommit`), as the other kinds'
/// consoles do. A read-only connection runs every statement inside `SET
/// TRANSACTION READ ONLY` and ends it after — the server's own refusal
/// behind the text's (`OracleText.onlyReads`).
actor OracleDriver: DatabaseDriver {
    static let sidMarker = "sid"

    let config: DatabaseConnection
    private let password: String?
    private(set) var connection: OracleConnection?
    private var nextID = 1
    /// This connection's own SID: its session is never cancelled from the
    /// Server page.
    var ownSession: String?
    // One operation at a time: a Save is its statements then COMMIT, and a
    // statement between them — each commits itself — would commit half of it
    // (an actor gives way at every await).
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func exclusive<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { queue.append($0) }
        }
        busy = true
        defer {
            if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
        }
        return try await work()
    }

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
    }

    /// What the Database field names: a service, or a SID — never guessed
    /// when empty (the listener alone knows what it serves).
    var service: OracleServiceMethod {
        let name = config.database.trimmingCharacters(in: .whitespaces)
        return config.location == Self.sidMarker ? .sid(name) : .serviceName(name)
    }

    func connect() async throws {
        guard connection == nil else { return }
        guard !config.database.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DatabaseError.failed("The service name, please — FREEPDB1, XEPDB1, ORCLPDB1, or your database's (Database field).")
        }
        let host = config.host.trimmingCharacters(in: .whitespaces)
        let port = config.port ?? 1521
        var configuration = OracleConnection.Configuration(
            host: host, port: port, service: service, username: config.user, password: password ?? "", tls: try Self.tls(config.sslMode))
        configuration.options.connectTimeout = .seconds(15)
        if config.sslMode == .verifyFull { configuration.options.tlsServerName = config.serverName ?? host }
        configuration.programName = OracleOps.programName
        do {
            // NIOPosix's loop, not Network.framework's (the package's
            // default): that one waits out the timeout on a refused port.
            let opened = try await OracleConnection.connect(
                on: MultiThreadedEventLoopGroup.singleton.next(), configuration: configuration, id: nextID, logger: Logger(label: "overterm.database"))
            nextID += 1
            connection = opened
        } catch {
            throw DatabaseError.failed(Self.describe(error, host: host, port: port, service: config.database, connecting: true))
        }
    }

    static func tls(_ mode: DatabaseSSLMode) throws -> OracleConnection.Configuration.TLS {
        switch mode {
        case .disable, .prefer: return .disable
        case .require:
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            return .require(try NIOSSLContext(configuration: tls))
        case .verifyFull:
            return .require(try NIOSSLContext(configuration: .makeClientConfiguration()))
        }
    }

    func close() async {
        try? await connection?.close()
        connection = nil
    }

    func execute(_ sql: String, limit: Int) async throws -> QueryResult {
        try await exclusive { try await executeAlone(sql, limit: limit) }
    }

    private func executeAlone(_ sql: String, limit: Int) async throws -> QueryResult {
        guard let connection else { throw DatabaseError.notConnected }
        let started = Date()
        if config.readOnly, !OracleText.onlyReads(sql) { throw DatabaseError.readOnly(OracleText.verb(of: sql)) }
        var result: QueryResult
        if let (owner, name) = OracleText.described(sql) {
            result = try await describe(owner: owner, name: name, on: connection)
        } else {
            result = try await run(OracleText.prepared(sql), limit: limit, on: connection)
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private func run(_ sql: String, limit: Int, on connection: OracleConnection) async throws -> QueryResult {
        let block = OracleText.isBlock(sql)
        var options = StatementOptions()
        options.autoCommit = !config.readOnly
        options.fetchLOBs = true
        options.prefetchRows = min(max(limit, 1) + 1, 1000)
        options.arraySize = min(max(limit, 1) + 1, 1000)
        var result = QueryResult()
        var lobs: [(row: Int, column: Int, lob: LOB, kind: String)] = []
        if block { await enableOutput(on: connection) }
        do {
            if config.readOnly { try await connection.execute("SET TRANSACTION READ ONLY") }
            let rows = try await connection.execute(OracleStatement(unsafeSQL: sql), options: options)
            for try await row in rows {
                // Its cells by its iterator: OracleRow's Collection indices
                // are broken in rc.4 (startIndex is endIndex; `map` traps).
                var cells: [OracleCell] = []
                var iterator = row.makeIterator()
                while let cell = iterator.next() { cells.append(cell) }
                if result.columns.isEmpty {
                    result.columns = cells.map(\.columnName)
                    result.types = cells.map { Self.typeName($0.dataType) }
                }
                guard result.rows.count < limit else {
                    result.truncated = true
                    break
                }
                var values: [String?] = []
                for cell in cells {
                    if let lob = Self.lob(cell) {
                        lobs.append((result.rows.count, values.count, lob.lob, lob.kind))
                        values.append(lob.said)
                    } else {
                        values.append(Self.text(cell))
                    }
                }
                result.rows.append(values)
            }
            if result.columns.isEmpty {
                // No rows: the columns are the statement's, if it has any —
                // OracleNIO describes none then, so a read's are asked of
                // DBMS_SQL (which parses a query, never runs it).
                let columns = rows.columns.map(\.name)
                if !columns.isEmpty {
                    result.columns = columns
                    result.types = columns.map { _ in "" }
                } else if OracleText.onlyReads(sql), !OracleText.isBlock(sql), let described = try? await describeColumns(sql, on: connection) {
                    result.columns = described.map(\.name)
                    result.types = described.map(\.type)
                } else {
                    result.affected = block ? nil : try await rows.affectedRows
                }
            }
        } catch {
            if config.readOnly { try? await connection.rollback() }
            throw DatabaseError.failed(Self.describe(error, host: config.host, port: config.port ?? 1521, service: config.database))
        }
        // A CLOB's start, read after the rows (the cursor's done with):
        // the first 50, the rest said by their size.
        for (index, item) in lobs.enumerated() where index < 50 && item.kind != "BLOB" {
            var reader = item.lob.readChunks(ofSize: 200, on: connection).makeAsyncIterator()
            guard let chunk = try? await reader.next() else { continue }
            let text = Self.lobText(Array(chunk.readableBytesView))
            let total = item.lob.estimatedSize
            result.rows[item.row][item.column] = total > text.count ? text + "… (\(item.kind), \(total) characters)" : text
        }
        // A read-only transaction ends after each statement: the next one
        // sees what was committed since.
        if config.readOnly { try? await connection.rollback() }
        if !result.hasRows { result.message = block ? "PL/SQL procedure successfully completed." : "Done" }
        if block, let output = try? await serverOutput(on: connection), !output.isEmpty {
            result.message = (result.message ?? "") + "\n" + output
        }
        return result
    }

    /// DBMS_OUTPUT's lines, after a block: what PUT_LINE said, as
    /// SQL*Plus's SERVEROUTPUT shows it.
    private var outputEnabled = false
    private func serverOutput(on connection: OracleConnection) async throws -> String {
        guard outputEnabled else { return "" }
        let rows = try await connection.execute(
            OracleStatement(
                unsafeSQL: """
                    WITH FUNCTION ot_lines RETURN CLOB IS
                      line VARCHAR2(32767); status INTEGER; lines CLOB;
                    BEGIN
                      LOOP
                        DBMS_OUTPUT.GET_LINE(line, status);
                        EXIT WHEN status <> 0;
                        lines := lines || line || CHR(10);
                      END LOOP;
                      RETURN lines;
                    END;
                    SELECT ot_lines() FROM dual
                    """), options: StatementOptions(fetchLOBs: false))
        var output = ""
        for try await row in rows {
            var iterator = row.makeIterator()
            if let cell = iterator.next() { output = Self.text(cell) ?? "" }
        }
        return output.trimmingCharacters(in: .newlines)
    }

    /// A query's columns without running it: DBMS_SQL parses and
    /// describes. Its text goes as a bind (4,000 bytes at most — a longer
    /// query's empty answer has no columns).
    private func describeColumns(_ sql: String, on connection: OracleConnection) async throws -> [(name: String, type: String)] {
        let statement: OracleStatement = """
            WITH FUNCTION ot_columns(q VARCHAR2) RETURN VARCHAR2 IS
              c INTEGER; n INTEGER; d DBMS_SQL.DESC_TAB3; lines VARCHAR2(32767);
            BEGIN
              c := DBMS_SQL.OPEN_CURSOR;
              DBMS_SQL.PARSE(c, q, DBMS_SQL.NATIVE);
              DBMS_SQL.DESCRIBE_COLUMNS3(c, n, d);
              DBMS_SQL.CLOSE_CURSOR(c);
              FOR i IN 1 .. n LOOP lines := lines || d(i).col_type || ' ' || d(i).col_name || CHR(10); END LOOP;
              RETURN lines;
            END;
            SELECT ot_columns(\(sql)) FROM dual
            """
        let rows = try await connection.execute(statement)
        var text = ""
        for try await row in rows {
            var iterator = row.makeIterator()
            if let cell = iterator.next() { text = Self.text(cell) ?? "" }
        }
        return text.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " "), let code = Int(line[..<space]) else { return nil }
            return (String(line[line.index(after: space)...]), Self.typeName(code: code))
        }
    }

    /// DBMS_SQL's type codes, as Oracle names them.
    static func typeName(code: Int) -> String {
        switch code {
        case 1: "VARCHAR2"
        case 2: "NUMBER"
        case 8: "LONG"
        case 12: "DATE"
        case 23: "RAW"
        case 24: "LONG RAW"
        case 69, 208: "ROWID"
        case 96: "CHAR"
        case 100: "BINARY_FLOAT"
        case 101: "BINARY_DOUBLE"
        case 112: "CLOB"
        case 113: "BLOB"
        case 114: "BFILE"
        case 119: "JSON"
        case 127: "VECTOR"
        case 180: "TIMESTAMP"
        case 181: "TIMESTAMP WITH TIME ZONE"
        case 182: "INTERVAL YEAR TO MONTH"
        case 183: "INTERVAL DAY TO SECOND"
        case 231: "TIMESTAMP WITH LOCAL TIME ZONE"
        case 252: "BOOLEAN"
        default: ""
        }
    }

    /// DBMS_OUTPUT on for this session, before the first block.
    private func enableOutput(on connection: OracleConnection) async {
        guard !outputEnabled else { return }
        _ = try? await connection.execute("BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
        outputEnabled = true
    }

    /// SQL*Plus's DESC: the object's columns from the dictionary.
    private func describe(owner: String?, name: String, on connection: OracleConnection) async throws -> QueryResult {
        let ownerSQL = owner.map(DatabaseDrivers.literal) ?? "SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')"
        let found = try await run(
            """
            SELECT column_name, nullable, data_type, data_length, data_precision, data_scale, char_length, char_used
            FROM all_tab_columns WHERE owner = \(ownerSQL) AND table_name = \(DatabaseDrivers.literal(name)) ORDER BY column_id
            """, limit: 10_000, on: connection)
        guard !found.rows.isEmpty else { throw DatabaseError.failed("ORA-04043: object \(name) does not exist") }
        var result = QueryResult(columns: ["Name", "Null?", "Type"], types: ["", "", ""])
        result.rows = found.rows.map { row in
            [row[0], row[1] == "N" ? "NOT NULL" : nil, Self.columnType(row, from: 2)]
        }
        return result
    }

    static func columnType(_ row: [String?], from i: Int) -> String {
        OracleText.typeName(
            row[i] ?? "", length: row[i + 1].flatMap { Int($0) }, precision: row[i + 2].flatMap { Int($0) },
            scale: row[i + 3].flatMap { Int($0) }, charLength: row[i + 4].flatMap { Int($0) }, charUsed: row[i + 5])
    }

    // MARK: The catalog

    /// The user's own schema first, then every other that isn't Oracle's
    /// own (`oracle_maintained`, 12c+; before it, every one).
    func schemas() async throws -> [String] {
        let me = try await execute("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM dual", limit: 1).rows.first?.first ?? nil
        let names: [String]
        do {
            names = try await execute("SELECT username FROM all_users WHERE oracle_maintained = 'N' ORDER BY username", limit: 100_000).rows
                .compactMap { $0.first ?? nil }
        } catch {
            names = try await execute("SELECT username FROM all_users ORDER BY username", limit: 100_000).rows.compactMap { $0.first ?? nil }
        }
        guard let me else { return names }
        return [me] + names.filter { $0 != me }
    }

    func tables(in schema: String) async throws -> [CatalogTable] {
        let owner = DatabaseDrivers.literal(schema)
        return try await execute(
            """
            SELECT table_name, 'TABLE' FROM all_tables WHERE owner = \(owner) AND nested = 'NO' AND secondary = 'N' AND table_name NOT LIKE 'BIN$%'
            UNION ALL SELECT view_name, 'VIEW' FROM all_views WHERE owner = \(owner)
            ORDER BY 1
            """, limit: 100_000
        ).rows.map { CatalogTable(schema: schema, name: $0[0] ?? "", isView: $0[1] == "VIEW") }
    }

    func columns(in schema: String) async throws -> [CatalogColumn] {
        try await execute(
            """
            SELECT table_name, column_name, nullable, data_type, data_length, data_precision, data_scale, char_length, char_used
            FROM all_tab_columns WHERE owner = \(DatabaseDrivers.literal(schema)) ORDER BY table_name, column_id
            """, limit: 1_000_000
        ).rows.map { CatalogColumn(table: $0[0] ?? "", name: $0[1] ?? "", type: Self.columnType($0, from: 3), nullable: $0[2] != "N") }
    }

    // MARK: Values

    /// A cell as text; nil is NULL.
    static func text(_ cell: OracleCell) -> String? {
        guard let buffer = cell.bytes else { return nil }
        let bytes = Array(buffer.readableBytesView)
        let type = cell.dataType
        switch type {
        case .number, .binaryInteger: return OracleValueText.number(bytes) ?? "?"
        case .date: return OracleValueText.dateTime(bytes, withZone: false)
        case .timestamp, .timestampLTZ: return OracleValueText.dateTime(bytes, withZone: false)
        case .timestampTZ: return OracleValueText.dateTime(bytes, withZone: true)
        case .intervalDS: return OracleValueText.interval(bytes, yearToMonth: false)
        case .intervalYM: return OracleValueText.interval(bytes, yearToMonth: true)
        case .raw, .longRAW: return OracleValueText.hex(bytes)
        case .binaryFloat: return (try? cell.decode(Float.self, context: .default)).map { "\($0)" }
        case .binaryDouble: return (try? cell.decode(Double.self, context: .default)).map { "\($0)" }
        case .boolean: return (try? cell.decode(Bool.self, context: .default)).map { $0 ? "TRUE" : "FALSE" }
        case .cursor: return "(cursor)"
        case .bFile: return "(BFILE)"
        case .json: return "(JSON — JSON_SERIALIZE(… ) shows it)"
        case .vector: return "(VECTOR — FROM_VECTOR(…) shows it)"
        case .object: return "(object — its attributes by name show it)"
        default:
            if let text = try? cell.decode(String.self, context: .default) { return text }
            return "(\(typeName(type)), \(bytes.count) bytes)"
        }
    }

    /// A LOB's locator: what is said for it now — its kind and size — and
    /// the LOB, for a CLOB's start read after the rows.
    private static func lob(_ cell: OracleCell) -> (lob: LOB, kind: String, said: String)? {
        let kind: String
        switch cell.dataType {
        case .clob: kind = "CLOB"
        case .nCLOB: kind = "NCLOB"
        case .blob: kind = "BLOB"
        default: return nil
        }
        guard cell.bytes != nil, let lob = try? cell.decode(LOB.self, context: .default) else { return nil }
        let size = lob.estimatedSize
        let said = kind == "BLOB" ? OracleValueText.lob(kind, text: nil, bytes: size) : "(\(kind), \(size) characters)"
        return (lob, kind, said)
    }

    /// A CLOB's bytes: UTF-16 (big-endian) from a database whose character
    /// set varies in width, as AL32UTF8 does; else the database's — UTF-8.
    static func lobText(_ bytes: [UInt8]) -> String {
        if bytes.count >= 2, bytes.count % 2 == 0, bytes.enumerated().contains(where: { $0.offset % 2 == 0 && $0.element == 0 }) {
            let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A type as Oracle names it.
    static func typeName(_ type: OracleDataType) -> String {
        switch type {
        case .varchar: "VARCHAR2"
        case .nVarchar: "NVARCHAR2"
        case .char: "CHAR"
        case .nChar: "NCHAR"
        case .number, .binaryInteger: "NUMBER"
        case .binaryFloat: "BINARY_FLOAT"
        case .binaryDouble: "BINARY_DOUBLE"
        case .date: "DATE"
        case .timestamp: "TIMESTAMP"
        case .timestampTZ: "TIMESTAMP WITH TIME ZONE"
        case .timestampLTZ: "TIMESTAMP WITH LOCAL TIME ZONE"
        case .intervalDS: "INTERVAL DAY TO SECOND"
        case .intervalYM: "INTERVAL YEAR TO MONTH"
        case .raw: "RAW"
        case .longRAW: "LONG RAW"
        case .long: "LONG"
        case .clob: "CLOB"
        case .nCLOB: "NCLOB"
        case .blob: "BLOB"
        case .bFile: "BFILE"
        case .boolean: "BOOLEAN"
        case .rowID, .uRowID: "ROWID"
        case .json: "JSON"
        case .vector: "VECTOR"
        case .cursor: "REF CURSOR"
        case .object: "OBJECT"
        default: "?"
        }
    }

    // MARK: Errors

    /// A failure in plain words: nobody at the address, no such host, the
    /// listener not knowing the service, a refused login, TLS.
    static func describe(_ error: Error, host: String, port: Int, service: String, connecting: Bool = false) -> String {
        if let error = error as? DatabaseError { return error.localizedDescription }
        let place = "\(host):\(port)"
        if let sql = error as? OracleSQLError {
            if let info = sql.serverInfo, let message = info.message?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return OracleErrors.explain(number: Int(info.number), message: message, place: place, service: service)
            }
            if sql.code == .failedToVerifyTLSCertificates || sql.code == .failedToAddSSLHandler {
                return
                    "TLS failed with \(place): \(sql.underlying.map { String(describing: $0) } ?? "the certificate was refused") — turn SSL off for a listener that speaks plain TCP, or Require to not verify a self-signed certificate."
            }
            if sql.code == .connectionError || sql.code == .uncleanShutdown, let underlying = sql.underlying {
                return describe(underlying, host: host, port: port, service: service, connecting: connecting)
            }
            // The listener's refusal (a TNS REFUSE, which OracleNIO reads as
            // the connection closing): most often a service it doesn't serve.
            if sql.code == .uncleanShutdown, connecting {
                return
                    "Oracle's listener at \(place) closed the connection before signing in — most often it doesn't serve “\(service)” (ORA-12514): check the service name (lsnrctl services lists them; Oracle Free's is FREEPDB1, XE's XEPDB1), or SID if it is one."
            }
            if sql.code == .serverVersionNotSupported { return "This Oracle is older than OracleNIO speaks (12.1 and later)." }
            return "Oracle: \(sql.code)\(sql.underlying.map { " — \($0)" } ?? "")"
        }
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED: return "Nothing answers at \(place) — is Oracle's listener running, and on that port?"
            case ETIMEDOUT: return "Oracle at \(place) didn't answer in time."
            default: return "Couldn't reach Oracle at \(place): \(io.description)"
            }
        }
        if let channel = error as? ChannelError, case .connectTimeout = channel {
            return "Oracle at \(place) didn't answer in time — is the host right, and the port open to this Mac?"
        }
        if error is NIOConnectionError {
            let text = String(describing: error)
            if text.contains("dnsAAAAError") || text.contains("dnsAError") || text.contains("resolution") {
                return "There's no host \(host) — check the name."
            }
            return "Nothing answers at \(place) — is Oracle's listener running, and on that port?"
        }
        if error is NIOSSLError || String(describing: error).contains("handshake") {
            return "TLS failed with \(place): \(error) — turn SSL off for a listener that speaks plain TCP, or Require to not verify a self-signed certificate."
        }
        return String(describing: error)
    }
}

/// ORA- errors a person meets connecting, said in Overterm's words with
/// Oracle's own beside them. Pure.
enum OracleErrors {
    static func explain(number: Int, message: String, place: String, service: String) -> String {
        switch number {
        case 1017: return "Oracle refused the user or password (\(message))."
        case 28000: return "The account is locked (\(message)) — a DBA unlocks it: ALTER USER … ACCOUNT UNLOCK."
        case 28001: return "The password has expired (\(message)) — change it in SQL*Plus or SQL Developer first."
        case 12514:
            return
                "The listener at \(place) doesn't know the service \(service.isEmpty ? "named" : "“\(service)”") — check the service name (lsnrctl services lists them; Oracle Free's is FREEPDB1, XE's XEPDB1)."
        case 12505: return "The listener at \(place) doesn't know the SID “\(service)” — a pluggable database is a service name, not a SID."
        case 12541: return "No listener at \(place) — is Oracle running, and on that port?"
        case 12545: return "There's no host for \(place) — check the name."
        case 1033, 1034: return "Oracle at \(place) isn't open yet (\(message)) — it may still be starting."
        default: return message
        }
    }
}
