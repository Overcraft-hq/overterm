import CryptoKit
import Foundation

/// Redis's server reads as every kind's — its own page is `RedisSlotView`'s
/// Server Info, which reads the same answers with the same parsers
/// (`RedisInfo`, `RedisClients`, `RedisSlowEntry`); this is what agents'
/// tools read. Its users are ACL's. No rows are edited: a key has its own
/// page. docs/architecture.md, Database: Server page, Users and roles.
extension RedisDriver: DatabaseMonitoring, DatabaseUserManagement {
    package static func monitorParts(for kind: DatabaseKind) -> [MonitorPart] { [.overview, .activity, .slowQueries] }

    package static func sessionStops(for session: DatabaseActivity, kind: DatabaseKind) -> [SessionStop]? {
        [
            SessionStop(
                terminate: true, menu: "Kill Client…", title: "Disconnect client \(session.id)?", command: "CLIENT KILL ID \(session.id)",
                effect: [session.client, session.application, session.user].compactMap { $0 }.joined(separator: " · ")
                    + "\n\nIts connection is closed; a client that reconnects comes back.", button: "Kill")
        ]
    }

    /// A reply refused for want of a permission (ACL) or a command (an old server).
    private func refused(_ reply: RedisValue, _ what: String, fix: String) -> MonitorGap? {
        guard case .error(let message) = reply else { return nil }
        if message.hasPrefix("NOPERM") { return MonitorGap(reason: "This user may not run \(what): \(message)", fix: fix) }
        return MonitorGap(reason: "Redis refused \(what): \(message)")
    }

    package func overview() async throws -> ServerOverview {
        let replies = try await pipeline([["INFO"], ["CONFIG", "GET", "maxclients"]])
        guard case .bulk(let data?) = replies[0] else {
            throw DatabaseError.failed(replies[0].text ?? "Redis didn't answer INFO.")
        }
        var maxClients: Int?
        if case .array(let pair?) = replies[1], pair.count == 2 { maxClients = pair[1].text.flatMap(Int.init) }
        return RedisOps.overview(RedisInfo(RedisValue.string(data)), maxClients: maxClients)
    }

    package func activity() async throws -> Monitored<[DatabaseActivity]> {
        let replies = try await pipeline([["CLIENT", "ID"], ["CLIENT", "LIST"]])
        if let gap = refused(replies[1], "CLIENT LIST", fix: "ACL SETUSER \(config.user.isEmpty ? "default" : config.user) +client|list") {
            return .unavailable(gap)
        }
        guard case .bulk(let data?) = replies[1] else { return .value([]) }
        let own: String? = if case .integer(let id) = replies[0] { String(id) } else { nil }
        return .value(RedisOps.activity(RedisClients.parse(RedisValue.string(data)), own: own))
    }

    package func slowQueries() async throws -> Monitored<[SlowQuery]> {
        let reply = try await command(["SLOWLOG", "GET", "128"])
        if let gap = refused(reply, "SLOWLOG GET", fix: "ACL SETUSER \(config.user.isEmpty ? "default" : config.user) +slowlog") {
            return .unavailable(gap)
        }
        return .value(RedisOps.slowQueries(RedisSlowEntry.parse(reply)))
    }

