import Foundation

/// A database's or a broker's own client, run in its container by
/// `docker exec -it` in a terminal tab: psql, mysql, redis-cli… The image
/// says which (`kind(of:)`); the env says who to sign in as — by name only:
/// the command says `"$POSTGRES_PASSWORD"` inside `sh -c '…'` and the
/// container's shell expands it, so no secret is on the tab's command line,
/// in its history or in Overterm. Pure.
enum DockerClient {
    enum Kind: String, CaseIterable, Sendable {
        case postgres, mysql, mariadb, redis, valkey, mongo, clickhouse, cassandra, neo4j, mssql

        /// The client, as its button says it.
        var program: String {
            switch self {
            case .postgres: "psql"
            case .mysql: "mysql"
            case .mariadb: "mariadb"
            case .redis: "redis-cli"
            case .valkey: "valkey-cli"
            case .mongo: "mongosh"
            case .clickhouse: "clickhouse-client"
            case .cassandra: "cqlsh"
            case .neo4j: "cypher-shell"
            case .mssql: "sqlcmd"
            }
        }

        /// The Database panel's kind and the port it serves on inside
        /// (`DockerDatabaseGuess`); nil for what the panel doesn't speak.
        var database: (DatabaseKind, port: Int)? {
            switch self {
            case .postgres: (.postgres, 5432)
            case .mysql, .mariadb: (.mysql, 3306)
            case .clickhouse: (.clickhouse, 8123)
            default: nil
            }
        }

        /// The words of an image's name that mean it. The first kind that
        /// has one wins: percona-server-mongodb is Mongo, and
        /// percona-distribution-postgresql PostgreSQL.
        static let imageWords: [(Kind, Set<String>)] = [
            (.mongo, ["mongo", "mongodb"]),
            (.postgres, ["postgres", "postgresql", "postgis", "timescaledb", "pgvector"]),
            (.mariadb, ["mariadb"]),
            (.mysql, ["mysql", "percona"]),
            (.valkey, ["valkey"]),
            (.redis, ["redis"]),
            (.clickhouse, ["clickhouse"]),
            (.cassandra, ["cassandra", "scylla"]),
            (.neo4j, ["neo4j"]),
            (.mssql, ["mssql"]),
        ]
    }

    /// Words that make an image a tool beside a database rather than the
    /// database: an exporter, a UI, a proxy, a keeper.
    static let toolWords: Set<String> = [
        "exporter", "express", "commander", "insight", "redisinsight", "admin", "ui", "web", "gui", "studio", "operator", "backup", "xtrabackup",
        "proxy", "router", "bouncer", "maxscale", "keeper", "sentinel", "manager", "meta", "client", "tools", "monitor", "agent", "connector",
        "migrate", "pmm",
    ]

    /// `docker.io/library/postgres:16@sha256:…` → `["library", "postgres"]`:
    /// lowercased, the digest dropped, the registry dropped (a first
    /// component with a `.` or a `:`, or `localhost`, when more follow),
    /// the last component's tag dropped.
    static func components(of image: String) -> [String] {
        let name = image.lowercased().split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var components = name.split(separator: "/").map(String.init)
        if components.count > 1, let first = components.first, first.contains(".") || first.contains(":") || first == "localhost" {
            components.removeFirst()
        }
        if let last = components.last, let colon = last.lastIndex(of: ":") {
            components[components.count - 1] = String(last[..<colon])
        }
        return components
    }

    /// The components' words: each split on `-`, `_` and `.`.
    static func words(of image: String) -> [String] { split(components(of: image)) }

    private static func split(_ components: [String]) -> [String] {
        components.flatMap { $0.split(whereSeparator: { "-_.".contains($0) }).map(String.init) }
    }

    /// The kind an image is, by the words of its name; nil for one named
    /// for a tool beside a database (`postgres-exporter`, `mongo-express`).
    static func kind(of image: String) -> Kind? { kind(words: words(of: image)) }

    private static func kind(words: [String]) -> Kind? {
        let words = Set(words)
        guard !words.isEmpty, words.isDisjoint(with: toolWords) else { return nil }
        return Kind.imageWords.first { !$0.1.isDisjoint(with: words) }?.0
    }

