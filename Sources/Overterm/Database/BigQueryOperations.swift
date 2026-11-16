import Foundation

/// BigQuery's Server page and rows edited. BigQuery has no server: the page
/// is the project's jobs — running and pending ones from the REST API's
/// `jobs.list` (free, so read every few seconds), the costliest of the last
/// week and the storage from the region's INFORMATION_SCHEMA (queries, billed
/// as any — read only when their tab opens and on Refresh). A job is
/// cancelled by `jobs.cancel`. No Locks: nothing waits on a row. No Users
/// page: who may do what is Google Cloud IAM, not SQL.
/// docs/architecture.md, Database: Server page.
extension BigQueryDriver: DatabaseMonitoring, DatabaseTableEditing {
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .slowQueries, .sizes] }

    /// `jobs.cancel` alone: there is no session to end.
    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        guard BigQueryOps.isJobID(session.id) else { return [] }
        return [
            SessionStop(
                terminate: false, menu: "Cancel Job…", title: "Cancel job \(session.id)?", command: "POST …/jobs/\(session.id)/cancel (jobs.cancel)",
                effect: SessionStop.said(session)
                    + "\n\nBigQuery stops it as soon as it can; a job may still finish first. A cancelled query's bytes already processed are billed; a script's statements that finished stay done.",
                button: "Cancel Job")
        ]
    }

    func editDialect() async -> SQLDialect { .bigquery }

    /// The table's declared primary key and every column's type — the
    /// literals are cast to them (BigQuery converts no text on its own).
    func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>? {
        let query: EditableQuery
        switch EditableQuery.parse(statement) {
        case .success(let parsed): query = parsed
        case .failure(let refusal): return .failure(refusal)
        }
        guard let table = BigQueryOps.table(query.table, defaultDataset: config.database) else {
            return .failure(.said("Name the table's dataset (dataset.table) — the connection has no default dataset."))
        }
        let found: (key: TableKey, types: [String: String], columns: [String])
        switch try await describe(table) {
        case nil: return .failure(.noKey(table.name))
        case .failure(let refusal)?: return .failure(refusal)
        case .success(let described)?: found = described
        }
        switch EditableResult.match(resultColumns: result.columns, tableColumns: found.columns, key: found.key) {
        case .failure(let refusal): return .failure(refusal)
        case .success(var editable):
            editable.types = editable.columns.map { found.types[$0] ?? "" }
            return .success(editable)
        }
    }

    func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try BigQueryOps.editStatements(edits, rows: rows, result: result)
    }

    func editSaveNote() async -> String { BigQueryOps.saveNote }

    /// The region INFORMATION_SCHEMA's jobs and storage are read in.
    private var region: (qualifier: String, assumed: Bool) { BigQueryOps.region(config.location) }

    // MARK: Monitoring

    func overview() async throws -> ServerOverview {
        let listing = try await jobs()
        let datasets = (try? await get("\(base)/datasets?maxResults=1000"))?["datasets"] as? [[String: Any]]
        return BigQueryOps.overview(
            project: config.project, location: config.location, datasets: datasets?.count, jobs: listing.jobs, everyone: listing.everyone)
    }

    /// Running and pending jobs — everyone's with `bigquery.jobs.listAll`,
    /// else this account's own.
    private func jobs() async throws -> (jobs: [DatabaseActivity], everyone: Bool) {
        let query = "jobs?stateFilter=running&stateFilter=pending&projection=full&maxResults=200"
        var everyone = true
        let answer: [String: Any]
        do {
            answer = try await get("\(base)/\(query)&allUsers=true")
        } catch {
            everyone = false
            answer = try await get("\(base)/\(query)")
        }
        let listed = BigQueryOps.jobs(answer, now: Date(), own: ownJobs)
        for job in listed.locations { jobLocations[job.key] = job.value }
        return (listed.jobs, everyone)
    }

    func activity() async throws -> Monitored<[DatabaseActivity]> {
        .value(try await jobs().jobs)
    }

    /// The last week's jobs grouped by their normalized text, costliest first.
    func slowQueries() async throws -> Monitored<[SlowQuery]> {
        do {
            let result = try await query(BigQueryOps.slowSQL(region: region.qualifier), limit: 200, own: true)
            return .value(BigQueryOps.slowQueries(result))
        } catch {
            return .unavailable(BigQueryOps.jobsGap(error, region: region))
        }
    }

    func sizes() async throws -> Monitored<DatabaseSizes> {
        do {
            let datasets = try await query(BigQueryOps.datasetSizesSQL(region: region.qualifier), limit: 200, own: true)
            let tables = try await query(BigQueryOps.tableSizesSQL(region: region.qualifier), limit: 50, own: true)
            var sizes = DatabaseSizes(databases: PostgresOps.sizes(datasets), tables: PostgresOps.sizes(tables))
            sizes.notes.append(
                "Logical bytes, from \(region.qualifier).INFORMATION_SCHEMA.TABLE_STORAGE\(region.assumed ? " (the connection names no location: US assumed)" : ""). Datasets are “databases” here; BigQuery has no indexes."
            )
            return .value(sizes)
        } catch {
            return .unavailable(
                MonitorGap(
                    reason: "\(region.qualifier).INFORMATION_SCHEMA.TABLE_STORAGE couldn't be read: \(error.localizedDescription)",
                    fix: region.assumed ? "the connection's Location (US, EU, us-central1…) — where its datasets are" : "bigquery.tables.list on the project (BigQuery Metadata Viewer)"))
        }
    }

    /// `jobs.cancel` — BigQuery cancels a job; there is no session to end.
    func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("cancelling a job") }
        guard !terminate else { throw DatabaseError.failed("BigQuery ends no session: a job is cancelled.") }
        guard BigQueryOps.isJobID(session) else { throw DatabaseError.failed("No job \(session).") }
        guard !ownJobs.contains(session) else { throw DatabaseError.failed("That is this page's own read.") }
        var address = "\(base)/jobs/\(session)/cancel"
        if let location = jobLocations[session] ?? (config.location.isEmpty ? nil : config.location),
            let encoded = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            address += "?location=\(encoded)"
        }
        _ = try await post(address, [:])
    }

    // MARK: Editing rows

    /// A table's declared primary key — BigQuery enforces none, so a table
    /// without one isn't edited.
    func key(of table: TableName) async throws -> TableKey? {
        guard let table = BigQueryOps.table(table, defaultDataset: config.database) else {
            throw DatabaseError.failed("Name the table's dataset (dataset.table) — the connection has no default dataset.")
        }
        switch try await describe(table) {
        case nil: return nil
        case .success(let found)?: return found.key
        case .failure(let refusal)?: throw DatabaseError.failed(refusal.message)
        }
    }

    /// The table's type, key and columns from its dataset's INFORMATION_SCHEMA
    /// (three small queries, the page's own); nil: no such table.
    private func describe(_ table: TableName) async throws -> Result<(key: TableKey, types: [String: String], columns: [String]), EditRefusal>? {
        let schema = BigQueryOps.informationSchema(project: config.project, dataset: table.schema ?? "")
        let name = SQLDialect.bigquery.literal(table.name)
        let kind = try await query("SELECT table_type FROM \(schema).TABLES WHERE table_name = \(name)", limit: 1, own: true)
        guard let type = kind.rows.first?.first ?? nil else { return nil }
        let constraints = try await query(BigQueryOps.keySQL(schema: schema, table: name), limit: 100, own: true)
        let columns = try await query(
            "SELECT column_name, data_type FROM \(schema).COLUMNS WHERE table_name = \(name) ORDER BY ordinal_position", limit: 10_000, own: true)
        let types = BigQueryOps.types(columns)
        return BigQueryOps.key(table, tableType: type, constraints: constraints, columns: columns).map { ($0, types.types, types.order) }
    }

    /// One script: a transaction whose every statement must change its one
    /// row (`@@row_count`), else everything is rolled back and the error
    /// says which.
    func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("saving the edits") }
        guard !statements.isEmpty else { return }
        do {
            _ = try await query(BigQueryOps.script(statements), limit: 1, own: false)
        } catch {
            let message = error.localizedDescription
            throw DatabaseError.failed(message.contains("Nothing was saved") ? message : message + " — nothing was saved.")
        }
    }
}

