import Foundation

// What a driver does beyond statements and the catalog — a server's page
// (monitoring), a result's rows edited, users and roles — each a protocol a
// driver conforms to, as far as its engine supports it. The UI asks the
// driver's type (`DatabaseDrivers.features`); a kind whose driver doesn't
// conform doesn't show the item. docs/architecture.md, Database: Server
// page, Editing rows, Users and roles.

/// What a kind's driver does beyond statements.
struct DatabaseFeatures: OptionSet, Sendable {
    let rawValue: Int
    /// The Server page: sessions, slow queries, locks, sizes, headline numbers.
    static let monitoring = DatabaseFeatures(rawValue: 1)
    /// A one-table result's rows edited in the grid.
    static let editing = DatabaseFeatures(rawValue: 2)
    /// The Users page.
    static let users = DatabaseFeatures(rawValue: 4)
}

extension DatabaseDrivers {
    /// The driver type a kind is made with — what `features` asks.
    static func driverType(of kind: DatabaseKind) -> any DatabaseDriver.Type {
        switch kind {
        case .sqlite: SQLiteDriver.self
        case .postgres, .redshift: PostgresDriver.self
        case .mysql, .mariadb: MySQLDriver.self
        case .clickhouse: ClickHouseDriver.self
        case .bigquery: BigQueryDriver.self
        case .redis: RedisDriver.self
        case .prometheus, .loki, .tempo: ObservabilityDriver.self
        case .s3, .gcs: NoSQLDriver.self
        case .mongodb, .documentdb: MongoDriver.self
        case .elasticsearch, .opensearch: SearchDriver.self
        case .dynamodb: DynamoDBDriver.self
        case .influxdb: InfluxDBDriver.self
        case .neo4j: Neo4jDriver.self
        case .rabbitmq: RabbitMQDriver.self
        case .oracle: OracleDriver.self
        }
    }

    /// What a kind's driver does, by what its type conforms to and says of
    /// the kind (one driver serves PostgreSQL and Redshift).
    static func features(of kind: DatabaseKind) -> DatabaseFeatures {
        let type = driverType(of: kind)
        var features: DatabaseFeatures = []
        if let monitoring = type as? any DatabaseMonitoring.Type, !monitoring.monitorParts(for: kind).isEmpty { features.insert(.monitoring) }
        if let editing = type as? any DatabaseTableEditing.Type, editing.editsRows(kind) { features.insert(.editing) }
        if let users = type as? any DatabaseUserManagement.Type, users.managesUsers(kind) { features.insert(.users) }
        return features
    }
}

extension DatabaseKind {
    var features: DatabaseFeatures { DatabaseDrivers.features(of: self) }
}

/// Why the engine has nothing to give for a part — said, with the line
/// that turns it on, never an empty table without a reason.
struct MonitorGap: Equatable, Sendable, Error {
    var reason: String
    /// The setting or statement that turns it on, when there is one.
    var fix: String?
}

/// A read that may find its source missing (an extension, a schema, a privilege).
enum Monitored<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case unavailable(MonitorGap)

    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    var gap: MonitorGap? {
        if case .unavailable(let gap) = self { return gap }
        return nil
    }
}

// MARK: Monitoring

/// The Server page's tabs — a driver says which its engine has.
enum MonitorPart: String, CaseIterable, Sendable {
    case overview = "Overview"
    case activity = "Activity"
    case slowQueries = "Slow Queries"
    case locks = "Locks"
    case sizes = "Sizes"
}

/// One headline number: version, uptime, connections of max…
struct ServerFact: Equatable, Sendable {
    var title: String
    var value: String
    var detail: String?
}

struct ServerOverview: Equatable, Sendable {
    var facts: [ServerFact] = []
    /// What the engine wants said beside them (a privilege missing…).
    var notes: [String] = []
}