    package func cancel(session: String, terminate: Bool) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("CLIENT KILL") }
        guard Int(session) != nil else { throw DatabaseError.failed("\(session) isn't a client's id.") }
        if case .integer(let own) = try await command(["CLIENT", "ID"]), String(own) == session {
            throw DatabaseError.failed("That is this connection's own client.")
        }
        let reply = try await command(["CLIENT", "KILL", "ID", session])
        if case .error(let message) = reply { throw DatabaseError.failed(message) }
        if case .integer(0) = reply { throw DatabaseError.failed("No client \(session) — it has gone already.") }
    }

    // MARK: Users (ACL)

    package func userDialect() async -> UserDialect { .postgres }  // never read: `userStatements` is its own

    package func userStatements() async -> any UserStatementMaking { RedisUserStatements() }

    package func users() async throws -> Monitored<[DatabaseUser]> {
        switch try await aclList() {
        case .value(let users): return .value(users.map(\.user))
        case .unavailable(let gap): return .unavailable(gap)
        }
    }

    package func grants(of user: DatabaseUser) async throws -> Monitored<[DatabaseGrant]> {
        switch try await aclList() {
        case .value(let users):
            guard let found = users.first(where: { $0.name == user.name }) else { return .unavailable(MonitorGap(reason: "\(user.name) is gone.")) }
            return .value(found.grants)
        case .unavailable(let gap): return .unavailable(gap)
        }
    }

    private func aclList() async throws -> Monitored<[RedisACLUser]> {
        let reply = try await command(["ACL", "LIST"])
        if case .error(let message) = reply {
            if message.uppercased().contains("UNKNOWN") {
                return .unavailable(MonitorGap(reason: "This server has no users — Redis has them from 6.0 on (ACL); before, one password (requirepass)."))
            }
            return .unavailable(
                refused(reply, "ACL LIST", fix: "ACL SETUSER \(config.user.isEmpty ? "default" : config.user) +acl|list")
                    ?? MonitorGap(reason: message))
        }
        guard case .array(let lines?) = reply else { return .value([]) }
        return .value(lines.compactMap { $0.text.flatMap(RedisACLUser.init) })
    }

    /// Each statement a command line, as redis-cli takes it; sent once, nothing kept.
    package func run(_ statements: [UserStatement]) async throws {
        guard !config.readOnly else { throw DatabaseError.readOnly("changing users") }
        for statement in statements {
            let words: [String]
            do {
                words = try RedisProtocol.words(statement.sql)
            } catch {
                throw DatabaseError.failed("Couldn't read \(statement.shown).")
            }
            guard words.first?.uppercased() == "ACL" else { throw DatabaseError.failed("Only ACL commands change users: \(statement.shown)") }
            // A new user's line starts with `reset`: never over one that exists.
            if words.count > 3, words[1].uppercased() == "SETUSER", words[3] == "reset" {
                let existing = try await command(["ACL", "GETUSER", words[2]])
                if case .error(let message) = existing { throw DatabaseError.failed(message) }
                if case .array(let parts?) = existing, !parts.isEmpty {
                    throw DatabaseError.failed("There is already a user \(words[2]) — nothing was changed.")
                }
            }
            if case .error(let message) = try await command(words) { throw DatabaseError.failed("\(message) — \(statement.shown)") }
        }
    }
}

