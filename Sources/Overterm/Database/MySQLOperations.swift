import Foundation
import MySQLNIO

/// MySQL's and MariaDB's Server page, rows edited, users and roles — from
/// information_schema, performance_schema and the mysql schema, through the
/// driver's one connection. docs/architecture.md, Database: Server page.
extension MySQLDriver: DatabaseMonitoring, DatabaseTableEditing, DatabaseUserManagement {
    private var isMariaDB: Bool { config.kind == .mariadb }

    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { MonitorPart.allCases }

    package func editDialect() async -> SQLDialect {
        await identify()
        return SQLDialect(engine: isMariaDB ? .mariadb : .mysql, backslashEscapes: backslashEscapes ?? true)
    }

    package func userDialect() async -> UserDialect { isMariaDB ? .mariadb : .mysql }

    private func read(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        try await execute(sql, limit: limit)
    }

    /// The connection's id and its sql_mode, once.
    private func identify() async {
        guard ownID == nil else { return }
        guard let row = try? await read("SELECT CONNECTION_ID() AS id, @@SESSION.sql_mode AS mode").rows.first else { return }
        ownID = (row[safe: 0] ?? nil).flatMap { Int($0) }
        backslashEscapes = !((row[safe: 1] ?? nil) ?? "").uppercased().contains("NO_BACKSLASH_ESCAPES")
    }

    /// An error the server says for a privilege missing: 1142 (command
    /// denied), 1227 (needs a privilege), 1044 (access to a database).
    package static func isPrivilege(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("denied") || text.contains("privilege")
    }

    // MARK: Monitoring

    package func overview() async throws -> ServerOverview {
        await identify()
        let status = try await read(MySQLOps.statusSQL)
        let variables = try await read(MySQLOps.variablesSQL)
        let replica = try? await read("SHOW REPLICA STATUS")
        return MySQLOps.overview(status: status, variables: variables, replica: replica)
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        await identify()
        return .value(MySQLOps.activity(try await read(MySQLOps.activitySQL)))
    }

    package func slowQueries() async throws -> Monitored<[SlowQuery]> {
        let settings = ResultRow.rows(of: try await read("SELECT @@performance_schema AS ps, @@log_output AS output, @@slow_query_log AS slow")).first
        if settings?.bool("ps") == true {
            do {
                return .value(MySQLOps.slowQueries(try await read(MySQLOps.digestSQL)))
            } catch  where Self.isPrivilege(error) {
                return .unavailable(
                    MonitorGap(
                        reason: "This user can't read performance_schema: \(error.localizedDescription)",
                        fix: "GRANT SELECT ON performance_schema.* TO <this user>; (by an administrator)"))
            }
        }
        // MariaDB keeps it off by default; its slow log can be a table.
        if (settings?["output"] ?? "").uppercased().contains("TABLE"), settings?.bool("slow") == true {
            do {
                return .value(MySQLOps.slowQueries(try await read(MySQLOps.slowLogSQL)))
            } catch  where Self.isPrivilege(error) {
                return .unavailable(MonitorGap(reason: "This user can't read mysql.slow_log: \(error.localizedDescription)"))
            }
        }
        return .unavailable(MySQLOps.performanceSchemaOff(mariadb: isMariaDB))
    }

    package func locks() async throws -> Monitored<[LockWait]> {
        if !isMariaDB {
            let on = ResultRow.rows(of: try await read("SELECT @@performance_schema AS ps")).first?.bool("ps") == true
            guard on else { return .unavailable(MySQLOps.performanceSchemaOff(mariadb: false)) }
        }
        do {
            return .value(PostgresOps.locks(try await read(isMariaDB ? MySQLOps.mariaLocksSQL : MySQLOps.mysqlLocksSQL)))
        } catch  where Self.isPrivilege(error) {
            return .unavailable(
                MonitorGap(
                    reason: "This user can't read who waits on whom: \(error.localizedDescription)",
                    fix: isMariaDB ? "GRANT PROCESS ON *.* TO <this user>;" : "GRANT SELECT ON performance_schema.* TO <this user>;"))
        }
    }