/// A session or connection, as the engine lists it: who, from where, doing what.
struct DatabaseActivity: Equatable, Sendable, Identifiable {
    /// What cancelling it names: a backend's pid, a thread's id.
    var id: String
    var user: String?
    /// A session may have no database (a document store's, a replication one).
    var database: String?
    var client: String?
    var application: String?
    /// active, idle, idle in transaction, Sleep, Query…
    var state: String?
    var statement: String?
    /// How long the statement has run — or, idle, how long it has been idle.
    var seconds: Double?
    /// What it waits on (a lock, IO, a client).
    var waiting: String?
    /// This connection's own session: never cancelled from here.
    var isOwn = false

    /// Whether it is doing something now, not sitting idle.
    var isActive: Bool {
        guard let state = state?.lowercased() else { return statement?.isEmpty == false }
        return !["idle", "sleep", "daemon"].contains(state)
    }
}

/// A statement as the engine's own record of statements sums it up.
struct SlowQuery: Equatable, Sendable, Identifiable {
    var id: String
    var statement: String
    var calls: Int
    /// Seconds, all calls together.
    var total: Double
    /// Seconds, a call.
    var mean: Double
    var rows: Int?
    var database: String?
    var user: String?
    /// What else the engine's record says of it (BigQuery's bytes processed
    /// and slot time, Oracle's CPU and buffer gets).
    var detail: String? = nil
}

/// A session waiting on another.
struct LockWait: Equatable, Sendable, Identifiable {
    var waiting: String
    var waitingUser: String?
    var waitingStatement: String?
    var blocking: String
    var blockingUser: String?
    var blockingStatement: String?
    /// The lock: its mode and what it is on.
    var lock: String?
    var seconds: Double?
    var id: String { "\(waiting)>\(blocking)" }
}

struct SizeEntry: Equatable, Sendable, Identifiable {
    /// A database, a table, an index (its table in `detail`).
    var name: String
    var schema: String?
    var bytes: Int64
    /// What else the engine says: rows (estimated), the index's table.
    var detail: String?
    /// What `bytes` counts when it isn't bytes — "nodes", "messages" — for
    /// an engine that says how many, not how big.
    var unit: String?
    var id: String { "\(schema ?? "")\u{1}\(name)" }

    /// As the page and the agents say it.
    var size: String { unit.map { "\(bytes) \($0)" } ?? OpsText.bytes(bytes) }
}

struct DatabaseSizes: Equatable, Sendable {
    var databases: [SizeEntry] = []
    var tables: [SizeEntry] = []
    var indexes: [SizeEntry] = []
    /// What couldn't be read, and why.
    var notes: [String] = []
}

/// A driver whose engine says what it is doing. Every read goes through the
/// driver's own connection; nothing is read unless asked (the page asks only
/// while it shows).
protocol DatabaseMonitoring: DatabaseDriver {
    /// The Server page's tabs for a kind; empty, no page.
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart]
    func overview() async throws -> ServerOverview
    func activity() async throws -> Monitored<[DatabaseActivity]>
    func slowQueries() async throws -> Monitored<[SlowQuery]>
    func locks() async throws -> Monitored<[LockWait]>
    func sizes() async throws -> Monitored<DatabaseSizes>
    /// Stops a session's statement — or, `terminate`, ends the session.
    /// Refused on a read-only connection and on the connection's own session.
    func cancel(session: String, terminate: Bool) async throws
    /// The engine's own consistency check, run on request (SQLite's
    /// `integrity_check`); nil where it has none.
    func integrityCheck() async throws -> String?
    /// How a session is stopped on this kind, as the menu and the
    /// confirmation say it — MongoDB's killOp, a search task's cancel; empty:
    /// none offered; nil: the SQL engines' two (`SessionStop.sql`).
    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]?
}