/// Redis's answers read for the shared page. Pure.
package enum RedisOps {
    package static func overview(_ info: RedisInfo, maxClients: Int?) -> ServerOverview {
        var facts: [ServerFact] = []
        facts.append(ServerFact(title: info["valkey_version"] != nil ? "Valkey" : "Redis", value: info.version ?? "—", detail: info["redis_mode"]))
        if let uptime = info.uptime { facts.append(ServerFact(title: "Up", value: uptime)) }
        if let clients = info["connected_clients"] {
            facts.append(ServerFact(title: "Clients", value: clients, detail: maxClients.map { "of \($0) (maxclients)" }))
        }
        if let used = info["used_memory_human"] {
            let max = info.number("maxmemory").flatMap { $0 > 0 ? OpsText.bytes(Int64($0)) : nil }
            facts.append(ServerFact(title: "Memory", value: used, detail: max.map { "of \($0) (maxmemory)" } ?? "no maxmemory"))
        }
        if let ratio = info.hitRatio { facts.append(ServerFact(title: "Hit rate", value: OpsText.percent(ratio), detail: "keyspace hits of lookups")) }
        facts.append(ServerFact(title: "Keys", value: "\(info.totalKeys)", detail: "in \(info.keyspace.count) database\(info.keyspace.count == 1 ? "" : "s")"))
        if let ops = info["instantaneous_ops_per_sec"] { facts.append(ServerFact(title: "Commands/s", value: ops)) }
        if let role = info["role"] {
            facts.append(ServerFact(title: "Role", value: role, detail: info["connected_slaves"].map { "\($0) replicas" }))
        }
        if let evicted = info["evicted_keys"], evicted != "0" { facts.append(ServerFact(title: "Evicted keys", value: evicted)) }
        if let blocked = info["blocked_clients"], blocked != "0" { facts.append(ServerFact(title: "Blocked clients", value: blocked)) }
        return ServerOverview(facts: facts)
    }

    /// CLIENT LIST's clients as sessions: `cmd` the last command, `idle` how
    /// long since, a blocked one (flag `b`) waiting on its keys.
    package static func activity(_ clients: [[String: String]], own: String?) -> [DatabaseActivity] {
        clients.compactMap { client in
            guard let id = client["id"] else { return nil }
            let flags = client["flags"] ?? ""
            let idle = client["idle"].flatMap(Double.init) ?? 0
            let state: String
            if flags.contains("b") {
                state = "blocked"
            } else if flags.contains("P") || (Int(client["psub"] ?? "0") ?? 0) + (Int(client["sub"] ?? "0") ?? 0) > 0 {
                state = "subscribed"
            } else if flags.contains("S") {
                state = "replica"
            } else if client["cmd"] == "monitor" || flags.contains("O") {
                state = "monitor"
            } else {
                state = idle > 0 ? "idle" : "active"
            }
            let command = client["cmd"].flatMap { $0 == "NULL" ? nil : $0.replacingOccurrences(of: "|", with: " ").uppercased() }
            return DatabaseActivity(
                id: id, user: client["user"], database: client["db"].map { "db\($0)" }, client: client["addr"],
                application: client["name"].flatMap { $0.isEmpty ? nil : $0 }, state: state, statement: command, seconds: idle,
                waiting: flags.contains("b") ? "keys (a blocking command)" : nil, isOwn: id == own)
        }
    }

    /// The slow log's entries, the same command line together: how often,
    /// in all, and on average. A password the line carries is masked.
    package static func slowQueries(_ entries: [RedisSlowEntry]) -> [SlowQuery] {
        var groups: [String: (calls: Int, micros: Int)] = [:]
        var order: [String] = []
        for entry in entries {
            let line = masked(entry.command)
            if groups[line] == nil { order.append(line) }
            groups[line, default: (0, 0)].calls += 1
            groups[line, default: (0, 0)].micros += entry.micros
        }
        return order.map { line in
            let group = groups[line] ?? (1, 0)
            let total = Double(group.micros) / 1_000_000
            return SlowQuery(id: line, statement: line, calls: group.calls, total: total, mean: total / Double(max(group.calls, 1)))
        }
    }

    /// AUTH's, HELLO's and ACL SETUSER's secrets: `>pass`, `#hash`, the word after AUTH.
    package static func masked(_ line: String) -> String {
        guard let words = try? RedisProtocol.words(line), let first = words.first?.uppercased() else { return line }
        switch first {
        case "AUTH": return "AUTH ••••"
        case "HELLO", "MIGRATE": return first + " …"
        case "ACL", "CONFIG":
            return words.map { word in
                word.hasPrefix(">") || word.hasPrefix("<") || word.hasPrefix("#") || word.hasPrefix("!") ? String(word.prefix(1)) + "••••" : RedisProtocol.quoted(word)
            }.joined(separator: " ")
        default: return line
        }
    }
}

