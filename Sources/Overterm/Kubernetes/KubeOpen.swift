import Foundation

// MARK: What opens through a forward (stage 1d; docs/design/kubernetes/analysis.md, 3.8)

/// Where an Ingress is reached from outside: each rule's host, https when
/// a TLS entry names it, at the rule's first plain path — else the
/// address the controller gave it. `o` opens the first in the default
/// browser: it is the cluster's own front door, not a forward. Pure.
enum KubeIngressLinks {
    static func urls(of ingress: [String: Any]) -> [URL] {
        let spec = ingress["spec"] as? [String: Any] ?? [:]
        let tls = spec["tls"] as? [[String: Any]] ?? []
        let secured = Set(tls.flatMap { $0["hosts"] as? [String] ?? [] }.map { $0.lowercased() })
        var urls: [URL] = []
        func add(_ text: String) {
            guard let url = URL(string: text), url.host != nil, !urls.contains(url) else { return }
            urls.append(url)
        }
        for rule in spec["rules"] as? [[String: Any]] ?? [] {
            // A wildcard host names no one page.
            guard let host = (rule["host"] as? String)?.lowercased(), !host.isEmpty, !host.contains("*") else { continue }
            let paths = (rule["http"] as? [String: Any])?["paths"] as? [[String: Any]] ?? []
            add("\(secured.contains(host) ? "https" : "http")://\(host)\(plainPath(paths.first?["path"] as? String))")
        }
        if urls.isEmpty {
            let status = ingress["status"] as? [String: Any] ?? [:]
            for entry in (status["loadBalancer"] as? [String: Any])?["ingress"] as? [[String: Any]] ?? [] {
                guard let address = (entry["hostname"] ?? entry["ip"]) as? String, !address.isEmpty else { continue }
                add("\(tls.isEmpty ? "http" : "https")://\(address.contains(":") ? "[\(address)]" : address)/")
            }
        }
        return urls
    }

    /// A rule's path as a page's: one written as a pattern (nginx's regex
    /// paths) is no page, so the root instead.
    static func plainPath(_ path: String?) -> String {
        guard let path, path.hasPrefix("/"), path.rangeOfCharacter(from: CharacterSet(charactersIn: "()*$^[]\\?+|{} ")) == nil else { return "/" }
        return path
    }
}

/// What a value of a pod's env is, as its spec says: written there, or a
/// Secret's key it refers to — which is never read unless the user asks,
/// and then only that key is kept (rule 9). Pure.
enum KubeEnvValue: Equatable, Sendable {
    case literal(String)
    case secret(name: String, key: String)
    /// A key an `envFrom` Secret gives only if it holds it, which isn't
    /// known without reading it: read and not there, the next name the
    /// image reads is tried.
    case secretIfHeld(name: String, key: String)
    /// A ConfigMap's key, a field of the pod: not read.
    case elsewhere

    var secretName: String? {
        switch self {
        case .secret(let name, _), .secretIfHeld(let name, _): name
        case .literal, .elsewhere: nil
        }
    }
}

/// What a Secret is asked for: the keys the env names from it, and those
/// an `envFrom` takes from it only if it holds them. Pure.
struct KubeSecretWant: Equatable, Sendable {
    var secret: String
    var keys: [String] = []
    var ifHeld: [String] = []

    /// Every key kept from the one GET.
    var all: [String] { keys + ifHeld.filter { !keys.contains($0) } }

    /// As the question names it: `db-auth (password)`, `pg-env (whichever
    /// of POSTGRES_PASSWORD, POSTGRESQL_PASSWORD it holds)`.
    var said: String {
        var parts: [String] = []
        if !keys.isEmpty { parts.append(keys.joined(separator: ", ")) }
        let maybe = ifHeld.filter { !keys.contains($0) }
        if !maybe.isEmpty { parts.append(maybe.count == 1 ? "\(maybe[0]) if it holds it" : "whichever of \(maybe.joined(separator: ", ")) it holds") }
        return "\(secret) (\(parts.joined(separator: "; ")))"
    }
}

