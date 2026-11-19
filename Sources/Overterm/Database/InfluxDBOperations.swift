import Foundation

/// InfluxDB's Server page and users, by version. 1.x: `SHOW DIAGNOSTICS`,
/// `SHOW STATS` (shards' disk bytes), `SHOW QUERIES` and `KILL QUERY`;
/// users in InfluxQL. 2.x: `/health`, `/metrics`' headline numbers, the
/// buckets with their retention and disk; users and their tokens over the
/// API (a token's value never read). 3.x: its health and version — it
/// lists no queries over HTTP and has tokens, not users. No rows are
/// edited: a point isn't updated in place (a write of the same series and
/// time overwrites it), and a delete is by time range and predicate, not
/// by a row. docs/architecture.md, Database: Server page, Users and roles.
extension InfluxDBDriver: DatabaseMonitoring, DatabaseUserManagement {
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .sizes] }

    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        [
            SessionStop(
                terminate: false, menu: "Kill Query…", title: "Kill query \(session.id)?", command: "KILL QUERY \(session.id)",
                effect: [session.database, OpsText.statement(session.statement, limit: 400)].compactMap { $0 }.joined(separator: "\n")
                    + "\n\nThe query stops; whoever asked gets an error.", button: "Kill")
        ]
    }

    /// An InfluxQL read's series; a refusal for want of admin said as a gap.
    private func admin(_ statement: String) async throws -> Monitored<[InfluxParse.Series]> {
        do {
            return .value(try await influxQL(statement, database: nil, write: false).last ?? [])
        } catch {
            let message = error.localizedDescription
            if message.contains("authoriz") || message.contains("admin privilege") {
                return .unavailable(
                    MonitorGap(
                        reason: "\(statement) needs an admin user: \(message)",
                        fix: config.user.isEmpty ? "GRANT ALL PRIVILEGES TO \"<user>\"" : "GRANT ALL PRIVILEGES TO \(InfluxUserStatements.name(config.user))"))
            }
            throw error
        }
    }

    func overview() async throws -> ServerOverview {
        switch try await resolvedVersion() {
        case .v1:
            var notes: [String] = []
            let diagnostics = try await admin("SHOW DIAGNOSTICS")
            let stats = try await admin("SHOW STATS")
            if let gap = diagnostics.gap ?? stats.gap { notes.append(gap.reason) }
            var overview = InfluxOps.overview1(diagnostics: diagnostics.value ?? [], stats: stats.value ?? [])
            overview.notes += notes
            return overview
        case .v2:
            let health = (try? await send("GET", "/health")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let metrics: String?
            do {
                metrics = String(decoding: try await send("GET", "/metrics", accept: "text/plain"), as: UTF8.self)
            } catch {
                metrics = nil
            }
            var overview = InfluxOps.overview2(health: health, metrics: metrics.map(InfluxOps.metrics) ?? [])
            if metrics == nil { overview.notes.append("/metrics didn't answer — it is off (metrics-disabled) or behind a proxy.") }
            return overview
        case .v3:
            let health = (try? await send("GET", "/health", accept: "text/plain")).map { String(decoding: $0, as: UTF8.self) } ?? "—"
            return ServerOverview(
                facts: [ServerFact(title: "InfluxDB", value: "3", detail: health.trimmingCharacters(in: .whitespacesAndNewlines))],
                notes: ["InfluxDB 3 lists neither its running queries nor its storage over HTTP; `influxdb3 show system` reads them from its own tables."])
        }
    }

    func activity() async throws -> Monitored<[DatabaseActivity]> {
        switch try await resolvedVersion() {
        case .v1:
            switch try await admin("SHOW QUERIES") {
            case .value(let series): return .value(InfluxOps.queries(series))
            case .unavailable(let gap): return .unavailable(gap)
            }
        case .v2:
            return .unavailable(
                MonitorGap(reason: "InfluxDB 2 doesn't list the queries it is running — its /metrics counts them (Queries running, on the Overview)."))
        case .v3:
            return .unavailable(MonitorGap(reason: "InfluxDB 3 doesn't list its queries over HTTP — `influxdb3 show system table queries` does."))
        }
    }

    func sizes() async throws -> Monitored<DatabaseSizes> {
        switch try await resolvedVersion() {
        case .v1:
            switch try await admin("SHOW STATS FOR 'shard'") {
            case .value(let series): return .value(InfluxOps.shardSizes(series))
            case .unavailable(let gap): return .unavailable(gap)
            }
        case .v2:
            var buckets: [[String: Any]] = []
            var offset = 0
            while true {
                let data = try await send("GET", "/api/v2/buckets", [("org", organization), ("limit", "100"), ("offset", "\(offset)")])
                let page = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["buckets"] as? [[String: Any]]) ?? []
                buckets += page
                if page.count < 100 || buckets.count >= 5000 { break }
                offset += 100
            }
            let metrics = (try? await send("GET", "/metrics", accept: "text/plain")).map { InfluxOps.metrics(String(decoding: $0, as: UTF8.self)) }
            return .value(InfluxOps.bucketSizes(buckets, metrics: metrics))
        case .v3:
            return .unavailable(MonitorGap(reason: "InfluxDB 3 doesn't say its storage over HTTP."))
        }
    }

    func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("KILL QUERY") }
        guard try await resolvedVersion() == .v1 else { throw DatabaseError.failed("Only InfluxDB 1 kills a query.") }
        guard let id = Int(session) else { throw DatabaseError.failed("\(session) isn't a query's id.") }
        if case .value(let series) = try await admin("SHOW QUERIES"), InfluxOps.queries(series).contains(where: { $0.id == session && $0.isOwn }) {
            throw DatabaseError.failed("That is this page's own query.")
        }
        _ = try await influxQL("KILL QUERY \(id)", database: nil, write: true)
    }

    // MARK: Users

    func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own

    func userStatements() async -> any UserStatementMaking {
        (try? await resolvedVersion()) == .v2 ? Influx2UserStatements() : InfluxUserStatements()
    }

    func users() async throws -> Monitored<[DatabaseUser]> {
        switch try await resolvedVersion() {
        case .v1:
            switch try await admin("SHOW USERS") {
            case .value(let series): return .value(InfluxOps.users1(series))
            case .unavailable(let gap): return .unavailable(gap)
            }
        case .v2:
            do {
                // A page is 100 at most.
                var users: [DatabaseUser] = []
                var offset = 0
                while true {
                    let page = InfluxOps.users2(try await send("GET", "/api/v2/users", [("limit", "100"), ("offset", "\(offset)")]))
                    users += page
                    if page.count < 100 || users.count >= 10_000 { break }
                    offset += 100
                }
                return .value(users)
            } catch {
                return .unavailable(
                    MonitorGap(reason: "This token may not read the users: \(error.localizedDescription)", fix: "influx auth create --read-users …  (or the operator token)"))
            }
        case .v3:
            return .unavailable(MonitorGap(reason: "InfluxDB 3 has tokens, not users — `influxdb3 create token` makes them."))
        }
    }

    func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        switch try await resolvedVersion() {
        case .v1:
            if user.superuser { return .value([DatabaseGrant(kind: "admin", object: "every database", privileges: ["ALL PRIVILEGES"], target: .server)]) }
            let series = try await influxQL("SHOW GRANTS FOR \(InfluxUserStatements.name(user.name))", database: nil, write: false).last ?? []
            return .value(InfluxOps.grants1(series))
        case .v2:
            guard let id = try await userID(user.name) else { return .unavailable(MonitorGap(reason: "\(user.name) is gone.")) }
            let data = try await send("GET", "/api/v2/authorizations", [("userID", id)])
            return .value(InfluxOps.tokens(data))
        case .v3:
            return .unavailable(MonitorGap(reason: "InfluxDB 3 has tokens, not users."))
        }
    }

    private func userID(_ name: String) async throws -> String? {
        let data: Data
        do {
            data = try await send("GET", "/api/v2/users", [("name", name)])
        } catch {
            // No such user is a 404.
            if error.localizedDescription.contains("not found") { return nil }
            throw error
        }
        let users = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["users"] as? [[String: Any]] ?? []
        return users.first { $0["name"] as? String == name }?["id"] as? String
    }

    /// 1.x: each statement InfluxQL, a POST. 2.x: each a request, its
    /// `{user:name}` and `{org}` the ids they name, looked up first.
    func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        let version = try await resolvedVersion()
        for statement in statements {
            do {
                if version == .v2 {
                    guard let request = UserRequest(statement.sql) else { throw DatabaseError.failed("Couldn't read \(statement.shown).") }
                    let path = try await resolved(request.path)
                    var body: String?
                    if let raw = request.body { body = try await resolved(raw) }
                    if request.onlyNew, try await userID(Influx2UserStatements.newName(request.body) ?? "") != nil {
                        throw DatabaseError.failed("There is already such a user — nothing was changed.")
                    }
                    _ = try await send(request.method, path, body: body.map { Data($0.utf8) }, contentType: body == nil ? nil : "application/json")
                } else {
                    _ = try await influxQL(statement.sql, database: nil, write: true)
                }
            } catch {
                throw DatabaseError.failed(statement.scrub(error.localizedDescription))
            }
        }
    }

    /// `{user:alice}` → alice's id, `{org}` → the organization's.
    private func resolved(_ text: String) async throws -> String {
        var out = text
        while let range = out.range(of: #"\{user:[^}]*\}"#, options: .regularExpression) {
            let encoded = String(out[range].dropFirst(6).dropLast())
            let name = encoded.removingPercentEncoding ?? encoded
            guard let id = try await userID(name) else { throw DatabaseError.failed("There's no user \(name).") }
            out.replaceSubrange(range, with: id)
        }
        if out.contains("{org}") {
            let data = try await send("GET", "/api/v2/orgs", [("org", organization)])
            let orgs = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["orgs"] as? [[String: Any]] ?? []
            guard let id = orgs.first?["id"] as? String else { throw DatabaseError.failed("There's no organization \(organization).") }
            out = out.replacingOccurrences(of: "{org}", with: id)
        }
        return out
    }
}