/// BigQuery's statements and REST answers for the Server page and editing.
/// Pure.
enum BigQueryOps {
    /// `region-us`, `region-europe-west1` — the connection's location, US
    /// when it names none (said).
    static func region(_ location: String) -> (qualifier: String, assumed: Bool) {
        let trimmed = location.trimmingCharacters(in: .whitespaces).lowercased()
        let safe = trimmed.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return safe.isEmpty ? ("`region-us`", true) : ("`region-\(safe)`", false)
    }

    /// A job id: letters, digits, `_`, `-` (Google's rule).
    static func isJobID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 1024 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// `` `project`.`dataset`.INFORMATION_SCHEMA ``.
    static func informationSchema(project: String, dataset: String) -> String {
        SQLDialect.bigquery.identifier(project) + "." + SQLDialect.bigquery.identifier(dataset) + ".INFORMATION_SCHEMA"
    }

    // MARK: Jobs (REST)

    /// jobs.list's jobs as sessions: the job id, who, the query or what the
    /// job does, how long — running since it started, pending since made.
    static func jobs(_ answer: [String: Any], now: Date, own: Set<String>) -> (jobs: [DatabaseActivity], locations: [String: String]) {
        var out: [DatabaseActivity] = []
        var locations: [String: String] = [:]
        for job in answer["jobs"] as? [[String: Any]] ?? [] {
            let reference = job["jobReference"] as? [String: Any] ?? [:]
            guard let id = reference["jobId"] as? String else { continue }
            if let location = reference["location"] as? String { locations[id] = location }
            let state = ((job["state"] as? String) ?? ((job["status"] as? [String: Any])?["state"] as? String) ?? "").lowercased()
            let configuration = job["configuration"] as? [String: Any] ?? [:]
            let statistics = job["statistics"] as? [String: Any] ?? [:]
            func millis(_ key: String) -> Double? { (statistics[key] as? String).flatMap(Double.init) ?? (statistics[key] as? NSNumber)?.doubleValue }
            let since = state == "pending" ? millis("creationTime") : millis("startTime") ?? millis("creationTime")
            var statement: String?
            if let query = configuration["query"] as? [String: Any] {
                statement = query["query"] as? String
            } else if let type = configuration["jobType"] as? String {
                statement = type
            }
            out.append(
                DatabaseActivity(
                    id: id, user: job["user_email"] as? String, database: reference["location"] as? String, client: nil,
                    application: (configuration["jobType"] as? String).map { $0.lowercased() + " job" }, state: state, statement: statement,
                    seconds: since.map { max(0, now.timeIntervalSince1970 - $0 / 1000) }, isOwn: own.contains(id)))
        }
        return (out.sorted { ($0.seconds ?? 0) > ($1.seconds ?? 0) }, locations)
    }

