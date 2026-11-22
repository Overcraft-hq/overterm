import Foundation

// MongoDB's and DocumentDB's Server page, a find's documents edited, and
// their users and roles — every read over the driver's own connection.
// docs/architecture.md, Database: Server page, Editing rows, Users and roles.

extension MongoDriver: DatabaseMonitoring {
    /// DocumentDB sends its profiler to CloudWatch and says nothing of who
    /// waits on a lock: those tabs aren't there (the overview says so).
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] {
        kind == .documentdb ? [.overview, .activity, .sizes] : MonitorPart.allCases
    }

    /// killOp only: an operation stops at its next yield; the connection
    /// it came on isn't the page's to end.
    package static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        [
            SessionStop(
                terminate: false, menu: "Kill Operation…", title: "Kill operation \(session.id)?",
                command: "db.adminCommand({ killOp: 1, op: \(MongoOps.operationID(session.id).shell) })",
                effect: SessionStop.said(session) + "\n\nIt stops at its next yield; a write it began is undone only inside a transaction.",
                button: "Kill Operation")
        ]
    }

    package func overview() async throws -> ServerOverview {
        if hello == nil { try await connect() }
        var notes: [String] = []
        var status = BSONDocument()
        do {
            status = try await send(["serverStatus": .int32(1)], database: "admin")
        } catch let error as MongoServerError {
            notes.append("serverStatus was refused (\(error.message)) — it needs the clusterMonitor role.")
        }
        if config.kind == .documentdb {
            notes.append(
                "DocumentDB writes slow operations to CloudWatch Logs (the profiler parameter of the cluster's parameter group) and doesn't say who waits on a lock — neither is here."
            )
        }
        var overview = MongoOps.overview(status: status, hello: hello ?? [:], kind: config.kind)
        overview.notes += notes
        return overview
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        .value(MongoOps.activity(try await operations(), own: hello?["connectionId"]?.int))
    }

    /// Every operation, other users' too where this user may see them.
    private func operations() async throws -> [BSONDocument] {
        if hello == nil { try await connect() }
        if config.kind == .documentdb {
            let reply = try await command(["currentOp": .int32(1), "$all": .bool(true)], database: "admin")
            return reply["inprog"]?.array?.compactMap(\.document) ?? []
        }
        func read(allUsers: Bool) async throws -> [BSONDocument] {
            let stage: BSONDocument = ["$currentOp": .document(["allUsers": .bool(allUsers), "idleConnections": .bool(false)])]
            let command = MongoCommand(
                method: "aggregate", body: ["aggregate": .int32(1), "pipeline": .array([.document(stage)]), "cursor": .document([:])], action: .cursor)
            return try await documents(command, database: "admin", limit: 2000)
        }
        do {
            return try await read(allUsers: true)
        } catch {
            // Without the inprog privilege: this user's own.
            return try await read(allUsers: false)
        }
    }

    package func slowQueries() async throws -> Monitored<[SlowQuery]> {
        if hello == nil { try await connect() }
        if hello?["msg"]?.string == "isdbgrid" {
            return .unavailable(MonitorGap(reason: "A mongos has no profiler of its own: each shard's is read on the shard."))
        }
        // MongoDB 8's (and Atlas') record of every query shape, when it has one.
        let shapes = MongoCommand(
            method: "aggregate", body: ["aggregate": .int32(1), "pipeline": .array([.document(["$queryStats": .document([:])])]), "cursor": .document([:])],
            action: .cursor)
        if let stats = try? await documents(shapes, database: "admin", limit: 2000), !stats.isEmpty {
            return .value(MongoOps.queryStats(stats))
        }
        let database = current
        let level: BSONDocument
        do {
            level = try await send(["profile": .int32(-1)], database: database)
        } catch let error as MongoServerError {
            return .unavailable(MonitorGap(reason: "The profiler's level couldn't be read on \(database): \(error.message)"))
        }
        let read = MongoCommand(
            collection: "system.profile", method: "find",
            body: [
                "find": .string("system.profile"), "sort": .document(["ts": .int32(-1)]),
                "projection": .document([
                    "ns": .int32(1), "op": .int32(1), "command": .int32(1), "millis": .int32(1), "nreturned": .int32(1), "queryHash": .int32(1),
                    "user": .int32(1),
                ]),
            ], action: .cursor, limit: 1000)
        let entries: [BSONDocument]
        do {
            entries = try await documents(read, database: database, limit: 1000)
        } catch let error as DatabaseError {
            return .unavailable(MonitorGap(reason: "\(database).system.profile couldn't be read: \(error.localizedDescription)"))
        }
        if entries.isEmpty, (level["was"]?.int ?? 0) == 0 {
            return .unavailable(
                MonitorGap(
                    reason:
                        "The profiler of \(database) is off: MongoDB keeps no record of its slow operations. Turn it on for operations slower than 100 ms (mongosh's db.setProfilingLevel(1, { slowms: 100 })):",
                    fix: "db.getSiblingDB(\(BSONText.quoted(database))).runCommand({ profile: 1, slowms: 100 })"))
        }
        return .value(MongoOps.profiled(entries))
    }

    package func locks() async throws -> Monitored<[LockWait]> {
        .value(MongoOps.locks(try await operations()))
    }

    package func sizes() async throws -> Monitored<DatabaseSizes> {
        if hello == nil { try await connect() }
        var sizes = DatabaseSizes()
        if let reply = try? await send(["listDatabases": .int32(1)], database: "admin") {
            sizes.databases = MongoOps.databases(reply)
        } else {
            sizes.notes.append("The databases' sizes need the listDatabases privilege.")
        }
        let database = current
        var stats: [(String, BSONDocument)] = []
        let collections = try await tables(in: database).filter { !$0.isView }
        for collection in collections.prefix(100) {
            if let found = await collectionStats(collection.name, in: database) { stats.append((collection.name, found)) }
        }
        let (tables, indexes) = MongoOps.collections(stats, database: database)
        sizes.tables = tables
        sizes.indexes = indexes
        sizes.notes.append(
            "Collections and indexes of \(database), the console's database\(collections.count > 100 ? " — the first 100 of \(collections.count)" : "").")
        return .value(sizes)
    }

    /// A collection's storage: `$collStats`, else the collStats command
    /// (DocumentDB's, and older servers').
    private func collectionStats(_ name: String, in database: String) async -> BSONDocument? {
        if config.kind != .documentdb {
            let command = MongoCommand(
                collection: name, method: "aggregate",
                body: ["aggregate": .string(name), "pipeline": .array([.document(["$collStats": .document(["storageStats": .document([:])])])]), "cursor": .document([:])],
                action: .cursor)
            if let found = try? await documents(command, database: database, limit: 1).first?["storageStats"]?.document { return found }
        }
        return try? await send(["collStats": .string(name)], database: database)
    }

    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("killOp") }
        guard !terminate else { throw DatabaseError.failed("MongoDB stops an operation (killOp); it doesn't end a session from here.") }
        guard session != "?" else { throw DatabaseError.failed("MongoDB didn't say which operation holds the lock.") }
        _ = try await command(["killOp": .int32(1), "op": MongoOps.operationID(session)], database: "admin")
    }
}

