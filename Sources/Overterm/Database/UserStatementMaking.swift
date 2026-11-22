import Foundation

/// How a kind's user changes are made, and what the Users page's sheets
/// ask for them. The SQL engines' is `SQLUserStatements`, over
/// `UserStatements`; a kind whose words aren't SQL's — Neo4j's Cypher,
/// InfluxQL, RabbitMQ's management API, Redis's ACL — makes its own. Every
/// statement is `UserStatement`: `sql` what is sent (a statement, or a
/// request the driver reads back), `shown` with any password masked. Pure.
package protocol UserStatementMaking: Sendable {
    /// What the sheets show and offer.
    var form: UserForm { get }
    func create(_ user: NewUser) throws -> [UserStatement]
    func password(of user: DatabaseUser, to password: String) throws -> UserStatement
    /// Whether Change Password…, Grant… and Grant Role… are offered on a user or role.
    func offers(_ action: UserAction, on user: DatabaseUser) -> Bool
    /// The target a Grant sheet's kind and its fields name.
    func target(_ kind: GrantKind, fields: [String]) -> GrantTarget
    /// The privileges a target can be granted, each a word the engine knows.
    func privileges(on target: GrantTarget) -> [String]
    func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement
    /// The statement that takes a listed grant back, when it is one the engine can name.
    func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement?
    /// Who may be granted to a user as a role.
    func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser]
    func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement
    func drop(_ user: DatabaseUser) throws -> UserStatement
}

package enum UserAction: Sendable { case password, grant, grantRole, drop }

/// A Grant sheet's kind of target, and the fields it is named by.
package struct GrantKind: Hashable, Sendable {
    package var title: String
    package var fields: [GrantField] = []
}

package struct GrantField: Hashable, Sendable {
    /// What the field is filled with when the sheet opens.
    package enum Fill: Hashable, Sendable {
        case empty
        /// The connection's database (vhost).
        case database
        /// The console's schema, else `public`.
        case schema
        case text(String)
    }

    package var title: String
    package var fill = Fill.empty
}

/// What the Users page's sheets show for a kind.
package struct UserForm: Equatable, Sendable {
    /// What names an account besides its name (`NewUser.host`), as the
    /// Create sheet asks for it — MySQL's host, MongoDB's database it signs
    /// in to; nil: nothing.
    package var account: String?
    /// What that field holds when the sheet opens; nil: `NewUser`'s own.
    package var accountFill: String?
    /// PostgreSQL's "Logs in" (a group role doesn't).
    package var login = false
    /// The superuser toggle's words, nil: none.
    package var superuser: String? = "Superuser"
    package var createDatabases = false
    package var createRoles = false
    package var validUntil = false
    /// Under the password fields: where it goes, and that it isn't kept.
    package var passwordNote = "The password is sent once, over this connection, and never kept here."
    package var grantKinds: [GrantKind] = []
    package var grantOption = false
    /// Under a user's grants.
    package var grantsNote: String?
    /// When a user has none listed.
    package var noGrants = "None of its own."
    /// What a user is called in the sheets' titles.
    package var noun = "User"
    /// A SQL engine's statements, made by a maker of its own (Oracle's,
    /// ClickHouse's): listed with `;` as `SQLUserStatements`' are.
    package var sql = false
}