/// What was read of the Secrets the user agreed to: each value kept by
/// `secret/key`, and which Secrets the GET answered — a key one of those
/// doesn't hold is then known not to be there. Pure.
struct KubeSecretValues: Equatable, Sendable {
    var values: [String: String] = [:]
    var read: Set<String> = []
}

/// A database pod, as `d` sees it: which kind its image is (the same table
/// as Docker's own client, `DockerClient`), its container and the port it
/// serves on, and where its user, database and password come from. Pure.
struct KubeDatabaseTarget: Equatable, Sendable {
    var kind: DatabaseKind
    var container: String
    var image: String
    /// The container's port the database serves on: the forward's remote end.
    var port: Int
    /// Each field's sources, in the order the image reads its names: the
    /// first given wins — an `envFrom` Secret's key giving way to the next
    /// once the Secret, read, turns out not to hold it.
    var user: [KubeEnvValue] = []
    var database: [KubeEnvValue] = []
    var password: [KubeEnvValue] = []
    /// MySQL's root password: the image makes the app's user only given
    /// its password too, else the user is root — decided once what was
    /// read is known. Empty when the app's user is sure.
    var rootPassword: [KubeEnvValue] = []
    /// The user and database the image starts with when its env says none.
    var defaultUser: String
    var defaultDatabase: String?

    /// The Secrets its env refers to, each with the keys wanted from it:
    /// what one GET each, on the user's ask, would read.
    var secretKeys: [KubeSecretWant] {
        var wants: [KubeSecretWant] = []
        func add(_ name: String, _ change: (inout KubeSecretWant) -> Void) {
            if let index = wants.firstIndex(where: { $0.secret == name }) {
                change(&wants[index])
            } else {
                var want = KubeSecretWant(secret: name)
                change(&want)
                wants.append(want)
            }
        }
        for value in user + database + password + rootPassword {
            switch value {
            case .secret(let name, let key): add(name) { if !$0.keys.contains(key) { $0.keys.append(key) } }
            case .secretIfHeld(let name, let key): add(name) { if !$0.ifHeld.contains(key) { $0.ifHeld.append(key) } }
            case .literal, .elsewhere: break
            }
        }
        return wants
    }

    /// Whether the password is one only a Secret holds.
    var passwordInSecret: Bool { (password + rootPassword).contains { $0.secretName != nil } }
}

enum KubeDatabase {
    /// The kinds the Database client speaks, as the page says them.
    static let spoken = "PostgreSQL, MySQL, MariaDB and ClickHouse"

    /// The first container whose image is a database the Database client
    /// speaks; nil when none is.
    static func detect(_ pod: [String: Any]) -> KubeDatabaseTarget? {
        for container in containers(of: pod) {
            guard let image = container["image"] as? String, let (kind, inside) = DockerClient.kind(of: image)?.database else { continue }
            let env = env(of: container)
            let declared = (container["ports"] as? [[String: Any]] ?? []).filter { ($0["protocol"] as? String ?? "TCP") == "TCP" }
                .compactMap { KubeForwardResolve.int($0["containerPort"]) }
            var target = KubeDatabaseTarget(
                kind: kind, container: container["name"] as? String ?? "", image: image, port: port(kind, inside: inside, declared: declared),
                defaultUser: "", defaultDatabase: nil)
            // A name's source, then the next names' while it is an
            // envFrom Secret's key that may not be there.
            func sources(_ names: [String]) -> [KubeEnvValue] {
                var found: [KubeEnvValue] = []
                for name in names {
                    guard let value = env[name] else { continue }
                    found.append(value)
                    if case .secretIfHeld = value { continue }
                    break
                }
                return found
            }
            func sure(_ sources: [KubeEnvValue]) -> Bool { sources.contains { if case .secretIfHeld = $0 { false } else { true } } }
            switch kind {
            case .postgres:
                target.user = sources(["POSTGRES_USER", "POSTGRESQL_USERNAME", "POSTGRESQL_USER"])
                target.database = sources(["POSTGRES_DB", "POSTGRESQL_DATABASE", "POSTGRES_DATABASE"])
                target.password = sources(["POSTGRES_PASSWORD", "POSTGRESQL_PASSWORD"])
                target.defaultUser = "postgres"
            case .mysql:
                // The image makes the app's user only given its password
                // too; else root — which, while an envFrom Secret may or
                // may not hold them, is decided once it is read.
                let user = sources(["MYSQL_USER", "MARIADB_USER"])
                let password = sources(["MYSQL_PASSWORD", "MARIADB_PASSWORD"])
                if !user.isEmpty && !password.isEmpty {
                    target.user = user
                    target.password = password
                }
                if !(sure(user) && sure(password)) { target.rootPassword = sources(["MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD"]) }
                target.database = sources(["MYSQL_DATABASE", "MARIADB_DATABASE"])
                target.defaultUser = "root"
                target.defaultDatabase = ""
            case .clickhouse:
                target.user = sources(["CLICKHOUSE_USER"])
                target.database = sources(["CLICKHOUSE_DB"])
                target.password = sources(["CLICKHOUSE_PASSWORD"])
                target.defaultUser = "default"
                target.defaultDatabase = "default"
            default:
                continue
            }
            return target
        }
        return nil
    }