// MARK: Editing documents

extension MongoDriver: DatabaseTableEditing {
    package func editDialect() async -> SQLDialect { .postgres }

    /// Not SQL: a find's documents are found by `editableResult`.
    package func key(of table: TableName) async throws -> TableKey? { nil }

    package func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>? {
        let command: MongoCommand
        do {
            command = try MongoText.command(statement)
        } catch {
            return .failure(.said(error.localizedDescription))
        }
        return MongoEdits.editable(command, database: command.database ?? current, result: result)
    }

    package func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try MongoEdits.statements(edits, rows: rows, result: result)
    }

    /// A replica set's (and mongos', and DocumentDB's) writes go in one
    /// transaction; a standalone server has none.
    private var transactional: Bool {
        guard let hello else { return false }
        return hello["setName"]?.string != nil || hello["msg"]?.string == "isdbgrid"
    }

    package func editSaveNote() async -> String {
        if hello == nil { try? await connect() }
        return transactional
            ? "In one transaction: if any statement fails, or doesn't find its document, none is kept."
            : "One by one — a standalone server has no transactions: a failure stops the rest, and those before it are kept."
    }

    package func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("a write") }
        if hello == nil { try await connect() }
        // Every statement read before anything is sent.
        let commands = try statements.map { statement -> (MongoCommand, EditStatement) in
            let command = try MongoText.command(statement.sql)
            guard command.action == .write else { throw DatabaseError.failed("Not a write: \(statement.sql)") }
            return (command, statement)
        }
        guard transactional else {
            for (command, statement) in commands { try check(try await self.command(command.body, database: command.database ?? current), statement) }
            return
        }
        let session: BSONDocument = ["id": .binary(subtype: 4, MongoShellParser.uuidBytes(UUID()))]
        let number = BSONValue.int64(1)
        do {
            for (index, (command, statement)) in commands.enumerated() {
                var body = command.body
                body["lsid"] = .document(session)
                body["txnNumber"] = number
                body["autocommit"] = .bool(false)
                if index == 0 { body["startTransaction"] = .bool(true) }
                try check(try await self.command(body, database: command.database ?? current), statement)
            }
            _ = try await self.command(
                ["commitTransaction": .int32(1), "lsid": .document(session), "txnNumber": number, "autocommit": .bool(false)], database: "admin")
        } catch {
            _ = try? await send(["abortTransaction": .int32(1), "lsid": .document(session), "txnNumber": number, "autocommit": .bool(false)], database: "admin")
            throw error
        }
    }

    /// A write's answer: it must have found exactly its document.
    private func check(_ reply: BSONDocument, _ statement: EditStatement) throws {
        if let error = reply["writeErrors"]?.array?.first?.document {
            throw DatabaseError.failed(
                MongoServerError.words(error["errmsg"]?.string ?? "The write failed.", code: error["code"]?.int, name: error["codeName"]?.string))
        }
        let n = reply["n"]?.int ?? 0
        guard n == statement.expectedRows else {
            throw DatabaseError.failed(
                "\(statement.sql) found \(n) document\(n == 1 ? "" : "s"), not \(statement.expectedRows) — it may have been changed or deleted since it was read.")
        }
    }
}

