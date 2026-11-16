import Foundation

/// A console language a kind has of its own — DynamoDB's PartiQL, InfluxDB's
/// InfluxQL/Flux/SQL and line protocol, Neo4j's Cypher: where its statements
/// are and what each one does. `DatabaseKind`'s `statements`, `verb`,
/// `onlyReads`, `agentReads`, `danger` and `subject` ask it first
/// (`consoleText`), so every console, history and agent path follows it.
/// Pure.
protocol KindConsoleText {
    static func statements(in text: String) -> [NSRange]
    static func verb(of statement: String) -> String
    /// Refused on a read-only connection unless it only reads.
    static func onlyReads(_ statement: String) -> Bool
    /// What an agent may run without asking — as strict or stricter.
    static func agentReads(_ statement: String) -> Bool
    static func danger(of statement: String) -> String?
    static func subject(of statement: String) -> String?
}

extension KindConsoleText {
    /// The statement the caret is in — or, between two, the one it just left.
    static func statement(at caret: Int, in text: String) -> NSRange? {
        let all = statements(in: text)
        if let inside = all.first(where: { caret >= $0.location && caret <= NSMaxRange($0) }) { return inside }
        return all.last { NSMaxRange($0) <= caret } ?? all.first
    }
}

extension DatabaseKind {
    /// Its own console language; nil for SQL, Redis and the observability kinds.
    var consoleText: KindConsoleText.Type? {
        switch self {
        case .dynamodb: DynamoText.self
        case .influxdb: InfluxText.self
        case .neo4j: CypherText.self
        default: nil
        }
    }

    /// What the panel's "Select Top" runs for a table of a kind that isn't
    /// SQL — nil for those that are.
    static func browseStatement(_ connection: DatabaseConnection, table: CatalogTable, limit: Int) -> String? {
        switch connection.kind {
        case .dynamodb: DynamoText.browse(table.name)
        case .influxdb: InfluxText.browse(table, connection: connection, limit: limit)
        case .neo4j: CypherText.browse(table, connection: connection, limit: limit)
        default: nil
        }
    }
}

/// The HTTP the drivers over a REST API share (DynamoDB, InfluxDB, Neo4j):
/// the base URL a connection makes — TLS as its mode says, checked as
/// `ClickHouseTrust` does — and a failure to reach it said in plain words.
struct HTTPDriverTransport: Sendable {
    let config: DatabaseConnection
    let session: URLSession

    init(_ connection: DatabaseConnection, timeout: TimeInterval = 120) {
        config = connection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: ClickHouseTrust(config: connection), delegateQueue: nil)
    }

    /// https unless TLS is off (Prefer is plain: none of these negotiate).
    var tls: Bool { config.sslMode == .require || config.sslMode == .verifyFull }

    /// `scheme://host:port/base/path?query`.
    func url(_ path: String, _ query: [(String, String)] = []) -> URL? {
        var components = URLComponents()
        components.scheme = tls ? "https" : "http"
        components.host = config.host.trimmingCharacters(in: .whitespaces)
        components.port = config.port ?? (tls && config.kind == .dynamodb ? nil : config.kind.defaultPort)
        let base = config.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        components.path = (base.isEmpty ? "" : "/" + base) + path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        // `+` is a space to a form decoder: a query's `a + b` must arrive as one.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// The request sent; a failure to reach the server said as one.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DatabaseError.failed("\(config.kind.title) gave no HTTP answer.") }
            return (data, http)
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw Self.unreachable(error, kind: config.kind, url: request.url)
        }
    }

    func close() { session.invalidateAndCancel() }

    /// Why it couldn't be reached, in words: nobody there, no such host,
    /// TLS where the server speaks none (or a certificate refused).
    static func unreachable(_ error: Error, kind: DatabaseKind, url: URL?) -> DatabaseError {
        let place = "\(url?.host ?? "")\(url?.port.map { ":\($0)" } ?? "")"
        guard let code = (error as? URLError)?.code else {
            return .failed("Couldn't reach \(kind.title) at \(place): \(error.localizedDescription)")
        }
        switch code {
        case .cannotConnectToHost, .networkConnectionLost:
            return .failed("Nothing answers at \(place) — is \(kind.title) running, and on that port?")
        case .cannotFindHost, .dnsLookupFailed:
            return .failed("There's no host \(url?.host ?? "") — check the name.")
        case .timedOut:
            return .failed("\(kind.title) at \(place) didn't answer in time.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected:
            return .failed(
                "TLS failed with \(place): \(error.localizedDescription) — turn TLS off for a server that speaks plain HTTP, or don't verify a self-signed certificate."
            )
        case .cancelled:
            return .failed("Cancelled.")
        default:
            return .failed("Couldn't reach \(kind.title) at \(place): \(error.localizedDescription)")
        }
    }

    /// A JSON value as the grid shows it: strings bare, booleans as words,
    /// numbers as written, the rest as compact JSON with sorted keys.
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        switch value {
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }
    }

    /// A string as a JSON literal.
    static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\(text)\""
    }

    /// What the server said when it refused: a JSON `message`/`error`, else its text.
    static func said(_ data: Data, status: Int, kind: DatabaseKind) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "Message", "error", "err"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
            }
        }
        let text = String(decoding: data.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\(kind.title) answered \(status)." : text
    }
}