    /// The ports an image serves another protocol on than the one the
    /// Database client speaks: ClickHouse's native, its TLS and its
    /// replicas' (the client speaks its HTTP, 8123); MySQL's X Protocol.
    static let otherProtocolPorts: [DatabaseKind: Set<Int>] = [.clickhouse: [9000, 9440, 9009], .mysql: [33060]]

    /// The forward's remote end: the image's own port when it is declared
    /// or nothing is; else the one port declared — unless that is one the
    /// image serves another protocol on, which the client doesn't speak.
    static func port(_ kind: DatabaseKind, inside: Int, declared: [Int]) -> Int {
        guard declared.count == 1, declared[0] != inside, !(otherProtocolPorts[kind] ?? []).contains(declared[0]) else { return inside }
        return declared[0]
    }

    /// The database client of an image the Database client doesn't speak
    /// (Redis, Mongo…), for saying why `d` can't: nil when none is.
    static func otherClient(_ pod: [String: Any]) -> DockerClient.Kind? {
        for container in containers(of: pod) {
            if let image = container["image"] as? String, let kind = DockerClient.kind(of: image), kind.database == nil { return kind }
        }
        return nil
    }

    private static func containers(of pod: [String: Any]) -> [[String: Any]] {
        (pod["spec"] as? [String: Any])?["containers"] as? [[String: Any]] ?? []
    }

    /// A container's env by name, as Kubernetes merges it: `envFrom`'s
    /// Secrets give every key they hold (under their prefix) — named here
    /// for the names a database image reads, each only if the Secret holds
    /// it (`secretIfHeld`: which keys it has isn't known without reading
    /// it) — and `env` wins over them.
    /// Values are kept as the spec has them; nothing is fetched.
    static func env(of container: [String: Any]) -> [String: KubeEnvValue] {
        var env: [String: KubeEnvValue] = [:]
        let wanted = allNames
        for source in container["envFrom"] as? [[String: Any]] ?? [] {
            let prefix = source["prefix"] as? String ?? ""
            // A ConfigMap's keys aren't read: a name one may give stays unknown.
            guard let secret = (source["secretRef"] as? [String: Any])?["name"] as? String else { continue }
            for name in wanted where name.hasPrefix(prefix) && name.count > prefix.count {
                env[name] = .secretIfHeld(name: secret, key: String(name.dropFirst(prefix.count)))
            }
        }
        for entry in container["env"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            if let value = entry["value"] as? String {
                env[name] = value.isEmpty ? nil : .literal(value)
            } else if let ref = (entry["valueFrom"] as? [String: Any])?["secretKeyRef"] as? [String: Any], let secret = ref["name"] as? String,
                let key = ref["key"] as? String
            {
                env[name] = .secret(name: secret, key: key)
            } else if entry["valueFrom"] != nil {
                env[name] = .elsewhere
            } else {
                env[name] = nil
            }
        }
        return env
    }