/// An ACL LIST line: `user alice on #<sha256> ~cache:* &* -@all +get`. Its
/// password hashes are counted, never kept. Pure.
package struct RedisACLUser: Equatable {
    package var name: String
    package var enabled = false
    package var passwords = 0
    package var nopass = false
    package var keys: [String] = []
    package var channels: [String] = []
    package var commands: [String] = []
    /// Redis 7's selectors: `(~logs:* +get)`.
    package var selectors: [String] = []
    package var flags: [String] = []

    package init?(_ line: String) {
        // Selectors are parenthesized and may hold spaces: taken out first.
        var rest = line
        var selectors: [String] = []
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            selectors.append(String(rest[rest.index(after: open)..<close]))
            rest.removeSubrange(open...close)
        }
        let words = rest.split(separator: " ").map(String.init)
        guard words.count >= 2, words[0] == "user" else { return nil }
        name = words[1]
        self.selectors = selectors
        for word in words.dropFirst(2) {
            switch word {
            case "on": enabled = true
            case "off": enabled = false
            case "nopass": nopass = true
            case "allkeys": keys.append("*")
            case "allchannels": channels.append("*")
            case "resetkeys", "resetchannels", "resetpass": break
            default:
                if word.hasPrefix("#") || word.hasPrefix(">") {
                    passwords += 1
                } else if word.hasPrefix("~") || word.hasPrefix("%") {
                    keys.append(word.hasPrefix("~") ? String(word.dropFirst()) : word)
                } else if word.hasPrefix("&") {
                    channels.append(String(word.dropFirst()))
                } else if word.hasPrefix("+") || word.hasPrefix("-") || word == "allcommands" || word == "nocommands" {
                    commands.append(word)
                } else {
                    flags.append(word)
                }
            }
        }
    }

    /// Everything: every command, every key.
    package var isSuperuser: Bool {
        (commands.contains("+@all") || commands.contains("allcommands")) && !commands.contains { $0.hasPrefix("-") } && keys.contains("*")
    }

    package var user: DatabaseUser {
        var attributes: [String] = []
        if nopass { attributes.append("no password") } else if passwords > 0 { attributes.append(passwords == 1 ? "a password set" : "\(passwords) passwords set") }
        if !selectors.isEmpty { attributes.append("\(selectors.count) selector\(selectors.count == 1 ? "" : "s")") }
        attributes += flags
        return DatabaseUser(name: name, canLogin: enabled && (nopass || passwords > 0), superuser: isSuperuser, attributes: attributes)
    }

    package var grants: [DatabaseGrant] {
        var grants = [
            DatabaseGrant(kind: "commands", object: "commands", privileges: commands.isEmpty ? ["-@all"] : commands, target: .server)
        ]
        if !keys.isEmpty { grants.append(DatabaseGrant(kind: "keys", object: keys.joined(separator: " "), privileges: ["~"], target: .named(kind: "Keys", name: ""))) }
        if !channels.isEmpty {
            grants.append(DatabaseGrant(kind: "channels", object: channels.joined(separator: " "), privileges: ["&"], target: .named(kind: "Channels", name: "")))
        }
        for (at, selector) in selectors.enumerated() {
            grants.append(DatabaseGrant(kind: "selector", object: "(\(selector))", privileges: ["selector \(at + 1)"], target: .named(kind: "Selectors", name: "")))
        }
        return grants
    }
}