/// The SQL engines' user statements — `UserStatements` in their dialect.
package struct SQLUserStatements: UserStatementMaking {
    package let dialect: UserDialect

    package var form: UserForm {
        let mysql = dialect.isMySQL
        let kinds: [GrantKind] =
            mysql
            ? [
                GrantKind(title: "Server"), GrantKind(title: "Database", fields: [GrantField(title: "Database", fill: .database)]),
                GrantKind(
                    title: "Table", fields: [GrantField(title: "Database", fill: .database), GrantField(title: "Table")]),
            ]
            : [
                GrantKind(title: "Database", fields: [GrantField(title: "Database", fill: .database)]),
                GrantKind(title: "Schema", fields: [GrantField(title: "Schema", fill: .schema)]),
                GrantKind(title: "All tables in schema", fields: [GrantField(title: "Schema", fill: .schema)]),
                GrantKind(title: "Table", fields: [GrantField(title: "Schema", fill: .schema), GrantField(title: "Table")]),
            ]
        return UserForm(
            account: mysql ? "Host (% is any)" : nil, login: dialect == .postgres, superuser: mysql ? nil : "Superuser", createDatabases: !mysql,
            createRoles: dialect == .postgres, validUntil: !mysql,
            passwordNote: dialect == .postgres
                ? "The password is sent as its SCRAM-SHA-256 verifier — never in the clear, and never kept here."
                : dialect == .redshift ? "The password is sent as its md5 form, and never kept here." : "The password is sent once, over this connection, and never kept here.",
            grantKinds: kinds, grantOption: true,
            grantsNote: dialect == .postgres ? "Tables and schemas of this database; databases of the server." : nil,
            noGrants: "None of its own — it may still have what PUBLIC is granted, or its roles'.")
    }

    package func create(_ user: NewUser) throws -> [UserStatement] { try UserStatements.create(user, dialect: dialect) }

    package func password(of user: DatabaseUser, to password: String) throws -> UserStatement {
        try UserStatements.password(of: user, to: password, dialect: dialect)
    }

    package func offers(_ action: UserAction, on user: DatabaseUser) -> Bool {
        action != .password || !user.isRole || !dialect.isMySQL
    }

    package func target(_ kind: GrantKind, fields: [String]) -> GrantTarget {
        func field(_ at: Int) -> String { fields.indices.contains(at) ? fields[at] : "" }
        switch kind.title {
        case "Server": return .server
        case "Schema": return .schema(field(0))
        case "All tables in schema": return .allTables(field(0))
        case "Table": return .table(TableName(schema: field(0), name: field(1)))
        default: return .database(field(0))
        }
    }

    package func privileges(on target: GrantTarget) -> [String] { UserStatements.privileges(on: target, dialect: dialect) }

    package func grant(_ privileges: [String], on target: GrantTarget, to user: DatabaseUser, grantOption: Bool) throws -> UserStatement {
        try UserStatements.grant(privileges, on: target, to: user, dialect: dialect, grantOption: grantOption)
    }

    package func revoke(_ grant: DatabaseGrant, from user: DatabaseUser) -> UserStatement? {
        if grant.kind == "role" {
            let parts = grant.object.split(separator: "@", maxSplits: 1).map(String.init)
            let role = DatabaseUser(name: parts.first ?? grant.object, host: dialect == .mysql && parts.count > 1 ? parts[1] : nil, isRole: true)
            return try? UserStatements.revokeRole(role, from: user, dialect: dialect)
        }
        guard let target = GrantTargets.target(of: grant, dialect: dialect) else { return nil }
        let allowed = UserStatements.privileges(on: target, dialect: dialect)
        let privileges = grant.privileges.filter(allowed.contains)
        guard !privileges.isEmpty else { return nil }
        return try? UserStatements.revoke(privileges, on: target, from: user, dialect: dialect)
    }

    /// Roles first; PostgreSQL grants any role, MySQL 8 any account.
    package func roleCandidates(for user: DatabaseUser, among users: [DatabaseUser]) -> [DatabaseUser] {
        let others = users.filter { $0.id != user.id && !user.memberOf.contains($0.display) }
        let roles = others.filter(\.isRole)
        return dialect == .mariadb || dialect == .redshift ? roles : roles + others.filter { !$0.isRole }
    }

    package func grantRole(_ role: DatabaseUser, to user: DatabaseUser) throws -> UserStatement {
        try UserStatements.grantRole(role, to: user, dialect: dialect)
    }

    package func drop(_ user: DatabaseUser) throws -> UserStatement { try UserStatements.drop(user, dialect: dialect) }
}

extension UserStatementMaking {
    /// A refusal in the sheets' words.
    package static func refusal(_ message: String) -> UserStatements.Refusal { UserStatements.Refusal(message: message) }

    /// A name, checked as `UserStatements` checks its own.
    package func checked(_ name: String, _ what: String = "A name") throws -> String {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw UserStatements.Refusal(message: "\(what), please.") }
        guard !name.contains("\0") else { throw UserStatements.Refusal(message: "\(what) can't hold a NUL character.") }
        return name
    }
}

/// A user change that is an HTTP request — RabbitMQ's management API,
/// InfluxDB 2's — as the preview shows it and the driver reads it back:
/// `METHOD /api/path {json}`; `NEW` before it, only where nothing is there
/// yet (a new user never replaces one). Pure.
package struct UserRequest: Equatable {
    package var onlyNew = false
    package var method: String
    package var path: String
    package var body: String?

    package init?(_ text: String) {
        var rest = Substring(text)
        if rest.hasPrefix("NEW ") {
            onlyNew = true
            rest = rest.dropFirst(4)
        }
        let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, ["GET", "PUT", "POST", "PATCH", "DELETE"].contains(parts[0]), parts[1].hasPrefix("/api/") else { return nil }
        method = parts[0]
        path = parts[1]
        body = parts.count > 2 ? parts[2] : nil
    }

    /// A JSON body, keys sorted.
    package static func json(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
