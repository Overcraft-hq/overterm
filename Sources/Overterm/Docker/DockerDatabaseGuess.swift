import Foundation

/// A database container, as a connection for the Database panel: its kind
/// from the image, its user, password and database from the variables the
/// image's own documentation asks for, its port as published on this Mac.
/// Pure.
///
/// A port that isn't published can't be reached from the Mac (Docker
/// Desktop's containers live in a VM): no guess then. A remote engine's
/// is reached at its host — through ssh to it, for `ssh://`, as the
/// engine is: the Database client's own tunnel, which reaches a port bound
/// to the host's loopback too.
enum DockerDatabaseGuess {
    struct Guess: Equatable {
        var connection: DatabaseConnection
        /// From the container's env — goes to the form, then the keychain.
        var password: String?
    }

    /// The kind an image is, and the port it serves on inside.
    static func kind(of image: String) -> (DatabaseKind, port: Int)? {
        let name = image.lowercased().split(separator: "/").last.map { String($0.split(separator: ":").first ?? "") } ?? ""
        if ["postgres", "postgis", "timescaledb", "pgvector", "timescaledb-ha", "supabase-postgres"].contains(where: name.hasPrefix) { return (.postgres, 5432) }
        if ["mysql", "mariadb", "percona"].contains(where: name.hasPrefix) { return (.mysql, 3306) }
        if name.hasPrefix("clickhouse") { return (.clickhouse, 8123) }
        return nil
    }

    static func guess(_ container: ContainerSummary, env: [(key: String, value: String)], endpoint: DockerEndpoint? = nil) -> Guess? {
        guard let (kind, inside) = kind(of: container.Image),
            let published = PublishedPort.of(container.Ports ?? []).first(where: { $0.containerPort == inside && $0.proto == "tcp" })
        else { return nil }
        let values = Dictionary(env.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        func first(_ keys: String...) -> String? { keys.lazy.compactMap { values[$0] }.first { !$0.isEmpty } }
        var connection = DatabaseConnection(
            name: [container.composeProject, container.composeService].compactMap { $0 }.joined(separator: " ").nonEmpty ?? container.name, kind: kind)
        connection.host = published.hostIP ?? "127.0.0.1"
        connection.port = published.hostPort
        switch endpoint?.address {
        case .ssh(let target):
            connection.sshEnabled = true
            connection.sshHost = target.host
            connection.sshUser = target.user ?? ""
            connection.sshPort = target.port ?? 22
        case .tcp:
            if let host = endpoint?.remoteHost { connection.host = published.hostIP ?? host }
        default: break
        }
        var password: String?
        switch kind {
        case .postgres:
            connection.user = first("POSTGRES_USER") ?? "postgres"
            connection.database = first("POSTGRES_DB") ?? connection.user
            password = first("POSTGRES_PASSWORD")
            // A local container speaks no TLS.
            connection.sslMode = .disable
        case .mysql:
            if let user = first("MYSQL_USER", "MARIADB_USER") {
                connection.user = user
                password = first("MYSQL_PASSWORD", "MARIADB_PASSWORD")
            } else {
                connection.user = "root"
                password = first("MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD")
            }
            connection.database = first("MYSQL_DATABASE", "MARIADB_DATABASE") ?? ""
            connection.sslMode = .disable
        case .clickhouse:
            connection.user = first("CLICKHOUSE_USER") ?? "default"
            connection.database = first("CLICKHOUSE_DB") ?? "default"
            password = first("CLICKHOUSE_PASSWORD")
        default:
            return nil
        }
        return Guess(connection: connection, password: password)
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
