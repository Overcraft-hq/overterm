import Foundation

// Elasticsearch's and OpenSearch's Server page, a search's hits edited, and
// their security plugin's users and roles — every request through the
// driver's own session and credentials. docs/architecture.md, Database:
// Server page, Editing rows, Users and roles.

extension SearchDriver: DatabaseMonitoring {
    /// No locks to wait on: a search engine has none a client takes.
    static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .slowQueries, .sizes] }

    /// A task is cancelled where it is cancellable; the node ends it.
    static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        [
            SessionStop(
                terminate: false, menu: "Cancel Task…", title: "Cancel task \(session.id)?", command: "POST /_tasks/\(session.id)/_cancel",
                effect: SessionStop.said(session) + "\n\nThe task stops where it can; what it already wrote stays.", button: "Cancel Task")
        ]
    }

    func overview() async throws -> ServerOverview {
        if product == nil { try await connect() }
        var notes: [String] = []
        let health = (try? await json("/_cluster/health")) as? [String: Any]
        if health == nil { notes.append("_cluster/health wasn't readable — it takes the monitor cluster privilege.") }
        let nodes = (try? await json("/_nodes/stats/jvm,os,fs")) as? [String: Any]
        var overview = SearchOps.overview(product: product ?? kind.title, health: health ?? [:], nodes: nodes ?? [:])
        // What the nodes are busy with: hot_threads' headline lines.
        if let (data, _) = try? await checked(SearchRequest(method: "GET", path: "/_nodes/hot_threads?threads=3&interval=200ms", body: nil)) {
            overview.notes += SearchOps.hotThreads(String(decoding: data, as: UTF8.self))
        }
        overview.notes = notes + overview.notes
        return overview
    }

    func activity() async throws -> Monitored<[DatabaseActivity]> {
        do {
            return .value(SearchOps.tasks(try await json("/_tasks?detailed=true&group_by=none")))
        } catch let error as DatabaseError {
            return .unavailable(MonitorGap(reason: "The tasks couldn't be listed: \(error.localizedDescription) — it takes the monitor cluster privilege."))
        }
    }

    func slowQueries() async throws -> Monitored<[SlowQuery]> {
        if kind == .opensearch {
            // OpenSearch's Query Insights plugin keeps the slowest searches.
            let (data, status) = try await send(SearchRequest(method: "GET", path: "/_insights/top_queries?type=latency", body: nil))
            if status == 200 {
                let top = SearchOps.topQueries(data)
                // Off, it answers an empty list: the setting says why.
                guard top.isEmpty else { return .value(top) }
                // (filter_path can't name a flat key: it splits on its dots.)
                let settings = try? await json("/_cluster/settings?include_defaults=true&flat_settings=true")
                guard SearchOps.insightsOff(settings) else { return .value(top) }
            }
            let said = SearchResults.error(data, status: status)
            if status == 200 || said.contains("not enabled") {
                return .unavailable(
                    MonitorGap(
                        reason: "OpenSearch's Query Insights is installed but keeps no top queries: its latency record is off. Turn it on:",
                        fix: #"PUT /_cluster/settings {"persistent": {"search.insights.top_queries.latency.enabled": true}}"#))
            }
        }
        let thresholds = (try? await json("/_all/_settings/index.search.slowlog.threshold.*?flat_settings=true")) as? [String: Any] ?? [:]
        return .unavailable(SearchOps.slowlogGap(thresholds, kind: kind))
    }

    func sizes() async throws -> Monitored<DatabaseSizes> {
        do {
            let rows = try await json("/_cat/indices?format=json&bytes=b&h=index,docs.count,store.size,pri,rep,health,status&s=store.size:desc")
            return .value(SearchOps.sizes(rows as? [[String: Any]] ?? []))
        } catch let error as DatabaseError {
            return .unavailable(MonitorGap(reason: "The indices couldn't be listed: \(error.localizedDescription)"))
        }
    }

    func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("POST _tasks/_cancel") }
        guard !terminate else { throw DatabaseError.failed("A task is cancelled; there is no session to end.") }
        guard SearchOps.isTaskID(session) else { throw DatabaseError.failed("“\(session)” isn't a task's id (node:number).") }
        let (data, _) = try await checked(SearchRequest(method: "POST", path: "/_tasks/\(session)/_cancel", body: nil))
        // A task or node not found is a 200 with its failure inside.
        if let failure = SearchOps.cancelFailure(data) { throw DatabaseError.failed("Task \(session) wasn't cancelled: \(failure)") }
    }
}

// MARK: Editing hits

extension SearchDriver: DatabaseTableEditing {
    func editDialect() async -> SQLDialect { .postgres }

