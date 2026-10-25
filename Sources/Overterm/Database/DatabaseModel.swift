import Foundation

/// One connection, open: its driver, what it is doing, and its catalog as
/// far as it has been read — schemas at once, a schema's tables and columns
/// when the tree or completion first asks for them.
@MainActor
final class DatabaseSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case closed, connecting, open
        case failed(String)
    }

    let connection: DatabaseConnection
    nonisolated var id: UUID { connection.id }
    private var driver: (any DatabaseDriver)?
    private let secrets: DatabaseSecrets

    @Published private(set) var state = State.closed
    @Published private(set) var schemas: [String] = []
    @Published private(set) var tables: [String: [CatalogTable]] = [:]
    @Published private(set) var columns: [String: [CatalogColumn]] = [:]
    /// The schema completion and unqualified names are about.
    @Published var schema: String?
    @Published private(set) var isRunning = false
    private var loadingColumns: Set<String> = []
    private var opening: Task<Void, Never>?
    private var running: Task<Void, Never>?

    init(_ connection: DatabaseConnection, secrets: DatabaseSecrets) {
        self.connection = connection
        self.secrets = secrets
    }

    var isOpen: Bool { state == .open }

    /// Opens it — or, while it is opening, waits for that: a statement run
    /// the moment a console picked the connection was dropped silently.
    func open() async {
        if let opening {
            await opening.value
            return
        }
        guard state != .open else { return }
        let task = Task { await connect() }
        opening = task
        await task.value
        opening = nil
    }

    private func connect() async {
        state = .connecting
        let driver = DatabaseDrivers.make(
            connection, password: secrets.value(.password, for: connection.id),
            serviceAccount: secrets.value(.serviceAccount, for: connection.id))
        do {
            try await driver.connect()
            self.driver = driver
            state = .open
            schemas = (try? await driver.schemas()) ?? []
            schema = schema ?? Self.startingSchema(connection, schemas: schemas)
        } catch {
            await driver.close()
            state = .failed(error.localizedDescription)
        }
    }

    /// The schema a connection starts on: public, its database, else the first.
    static func startingSchema(_ connection: DatabaseConnection, schemas: [String]) -> String? {
        if let preferred = connection.kind.defaultSchema, schemas.contains(preferred) { return preferred }
        if !connection.database.isEmpty, schemas.contains(connection.database) { return connection.database }
        if connection.kind == .sqlite { return "main" }
        return schemas.first
    }

    func close() async {
        running?.cancel()
        await driver?.close()
        driver = nil
        state = .closed
        schemas = []
        tables = [:]
        columns = [:]
    }

    func reloadCatalog() async {
        guard let driver else { return }
        tables = [:]
        columns = [:]
        schemas = (try? await driver.schemas()) ?? schemas
    }

    func loadTables(_ schema: String) async {
        guard let driver, tables[schema] == nil else { return }
        tables[schema] = (try? await driver.tables(in: schema)) ?? []
    }

    /// Every column of a schema, once: the tree's and completion's.
    func loadColumns(_ schema: String) async {
        guard let driver, columns[schema] == nil, !loadingColumns.contains(schema) else { return }
        loadingColumns.insert(schema)
        defer { loadingColumns.remove(schema) }
        columns[schema] = (try? await driver.columns(in: schema)) ?? []
    }

    func columns(of table: String, in schema: String) -> [CatalogColumn] {
        columns[schema]?.filter { $0.table.caseInsensitiveCompare(table) == .orderedSame } ?? []
    }

    // MARK: Running

    /// The statements in order — each one's result, or where it stopped.
    /// A read-only connection refuses a write before it is sent.
    func run(_ statements: [String], limit: Int, onResult: @escaping (Int, Result<QueryResult, Error>) -> Void) async {
        if state != .open { await open() }
        guard let driver, state == .open else {
            if case .failed(let message) = state { onResult(0, .failure(DatabaseError.failed(message))) }
            return
        }
        isRunning = true
        defer { isRunning = false }
        for (index, sql) in statements.enumerated() {
            if Task.isCancelled { break }
            if connection.readOnly, !SQLText.onlyReads(sql) {
                onResult(index, .failure(DatabaseError.readOnly(SQLText.verb(of: sql))))
                break
            }
            do {
                let result = try await driver.execute(sql, limit: limit)
                onResult(index, .success(result))
            } catch {
                onResult(index, .failure(error))
                break
            }
        }
        // A statement may have made or dropped a table: the catalog is read again.
        if statements.contains(where: { !SQLText.onlyReads($0) }) {
            tables = [:]
            columns = [:]
        }
    }
}

