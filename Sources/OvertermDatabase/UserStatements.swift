import CommonCrypto
import CryptoKit
import Foundation

/// Whose words a user statement is in.
package enum UserDialect: Equatable, Sendable {
    case postgres, redshift, mysql, mariadb

    package var sql: SQLDialect {
        switch self {
        case .postgres: .postgres
        case .redshift: .redshift
        case .mysql: .mysql
        case .mariadb: .mariadb
        }
    }

    package var isMySQL: Bool { self == .mysql || self == .mariadb }
}

/// A statement that changes users, and how it is shown: `shown` has the
/// password replaced, and is all the preview, the confirmation and any
/// error ever say. `sql` lives in memory until it is sent, once.
package struct UserStatement: Equatable, Sendable {
    package var sql: String
    package var shown: String

    package init(_ sql: String, shown: String? = nil) {
        self.sql = sql
        self.shown = shown ?? sql
    }
}

/// What a grant is on.
package enum GrantTarget: Equatable, Hashable, Sendable {
    /// MySQL's `*.*`.
    case server
    /// PostgreSQL's database; MySQL's database's tables (`db.*`).
    case database(String)
    /// PostgreSQL's schema.
    case schema(String)
    /// Every table now in a schema (PostgreSQL's `ALL TABLES IN SCHEMA`).
    case allTables(String)
    case table(TableName)
    /// An engine's own kind of object — RabbitMQ's vhost, Redis's key
    /// pattern, Neo4j's graph: its kind as the engine says it, and its name.
    case named(kind: String, name: String)

    package var title: String {
        switch self {
        case .server: "Server (*.*)"
        case .database(let name): "Database \(name)"
        case .schema(let name): "Schema \(name)"
        case .allTables(let name): "All tables in \(name)"
        case .table(let table): "Table \(table.schema.map { "\($0)." } ?? "")\(table.name)"
        case .named(let kind, let name): "\(kind) \(name)"
        }
    }
}

/// A new user, as the Create sheet fills it in. The password is in memory
/// only, until the statement that carries it is sent.
package struct NewUser: Equatable, Sendable {
    package var name = ""
    /// MySQL's account host; `%` when empty.
    package var host = "%"
    package var password = ""
    /// PostgreSQL: a role that can log in (a user) or not (a group role).
    package var login = true
    package var superuser = false
    package var createDatabases = false
    package var createRoles = false
    /// PostgreSQL's VALID UNTIL, `yyyy-MM-dd`; empty: forever.
    package var validUntil = ""

    package init(
        name: String = "", host: String = "%", password: String = "", login: Bool = true, superuser: Bool = false, createDatabases: Bool = false, createRoles: Bool = false, validUntil: String = ""
    ) {
        self.name = name
        self.host = host
        self.password = password
        self.login = login
        self.superuser = superuser
        self.createDatabases = createDatabases
        self.createRoles = createRoles
        self.validUntil = validUntil
    }
}