/// ACL SETUSER and DELUSER, each a command line whose every word is one
/// argument (`RedisProtocol.quoted`) — a name or a pattern never adds a
/// rule. A password goes as its SHA-256 (`#<hex>`), so it is never in the
/// clear on the wire, in MONITOR or the slow log. Pure.
package struct RedisUserStatements: UserStatementMaking {
    package static let commandCategories = [
        "+@all", "+@read", "+@write", "+@keyspace", "+@string", "+@hash", "+@list", "+@set", "+@sortedset", "+@stream", "+@bitmap",
        "+@geo", "+@hyperloglog", "+@pubsub", "+@transaction", "+@scripting", "+@connection", "+@fast", "+@slow", "+@admin", "+@dangerous",
    ]
    package static let keyAccess = ["read and write (~)", "read only (%R~)", "write only (%W~)"]

    package var form: UserForm {
        UserForm(
            login: true, superuser: "Every command, key and channel (~* &* +@all)",
            passwordNote:
                "The password goes as its SHA-256 (#…), never in the clear, and is never kept here. ACL SETUSER changes the running server: ACL SAVE (with an aclfile) or CONFIG REWRITE keeps it over a restart.",
            grantKinds: [
                GrantKind(title: "Commands"), GrantKind(title: "Keys", fields: [GrantField(title: "Key pattern", fill: .text("*"))]),
                GrantKind(title: "Channels", fields: [GrantField(title: "Channel pattern", fill: .text("*"))]),
            ],
            noGrants: "No rules: it may run no command.")
    }

    private func line(_ words: [String]) -> String { words.map(RedisProtocol.quoted).joined(separator: " ") }

    package static func hash(_ password: String) -> String {
        "#" + SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    package func create(_ user: NewUser) throws -> [UserStatement] {
        let name = try checked(user.name)
        guard !user.password.isEmpty else { throw Self.refusal("A password, please.") }
        // `reset` first: an ACL SETUSER of a name that exists would add to it.
        var rules = ["reset", user.login ? "on" : "off"]
        rules += user.superuser ? ["~*", "&*", "+@all"] : []
        let head = ["ACL", "SETUSER", name] + rules
        let sql = line(head + [Self.hash(user.password)])
        return [UserStatement(sql, shown: line(head) + " #••••••••")]
    }

    package func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        let name = try checked(user.name)
        guard !password.isEmpty else { throw Self.refusal("A password, please.") }
        let head = line(["ACL", "SETUSER", name, "resetpass"])
        return UserStatement(head + " " + RedisProtocol.quoted(Self.hash(password)), shown: head + " #••••••••")
    }

    package func offers(_ action: UserAction, on user: DatabaseUser) -> Bool { action != .grantRole }

    package func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        switch kind.title {
        case "Keys": .named(kind: "Keys", name: fields.first ?? "")
        case "Channels": .named(kind: "Channels", name: fields.first ?? "")
        default: .server
        }
    }

    package func privileges(on target: GrantTarget) -> [String] {
        switch target {
        case .named("Keys", _): Self.keyAccess
        case .named("Channels", _): ["subscribe and publish (&)"]
        default: Self.commandCategories
        }
    }

    package func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        let name = try checked(user.name)
        let allowed = self.privileges(on: target)
        guard !privileges.isEmpty else { throw Self.refusal("Pick what it may do.") }
        for privilege in privileges where !allowed.contains(privilege) { throw Self.refusal("\(privilege) isn't one of Redis's rules here.") }
        let rules: [String]
        switch target {
        case .named("Keys", let pattern):
            let pattern = try checked(pattern, "A key pattern")
            let both = privileges.contains(Self.keyAccess[0]) || (privileges.contains(Self.keyAccess[1]) && privileges.contains(Self.keyAccess[2]))
            rules = [both ? "~" + pattern : privileges.contains(Self.keyAccess[1]) ? "%R~" + pattern : "%W~" + pattern]
        case .named("Channels", let pattern):
            rules = ["&" + (try checked(pattern, "A channel pattern"))]
        default:
            rules = privileges
        }
        return UserStatement(line(["ACL", "SETUSER", name] + rules))
    }

    /// A row of rules taken back whole: its commands (nocommands), keys
    /// (resetkeys), channels (resetchannels), selectors (clearselectors).
    package func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        let rule: String? =
            switch grant.kind {
            case "commands": "nocommands"
            case "keys": "resetkeys"
            case "channels": "resetchannels"
            case "selector": "clearselectors"
            default: nil
            }
        guard let rule, let name = try? checked(user.name) else { return nil }
        return UserStatement(line(["ACL", "SETUSER", name, rule]))
    }

    package func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] { [] }

    package func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement { throw Self.refusal("Redis has no roles.") }

    package func drop(_ user: DatabaseUser) throws -> UserStatement { UserStatement(line(["ACL", "DELUSER", try checked(user.name)])) }
}