    /// Not SQL: a search's hits are found by `editableResult`.
    func key(of table: TableName) async throws -> TableKey? { nil }

    func editableResult(for statement: String, result: QueryResult) async throws -> Result<EditableResult, EditRefusal>? {
        let request: SearchRequest
        do {
            request = try SearchRequest.parse(statement)
        } catch {
            return .failure(.said(error.localizedDescription))
        }
        return SearchEdits.editable(request, result: result)
    }

    func editStatements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) async throws -> [EditStatement] {
        try SearchEdits.statements(edits, rows: rows, result: result)
    }

    func editSaveNote() async -> String {
        "One by one — \(kind.title) has no transactions: a failure (a document changed since it was read, or gone) stops the rest, and those before it are kept. Each waits for the index to refresh, so the hits read again show it."
    }

    func apply(_ statements: [EditStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("a write") }
        let requests = try statements.map { statement -> SearchRequest in
            let request = try SearchRequest.parse(statement.sql)
            guard ["_update", "_doc", "_create"].contains(request.endpoint ?? "") else { throw DatabaseError.failed("Not a document's write: \(request.verb)") }
            return request
        }
        for request in requests {
            let (data, status) = try await send(request)
            if status == 409 {
                throw DatabaseError.failed("\(request.verb): the document changed since it was read (a version conflict) — nothing after it ran.")
            }
            if status == 404 { throw DatabaseError.failed("\(request.verb): the document is gone — nothing after it ran.") }
            guard (200..<300).contains(status) else { throw DatabaseError.failed("\(request.verb): \(SearchResults.error(data, status: status))") }
        }
    }
}

// MARK: Users and roles

extension SearchDriver: DatabaseUserManagement {
    func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own

    func userStatements() async -> any UserStatementMaking { SearchUserStatements(opensearch: kind == .opensearch) }

    func users() async throws -> Monitored<[DatabaseUser]> {
        if kind == .opensearch {
            do {
                let users = try await securityRead("/_plugins/_security/api/internalusers").get()
                let roles = try await securityRead("/_plugins/_security/api/roles").get()
                let mapping = (try? await securityRead("/_plugins/_security/api/rolesmapping").get()) ?? [:]
                return .value(SearchOps.openSearchUsers(users, roles: roles, mapping: mapping))
            } catch let gap as MonitorGap {
                return .unavailable(gap)
            }
        }
        do {
            let users = try await securityRead("/_security/user").get()
            let roles = try await securityRead("/_security/role").get()
            return .value(SearchOps.elasticUsers(users, roles: roles))
        } catch let gap as MonitorGap {
            return .unavailable(gap)
        }
    }

    /// A security API's answer, or why it can't be read: security off, or
    /// this user without the privilege to manage it.
    private func securityRead(_ path: String) async throws -> Result<[String: [String: Any]], MonitorGap> {
        let (data, status) = try await send(SearchRequest(method: "GET", path: path, body: nil))
        if (200..<300).contains(status) {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return .success(object.compactMapValues { $0 as? [String: Any] })
        }
        return .failure(SearchOps.securityGap(status: status, said: SearchResults.error(data, status: status), kind: kind, user: config.user))
    }

    func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        let path = kind == .opensearch ? "/_plugins/_security/api/roles" : "/_security/role"
        switch try await securityRead(path) {
        case .success(let roles): return .value(SearchOps.grants(of: user, roles: roles))
        case .failure(let gap): return .unavailable(gap)
        }
    }

    /// Each a request as the console writes it (`SearchUserStatements`),
    /// sent once; the error the server's words, never the request's body.
    func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("a user change") }
        for statement in statements {
            let request: SearchRequest
            do {
                request = try SearchRequest.parse(statement.sql)
            } catch {
                throw DatabaseError.failed("\(statement.shown) couldn't be read.")
            }
            let (data, status) = try await send(request)
            guard (200..<300).contains(status) else { throw DatabaseError.failed("\(request.verb): \(SearchResults.error(data, status: status))") }
        }
    }
}

