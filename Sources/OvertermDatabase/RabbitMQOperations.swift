import CryptoKit
import Foundation

/// RabbitMQ's Server page and users, from the management API: the
/// overview and the nodes (memory, disk, file descriptors, alarms), the
/// connections with their channels (one closed: DELETE), the queues by
/// size and rate; users (never their password hash), their permissions per
/// vhost and topic permissions. No rows are edited: messages aren't rows.
/// docs/architecture.md, Database: Server page, Users and roles.
extension RabbitMQDriver: DatabaseMonitoring, DatabaseUserManagement {
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .sizes] }

    package static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        [
            SessionStop(
                terminate: true, menu: "Close Connection…", title: "Close \(session.user ?? "its") connection from \(session.client ?? session.id)?",
                command: "DELETE /api/connections/\(RabbitText.segment(session.id))",
                effect: [session.application, session.database.map { "vhost \($0)" }, session.statement].compactMap { $0 }.joined(separator: " · ")
                    + "\n\nIts channels close with it; messages it hadn't acknowledged go back to their queues. A client that reconnects comes back.",
                button: "Close")
        ]
    }

    package func overview() async throws -> ServerOverview {
        let overview = try await json("GET", "/api/overview") as? [String: Any] ?? [:]
        let nodes: [[String: Any]]?
        do {
            nodes = try await json("GET", "/api/nodes") as? [[String: Any]]
        } catch {
            nodes = nil
        }
        return RabbitOps.overview(overview, nodes: nodes)
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        let connections =
            try await json(
                "GET",
                "/api/connections?columns=name,user,vhost,peer_host,peer_port,client_properties,state,channels,connected_at,protocol,recv_oct_details,send_oct_details"
            ) as? [[String: Any]] ?? []
        let channels =
            (try? await json("GET", "/api/channels?columns=connection_details,consumer_count,messages_unacknowledged") as? [[String: Any]]) ?? []
        return .value(RabbitOps.activity(connections, channels: channels, now: Date()))
    }

    package func sizes() async throws -> Monitored<DatabaseSizes> {
        let queues =
            try await json(
                "GET",
                "/api/queues?columns=name,vhost,type,state,messages,messages_ready,messages_unacknowledged,message_bytes,consumers,message_stats"
            ) as? [[String: Any]] ?? []
        return .value(RabbitOps.sizes(queues))
    }

    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("closing a connection") }
        _ = try await request("DELETE", "/api/connections/\(RabbitText.segment(session))")
    }

    // MARK: Users

    package func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own

    package func userStatements() async -> any UserStatementMaking { RabbitUserStatements() }

    package func users() async throws -> Monitored<[DatabaseUser]> {
        do {
            // Never `password_hash`: only the columns asked for come back.
            let list = try await json("GET", "/api/users?columns=name,tags") as? [[String: Any]] ?? []
            return .value(list.compactMap(RabbitOps.user))
        } catch {
            let message = error.localizedDescription
            // A user who isn't an administrator is answered 401 (or 403), its
            // credentials good — `connect` has checked them.
            if message.contains("403") || message.contains("refused") || message.lowercased().contains("not_authorised") {
                return .unavailable(
                    MonitorGap(
                        reason: "Only an administrator lists users — \(config.user) isn't tagged administrator.",
                        fix: "rabbitmqctl set_user_tags \(config.user.isEmpty ? "<user>" : config.user) administrator"))
            }
            throw error
        }
    }

    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        let name = RabbitText.segment(user.name)
        let permissions = try await json("GET", "/api/users/\(name)/permissions") as? [[String: Any]] ?? []
        let topics = (try? await json("GET", "/api/users/\(name)/topic-permissions") as? [[String: Any]]) ?? []
        return .value(RabbitOps.grants(permissions: permissions, topics: topics))
    }

    /// Each statement a request — `METHOD /path {json}` — sent once.
    /// `NEW` before it: only where nothing is there yet (a new user never
    /// replaces one).
    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        for statement in statements {
            guard let request = UserRequest(statement.sql) else { throw DatabaseError.failed("Couldn't read \(statement.shown).") }
            if request.onlyNew {
                let exists: Bool
                do {
                    _ = try await self.request("GET", request.path)
                    exists = true
                } catch let error as DatabaseError {
                    throw error
                } catch {
                    exists = false  // its 404
                }
                if exists { throw DatabaseError.failed("There is already one at \(request.path) — nothing was changed.") }
            }
            do {
                _ = try await self.request(request.method, request.path, body: request.body.map { Data($0.utf8) })
            } catch {
                throw DatabaseError.failed(statement.scrub(error.localizedDescription))
            }
        }
    }
}