    package func sizes() async throws -> Monitored<DatabaseSizes> {
        var sizes = DatabaseSizes()
        for (part, sql) in [("Databases", MySQLOps.databaseSizesSQL), ("Tables", MySQLOps.tableSizesSQL), ("Indexes", MySQLOps.indexSizesSQL)] {
            do {
                let entries = PostgresOps.sizes(try await read(sql, limit: 200))
                switch part {
                case "Databases": sizes.databases = entries
                case "Tables": sizes.tables = entries
                default: sizes.indexes = entries
                }
            } catch {
                sizes.notes.append("\(part): \(error.localizedDescription)")
            }
        }
        if !isMariaDB { sizes.notes.append("MySQL keeps these figures up to a day old (information_schema_stats_expiry).") }
        return .value(sizes)
    }

    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly(terminate ? "KILL" : "KILL QUERY") }
        await identify()
        guard let id = Int(session) else { throw DatabaseError.failed("No session \(session).") }
        guard id != ownID else { throw DatabaseError.failed("That is this connection's own session.") }
        _ = try await read(terminate ? "KILL \(id)" : "KILL QUERY \(id)")
    }

    // MARK: Editing rows

    package func key(of table: TableName) async throws -> TableKey? {
        let dialect = await editDialect()
        let schema = table.schema.map(dialect.literal) ?? "DATABASE()"
        let result = try await read(MySQLOps.keySQL(schema: schema, table: dialect.literal(table.name)))
        guard var key = MySQLOps.key(result) else { return nil }
        if let columns = try? await read(MySQLOps.columnKindsSQL(schema: schema, table: dialect.literal(table.name))) {
            key.readOnlyColumns = MySQLOps.readOnlyColumns(columns)
        }
        return key
    }

    package func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        try await exclusive {
            guard let connection else { throw DatabaseError.notConnected }
            do {
                try await connection.simpleQuery("START TRANSACTION").get()
                for (index, statement) in statements.enumerated() {
                    let changed = MySQLCollected(limit: 0)
                    try await connection.query(statement.sql, [], onRow: { _ in }, onMetadata: { changed.affected = Int($0.affectedRows) }).get()
                    var count = changed.affected ?? 0
                    // MySQL counts only rows whose values changed: an UPDATE to
                    // the same value says 0. The key finds the row or it doesn't.
                    if count != statement.expectedRows, let countSQL = statement.countSQL {
                        let found = MySQLCollected(limit: 1)
                        try await connection.simpleQuery(countSQL, onRow: { found.add($0) }).get()
                        count = found.result.rows.first?.first.flatMap { $0.flatMap { Int($0) } } ?? 0
                    }
                    guard count == statement.expectedRows else {
                        throw DatabaseError.failed(EditApplyError.wrongCount(index: index, changed: count, sql: statement.sql))
                    }
                }
                try await connection.simpleQuery("COMMIT").get()
            } catch {
                _ = try? await connection.simpleQuery("ROLLBACK").get()
                if let error = error as? DatabaseError { throw error }
                throw DatabaseError.failed(Self.describe(error) + " — nothing was saved.")
            }
        }
    }

    // MARK: Users and roles

    package func users() async throws -> Monitored<[DatabaseUser]> {
        do {
            let users = try await read(isMariaDB ? MySQLOps.mariaUsersSQL : MySQLOps.mysqlUsersSQL)
            let edges = (try? await read(isMariaDB ? MySQLOps.mariaRolesSQL : MySQLOps.mysqlRolesSQL)) ?? QueryResult()
            return .value(MySQLOps.users(users, roles: edges))
        } catch  where Self.isPrivilege(error) {
            return .unavailable(
                MonitorGap(
                    reason: "This user may not read the users' catalog (mysql.user): \(error.localizedDescription)",
                    fix: "GRANT SELECT ON mysql.* TO <this user>; (by an administrator)"))
        }
    }

    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        let dialect = await userDialect()
        do {
            let result = try await read("SHOW GRANTS FOR \(UserStatements.account(user, dialect: dialect))")
            return .value(MySQLOps.grants(result.rows.compactMap { $0.first ?? nil }))
        } catch  where Self.isPrivilege(error) {
            return .unavailable(MonitorGap(reason: "This user may not read another's grants: \(error.localizedDescription)"))
        }
    }

    /// Sent as text (the simple protocol): MySQLNIO logs a prepared
    /// statement's text when it fails to close, a simple query's never.
    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        try await exclusive {
            guard let connection else { throw DatabaseError.notConnected }
            for statement in statements {
                do {
                    try await connection.simpleQuery(statement.sql, onRow: { _ in }).get()
                } catch {
                    throw DatabaseError.failed(statement.scrub(Self.describe(error)))
                }
            }
        }
    }
}

