import Foundation
import Logging
import PostgresNIO

/// PostgreSQL's (and Redshift's) Server page, rows edited, users and roles —
/// read from its own statistics views and catalog, through the driver's one
/// connection. Redshift has its own system tables (`stv_*`, `sys_*`,
/// `svv_*`, `pg_user`): each read asks the ones its kind has.
/// docs/architecture.md, Database: Server page.
extension PostgresDriver: DatabaseMonitoring, DatabaseTableEditing, DatabaseUserManagement {
    private var isRedshift: Bool { config.kind == .redshift }

    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { MonitorPart.allCases }

    /// Redshift declares primary keys but never enforces them: a "key" may
    /// find two rows, so its rows aren't edited.
    package static func editsRows(_ kind: DatabaseKind) -> Bool { kind == .postgres }

    package func editDialect() async -> SQLDialect { isRedshift ? .redshift : .postgres }
    package func userDialect() async -> UserDialect { isRedshift ? .redshift : .postgres }

    /// A read of the Server's: its rows, or the server's own words thrown.
    private func read(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        try await execute(sql, limit: limit)
    }

    /// The backend's pid and the server's version, once.
    private func identify() async {
        guard ownPID == nil else { return }
        let row = try? await read("SELECT pg_backend_pid() AS pid, current_setting('server_version_num') AS version").rows.first
        ownPID = (row?[0]).flatMap { $0.flatMap { Int($0) } }
        versionNumber = (row?[1]).flatMap { $0.flatMap { Int($0) } }
    }

    // MARK: Monitoring

    package func overview() async throws -> ServerOverview {
        await identify()
        if isRedshift {
            let result = try await read(PostgresOps.redshiftOverviewSQL)
            return PostgresOps.overview(result, redshift: true)
        }
        return PostgresOps.overview(try await read(PostgresOps.overviewSQL), redshift: false)
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        await identify()
        let result = try await read(isRedshift ? PostgresOps.redshiftActivitySQL : PostgresOps.activitySQL)
        return .value(PostgresOps.activity(result))
    }

    package func slowQueries() async throws -> Monitored<[SlowQuery]> {
        if isRedshift {
            do {
                return .value(PostgresOps.slowQueries(try await read(PostgresOps.redshiftSlowSQL)))
            } catch {
                return .unavailable(MonitorGap(reason: "Redshift's sys_query_history couldn't be read: \(error.localizedDescription)"))
            }
        }
        await identify()
        let installed = try await read("SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements'")
        guard !installed.rows.isEmpty else { return .unavailable(PostgresOps.statementsMissing(database: config.database)) }
        do {
            return .value(PostgresOps.slowQueries(try await read(PostgresOps.slowSQL(version: versionNumber ?? 0))))
        } catch {
            // Installed, but not preloaded: the view refuses to be read.
            if error.localizedDescription.contains("shared_preload_libraries") {
                return .unavailable(
                    MonitorGap(
                        reason: "pg_stat_statements is installed but not loaded: \(error.localizedDescription)",
                        fix: "shared_preload_libraries = 'pg_stat_statements' in postgresql.conf, then restart the server"))
            }
            throw error
        }
    }

    package func locks() async throws -> Monitored<[LockWait]> {
        let result = try await read(isRedshift ? PostgresOps.redshiftLocksSQL : PostgresOps.locksSQL)
        return .value(PostgresOps.locks(result))
    }