/// InfluxDB's answers read. Pure.
enum InfluxOps {
    /// A series' first row as a dictionary.
    static func fields(_ series: InfluxParse.Series) -> [String: String] {
        guard let row = series.values.first else { return [:] }
        var fields: [String: String] = [:]
        for (at, column) in series.columns.enumerated() where at < row.count { fields[column] = row[at] }
        return fields
    }

    /// Go's duration text: `1h2m3.5s`, `150ms`, `12µs`.
    static func goDuration(_ text: String) -> Double? {
        var total = 0.0
        var number = ""
        var unit = ""
        var any = false
        func flush() -> Bool {
            guard !number.isEmpty else { return unit.isEmpty }
            guard let value = Double(number) else { return false }
            let scale: Double? =
                switch unit {
                case "h": 3600
                case "m": 60
                case "s": 1
                case "ms": 0.001
                case "us", "µs", "μs": 0.000_001
                case "ns": 0.000_000_001
                default: nil
                }
            guard let scale else { return false }
            total += value * scale
            any = true
            number = ""
            unit = ""
            return true
        }
        for c in text.trimmingCharacters(in: .whitespaces) {
            if c.isNumber || c == "." {
                if !unit.isEmpty, !flush() { return nil }
                number.append(c)
            } else {
                unit.append(c)
            }
        }
        guard flush(), any else { return nil }
        return total
    }