    static func overview(project: String, location: String, datasets: Int?, jobs: [DatabaseActivity], everyone: Bool) -> ServerOverview {
        let running = jobs.filter { $0.state == "running" }.count
        let pending = jobs.filter { $0.state == "pending" }.count
        var facts = [
            ServerFact(title: "Project", value: project),
            ServerFact(title: "Location", value: location.isEmpty ? "US" : location, detail: location.isEmpty ? "assumed — the connection names none" : nil),
            ServerFact(title: "Running", value: "\(running)", detail: everyone ? "jobs, everyone's" : "jobs, this account's own"),
            ServerFact(title: "Pending", value: "\(pending)", detail: "jobs waiting for slots"),
        ]
        if let datasets { facts.append(ServerFact(title: "Datasets", value: "\(datasets)")) }
        var notes = [
            "BigQuery has no server: this is the project's jobs. Slow Queries and Sizes read INFORMATION_SCHEMA — queries, billed like any (10 MB at least) — only when their tab opens and on Refresh."
        ]
        if !everyone {
            notes.append("Only this account's jobs: everyone's need bigquery.jobs.listAll (BigQuery Resource Viewer on the project).")
        }
        return ServerOverview(facts: facts, notes: notes)
    }

    // MARK: INFORMATION_SCHEMA

    /// The last seven days' finished queries, grouped by their text with
    /// literals taken out, costliest by slot time; a script's children only.
    static func slowSQL(region: String) -> String {
        """
        SELECT COALESCE(query_info.query_hashes.normalized_literals, TO_HEX(MD5(query))) AS id, ANY_VALUE(query) AS query,
          ANY_VALUE(user_email) AS user, COUNT(*) AS calls,
          SUM(TIMESTAMP_DIFF(end_time, start_time, MILLISECOND)) / 1000 AS total,
          AVG(TIMESTAMP_DIFF(end_time, start_time, MILLISECOND)) / 1000 AS mean,
          SUM(total_slot_ms) / 1000 AS slot_seconds, SUM(total_bytes_processed) AS bytes, SUM(total_bytes_billed) AS billed
        FROM \(region).INFORMATION_SCHEMA.JOBS_BY_PROJECT
        WHERE creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY) AND job_type = 'QUERY' AND state = 'DONE'
          AND statement_type != 'SCRIPT' AND end_time IS NOT NULL
        GROUP BY id ORDER BY SUM(total_slot_ms) DESC LIMIT 200
        """
    }

