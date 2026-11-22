import Foundation
import OracleNIO

/// Oracle's Server page, rows edited, users and roles — from its dynamic
/// performance views (`v$session`, `v$sqlstats`, `v$instance`…) and its
/// dictionary (`dba_*`, `all_*`), through the driver's one connection. A user
/// without the privilege to read them is told which grant gives it
/// (SELECT_CATALOG_ROLE). docs/architecture.md, Database: Server page.
extension OracleDriver: DatabaseMonitoring, DatabaseTableEditing, DatabaseUserManagement {
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { MonitorPart.allCases }

    /// `ALTER SYSTEM CANCEL SQL` and `KILL SESSION`, for an id that is
    /// `sid,serial#`; one of Overterm's own connections only cancelled.
    package static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        OracleOps.stops(for: session)
    }

    package func editDialect() async -> SQLDialect { .oracle }
    package func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own
    package func userStatements() async -> any UserStatementMaking { OracleUserStatements(owner: config.user.uppercased()) }

    /// A new row sets a column at least (Oracle has no DEFAULT VALUES); the
    /// rest is SQL's, in Oracle's quoting.
    package func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try OracleOps.editStatements(edits, rows: rows, result: result)
    }

    package func editSaveNote() async -> String { "In one transaction: if any statement fails, none is kept. " + OracleOps.emptyIsNull }

    private func read(_ sql: String, limit: Int = 10_000) async throws -> QueryResult {
        try await execute(sql, limit: limit)
    }

    /// This connection's own SID, once (SYS_CONTEXT needs no privilege).
    private func identify() async -> String? {
        if let ownSession { return ownSession }
        let sid = (try? await read("SELECT SYS_CONTEXT('USERENV', 'SID') AS sid FROM dual", limit: 1))?.rows.first?.first ?? nil
        ownSession = sid
        return sid
    }

    /// A v$ or dba_ view this user may not read: said, with the grant.
    private func gap(_ error: Error, what: String) -> MonitorGap? {
        guard OracleOps.isPrivilege(error) else { return nil }
        return MonitorGap(
            reason: "This user can't read \(what): \(error.localizedDescription)",
            fix: "GRANT SELECT_CATALOG_ROLE TO \(config.user.isEmpty ? "<this user>" : config.user.uppercased()); (by a DBA — or SELECT ANY DICTIONARY)")
    }

    // MARK: Monitoring

    package func overview() async throws -> ServerOverview {
        do {
            let result: QueryResult
            do {
                result = try await read(OracleOps.overviewSQL(fullVersion: true), limit: 1)
            } catch  where !OracleOps.isPrivilege(error) {
                // version_full is 18c's; before it, version.
                result = try await read(OracleOps.overviewSQL(fullVersion: false), limit: 1)
            }
            return OracleOps.overview(result)
        } catch {
            guard let gap = gap(error, what: "v$instance") else { throw error }
            // What every user may read: the version and where it is.
            let basic = try? await read(
                "SELECT banner_full AS version, SYS_CONTEXT('USERENV', 'CON_NAME') AS container, SYS_CONTEXT('USERENV', 'DB_NAME') AS db_name FROM v$version WHERE ROWNUM = 1",
                limit: 1)
            var overview = basic.map(OracleOps.overview) ?? ServerOverview()
            overview.notes.append(gap.reason + " — " + (gap.fix ?? ""))
            return overview
        }
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        do {
            return .value(OracleOps.activity(try await read(OracleOps.activitySQL)))
        } catch {
            guard let gap = gap(error, what: "v$session") else { throw error }
            return .unavailable(gap)
        }
    }

    package func slowQueries() async throws -> Monitored<[SlowQuery]> {
        do {
            let byTotal = try await read(OracleOps.slowSQL(byMean: false), limit: 100)
            let byMean = try await read(OracleOps.slowSQL(byMean: true), limit: 100)
            return .value(OracleOps.slowQueries([byTotal, byMean]))
        } catch {
            guard let gap = gap(error, what: "v$sqlstats") else { throw error }
            return .unavailable(gap)
        }
    }

    package func locks() async throws -> Monitored<[LockWait]> {
        do {
            return .value(PostgresOps.locks(try await read(OracleOps.locksSQL)))
        } catch {
            guard let gap = gap(error, what: "v$session") else { throw error }
            return .unavailable(gap)
        }
    }

    /// dba_segments; without it, user_segments — this user's own, said.
    package func sizes() async throws -> Monitored<DatabaseSizes> {
        var sizes = DatabaseSizes()
        do {
            sizes.databases = PostgresOps.sizes(try await read(OracleOps.schemaSizesSQL, limit: 50))
            sizes.tables = PostgresOps.sizes(try await read(OracleOps.segmentSizesSQL(view: "dba_segments", index: false), limit: 50))
            sizes.indexes = PostgresOps.sizes(try await read(OracleOps.segmentSizesSQL(view: "dba_segments", index: true), limit: 50))
            sizes.notes.append("“Databases” are schemas here: each owner's segments together. Oracle's own schemas' tables are left out.")
        } catch {
            guard OracleOps.isPrivilege(error) else { throw error }
            sizes.tables = PostgresOps.sizes(try await read(OracleOps.segmentSizesSQL(view: "user_segments", index: false), limit: 50))
            sizes.indexes = PostgresOps.sizes(try await read(OracleOps.segmentSizesSQL(view: "user_segments", index: true), limit: 50))
            sizes.notes.append("Only this user's own segments (user_segments): every schema's needs SELECT_CATALOG_ROLE (by a DBA).")
        }
        return .value(sizes)
    }

    /// `ALTER SYSTEM CANCEL SQL` (the statement stops) or `KILL SESSION …
    /// IMMEDIATE` — the ALTER SYSTEM privilege's.
    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly(terminate ? "KILL SESSION" : "CANCEL SQL") }
        guard let statement = OracleOps.stopStatement(session, terminate: terminate) else { throw DatabaseError.failed("No session \(session).") }
        let own = await identify()
        guard session.split(separator: ",").first.map(String.init) != own else { throw DatabaseError.failed("That is this connection's own session.") }
        // One of Overterm's own connections ended under it hangs or traps
        // OracleNIO (a statement on a killed session never comes back):
        // its statement is cancelled, the session closed from the panel.
        if terminate {
            let parts = session.split(separator: ",")
            let program = try? await read("SELECT program FROM v$session WHERE sid = \(parts[0]) AND serial# = \(parts[1])", limit: 1).rows.first?.first ?? nil
            if program == OracleOps.programName {
                throw DatabaseError.failed(
                    "\(session) is one of Overterm's own connections: cancel its statement, or disconnect it in the Database panel — ending it from here would leave it hanging.")
            }
        }
        do {
            _ = try await read(statement, limit: 1)
        } catch  where OracleOps.isPrivilege(error) {
            throw DatabaseError.failed("\(error.localizedDescription) — cancelling another session needs ALTER SYSTEM.")
        }
    }

    // MARK: Editing rows

    /// The primary key, else an enabled unique key over NOT NULL columns,
    /// else — a heap table's — its ROWID. A name as written first, then as
    /// Oracle reads it unquoted (upper-case).
    package func key(of table: TableName) async throws -> TableKey? {
        let current = try await read("SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM dual", limit: 1).rows.first?.first ?? nil
        for candidate in OracleOps.candidates(table, currentSchema: current ?? "") {
            let owner = DatabaseDrivers.literal(candidate.schema ?? "")
            let name = DatabaseDrivers.literal(candidate.name)
            let found = try await read("SELECT iot_type FROM all_tables WHERE owner = \(owner) AND table_name = \(name)", limit: 1)
            guard let row = found.rows.first else { continue }
            let constraints = try await read(OracleOps.keySQL(owner: owner, table: name))
            let columns = try await read(OracleOps.columnsSQL(owner: owner, table: name))
            return OracleOps.key(candidate, heap: (row.first ?? nil) == nil, constraints: constraints, columns: columns)
        }
        return nil
    }

    /// In one transaction: each statement must change its one row, else
    /// all of it is rolled back. The session's date and number formats are
    /// set to the ones the grid shows values in, then put back.
    package func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        try await exclusive {
            guard let connection else { throw DatabaseError.notConnected }
            let saved = (try? await Self.rows(OracleOps.nlsReadSQL, on: connection)) ?? []
            var options = StatementOptions()
            options.autoCommit = false
            do {
                for statement in OracleOps.nlsSetStatements { _ = try await connection.execute(OracleStatement(unsafeSQL: statement), options: options) }
                for (index, statement) in statements.enumerated() {
                    let rows = try await connection.execute(OracleStatement(unsafeSQL: statement.sql), options: options)
                    let changed = try await rows.affectedRows
                    guard changed == statement.expectedRows else {
                        throw DatabaseError.failed(EditApplyError.wrongCount(index: index, changed: changed, sql: statement.sql))
                    }
                }
                try await connection.commit()
            } catch {
                try? await connection.rollback()
                await Self.restore(saved, on: connection)
                if let error = error as? DatabaseError { throw error }
                throw DatabaseError.failed(
                    Self.describe(error, host: config.host, port: config.port ?? 1521, service: config.database) + " — nothing was saved.")
            }
            await Self.restore(saved, on: connection)
        }
    }

    private static func restore(_ saved: [[String?]], on connection: OracleConnection) async {
        for statement in OracleOps.nlsRestoreStatements(saved) {
            _ = try? await connection.execute(OracleStatement(unsafeSQL: statement))
        }
    }

    /// A statement's rows as text, on the connection itself (inside `exclusive`).
    private static func rows(_ sql: String, on connection: OracleConnection) async throws -> [[String?]] {
        let rows = try await connection.execute(OracleStatement(unsafeSQL: sql))
        var out: [[String?]] = []
        for try await row in rows {
            var cells: [String?] = []
            var iterator = row.makeIterator()
            while let cell = iterator.next() { cells.append(text(cell)) }
            out.append(cells)
        }
        return out
    }

    // MARK: Users and roles

    /// dba_users (never a password column — none is asked for), the roles,
    /// who is granted which.
    package func users() async throws -> Monitored<[DatabaseUser]> {
        do {
            let users = try await read(OracleOps.usersSQL)
            let roles = try await read(OracleOps.rolesSQL)
            let memberships = (try? await read(OracleOps.roleGrantsSQL, limit: 100_000)) ?? QueryResult()
            return .value(OracleOps.users(users, roles: roles, memberships: memberships))
        } catch {
            guard OracleOps.isPrivilege(error) else { throw error }
            return .unavailable(
                MonitorGap(
                    reason: "This user may not read Oracle's users (dba_users): \(error.localizedDescription)",
                    fix: "GRANT SELECT_CATALOG_ROLE TO \(config.user.isEmpty ? "<this user>" : config.user.uppercased()); (by a DBA)"))
        }
    }

    /// System privileges, roles, object grants — dba_*; this user's own
    /// through user_* when dba_* can't be read.
    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        do {
            return .value(OracleOps.grants(try await read(OracleOps.grantsSQL(DatabaseDrivers.literal(user.name)))))
        } catch {
            guard OracleOps.isPrivilege(error) else { throw error }
            let me = (try? await read("SELECT USER FROM dual", limit: 1))?.rows.first?.first ?? nil
            if me == user.name, let own = try? await read(OracleOps.ownGrantsSQL) {
                return .value(OracleOps.grants(own))
            }
            return .unavailable(
                MonitorGap(
                    reason: "This user may not read another's grants (dba_sys_privs, dba_tab_privs): \(error.localizedDescription)",
                    fix: "GRANT SELECT_CATALOG_ROLE TO \(config.user.isEmpty ? "<this user>" : config.user.uppercased()); (by a DBA)"))
        }
    }

    /// Sent once each, in order (DDL commits itself); an error said with the
    /// password scrubbed.
    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        try await exclusive {
            guard let connection else { throw DatabaseError.notConnected }
            for statement in statements {
                do {
                    _ = try await connection.execute(OracleStatement(unsafeSQL: statement.sql))
                } catch {
                    throw DatabaseError.failed(statement.scrub(Self.describe(error, host: config.host, port: config.port ?? 1521, service: config.database)))
                }
            }
        }
    }
}