/// MySQL's and MariaDB's statements for the Server and Users pages, and
/// their answers read. Pure.
package enum MySQLOps {
    package static let system = "('mysql', 'information_schema', 'performance_schema', 'sys')"

    package static let statusSQL = """
        SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime', 'Threads_connected', 'Threads_running', 'Max_used_connections', 'Questions',
          'Slow_queries', 'Innodb_buffer_pool_read_requests', 'Innodb_buffer_pool_reads', 'Aborted_connects', 'Innodb_row_lock_waits')
        """

    package static let variablesSQL = """
        SELECT @@version AS version, @@version_comment AS comment, @@max_connections AS max_connections, @@read_only AS read_only,
          @@innodb_buffer_pool_size AS pool, DATABASE() AS db
        """

    package static let activitySQL = """
        SELECT ID AS id, USER AS user, HOST AS client, DB AS `database`, COMMAND AS state, TIME AS seconds, STATE AS waiting, INFO AS query,
          ID = CONNECTION_ID() AS own
        FROM information_schema.PROCESSLIST WHERE COMMAND <> 'Daemon' ORDER BY COMMAND = 'Sleep', TIME DESC
        """

    /// The hundred costliest by total time and the hundred by mean.
    package static let digestSQL: String = {
        let select = """
            SELECT DIGEST AS id, SCHEMA_NAME AS `database`, COUNT_STAR AS calls, SUM_TIMER_WAIT / 1e12 AS total,
              AVG_TIMER_WAIT / 1e12 AS mean, SUM_ROWS_SENT AS `rows`, DIGEST_TEXT AS query
            FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST_TEXT IS NOT NULL
            """
        return "(\(select) ORDER BY SUM_TIMER_WAIT DESC LIMIT 100) UNION (\(select) ORDER BY AVG_TIMER_WAIT DESC LIMIT 100)"
    }()

    package static let slowLogSQL = """
        SELECT MD5(sql_text) AS id, db AS `database`, COUNT(*) AS calls, SUM(TIME_TO_SEC(query_time)) AS total,
          AVG(TIME_TO_SEC(query_time)) AS mean, SUM(rows_sent) AS `rows`, CONVERT(sql_text USING utf8mb4) AS query
        FROM mysql.slow_log GROUP BY sql_text, db ORDER BY total DESC LIMIT 100
        """

    package static func performanceSchemaOff(mariadb: Bool) -> MonitorGap {
        MonitorGap(
            reason: "performance_schema is off — it is \(mariadb ? "MariaDB" : "MySQL")'s record of statements and locks.",
            fix: "performance_schema = ON in my.cnf, then restart the server"
                + (mariadb ? " — or slow_query_log = 1 and log_output = 'TABLE', to read mysql.slow_log" : ""))
    }

    package static let mysqlLocksSQL = """
        SELECT wt.PROCESSLIST_ID AS waiting, wt.PROCESSLIST_USER AS waiting_user, wt.PROCESSLIST_INFO AS waiting_query,
          bt.PROCESSLIST_ID AS blocking, bt.PROCESSLIST_USER AS blocking_user, bt.PROCESSLIST_INFO AS blocking_query,
          CONCAT(wl.LOCK_MODE, ' on ', wl.OBJECT_SCHEMA, '.', wl.OBJECT_NAME) AS `lock`, wt.PROCESSLIST_TIME AS seconds
        FROM performance_schema.data_lock_waits w
        JOIN performance_schema.data_locks wl ON wl.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID
        JOIN performance_schema.threads wt ON wt.THREAD_ID = w.REQUESTING_THREAD_ID
        JOIN performance_schema.threads bt ON bt.THREAD_ID = w.BLOCKING_THREAD_ID
        """

    package static let mariaLocksSQL = """
        SELECT r.trx_mysql_thread_id AS waiting, rp.USER AS waiting_user, r.trx_query AS waiting_query,
          b.trx_mysql_thread_id AS blocking, bp.USER AS blocking_user, b.trx_query AS blocking_query,
          CONCAT(l.lock_mode, ' on ', l.lock_table) AS `lock`, TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS seconds
        FROM information_schema.INNODB_LOCK_WAITS w
        JOIN information_schema.INNODB_TRX r ON r.trx_id = w.requesting_trx_id
        JOIN information_schema.INNODB_TRX b ON b.trx_id = w.blocking_trx_id
        LEFT JOIN information_schema.INNODB_LOCKS l ON l.lock_id = w.requested_lock_id
        LEFT JOIN information_schema.PROCESSLIST rp ON rp.ID = r.trx_mysql_thread_id
        LEFT JOIN information_schema.PROCESSLIST bp ON bp.ID = b.trx_mysql_thread_id
        """

    /// Every database, an empty one too.
    package static let databaseSizesSQL = """
        SELECT s.SCHEMA_NAME AS name, COALESCE(SUM(t.DATA_LENGTH + t.INDEX_LENGTH), 0) AS bytes
        FROM information_schema.SCHEMATA s LEFT JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = s.SCHEMA_NAME
        GROUP BY s.SCHEMA_NAME ORDER BY bytes DESC
        """

    package static let tableSizesSQL = """
        SELECT TABLE_SCHEMA AS `schema`, TABLE_NAME AS name, DATA_LENGTH + INDEX_LENGTH AS bytes,
          CONCAT('rows ≈ ', COALESCE(TABLE_ROWS, 0), ', ', COALESCE(ENGINE, '')) AS detail
        FROM information_schema.TABLES WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA NOT IN \(system)
        ORDER BY bytes DESC LIMIT 50
        """

    package static let indexSizesSQL = """
        SELECT database_name AS `schema`, index_name AS name, stat_value * @@innodb_page_size AS bytes, CONCAT('on ', table_name) AS detail
        FROM mysql.innodb_index_stats WHERE stat_name = 'size' AND database_name NOT IN \(system)
        ORDER BY bytes DESC LIMIT 50
        """

    package static func keySQL(schema: String, table: String) -> String {
        """
        SELECT TABLE_SCHEMA AS `schema`, TABLE_NAME AS name, INDEX_NAME AS `index`, COLUMN_NAME AS `column`, NULLABLE AS nullable,
          SUB_PART AS sub_part
        FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(table) AND NON_UNIQUE = 0
        ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
        """
    }

    package static func columnKindsSQL(schema: String, table: String) -> String {
        "SELECT COLUMN_NAME AS name, DATA_TYPE AS type, EXTRA AS extra FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(schema) AND TABLE_NAME = \(table)"
    }

    /// Never `authentication_string` (or `Password`): a password's hash is
    /// never read, so never shown or told to an agent.
    package static let mysqlUsersSQL = """
        SELECT User AS name, Host AS host, account_locked AS locked, password_expired AS expired, Super_priv AS super,
          max_user_connections AS max_connections, plugin
        FROM mysql.user ORDER BY User, Host
        """

    /// MariaDB's mysql.user is a view; whether an account is locked is in
    /// global_priv's JSON. Never `Password` or `authentication_string`.
    package static let mariaUsersSQL = """
        SELECT u.User AS name, u.Host AS host, u.is_role, COALESCE(JSON_VALUE(g.Priv, '$.account_locked'), 'false') AS locked,
          u.password_expired AS expired, u.Super_priv AS super, u.max_user_connections AS max_connections, u.plugin
        FROM mysql.user u LEFT JOIN mysql.global_priv g ON g.User = u.User AND g.Host = u.Host
        ORDER BY u.is_role, u.User, u.Host
        """

    package static let mysqlRolesSQL = "SELECT FROM_USER AS role, FROM_HOST AS role_host, TO_USER AS member, TO_HOST AS member_host FROM mysql.role_edges"
    package static let mariaRolesSQL = "SELECT Role AS role, User AS member, Host AS member_host FROM mysql.roles_mapping"

    // MARK: Answers

    package static func overview(status: QueryResult, variables: QueryResult, replica: QueryResult?) -> ServerOverview {
        var values: [String: String] = [:]
        for row in status.rows where row.count >= 2 {
            if let name = row[0], let value = row[1] { values[name.lowercased()] = value }
        }
        func int(_ name: String) -> Int? { values[name].flatMap { Int($0) } }
        let settings = ResultRow.rows(of: variables).first
        var facts: [ServerFact] = []
        facts.append(ServerFact(title: "Version", value: settings?["version"] ?? "—", detail: settings?["comment"]))
        facts.append(ServerFact(title: "Uptime", value: int("uptime").map { OpsText.duration(Double($0)) } ?? "—"))
        if let used = int("threads_connected"), let max = settings?.int("max_connections") {
            facts.append(
                ServerFact(title: "Connections", value: "\(used) / \(max)", detail: int("max_used_connections").map { "at most \($0) since start" }))
        }
        facts.append(ServerFact(title: "Running", value: values["threads_running"] ?? "—", detail: "threads doing something now"))
        if let requests = int("innodb_buffer_pool_read_requests"), let reads = int("innodb_buffer_pool_reads"), requests > 0 {
            facts.append(
                ServerFact(
                    title: "Buffer pool hit", value: OpsText.percent(1 - Double(reads) / Double(requests)),
                    detail: settings?.int64("pool").map { "of \(OpsText.bytes($0))" }))
        }
        facts.append(ServerFact(title: "Queries", value: values["questions"] ?? "—", detail: values["slow_queries"].map { "\($0) slow" }))
        facts.append(ServerFact(title: "Row lock waits", value: values["innodb_row_lock_waits"] ?? "—", detail: "since start"))
        if let row = replica.flatMap({ ResultRow.rows(of: $0).first }) {
            let behind = row["seconds_behind_source"] ?? row["seconds_behind_master"]
            facts.append(ServerFact(title: "Replica", value: behind.flatMap(Double.init).map { "\(OpsText.duration($0)) behind" } ?? "not running", detail: row["source_host"] ?? row["master_host"]))
        }
        if settings?.bool("read_only") == true { facts.append(ServerFact(title: "Read-only", value: "Yes", detail: "@@read_only")) }
        return ServerOverview(facts: facts)
    }

    package static func activity(_ result: QueryResult) -> [DatabaseActivity] {
        ResultRow.rows(of: result).map { row in
            DatabaseActivity(
                id: row["id"] ?? "", user: row["user"], database: row["database"], client: row["client"], state: row["state"],
                statement: row["query"].flatMap { $0.isEmpty ? nil : $0 }, seconds: row.double("seconds"),
                waiting: row["waiting"].flatMap { $0.isEmpty ? nil : $0 }, isOwn: row.bool("own"))
        }
    }

    package static func slowQueries(_ result: QueryResult) -> [SlowQuery] { PostgresOps.slowQueries(result) }

    /// The primary key, else the first unique index over whole NOT NULL columns.
    package static func key(_ result: QueryResult) -> TableKey? {
        var order: [String] = []
        var indexes: [String: (schema: String, table: String, columns: [String], usable: Bool)] = [:]
        for row in ResultRow.rows(of: result) {
            guard let index = row["index"] else { continue }
            if indexes[index] == nil {
                order.append(index)
                indexes[index] = (row["schema"] ?? "", row["name"] ?? "", [], true)
            }
            // A functional part (no column), a prefix, or NULL allowed: no key.
            guard let column = row["column"], row["sub_part"] == nil, row["nullable"]?.uppercased() != "YES" else {
                indexes[index]?.usable = false
                continue
            }
            indexes[index]?.columns.append(column)
        }
        for name in order {
            guard let index = indexes[name], index.usable, !index.columns.isEmpty else { continue }
            return TableKey(
                table: TableName(schema: index.schema, name: index.table), kind: name == "PRIMARY" ? .primary : .unique(name), columns: index.columns)
        }
        return nil
    }

    /// Generated columns can't be written; a binary one's text isn't its value.
    package static func readOnlyColumns(_ result: QueryResult) -> Set<String> {
        let binary: Set<String> = [
            "blob", "tinyblob", "mediumblob", "longblob", "binary", "varbinary", "geometry", "point", "linestring", "polygon", "multipoint",
            "multilinestring", "multipolygon", "geometrycollection",
        ]
        return Set(
            ResultRow.rows(of: result).compactMap { row in
                guard let name = row["name"] else { return nil }
                let extra = (row["extra"] ?? "").uppercased()
                let generated = extra.contains("VIRTUAL GENERATED") || extra.contains("STORED GENERATED") || extra.contains("PERSISTENT GENERATED")
                return generated || binary.contains((row["type"] ?? "").lowercased()) ? name : nil
            })
    }

    package static func users(_ result: QueryResult, roles: QueryResult) -> [DatabaseUser] {
        var memberOf: [String: [String]] = [:]
        var roleAccounts: Set<String> = []
        for row in ResultRow.rows(of: roles) {
            guard let role = row["role"], let member = row["member"] else { continue }
            let roleName = row["role_host"].map { "\(role)@\($0)" } ?? role
            roleAccounts.insert(roleName)
            memberOf["\(member)@\(row["member_host"] ?? "%")", default: []].append(roleName)
        }
        return ResultRow.rows(of: result).map { row in
            let name = row["name"] ?? ""
            let host = row["host"] ?? "%"
            let isRole = row["is_role"] != nil ? row.bool("is_role") : roleAccounts.contains("\(name)@\(host)")
            var attributes: [String] = []
            if row.bool("locked") { attributes.append("locked") }
            if row.bool("expired") { attributes.append("password expired") }
            if let plugin = row["plugin"], !plugin.isEmpty, !isRole { attributes.append(plugin) }
            return DatabaseUser(
                name: name, host: isRole && row["is_role"] != nil ? nil : host, isRole: isRole, canLogin: !isRole && !row.bool("locked"),
                superuser: row.bool("super"), attributes: attributes, connectionLimit: row.int("max_connections").flatMap { $0 > 0 ? $0 : nil },
                memberOf: (memberOf["\(name)@\(host)"] ?? []).sorted())
        }
    }

    /// SHOW GRANTS' lines as grants — a password's hash (MariaDB's
    /// `IDENTIFIED BY PASSWORD '*…'`, `IDENTIFIED VIA … USING '…'`) cut out
    /// before anything reads them.
    package static func grants(_ lines: [String]) -> [DatabaseGrant] {
        lines.compactMap { raw in
            let line = redact(raw)
            guard line.uppercased().hasPrefix("GRANT ") else { return nil }
            let body = String(line.dropFirst(6))
            let grantable = upperOutside(body).contains(" WITH GRANT OPTION") || upperOutside(body).contains(" WITH ADMIN OPTION")
            guard let to = find(" TO ", in: body) else { return nil }
            let head = String(body[..<to.lowerBound])
            guard let on = find(" ON ", in: head) else {
                // A role: GRANT `r`@`%` TO …
                return DatabaseGrant(kind: "role", object: unquote(head), privileges: ["MEMBER"], grantable: grantable)
            }
            let privileges = splitTop(String(head[..<on.lowerBound]))
            let object = String(head[on.upperBound...]).trimmingCharacters(in: .whitespaces)
            let kind: String
            if object == "*.*" {
                kind = "server"
            } else if object.hasSuffix(".*") {
                kind = "database"
            } else if object.uppercased().hasPrefix("PROCEDURE ") || object.uppercased().hasPrefix("FUNCTION ") {
                kind = "routine"
            } else {
                kind = "table"
            }
            return DatabaseGrant(kind: kind, object: unquote(object), privileges: privileges, grantable: grantable, target: target(object))
        }
    }

    /// `*.*`, `` `db`.* ``, `` `db`.`t` `` as a target; nil for a routine's.
    package static func target(_ object: String) -> GrantTarget? {
        if object == "*.*" { return .server }
        var parts: [String] = []
        var current = ""
        var quoted = false
        var chars = Array(object)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "`" {
                if quoted, chars.first == "`" {
                    current.append("`")
                    chars = chars.dropFirst()
                } else {
                    quoted.toggle()
                }
            } else if c == ".", !quoted {
                parts.append(current)
                current = ""
            } else if c == " ", !quoted {
                return nil
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return parts[1] == "*" ? .database(parts[0]) : .table(TableName(schema: parts[0], name: parts[1]))
    }

    /// A line with `IDENTIFIED …` (and whatever secret follows) removed, up
    /// to the grant's own options (`WITH GRANT OPTION`, `WITH ADMIN OPTION`,
    /// `WITH MAX_…`) or the end — scanned outside quoted names and strings.
    /// Never up to any `WITH`: `IDENTIFIED WITH plugin AS '*hash'` has one.
    package static func redact(_ line: String) -> String {
        guard let identified = find(" IDENTIFIED ", in: line) else { return line }
        let kept = String(line[..<identified.lowerBound])
        let rest = String(line[identified.lowerBound...])
        let options = [" WITH GRANT OPTION", " WITH ADMIN OPTION", " WITH MAX_"].compactMap { find($0, in: rest) }
        guard let first = options.min(by: { $0.lowerBound < $1.lowerBound }) else { return kept }
        return kept + String(rest[first.lowerBound...])
    }

    /// Where `word` is in `text`, outside `…`, '…' and "…".
    private static func find(_ word: String, in text: String) -> Range<String.Index>? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "`" || c == "'" || c == "\"" {
                quote = c
            } else if text[index...].uppercased().hasPrefix(word) {
                return index..<text.index(index, offsetBy: word.count)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func upperOutside(_ text: String) -> String {
        var out = ""
        var quote: Character?
        for c in text {
            if let open = quote {
                if c == open { quote = nil }
                out.append(" ")
            } else if c == "`" || c == "'" || c == "\"" {
                quote = c
                out.append(" ")
            } else {
                out += c.uppercased()
            }
        }
        return out
    }

    /// `SELECT, INSERT (a, b)` → ["SELECT", "INSERT (a, b)"].
    private static func splitTop(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for c in text {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if c == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    private static func unquote(_ text: String) -> String { text.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces) }
}