/// The search engines' answers read for the Server and Users pages. Pure.
enum SearchOps {
    /// `node:42` — nothing that could be a path of its own.
    static func isTaskID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_\-]+:[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Whether Query Insights' latency record is off, by the cluster's
    /// settings (persistent, transient or the default).
    static func insightsOff(_ settings: Any?) -> Bool {
        let object = settings as? [String: Any] ?? [:]
        for level in ["transient", "persistent", "defaults"] {
            if let value = (object[level] as? [String: Any])?["search.insights.top_queries.latency.enabled"] { return "\(value)" != "true" && "\(value)" != "1" }
        }
        return true
    }

    /// `_cancel`'s answer: the node's or the task's failure, when there is one.
    static func cancelFailure(_ data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        for key in ["node_failures", "task_failures"] {
            guard let first = (object[key] as? [[String: Any]])?.first else { continue }
            let cause = (first["caused_by"] as? [String: Any])?["reason"] as? String
            return cause ?? first["reason"] as? String ?? SearchResults.cell(first) ?? "it failed"
        }
        return nil
    }

    static func overview(product: String, health: [String: Any], nodes: [String: Any]) -> ServerOverview {
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        var facts = [ServerFact(title: "Version", value: product, detail: health["cluster_name"] as? String)]
        if let status = health["status"] as? String {
            facts.append(
                ServerFact(
                    title: "Health", value: status, detail: int(health["number_of_pending_tasks"]).map { "\($0) pending task\($0 == 1 ? "" : "s")" }))
        }
        if let count = int(health["number_of_nodes"]) {
            facts.append(ServerFact(title: "Nodes", value: "\(count)", detail: int(health["number_of_data_nodes"]).map { "\($0) data" }))
        }
        if let active = int(health["active_shards"]) {
            let unassigned = int(health["unassigned_shards"]) ?? 0
            let moving = (int(health["relocating_shards"]) ?? 0) + (int(health["initializing_shards"]) ?? 0)
            facts.append(
                ServerFact(
                    title: "Shards", value: "\(active) active",
                    detail: ["\(int(health["active_primary_shards"]) ?? 0) primary", unassigned > 0 ? "\(unassigned) unassigned" : nil, moving > 0 ? "\(moving) moving" : nil]
                        .compactMap { $0 }.joined(separator: " · ")))
        }
        let all = (nodes["nodes"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        if !all.isEmpty {
            let heaps = all.compactMap { node -> (Int64, Int64)? in
                guard let memory = (node["jvm"] as? [String: Any])?["mem"] as? [String: Any], let used = (memory["heap_used_in_bytes"] as? NSNumber)?.int64Value,
                    let max = (memory["heap_max_in_bytes"] as? NSNumber)?.int64Value, max > 0
                else { return nil }
                return (used, max)
            }
            if let worst = heaps.max(by: { Double($0.0) / Double($0.1) < Double($1.0) / Double($1.1) }) {
                facts.append(
                    ServerFact(
                        title: "Heap", value: OpsText.percent(Double(worst.0) / Double(worst.1)),
                        detail: "\(OpsText.bytes(worst.0)) of \(OpsText.bytes(worst.1))\(all.count > 1 ? " — the fullest node" : "")"))
            }
            let cpus = all.compactMap { ((($0["os"] as? [String: Any])?["cpu"] as? [String: Any])?["percent"] as? NSNumber)?.intValue }
            if let busiest = cpus.max() { facts.append(ServerFact(title: "CPU", value: "\(busiest)%", detail: all.count > 1 ? "the busiest node" : nil)) }
            let disks = all.compactMap { ($0["fs"] as? [String: Any])?["total"] as? [String: Any] }
            let total = disks.compactMap { ($0["total_in_bytes"] as? NSNumber)?.int64Value }.reduce(0, +)
            let free = disks.compactMap { ($0["available_in_bytes"] as? NSNumber)?.int64Value }.reduce(0, +)
            if total > 0 {
                facts.append(ServerFact(title: "Disk used", value: OpsText.percent(Double(total - free) / Double(total)), detail: "\(OpsText.bytes(free)) free"))
            }
        }
        return ServerOverview(facts: facts)
    }

    /// hot_threads' headline: each busy thread's share, on its node.
    static func hotThreads(_ text: String) -> [String] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let busy = lines.filter { $0.contains("cpu usage by thread") }.prefix(5)
        return busy.map { "Hot thread: \($0)" }
    }

    /// `_tasks`' running tasks, whichever way grouped. The listing's own task
    /// is this connection's.
    static func tasks(_ answer: Any) -> [DatabaseActivity] {
        var found: [(String, [String: Any])] = []
        let object = answer as? [String: Any] ?? [:]
        if let list = object["tasks"] as? [[String: Any]] {
            for task in list { found.append(("\(task["node"] as? String ?? ""):\((task["id"] as? NSNumber)?.stringValue ?? "")", task)) }
        } else if let byID = object["tasks"] as? [String: Any] {
            for (id, task) in byID { if let task = task as? [String: Any] { found.append((id, task)) } }
        } else if let nodes = object["nodes"] as? [String: Any] {
            for node in nodes.values {
                for (id, task) in ((node as? [String: Any])?["tasks"] as? [String: Any]) ?? [:] { if let task = task as? [String: Any] { found.append((id, task)) } }
            }
        }
        return found.map { id, task in
            let action = task["action"] as? String ?? ""
            let description = task["description"] as? String ?? ""
            let headers = task["headers"] as? [String: Any] ?? [:]
            var index: String?
            if let range = description.range(of: #"indices\[[^\]]*\]"#, options: .regularExpression) {
                index = String(description[range].dropFirst("indices[".count).dropLast())
            }
            let nanos = (task["running_time_in_nanos"] as? NSNumber)?.doubleValue
            return DatabaseActivity(
                id: id, database: index, client: task["node"] as? String, application: headers["X-Opaque-Id"] as? String,
                state: task["cancelled"] as? Bool == true ? "cancelling" : (task["cancellable"] as? Bool == false ? "running (can't cancel)" : "running"),
                statement: [action, description].filter { !$0.isEmpty }.joined(separator: " "), seconds: nanos.map { $0 / 1_000_000_000 },
                isOwn: action.hasPrefix("cluster:monitor/tasks/lists"))
        }.sorted { ($0.seconds ?? 0) > ($1.seconds ?? 0) }
    }

    /// OpenSearch Query Insights' top queries by latency.
    static func topQueries(_ data: Data) -> [SlowQuery] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let entries = object["top_queries"] as? [[String: Any]] ?? []
        return entries.enumerated().map { index, entry in
            let measurement = (entry["measurements"] as? [String: Any])?["latency"] as? [String: Any]
            let number = ((measurement?["number"] ?? entry["latency"]) as? NSNumber)?.doubleValue ?? 0
            let count = max((measurement?["count"] as? NSNumber)?.intValue ?? 1, 1)
            let averaged = measurement?["aggregationType"] as? String == "AVERAGE"
            let total = (averaged ? number * Double(count) : number) / 1000
            let indices = (entry["indices"] as? [String])?.joined(separator: ",") ?? ""
            return SlowQuery(
                id: entry["id"] as? String ?? "\(index)", statement: "\(indices) \(SearchResults.cell(entry["source"]) ?? "")".trimmingCharacters(in: .whitespaces),
                calls: count, total: total, mean: total / Double(count), database: indices.isEmpty ? nil : indices)
        }
    }

    /// Why there is no slow query to list: the slow log is the nodes' files,
    /// and each index's thresholds now — with the line that sets them.
    static func slowlogGap(_ settings: [String: Any], kind: DatabaseKind) -> MonitorGap {
        var set: [String] = []
        for index in settings.keys.sorted() where !SearchCatalog.isHidden(index) {
            let flat = ((settings[index] as? [String: Any])?["settings"] as? [String: Any]) ?? [:]
            let thresholds = flat.keys.sorted().compactMap { key -> String? in
                guard let value = flat[key] as? String, value != "-1" else { return nil }
                return "\(key.replacingOccurrences(of: "index.search.slowlog.threshold.", with: "")) \(value)"
            }
            if !thresholds.isEmpty { set.append("\(index): \(thresholds.joined(separator: ", "))") }
        }
        let now = set.isEmpty ? "No index has a threshold set." : "Thresholds set: " + set.prefix(10).joined(separator: "; ") + (set.count > 10 ? "; …" : "") + "."
        let insights = kind == .opensearch ? " OpenSearch's Query Insights plugin, where installed, keeps the slowest searches readable — it isn't here." : ""
        return MonitorGap(
            reason: "\(kind.title) writes its search slow log to each node's log files, which its API doesn't read back.\(insights) \(now) Set a threshold per index:",
            fix: #"PUT /<index>/_settings {"index.search.slowlog.threshold.query.warn": "1s", "index.search.slowlog.threshold.query.info": "500ms"}"#)
    }

    static func sizes(_ rows: [[String: Any]]) -> DatabaseSizes {
        var sizes = DatabaseSizes()
        let visible = rows.filter { !SearchCatalog.isHidden($0["index"] as? String ?? ".") }
        func number(_ value: Any?) -> Int64 { Int64(value as? String ?? "") ?? (value as? NSNumber)?.int64Value ?? 0 }
        sizes.tables = visible.prefix(50).compactMap { row in
            guard let name = row["index"] as? String else { return nil }
            let docs = number(row["docs.count"])
            let shards = "\(row["pri"] as? String ?? "?") pri/\(row["rep"] as? String ?? "?") rep"
            let closed = row["status"] as? String == "close"
            return SizeEntry(
                name: name, bytes: number(row["store.size"]),
                detail: closed ? "closed" : "\(docs) doc\(docs == 1 ? "" : "s") · \(row["health"] as? String ?? "") · \(shards)")
        }
        let total = visible.map { number($0["store.size"]) }.reduce(0, +)
        sizes.notes.append("\(visible.count) indices, \(OpsText.bytes(total)) in all, replicas included\(visible.count > 50 ? " — the 50 largest listed" : "").")
        return sizes
    }

    /// Why users can't be read: security off, or not this user's to manage.
    static func securityGap(status: Int, said: String, kind: DatabaseKind, user: String) -> MonitorGap {
        let who = user.isEmpty ? "This connection's credentials" : user
        let lower = said.lowercased()
        if lower.contains("security must be explicitly enabled") || lower.contains("security is not enabled") || lower.contains("no handler found")
            || (kind == .opensearch && status == 400)
        {
            return MonitorGap(
                reason: "Security is off on this cluster: it has no users or roles\(kind == .opensearch ? " (the security plugin isn't on)" : " (xpack.security.enabled is false)").")
        }
        if status == 403 || status == 401 {
            let privilege =
                kind == .opensearch
                ? "the security REST API (an admin's certificate, or a role with restapi:admin/internalusers)" : "the manage_security cluster privilege (read_security to read only)"
            return MonitorGap(reason: "\(who) may not read the users — that takes \(privilege). \(said)")
        }
        return MonitorGap(reason: "The users couldn't be read: \(said)")
    }

    /// Elasticsearch's users (`_security/user`) and roles (`_security/role`)
    /// — a user's password is never in either answer.
    static func elasticUsers(_ users: [String: [String: Any]], roles: [String: [String: Any]]) -> [DatabaseUser] {
        var out = users.keys.sorted().map { name -> DatabaseUser in
            let entry = users[name] ?? [:]
            let memberOf = (entry["roles"] as? [String] ?? []).sorted()
            var attributes: [String] = []
            let metadata = entry["metadata"] as? [String: Any] ?? [:]
            if (metadata["_reserved"] as? Bool) == true { attributes.append("built-in") }
            if let full = entry["full_name"] as? String, !full.isEmpty { attributes.append(SearchUserStatements.fullName + full) }
            if let email = entry["email"] as? String, !email.isEmpty { attributes.append(SearchUserStatements.email + email) }
            if metadata.keys.contains(where: { !$0.hasPrefix("_") }) { attributes.append(SearchUserStatements.hasMetadata) }
            return DatabaseUser(
                name: name, canLogin: entry["enabled"] as? Bool ?? true, superuser: memberOf.contains("superuser"), attributes: attributes, memberOf: memberOf)
        }
        out += roles.keys.sorted().map { name in
            let entry = roles[name] ?? [:]
            let builtIn = ((entry["metadata"] as? [String: Any])?["_reserved"] as? Bool) == true
            return DatabaseUser(name: name, isRole: true, canLogin: false, superuser: name == "superuser", attributes: builtIn ? ["built-in"] : [])
        }
        return out
    }

    /// OpenSearch's internal users — their `hash` never read — with the
    /// roles they hold: their own (`opendistro_security_roles`) and those
    /// mapped to them by name or backend role (`rolesmapping`, said apart).
    static func openSearchUsers(_ users: [String: [String: Any]], roles: [String: [String: Any]], mapping: [String: [String: Any]]) -> [DatabaseUser] {
        // A role is mapped to a user by name, or by a backend role it has.
        var mapped: [String: [String]] = [:]
        for (name, entry) in users {
            let backend = Set(entry["backend_roles"] as? [String] ?? [])
            for (role, map) in mapping {
                let byName = (map["users"] as? [String] ?? []).contains(name)
                let byBackend = !backend.isDisjoint(with: map["backend_roles"] as? [String] ?? [])
                if byName || byBackend { mapped[name, default: []].append(role) }
            }
        }
        var out = users.keys.sorted().compactMap { name -> DatabaseUser? in
            let entry = users[name] ?? [:]
            guard entry["hidden"] as? Bool != true else { return nil }
            let own = (entry["opendistro_security_roles"] as? [String] ?? []).sorted()
            let byMapping = (mapped[name] ?? []).sorted()
            var attributes: [String] = []
            if entry["reserved"] as? Bool == true || entry["static"] as? Bool == true { attributes.append("built-in") }
            if !byMapping.isEmpty { attributes.append("mapped: " + byMapping.joined(separator: ", ")) }
            if let backend = entry["backend_roles"] as? [String], !backend.isEmpty { attributes.append("backend roles: " + backend.joined(separator: ", ")) }
            return DatabaseUser(name: name, superuser: (own + byMapping).contains("all_access"), attributes: attributes, memberOf: own)
        }
        out += roles.keys.sorted().compactMap { name in
            let entry = roles[name] ?? [:]
            guard entry["hidden"] as? Bool != true else { return nil }
            let builtIn = entry["reserved"] as? Bool == true || entry["static"] as? Bool == true
            return DatabaseUser(name: name, isRole: true, canLogin: false, superuser: name == "all_access", attributes: builtIn ? ["built-in"] : [])
        }
        return out
    }

    /// A user's roles (each revocable), then what each gives: its cluster
    /// privileges, and per index pattern its privileges.
    static func grants(of user: DatabaseUser, roles: [String: [String: Any]]) -> [DatabaseGrant] {
        var grants: [DatabaseGrant] = []
        var names = user.isRole ? [user.name] : user.memberOf
        if !user.isRole {
            grants += user.memberOf.map { DatabaseGrant(kind: "role", object: $0, privileges: ["granted role"]) }
            if let mapped = user.attributes.first(where: { $0.hasPrefix("mapped: ") }) {
                let byMapping = mapped.dropFirst("mapped: ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                grants += byMapping.map { DatabaseGrant(kind: "mapped role", object: $0, privileges: ["by rolesmapping"]) }
                names += byMapping
            }
        }
        for name in names {
            let entry = roles[name] ?? [:]
            let cluster = (entry["cluster"] ?? entry["cluster_permissions"]) as? [String] ?? []
            if !cluster.isEmpty { grants.append(DatabaseGrant(kind: "server", object: "cluster (\(name))", privileges: cluster)) }
            for index in (entry["indices"] ?? entry["index_permissions"]) as? [[String: Any]] ?? [] {
                let patterns = (index["names"] ?? index["index_patterns"]) as? [String] ?? []
                let privileges = (index["privileges"] ?? index["allowed_actions"]) as? [String] ?? []
                grants.append(DatabaseGrant(kind: "index", object: "\(patterns.joined(separator: ",")) (\(name))", privileges: privileges))
            }
        }
        return grants
    }
}

/// A search's hits as rows edited: each found again by its `_index` and
/// `_id` (its `_routing` where it has one), on the version it was read at
/// when the search asked for it (`seq_no_primary_term`: `if_seq_no`,
/// `if_primary_term`). A cell is a top-level field of `_source` — `_update`
/// with `doc`, or a script where a field is removed —, a new hit `POST
/// /<index>/_doc` (`_create` with an `_id`), a deleted one `DELETE`. Each
/// a request as Dev Tools writes it, and that is what runs. Pure.
enum SearchEdits {
    static let metaColumns: Set<String> = ["_index", "_id", "_score", "_seq_no", "_primary_term", "_routing"]

    static func editable(_ request: SearchRequest, result: QueryResult) -> Result<EditableResult, EditRefusal> {
        guard request.endpoint == "_search", ["GET", "POST"].contains(request.method) else {
            return .failure(.said("Documents are edited in a _search's hits — not another API's answer."))
        }
        guard result.columns.starts(with: ["_index", "_id"]) else { return .failure(.said("These rows aren't hits: an aggregation's, or the fields of a query.")) }
        if let body = request.body, let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any], let source = object["_source"] {
            guard (source as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true else {
                return .failure(.said("A _source filter shows part of each document: leave it out to edit them."))
            }
        }
        // A new hit goes to the one index the search names, unless its own
        // _index cell says another.
        let indices = request.indices
        let target = indices.count == 1 && !indices[0].contains("*") ? indices[0] : ""
        let key = TableKey(
            table: TableName(schema: nil, name: target), kind: .identity("_index and _id"), columns: ["_index", "_id"],
            readOnlyColumns: ["_score", "_seq_no", "_primary_term", "_routing"])
        return .success(EditableResult(key: key, columns: result.columns, keyIndexes: [0, 1], removesFields: true, types: result.types))
    }

    /// A path segment, every character but the unreserved escaped: an id
    /// may hold `/`, `?` or `%` and stays one segment.
    static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? text
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func statements(_ edits: PendingEdits, rows: [[String?]], result: EditableResult) throws -> [EditStatement] {
        func column(_ name: String) -> Int? { result.columns.firstIndex(of: name) }
        func cell(_ row: Int, _ name: String) -> String? { column(name).flatMap { rows[safe: row]?[safe: $0] ?? nil } }
        /// The query that finds a read hit again, on the version it was read at.
        func found(_ row: Int) throws -> (path: String, query: [String]) {
            guard let index = cell(row, "_index"), let id = cell(row, "_id") else { throw EditRefusal.truncatedKey }
            var query: [String] = []
            if let seq = cell(row, "_seq_no"), let term = cell(row, "_primary_term") { query += ["if_seq_no=\(seq)", "if_primary_term=\(term)"] }
            if let routing = cell(row, "_routing") { query.append("routing=\(segment(routing))") }
            return ("/\(segment(index))", query + ["refresh=wait_for"])
        }
        func field(_ at: Int) throws -> String? {
            let name = result.columns[safe: at] ?? ""
            if metaColumns.contains(name) { return nil }
            guard !name.contains(".") else { throw EditRefusal.said("“\(name)” has a dot: a field of an object, not one of the document's own.") }
            return name
        }
        func request(_ method: String, _ path: String, _ query: [String], _ body: Any?) -> EditStatement {
            let line = "\(method) \(path)\(query.isEmpty ? "" : "?" + query.joined(separator: "&"))"
            return EditStatement(sql: body.map { line + "\n" + json($0) } ?? line, terminator: "\n")
        }
        var statements: [EditStatement] = []
        for row in edits.deleted.sorted() {
            let (path, query) = try found(row)
            statements.append(request("DELETE", "\(path)/_doc/\(segment(cell(row, "_id") ?? ""))", query, nil))
        }
        for row in edits.updates.keys.sorted() {
            guard let cells = edits.updates[row], !cells.isEmpty else { continue }
            var set: [String: Any] = [:]
            var removed: [String] = []
            for at in cells.keys.sorted() {
                guard let name = try field(at) else {
                    throw EditRefusal.said("\(result.columns[safe: at] ?? "") can't be changed — a document's _index and _id are its own: duplicate it with new ones, then delete it.")
                }
                switch cells[at] ?? .null {
                case .absent: removed.append(name)
                case .null: set[name] = NSNull()
                case .text(let text): set[name] = try value(text, type: result.types[safe: at] ?? "")
                }
            }
            let (path, query) = try found(row)
            let body: [String: Any] =
                removed.isEmpty
                ? ["doc": set]
                : [
                    "script": [
                        "lang": "painless", "source": "ctx._source.putAll(params.set); for (String f : params.unset) { ctx._source.remove(f) }",
                        "params": ["set": set, "unset": removed],
                    ]
                ]
            statements.append(request("POST", "\(path)/_update/\(segment(cell(row, "_id") ?? ""))", query, body))
        }
        for values in edits.inserted {
            var document: [String: Any] = [:]
            var index = result.key.table.name
            var id: String?
            for at in values.keys.sorted() {
                let name = result.columns[safe: at] ?? ""
                switch (name, values[at] ?? .absent) {
                case (_, .absent): continue
                case ("_index", .text(let text)): index = text
                case ("_id", .text(let text)): id = text
                case ("_index", .null), ("_id", .null): continue
                case (_, let cell):
                    guard let field = try field(at) else { continue }
                    if case .text(let text) = cell { document[field] = try value(text, type: result.types[safe: at] ?? "") } else { document[field] = NSNull() }
                }
            }
            guard !index.isEmpty else {
                throw EditRefusal.said("A new document needs its _index: the search names more than one index — set the new row's _index.")
            }
            if let id, !id.isEmpty {
                statements.append(request("PUT", "/\(segment(index))/_create/\(segment(id))", ["refresh=wait_for"], document))
            } else {
                statements.append(request("POST", "/\(segment(index))/_doc", ["refresh=wait_for"], document))
            }
        }
        return statements
    }

    /// A cell's text as its field's JSON type: a string as itself, a number,
    /// a boolean, an object or an array as JSON; a field of several types
    /// (or none yet) as JSON when it reads as JSON, else as text.
    static func value(_ text: String, type: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        switch type {
        case "string": return text
        case "number":
            if let number = parsed as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number }
        case "boolean":
            if let flag = parsed as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { return flag }
        case "object":
            if let object = parsed as? [String: Any] { return object }
        case "array":
            if let array = parsed as? [Any] { return array }
        default:
            if let parsed, !(parsed is NSNull) { return parsed }
            return text
        }
        throw EditRefusal.said("“\(text)” isn't a\(type == "array" || type == "object" ? "n" : "") \(type) — write it as JSON.")
    }
}

/// The security plugins' user requests as Dev Tools writes them —
/// Elasticsearch's `_security/user`, OpenSearch's `_plugins/_security/api`.
/// A grant is a role (a user's own list; OpenSearch's role mappings are said,
/// not changed). The password goes once, in the request's body; the server
/// keeps its hash. Pure.
struct SearchUserStatements: UserStatementMaking {
    /// What of an Elasticsearch user its update writes again, as the page
    /// lists it: an update writes the user whole, so they are kept.
    static let fullName = "name: "
    static let email = "email: "
    static let hasMetadata = "has metadata"

    var opensearch = false

    private var engine: String { opensearch ? "OpenSearch" : "Elasticsearch" }

    /// No Grant…: what a user may do is its roles' (Grant Role…).
    var form: UserForm {
        UserForm(
            superuser: nil,
            passwordNote:
                "The password is sent once, in the request's body, over this connection — https keeps it off the wire in the clear, http doesn't. The server keeps only its hash; nothing is kept here.",
            noGrants: "No roles of its own.")
    }

    /// A role has no password and holds privileges, not roles.
    func offers(_ action: UserAction, on user: DatabaseUser) -> Bool {
        switch action {
        case .password, .grantRole: !user.isRole
        case .grant: false
        case .drop: true
        }
    }

    func target(_ kind: GrantKind, fields: [String]) -> GrantTarget { .named(kind: kind.title, name: fields.first ?? "") }

    func privileges(on target: GrantTarget) -> [String] { [] }

    func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] {
        users.filter { $0.isRole && $0.id != user.id && !user.memberOf.contains($0.name) }
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private var users: String { opensearch ? "/_plugins/_security/api/internalusers" : "/_security/user" }

    private var roles: String { opensearch ? "/_plugins/_security/api/roles" : "/_security/role" }

    private func name(_ user: DatabaseUser) throws -> String { SearchEdits.segment(try checked(user.name)) }

    /// The request, and as shown: the body's password masked.
    private static func secret(_ head: String, _ body: (String) -> Any, _ password: String) -> UserStatement {
        UserStatement(head + "\n" + json(body(password)), shown: head + "\n" + json(body("••••••••")))
    }

    func create(_ user: NewUser) throws -> [UserStatement] {
        let path = try name(DatabaseUser(name: user.name))
        guard !user.password.isEmpty else { throw Self.refusal("A password, please.") }
        if opensearch {
            return [Self.secret("PUT \(users)/\(path)", { ["password": $0, "opendistro_security_roles": [String]()] }, user.password)]
        }
        return [Self.secret("POST \(users)/\(path)", { ["password": $0, "roles": [String]()] }, user.password)]
    }

    func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        let path = try name(user)
        guard !user.isRole else { throw Self.refusal("A role has no password.") }
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        if opensearch {
            return Self.secret("PATCH \(users)/\(path)", { [["op": "add", "path": "/password", "value": $0]] }, password)
        }
        return Self.secret("POST \(users)/\(path)/_password", { ["password": $0] }, password)
    }

    func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        throw Self.refusal("\(engine) grants through roles: Grant Role….")
    }

    /// The user's own roles, written whole: Elasticsearch's update of a user
    /// keeps its password (and nothing else unwritten), OpenSearch's patch
    /// changes that one list.
    private func roles(of user: DatabaseUser, _ roles: [String]) throws -> UserStatement {
        let path = try name(user)
        guard !user.isRole else { throw Self.refusal("A role holds privileges, not roles.") }
        if opensearch {
            return UserStatement("PATCH \(users)/\(path)\n" + Self.json([["op": "add", "path": "/opendistro_security_roles", "value": roles]]))
        }
        // The update writes the user whole: its name, email and whether it
        // is enabled are written again; metadata would be lost — refused.
        guard !user.attributes.contains(Self.hasMetadata) else {
            throw Self.refusal("\(user.name) has metadata of its own, which writing its roles would drop — change them in Kibana.")
        }
        var body: [String: Any] = ["roles": roles, "enabled": user.canLogin]
        for attribute in user.attributes {
            if attribute.hasPrefix(Self.fullName) { body["full_name"] = String(attribute.dropFirst(Self.fullName.count)) }
            if attribute.hasPrefix(Self.email) { body["email"] = String(attribute.dropFirst(Self.email.count)) }
        }
        return UserStatement("POST \(users)/\(path)\n" + Self.json(body))
    }

    func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement {
        _ = try checked(role.name, "A role")
        guard !user.memberOf.contains(role.name) else { throw Self.refusal("\(user.name) has \(role.name) already.") }
        return try roles(of: user, user.memberOf + [role.name])
    }

    func revokeRole(_ role: DatabaseUser, from user: DatabaseUser) throws -> UserStatement {
        guard user.memberOf.contains(role.name) else { throw Self.refusal("\(role.name) isn't one of \(user.name)'s own roles.") }
        return try roles(of: user, user.memberOf.filter { $0 != role.name })
    }

    func drop(_ user: DatabaseUser) throws -> UserStatement {
        let path = try name(user)
        return UserStatement("DELETE \(user.isRole ? roles : users)/\(path)")
    }

    /// A role of the user's own; one mapped to it is the mapping's to change.
    func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard grant.kind == "role" else { return nil }
        return try? revokeRole(DatabaseUser(name: grant.object, isRole: true), from: user)
    }
}