    package func sizes() async throws -> Monitored<DatabaseSizes> {
        var sizes = DatabaseSizes()
        if isRedshift {
            do {
                sizes.tables = PostgresOps.sizes(try await read(PostgresOps.redshiftTablesSQL))
            } catch {
                sizes.notes.append("Tables: \(error.localizedDescription)")
            }
            sizes.notes.append("Redshift has no indexes; svv_table_info says tables' sizes.")
            return .value(sizes)
        }
        for (part, sql) in [("Databases", PostgresOps.databaseSizesSQL), ("Tables", PostgresOps.tableSizesSQL), ("Indexes", PostgresOps.indexSizesSQL)] {
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
        return .value(sizes)
    }

    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly(terminate ? "terminating a session" : "cancelling a statement") }
        await identify()
        guard let pid = Int(session) else { throw DatabaseError.failed("No session \(session).") }
        guard pid != ownPID else { throw DatabaseError.failed("That is this connection's own session.") }
        let function = terminate ? "pg_terminate_backend" : "pg_cancel_backend"
        let answer = try await read("SELECT \(function)(\(pid))").rows.first?.first ?? nil
        guard answer == "t" || answer == "true" else {
            throw DatabaseError.failed("\(pid) wasn't \(terminate ? "terminated" : "cancelled") — it has ended, or isn't this user's to signal (pg_signal_backend).")
        }
    }

    // MARK: Editing rows

    package func key(of table: TableName) async throws -> TableKey? {
        guard !isRedshift else { return nil }
        let dialect = SQLDialect.postgres
        let regclass = dialect.literal(dialect.qualified(table))
        let result = try await read(PostgresOps.keySQL(regclass: regclass))
        guard var key = PostgresOps.key(result) else { return nil }
        // Generated columns can't be written (12+; older servers have none).
        if let generated = try? await read(
            "SELECT attname FROM pg_attribute WHERE attrelid = to_regclass(\(regclass)) AND attnum > 0 AND NOT attisdropped AND attgenerated <> ''")
        {
            key.readOnlyColumns = Set(generated.rows.compactMap { $0.first ?? nil })
        }
        return key
    }

    package func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        try await exclusive {
            guard let connection else { throw DatabaseError.notConnected }
            let logger = Logger(label: "overterm.database")
            do {
                _ = try await connection.simpleQuery("BEGIN").get()
                for (index, statement) in statements.enumerated() {
                    let metadata = try await connection.query(PostgresQuery(unsafeSQL: statement.sql), logger: logger) { _ in }.get()
                    let changed = metadata.rows ?? 0
                    guard changed == statement.expectedRows else {
                        throw DatabaseError.failed(EditApplyError.wrongCount(index: index, changed: changed, sql: statement.sql))
                    }
                }
                _ = try await connection.simpleQuery("COMMIT").get()
            } catch {
                _ = try? await connection.simpleQuery("ROLLBACK").get()
                if let error = error as? DatabaseError { throw error }
                throw DatabaseError.failed(Self.describe(error) + " — nothing was saved.")
            }
        }
    }

    // MARK: Users and roles

    package func users() async throws -> Monitored<[DatabaseUser]> {
        if isRedshift {
            let users = try await read(PostgresOps.redshiftUsersSQL)
            let groups = (try? await read(PostgresOps.redshiftGroupsSQL)) ?? QueryResult()
            return .value(PostgresOps.redshiftUsers(users, groups: groups))
        }
        return .value(PostgresOps.users(try await read(PostgresOps.usersSQL)))
    }

    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        let name = DatabaseDrivers.literal(user.name)
        if isRedshift {
            do {
                return .value(PostgresOps.grants(try await read(PostgresOps.redshiftGrantsSQL(name))))
            } catch {
                return .unavailable(MonitorGap(reason: "Redshift's svv_relation_privileges couldn't be read: \(error.localizedDescription)"))
            }
        }
        return .value(PostgresOps.grants(try await read(PostgresOps.grantsSQL(name))))
    }

    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        try await exclusive {
            guard let connection else { throw DatabaseError.notConnected }
            for statement in statements {
                do {
                    _ = try await connection.simpleQuery(statement.sql).get()
                } catch {
                    throw DatabaseError.failed(statement.scrub(Self.describe(error)))
                }
            }
        }
    }
}

/// Why a Save stopped, said with the statement as it is shown.
package enum EditApplyError {
    package static func wrongCount(index: Int, changed: Int, sql: String) -> String {
        "Statement \(index + 1) changed \(changed) rows, not 1 — the row has changed or gone since it was read. Nothing was saved.\n\(sql)"
    }
}