// MARK: Users and roles

extension MongoDriver: DatabaseUserManagement {
    package func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own

    package func userStatements() async -> any UserStatementMaking { MongoUserStatements(signsInTo: authDatabase) }

    private var authDatabase: String { config.authSource.isEmpty ? "admin" : config.authSource }

    package func users() async throws -> Monitored<[DatabaseUser]> {
        if hello == nil { try await connect() }
        var found: [BSONDocument]
        do {
            found = try await send(["usersInfo": .document(["forAllDBs": .bool(true)])], database: "admin")["users"]?.array?.compactMap(\.document) ?? []
        } catch {
            do {
                found = try await send(["usersInfo": .int32(1)], database: authDatabase)["users"]?.array?.compactMap(\.document) ?? []
            } catch let error as MongoServerError {
                return .unavailable(
                    MonitorGap(
                        reason:
                            "\(config.user.isEmpty ? "This connection" : config.user) may not read the users (\(error.message)) — it takes the viewUser action (userAdmin, userAdminAnyDatabase or root)."
                    ))
            }
        }
        var users = MongoOps.users(found)
        // Custom roles: where the users are, the console's database, admin.
        var databases = Set(users.compactMap(\.host))
        databases.formUnion(["admin", current])
        for database in databases.sorted() {
            guard let reply = try? await send(["rolesInfo": .int32(1), "showBuiltinRoles": .bool(false)], database: database) else { continue }
            users += MongoOps.roles(reply["roles"]?.array?.compactMap(\.document) ?? [])
        }
        return .value(users)
    }

    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        let database = user.host ?? "admin"
        let name: BSONValue = .document(["\(user.isRole ? "role" : "user")": .string(user.name), "db": .string(database)])
        let key = user.isRole ? "rolesInfo" : "usersInfo"
        var reply: BSONDocument
        do {
            reply = try await send([key: name, "showPrivileges": .bool(true)], database: database)
        } catch {
            // DocumentDB doesn't show privileges: the roles alone.
            do {
                reply = try await send([key: name], database: database)
            } catch let error as MongoServerError {
                return .unavailable(MonitorGap(reason: "\(user.display)'s roles couldn't be read: \(error.message)"))
            }
        }
        guard let entry = reply[user.isRole ? "roles" : "users"]?.array?.first?.document else {
            return .unavailable(MonitorGap(reason: "\(user.display) wasn't found."))
        }
        return .value(MongoOps.grants(entry))
    }

    /// Each a command the console reads (`MongoUserStatements`), sent once;
    /// never recorded, never logged. An error says the server's words, which
    /// never repeat a password.
    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("a user change") }
        if hello == nil { try await connect() }
        for statement in statements {
            let command: MongoCommand
            do {
                command = try MongoText.command(statement.sql)
            } catch {
                throw DatabaseError.failed("\(statement.shown) couldn't be read.")
            }
            _ = try await self.command(command.body, database: command.database ?? authDatabase)
        }
    }
}

