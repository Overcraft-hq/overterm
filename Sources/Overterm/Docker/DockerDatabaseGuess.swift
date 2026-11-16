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

    /// The kind an image is, and the port it serves on inside: the same
    /// table as its own client's (`DockerClient`), so a tool named after a
    /// database — PostgREST, an exporter, a keeper — is none.
    static func kind(of image: String) -> (DatabaseKind, port: Int)? {
        DockerClient.kind(of: image)?.database ?? searchKind(words: DockerClient.words(of: image))
    }

    /// Elasticsearch and OpenSearch have no client to run inside, so no
    /// `DockerClient.Kind`: their images by name — Elastic's and the
    /// library's `elasticsearch`, `opensearchproject/opensearch`, Bitnami's
    /// — never Dashboards, Kibana or an exporter.
    static func searchKind(words: [String]) -> (DatabaseKind, port: Int)? {
        let words = Set(words)
        guard words.isDisjoint(with: DockerClient.toolWords), words.isDisjoint(with: ["dashboards", "kibana", "logstash", "beat"]) else { return nil }
        if words.contains("opensearch") { return (.opensearch, 9200) }
        if words.contains("elasticsearch") { return (.elasticsearch, 9200) }
        return nil
    }

    /// A container's, by the same rule as its client's: a compose
    /// project's name in its image says nothing, and an image listed by
    /// its ID is known by `reference` (inspect's `Config.Image`).
    static func kind(of container: ContainerSummary, reference: String? = nil) -> (DatabaseKind, port: Int)? {
        if let found = DockerClient.kind(of: container, reference: reference)?.database { return found }
        let image = DockerClient.listsImageByID(container) ? reference : container.Image
        return image.flatMap { searchKind(words: DockerClient.words(of: $0)) }
    }

    static func guess(
        _ container: ContainerSummary, env: [(key: String, value: String)], endpoint: DockerEndpoint? = nil, reference: String? = nil
    ) -> Guess? {
        guard let (kind, inside) = kind(of: container, reference: reference),
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
            if let host = endpoint?.remoteHost {
                // Bound to that host's own loopback: only the host reaches it,
                // and 127.0.0.1 here is this Mac.
                if let ip = published.hostIP, ["127.0.0.1", "::1"].contains(ip) { return nil }
                connection.host = published.hostIP ?? host
            }
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
            // The image makes the app's user only given its password too.
            if let user = first("MYSQL_USER", "MARIADB_USER"), let own = first("MYSQL_PASSWORD", "MARIADB_PASSWORD") {
                connection.user = user
                password = own
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
        case .redis:
            // The official image has no password of its own; Bitnami's say
            // theirs here. One given as `--requirepass` is asked for.
            password = first("REDIS_PASSWORD", "VALKEY_PASSWORD")
            connection.sslMode = .disable
        case .elasticsearch:
            // 8's image turns security on — the `elastic` user, TLS with a
            // certificate of its own — unless the env turns it off.
            let security = first("xpack.security.enabled")?.lowercased() != "false"
            let tls =
                security && first("xpack.security.http.ssl.enabled")?.lowercased() != "false"
                && Self.majorTag(reference ?? container.Image) >= 8
            if security {
                connection.user = "elastic"
                password = first("ELASTIC_PASSWORD", "ELASTICSEARCH_PASSWORD")
            }
            connection.sslMode = tls ? .require : .disable
        case .opensearch:
            // The security plugin: `admin`, its demo certificate — unless disabled.
            let disabled =
                first("DISABLE_SECURITY_PLUGIN")?.lowercased() == "true" || first("plugins.security.disabled")?.lowercased() == "true"
            if !disabled {
                connection.user = "admin"
                password = first("OPENSEARCH_INITIAL_ADMIN_PASSWORD", "OPENSEARCH_PASSWORD")
            }
            connection.sslMode = disabled ? .disable : .require
        default:
            return nil
        }
        return Guess(connection: connection, password: password)
    }
}

extension DockerDatabaseGuess {
    /// An image's tag's major version (`elasticsearch:7.17.10` → 7); a
    /// tag that isn't a version (`latest`) the newest, so Int.max.
    static func majorTag(_ image: String) -> Int {
        let name = image.split(separator: "@").first.map(String.init) ?? image
        guard let last = name.split(separator: "/").last, let colon = last.lastIndex(of: ":") else { return .max }
        let tag = last[last.index(after: colon)...]
        return Int(tag.prefix { $0.isNumber }) ?? .max
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