    static func overview1(diagnostics: [InfluxParse.Series], stats: [InfluxParse.Series]) -> ServerOverview {
        var facts: [ServerFact] = []
        let build = diagnostics.first { $0.name == "build" }.map(fields) ?? [:]
        let system = diagnostics.first { $0.name == "system" }.map(fields) ?? [:]
        facts.append(ServerFact(title: "InfluxDB", value: build["Version"] ?? "1.x", detail: build["Commit"].map { "commit \($0.prefix(8))" }))
        if let uptime = system["uptime"] { facts.append(ServerFact(title: "Up", value: goDuration(uptime).map(OpsText.duration) ?? uptime)) }
        let databases = stats.filter { $0.name == "database" }
        if !databases.isEmpty {
            let series = databases.compactMap { fields($0)["numSeries"].flatMap(Int.init) }.reduce(0, +)
            facts.append(ServerFact(title: "Databases", value: "\(databases.count)", detail: "\(series) series"))
        }
        let runtime = stats.first { $0.name == "runtime" }.map(fields) ?? [:]
        if let heap = runtime["HeapInUse"].flatMap(Int64.init) {
            facts.append(ServerFact(title: "Heap in use", value: OpsText.bytes(heap), detail: runtime["NumGoroutine"].map { "\($0) goroutines" }))
        }
        let queries = stats.first { $0.name == "queryExecutor" }.map(fields) ?? [:]
        if let active = queries["queriesActive"] {
            facts.append(ServerFact(title: "Queries running", value: active, detail: queries["queriesExecuted"].map { "\($0) run since start" }))
        }
        let http = stats.first { $0.name == "httpd" }.map(fields) ?? [:]
        if let written = http["pointsWrittenOK"] {
            facts.append(ServerFact(title: "Points written", value: written, detail: http["writeReq"].map { "in \($0) writes" }))
        }
        let disk = stats.filter { $0.name == "shard" }.compactMap { fields($0)["diskBytes"].flatMap(Int64.init) }.reduce(0, +)
        if disk > 0 { facts.append(ServerFact(title: "Shards on disk", value: OpsText.bytes(disk))) }
        return ServerOverview(facts: facts)
    }