    /// The kind a container is, by its image's name: what its verbs, `q`
    /// and Open in Database all ask. Compose names an image it builds
    /// after the project and the service (`shop-wt-fix-redis-timeout-api`),
    /// and a worktree's project after its branch. The project's name
    /// leading the image's says nothing about it, so it is dropped: a
    /// branch about Redis gives no service redis-cli, and a project called
    /// `admin-panel` keeps its built `postgres`'s psql. Docker lists an
    /// image by its ID once its tag has moved on to a newer one (a pull):
    /// then `reference` says, the name inspect keeps (`Config.Image`).
    static func kind(of container: ContainerSummary, reference: String? = nil) -> Kind? {
        var image = container.Image
        if listsImageByID(container) {
            guard let reference else { return nil }
            image = reference
        }
        var components = components(of: image)
        if let project = container.composeProject?.lowercased(), let last = components.last,
            let lead = [project + "-", project + "_"].first(where: { last.hasPrefix($0) && last.count > $0.count })
        {
            components[components.count - 1] = String(last.dropFirst(lead.count))
        }
        return kind(words: split(components))
    }

    /// Whether the list names the image only by its ID: what Docker's
    /// says once the tag the container was made from names another image.
    static func listsImageByID(_ container: ContainerSummary) -> Bool {
        container.Image.hasPrefix("sha256:") || container.Image == container.ImageID
    }

    /// The names the env gives a non-empty value. Only the names, never the
    /// values, go any further.
    static func names(in env: [(key: String, value: String)]) -> Set<String> {
        Set(env.filter { !$0.value.isEmpty }.map(\.key))
    }

    /// The first of `names` the env has, as the container's shell reads it:
    /// `"$NAME"`, or `"$(cat "$NAME_FILE")"` for a Docker secret's file (the
    /// images' `_FILE` convention). Each name is tried bare, then with
    /// `_FILE`, before the next.
    static func word(_ names: String..., in env: Set<String>) -> String? { word(names, in: env) }

    static func word(_ names: [String], in env: Set<String>) -> String? {
        for name in names {
            if env.contains(name) { return "\"$\(name)\"" }
            if env.contains(name + "_FILE") { return "\"$(cat \"$\(name)_FILE\")\"" }
        }
        return nil
    }