    static func jobsGap(_ error: Error, region: (qualifier: String, assumed: Bool)) -> MonitorGap {
        let message = error.localizedDescription
        if message.lowercased().contains("access denied") || message.contains("permission") {
            return MonitorGap(
                reason: "\(region.qualifier).INFORMATION_SCHEMA.JOBS_BY_PROJECT is the project's record of its jobs; this account may not read it: \(message)",
                fix: "roles/bigquery.resourceViewer on the project (bigquery.jobs.listAll)")
        }
        return MonitorGap(
            reason: "\(region.qualifier).INFORMATION_SCHEMA.JOBS_BY_PROJECT couldn't be read: \(message)",
            fix: region.assumed ? "the connection's Location (US, EU, us-central1…) — where its jobs run" : nil)
    }

    static func datasetSizesSQL(region: String) -> String {
        """
        SELECT table_schema AS name, SUM(total_logical_bytes) AS bytes, CONCAT(CAST(COUNT(*) AS STRING), ' tables') AS detail
        FROM \(region).INFORMATION_SCHEMA.TABLE_STORAGE WHERE NOT deleted GROUP BY table_schema ORDER BY bytes DESC
        """
    }

    static func tableSizesSQL(region: String) -> String {
        """
        SELECT table_schema AS schema, table_name AS name, total_logical_bytes AS bytes,
          CONCAT('rows ', CAST(total_rows AS STRING), ', ', CAST(ROUND(total_physical_bytes / 1048576) AS STRING), ' MiB physical') AS detail
        FROM \(region).INFORMATION_SCHEMA.TABLE_STORAGE WHERE NOT deleted ORDER BY total_logical_bytes DESC LIMIT 50
        """
    }

    static func slowQueries(_ result: QueryResult) -> [SlowQuery] {
        ResultRow.rows(of: result).compactMap { row in
            guard let id = row["id"] else { return nil }
            let detail = [
                row.int64("bytes").map { "\(OpsText.bytes($0)) processed" }, row.double("slot_seconds").map { "\(OpsText.duration($0)) of slots" },
            ].compactMap { $0 }
            return SlowQuery(
                id: id, statement: row["query"] ?? "", calls: row.int("calls") ?? 0, total: row.double("total") ?? 0, mean: row.double("mean") ?? 0,
                rows: nil, database: nil, user: row["user"], detail: detail.isEmpty ? nil : detail.joined(separator: ", "))
        }
    }

    // MARK: Editing

    static func keySQL(schema: String, table: String) -> String {
        """
        SELECT k.column_name, k.ordinal_position FROM \(schema).TABLE_CONSTRAINTS c
        JOIN \(schema).KEY_COLUMN_USAGE k ON k.constraint_name = c.constraint_name AND k.table_name = c.table_name
        WHERE c.table_name = \(table) AND c.constraint_type = 'PRIMARY KEY' ORDER BY k.ordinal_position
        """
    }

    /// Types whose grid text isn't a literal a CAST reads back: nested ones
    /// (shown as JSON), BYTES (shown base64), GEOGRAPHY (WKT needs its function).
    static func isUnwritable(_ type: String) -> Bool {
        let upper = type.uppercased()
        return ["STRUCT", "ARRAY", "JSON", "BYTES", "GEOGRAPHY", "RANGE"].contains { upper.hasPrefix($0) }
    }

    /// `dataset.table` as written, a backticked `` `dataset.table` `` cut in
    /// two, else the connection's dataset; nil: no dataset to name.
    static func table(_ table: TableName, defaultDataset: String) -> TableName? {
        if table.schema == nil, table.name.contains(".") {
            let parts = table.name.split(separator: ".").map(String.init)
            guard parts.count >= 2 else { return nil }
            return TableName(schema: parts[parts.count - 2], name: parts[parts.count - 1])
        }
        guard let dataset = table.schema ?? (defaultDataset.isEmpty ? nil : defaultDataset) else { return nil }
        return TableName(schema: dataset, name: table.name)
    }

    /// Each column's type, and the columns in order.
    static func types(_ columns: QueryResult) -> (types: [String: String], order: [String]) {
        var types: [String: String] = [:]
        var order: [String] = []
        for row in ResultRow.rows(of: columns) {
            guard let name = row["column_name"] else { continue }
            types[name] = row["data_type"] ?? ""
            order.append(name)
        }
        return (types, order)
    }

    static let saveNote =
        "BigQuery: one script, in a transaction — each statement must change exactly one row (@@row_count), else none is kept. The key is declared, not enforced. Rows still in the streaming buffer can't be updated or deleted."