    /// Prometheus text: each sample's name, labels and value.
    struct Sample: Equatable {
        var name: String
        var labels: [String: String]
        var value: Double
    }

    static func metrics(_ text: String) -> [Sample] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#"), let space = line.lastIndex(of: " ") else { return nil }
            let head = line[..<space]
            guard let value = Double(line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)) else { return nil }
            guard let brace = head.firstIndex(of: "{"), head.hasSuffix("}") else { return Sample(name: String(head), labels: [:], value: value) }
            var labels: [String: String] = [:]
            let inside = head[head.index(after: brace)..<head.index(before: head.endIndex)]
            // `a="x",b="y"` — values don't hold `",` in what is read here.
            for pair in inside.components(separatedBy: "\",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                labels[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ", "))] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return Sample(name: String(head[..<brace]), labels: labels, value: value)
        }
    }

    static func overview2(health: [String: Any], metrics: [Sample]) -> ServerOverview {
        func sum(_ name: String) -> Double? {
            let found = metrics.filter { $0.name == name }
            return found.isEmpty ? nil : found.reduce(0) { $0 + $1.value }
        }
        var facts = [
            ServerFact(title: "InfluxDB", value: health["version"] as? String ?? "2.x", detail: (health["status"] as? String).map { "health \($0)" })
        ]
        if let uptime = sum("influxdb_uptime_seconds") { facts.append(ServerFact(title: "Up", value: OpsText.duration(uptime))) }
        if let buckets = sum("influxdb_buckets_total") {
            facts.append(ServerFact(title: "Buckets", value: String(Int(buckets)), detail: sum("influxdb_organizations_total").map { "\(Int($0)) organizations" }))
        }
        if let users = sum("influxdb_users_total") {
            facts.append(ServerFact(title: "Users", value: String(Int(users)), detail: sum("influxdb_tokens_total").map { "\(Int($0)) tokens" }))
        }
        if let disk = sum("storage_shard_disk_size") { facts.append(ServerFact(title: "Shards on disk", value: OpsText.bytes(Int64(disk)))) }
        if let memory = sum("go_memstats_alloc_bytes") { facts.append(ServerFact(title: "Memory", value: OpsText.bytes(Int64(memory)), detail: "Go heap allocated")) }
        if let running = sum("qc_executing_active") {
            facts.append(ServerFact(title: "Queries running", value: String(Int(running)), detail: sum("qc_queueing_active").map { "\(Int($0)) queued" }))
        }
        var notes: [String] = []
        if let message = health["message"] as? String, health["status"] as? String != "pass" { notes.append(message) }
        return ServerOverview(facts: facts, notes: notes)
    }

    /// `SHOW QUERIES`' rows: qid, query, database, duration, status.
    static func queries(_ series: [InfluxParse.Series]) -> [DatabaseActivity] {
        series.flatMap { s -> [DatabaseActivity] in
            s.values.compactMap { row in
                var fields: [String: String] = [:]
                for (at, column) in s.columns.enumerated() where at < row.count { fields[column] = row[at] }
                guard let id = fields["qid"] else { return nil }
                let query = fields["query"]
                return DatabaseActivity(
                    id: id, database: fields["database"].flatMap { $0.isEmpty ? nil : $0 }, state: fields["status"] ?? "running", statement: query,
                    seconds: fields["duration"].flatMap(goDuration), isOwn: query?.trimmingCharacters(in: .whitespaces).uppercased() == "SHOW QUERIES")
            }
        }
    }

    /// `SHOW STATS FOR 'shard'`: disk bytes by database, and by retention policy.
    static func shardSizes(_ series: [InfluxParse.Series]) -> DatabaseSizes {
        var databases: [String: Int64] = [:]
        var policies: [String: (database: String, policy: String, bytes: Int64, shards: Int)] = [:]
        for s in series where s.name == "shard" {
            let bytes = fields(s)["diskBytes"].flatMap(Int64.init) ?? 0
            let database = s.tags["database"] ?? "?"
            let policy = s.tags["retentionPolicy"] ?? "?"
            databases[database, default: 0] += bytes
            let key = database + "\u{1}" + policy
            policies[key, default: (database, policy, 0, 0)].bytes += bytes
            policies[key, default: (database, policy, 0, 0)].shards += 1
        }
        var sizes = DatabaseSizes()
        sizes.databases = databases.map { SizeEntry(name: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
        sizes.tables = policies.values.map {
            SizeEntry(name: $0.policy, schema: $0.database, bytes: $0.bytes, detail: "retention policy · \($0.shards) shard\($0.shards == 1 ? "" : "s")")
        }.sorted { $0.bytes > $1.bytes }
        return sizes
    }

    /// Buckets with their retention, and their shards' bytes from `/metrics`.
    static func bucketSizes(_ buckets: [[String: Any]], metrics: [Sample]?) -> DatabaseSizes {
        var bytes: [String: Int64] = [:]
        for sample in metrics ?? [] where sample.name == "storage_shard_disk_size" {
            if let bucket = sample.labels["bucket"] { bytes[bucket, default: 0] += Int64(sample.value) }
        }
        var sizes = DatabaseSizes()
        sizes.databases = buckets.compactMap { bucket in
            guard let name = bucket["name"] as? String else { return nil }
            let every = ((bucket["retentionRules"] as? [[String: Any]])?.first?["everySeconds"] as? NSNumber)?.doubleValue ?? 0
            let retention = every > 0 ? "retention \(OpsText.duration(every))" : "kept forever"
            let system = bucket["type"] as? String == "system" ? " · InfluxDB's own" : ""
            return SizeEntry(name: name, bytes: bytes[bucket["id"] as? String ?? ""] ?? 0, detail: retention + system)
        }.sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
        if metrics == nil { sizes.notes.append("No bytes: /metrics didn't answer.") }
        return sizes
    }

    /// `SHOW USERS`: user, admin.
    static func users1(_ series: [InfluxParse.Series]) -> [DatabaseUser] {
        series.flatMap { s in
            s.values.compactMap { row -> DatabaseUser? in
                let user = s.columns.firstIndex(of: "user").flatMap { row[safe: $0] ?? nil }
                let admin = s.columns.firstIndex(of: "admin").flatMap { row[safe: $0] ?? nil } == "true"
                return user.map { DatabaseUser(name: $0, superuser: admin, attributes: admin ? ["admin"] : []) }
            }
        }
    }

    /// `SHOW GRANTS FOR`: database, privilege (NO PRIVILEGES left out).
    static func grants1(_ series: [InfluxParse.Series]) -> [DatabaseGrant] {
        series.flatMap { s in
            s.values.compactMap { row -> DatabaseGrant? in
                guard let database = s.columns.firstIndex(of: "database").flatMap({ row[safe: $0] ?? nil }),
                    let privilege = s.columns.firstIndex(of: "privilege").flatMap({ row[safe: $0] ?? nil }), privilege != "NO PRIVILEGES"
                else { return nil }
                return DatabaseGrant(kind: "database", object: database, privileges: [privilege], target: .database(database))
            }
        }
    }

    static func users2(_ data: Data) -> [DatabaseUser] {
        let users = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["users"] as? [[String: Any]] ?? []
        return users.compactMap { user in
            guard let name = user["name"] as? String else { return nil }
            let active = (user["status"] as? String ?? "active") == "active"
            return DatabaseUser(name: name, canLogin: active, attributes: active ? [] : ["inactive"])
        }
    }

    /// A user's tokens as its grants: each one's description and
    /// permissions — never the token itself, which isn't decoded.
    static func tokens(_ data: Data) -> [DatabaseGrant] {
        let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["authorizations"] as? [[String: Any]] ?? []
        return list.compactMap { token in
            guard let id = token["id"] as? String else { return nil }
            let permissions = (token["permissions"] as? [[String: Any]] ?? []).map { permission -> String in
                let resource = permission["resource"] as? [String: Any] ?? [:]
                let what = [resource["type"] as? String, resource["name"] as? String].compactMap { $0 }.joined(separator: " ")
                return "\(permission["action"] as? String ?? "?") \(what.isEmpty ? "?" : what)"
            }
            let description = (token["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "token \(id)"
            let status = token["status"] as? String == "inactive" ? " (inactive)" : ""
            return DatabaseGrant(kind: "token", object: description + status, privileges: permissions, target: .named(kind: "token", name: id))
        }
    }
}

/// InfluxDB 1.x's user statements in InfluxQL, names in double quotes and
/// passwords in single, each escaped as InfluxQL reads them. The password
/// is sent once (InfluxDB redacts it from its own query log). Pure.
struct InfluxUserStatements: UserStatementMaking {
    static func name(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static let mask = "'••••••••'"

    var form: UserForm {
        UserForm(
            superuser: "Admin (ALL PRIVILEGES)",
            passwordNote: "The password is sent once, over this connection — InfluxDB keeps it out of its query log — and never kept here.",
            grantKinds: [GrantKind(title: "Database", fields: [GrantField(title: "Database", fill: .database)]), GrantKind(title: "Server (admin)")],
            noGrants: "No privileges.")
    }

    func create(_ user: NewUser) throws -> [UserStatement] {
        let head = "CREATE USER \(Self.name(try checked(user.name))) WITH PASSWORD "
        guard !user.password.isEmpty else { throw Self.refusal("A password, please.") }
        let tail = user.superuser ? " WITH ALL PRIVILEGES" : ""
        return [UserStatement(head + Self.literal(user.password) + tail, shown: head + Self.mask + tail)]
    }

    func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        let head = "SET PASSWORD FOR \(Self.name(try checked(user.name))) = "
        return UserStatement(head + Self.literal(password), shown: head + Self.mask)
    }

    func offers(_ action: UserAction, on user: DatabaseUser) -> Bool { action != .grantRole }

    func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        kind.title == "Database" ? .database(fields.first ?? "") : .server
    }

    func privileges(on target: GrantTarget) -> [String] {
        if case .server = target { return ["ALL PRIVILEGES"] }
        return ["READ", "WRITE", "ALL"]
    }

    func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        let name = Self.name(try checked(user.name))
        guard !privileges.isEmpty else { throw Self.refusal("Pick a privilege.") }
        for privilege in privileges where !self.privileges(on: target).contains(privilege) { throw Self.refusal("\(privilege) isn't an InfluxDB privilege here.") }
        switch target {
        case .server:
            return UserStatement("GRANT ALL PRIVILEGES TO \(name)")
        case .database(let database):
            let both = privileges.contains("ALL") || (privileges.contains("READ") && privileges.contains("WRITE"))
            let privilege = both ? "ALL" : privileges[0]
            return UserStatement("GRANT \(privilege) ON \(Self.name(try checked(database, "A database"))) TO \(name)")
        default:
            throw Self.refusal("InfluxDB grants on a database, or everything.")
        }
    }

    func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard let name = try? checked(user.name) else { return nil }
        switch grant.target {
        case .server?: return UserStatement("REVOKE ALL PRIVILEGES FROM \(Self.name(name))")
        case .database(let database)?:
            let privilege = grant.privileges.first == "READ" ? "READ" : grant.privileges.first == "WRITE" ? "WRITE" : "ALL"
            return UserStatement("REVOKE \(privilege) ON \(Self.name(database)) FROM \(Self.name(name))")
        default: return nil
        }
    }

    func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] { [] }

    func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement { throw Self.refusal("InfluxDB has no roles.") }

    func drop(_ user: DatabaseUser) throws -> UserStatement { UserStatement("DROP USER \(Self.name(try checked(user.name)))") }
}