    private static let allNames = [
        "POSTGRES_USER", "POSTGRESQL_USERNAME", "POSTGRESQL_USER", "POSTGRES_DB", "POSTGRESQL_DATABASE", "POSTGRES_DATABASE", "POSTGRES_PASSWORD",
        "POSTGRESQL_PASSWORD", "MYSQL_USER", "MARIADB_USER", "MYSQL_PASSWORD", "MARIADB_PASSWORD", "MYSQL_ROOT_PASSWORD", "MARIADB_ROOT_PASSWORD",
        "MYSQL_DATABASE", "MARIADB_DATABASE", "CLICKHOUSE_USER", "CLICKHOUSE_DB", "CLICKHOUSE_PASSWORD",
    ]

    /// The keys of a Secret read on the user's ask that `wanted` names, as
    /// text: every other value of the answer is left with it, to go when
    /// the caller drops it. A value that isn't text is none.
    static func take(_ read: KubeSecretRead, keys wanted: [String]) -> [String: String] {
        var taken: [String: String] = [:]
        for key in wanted {
            guard let value = read.values[key], KubeSecret.isText(value) else { continue }
            taken[key] = String(decoding: value, as: UTF8.self)
        }
        return taken
    }

    /// A field's value from its sources and what was read: `given` when
    /// one names it — its value nil while unknown (a Secret not read, a
    /// ConfigMap's key) or, without `literal`, written in the spec. An
    /// envFrom Secret's key the Secret, read, doesn't hold gives way to the
    /// next source.
    static func resolve(_ sources: [KubeEnvValue], _ read: KubeSecretValues, literal: Bool = true) -> (given: Bool, value: String?) {
        for source in sources {
            switch source {
            case .literal(let text): return (true, literal ? text : nil)
            case .secret(let name, let key): return (true, read.values["\(name)/\(key)"])
            case .secretIfHeld(let name, let key):
                if let value = read.values["\(name)/\(key)"] { return (true, value) }
                if read.read.contains(name) { continue }
                return (true, nil)
            case .elsewhere: return (true, nil)
            }
        }
        return (false, nil)
    }

    /// The Database client's connection to the pod through its forward:
    /// 127.0.0.1 and the forward's local port, the user and database the
    /// env writes — or what `read` holds of the Secrets the user agreed
    /// to read — and the password only from `read`: one written in the
    /// spec is left for the user to type, and none is ever put anywhere
    /// but the form, which keeps it in the keychain if saved. MySQL's
    /// app user only with its password, else root with root's.
    static func connection(
        _ target: KubeDatabaseTarget, pod: String, context: String, namespace: String, localPort: Int, read: KubeSecretValues = KubeSecretValues()
    ) -> DockerDatabaseGuess.Guess {
        var user = resolve(target.user, read)
        var password = resolve(target.password, read, literal: false)
        if target.kind == .mysql, !(user.given && password.given) {
            user = (false, nil)
            password = resolve(target.rootPassword, read, literal: false)
        }
        var connection = DatabaseConnection(name: "\(pod) · \(context)/\(namespace)", kind: target.kind)
        connection.host = KubeForwardAddress.loopback
        connection.port = localPort
        connection.user = user.value ?? target.defaultUser
        connection.database = resolve(target.database, read).value ?? target.defaultDatabase ?? connection.user
        // Through kubectl's forward to the pod: whether the server speaks
        // TLS is its own — asked for, not required.
        connection.sslMode = .prefer
        return DockerDatabaseGuess.Guess(connection: connection, password: password.value)
    }
}

extension KubeResourceKind {
    static let secrets = KubeResourceKind(
        group: "", version: "v1", resource: "secrets", kind: "Secret", singular: "secret", namespaced: true,
        verbs: ["create", "delete", "deletecollection", "get", "list", "patch", "update", "watch"])
}

extension KubeObjectRef {
    /// An Ingress: `o` opens where it is reached, in the default browser.
    var isIngress: Bool { kind.kind == "Ingress" && ["networking.k8s.io", "extensions"].contains(kind.group) }
}