/// MongoDB's answers read for the Server page and the Users page. Pure.
package enum MongoOps {
    /// An operation's id as killOp takes it: a number, or a mongos' `shard:123`.
    package static func operationID(_ text: String) -> BSONValue {
        if let n = Int64(text) { return Int32(exactly: n).map(BSONValue.int32) ?? .int64(n) }
        return .string(text)
    }

    package static func overview(status: BSONDocument, hello: BSONDocument, kind: DatabaseKind) -> ServerOverview {
        var facts: [ServerFact] = []
        func number(_ value: BSONValue?) -> Double? {
            switch value {
            case .double(let d)?: d
            case .int32(let n)?: Double(n)
            case .int64(let n)?: Double(n)
            default: nil
            }
        }
        let version = status["version"]?.string ?? ""
        facts.append(ServerFact(title: "Version", value: version.isEmpty ? "—" : version, detail: kind == .documentdb ? "Amazon DocumentDB" : status["process"]?.string))
        if let uptime = number(status["uptime"]) { facts.append(ServerFact(title: "Uptime", value: OpsText.duration(uptime), detail: status["host"]?.string)) }
        if let connections = status["connections"]?.document, let current = number(connections["current"]) {
            let available = number(connections["available"]) ?? 0
            facts.append(
                ServerFact(
                    title: "Connections", value: "\(Int(current)) of \(Int(current + available))",
                    detail: number(connections["totalCreated"]).map { "\(Int($0)) opened since start" }))
        }
        if let ops = status["opcounters"]?.document {
            let parts = ["query", "insert", "update", "delete", "getmore", "command"].compactMap { name in number(ops[name]).map { "\(name) \(Int($0))" } }
            let total = ["query", "insert", "update", "delete", "getmore", "command"].compactMap { number(ops[$0]) }.reduce(0, +)
            facts.append(ServerFact(title: "Operations", value: "\(Int(total))", detail: parts.joined(separator: " · ")))
        }
        if let cache = status["wiredTiger"]?.document?["cache"]?.document, let used = number(cache["bytes currently in the cache"]),
            let max = number(cache["maximum bytes configured"]), max > 0
        {
            facts.append(ServerFact(title: "Cache used", value: OpsText.percent(used / max), detail: "\(OpsText.bytes(Int64(used))) of \(OpsText.bytes(Int64(max)))"))
        }
        if let resident = number(status["mem"]?.document?["resident"]) {
            facts.append(ServerFact(title: "Memory", value: OpsText.bytes(Int64(resident) * 1024 * 1024), detail: "resident"))
        }
        if let network = status["network"]?.document, let bytesIn = number(network["bytesIn"]), let bytesOut = number(network["bytesOut"]) {
            facts.append(ServerFact(title: "Network", value: OpsText.bytes(Int64(bytesIn + bytesOut)), detail: "in \(OpsText.bytes(Int64(bytesIn))) · out \(OpsText.bytes(Int64(bytesOut)))"))
        }
        let role: String
        if hello["msg"]?.string == "isdbgrid" {
            role = "mongos"
        } else if let set = hello["setName"]?.string {
            role = hello["isWritablePrimary"]?.bool == true || hello["ismaster"]?.bool == true ? "primary of \(set)" : "secondary of \(set)"
        } else {
            role = "standalone"
        }
        facts.append(ServerFact(title: "Topology", value: role, detail: hello["hosts"]?.array.map { "\($0.count) members" }))
        return ServerOverview(facts: facts)
    }

    /// `$currentOp`'s (or DocumentDB's currentOp's) operations as sessions.
    /// An operation without a client is the server's own work (a TTL
    /// monitor, a checkpoint): listed as a daemon, out of the busy list.
    package static func activity(_ operations: [BSONDocument], own: Int?) -> [DatabaseActivity] {
        operations.compactMap { op -> DatabaseActivity? in
            guard let id = op["opid"] else { return nil }
            let active = op["active"]?.bool ?? false
            let client = op["client"]?.string ?? op["client_s"]?.string
            let users = op["effectiveUsers"]?.array?.compactMap(\.document) ?? []
            let user = users.first.map { "\($0["user"]?.string ?? "")@\($0["db"]?.string ?? "")" } ?? op["user"]?.string
            let namespace = op["ns"]?.string ?? ""
            let database = namespace.split(separator: ".", maxSplits: 1).first.map(String.init)
            var seconds: Double?
            if let micros = op["microsecs_running"]?.int {
                seconds = Double(micros) / 1_000_000
            } else if let secs = op["secs_running"]?.int {
                seconds = Double(secs)
            }
            let state: String
            if client == nil, op["connectionId"] == nil {
                state = "daemon"
            } else if op["type"]?.string == "idleSession" || !active {
                state = "idle"
            } else {
                state = op["op"]?.string ?? "active"
            }
            var waiting: String?
            if op["waitingForLock"]?.bool == true { waiting = "a lock" } else if op["waitingForFlowControl"]?.bool == true { waiting = "flow control" }
            return DatabaseActivity(
                id: id.string ?? id.int.map(String.init) ?? id.shell, user: user, database: database?.isEmpty == false ? database : nil, client: client,
                application: op["appName"]?.string ?? op["desc"]?.string, state: state, statement: statement(op), seconds: seconds, waiting: waiting,
                isOwn: own != nil && op["connectionId"]?.int == own)
        }
    }

    /// What an operation runs, as the shell writes it — its session's and
    /// the cluster's fields left out, a password never.
    package static func statement(_ op: BSONDocument) -> String? {
        guard var command = op["command"]?.document ?? op["query"]?.document else { return nil }
        for noise in ["lsid", "$clusterTime", "$db", "$readPreference", "txnNumber", "autocommit", "$audit", "$client"] { command[noise] = nil }
        guard !command.isEmpty else { return nil }
        return BSONText.shell(.document(masked(command)))
    }

    /// pwd, password, and anything named like a secret, said as ••••.
    package static func masked(_ document: BSONDocument) -> BSONDocument {
        var out = BSONDocument()
        for field in document.fields {
            let lower = field.key.lowercased()
            if ["pwd", "password", "newpassword", "secret", "key"].contains(lower) || lower.hasSuffix("password") {
                out.fields.append((field.key, .string("••••")))
            } else if let inner = field.value.document {
                out.fields.append((field.key, .document(masked(inner))))
            } else if let items = field.value.array {
                out.fields.append((field.key, .array(items.map { $0.document.map { .document(masked($0)) } ?? $0 })))
            } else {
                out.fields.append(field)
            }
        }
        return out
    }

    /// A command's shape: every value a `?`, so one statement is one row
    /// whatever its values (and no value is shown).
    package static func shape(_ value: BSONValue) -> BSONValue {
        switch value {
        case .document(let document):
            return .document(BSONDocument(document.fields.map { ($0.key, shape($0.value)) }))
        case .array(let items):
            return .array(items.first.map { [shape($0)] } ?? [])
        default:
            return .string("?")
        }
    }

    /// The profiler's entries summed by statement: its namespace, its kind,
    /// its query hash or its shape.
    package static func profiled(_ entries: [BSONDocument]) -> [SlowQuery] {
        struct Sum {
            var statement: String
            var database: String?
            var user: String?
            var calls = 0
            var millis = 0.0
            var rows = 0
        }
        var sums: [String: Sum] = [:]
        var order: [String] = []
        for entry in entries {
            var command = entry["command"]?.document ?? [:]
            for noise in ["lsid", "$clusterTime", "$db", "$readPreference", "txnNumber", "autocommit", "comment", "batchSize", "cursor"] { command[noise] = nil }
            let shaped = BSONText.shell(shape(.document(command)))
            let namespace = entry["ns"]?.string ?? ""
            let key = "\(namespace)|\(entry["op"]?.string ?? "")|\(entry["queryHash"]?.string ?? shaped)"
            if sums[key] == nil {
                order.append(key)
                let database = namespace.split(separator: ".", maxSplits: 1).first.map(String.init)
                sums[key] = Sum(statement: "\(namespace) \(shaped)", database: database, user: entry["user"]?.string)
            }
            sums[key]?.calls += 1
            sums[key]?.millis += Double(entry["millis"]?.int ?? 0)
            sums[key]?.rows += entry["nreturned"]?.int ?? 0
        }
        return order.compactMap { key in
            guard let sum = sums[key] else { return nil }
            let total = sum.millis / 1000
            return SlowQuery(
                id: key, statement: sum.statement, calls: sum.calls, total: total, mean: total / Double(max(sum.calls, 1)), rows: sum.rows, database: sum.database,
                user: sum.user)
        }
    }

    /// `$queryStats`' query shapes: each its count and its time.
    package static func queryStats(_ entries: [BSONDocument]) -> [SlowQuery] {
        entries.enumerated().map { index, entry in
            let key = entry["key"]?.document ?? [:]
            let metrics = entry["metrics"]?.document ?? [:]
            let calls = metrics["execCount"]?.int ?? 0
            let micros = metrics["totalExecMicros"]?.document?["sum"]?.int ?? 0
            let total = Double(micros) / 1_000_000
            let namespace = key["queryShape"]?.document?["cmdNs"]?.document
            let database = namespace?["db"]?.string
            let collection = namespace?["coll"]?.string
            let shown = [database, collection].compactMap { $0 }.joined(separator: ".")
            return SlowQuery(
                id: entry["queryShapeHash"]?.string ?? "\(index)", statement: "\(shown) \(BSONText.shell(.document(masked(key["queryShape"]?.document ?? key))))",
                calls: calls, total: total, mean: total / Double(max(calls, 1)), rows: metrics["docsReturned"]?.document?["sum"]?.int, database: database)
        }
    }

    /// Operations waiting for a lock, and who may hold it. MongoDB says an
    /// operation waits, not on whom: the blocker is the longest-running
    /// operation not waiting that holds an exclusive lock (W or X) on the
    /// same database, or the whole server — else "?".
    package static func locks(_ operations: [BSONDocument]) -> [LockWait] {
        let pairs = operations.compactMap { op in activity([op], own: nil).first.map { ($0, op) } }
        let sessions = pairs.map(\.0)
        let byID = Dictionary(pairs.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        func database(_ op: BSONDocument) -> String { (op["ns"]?.string ?? "").split(separator: ".", maxSplits: 1).first.map(String.init) ?? "" }
        func exclusive(_ op: BSONDocument) -> Bool {
            (op["locks"]?.document?.fields ?? []).contains { $0.value.string == "W" || $0.value.string == "X" }
        }
        return sessions.filter { $0.waiting == "a lock" }.map { waiting in
            let op = byID[waiting.id] ?? [:]
            let wanted = (op["locks"]?.document?.fields ?? []).map { "\($0.key) \($0.value.string ?? "")" }.joined(separator: ", ")
            let holders = sessions.filter { candidate in
                guard candidate.id != waiting.id, candidate.waiting == nil, let held = byID[candidate.id], exclusive(held) else { return false }
                let place = database(held)
                return place.isEmpty || place == database(op)
            }.sorted { ($0.seconds ?? 0) > ($1.seconds ?? 0) }
            let blocker = holders.first
            return LockWait(
                waiting: waiting.id, waitingUser: waiting.user, waitingStatement: waiting.statement, blocking: blocker?.id ?? "?", blockingUser: blocker?.user,
                blockingStatement: blocker?.statement ?? (blocker == nil ? "MongoDB doesn't say who holds it" : nil),
                lock: wanted.isEmpty ? nil : "wants \(wanted) on \(database(op).isEmpty ? "the server" : database(op))", seconds: waiting.seconds)
        }
    }

    package static func databases(_ reply: BSONDocument) -> [SizeEntry] {
        (reply["databases"]?.array?.compactMap(\.document) ?? []).compactMap { entry in
            guard let name = entry["name"]?.string else { return nil }
            return SizeEntry(name: name, bytes: Int64(entry["sizeOnDisk"]?.int ?? 0), detail: entry["empty"]?.bool == true ? "empty" : nil)
        }.sorted { $0.bytes > $1.bytes }
    }

    /// Collections by their storage on disk, and their indexes, largest first.
    package static func collections(_ stats: [(String, BSONDocument)], database: String) -> (tables: [SizeEntry], indexes: [SizeEntry]) {
        var tables: [SizeEntry] = []
        var indexes: [SizeEntry] = []
        for (name, stat) in stats {
            let count = stat["count"]?.int ?? 0
            let data = stat["size"]?.int ?? 0
            tables.append(
                SizeEntry(
                    name: name, schema: database, bytes: Int64(stat["storageSize"]?.int ?? data),
                    detail: "\(count) doc\(count == 1 ? "" : "s") · data \(OpsText.bytes(Int64(data)))"))
            for index in stat["indexSizes"]?.document?.fields ?? [] {
                indexes.append(SizeEntry(name: index.key, schema: database, bytes: Int64(index.value.int ?? 0), detail: "on \(name)"))
            }
        }
        return (Array(tables.sorted { $0.bytes > $1.bytes }.prefix(50)), Array(indexes.sorted { $0.bytes > $1.bytes }.prefix(50)))
    }

    /// usersInfo's users: a name in a database, its roles — never its
    /// credentials (they aren't asked for).
    package static func users(_ found: [BSONDocument]) -> [DatabaseUser] {
        found.compactMap { entry in
            guard let name = entry["user"]?.string else { return nil }
            let roles = roleNames(entry["roles"])
            var attributes = (entry["mechanisms"]?.array?.compactMap(\.string) ?? [])
            if entry["authenticationRestrictions"]?.array?.isEmpty == false { attributes.append("restricted by address") }
            return DatabaseUser(
                name: name, host: entry["db"]?.string ?? "admin", superuser: roles.contains("root@admin") || roles.contains("__system@admin"),
                attributes: attributes, memberOf: roles)
        }.sorted { ($0.host ?? "", $0.name) < ($1.host ?? "", $1.name) }
    }

    /// rolesInfo's roles that aren't built in.
    package static func roles(_ found: [BSONDocument]) -> [DatabaseUser] {
        found.compactMap { entry in
            guard let name = entry["role"]?.string, entry["isBuiltin"]?.bool != true else { return nil }
            return DatabaseUser(name: name, host: entry["db"]?.string ?? "admin", isRole: true, canLogin: false, memberOf: roleNames(entry["roles"]))
        }
    }

    package static func roleNames(_ value: BSONValue?) -> [String] {
        (value?.array?.compactMap(\.document) ?? []).compactMap { role in
            guard let name = role["role"]?.string else { return nil }
            return "\(name)@\(role["db"]?.string ?? "admin")"
        }
    }

    /// A user's or a role's grants: the roles granted (each revocable), then
    /// what they give together, by resource.
    package static func grants(_ entry: BSONDocument) -> [DatabaseGrant] {
        var grants = roleNames(entry["roles"]).map { DatabaseGrant(kind: "role", object: $0, privileges: ["granted role"]) }
        let privileges = entry["inheritedPrivileges"]?.array ?? entry["privileges"]?.array ?? []
        for privilege in privileges.compactMap(\.document) {
            let resource = privilege["resource"]?.document ?? [:]
            let actions = (privilege["actions"]?.array?.compactMap(\.string) ?? []).sorted()
            let kind: String
            let object: String
            if resource["cluster"]?.bool == true {
                (kind, object) = ("server", "cluster")
            } else if resource["anyResource"]?.bool == true {
                (kind, object) = ("server", "any resource")
            } else {
                let db = resource["db"]?.string ?? ""
                let collection = resource["collection"]?.string ?? ""
                let dbName = db.isEmpty ? "every database" : db
                (kind, object) = collection.isEmpty ? ("database", dbName) : ("collection", "\(dbName).\(collection)")
            }
            grants.append(DatabaseGrant(kind: kind, object: object, privileges: actions))
        }
        return grants
    }
}

/// A find's documents as rows edited: each found again by its `_id`, a cell
/// a top-level field — `$set` to a value or null, `$unset` to remove it —,
/// a new document `insertOne`, a deleted one `deleteOne`. Each statement
/// is written as the console reads it, and that is what runs. Pure.
package enum MongoEdits {
    package static func editable(_ command: MongoCommand, database: String, result: QueryResult) -> Result<EditableResult, EditRefusal> {
        guard command.action == .cursor, command.name == "find", let collection = command.collection else {
            return .failure(.said("Documents are edited in a find() on one collection — not an aggregate or a command's answer."))
        }
        if let projection = command.body["projection"]?.document {
            let plain = projection.fields.allSatisfy { field in
                switch field.value {
                case .bool, .int32, .int64, .double: true
                default: false
                }
            }
            guard plain else { return .failure(.said("A projection that computes fields isn't the documents' own: leave it out to edit them.")) }
        }
        guard let at = result.columns.firstIndex(of: "_id") else { return .failure(.keyNotShown(["_id"])) }
        if result.types[safe: at] == "mixed" {
            return .failure(.said("The _id values are of several types: a cell can't say which each one is."))
        }
        let key = TableKey(table: TableName(schema: database, name: collection), kind: .identity("_id"), columns: ["_id"])
        return .success(EditableResult(key: key, columns: result.columns, keyIndexes: [at], removesFields: true, types: result.types))
    }

    package static func statements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) throws -> [EditStatement] {
        let database = result.key.table.schema ?? "test"
        let collection = "db.getSiblingDB(\(BSONText.quoted(database))).getCollection(\(BSONText.quoted(result.key.table.name)))"
        let idColumn = result.keyIndexes.first ?? 0
        func id(_ row: Int) throws -> BSONValue {
            guard let text = rows[safe: row]?[safe: idColumn] ?? nil else { throw EditRefusal.truncatedKey }
            return try value(text, type: result.types[safe: idColumn] ?? "")
        }
        func field(_ column: Int) throws -> String {
            let name = result.columns[safe: column] ?? ""
            guard !name.contains("."), !name.hasPrefix("$") else {
                throw EditRefusal.said("“\(name)” has a dot or starts with $: MongoDB's $set would read it as a path or an operator.")
            }
            return name
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            let filter: BSONValue = .document(["_id": try id(row)])
            statements.append(EditStatement(sql: "\(collection).deleteOne(\(filter.shell))"))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            var set = BSONDocument()
            var unset = BSONDocument()
            for column in cells.keys.sorted() {
                guard column != idColumn else { throw EditRefusal.said("_id can't be changed — duplicate the document with a new _id, then delete this one.") }
                let name = try field(column)
                switch cells[column] ?? .null {
                case .absent: unset[name] = .string("")
                case .null: set[name] = .null
                case .text(let text): set[name] = try value(text, type: result.types[safe: column] ?? "")
                }
            }
            var update = BSONDocument()
            if !set.isEmpty { update["$set"] = .document(set) }
            if !unset.isEmpty { update["$unset"] = .document(unset) }
            let filter: BSONValue = .document(["_id": try id(row)])
            statements.append(EditStatement(sql: "\(collection).updateOne(\(filter.shell), \(BSONValue.document(update).shell))"))
        }
        for values in edits.inserted {
            var document = BSONDocument()
            for column in values.keys.sorted() {
                let name = try field(column)
                switch values[column] ?? .absent {
                case .absent: continue
                case .null: document[name] = .null
                case .text(let text): document[name] = try value(text, type: result.types[safe: column] ?? "")
                }
            }
            // _id first, as the server keeps it.
            if let id = document["_id"] {
                document["_id"] = nil
                document.fields.insert((key: "_id", value: id), at: 0)
            }
            statements.append(EditStatement(sql: "\(collection).insertOne(\(BSONValue.document(document).shell))"))
        }
        return statements
    }

    /// A cell's text as a value of its column's type — a string as itself,
    /// a date as its ISO time, a number as the column's kind of number —;
    /// any other type, or a column of several, as the shell writes a value
    /// (`{ "a": 1 }`, `ObjectId("…")`, `42`), else the text.
    package static func value(_ text: String, type: String) throws -> BSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch type {
        case "string": return .string(text)
        case "symbol": return .symbol(text)
        case "objectId": if let id = ObjectID(hex: trimmed) { return .objectId(id) }
        case "date": if let ms = MongoShellParser.date(trimmed) { return .date(ms) }
        case "int": if let n = Int32(trimmed) { return .int32(n) }
        case "long": if let n = Int64(trimmed) { return .int64(n) }
        case "double": if let d = Double(trimmed) { return .double(d) }
        case "decimal": if let d = Decimal128(trimmed) { return .decimal128(d) }
        case "bool":
            if trimmed == "true" { return .bool(true) }
            if trimmed == "false" { return .bool(false) }
        case "uuid": if let uuid = UUID(uuidString: trimmed) { return .binary(subtype: 4, MongoShellParser.uuidBytes(uuid)) }
        default: break
        }
        var parser = MongoShellParser(text)
        if let parsed = try? parser.value(), parser.atEnd { return parsed }
        if ["", "mixed", "null", "undefined"].contains(type) { return .string(text) }
        throw EditRefusal.said("“\(text)” isn't a \(type) — write it as the shell writes one: \(example(type)).")
    }

    private static func example(_ type: String) -> String {
        switch type {
        case "objectId": #"ObjectId("65f1…") or its 24 hex digits"#
        case "date": "2026-01-31T09:30:00Z"
        case "int", "long": "42"
        case "double": "4.5"
        case "bool": "true or false"
        case "object": #"{ "a": 1 }"#
        case "array": #"[1, "two"]"#
        default: #"its shell form, or "text" in quotes"#
        }
    }
}