    /// Shell statements first, then the client's words: literals, or what
    /// `word` gives.
    static func invocation(_ kind: Kind, env: Set<String>) -> (setup: [String], words: [String]) {
        func word(_ names: String...) -> String? { DockerClient.word(names, in: env) }
        switch kind {
        case .postgres:
            // Over the socket, which the official image trusts. Its
            // database is named after POSTGRES_USER unless the env says;
            // Bitnami's is `postgres` whoever the user.
            let user = word("POSTGRES_USER", "POSTGRESQL_USERNAME") ?? "postgres"
            let database = word("POSTGRES_DB", "POSTGRESQL_DATABASE") ?? word("POSTGRES_USER") ?? "postgres"
            let setup = word("POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD").map { ["export PGPASSWORD=" + $0] } ?? []
            return (setup, ["psql", "-U", user, "-d", database])
        case .mysql, .mariadb:
            let mariadb = kind == .mariadb
            func mysqlWord(_ suffix: String) -> String? { mariadb ? word("MARIADB_" + suffix, "MYSQL_" + suffix) : word("MYSQL_" + suffix) }
            // 11.x images have no `mysql`, 10.3 and older no `mariadb`.
            var words = [mariadb ? "\"$(command -v mariadb || echo mysql)\"" : "mysql"]
            // The app's own user over root, as Open in Database — when the
            // image made it: it makes one only given its password too.
            if let user = mysqlWord("USER"), let password = mysqlWord("PASSWORD") {
                words += ["-u", user, "-p" + password]
            } else {
                words += ["-u", "root"]
                let empty = env.contains("MYSQL_ALLOW_EMPTY_PASSWORD") || (mariadb && env.contains("MARIADB_ALLOW_EMPTY_ROOT_PASSWORD"))
                if let password = mysqlWord("ROOT_PASSWORD") {
                    words.append("-p" + password)
                } else if !empty {
                    // Asks for it.
                    words.append("-p")
                }
            }
            if let database = mysqlWord("DATABASE") { words.append(database) }
            return ([], words)
        case .redis, .valkey:
            let password = kind == .valkey ? word("VALKEY_PASSWORD", "REDIS_PASSWORD") : word("REDIS_PASSWORD")
            let port = kind == .valkey ? word("VALKEY_PORT_NUMBER") : word("REDIS_PORT_NUMBER")
            // valkey-cli still reads REDISCLI_AUTH, its old name.
            return (password.map { ["export REDISCLI_AUTH=" + $0] } ?? [], [kind.program] + (port.map { ["-p", $0] } ?? []))
        case .mongo:
            let user = word("MONGO_INITDB_ROOT_USERNAME", "MONGODB_ROOT_USER")
            let password = word("MONGO_INITDB_ROOT_PASSWORD", "MONGODB_ROOT_PASSWORD")
            // Images before 6 have only `mongo`.
            var words = ["\"$(command -v mongosh || echo mongo)\""]
            if let login = user ?? (password != nil ? "root" : nil) {
                words += ["-u", login] + (password.map { ["-p", $0] } ?? []) + ["--authenticationDatabase", "admin"]
            }
            if let database = word("MONGO_INITDB_DATABASE", "MONGODB_DATABASE") { words.append(database) }
            return ([], words)
        case .clickhouse:
            // clickhouse-client reads CLICKHOUSE_USER and _PASSWORD itself:
            // exported only when they come from another name — Bitnami's
            // ADMIN ones, or a secret's file.
            var setup: [String] = []
            let names = [
                ("CLICKHOUSE_USER", ["CLICKHOUSE_USER", "CLICKHOUSE_ADMIN_USER"]), ("CLICKHOUSE_PASSWORD", ["CLICKHOUSE_PASSWORD", "CLICKHOUSE_ADMIN_PASSWORD"]),
            ]
            for (target, sources) in names {
                if let found = DockerClient.word(sources, in: env), found != "\"$\(target)\"" {
                    setup.append("export \(target)=\(found)")
                }
            }
            return (setup, ["clickhouse-client"] + (word("CLICKHOUSE_DB").map { ["--database", $0] } ?? []))
        case .cassandra:
            // cqlsh takes no password from the env: it asks.
            return ([], ["cqlsh"] + (word("CASSANDRA_USER").map { ["-u", $0] } ?? []))
        case .neo4j:
            // NEO4J_AUTH is `user/password`, or `none`.
            guard let auth = word("NEO4J_AUTH") else { return ([], ["cypher-shell"]) }
            let split = #"[ "$NEO4J_AUTH" = none ] || export NEO4J_USERNAME="${NEO4J_AUTH%%/*}" NEO4J_PASSWORD="${NEO4J_AUTH#*/}""#
            return (auth == #""$NEO4J_AUTH""# ? [split] : ["NEO4J_AUTH=" + auth, split], ["cypher-shell"])
        case .mssql:
            // The tools moved to mssql-tools18 in 2022's CU14.
            var setup = ["c=/opt/mssql-tools18/bin/sqlcmd", #"[ -x "$c" ] || c=/opt/mssql-tools/bin/sqlcmd"#]
            if let password = word("MSSQL_SA_PASSWORD", "SA_PASSWORD") { setup.append("export SQLCMDPASSWORD=" + password) }
            return (setup, [#""$c""#, "-S", "localhost", "-U", "sa", "-C"])
        }
    }

    /// What runs in the container: the client's own words when nothing in
    /// them is for a shell to expand, else `sh -c` and a script.
    static func arguments(_ kind: Kind, env: Set<String>) -> [String] {
        let (setup, words) = invocation(kind, env: env)
        if setup.isEmpty, !words.contains(where: { $0.contains { "$\"'".contains($0) } }) { return words }
        return ["sh", "-c", (setup + ["exec " + words.joined(separator: " ")]).joined(separator: "; ")]
    }

    /// `docker exec -it <name> …`, as typed into a terminal tab.
    static func command(_ kind: Kind, in container: ContainerSummary, env: Set<String>, endpoint: DockerEndpoint? = nil) -> String {
        DockerCommands.prefix(for: endpoint) + (["docker", "exec", "-it", container.name] + arguments(kind, env: env)).map(DockerCommands.quote).joined(separator: " ")
    }
}