/// The statements that make, change and drop users and roles, quoted the
/// engine's way — a name or a password never ends the statement it is in.
/// PostgreSQL's password goes as its SCRAM-SHA-256 verifier (as psql's
/// `\password` sends it) and Redshift's as its md5 form: neither is in the
/// clear on the wire or in a server log. MySQL's goes as `IDENTIFIED BY`,
/// which the server keeps out of its logs. Pure.
package enum UserStatements {
    package struct Refusal: Error, Equatable, LocalizedError {
        package var message: String
        package var errorDescription: String? { message }
    }

    package static let mask = "'••••••••'"

    /// The privileges a target can be granted, each a word the engine knows —
    /// nothing typed goes into a GRANT.
    package static func privileges(on target: GrantTarget, dialect: UserDialect) -> [String] {
        if dialect.isMySQL {
            let tables = ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "INDEX", "REFERENCES", "TRIGGER", "CREATE VIEW", "SHOW VIEW"]
            switch target {
            case .server:
                return ["ALL PRIVILEGES"] + tables + [
                    "CREATE USER", "PROCESS", "RELOAD", "SHOW DATABASES", "REPLICATION CLIENT", "REPLICATION SLAVE", "EXECUTE", "CREATE ROUTINE",
                    "ALTER ROUTINE", "EVENT", "LOCK TABLES", "CREATE TEMPORARY TABLES",
                ]
            case .database: return ["ALL PRIVILEGES"] + tables + ["EXECUTE", "CREATE ROUTINE", "ALTER ROUTINE", "EVENT", "LOCK TABLES", "CREATE TEMPORARY TABLES"]
            case .table: return ["ALL PRIVILEGES"] + tables
            case .schema, .allTables, .named: return []
            }
        }
        switch target {
        case .server, .named: return []
        case .database: return dialect == .redshift ? ["ALL", "CREATE", "TEMPORARY"] : ["ALL", "CONNECT", "CREATE", "TEMPORARY"]
        case .schema: return ["ALL", "USAGE", "CREATE"]
        case .table, .allTables:
            return dialect == .redshift
                ? ["ALL", "SELECT", "INSERT", "UPDATE", "DELETE", "REFERENCES"]
                : ["ALL", "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"]
        }
    }

    /// The targets an engine grants on.
    package static func targetKinds(_ dialect: UserDialect) -> [String] {
        dialect.isMySQL ? ["Server", "Database", "Table"] : ["Database", "Schema", "All tables in schema", "Table"]
    }

    // MARK: Names

    private static func checkName(_ name: String, _ what: String = "A name") throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Refusal(message: "\(what), please.") }
        guard !name.contains("\0") else { throw Refusal(message: "\(what) can't hold a NUL character.") }
    }

    /// A user as a statement names it: `"name"`, or MySQL's `'name'@'host'`
    /// (MariaDB's role: its name alone).
    package static func account(_ user: DatabaseUser, dialect: UserDialect) -> String {
        let sql = dialect.sql
        if dialect.isMySQL {
            if dialect == .mariadb, user.isRole { return sql.identifier(user.name) }
            return sql.literal(user.name) + "@" + sql.literal(user.host ?? "%")
        }
        return sql.identifier(user.name)
    }

    private static func target(_ target: GrantTarget, dialect: UserDialect) throws -> String {
        let sql = dialect.sql
        switch (target, dialect.isMySQL) {
        case (.server, true): return "*.*"
        case (.database(let name), true):
            try checkName(name, "A database")
            return sql.identifier(name) + ".*"
        case (.table(let table), true):
            try checkName(table.name, "A table")
            return sql.qualified(table)
        case (.database(let name), false):
            try checkName(name, "A database")
            return "DATABASE " + sql.identifier(name)
        case (.schema(let name), false):
            try checkName(name, "A schema")
            return "SCHEMA " + sql.identifier(name)
        case (.allTables(let name), false):
            try checkName(name, "A schema")
            return "ALL TABLES IN SCHEMA " + sql.identifier(name)
        case (.table(let table), false):
            try checkName(table.name, "A table")
            return "TABLE " + sql.qualified(table)
        default:
            throw Refusal(message: "\(target.title) isn't something \(dialect.isMySQL ? "MySQL" : "PostgreSQL") grants on.")
        }
    }

    // MARK: Statements

    /// CREATE ROLE … LOGIN PASSWORD, CREATE USER … IDENTIFIED BY. `salt` is
    /// the tests' (random otherwise).
    package static func create(_ user: NewUser, dialect: UserDialect, salt: Data? = nil) throws -> [UserStatement] {
        try checkName(user.name)
        let sql = dialect.sql
        if dialect.isMySQL {
            let account = sql.literal(user.name) + "@" + sql.literal(user.host.isEmpty ? "%" : user.host)
            guard !user.password.isEmpty else { throw Refusal(message: "A password, please.") }
            let statement = "CREATE USER \(account) IDENTIFIED BY "
            return [UserStatement(statement + sql.literal(user.password), shown: statement + mask)]
        }
        var options: [String] = []
        if dialect == .redshift {
            // Redshift: CREATE USER … PASSWORD; a user without a password can't sign in.
            guard !user.password.isEmpty else { throw Refusal(message: "A password, please.") }
            if user.superuser { options.append("CREATEUSER") }
            if user.createDatabases { options.append("CREATEDB") }
            if let until = try validUntil(user.validUntil) { options.append("VALID UNTIL \(sql.literal(until))") }
            let head = "CREATE USER \(sql.identifier(user.name)) PASSWORD "
            let tail = options.isEmpty ? "" : " " + options.joined(separator: " ")
            return [UserStatement(head + sql.literal(redshiftMD5(user.password, user: user.name)) + tail, shown: head + mask + tail)]
        }
        options.append(user.login ? "LOGIN" : "NOLOGIN")
        if user.superuser { options.append("SUPERUSER") }
        if user.createDatabases { options.append("CREATEDB") }
        if user.createRoles { options.append("CREATEROLE") }
        if let until = try validUntil(user.validUntil) { options.append("VALID UNTIL \(sql.literal(until))") }
        let head = "CREATE ROLE \(sql.identifier(user.name)) WITH \(options.joined(separator: " "))"
        guard !user.password.isEmpty else {
            guard !user.login else { throw Refusal(message: "A password, please — or a role that doesn't log in.") }
            return [UserStatement(head)]
        }
        let verifier = scramVerifier(user.password, salt: salt)
        return [UserStatement("\(head) PASSWORD \(sql.literal(verifier))", shown: "\(head) PASSWORD \(mask)")]
    }

    /// ALTER ROLE … PASSWORD, ALTER USER … IDENTIFIED BY.
    package static func password(of user: DatabaseUser, to password: String, dialect: UserDialect, salt: Data? = nil) throws -> UserStatement {
        try checkName(user.name)
        guard !password.isEmpty else { throw Refusal(message: "A password, please.") }
        let sql = dialect.sql
        switch dialect {
        case .mysql, .mariadb:
            let head = "ALTER USER \(account(user, dialect: dialect)) IDENTIFIED BY "
            return UserStatement(head + sql.literal(password), shown: head + mask)
        case .redshift:
            let head = "ALTER USER \(sql.identifier(user.name)) PASSWORD "
            return UserStatement(head + sql.literal(redshiftMD5(password, user: user.name)), shown: head + mask)
        case .postgres:
            let head = "ALTER ROLE \(sql.identifier(user.name)) PASSWORD "
            return UserStatement(head + sql.literal(scramVerifier(password, salt: salt)), shown: head + mask)
        }
    }

    package static func grant(_ privileges: [String], on object: GrantTarget, to user: DatabaseUser, dialect: UserDialect, grantOption: Bool = false) throws
        -> UserStatement
    {
        let words = try checked(privileges, on: object, dialect: dialect)
        let on = try target(object, dialect: dialect)
        return UserStatement(
            "GRANT \(words) ON \(on) TO \(account(user, dialect: dialect))" + (grantOption ? " WITH GRANT OPTION" : ""))
    }

    package static func revoke(_ privileges: [String], on object: GrantTarget, from user: DatabaseUser, dialect: UserDialect) throws -> UserStatement {
        let words = try checked(privileges, on: object, dialect: dialect)
        let on = try target(object, dialect: dialect)
        return UserStatement("REVOKE \(words) ON \(on) FROM \(account(user, dialect: dialect))")
    }

    /// A role's membership: GRANT role TO user (Redshift: a group's ADD USER).
    package static func grantRole(_ role: DatabaseUser, to user: DatabaseUser, dialect: UserDialect) throws -> UserStatement {
        try checkName(role.name, "A role")
        if dialect == .redshift {
            return UserStatement("ALTER GROUP \(dialect.sql.identifier(role.name)) ADD USER \(dialect.sql.identifier(user.name))")
        }
        return UserStatement("GRANT \(account(role, dialect: dialect)) TO \(account(user, dialect: dialect))")
    }

    package static func revokeRole(_ role: DatabaseUser, from user: DatabaseUser, dialect: UserDialect) throws -> UserStatement {
        try checkName(role.name, "A role")
        if dialect == .redshift {
            return UserStatement("ALTER GROUP \(dialect.sql.identifier(role.name)) DROP USER \(dialect.sql.identifier(user.name))")
        }
        return UserStatement("REVOKE \(account(role, dialect: dialect)) FROM \(account(user, dialect: dialect))")
    }

    /// DROP ROLE, DROP USER (a MariaDB role: DROP ROLE).
    package static func drop(_ user: DatabaseUser, dialect: UserDialect) throws -> UserStatement {
        try checkName(user.name)
        switch dialect {
        case .postgres: return UserStatement("DROP ROLE \(account(user, dialect: dialect))")
        case .redshift: return UserStatement(user.isRole ? "DROP GROUP \(account(user, dialect: dialect))" : "DROP USER \(account(user, dialect: dialect))")
        case .mysql, .mariadb: return UserStatement((user.isRole ? "DROP ROLE " : "DROP USER ") + account(user, dialect: dialect))
        }
    }

    private static func checked(_ privileges: [String], on object: GrantTarget, dialect: UserDialect) throws -> String {
        let allowed = Self.privileges(on: object, dialect: dialect)
        guard !privileges.isEmpty else { throw Refusal(message: "Pick a privilege.") }
        for privilege in privileges where !allowed.contains(privilege) {
            throw Refusal(message: "\(privilege) isn't a privilege on \(object.title.lowercased()).")
        }
        // ALL alone: beside it the others say nothing more.
        if let all = privileges.first(where: { $0.hasPrefix("ALL") }) { return all }
        return privileges.joined(separator: ", ")
    }

    /// `yyyy-MM-dd`, checked to be a date; nil when empty.
    private static func validUntil(_ text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard formatter.date(from: trimmed) != nil else { throw Refusal(message: "Valid until is a date: 2027-01-31.") }
        return trimmed
    }

    // MARK: Passwords, never in the clear

    /// PostgreSQL's stored form of a password (RFC 5803, as `\password` makes
    /// it): `SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>`.
    package static func scramVerifier(_ password: String, salt: Data? = nil, iterations: Int = 4096) -> String {
        let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let prepared = Data(MongoSCRAM.saslPrep(password).utf8)
        var salted = [UInt8](repeating: 0, count: 32)
        _ = prepared.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), prepared.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations), &salted, salted.count)
            }
        }
        let key = SymmetricKey(data: salted)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: key))
        let storedKey = Data(SHA256.hash(data: clientKey))
        let serverKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: key))
        return "SCRAM-SHA-256$\(iterations):\(salt.base64EncodedString())$\(storedKey.base64EncodedString()):\(serverKey.base64EncodedString())"
    }

    /// Redshift's: `md5` and the MD5 of the password then the user's name.
    package static func redshiftMD5(_ password: String, user: String) -> String {
        "md5" + Insecure.MD5.hash(data: Data((password + user).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