/// One way a session is stopped: Neo4j's TERMINATE TRANSACTION, Redis's
/// CLIENT KILL, RabbitMQ's connection closed.
struct SessionStop: Equatable, Sendable {
    /// What `cancel(session:terminate:)` is called with.
    var terminate: Bool
    /// The menu item: "Terminate Transaction…".
    var menu: String
    /// The confirmation's question.
    var title: String
    /// What is sent, as the confirmation shows it.
    var command: String
    /// What it does.
    var effect: String
    var button: String
}

extension SessionStop {
    /// Who a session is and what it runs, as a confirmation says it.
    static func said(_ session: DatabaseActivity) -> String {
        [session.user, session.database, session.client].compactMap { $0 }.joined(separator: " · ") + "\n"
            + OpsText.statement(session.statement, limit: 400)
    }

    /// The SQL engines' two: cancel the statement, terminate the session.
    static func sql(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop] {
        let mysql = kind == .mysql || kind == .mariadb
        return [
            SessionStop(
                terminate: false, menu: "Cancel Statement…", title: "Cancel session \(session.id)'s statement?",
                command: mysql ? "KILL QUERY \(session.id)" : "pg_cancel_backend(\(session.id))",
                effect: said(session) + "\n\nThe statement stops; the session stays.", button: "Cancel Statement"),
            SessionStop(
                terminate: true, menu: "Terminate Session…", title: "End session \(session.id)?",
                command: mysql ? "KILL \(session.id)" : "pg_terminate_backend(\(session.id))",
                effect: said(session) + "\n\nIts connection is closed; what it hadn't committed is rolled back.", button: "Terminate"),
        ]
    }
}

extension DatabaseMonitoring {
    func activity() async throws -> Monitored<[DatabaseActivity]> { .unavailable(MonitorGap(reason: "This engine doesn't list its sessions.")) }
    func slowQueries() async throws -> Monitored<[SlowQuery]> { .unavailable(MonitorGap(reason: "This engine keeps no record of slow queries.")) }
    func locks() async throws -> Monitored<[LockWait]> { .unavailable(MonitorGap(reason: "This engine doesn't say who waits on whom.")) }
    func sizes() async throws -> Monitored<DatabaseSizes> { .unavailable(MonitorGap(reason: "This engine doesn't say its sizes.")) }
    func cancel(session: String, terminate: Bool) async throws { throw DatabaseError.failed("Sessions can't be cancelled here.") }
    func integrityCheck() async throws -> String? { nil }
    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? { nil }
}

// MARK: Editing rows

/// A table as a result names it: its schema when written, else nil — the
/// driver resolves it as an unqualified name would be.
struct TableName: Equatable, Hashable, Sendable {
    var schema: String?
    var name: String
}

/// How a table's rows are found again.
struct TableKey: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case primary
        /// A unique key over columns that can't be NULL: its name.
        case unique(String)
        /// SQLite's rowid, for a rowid table without a primary key.
        case rowid
        /// A row's own identity, not a SQL table's key, said as the engine
        /// says it: a node's `elementId`, a document's `_id`, a search hit's
        /// `_index` and `_id`, a DynamoDB item's partition and sort key.
        case identity(String)
    }

    /// The table, resolved: its schema as the database names it.
    var table: TableName
    var kind: Kind
    var columns: [String]
    /// Columns a cell of the grid can't be written back into: generated ones,
    /// and those whose text isn't their value (a SQLite BLOB's "<n bytes>").
    var readOnlyColumns: Set<String> = []
    /// Columns a new row sets but an existing row's UPDATE can't change
    /// (ClickHouse's sorting and partition keys).
    var fixedColumns: Set<String> = []
    /// A word or two the edit bar shows beside the pencil when a kind's Save
    /// isn't the usual one ("mutations", "key not enforced", "by ROWID").
    var label: String?
    /// What the edit bar's help says of it beside the key.
    var note: String?

    /// What the status bar says the rows are found by.
    var summary: String {
        let names = columns.joined(separator: ", ")
        switch kind {
        case .primary: return "primary key \(names)"
        case .unique(let index): return "unique key \(index) (\(names))"
        case .rowid: return "rowid"
        case .identity(let what): return what
        }
    }
}

