import Foundation
import Security

/// The databases the client speaks — and the object stores it browses.
enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres, mysql, sqlite, redshift, clickhouse, bigquery
    /// Buckets and their files: S3 and everything that speaks it (Spaces,
    /// MinIO, R2, B2, Wasabi, GCS's interoperability), and GCS's own API.
    case s3, gcs

    /// Files, not tables: its tree is buckets and folders, no console.
    var isStorage: Bool { self == .s3 || self == .gcs }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        case .redshift: "Amazon Redshift"
        case .clickhouse: "ClickHouse"
        case .bigquery: "BigQuery"
        case .s3: "S3-Compatible Storage"
        case .gcs: "Google Cloud Storage"
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
        case .sqlite, .bigquery, .s3, .gcs: nil
        }
    }

    /// A host, a port, a user and a password — the SQL servers.
    var usesServer: Bool { [.postgres, .mysql, .redshift, .clickhouse].contains(self) }

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
    /// S3: whose it is (its endpoint and addressing), bucket names in the
    /// path rather than the host (MinIO), and credentials from an AWS CLI
    /// profile instead of a key in the keychain.
    var provider = StorageProvider.aws
    var pathStyle = false
    var awsProfile = ""

    init(name: String, kind: DatabaseKind) {
        self.name = name
        self.kind = kind
        port = kind.defaultPort
        if kind == .bigquery || kind == .gcs { bigQueryAuth = .gcloud }
        if kind == .s3 { apply(.aws) }
    }

    /// A provider's endpoint, region and addressing, as a starting point.
    mutating func apply(_ provider: StorageProvider) {
        self.provider = provider
        host = provider.endpoint(region: provider.defaultRegion)
        location = provider.defaultRegion
        pathStyle = provider.pathStyle
        port = provider == .minio ? 9000 : nil
        sslMode = provider == .minio ? .disable : .require
    }

    // Read field by field: a file written before a field existed still
    // opens (a missing field takes its default) — every connection kept.
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, user, database, sslMode, filePath, project, location, bigQueryAuth, readOnly, provider,
            pathStyle, awsProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(DatabaseKind.self, forKey: .kind)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        sslMode = try c.decodeIfPresent(DatabaseSSLMode.self, forKey: .sslMode) ?? .prefer
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        bigQueryAuth = try c.decodeIfPresent(BigQueryAuth.self, forKey: .bigQueryAuth) ?? .serviceAccount
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        provider = try c.decodeIfPresent(StorageProvider.self, forKey: .provider) ?? .aws
        pathStyle = try c.decodeIfPresent(Bool.self, forKey: .pathStyle) ?? false
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile) ?? ""
    }

    /// Where it is, for its row and its tooltip.
    var summary: String {
        switch kind {
        case .sqlite: (filePath as NSString).abbreviatingWithTildeInPath
        case .bigquery, .gcs: project.isEmpty ? "No project" : project
        case .s3: provider == .aws ? "AWS \(location)" : host
        default:
            "\(user.isEmpty ? "" : user + "@")\(host)\(port.map { ":\($0)" } ?? "")\(database.isEmpty ? "" : "/" + database)"
        }
    }

    /// What it can't be saved without, said plainly; nil when it can.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "A name, please." }
        switch kind {
        case .sqlite: return filePath.isEmpty ? "Choose the database file." : nil
        case .bigquery, .gcs: return project.isEmpty ? "The project, please." : nil
        case .s3:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { return "The endpoint, please." }
            if awsProfile.isEmpty, user.isEmpty { return "The access key, or an AWS profile." }
            return nil
        default:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { return "The host, please." }
            if let port, !(1...65535).contains(port) { return "The port is 1 to 65535." }
            return nil
        }
    }
}

/// Whose S3 it is: the endpoint a region makes, and how buckets are named.
enum StorageProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case aws, digitalocean, minio, r2, backblaze, wasabi, gcs, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aws: "Amazon S3"
        case .digitalocean: "DigitalOcean Spaces"
        case .minio: "MinIO"
        case .r2: "Cloudflare R2"
        case .backblaze: "Backblaze B2"
        case .wasabi: "Wasabi"
        case .gcs: "Google Cloud Storage (HMAC)"
        case .custom: "Other S3-compatible"
        }
    }

    var defaultRegion: String {
        switch self {
        case .aws: "us-east-1"
        case .digitalocean: "nyc3"
        case .backblaze: "us-west-004"
        case .wasabi: "us-east-1"
        case .r2, .gcs: "auto"
        case .minio, .custom: "us-east-1"
        }
    }

    /// Its endpoint in a region; R2's needs the account's id in place of
    /// `ACCOUNT_ID`.
    func endpoint(region: String) -> String {
        switch self {
        case .aws: "s3.\(region).amazonaws.com"
        case .digitalocean: "\(region).digitaloceanspaces.com"
        case .minio: "localhost"
        case .r2: "ACCOUNT_ID.r2.cloudflarestorage.com"
        case .backblaze: "s3.\(region).backblazeb2.com"
        case .wasabi: "s3.\(region).wasabisys.com"
        case .gcs: "storage.googleapis.com"
        case .custom: ""
        }
    }

    /// Bucket names in the path (`host/bucket/key`) rather than the host.
    var pathStyle: Bool { self == .minio || self == .custom || self == .r2 }
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