/// MongoDB's user commands as the console writes them — `createUser`,
/// `updateUser`, `grantRolesToUser`, `revokeRolesFromUser`, `dropUser` (and
/// a role's), in the account's database. A grant is a role: a built-in one
/// on a database, or one of the server's own. The password goes once,
/// inside createUser or updateUser; the server keeps only its SCRAM
/// verifiers. Pure.
package struct MongoUserStatements: UserStatementMaking {
    package static let databaseRoles = ["read", "readWrite", "dbAdmin", "dbOwner", "userAdmin"]
    package static let adminRoles = [
        "readAnyDatabase", "readWriteAnyDatabase", "userAdminAnyDatabase", "dbAdminAnyDatabase", "clusterMonitor", "clusterManager", "hostManager",
        "clusterAdmin", "backup", "restore", "root",
    ]

    /// The database a new user signs in to unless the sheet says otherwise:
    /// the connection's own (its authSource), else admin.
    package var signsInTo = "admin"

    package var form: UserForm {
        UserForm(
            account: "Database it signs in to (admin if empty)", accountFill: signsInTo, superuser: nil,
            passwordNote:
                "The password is sent once, inside the command, over this connection — TLS keeps it off the wire in the clear. The server keeps only its SCRAM verifiers; nothing is kept here.",
            grantKinds: [GrantKind(title: "Database", fields: [GrantField(title: "Database", fill: .database)])],
            noGrants: "No roles of its own.")
    }

    package func offers(_ action: UserAction, on user: DatabaseUser) -> Bool { action != .password || !user.isRole }

    package func target(_ kind: GrantKind, fields: [String]) -> GrantTarget { .database(fields.first ?? "") }

    package func privileges(on target: GrantTarget) -> [String] {
        guard case .database(let name) = target else { return [] }
        return name == "admin" ? Self.databaseRoles + Self.adminRoles : Self.databaseRoles
    }

    /// Roles only: a user isn't granted to another.
    package func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] {
        users.filter { $0.isRole && $0.id != user.id && !user.memberOf.contains($0.display) }
    }

    private static func database(_ user: DatabaseUser) -> String {
        let name = user.host ?? ""
        return name.isEmpty || name == "%" ? "admin" : name
    }

    /// `db.getSiblingDB("admin").runCommand({ … })` — every name and value
    /// a quoted string of the shell's, so none ends the command.
    private static func command(_ body: BSONDocument, in database: String) -> String {
        "db.getSiblingDB(\(BSONText.quoted(database))).runCommand(\(BSONValue.document(body).shell))"
    }

    private static func withPassword(_ body: BSONDocument, _ password: String, in database: String) -> UserStatement {
        var sent = body
        sent["pwd"] = .string(password)
        var shown = body
        shown["pwd"] = .string("••••••••")
        return UserStatement(command(sent, in: database), shown: command(shown, in: database))
    }

    private static func roles(_ names: [String], in database: String) -> BSONValue {
        .array(names.map { .document(["role": .string($0), "db": .string(database)]) })
    }

    package func create(_ user: NewUser) throws -> [UserStatement] {
        _ = try checked(user.name)
        guard !user.password.isEmpty else { throw Self.refusal("A password, please.") }
        let database = Self.database(DatabaseUser(name: user.name, host: user.host.trimmingCharacters(in: .whitespaces)))
        _ = try checked(database, "A database")
        return [Self.withPassword(["createUser": .string(user.name), "roles": .array([])], user.password, in: database)]
    }

    package func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        _ = try checked(user.name)
        guard !user.isRole else { throw Self.refusal("A role has no password.") }
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        return Self.withPassword(["updateUser": .string(user.name)], password, in: Self.database(user))
    }

    package func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        try UserStatement(Self.command(rolesCommand(grant: true, privileges, on: target, user), in: Self.database(user)))
    }

    package func revoke(_ privileges: [String], on target: GrantTarget, from user: DatabaseUser) throws -> UserStatement {
        try UserStatement(Self.command(rolesCommand(grant: false, privileges, on: target, user), in: Self.database(user)))
    }

    private func rolesCommand(grant: Bool, _ privileges: [String], on target: GrantTarget, _ user: DatabaseUser) throws -> BSONDocument {
        _ = try checked(user.name)
        guard case .database(let name) = target else { throw Self.refusal("MongoDB grants roles on a database.") }
        _ = try checked(name, "A database")
        let allowed = self.privileges(on: target)
        guard !privileges.isEmpty else { throw Self.refusal("Pick a role.") }
        for privilege in privileges where !allowed.contains(privilege) {
            throw Self.refusal("\(privilege) isn't a role on \(name).")
        }
        let verb = (grant ? "grantRolesTo" : "revokeRolesFrom") + (user.isRole ? "Role" : "User")
        return [verb: .string(user.name), "roles": Self.roles(privileges, in: name)]
    }

    package func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement {
        _ = try checked(user.name)
        _ = try checked(role.name, "A role")
        let verb = user.isRole ? "grantRolesToRole" : "grantRolesToUser"
        return UserStatement(Self.command([verb: .string(user.name), "roles": Self.roles([role.name], in: Self.database(role))], in: Self.database(user)))
    }

    package func revokeRole(_ role: DatabaseUser, from user: DatabaseUser) throws -> UserStatement {
        _ = try checked(user.name)
        _ = try checked(role.name, "A role")
        let verb = user.isRole ? "revokeRolesFromRole" : "revokeRolesFromUser"
        return UserStatement(Self.command([verb: .string(user.name), "roles": Self.roles([role.name], in: Self.database(role))], in: Self.database(user)))
    }

    package func drop(_ user: DatabaseUser) throws -> UserStatement {
        _ = try checked(user.name)
        return UserStatement(Self.command([user.isRole ? "dropRole" : "dropUser": .string(user.name)], in: Self.database(user)))
    }

    /// A role granted (`readWrite@shop`) is revoked; a privilege it gives isn't
    /// the user's own to revoke.
    package func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard grant.kind == "role", let at = grant.object.lastIndex(of: "@") else { return nil }
        let role = DatabaseUser(name: String(grant.object[..<at]), host: String(grant.object[grant.object.index(after: at)...]), isRole: true)
        return try? revokeRole(role, from: user)
    }
}