/// One statement of a Save, and what it must do: an UPDATE or DELETE of
/// exactly one row (its key), an INSERT of one.
struct EditStatement: Equatable, Sendable {
    var sql: String
    /// Rows it must change: 1, else the whole Save is rolled back.
    var expectedRows = 1
    /// A count of the rows the key finds — for MySQL, whose UPDATE counts
    /// only the rows it actually changed (0 when the value was the same).
    var countSQL: String?
    /// What the Save's confirmation says of it beside the statement (a
    /// node's relationships deleted with it).
    var note: String?
    /// What ends it in a listing: `;`, or a blank line after a request
    /// whose body is JSON (Elasticsearch's).
    var terminator = ";"

    /// Statements as the preview and the confirmation list them.
    static func listing(_ statements: [EditStatement]) -> String {
        statements.map { $0.sql + $0.terminator }.joined(separator: "\n")
    }
}

/// A driver whose results can be edited: it finds a table's key, and
/// applies a Save's statements together, in one transaction.
protocol DatabaseTableEditing: DatabaseDriver {
    /// Whether a kind's rows are edited (Redshift's keys aren't enforced, so
    /// its rows aren't).
    static func editsRows(_ kind: DatabaseKind) -> Bool
    /// How names and values are written in its statements.
    func editDialect() async -> SQLDialect
    /// The table's key — primary, else a unique key over NOT NULL columns
    /// (SQLite: else its rowid); nil when it has none, or no such table.
    func key(of table: TableName) async throws -> TableKey?
    /// The statements in one transaction — each checked to change the rows it
    /// expects; any failure rolls back all of them. Refused on a read-only
    /// connection.
    func apply(_ statements: [EditStatement]) async throws
    /// A kind whose statements aren't SQL (documents, items, hits) finds its
    /// rows itself: the result's key and columns, or why not. nil: the SQL
    /// way — `EditableQuery`, `key(of:)`, the catalog's columns.
    func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>?
    /// The statements a Save runs, in its own console language — what the
    /// preview and the confirmation show, and what `apply` runs.
    func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement]
    /// What the confirmation says of how they run together.
    func editSaveNote() async -> String
}

extension DatabaseTableEditing {
    static func editsRows(_ kind: DatabaseKind) -> Bool { true }

    func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>? { nil }

    func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try EditStatements.make(edits, rows: rows, result: result, dialect: await editDialect())
    }

    func editSaveNote() async -> String { "In one transaction: if any statement fails, none is kept." }
}

// MARK: Users and roles

/// A user or a role, as the engine's catalog says it — never its password
/// or the password's hash.
struct DatabaseUser: Equatable, Hashable, Sendable, Identifiable {
    var name: String
    /// MySQL's and MariaDB's: the account's host (`%`, `localhost`).
    var host: String?
    var isRole = false
    var canLogin = true
    var superuser = false
    /// What else is true of it, in words: "creates databases", "locked"…
    var attributes: [String] = []
    var validUntil: String?
    var connectionLimit: Int?
    /// The roles it is a member of.
    var memberOf: [String] = []

    var id: String { host.map { "\(name)@\($0)" } ?? name }
    var display: String { host.map { "\(name)@\($0)" } ?? name }
}

/// What a user may do on one object.
struct DatabaseGrant: Equatable, Hashable, Sendable, Identifiable {
    /// server, database, schema, table, role, owner
    var kind: String
    /// The object as the engine names it: `shop`, `public.orders`, `*.*`.
    var object: String
    var privileges: [String]
    var grantable = false
    /// What a REVOKE of it names, when the engine said it exactly.
    var target: GrantTarget? = nil
    var id: String { "\(kind) \(object)" }
}

