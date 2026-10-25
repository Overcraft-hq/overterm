import Foundation
import Security

/// The databases the client speaks.
enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres, mysql, sqlite, redshift, clickhouse, bigquery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        case .redshift: "Amazon Redshift"
        case .clickhouse: "ClickHouse"
        case .bigquery: "BigQuery"
        }
    }

    /// Its port when nobody says otherwise; nil for those with no server.
    var defaultPort: Int? {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .redshift: 5439
        // ClickHouse's HTTP interface; 8443 with TLS.
        case .clickhouse: 8123
        case .sqlite, .bigquery: nil
        }
    }

    /// A host, a port, a user and a password — every kind but SQLite's file
    /// and BigQuery's project.
    var usesServer: Bool { self != .sqlite && self != .bigquery }

    /// The schema a new connection starts on.
    var defaultSchema: String? {
        switch self {
        case .postgres, .redshift: "public"
        default: nil
        }
    }
}

/// TLS, as libpq names the choices.
enum DatabaseSSLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disable, prefer, require, verifyFull = "verify-full"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disable: "Disable"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyFull: "Verify Full"
        }
    }
}

/// How BigQuery is signed in to.
enum BigQueryAuth: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A service account's JSON key, kept in the keychain.
    case serviceAccount
    /// Whoever `gcloud auth login` signed in on this Mac.
    case gcloud

    var id: String { rawValue }
    var title: String { self == .gcloud ? "gcloud on this Mac" : "Service account" }
}

/// One saved connection. What it says is kept in Overterm's own folder
/// (`DatabaseStore`); its password or service account key is not — that is
/// in the keychain, found by the connection's id.
struct DatabaseConnection: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: DatabaseKind
    var host = "localhost"
    var port: Int?
    var user = ""
    /// The database to connect to (ClickHouse's default database too).
    var database = ""
    var sslMode = DatabaseSSLMode.prefer
    /// SQLite's file.
    var filePath = ""
    /// BigQuery's project, the location its jobs run in, how it signs in.
    var project = ""
    var location = ""
    var bigQueryAuth = BigQueryAuth.serviceAccount
    /// Only reads: anything that would write is refused before it is sent.
    var readOnly = false

    init(name: String, kind: DatabaseKind) {
        self.name = name
        self.kind = kind
        port = kind.defaultPort
        if kind == .bigquery { bigQueryAuth = .gcloud }
    }

    /// Where it is, for its row and its tooltip.
    var summary: String {
        switch kind {
        case .sqlite: (filePath as NSString).abbreviatingWithTildeInPath
        case .bigquery: project.isEmpty ? "No project" : project
        default:
            "\(user.isEmpty ? "" : user + "@")\(host)\(port.map { ":\($0)" } ?? "")\(database.isEmpty ? "" : "/" + database)"
        }
    }

    /// What it can't be saved without, said plainly; nil when it can.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A name, please." }
        switch kind {
        case .sqlite: return filePath.isEmpty ? "Choose the database file." : nil
        case .bigquery: return project.isEmpty ? "The project, please." : nil
        default:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { return "The host, please." }
            if let port, !(1...65535).contains(port) { return "The port is 1 to 65535." }
            return nil
        }
    }
}

/// A connection's secret: its password, or BigQuery's service account key.
enum DatabaseSecretKind: String, Sendable {
    case password, serviceAccount
}

/// Where secrets live — never in the connections' file.
@MainActor
protocol DatabaseSecrets: AnyObject {
    func value(_ kind: DatabaseSecretKind, for id: UUID) -> String?
    func set(_ value: String?, _ kind: DatabaseSecretKind, for id: UUID)
}

/// The login keychain: one item a connection and secret.
@MainActor
final class KeychainDatabaseSecrets: DatabaseSecrets {
    static let service = "\(AppEnvironment.bundleIdentifier).database"

    private func match(_ kind: DatabaseSecretKind, _ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "\(id.uuidString)|\(kind.rawValue)",
        ]
    }

    func value(_ kind: DatabaseSecretKind, for id: UUID) -> String? {
        var query = match(kind, id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, _ kind: DatabaseSecretKind, for id: UUID) {
        SecItemDelete(match(kind, id) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = match(kind, id)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = kind == .password ? "Overterm database password" : "Overterm BigQuery service account"
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// For isolated runs and tests: nothing reaches the user's keychain.
@MainActor
final class MemoryDatabaseSecrets: DatabaseSecrets {
    private var values: [String: String] = [:]
    func value(_ kind: DatabaseSecretKind, for id: UUID) -> String? { values["\(id)|\(kind.rawValue)"] }
    func set(_ value: String?, _ kind: DatabaseSecretKind, for id: UUID) { values["\(id)|\(kind.rawValue)"] = value }
}

/// The saved connections: `connections.json` in Overterm's folder, its
/// secrets in the keychain. One for the app — every window lists the same.
@MainActor
final class DatabaseStore: ObservableObject {
    static let shared = DatabaseStore()

    @Published private(set) var connections: [DatabaseConnection] = []
    let secrets: DatabaseSecrets
    let file: URL

    init(file: URL? = nil, secrets: DatabaseSecrets? = nil) {
        self.file =
            file ?? AppEnvironment.supportDirectory.appendingPathComponent("Database", isDirectory: true).appendingPathComponent("connections.json")
        self.secrets = secrets ?? (AppEnvironment.isIsolated ? MemoryDatabaseSecrets() : KeychainDatabaseSecrets())
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: file),
            let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        connections = saved.connections
    }

    /// Adds or replaces it; `secret` (nil: leave it as it is) goes to the keychain.
    func save(_ connection: DatabaseConnection, password: String? = nil, serviceAccount: String? = nil) throws {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        if let password { secrets.set(password, .password, for: connection.id) }
        if let serviceAccount { secrets.set(serviceAccount, .serviceAccount, for: connection.id) }
        try write()
    }

    func delete(_ connection: DatabaseConnection) throws {
        connections.removeAll { $0.id == connection.id }
        secrets.set(nil, .password, for: connection.id)
        secrets.set(nil, .serviceAccount, for: connection.id)
        try write()
    }

    func connection(_ id: UUID?) -> DatabaseConnection? { connections.first { $0.id == id } }

    private struct Saved: Codable {
        var version = 1
        var connections: [DatabaseConnection]
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Saved(connections: connections)).write(to: file, options: .atomic)
    }
}