/// InfluxDB 2's users over its API: created, a password set, made a member
/// of the connection's organization; dropped; a token revoked (deleted).
/// `{user:name}` and `{org}` are ids the driver looks up just before
/// sending. Tokens aren't made here — a token's value would have to be
/// shown; `influx auth create` makes them. The password goes as InfluxDB 2's
/// API takes it — in the request body — and is never kept. Pure.
struct Influx2UserStatements: UserStatementMaking {
    var form: UserForm {
        UserForm(
            superuser: nil, passwordNote: "The password is sent once, in the request's body as InfluxDB 2's API takes it, and never kept here.",
            grantsNote: "Its tokens, by description and what each may do — never a token's value. Revoke deletes one.",
            noGrants: "No tokens.")
    }

    private static func user(_ name: String) -> String { "{user:\(RabbitText.segment(name))}" }

    /// The name a create's body gives.
    static func newName(_ body: String?) -> String? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        return object["name"] as? String
    }

    func create(_ user: NewUser) throws -> [UserStatement] {
        let name = try checked(user.name)
        guard !user.password.isEmpty else { throw Self.refusal("A password, please.") }
        guard user.password.count >= 8 else { throw Self.refusal("InfluxDB 2 wants a password of 8 characters or more.") }
        return [
            UserStatement("NEW POST /api/v2/users \(UserRequest.json(["name": name, "status": "active"]))"),
            try password(of: DatabaseUser(name: name), to: user.password),
            UserStatement("POST /api/v2/orgs/{org}/members \(UserRequest.json(["id": Self.user(name)]))"),
        ]
    }

    func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        let path = "POST /api/v2/users/\(Self.user(try checked(user.name)))/password "
        guard password.count >= 8 else { throw Self.refusal("InfluxDB 2 wants a password of 8 characters or more.") }
        return UserStatement(path + UserRequest.json(["password": password]), shown: path + UserRequest.json(["password": "••••••••"]))
    }

    func offers(_ action: UserAction, on user: DatabaseUser) -> Bool { action == .password || action == .drop }

    func target(_ kind: GrantKind, fields: [String]) -> GrantTarget { .server }

    func privileges(on target: GrantTarget) -> [String] { [] }

    func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        throw Self.refusal("Tokens are made with `influx auth create`: a new token's value would have to be shown.")
    }

    func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard case .named("token", let id)? = grant.target, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return UserStatement("DELETE /api/v2/authorizations/\(id)")
    }

    func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] { [] }

    func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement { throw Self.refusal("InfluxDB has no roles.") }

    func drop(_ user: DatabaseUser) throws -> UserStatement { UserStatement("DELETE /api/v2/users/\(Self.user(try checked(user.name)))") }
}
