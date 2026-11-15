import Foundation

/// What a state's outputs open in Overterm (analysis 2.4, "Outputs into
/// Overterm", stage 2c): a URL in the browser column, a database's host in
/// the Database client's form (its password asked there, never read from an
/// output), a URL as an API environment's variable, an EKS, GKE or AKS
/// cluster on the Kubernetes page. Only from the masked model: a sensitive
/// output, or a value masked inside one, offers nothing. Pure.
enum TerraformOutputLinks {
    enum Offer: Equatable, Hashable, Sendable {
        /// Open in Browser.
        case browser(URL)
        /// New Database Connection…: the kind guessed (the form lets it be
        /// changed), the host and port; never a user's password.
        case database(kind: DatabaseKind, host: String, port: Int?, database: String?)
        /// Add to API environment: a variable named after the output.
        case apiVariable(name: String, value: String)
        /// Open in Kubernetes: the context whose server or name is this cluster's.
        case kubernetes(Cluster)

        var title: String {
            switch self {
            case .browser: "Open in Browser"
            case .database: "New Database Connection…"
            case .apiVariable: "Add to API Environment…"
            case .kubernetes: "Open in Kubernetes"
            }
        }

        var symbol: String {
            switch self {
            case .browser: "globe"
            case .database: "cylinder"
            case .apiVariable: "paperplane"
            case .kubernetes: "server.rack"
            }
        }

        /// Its accessibility id's last part.
        var key: String {
            switch self {
            case .browser: "browser"
            case .database: "database"
            case .apiVariable: "api"
            case .kubernetes: "kubernetes"
            }
        }
    }

    /// A managed cluster an output names.
    struct Cluster: Equatable, Hashable, Sendable {
        enum Service: String, Sendable { case eks = "EKS", gke = "GKE", aks = "AKS" }
        var service: Service
        /// Its name (an EKS ARN's last part, GKE's `clusters/<name>`).
        var name: String?
        /// Its API server's host.
        var server: String?
    }

    /// What `output` offers, the first of each kind found in it (its own
    /// value, or its fields and items two deep).
    static func offers(for output: TerraformState.Output) -> [Offer] {
        guard !output.sensitive, let value = output.value else { return [] }
        var leaves: [(path: String, value: String)] = []
        var numbers: [String: Int] = [:]
        collect(value, path: output.name, depth: 0, into: &leaves, numbers: &numbers)
        var found: [Offer] = []
        func add(_ offer: Offer) {
            if !found.contains(where: { $0.key == offer.key }) { found.append(offer) }
        }
        var cluster: Cluster?
        for (path, text) in leaves {
            if let hint = clusterHint(path: path, value: text) {
                cluster = merged(cluster, hint)
            }
        }
        for (path, text) in leaves {
            if let url = webURL(text), cluster == nil || !isClusterServer(url.host ?? "") {
                add(.browser(url))
                add(.apiVariable(name: variableName(path), value: url.absoluteString))
            }
            if let database = database(path: path, value: text, siblingPort: numbers[sibling(path, "port")]) { add(database) }
        }
        if let cluster { add(.kubernetes(cluster)) }
        return found
    }

    /// The string leaves of a value, with their dotted paths; the numbers by path too (a sibling `port`).
    private static func collect(_ value: TerraformValue, path: String, depth: Int, into leaves: inout [(path: String, value: String)], numbers: inout [String: Int]) {
        guard depth <= 2, leaves.count < 64 else { return }
        switch value {
        case .string(let text): leaves.append((path, text))
        case .number(let text): if let number = Int(text) { numbers[path] = number }
        case .object(let fields):
            for key in fields.keys.sorted() { collect(fields[key]!, path: path + "." + key, depth: depth + 1, into: &leaves, numbers: &numbers) }
        case .list(let items):
            for (index, item) in items.prefix(8).enumerated() { collect(item, path: "\(path)[\(index)]", depth: depth + 1, into: &leaves, numbers: &numbers) }
        default: break
        }
    }

