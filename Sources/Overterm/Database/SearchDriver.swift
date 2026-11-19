import Foundation

/// Elasticsearch and OpenSearch over their REST API — one driver, as the
/// two share it: a base URL (TLS or not, a path behind a proxy, an SSH
/// tunnel's local end), Basic auth with a user, an API key or a bearer
/// token without one, and AWS's SigV4 for a managed OpenSearch signed by an
/// AWS profile.
///
/// A console's request is Kibana Dev Tools': `GET /orders/_search` and its
/// JSON body (`SearchText`, `SearchRequest`). A search's hits come back as
/// rows, `_cat`'s as rows (`format=json` added), SQL's and ES|QL's as their
/// columns, anything else as its JSON in one cell (`SearchResults`).
actor SearchDriver: DatabaseDriver {
    let config: DatabaseConnection
    private let password: String?
    private let session: URLSession
    /// What the server said it is, at connect: "Elasticsearch 8.15.0".
    private(set) var product: String?
    /// An index's fields, read once a catalog read.
    private var mappingCache: [String: [(String, String)]]?
    private var streamCache: [String: [String]]?
    private var aliasCache: [String: [String]]?

    init(_ connection: DatabaseConnection, password: String?) {
        config = connection
        self.password = password
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration, delegate: ClickHouseTrust(config: connection), delegateQueue: nil)
    }

    nonisolated var kind: DatabaseKind { config.kind }

    /// `https://host:port/base/path?query` — the path as written, its query kept.
    nonisolated func url(_ path: String) -> URL? {
        var components = URLComponents()
        components.scheme = config.sslMode == .disable || config.sslMode == .prefer ? "http" : "https"
        components.host = config.host
        components.port = config.port ?? kind.defaultPort
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let route = String(path.prefix { $0 != "?" })
        let query = path.firstIndex(of: "?").map { String(path[path.index(after: $0)...]) }
        components.percentEncodedPath = (base.isEmpty ? "" : "/" + Self.encodePath(base)) + Self.encodePath(route)
        if let query, !query.isEmpty {
            components.percentEncodedQuery = query.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? query
        }
        return components.url
    }

    /// A path's characters as they go on the wire: `*` and `,` as they are
    /// (index patterns), a space or a `#` escaped; what is escaped already kept.
    static func encodePath(_ path: String) -> String {
        if path.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil { return path }
        return path.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? path
    }

    private static let pathAllowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "*,"))
    private static let queryAllowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "%")).subtracting(CharacterSet(charactersIn: "+#"))

    /// One request, signed in, its answer's body and status.
    func send(_ request: SearchRequest) async throws -> (Data, Int) {
        guard let url = url(request.path) else { throw DatabaseError.failed("The host isn't a valid address.") }
        var http = URLRequest(url: url)
        http.httpMethod = try Self.wireMethod(request)
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = request.body.map { Data($0.utf8) }
        if let body {
            http.httpBody = body
            http.setValue(request.isNDJSON ? "application/x-ndjson" : "application/json", forHTTPHeaderField: "Content-Type")
        }
        try sign(&http, body: body ?? Data())
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: http)
        } catch let error as URLError {
            throw DatabaseError.failed(reach(error, url: url))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    /// The method sent. URLSession sends no body with a GET (it fails,
    /// "resource exceeds maximum size"): a GET with one to an API that
    /// takes POST to read the same — `_search`, `_count`… — goes as that
    /// POST; to any other it is refused rather than sent without its body.
    static func wireMethod(_ request: SearchRequest) throws -> String {
        guard request.method == "GET", request.body != nil else { return request.method }
        guard let endpoint = request.endpoint, SearchRequest.readingPosts.contains(endpoint) else {
            throw DatabaseError.failed("\(request.verb) can't carry a body from here — only the APIs that read by POST too (_search, _count, _msearch…) can.")
        }
        return "POST"
    }

    /// Why it couldn't be reached, as can be acted on.
    private func reach(_ error: URLError, url: URL) -> String {
        let at = "\(url.host ?? ""):\(url.port ?? 0)"
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .dnsLookupFailed:
            return "Couldn't reach \(kind.title) at \(at) — \(error.localizedDescription)"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
            .serverCertificateHasUnknownRoot, .clientCertificateRejected, .cancelled:
            return
                "TLS failed with \(at) — \(error.localizedDescription) A self-signed certificate (Elasticsearch's own, at first start) needs TLS “On — don't check the certificate”."
        default:
            return "\(kind.title) at \(at): \(error.localizedDescription)"
        }
    }

    /// Basic, ApiKey, Bearer — or AWS's SigV4 with a profile.
    private func sign(_ request: inout URLRequest, body: Data) throws {
        if !config.awsProfile.isEmpty {
            guard let credentials = AWSProfile.load(config.awsProfile) else {
                throw DatabaseError.failed("The AWS profile “\(config.awsProfile)” has no access key in ~/.aws/credentials.")
            }
            let host = config.serverName ?? config.host
            let region = config.location.nonEmpty ?? SearchAWS.region(host: host) ?? credentials.region ?? "us-east-1"
            let signer = S3Signer(
                accessKey: credentials.accessKey, secretKey: credentials.secretKey, sessionToken: credentials.sessionToken, region: region,
                service: SearchAWS.service(host: host))
            var headers: [String: String] = [:]
            if let type = request.value(forHTTPHeaderField: "Content-Type") { headers["content-type"] = type }
            guard let url = request.url else { return }
            for (name, value) in signer.sign(method: request.httpMethod ?? "GET", url: url, headers: headers, payloadHash: S3Signer.sha256(body), date: Date()) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            return
        }
        if let header = SearchAuth.header(user: config.user, secret: password) { request.setValue(header, forHTTPHeaderField: "Authorization") }
    }

    /// The answer's body, or the server's own words for why not.
    func checked(_ request: SearchRequest) async throws -> (Data, Int) {
        let (data, status) = try await send(request)
        switch status {
        case 200..<300: return (data, status)
        case 404 where request.method == "HEAD": return (data, status)
        case 401:
            let how = config.user.isEmpty ? "an API key (or “Bearer …”) as the password" : "user \(config.user) and its password"
            throw DatabaseError.failed("\(kind.title) refused the credentials (401) — \(how). \(SearchResults.error(data, status: status))")
        case 403 where !config.awsProfile.isEmpty:
            throw DatabaseError.failed("AWS refused the signed request (403): \(SearchResults.error(data, status: status))")
        case 403:
            throw DatabaseError.failed("Not allowed (403): \(SearchResults.error(data, status: status))")
        default:
            throw DatabaseError.failed(SearchResults.error(data, status: status))
        }
    }

    func json(_ path: String) async throws -> Any {
        let (data, _) = try await checked(SearchRequest(method: "GET", path: path, body: nil))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func connect() async throws {
        // AWS's Serverless has no root; its indices answer.
        if SearchAWS.service(host: config.serverName ?? config.host) == "aoss" {
            _ = try await checked(SearchRequest(method: "GET", path: "/_cat/indices?format=json", body: nil))
            product = "OpenSearch Serverless"
            return
        }
        let root = try await json("/") as? [String: Any] ?? [:]
        let version = root["version"] as? [String: Any] ?? [:]
        let distribution = (version["distribution"] as? String)?.lowercased()
        let name = distribution == "opensearch" ? "OpenSearch" : "Elasticsearch"
        product = "\(name) \(version["number"] as? String ?? "")".trimmingCharacters(in: .whitespaces)
    }

    func close() async { session.invalidateAndCancel() }

    func execute(_ text: String, limit: Int) async throws -> QueryResult {
        var request = try SearchRequest.parse(text)
        guard !config.readOnly || request.onlyReads else { throw DatabaseError.readOnly(request.verb) }
        // `_cat`'s text table as rows: its JSON, unless a format is asked for.
        if request.endpoint == "_cat", !request.path.contains("format=") {
            request.path += request.path.contains("?") ? "&format=json" : "?format=json"
        }
        let started = Date()
        let (data, status) = try await checked(request)
        var result = SearchResults.result(data, request: request, status: status, limit: limit)
        result.duration = Date().timeIntervalSince(started)
        if !request.onlyReads {
            mappingCache = nil
            streamCache = nil
            aliasCache = nil
        }
        return result
    }

    // MARK: The catalog

    /// Indices, data streams, aliases — the folders that have any.
    func schemas() async throws -> [String] {
        var out = [SearchCatalog.indices]
        if let streams = try? await streams(), !streams.isEmpty { out.append(SearchCatalog.dataStreams) }
        if let aliases = try? await aliases(), !aliases.isEmpty { out.append(SearchCatalog.aliases) }
        return out
    }

    /// A folder's names, each with its documents counted.
    func tables(in schema: String) async throws -> [CatalogTable] {
        switch schema {
        case SearchCatalog.dataStreams:
            return try await streams().keys.sorted().map { CatalogTable(schema: schema, name: $0, isView: false, detail: "data stream") }
        case SearchCatalog.aliases:
            return try await aliases().sorted { $0.key < $1.key }.map {
                CatalogTable(schema: schema, name: $0.key, isView: true, detail: $0.value.count == 1 ? $0.value[0] : "\($0.value.count) indices")
            }
        default:
            let rows = try await json("/_cat/indices?format=json&h=index,docs.count,health,status&s=index") as? [[String: Any]] ?? []
            return rows.compactMap { row in
                guard let name = row["index"] as? String, !SearchCatalog.isHidden(name) else { return nil }
                let closed = row["status"] as? String == "close"
                return CatalogTable(schema: schema, name: name, detail: closed ? "closed" : SearchCatalog.docs(row["docs.count"] as? String))
            }
        }
    }

    /// Every field of the folder's indices: an index's mapping, a data
    /// stream's newest backing index's, an alias's first index's.
    func columns(in schema: String) async throws -> [CatalogColumn] {
        let mappings = try await mappings()
        func columns(_ name: String, from index: String?) -> [CatalogColumn] {
            guard let index, let fields = mappings[index] else { return [] }
            return fields.map { CatalogColumn(table: name, name: $0.0, type: $0.1) }
        }
        switch schema {
        case SearchCatalog.dataStreams:
            return try await streams().sorted { $0.key < $1.key }.flatMap { columns($0.key, from: $0.value.last) }
        case SearchCatalog.aliases:
            return try await aliases().sorted { $0.key < $1.key }.flatMap { columns($0.key, from: $0.value.first) }
        default:
            return mappings.keys.filter { !SearchCatalog.isHidden($0) }.sorted().flatMap { columns($0, from: $0) }
        }
    }

    private func mappings() async throws -> [String: [(String, String)]] {
        if let mappingCache { return mappingCache }
        // Hidden too: a data stream's backing indices are.
        let (data, _) = try await checked(SearchRequest(method: "GET", path: "/_mapping?expand_wildcards=open,hidden", body: nil))
        let found = SearchCatalog.mappings(data)
        mappingCache = found
        return found
    }

    /// Data streams, each its backing indices, oldest first.
    private func streams() async throws -> [String: [String]] {
        if let streamCache { return streamCache }
        let object = try await json("/_data_stream") as? [String: Any] ?? [:]
        var found: [String: [String]] = [:]
        for stream in object["data_streams"] as? [[String: Any]] ?? [] {
            guard let name = stream["name"] as? String, !SearchCatalog.isHidden(name) else { continue }
            found[name] = (stream["indices"] as? [[String: Any]] ?? []).compactMap { $0["index_name"] as? String }
        }
        streamCache = found
        return found
    }

    /// Aliases, each the indices behind it.
    private func aliases() async throws -> [String: [String]] {
        if let aliasCache { return aliasCache }
        let rows = try await json("/_cat/aliases?format=json&h=alias,index") as? [[String: Any]] ?? []
        var found: [String: [String]] = [:]
        for row in rows {
            guard let alias = row["alias"] as? String, let index = row["index"] as? String, !SearchCatalog.isHidden(alias) else { continue }
            found[alias, default: []].append(index)
        }
        aliasCache = found
        return found
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