/// The client's state for the app: the saved connections (DatabaseStore),
/// the ones open, and the history of what was run.
@MainActor
final class DatabaseModel: ObservableObject {
    static let shared = DatabaseModel()

    let store: DatabaseStore
    // Not published: a session is made the first time the panel draws its row.
    private(set) var sessions: [UUID: DatabaseSession] = [:]
    /// Storage connections' sessions, as `sessions` for the databases.
    var storageSessions: [UUID: StorageSession] = [:]
    /// Open folders of the tree: connection ids, `id/schema`, `id/schema/table`.
    @Published var expanded: Set<String> = []
    @Published var filter = ""
    @Published private(set) var history: [HistoryItem] = []

    struct HistoryItem: Codable, Equatable, Identifiable {
        var id = UUID()
        var connection: UUID
        var sql: String
        var date: Date
        var rows: Int?
        var error: String?
    }

    init(store: DatabaseStore? = nil) {
        self.store = store ?? DatabaseStore.shared
        history = Self.loadHistory()
    }

    func session(_ connection: DatabaseConnection) -> DatabaseSession {
        if let session = sessions[connection.id], session.connection == connection { return session }
        // A connection edited since: the old session goes.
        if let stale = sessions[connection.id] { Task { await stale.close() } }
        let session = DatabaseSession(connection, secrets: store.secrets)
        sessions[connection.id] = session
        return session
    }

    func session(id: UUID?) -> DatabaseSession? {
        store.connection(id).map(session)
    }

    func disconnect(_ connection: DatabaseConnection) {
        if let storage = storageSessions.removeValue(forKey: connection.id) { storage.close() }
        expanded = expanded.filter { !$0.hasPrefix(connection.id.uuidString) }
        guard let session = sessions[connection.id] else { return }
        Task { await session.close() }
        expanded = expanded.filter { !$0.hasPrefix(connection.id.uuidString) }
    }

    func delete(_ connection: DatabaseConnection) throws {
        disconnect(connection)
        sessions[connection.id] = nil
        try store.delete(connection)
    }

    // MARK: History

    private static var historyFile: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("Database", isDirectory: true).appendingPathComponent("history.json")
    }

    private static func loadHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }

    func record(_ sql: String, on connection: UUID, rows: Int?, error: String?) {
        history.insert(HistoryItem(connection: connection, sql: sql, date: Date(), rows: rows, error: error), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        let items = history
        try? FileManager.default.createDirectory(at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: Self.historyFile, options: .atomic)
    }

    // MARK: Consoles

    /// A connection's console: a `.sql` file of its own in Overterm's folder,
    /// opened in the editor and kept between launches, as DataGrip's are.
    func console(for connection: DatabaseConnection) -> URL {
        let folder = AppEnvironment.supportDirectory.appendingPathComponent("Database/Consoles", isDirectory: true)
        let safe = connection.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(safe) — \(connection.id.uuidString.prefix(8)).sql")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        attach(url, to: connection.id)
        return url
    }

    /// Which connection a `.sql` file runs on: remembered by its path.
    private static let attachmentsKey = "databaseFileConnections"

    func attach(_ file: URL, to connection: UUID?) {
        var map = AppEnvironment.defaults.dictionary(forKey: Self.attachmentsKey) as? [String: String] ?? [:]
        map[file.standardizedFileURL.path] = connection?.uuidString
        AppEnvironment.defaults.set(map, forKey: Self.attachmentsKey)
        objectWillChange.send()
    }

    func connection(for file: URL) -> DatabaseConnection? {
        let map = AppEnvironment.defaults.dictionary(forKey: Self.attachmentsKey) as? [String: String] ?? [:]
        return map[file.standardizedFileURL.path].flatMap(UUID.init(uuidString:)).flatMap(store.connection)
    }
}