extension UserStatement {
    /// An error's text with what the mask hides taken out — a server that
    /// quotes the statement back never shows the password.
    package func scrub(_ message: String) -> String {
        guard sql != shown else { return message }
        // What differs between the two is the secret's literal.
        let common = zip(sql, shown).prefix { $0 == $1 }.count
        let tail = zip(sql.reversed(), shown.reversed()).prefix { $0 == $1 }.count
        let start = sql.index(sql.startIndex, offsetBy: common)
        let end = sql.index(sql.endIndex, offsetBy: -min(tail, sql.count - common))
        let secret = String(sql[start..<end])
        guard !secret.isEmpty else { return message }
        var scrubbed = message.replacingOccurrences(of: secret, with: "••••")
        // The secret without its quotes, as a server may say it.
        let bare = secret.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if bare.count >= 3 { scrubbed = scrubbed.replacingOccurrences(of: bare, with: "••••") }
        return scrubbed
    }
}

/// PostgreSQL's and Redshift's statements for the Server and Users pages,
/// and their answers read. Pure.
package enum PostgresOps {
    // MARK: Statements

    package static let overviewSQL = """
        SELECT version() AS version, current_setting('server_version') AS server_version,
          EXTRACT(EPOCH FROM now() - pg_postmaster_start_time())::float8 AS uptime,
          (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend')::int8 AS connections,
          current_setting('max_connections')::int8 AS max_connections,
          (SELECT sum(blks_hit)::float8 / NULLIF(sum(blks_hit) + sum(blks_read), 0) FROM pg_stat_database) AS cache_hit,
          pg_is_in_recovery() AS replica,
          CASE WHEN pg_is_in_recovery() THEN EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())::float8 END AS lag,
          (SELECT count(*) FROM pg_stat_replication)::int8 AS replicas,
          current_database() AS database, pg_database_size(current_database()) AS database_size,
          (SELECT sum(xact_commit)::int8 FROM pg_stat_database) AS commits,
          (SELECT sum(xact_rollback)::int8 FROM pg_stat_database) AS rollbacks,
          (SELECT sum(deadlocks)::int8 FROM pg_stat_database) AS deadlocks
        """

    package static let redshiftOverviewSQL = """
        SELECT version() AS version, current_database() AS database,
          (SELECT count(*) FROM stv_sessions)::int8 AS connections,
          (SELECT count(*) FROM stv_recents WHERE status = 'Running')::int8 AS running
        """

    package static let activitySQL = """
        SELECT pid::text AS id, usename AS user, datname AS database, client_addr::text AS client, application_name AS application,
          state, wait_event_type, wait_event, query,
          EXTRACT(EPOCH FROM now() - CASE WHEN state = 'active' THEN query_start ELSE COALESCE(state_change, backend_start) END)::float8 AS seconds,
          pid = pg_backend_pid() AS own
        FROM pg_stat_activity WHERE backend_type = 'client backend'
        ORDER BY state = 'active' DESC, seconds DESC NULLS LAST
        """

    package static let redshiftActivitySQL = """
        SELECT s.process::text AS id, TRIM(s.user_name) AS user, TRIM(s.db_name) AS database,
          CASE WHEN r.pid IS NULL THEN 'idle' ELSE 'active' END AS state, TRIM(r.query) AS query,
          CASE WHEN r.pid IS NULL THEN DATEDIFF(second, s.starttime, GETDATE()) ELSE r.duration / 1000000.0 END AS seconds,
          s.process = pg_backend_pid() AS own
        FROM stv_sessions s LEFT JOIN stv_recents r ON r.pid = s.process AND r.status = 'Running'
        ORDER BY 4, 6 DESC
        """

    /// Ranked by total time and by mean: the hundred of each.
    package static func slowSQL(version: Int) -> String {
        let (total, mean) = version >= 130000 || version == 0 ? ("total_exec_time", "mean_exec_time") : ("total_time", "mean_time")
        let select = """
            SELECT s.queryid::text AS id, d.datname AS database, r.rolname AS user, s.calls, s.\(total) / 1000 AS total,
              s.\(mean) / 1000 AS mean, s.rows, s.query
            FROM pg_stat_statements s LEFT JOIN pg_database d ON d.oid = s.dbid LEFT JOIN pg_roles r ON r.oid = s.userid
            """
        return "(\(select) ORDER BY s.\(total) DESC LIMIT 100) UNION (\(select) ORDER BY s.\(mean) DESC LIMIT 100)"
    }

    package static let redshiftSlowSQL = """
        SELECT md5(query_text) AS id, database_name AS database, COUNT(*) AS calls, SUM(elapsed_time) / 1000000.0 AS total,
          AVG(elapsed_time) / 1000000.0 AS mean, SUM(returned_rows) AS rows, query_text AS query
        FROM sys_query_history GROUP BY query_text, database_name ORDER BY total DESC LIMIT 100
        """

    package static func statementsMissing(database: String) -> MonitorGap {
        MonitorGap(
            reason: "pg_stat_statements isn't installed\(database.isEmpty ? "" : " in \(database)") — it is PostgreSQL's record of statements.",
            fix: "shared_preload_libraries = 'pg_stat_statements' in postgresql.conf (a restart), then: CREATE EXTENSION pg_stat_statements;")
    }

    package static let locksSQL = """
        SELECT w.pid::text AS waiting, w.usename AS waiting_user, w.query AS waiting_query,
          b.pid::text AS blocking, b.usename AS blocking_user, b.query AS blocking_query,
          (SELECT string_agg(DISTINCT l.mode || COALESCE(' on ' || l.relation::regclass::text, ' (' || l.locktype || ')'), ', ')
             FROM pg_locks l WHERE l.pid = w.pid AND NOT l.granted) AS lock,
          EXTRACT(EPOCH FROM now() - w.state_change)::float8 AS seconds
        FROM pg_stat_activity w
        CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS bp(pid)
        JOIN pg_stat_activity b ON b.pid = bp.pid
        ORDER BY seconds DESC NULLS LAST
        """

    package static let redshiftLocksSQL = """
        SELECT w.pid::text AS waiting, TRIM(w.txn_owner) AS waiting_user, h.pid::text AS blocking, TRIM(h.txn_owner) AS blocking_user,
          w.lock_mode || ' on ' || w.relation AS lock, DATEDIFF(second, w.txn_start, GETDATE()) AS seconds
        FROM svv_transactions w JOIN svv_transactions h ON h.relation = w.relation AND h.granted AND h.pid <> w.pid
        WHERE NOT w.granted
        """

    package static let databaseSizesSQL = """
        SELECT datname AS name, CASE WHEN has_database_privilege(datname, 'CONNECT') THEN pg_database_size(datname) END AS bytes
        FROM pg_database WHERE NOT datistemplate ORDER BY bytes DESC NULLS LAST
        """

    package static let tableSizesSQL = """
        SELECT n.nspname AS schema, c.relname AS name, pg_total_relation_size(c.oid) AS bytes,
          'rows ≈ ' || GREATEST(c.reltuples, 0)::int8 || ', data ' || pg_size_pretty(pg_relation_size(c.oid)) AS detail
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'm', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%'
        ORDER BY bytes DESC NULLS LAST LIMIT 50
        """

    package static let indexSizesSQL = """
        SELECT n.nspname AS schema, c.relname AS name, pg_relation_size(c.oid) AS bytes, 'on ' || t.relname AS detail
        FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid JOIN pg_class t ON t.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%'
        ORDER BY bytes DESC NULLS LAST LIMIT 50
        """

    package static let redshiftTablesSQL = """
        SELECT "schema" AS schema, "table" AS name, size::int8 * 1048576 AS bytes, 'rows ≈ ' || tbl_rows AS detail
        FROM svv_table_info ORDER BY size DESC LIMIT 50
        """

    /// A table's unique indexes over plain columns, the primary key first.
    package static func keySQL(regclass: String) -> String {
        """
        SELECT n.nspname AS schema, c.relname AS name, i.indexrelid::regclass::text AS index, i.indisprimary AS is_primary,
          a.attname AS column, a.attnotnull AS not_null
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_index i ON i.indrelid = c.oid
        CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
        WHERE c.oid = to_regclass(\(regclass)) AND i.indisunique AND i.indisvalid AND i.indpred IS NULL AND i.indexprs IS NULL
        ORDER BY i.indisprimary DESC, i.indexrelid, k.ord
        """
    }

    /// `pg_roles`, never `pg_authid`: its password column is always `********`,
    /// and isn't asked for anyway.
    package static let usersSQL = """
        SELECT r.rolname AS name, r.rolsuper, r.rolinherit, r.rolcreaterole, r.rolcreatedb, r.rolcanlogin, r.rolreplication, r.rolbypassrls,
          r.rolconnlimit, r.rolvaliduntil::text AS valid_until,
          COALESCE((SELECT array_to_json(array_agg(b.rolname ORDER BY b.rolname))::text
             FROM pg_auth_members m JOIN pg_roles b ON b.oid = m.roleid WHERE m.member = r.oid), '[]') AS member_of
        FROM pg_roles r WHERE r.rolname !~ '^pg_' ORDER BY r.rolcanlogin DESC, r.rolname
        """

    package static let redshiftUsersSQL = "SELECT usename AS name, usesuper AS rolsuper, usecreatedb AS rolcreatedb, valuntil::text AS valid_until FROM pg_user ORDER BY usename"
    package static let redshiftGroupsSQL = "SELECT g.groname AS role, u.usename AS member FROM pg_group g LEFT JOIN pg_user u ON u.usesysid = ANY(g.grolist)"

    /// What a role may do, from the catalog's ACLs (readable by anyone), and
    /// what it owns — in the connection's database, plus every database's.
    package static func grantsSQL(_ name: String) -> String {
        let system = "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%'"
        let privileges = "string_agg(a.privilege_type, ', ' ORDER BY a.privilege_type) AS privileges, bool_or(a.is_grantable) AS grantable"
        return """
            WITH r AS (SELECT oid FROM pg_roles WHERE rolname = \(name))
            SELECT 'database' AS kind, d.datname AS object, NULL::text AS schema_name, d.datname::text AS object_name, \(privileges)
              FROM pg_database d, aclexplode(d.datacl) a, r WHERE a.grantee = r.oid GROUP BY d.datname
            UNION ALL SELECT 'owner', 'database ' || d.datname, NULL, NULL, 'OWNER', false FROM pg_database d, r WHERE d.datdba = r.oid
            UNION ALL SELECT 'schema', n.nspname, NULL, n.nspname::text, \(privileges)
              FROM pg_namespace n, aclexplode(n.nspacl) a, r WHERE a.grantee = r.oid GROUP BY n.nspname
            UNION ALL SELECT 'owner', 'schema ' || n.nspname, NULL, NULL, 'OWNER', false FROM pg_namespace n, r WHERE n.nspowner = r.oid AND \(system)
            UNION ALL SELECT 'table', n.nspname || '.' || c.relname, n.nspname::text, c.relname::text, \(privileges)
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a, r
              WHERE a.grantee = r.oid AND c.relkind IN ('r', 'v', 'm', 'p', 'f') GROUP BY n.nspname, c.relname
            UNION ALL SELECT 'owner', 'table ' || n.nspname || '.' || c.relname, NULL, NULL, 'OWNER', false
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, r
              WHERE c.relowner = r.oid AND c.relkind IN ('r', 'v', 'm', 'p', 'f') AND \(system)
            UNION ALL SELECT 'role', b.rolname, NULL, NULL, 'MEMBER', m.admin_option FROM pg_auth_members m JOIN pg_roles b ON b.oid = m.roleid, r
              WHERE m.member = r.oid
            ORDER BY 1, 2
            """
    }

    package static func redshiftGrantsSQL(_ name: String) -> String {
        """
        SELECT 'table' AS kind, namespace_name || '.' || relation_name AS object, namespace_name AS schema_name, relation_name AS object_name,
          LISTAGG(privilege_type, ', ') WITHIN GROUP (ORDER BY privilege_type) AS privileges, bool_or(admin_option) AS grantable
        FROM svv_relation_privileges WHERE identity_name = \(name) GROUP BY namespace_name, relation_name ORDER BY 2
        """
    }

    // MARK: Answers

    package static func overview(_ result: QueryResult, redshift: Bool) -> ServerOverview {
        guard let row = ResultRow.rows(of: result).first else { return ServerOverview() }
        var facts: [ServerFact] = []
        let version = row["version"] ?? ""
        if redshift {
            facts.append(ServerFact(title: "Version", value: version.components(separatedBy: "Redshift ").last.map { "Redshift \($0)" } ?? version))
            facts.append(ServerFact(title: "Sessions", value: row["connections"] ?? "—", detail: row["running"].map { "\($0) running" }))
            facts.append(ServerFact(title: "Database", value: row["database"] ?? "—"))
            return ServerOverview(facts: facts)
        }
        facts.append(ServerFact(title: "Version", value: row["server_version"] ?? "—", detail: version.components(separatedBy: " on ").last))
        facts.append(ServerFact(title: "Uptime", value: row.double("uptime").map(OpsText.duration) ?? "—"))
        if let used = row.int("connections"), let max = row.int("max_connections") {
            facts.append(ServerFact(title: "Connections", value: "\(used) / \(max)", detail: OpsText.percent(Double(used) / Double(Swift.max(max, 1))) + " used"))
        }
        facts.append(ServerFact(title: "Cache hit", value: row.double("cache_hit").map(OpsText.percent) ?? "—", detail: "shared buffers, every database"))
        if let size = row.int64("database_size") {
            facts.append(ServerFact(title: "Database", value: OpsText.bytes(size), detail: row["database"]))
        }
        if row.bool("replica") {
            facts.append(ServerFact(title: "Replica", value: row.double("lag").map { "\(OpsText.duration($0)) behind" } ?? "replaying", detail: "since the last replayed commit"))
        } else {
            facts.append(ServerFact(title: "Role", value: "Primary", detail: row.int("replicas").map { "\($0) replica\($0 == 1 ? "" : "s") streaming" }))
        }
        facts.append(ServerFact(title: "Transactions", value: row["commits"] ?? "—", detail: row["rollbacks"].map { "\($0) rolled back" }))
        facts.append(ServerFact(title: "Deadlocks", value: row["deadlocks"] ?? "—", detail: "since the statistics were reset"))
        return ServerOverview(facts: facts)
    }

    package static func activity(_ result: QueryResult) -> [DatabaseActivity] {
        ResultRow.rows(of: result).map { row in
            let wait = [row["wait_event_type"], row["wait_event"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            return DatabaseActivity(
                id: row["id"] ?? "", user: row["user"], database: row["database"], client: row["client"], application: row["application"].flatMap { $0.isEmpty ? nil : $0 },
                state: row["state"], statement: row["query"].flatMap { $0.isEmpty ? nil : $0 }, seconds: row.double("seconds"),
                waiting: wait.isEmpty ? nil : wait, isOwn: row.bool("own"))
        }
    }

    package static func slowQueries(_ result: QueryResult) -> [SlowQuery] {
        ResultRow.rows(of: result).enumerated().map { index, row in
            SlowQuery(
                id: (row["id"] ?? "") + "\u{1}\(row["database"] ?? "")\u{1}\(row["user"] ?? "")\u{1}\(index)", statement: row["query"] ?? "",
                calls: row.int("calls") ?? 0, total: row.double("total") ?? 0, mean: row.double("mean") ?? 0, rows: row.int("rows"),
                database: row["database"], user: row["user"])
        }
        .sorted { $0.total > $1.total }
    }

    package static func locks(_ result: QueryResult) -> [LockWait] {
        ResultRow.rows(of: result).map { row in
            LockWait(
                waiting: row["waiting"] ?? "", waitingUser: row["waiting_user"], waitingStatement: row["waiting_query"], blocking: row["blocking"] ?? "",
                blockingUser: row["blocking_user"], blockingStatement: row["blocking_query"], lock: row["lock"], seconds: row.double("seconds"))
        }
    }

    package static func sizes(_ result: QueryResult) -> [SizeEntry] {
        ResultRow.rows(of: result).compactMap { row in
            guard let name = row["name"] else { return nil }
            return SizeEntry(name: name, schema: row["schema"], bytes: row.int64("bytes") ?? 0, detail: row["detail"])
        }
    }

    /// The first unique index whose columns can't be NULL — the primary key
    /// when there is one (its rows come first).
    package static func key(_ result: QueryResult) -> TableKey? {
        var order: [String] = []
        var indexes: [String: (schema: String, table: String, primary: Bool, columns: [String], notNull: Bool)] = [:]
        for row in ResultRow.rows(of: result) {
            guard let index = row["index"], let column = row["column"] else { continue }
            if indexes[index] == nil {
                order.append(index)
                indexes[index] = (row["schema"] ?? "", row["name"] ?? "", row.bool("is_primary"), [], true)
            }
            indexes[index]?.columns.append(column)
            if !row.bool("not_null") { indexes[index]?.notNull = false }
        }
        for name in order {
            guard let index = indexes[name], index.primary || index.notNull else { continue }
            return TableKey(table: TableName(schema: index.schema, name: index.table), kind: index.primary ? .primary : .unique(name), columns: index.columns)
        }
        return nil
    }

    package static func users(_ result: QueryResult) -> [DatabaseUser] {
        ResultRow.rows(of: result).map { row in
            var attributes: [String] = []
            if row.bool("rolcreatedb") { attributes.append("creates databases") }
            if row.bool("rolcreaterole") { attributes.append("creates roles") }
            if row.bool("rolreplication") { attributes.append("replication") }
            if row.bool("rolbypassrls") { attributes.append("bypasses row security") }
            if row["rolinherit"] != nil, !row.bool("rolinherit") { attributes.append("doesn't inherit") }
            let limit = row.int("rolconnlimit").flatMap { $0 < 0 ? nil : $0 }
            let members = (row["member_of"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String]) ?? []
            let login = row.bool("rolcanlogin")
            return DatabaseUser(
                name: row["name"] ?? "", isRole: !login, canLogin: login, superuser: row.bool("rolsuper"), attributes: attributes,
                validUntil: row["valid_until"].flatMap { $0 == "infinity" ? nil : $0 }, connectionLimit: limit, memberOf: members)
        }
    }

    package static func redshiftUsers(_ users: QueryResult, groups: QueryResult) -> [DatabaseUser] {
        var memberships: [String: [String]] = [:]
        var groupNames: [String] = []
        for row in ResultRow.rows(of: groups) {
            guard let group = row["role"] else { continue }
            if !groupNames.contains(group) { groupNames.append(group) }
            if let member = row["member"] { memberships[member, default: []].append(group) }
        }
        let people = ResultRow.rows(of: users).map { row in
            let name = row["name"] ?? ""
            return DatabaseUser(
                name: name, superuser: row.bool("rolsuper"), attributes: row.bool("rolcreatedb") ? ["creates databases"] : [],
                validUntil: row["valid_until"].flatMap { $0 == "infinity" ? nil : $0 }, memberOf: memberships[name]?.sorted() ?? [])
        }
        return people + groupNames.sorted().map { DatabaseUser(name: $0, isRole: true, canLogin: false) }
    }

    package static func grants(_ result: QueryResult) -> [DatabaseGrant] {
        ResultRow.rows(of: result).map { row in
            let kind = row["kind"] ?? ""
            var target: GrantTarget?
            if let name = row["object_name"] {
                switch kind {
                case "database": target = .database(name)
                case "schema": target = .schema(name)
                case "table": target = .table(TableName(schema: row["schema_name"], name: name))
                default: break
                }
            }
            return DatabaseGrant(
                kind: kind, object: row["object"] ?? "",
                privileges: (row["privileges"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, grantable: row.bool("grantable"),
                target: target)
        }
    }
}