/// Oracle's statements for the Server and Users pages, and their answers
/// read. Pure.
package enum OracleOps {
    /// What Overterm's connections call themselves (`v$session.program`).
    package static let programName = "Overterm"

    /// The statement that stops a session — nil unless the id is `sid,serial#`.
    package static func stopStatement(_ session: String, terminate: Bool) -> String? {
        guard isSession(session) else { return nil }
        return terminate ? "ALTER SYSTEM KILL SESSION '\(session)' IMMEDIATE" : "ALTER SYSTEM CANCEL SQL '\(session)'"
    }

    /// Cancel the statement; end the session — not one of Overterm's own,
    /// which OracleNIO would wait on forever (disconnected in the panel instead).
    package static func stops(for session: DatabaseActivity) -> [SessionStop] {
        guard let cancel = stopStatement(session.id, terminate: false), let kill = stopStatement(session.id, terminate: true) else { return [] }
        var stops = [
            SessionStop(
                terminate: false, menu: "Cancel Statement…", title: "Cancel session \(session.id)'s statement?", command: cancel,
                effect: SessionStop.said(session) + "\n\nThe statement stops with ORA-01013; the session stays.", button: "Cancel Statement")
        ]
        if session.application != programName {
            stops.append(
                SessionStop(
                    terminate: true, menu: "Kill Session…", title: "Kill session \(session.id)?", command: kill,
                    effect: SessionStop.said(session) + "\n\nIts connection is ended; what it hadn't committed is rolled back.", button: "Kill Session"))
        }
        return stops
    }

    /// ORA-00942 (no such view — or no privilege to see it), ORA-01031
    /// (insufficient privileges), ORA-01039.
    package static func isPrivilege(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return ["ORA-00942", "ORA-01031", "ORA-01039", "insufficient privileges", "does not exist"].contains { text.contains($0) }
    }

    /// `sid,serial#`, digits only — what goes into ALTER SYSTEM's literal.
    package static func isSession(_ id: String) -> Bool {
        id.range(of: #"^[0-9]{1,10},[0-9]{1,10}$"#, options: .regularExpression) != nil
    }

    // MARK: Monitoring statements

    package static func overviewSQL(fullVersion: Bool) -> String {
        """
        SELECT \(fullVersion ? "i.version_full" : "i.version") AS version, i.instance_name, i.host_name,
          ROUND((SYSDATE - i.startup_time) * 86400) AS uptime, d.name AS db_name, d.database_role AS role, d.open_mode,
          SYS_CONTEXT('USERENV', 'CON_NAME') AS container,
          (SELECT COUNT(*) FROM v$session WHERE type = 'USER') AS sessions,
          (SELECT COUNT(*) FROM v$session WHERE type = 'USER' AND status = 'ACTIVE') AS active,
          (SELECT value FROM v$parameter WHERE name = 'sessions') AS max_sessions,
          (SELECT COUNT(*) FROM v$process) AS processes,
          (SELECT value FROM v$parameter WHERE name = 'processes') AS max_processes,
          (SELECT SUM(CASE name WHEN 'physical reads cache' THEN value END) FROM v$sysstat) AS physical_reads,
          (SELECT SUM(CASE WHEN name IN ('consistent gets from cache', 'db block gets from cache') THEN value END) FROM v$sysstat) AS logical_reads,
          (SELECT SUM(CASE name WHEN 'user commits' THEN value END) FROM v$sysstat) AS commits,
          (SELECT SUM(CASE name WHEN 'user rollbacks' THEN value END) FROM v$sysstat) AS rollbacks
        FROM v$instance i CROSS JOIN v$database d
        """
    }

    /// Client sessions, the busy first; the statement from v$sql.
    package static let activitySQL = """
        SELECT s.sid || ',' || s.serial# AS id, s.username AS "user", s.schemaname AS "database", s.machine AS client,
          s.program AS application, s.status AS state, CASE WHEN s.wait_class <> 'Idle' THEN s.event END AS waiting,
          s.last_call_et AS seconds,
          (SELECT q.sql_text FROM v$sql q WHERE q.sql_id = s.sql_id AND q.child_number = s.sql_child_number AND ROWNUM = 1) AS query,
          CASE WHEN s.sid = SYS_CONTEXT('USERENV', 'SID') THEN 1 ELSE 0 END AS own
        FROM v$session s WHERE s.type = 'USER'
        ORDER BY CASE s.status WHEN 'ACTIVE' THEN 0 ELSE 1 END, s.last_call_et DESC
        """

    /// v$sqlstats, the hundred costliest by elapsed time — all of it, or a call's.
    package static func slowSQL(byMean: Bool) -> String {
        let order = byMean ? "elapsed_time / executions" : "elapsed_time"
        return """
            SELECT sql_id AS id, executions AS calls, elapsed_time / 1000000 AS total, elapsed_time / 1000000 / executions AS mean,
              rows_processed AS "rows", cpu_time / 1000000 AS cpu, buffer_gets, sql_text AS query
            FROM v$sqlstats WHERE executions > 0 ORDER BY \(order) DESC FETCH FIRST 100 ROWS ONLY
            """
    }

    /// Who waits on whom: v$session's blocking_session, the object from the
    /// row it waits on; an idle blocker's last statement (prev_sql_id).
    package static let locksSQL = """
        SELECT w.sid || ',' || w.serial# AS waiting, w.username AS waiting_user,
          (SELECT q.sql_text FROM v$sql q WHERE q.sql_id = w.sql_id AND ROWNUM = 1) AS waiting_query,
          b.sid || ',' || b.serial# AS blocking, b.username AS blocking_user,
          (SELECT q.sql_text FROM v$sql q WHERE q.sql_id = NVL(b.sql_id, b.prev_sql_id) AND ROWNUM = 1) AS blocking_query,
          w.event || (SELECT ' on ' || o.owner || '.' || o.object_name FROM all_objects o WHERE o.object_id = w.row_wait_obj# AND ROWNUM = 1) AS "lock",
          w.wait_time_micro / 1000000 AS seconds
        FROM v$session w JOIN v$session b ON b.sid = w.blocking_session
        WHERE w.blocking_session IS NOT NULL
        ORDER BY w.wait_time_micro DESC
        """

    package static let schemaSizesSQL = """
        SELECT owner AS name, SUM(bytes) AS "bytes", COUNT(*) || ' segments' AS detail
        FROM dba_segments GROUP BY owner ORDER BY 2 DESC FETCH FIRST 50 ROWS ONLY
        """

    /// The biggest tables or indexes — `dba_segments` (Oracle's own schemas
    /// left out) or `user_segments`, which has no owner.
    package static func segmentSizesSQL(view: String, index: Bool) -> String {
        let dba = view == "dba_segments"
        let owner = dba ? "s.owner" : "SYS_CONTEXT('USERENV', 'CURRENT_USER')"
        let type = index ? "s.segment_type LIKE 'INDEX%'" : "s.segment_type LIKE 'TABLE%'"
        let mine = dba ? " AND s.owner NOT IN (SELECT username FROM dba_users WHERE oracle_maintained = 'Y')" : ""
        let detail =
            index
            ? "'on ' || MIN((SELECT i.table_name FROM \(dba ? "dba_indexes" : "user_indexes") i WHERE \(dba ? "i.owner = s.owner AND " : "")i.index_name = s.segment_name))"
            : "MIN(s.segment_type) || ', ' || MIN(s.tablespace_name)"
        return """
            SELECT \(owner) AS "schema", s.segment_name AS name, SUM(s.bytes) AS "bytes", \(detail) AS detail
            FROM \(view) s WHERE \(type)\(mine)
            GROUP BY \(dba ? "s.owner, " : "")s.segment_name ORDER BY 3 DESC FETCH FIRST 50 ROWS ONLY
            """
    }

    // MARK: Editing statements

    /// A name as written, then as Oracle reads it unquoted.
    package static func candidates(_ table: TableName, currentSchema: String) -> [TableName] {
        let exact = TableName(schema: table.schema ?? currentSchema, name: table.name)
        let upper = TableName(schema: (table.schema ?? currentSchema).uppercased(), name: table.name.uppercased())
        return exact == upper ? [exact] : [exact, upper]
    }

    package static func keySQL(owner: String, table: String) -> String {
        """
        SELECT c.constraint_name AS "index", c.constraint_type AS kind, cc.column_name AS "column", tc.nullable
        FROM all_constraints c
        JOIN all_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
        JOIN all_tab_columns tc ON tc.owner = c.owner AND tc.table_name = c.table_name AND tc.column_name = cc.column_name
        WHERE c.owner = \(owner) AND c.table_name = \(table) AND c.constraint_type IN ('P', 'U') AND c.status = 'ENABLED'
        ORDER BY CASE c.constraint_type WHEN 'P' THEN 0 ELSE 1 END, c.constraint_name, cc.position
        """
    }

    package static func columnsSQL(owner: String, table: String) -> String {
        """
        SELECT c.column_name AS name, c.data_type AS type, c.data_type_owner AS type_owner, c.virtual_column AS virtual,
          (SELECT i.generation_type FROM all_tab_identity_cols i
            WHERE i.owner = c.owner AND i.table_name = c.table_name AND i.column_name = c.column_name) AS generation
        FROM all_tab_cols c WHERE c.owner = \(owner) AND c.table_name = \(table) AND c.hidden_column = 'NO'
        """
    }

    /// Types whose grid text isn't their value, or that a literal can't set.
    package static let unwritable: [String] = ["CLOB", "NCLOB", "BLOB", "BFILE", "LONG", "JSON", "VECTOR", "XMLTYPE", "ROWID", "UROWID", "ANYDATA"]

    package static func key(_ table: TableName, heap: Bool, constraints: QueryResult, columns: QueryResult) -> TableKey? {
        var readOnly: Set<String> = []
        for row in ResultRow.rows(of: columns) {
            guard let name = row["name"] else { continue }
            let type = (row["type"] ?? "").uppercased()
            let objectType = !(row["type_owner"] ?? "").isEmpty
            let generated = row["virtual"] == "YES" || row["generation"] == "ALWAYS"
            if generated || objectType || unwritable.contains(where: { type == $0 || type.hasPrefix($0 + " ") || type.hasPrefix($0 + "(") }) {
                readOnly.insert(name)
            }
        }
        var order: [String] = []
        var found: [String: (primary: Bool, columns: [String], notNull: Bool)] = [:]
        for row in ResultRow.rows(of: constraints) {
            guard let index = row["index"], let column = row["column"] else { continue }
            if found[index] == nil {
                order.append(index)
                found[index] = (row["kind"] == "P", [], true)
            }
            found[index]?.columns.append(column)
            if row["nullable"] != "N" { found[index]?.notNull = false }
        }
        for name in order {
            guard let index = found[name], index.primary || index.notNull else { continue }
            var key = TableKey(table: table, kind: index.primary ? .primary : .unique(name), columns: index.columns, readOnlyColumns: readOnly)
            key.note = emptyIsNull
            return key
        }
        guard heap else { return nil }
        var key = TableKey(table: table, kind: .rowid, columns: ["rowid"], readOnlyColumns: readOnly)
        key.label = "by ROWID"
        key.note = rowidNote + " " + emptyIsNull
        return key
    }

    package static let rowidNote =
        "No primary or unique NOT NULL key: rows are found by their ROWID — select it too (SELECT ROWID, t.* FROM … t). A row's ROWID holds until the table is moved, shrunk or rebuilt."

    /// SQL's statements in Oracle's quoting; a new row with nothing set is
    /// refused (no DEFAULT VALUES), a ROWID key said in the confirmation.
    package static func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) throws -> [EditStatement] {
        for values in edits.inserted where !values.keys.contains(where: result.isEditable) {
            throw EditRefusal.said("A new row needs a value in one column at least: Oracle has no DEFAULT VALUES.")
        }
        var statements = try EditStatements.make(edits, rows: rows, result: result, dialect: .oracle)
        if result.key.kind == .rowid {
            for at in statements.indices where !statements[at].sql.hasPrefix("INSERT") { statements[at].note = rowidNote }
        }
        return statements
    }

    /// What an Oracle-maintained role says among its attributes.
    package static let maintained = "Oracle's own"

    /// Oracle's own rule, said where NULL and '' are told apart elsewhere.
    package static let emptyIsNull = "Oracle keeps an empty string as NULL."

    /// The session's formats while a Save runs: the ones the grid shows
    /// dates, timestamps and numbers in, so their text reads back as the
    /// same value (Oracle reads a shorter date than its format).
    package static let nlsParameters = ["NLS_DATE_FORMAT", "NLS_TIMESTAMP_FORMAT", "NLS_TIMESTAMP_TZ_FORMAT", "NLS_NUMERIC_CHARACTERS"]
    package static let nlsReadSQL =
        "SELECT parameter, value FROM nls_session_parameters WHERE parameter IN (\(nlsParameters.map(DatabaseDrivers.literal).joined(separator: ", ")))"
    package static let nlsSetStatements = [
        "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'",
        "ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF'",
        "ALTER SESSION SET NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF TZR'",
        "ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,'",
    ]

    /// The session's own formats back, as they were read.
    package static func nlsRestoreStatements(_ saved: [[String?]]) -> [String] {
        saved.compactMap { row in
            guard row.count >= 2, let name = row[0], nlsParameters.contains(name), let value = row[1] else { return nil }
            return "ALTER SESSION SET \(name) = \(DatabaseDrivers.literal(value))"
        }
    }

    // MARK: Users statements

    /// Users that aren't Oracle's own; no password column is asked for.
    package static let usersSQL = """
        SELECT username AS name, account_status, expiry_date, profile, authentication_type, common
        FROM dba_users WHERE oracle_maintained = 'N' ORDER BY username
        """

    /// The roles made here, and Oracle's few a user is usually given.
    package static let rolesSQL = """
        SELECT role AS name, authentication_type, oracle_maintained FROM dba_roles
        WHERE oracle_maintained = 'N' OR role IN ('CONNECT', 'RESOURCE', 'DBA', 'SELECT_CATALOG_ROLE', 'EXECUTE_CATALOG_ROLE', 'DB_DEVELOPER_ROLE')
        ORDER BY role
        """

    package static let roleGrantsSQL = "SELECT grantee, granted_role FROM dba_role_privs"

    package static func grantsSQL(_ name: String) -> String {
        """
        SELECT 'system' AS kind, privilege, admin_option AS grantable, NULL AS owner, NULL AS object_name FROM dba_sys_privs WHERE grantee = \(name)
        UNION ALL SELECT 'role', granted_role, admin_option, NULL, NULL FROM dba_role_privs WHERE grantee = \(name)
        UNION ALL SELECT LOWER(type), privilege, grantable, owner, table_name FROM dba_tab_privs WHERE grantee = \(name)
        ORDER BY 1, 4, 5, 2
        """
    }

    /// This user's own, which every user may read.
    package static let ownGrantsSQL = """
        SELECT 'system' AS kind, privilege, admin_option AS grantable, NULL AS owner, NULL AS object_name FROM user_sys_privs
        UNION ALL SELECT 'role', granted_role, admin_option, NULL, NULL FROM user_role_privs
        UNION ALL SELECT LOWER(type), privilege, grantable, owner, table_name FROM user_tab_privs WHERE grantee = USER
        ORDER BY 1, 4, 5, 2
        """

    // MARK: Answers

    package static func overview(_ result: QueryResult) -> ServerOverview {
        guard let row = ResultRow.rows(of: result).first else { return ServerOverview() }
        var facts: [ServerFact] = []
        facts.append(ServerFact(title: "Version", value: row["version"] ?? "—", detail: row["host_name"].map { "on \($0)" }))
        if let uptime = row.double("uptime") { facts.append(ServerFact(title: "Uptime", value: OpsText.duration(uptime), detail: row["instance_name"])) }
        if let used = row.int("sessions"), let max = row.int("max_sessions") {
            facts.append(
                ServerFact(
                    title: "Sessions", value: "\(used) / \(max)", detail: row.int("active").map { "\($0) active" } ?? OpsText.percent(Double(used) / Double(Swift.max(max, 1)))))
        }
        if let used = row.int("processes"), let max = row.int("max_processes") {
            facts.append(ServerFact(title: "Processes", value: "\(used) / \(max)", detail: OpsText.percent(Double(used) / Double(Swift.max(max, 1))) + " used"))
        }
        if let physical = row.double("physical_reads"), let logical = row.double("logical_reads"), logical > 0 {
            facts.append(ServerFact(title: "Buffer cache hit", value: OpsText.percent(1 - physical / logical), detail: "since the instance started"))
        }
        let database = [row["db_name"], row["container"]].compactMap { $0 }.filter { !$0.isEmpty }
        if !database.isEmpty {
            facts.append(
                ServerFact(
                    title: "Database", value: database.joined(separator: " / "),
                    detail: [row["role"], row["open_mode"]].compactMap { $0 }.joined(separator: ", ").lowercased()))
        }
        if let commits = row["commits"] {
            facts.append(ServerFact(title: "Transactions", value: commits, detail: row["rollbacks"].map { "\($0) rolled back" }))
        }
        return ServerOverview(facts: facts)
    }

    /// INACTIVE is idle; the rest lower-cased as Oracle says them.
    package static func activity(_ result: QueryResult) -> [DatabaseActivity] {
        ResultRow.rows(of: result).map { row in
            let status = (row["state"] ?? "").lowercased()
            return DatabaseActivity(
                id: row["id"] ?? "", user: row["user"], database: row["database"], client: row["client"],
                application: row["application"].flatMap { $0.isEmpty ? nil : $0 }, state: status == "inactive" ? "idle" : status,
                statement: row["query"].flatMap { $0.isEmpty ? nil : $0 }, seconds: row.double("seconds"),
                waiting: row["waiting"].flatMap { $0.isEmpty ? nil : $0 }, isOwn: row.bool("own"))
        }
    }

    /// The two rankings merged, each statement once.
    package static func slowQueries(_ results: [QueryResult]) -> [SlowQuery] {
        var seen: Set<String> = []
        var out: [SlowQuery] = []
        for result in results {
            for row in ResultRow.rows(of: result) {
                guard let id = row["id"], seen.insert(id).inserted else { continue }
                let detail = [row.double("cpu").map { "CPU \(OpsText.duration($0))" }, row["buffer_gets"].map { "\($0) buffer gets" }].compactMap { $0 }
                out.append(
                    SlowQuery(
                        id: id, statement: row["query"] ?? "", calls: row.int("calls") ?? 0, total: row.double("total") ?? 0, mean: row.double("mean") ?? 0,
                        rows: row.int("rows"), database: nil, user: nil, detail: detail.isEmpty ? nil : detail.joined(separator: ", ")))
            }
        }
        return out.sorted { $0.total > $1.total }
    }

    package static func users(_ users: QueryResult, roles: QueryResult, memberships: QueryResult) -> [DatabaseUser] {
        var memberOf: [String: [String]] = [:]
        for row in ResultRow.rows(of: memberships) {
            guard let grantee = row["grantee"], let role = row["granted_role"] else { continue }
            memberOf[grantee, default: []].append(role)
        }
        let people = ResultRow.rows(of: users).map { row -> DatabaseUser in
            let name = row["name"] ?? ""
            let status = row["account_status"] ?? "OPEN"
            let authentication = (row["authentication_type"] ?? "PASSWORD").uppercased()
            var attributes: [String] = []
            if status != "OPEN" { attributes.append(status.lowercased()) }
            if authentication == "NONE" {
                attributes.append("schema only — no password")
            } else if authentication != "PASSWORD" {
                attributes.append(authentication.lowercased())
            }
            if let profile = row["profile"], profile != "DEFAULT" { attributes.append("profile \(profile)") }
            if row["common"] == "YES" { attributes.append("common") }
            return DatabaseUser(
                name: name, canLogin: status == "OPEN" && authentication != "NONE", attributes: attributes, validUntil: row["expiry_date"],
                memberOf: (memberOf[name] ?? []).sorted())
        }
        let groups = ResultRow.rows(of: roles).map { row -> DatabaseUser in
            let name = row["name"] ?? ""
            var attributes: [String] = []
            if row["oracle_maintained"] == "Y" { attributes.append(maintained) }
            if let authentication = row["authentication_type"], !["NONE", ""].contains(authentication) { attributes.append("needs \(authentication.lowercased())") }
            return DatabaseUser(name: name, isRole: true, canLogin: false, attributes: attributes, memberOf: (memberOf[name] ?? []).sorted())
        }
        return people + groups
    }

    /// A system privilege a grant each; a role each; an object's privileges together.
    package static func grants(_ result: QueryResult) -> [DatabaseGrant] {
        var out: [DatabaseGrant] = []
        var objects: [String: Int] = [:]
        for row in ResultRow.rows(of: result) {
            guard let kind = row["kind"], let privilege = row["privilege"] else { continue }
            let grantable = row["grantable"] == "YES"
            switch kind {
            case "system":
                out.append(DatabaseGrant(kind: "system", object: privilege, privileges: [privilege], grantable: grantable, target: .server))
            case "role":
                out.append(DatabaseGrant(kind: "role", object: privilege, privileges: ["MEMBER"], grantable: grantable))
            default:
                let owner = row["owner"] ?? ""
                let name = row["object_name"] ?? ""
                let object = owner.isEmpty ? name : "\(owner).\(name)"
                if let at = objects["\(kind) \(object)"] {
                    out[at].privileges.append(privilege)
                    out[at].grantable = out[at].grantable || grantable
                } else {
                    objects["\(kind) \(object)"] = out.count
                    let target: GrantTarget? = kind == "table" || kind == "view" ? .table(TableName(schema: owner, name: name)) : nil
                    out.append(DatabaseGrant(kind: kind, object: object, privileges: [privilege], grantable: grantable, target: target))
                }
            }
        }
        return out
    }
}