/// A driver whose engine has users and roles to list and change.
protocol DatabaseUserManagement: DatabaseDriver {
    static func managesUsers(_ kind: DatabaseKind) -> Bool
    func userDialect() async -> UserDialect
    /// Every user and role; unavailable where this user may not read them.
    func users() async throws -> Monitored<[DatabaseUser]>
    /// A user's privileges, as far as the engine says.
    func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]>
    /// Statements `UserStatements` made, sent once, in order, nothing kept —
    /// not in the history, not in a log. Refused on a read-only connection.
    func run(_ statements: [UserStatement]) async throws
    /// How its statements are made and what the sheets ask; the SQL
    /// engines' from `userDialect()`.
    func userStatements() async -> any UserStatementMaking
}

extension DatabaseUserManagement {
    static func managesUsers(_ kind: DatabaseKind) -> Bool { true }
    func userStatements() async -> any UserStatementMaking { SQLUserStatements(dialect: await userDialect()) }
}

// MARK: Reading the engines' answers

/// A row of a catalog query, read by column name — the engines' answers are
/// text (`QueryResult`), whatever their types.
struct ResultRow {
    let columns: [String: Int]
    let values: [String?]

    init(_ values: [String?], columns: [String: Int]) {
        self.values = values
        self.columns = columns
    }

    static func rows(of result: QueryResult) -> [ResultRow] {
        var index: [String: Int] = [:]
        for (at, name) in result.columns.enumerated() where index[name.lowercased()] == nil { index[name.lowercased()] = at }
        return result.rows.map { ResultRow($0, columns: index) }
    }

    subscript(_ name: String) -> String? {
        guard let at = columns[name.lowercased()], values.indices.contains(at) else { return nil }
        return values[at]
    }

    func int(_ name: String) -> Int? { self[name].flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    func int64(_ name: String) -> Int64? { self[name].flatMap { Int64($0) ?? Double($0).map { Int64($0) } } }
    func double(_ name: String) -> Double? { self[name].flatMap(Double.init) }
    /// t/f, 1/0, YES/NO, true/false.
    func bool(_ name: String) -> Bool { ["t", "1", "true", "yes", "y", "on"].contains(self[name]?.lowercased() ?? "") }
}

/// Numbers as the pages and the agents say them.
enum OpsText {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    /// 0.004 → "4 ms", 75 → "1 min 15 s", 90061 → "1 d 1 h".
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds)
        if whole < 3600 { return "\(whole / 60) min \(whole % 60) s" }
        if whole < 86400 { return "\(whole / 3600) h \(whole % 3600 / 60) min" }
        return "\(whole / 86400) d \(whole % 86400 / 3600) h"
    }

    /// A statement on one line, cut, its password literals masked: what a
    /// row, the clipboard and an agent's table get.
    static func statement(_ text: String?, limit: Int = 200) -> String {
        guard let text else { return "" }
        let line = maskSecrets(text).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Another session's statement may set a password — `PASSWORD '…'`,
    /// `IDENTIFIED BY '…'`, `IDENTIFIED WITH plugin AS '…'`, `USING '…'`,
    /// MariaDB's `PASSWORD('…')`: the literal is masked wherever a
    /// statement is shown or told to an agent.
    static func maskSecrets(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\b(PASSWORD|IDENTIFIED\s+BY|IDENTIFIED\s+WITH\s+\S+\s+(?:BY|AS)|USING)(\s*\(?\s*)(?:E|N)?'(?:[^'\\]|''|\\.)*'"#,
            with: "$1$2'••••'", options: .regularExpression
        )
        // Oracle's: a quoted identifier or a bare word (`IDENTIFIED BY "…"`).
        .replacingOccurrences(of: #"(?i)\b(IDENTIFIED\s+BY\s+)(?:"[^"]*"|[^\s'";]+)"#, with: "$1\"••••\"", options: .regularExpression)
    }

    static func percent(_ ratio: Double) -> String { String(format: "%.1f%%", ratio * 100) }
}