    static func key(_ table: TableName, tableType: String, constraints: QueryResult, columns: QueryResult) -> Result<TableKey, EditRefusal> {
        guard tableType == "BASE TABLE" else {
            return .failure(.said("\(table.name) is a \(tableType.lowercased()): rows are edited in a table."))
        }
        let keyColumns = ResultRow.rows(of: constraints).compactMap { $0["column_name"] }
        guard !keyColumns.isEmpty else {
            return .failure(
                .said(
                    "\(table.name) declares no primary key, and BigQuery enforces none: rows are edited only where one is declared (ALTER TABLE … ADD PRIMARY KEY (…) NOT ENFORCED)."))
        }
        var readOnly: Set<String> = []
        for row in ResultRow.rows(of: columns) {
            guard let name = row["column_name"], let type = row["data_type"], isUnwritable(type) else { continue }
            readOnly.insert(name)
        }
        var key = TableKey(table: table, kind: .primary, columns: keyColumns, readOnlyColumns: readOnly)
        key.label = "key not enforced"
        key.note = "BigQuery declares the key, doesn't enforce it: each change is checked to touch one row."
        return .success(key)
    }

    /// A literal as its column takes it: `CAST('5' AS INT64)`; a STRING's as is.
    static func value(_ cell: CellValue, type: String) -> String {
        guard case .text(let text) = cell else { return "NULL" }
        return cast(SQLDialect.bigquery.literal(text), to: type)
    }

    static func cast(_ literal: String, to type: String) -> String {
        let bare = type.trimmingCharacters(in: .whitespaces)
        // A type is the catalog's words: letters, digits, (), commas, spaces.
        guard !bare.isEmpty, !bare.uppercased().hasPrefix("STRING"),
            bare.range(of: #"^[A-Za-z][A-Za-z0-9_(), ]*$"#, options: .regularExpression) != nil
        else { return literal }
        return "CAST(\(literal) AS \(bare))"
    }

    /// A Save's statements, SQL's order — each literal cast to its column's
    /// type (`EditableResult.types`); a new row sets a column at least. Pure.
    static func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) throws -> [EditStatement] {
        let dialect = SQLDialect.bigquery
        let table = dialect.qualified(result.key.table)
        func type(_ column: Int) -> String { result.types[safe: column] ?? "" }
        func whereKey(_ row: Int) throws -> String {
            guard rows.indices.contains(row) else { throw EditRefusal.truncatedKey }
            return try zip(result.key.columns, result.keyIndexes).map { column, at in
                guard let value = rows[row][safe: at] ?? nil else { throw EditRefusal.truncatedKey }
                return dialect.identifier(column) + " = " + cast(dialect.literal(value), to: type(at))
            }.joined(separator: " AND ")
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            statements.append(EditStatement(sql: "DELETE FROM \(table) WHERE \(try whereKey(row))"))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            let sets = try cells.keys.sorted().map { column -> String in
                guard result.isEditable(column) else { throw EditRefusal.unknownColumn(result.columns[safe: column] ?? "?") }
                return dialect.identifier(result.columns[column]) + " = " + value(cells[column] ?? .null, type: type(column))
            }
            statements.append(EditStatement(sql: "UPDATE \(table) SET \(sets.joined(separator: ", ")) WHERE \(try whereKey(row))"))
        }
        for values in edits.inserted {
            let columns = values.keys.sorted().filter { result.isEditable($0) }
            guard !columns.isEmpty else { throw EditRefusal.said("A new row needs a value in one column at least.") }
            let names = columns.map { dialect.identifier(result.columns[$0]) }.joined(separator: ", ")
            let literals = columns.map { value(values[$0] ?? .null, type: type($0)) }.joined(separator: ", ")
            statements.append(EditStatement(sql: "INSERT INTO \(table) (\(names)) VALUES (\(literals))"))
        }
        return statements
    }

    /// The statements in one transaction, each checked by `@@row_count`; any
    /// error rolls all of it back and is raised again.
    static func script(_ statements: [EditStatement]) -> String {
        var lines = ["BEGIN", "  BEGIN TRANSACTION;"]
        for (index, statement) in statements.enumerated() {
            lines.append("  \(statement.sql);")
            let message = SQLDialect.bigquery.literal(
                "Statement \(index + 1) changed %d rows, not \(statement.expectedRows) — the row has changed or gone since it was read, or the key isn't unique. Nothing was saved.")
            lines.append("  IF @@row_count <> \(statement.expectedRows) THEN RAISE USING MESSAGE = FORMAT(\(message), @@row_count); END IF;")
        }
        lines += ["  COMMIT TRANSACTION;", "EXCEPTION WHEN ERROR THEN", "  ROLLBACK TRANSACTION;", "  RAISE USING MESSAGE = @@error.message;", "END;"]
        return lines.joined(separator: "\n")
    }
}