// MARK: Users' statements

/// Oracle's user statements: CREATE USER … IDENTIFIED BY (and GRANT CREATE
/// SESSION when it logs in), ALTER USER, system privileges granted WITH
/// ADMIN OPTION or a table's WITH GRANT OPTION, roles, DROP USER/ROLE. A
/// plain name typed is upper-cased as Oracle reads it unquoted; a name
/// from the catalog is quoted as it is. Pure.
package struct OracleUserStatements: UserStatementMaking {
    /// Whose tables a Grant sheet's Owner starts with: the connection's user.
    package var owner = ""

    package static let mask = "\"••••••••\""

    package var form: UserForm {
        UserForm(
            login: true, superuser: nil,
            passwordNote:
                "The password is sent once, over this connection (encrypted only over TCPS), and never kept here. A plain name is upper-cased, as Oracle reads it.",
            grantKinds: [
                GrantKind(title: "System privilege"),
                GrantKind(title: "Table", fields: [GrantField(title: "Owner", fill: owner.isEmpty ? .schema : .text(owner)), GrantField(title: "Table")]),
            ],
            grantOption: true, grantsNote: "System privileges, roles, and grants on objects (tables, views, procedures).",
            noGrants: "None of its own — it may still have PUBLIC's, or its roles'.", sql: true)
    }

    /// A plain name — a letter, then letters, digits, `_`, `$`, `#` — as
    /// Oracle reads it unquoted: upper-case. Anything else as written. A
    /// `"` can't be in an Oracle name at all.
    package static func name(_ typed: String, _ what: String = "A name") throws -> String {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw refusal("\(what), please.") }
        guard !name.contains("\0"), !name.contains("\"") else { throw refusal("\(what) can't hold a \" or a NUL in Oracle.") }
        let plain = name.range(of: #"^[A-Za-z][A-Za-z0-9_$#]*$"#, options: .regularExpression) != nil
        return plain ? name.uppercased() : name
    }

    /// A catalog's name, quoted as it is.
    private func quoted(_ name: String) throws -> String {
        guard !name.contains("\"") else { throw Self.refusal("An Oracle name can't hold a \".") }
        return SQLDialect.oracle.identifier(try checked(name))
    }

    /// Oracle's password is a quoted identifier: anything but `"`.
    private static func password(_ password: String) throws -> String {
        guard !password.isEmpty else { throw refusal("A password, please.") }
        guard !password.contains("\""), !password.contains("\0") else { throw refusal("An Oracle password can't hold a \".") }
        return "\"" + password + "\""
    }

    package func create(_ user: NewUser) throws -> [UserStatement] {
        let name = SQLDialect.oracle.identifier(try Self.name(user.name))
        let head = "CREATE USER \(name) IDENTIFIED BY "
        var statements = [UserStatement(head + (try Self.password(user.password)), shown: head + Self.mask)]
        if user.login { statements.append(UserStatement("GRANT CREATE SESSION TO \(name)")) }
        return statements
    }

    package func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        let head = "ALTER USER \(try quoted(user.name)) IDENTIFIED BY "
        return UserStatement(head + (try Self.password(password)), shown: head + Self.mask)
    }

    /// Oracle's own roles (CONNECT, DBA…) are granted, never changed or dropped.
    package func offers(_ action: UserAction, on user: DatabaseUser) -> Bool {
        let oracles = user.attributes.contains(OracleOps.maintained)
        switch action {
        case .password: return !user.isRole
        case .grant, .grantRole: return !oracles || !user.isRole
        case .drop: return !oracles
        }
    }

    package func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        guard kind.title == "Table" else { return .server }
        return .table(TableName(schema: fields.first ?? "", name: fields.count > 1 ? fields[1] : ""))
    }

    package func privileges(on target: GrantTarget) -> [String] {
        switch target {
        case .server:
            return [
                "CREATE SESSION", "CREATE TABLE", "CREATE VIEW", "CREATE SEQUENCE", "CREATE PROCEDURE", "CREATE TRIGGER", "CREATE TYPE",
                "CREATE SYNONYM", "CREATE MATERIALIZED VIEW", "UNLIMITED TABLESPACE", "ALTER SESSION", "SELECT ANY TABLE", "INSERT ANY TABLE",
                "UPDATE ANY TABLE", "DELETE ANY TABLE", "SELECT ANY DICTIONARY", "CREATE USER", "ALTER USER", "DROP USER", "CREATE ROLE",
                "GRANT ANY ROLE", "ALTER SYSTEM",
            ]
        case .table: return ["ALL", "SELECT", "INSERT", "UPDATE", "DELETE", "ALTER", "INDEX", "REFERENCES", "READ"]
        default: return []
        }
    }

    /// `"OWNER"."TABLE"` — a typed name as Oracle reads it; nil: a system privilege.
    private func object(_ target: GrantTarget) throws -> String? {
        switch target {
        case .server: return nil
        case .table(let table):
            let name = SQLDialect.oracle.identifier(try Self.name(table.name, "A table"))
            guard let owner = table.schema, !owner.trimmingCharacters(in: .whitespaces).isEmpty else { return name }
            return SQLDialect.oracle.identifier(try Self.name(owner, "An owner")) + "." + name
        default: throw Self.refusal("Oracle grants system privileges, or on a table.")
        }
    }

    private func words(_ privileges: [String], on target: GrantTarget) throws -> String {
        let allowed = self.privileges(on: target)
        guard !privileges.isEmpty else { throw Self.refusal("Pick a privilege.") }
        for privilege in privileges where !allowed.contains(privilege) {
            throw Self.refusal("\(privilege) isn't a privilege on \(target.title.lowercased()).")
        }
        return privileges.contains("ALL") ? "ALL" : privileges.joined(separator: ", ")
    }

    package func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        let words = try words(privileges, on: target)
        let who = try quoted(user.name)
        guard let object = try object(target) else {
            return UserStatement("GRANT \(words) TO \(who)" + (grantOption ? " WITH ADMIN OPTION" : ""))
        }
        return UserStatement("GRANT \(words) ON \(object) TO \(who)" + (grantOption ? " WITH GRANT OPTION" : ""))
    }

    /// A privilege's name as the catalog says it: words of capitals.
    private static func isWord(_ privilege: String) -> Bool {
        privilege.range(of: #"^[A-Z][A-Z ]*$"#, options: .regularExpression) != nil
    }

    /// The listed grant taken back: a system privilege, a role, a table's privileges.
    package func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard let who = try? quoted(user.name) else { return nil }
        switch grant.kind {
        case "system":
            guard Self.isWord(grant.object) else { return nil }
            return UserStatement("REVOKE \(grant.object) FROM \(who)")
        case "role":
            guard let role = try? quoted(grant.object) else { return nil }
            return UserStatement("REVOKE \(role) FROM \(who)")
        default:
            guard case .table(let table)? = grant.target, let owner = table.schema, let name = try? quoted(table.name), let schema = try? quoted(owner)
            else { return nil }
            let privileges = grant.privileges.filter(Self.isWord)
            guard !privileges.isEmpty else { return nil }
            return UserStatement("REVOKE \(privileges.joined(separator: ", ")) ON \(schema).\(name) FROM \(who)")
        }
    }

    /// Roles only: Oracle grants a role, never a user.
    package func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] {
        users.filter { $0.isRole && $0.id != user.id && !user.memberOf.contains($0.name) }
    }

    package func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement {
        UserStatement("GRANT \(try quoted(role.name)) TO \(try quoted(user.name))")
    }

    package func drop(_ user: DatabaseUser) throws -> UserStatement {
        UserStatement((user.isRole ? "DROP ROLE " : "DROP USER ") + (try quoted(user.name)))
    }
}