/// The management API's answers read. Pure.
package enum RabbitOps {
    package static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    package static func rate(_ object: [String: Any]?, _ name: String) -> Double? {
        ((object?[name + "_details"]) as? [String: Any]).flatMap { number($0["rate"]) }
    }

    package static func overview(_ overview: [String: Any], nodes: [[String: Any]]?) -> ServerOverview {
        var facts: [ServerFact] = []
        var notes: [String] = []
        facts.append(
            ServerFact(
                title: "RabbitMQ", value: overview["rabbitmq_version"] as? String ?? "—",
                detail: (overview["erlang_version"] as? String).map { "Erlang \($0)" }))
        if let cluster = overview["cluster_name"] as? String { facts.append(ServerFact(title: "Cluster", value: cluster, detail: nodes.map { "\($0.count) nodes" })) }
        let totals = overview["object_totals"] as? [String: Any] ?? [:]
        func count(_ key: String) -> String { number(totals[key]).map { String(Int($0)) } ?? "—" }
        facts.append(ServerFact(title: "Connections", value: count("connections"), detail: "\(count("channels")) channels"))
        facts.append(ServerFact(title: "Queues", value: count("queues"), detail: "\(count("consumers")) consumers"))
        let queued = overview["queue_totals"] as? [String: Any] ?? [:]
        if let messages = number(queued["messages"]) {
            facts.append(
                ServerFact(
                    title: "Messages", value: String(Int(messages)),
                    detail: "\(Int(number(queued["messages_ready"]) ?? 0)) ready, \(Int(number(queued["messages_unacknowledged"]) ?? 0)) unacked"))
        }
        let stats = overview["message_stats"] as? [String: Any]
        if let publish = rate(stats, "publish") {
            facts.append(
                ServerFact(title: "Published/s", value: String(format: "%.1f", publish), detail: rate(stats, "deliver_get").map { String(format: "%.1f delivered/s", $0) }))
        }
        if let nodes {
            for node in nodes {
                let name = node["name"] as? String ?? "node"
                let short = name.split(separator: "@").last.map(String.init) ?? name
                if node["running"] as? Bool == false {
                    notes.append("\(name) isn't running.")
                    continue
                }
                if let used = number(node["mem_used"]) {
                    let limit = number(node["mem_limit"])
                    facts.append(
                        ServerFact(
                            title: "Memory · \(short)", value: OpsText.bytes(Int64(used)),
                            detail: limit.map { "of \(OpsText.bytes(Int64($0))) (high watermark)" }))
                }
                if let free = number(node["disk_free"]) {
                    facts.append(
                        ServerFact(
                            title: "Disk free · \(short)", value: OpsText.bytes(Int64(free)),
                            detail: number(node["disk_free_limit"]).map { "limit \(OpsText.bytes(Int64($0)))" }))
                }
                if let fds = number(node["fd_used"]), let total = number(node["fd_total"]) {
                    facts.append(ServerFact(title: "File descriptors · \(short)", value: "\(Int(fds)) of \(Int(total))"))
                }
                if let uptime = number(node["uptime"]) { facts.append(ServerFact(title: "Up · \(short)", value: OpsText.duration(uptime / 1000))) }
                if node["mem_alarm"] as? Bool == true {
                    notes.append("Memory alarm on \(name): publishers are blocked until memory falls under the high watermark.")
                }
                if node["disk_free_alarm"] as? Bool == true {
                    notes.append("Disk alarm on \(name): publishers are blocked until free disk is over its limit.")
                }
            }
        } else {
            notes.append("The nodes (memory, disk, file descriptors, alarms) are shown to a user tagged monitoring or administrator.")
        }
        notes.append("Other users' connections are listed to a user tagged monitoring or administrator.")
        return ServerOverview(facts: facts, notes: notes)
    }

    /// Connections as sessions: who, from where, its vhost, its state
    /// (running, blocked by an alarm, flow), how long since it opened, its
    /// channels' consumers and unacknowledged messages.
    package static func activity(_ connections: [[String: Any]], channels: [[String: Any]], now: Date) -> [DatabaseActivity] {
        var perConnection: [String: (channels: Int, consumers: Int, unacked: Int)] = [:]
        for channel in channels {
            guard let name = (channel["connection_details"] as? [String: Any])?["name"] as? String else { continue }
            perConnection[name, default: (0, 0, 0)].channels += 1
            perConnection[name, default: (0, 0, 0)].consumers += Int(number(channel["consumer_count"]) ?? 0)
            perConnection[name, default: (0, 0, 0)].unacked += Int(number(channel["messages_unacknowledged"]) ?? 0)
        }
        return connections.compactMap { connection in
            guard let name = connection["name"] as? String else { return nil }
            let properties = connection["client_properties"] as? [String: Any] ?? [:]
            let application =
                (properties["connection_name"] as? String)
                ?? [properties["product"] as? String, properties["version"] as? String].compactMap { $0 }.joined(separator: " ").nonEmpty
            let state = connection["state"] as? String
            let counts = perConnection[name]
            var doing = ["\(Int(number(connection["channels"]) ?? Double(counts?.channels ?? 0))) channels"]
            if let counts {
                if counts.consumers > 0 { doing.append("\(counts.consumers) consumers") }
                if counts.unacked > 0 { doing.append("\(counts.unacked) unacked") }
            }
            if let received = rate(connection, "recv_oct"), received > 0 { doing.append("in \(OpsText.bytes(Int64(received)))/s") }
            if let sent = rate(connection, "send_oct"), sent > 0 { doing.append("out \(OpsText.bytes(Int64(sent)))/s") }
            if let proto = connection["protocol"] as? String { doing.append(proto) }
            let host = connection["peer_host"] as? String
            let client = host.map { host in number(connection["peer_port"]).map { "\(host):\(Int($0))" } ?? host }
            let since = number(connection["connected_at"]).map { max(0, now.timeIntervalSince1970 - $0 / 1000) }
            return DatabaseActivity(
                id: name, user: connection["user"] as? String, database: connection["vhost"] as? String, client: client, application: application,
                state: state, statement: doing.joined(separator: " · "), seconds: since,
                waiting: state == "blocked" || state == "blocking" ? "a resource alarm (memory or disk)" : state == "flow" ? "flow control" : nil)
        }
    }

    /// The queues, biggest first (by bytes, then messages), and each
    /// vhost's sum; their rates beside them.
    package static func sizes(_ queues: [[String: Any]]) -> DatabaseSizes {
        var sizes = DatabaseSizes()
        var vhosts: [String: (bytes: Int64, messages: Int, queues: Int)] = [:]
        for queue in queues {
            guard let name = queue["name"] as? String else { continue }
            let vhost = queue["vhost"] as? String ?? "/"
            let bytes = Int64(number(queue["message_bytes"]) ?? 0)
            let messages = Int(number(queue["messages"]) ?? 0)
            vhosts[vhost, default: (0, 0, 0)].bytes += bytes
            vhosts[vhost, default: (0, 0, 0)].messages += messages
            vhosts[vhost, default: (0, 0, 0)].queues += 1
            var detail = [
                "\(messages) messages (\(Int(number(queue["messages_ready"]) ?? 0)) ready, \(Int(number(queue["messages_unacknowledged"]) ?? 0)) unacked)"
            ]
            let stats = queue["message_stats"] as? [String: Any]
            if let publish = rate(stats, "publish") { detail.append(String(format: "in %.1f/s", publish)) }
            if let deliver = rate(stats, "deliver_get") { detail.append(String(format: "out %.1f/s", deliver)) }
            detail.append("\(Int(number(queue["consumers"]) ?? 0)) consumers")
            if let type = queue["type"] as? String { detail.append(type) }
            if let state = queue["state"] as? String, state != "running" { detail.append(state) }
            sizes.tables.append(SizeEntry(name: name, schema: vhost, bytes: bytes, detail: detail.joined(separator: " · ")))
        }
        sizes.tables.sort { ($0.bytes, $0.detail ?? "") > ($1.bytes, $1.detail ?? "") }
        if sizes.tables.count > 200 {
            sizes.notes.append("The 200 biggest of \(sizes.tables.count) queues.")
            sizes.tables = Array(sizes.tables.prefix(200))
        }
        sizes.databases = vhosts.map { name, sum in
            SizeEntry(name: name, bytes: sum.bytes, detail: "vhost · \(sum.queues) queues · \(sum.messages) messages")
        }.sorted { $0.bytes > $1.bytes }
        sizes.notes.append("Bytes are the messages' bodies in the queues, as RabbitMQ counts them.")
        return sizes
    }

    /// A user, its tags as its attributes (administrator its superuser).
    package static func user(_ row: [String: Any]) -> DatabaseUser? {
        guard let name = row["name"] as? String else { return nil }
        let tags: [String]
        if let list = row["tags"] as? [String] {
            tags = list
        } else {
            tags = (row["tags"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return DatabaseUser(name: name, superuser: tags.contains("administrator"), attributes: tags)
    }

    /// Its permissions per vhost (configure, write, read: each a regex of
    /// the names it may), and its topic permissions per exchange.
    package static func grants(permissions: [[String: Any]], topics: [[String: Any]]) -> [DatabaseGrant] {
        var grants: [DatabaseGrant] = []
        for permission in permissions {
            guard let vhost = permission["vhost"] as? String else { continue }
            let privileges = ["configure", "write", "read"].map { "\($0) \(permission[$0] as? String ?? "")" }
            grants.append(DatabaseGrant(kind: "vhost", object: vhost, privileges: privileges, target: .named(kind: "Vhost", name: vhost)))
        }
        for topic in topics {
            guard let vhost = topic["vhost"] as? String else { continue }
            let exchange = topic["exchange"] as? String ?? ""
            grants.append(
                DatabaseGrant(
                    kind: "topic", object: "\(vhost) · \(exchange.isEmpty ? "(default)" : exchange)",
                    privileges: ["write \(topic["write"] as? String ?? "")", "read \(topic["read"] as? String ?? "")"],
                    target: .named(kind: "Topic", name: vhost)))
        }
        return grants
    }
}

/// The management API's user requests, each `METHOD /path {json}` with every
/// path segment percent-encoded — a name never reaches another path. A
/// password goes as its salted SHA-256 (`rabbit_password_hashing_sha256`,
/// RabbitMQ's own), never in the clear; the shown request masks it. Pure.
package struct RabbitUserStatements: UserStatementMaking {
    package static let algorithm = "rabbit_password_hashing_sha256"
    package static let permissions = ["configure", "write", "read"]

    package var form: UserForm {
        UserForm(
            superuser: "Administrator (the administrator tag)",
            passwordNote: "The password goes as its salted SHA-256 (RabbitMQ's own hashing), never in the clear, and is never kept here.",
            grantKinds: [GrantKind(title: "Vhost", fields: [GrantField(title: "Vhost", fill: .database)])],
            noGrants: "No permissions: it can't use any vhost.")
    }

    /// RabbitMQ's `rabbit_password_hashing_sha256`: base64 of a 4-byte salt,
    /// then SHA-256 of the salt and the password.
    package static func hash(_ password: String, salt: Data? = nil) -> String {
        let salt = salt ?? Data((0..<4).map { _ in UInt8.random(in: 0...255) })
        return (salt + Data(SHA256.hash(data: salt + Data(password.utf8)))).base64EncodedString()
    }

    private static func json(_ object: [String: String]) -> String { UserRequest.json(object) }

    /// The user's PUT: its password's hash and its tags.
    private func put(_ name: String, password: String, tags: [String], onlyNew: Bool) throws -> UserStatement {
        let path = "/api/users/\(RabbitText.segment(try checked(name)))"
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        let tags = tags.joined(separator: ",")
        let body = Self.json(["hashing_algorithm": Self.algorithm, "password_hash": Self.hash(password), "tags": tags])
        let shown = Self.json(["hashing_algorithm": Self.algorithm, "password_hash": "••••••••", "tags": tags])
        return UserStatement((onlyNew ? "NEW " : "") + "PUT \(path) \(body)", shown: "PUT \(path) \(shown)")
    }

    package func create(_ user: NewUser) throws -> [UserStatement] {
        [try put(user.name, password: user.password, tags: user.superuser ? ["administrator"] : [], onlyNew: true)]
    }

    /// A PUT replaces the user: its tags go with the new password.
    package func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        try put(user.name, password: password, tags: user.attributes, onlyNew: false)
    }

    package func offers(_ action: UserAction, on user: DatabaseUser) -> Bool { action != .grantRole }

    package func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        let vhost = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
        return .named(kind: "Vhost", name: vhost.isEmpty ? "/" : vhost)
    }

    package func privileges(on target: GrantTarget) -> [String] { Self.permissions }

    /// The vhost's permissions set: each picked may use every name (`.*`),
    /// each not picked none (`^$`) — what it had there is replaced.
    package func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        guard case .named("Vhost", let vhost) = target else { throw Self.refusal("RabbitMQ grants on a vhost.") }
        guard !privileges.isEmpty else { throw Self.refusal("Pick configure, write or read.") }
        for privilege in privileges where !Self.permissions.contains(privilege) { throw Self.refusal("\(privilege) isn't a RabbitMQ permission.") }
        var body: [String: String] = [:]
        for permission in Self.permissions { body[permission] = privileges.contains(permission) ? ".*" : "^$" }
        let path = "/api/permissions/\(RabbitText.segment(try checked(vhost, "A vhost")))/\(RabbitText.segment(try checked(user.name)))"
        return UserStatement("PUT \(path) \(Self.json(body))")
    }

    package func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        guard case .named(let kind, let vhost)? = grant.target, let name = try? checked(user.name) else { return nil }
        let base = kind == "Topic" ? "/api/topic-permissions/" : "/api/permissions/"
        return UserStatement("DELETE \(base)\(RabbitText.segment(vhost))/\(RabbitText.segment(name))")
    }

    package func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] { [] }

    package func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement { throw Self.refusal("RabbitMQ has no roles — tags.") }

    package func drop(_ user: DatabaseUser) throws -> UserStatement { UserStatement("DELETE /api/users/\(RabbitText.segment(try checked(user.name)))") }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