    private static func sibling(_ path: String, _ name: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return name }
        return String(path[..<dot]) + "." + name
    }

    /// An `http(s)` URL with a host and no user or password in it.
    static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 2048, !trimmed.contains(" "), let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, !trimmed.contains("••••")
        else { return nil }
        return components.url
    }

    /// The API environment's variable for an output's path: `api_url`,
    /// `service.endpoint` → `service_endpoint`.
    static func variableName(_ path: String) -> String {
        let mapped = path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" }
        var name = String(mapped)
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return name.isEmpty ? "terraform_output" : String(name.prefix(64))
    }

    // MARK: Databases

    /// The words that make a host's path, or the host itself, a database's.
    private static let databaseWords = ["db", "database", "rds", "postgres", "postgresql", "mysql", "mariadb", "aurora", "redshift", "clickhouse", "sql"]
    /// The words that say a value is a host to connect to.
    private static let hostWords = ["endpoint", "host", "hostname", "address", "fqdn", "url", "dsn", "connection", "writer", "reader"]

    static func database(path: String, value: String, siblingPort: Int? = nil) -> Offer? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.count <= 512, !text.contains("••••") else { return nil }
        // A URL with a database's scheme: its host, port and database, never its user's password.
        if let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(), let kind = kind(scheme: scheme),
            let host = components.host, !host.isEmpty
        {
            let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .database(kind: kind, host: host, port: components.port, database: database.isEmpty ? nil : database)
        }
        guard let (host, port) = hostAndPort(text) else { return nil }
        let words = Set(path.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let hostParts = Set(host.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let namedHost = !words.isDisjoint(with: hostWords)
        let databaseNamed = !words.isDisjoint(with: databaseWords) || !hostParts.isDisjoint(with: databaseWords)
        guard namedHost, databaseNamed else { return nil }
        let guessed = kind(words: words.union(hostParts)) ?? kind(port: port ?? siblingPort) ?? .postgres
        return .database(kind: guessed, host: host, port: port ?? siblingPort, database: nil)
    }

    /// `host` or `host:port`, a DNS name with a dot or an IPv4 address.
    static func hostAndPort(_ text: String) -> (String, Int?)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let host = String(parts[0]).lowercased()
        var port: Int?
        if parts.count == 2 {
            guard let number = Int(parts[1]), (1...65_535).contains(number) else { return nil }
            port = number
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.hasPrefix("-"), host.count <= 253,
            host.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return (host, port)
    }

    private static func kind(scheme: String) -> DatabaseKind? {
        switch scheme {
        case "postgres", "postgresql": .postgres
        case "mysql", "mariadb": .mysql
        case "redshift": .redshift
        case "clickhouse": .clickhouse
        default: nil
        }
    }

    private static func kind(words: Set<String>) -> DatabaseKind? {
        if words.contains("redshift") { return .redshift }
        if words.contains("clickhouse") { return .clickhouse }
        if !words.isDisjoint(with: ["mysql", "mariadb"]) { return .mysql }
        if !words.isDisjoint(with: ["postgres", "postgresql", "pg"]) { return .postgres }
        return nil
    }

    private static func kind(port: Int?) -> DatabaseKind? {
        switch port {
        case 5432: .postgres
        case 3306: .mysql
        case 5439: .redshift
        case 8123, 8443, 9000: .clickhouse
        default: nil
        }
    }

    // MARK: Clusters

    static func isClusterServer(_ host: String) -> Bool {
        let host = host.lowercased()
        return host.hasSuffix(".eks.amazonaws.com") || host.hasSuffix(".azmk8s.io")
    }

    /// What a value says of a managed cluster: an EKS ARN, an EKS or AKS
    /// API server, a GKE cluster's ID — or a GKE endpoint (an address) under
    /// a path that says so.
    static func clusterHint(path: String, value: String) -> Cluster? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("arn:aws:eks:"), let range = text.range(of: ":cluster/") {
            let name = String(text[range.upperBound...])
            return name.isEmpty ? nil : Cluster(service: .eks, name: name, server: nil)
        }
        if let range = text.range(of: #"^projects/[^/]+/(locations|zones)/[^/]+/clusters/[^/]+$"#, options: .regularExpression),
            let name = text[range].split(separator: "/").last
        {
            return Cluster(service: .gke, name: String(name), server: nil)
        }
        let host = URLComponents(string: text)?.host ?? (text.contains("/") ? nil : text)
        guard let host = host?.lowercased() else { return nil }
        if host.hasSuffix(".eks.amazonaws.com") { return Cluster(service: .eks, name: nil, server: host) }
        if host.hasSuffix(".azmk8s.io") { return Cluster(service: .aks, name: nil, server: host) }
        let words = Set(path.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if words.contains("gke"), words.contains("endpoint"), isIPv4(host) { return Cluster(service: .gke, name: nil, server: host) }
        return nil
    }

    private static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func merged(_ known: Cluster?, _ hint: Cluster) -> Cluster {
        guard var known else { return hint }
        if known.name == nil { known.name = hint.name }
        if known.server == nil { known.server = hint.server }
        return known
    }

    /// The kubeconfig context that is `cluster`'s: by its API server's
    /// host first, then by name — EKS's `arn:…:cluster/<name>` or a
    /// context named after it, GKE's `gke_<project>_<location>_<name>`, AKS's
    /// own name. Nil when none is.
    static func context(for cluster: Cluster, in contexts: [(name: String, cluster: String, server: String?)]) -> String? {
        if let server = cluster.server?.lowercased() {
            if let found = contexts.first(where: { ($0.server.flatMap { URLComponents(string: $0)?.host?.lowercased() }) == server }) { return found.name }
        }
        guard let name = cluster.name, !name.isEmpty else { return nil }
        let suffixes = ["/" + name, "_" + name, "@" + name]
        for candidate in contexts {
            for label in [candidate.cluster, candidate.name] where label == name || suffixes.contains(where: { label.hasSuffix($0) }) {
                return candidate.name
            }
        }
        return nil
    }

    /// What to run when no context points at it — said, never run.
    static func kubeconfigHint(for cluster: Cluster) -> String {
        let name = cluster.name ?? "<cluster>"
        switch cluster.service {
        case .eks: return "aws eks update-kubeconfig --name \(name)"
        case .gke: return "gcloud container clusters get-credentials \(name)"
        case .aks: return "az aks get-credentials --name \(name) --resource-group <group>"
        }
    }

    // MARK: The API environment

    /// An environment file's text with `name` set to `value` in its
    /// `vars { }` — added, or changed in place — every other block kept
    /// byte for byte (`BruFile`). Nil when `name` is one of its secrets.
    static func environment(_ text: String, setting name: String, to value: String) -> String? {
        var file = BruFile(parsing: text)
        guard !file.secretNames.contains(name) else { return nil }
        var variables = file.variables
        if let index = variables.firstIndex(where: { $0.key == name }) {
            variables[index].value = value
            variables[index].enabled = true
        } else {
            variables.append(BruPair(key: name, value: value))
        }
        file.variables = variables
        return file.text
    }
}
