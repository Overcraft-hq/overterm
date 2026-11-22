import Foundation

/// One connection, open: its driver, what it is doing, and its catalog as
/// far as it has been read — schemas at once, a schema's tables and columns
/// when the tree or completion first asks for them.
@MainActor
package final class DatabaseSession: ObservableObject, Identifiable {
    package enum State: Equatable {
        case closed, connecting, open
        case failed(String)
    }

    package let connection: DatabaseConnection
    package nonisolated var id: UUID { connection.id }
    private var driver: (any DatabaseDriver)?
    private var tunnel: SSHTunnel?
    private let secrets: DatabaseSecrets

    @Published package private(set) var state = State.closed
    @Published package private(set) var schemas: [String] = []
    @Published package private(set) var tables: [String: [CatalogTable]] = [:]
    @Published package private(set) var columns: [String: [CatalogColumn]] = [:]
    /// The schema completion and unqualified names are about.
    @Published package var schema: String?
    @Published package private(set) var isRunning = false
    /// The window Prometheus's, Loki's and Tempo's queries look at — every
    /// console of the connection's.
    @Published package var range = TimeRange.h1
    private var loadingColumns: Set<String> = []
    /// A Redis connection's key browsers, by database.
    private var browsers: [Int: RedisBrowser] = [:]
    private var catalog: ObservabilityCatalog?
    private var opening: Task<Void, Never>?
    private var running: Task<Void, Never>?

    package init(_ connection: DatabaseConnection, secrets: DatabaseSecrets) {
        self.connection = connection
        self.secrets = secrets
    }

    package var isOpen: Bool { state == .open }

    /// The driver as Redis: the browser, a key's page and the server's
    /// speak commands, not statements.
    package var redis: RedisDriver? { driver as? RedisDriver }

    /// The driver as Prometheus, Loki or Tempo: the tree's labels and tags,
    /// a trace, the live tail.
    package var observability: ObservabilityDriver? { driver as? ObservabilityDriver }

    /// The Server page's reads — the driver's own connection, nothing else.
    package var monitoring: (any DatabaseMonitoring)? {
        connection.kind.features.contains(.monitoring) ? driver as? any DatabaseMonitoring : nil
    }

    /// A result's rows edited — never on a read-only connection.
    package var editing: (any DatabaseTableEditing)? {
        !connection.readOnly && connection.kind.features.contains(.editing) ? driver as? any DatabaseTableEditing : nil
    }

    /// The Users page's reads and writes (the writes refused on a read-only connection).
    package var userManagement: (any DatabaseUserManagement)? {
        connection.kind.features.contains(.users) ? driver as? any DatabaseUserManagement : nil
    }

    /// A Prometheus, Loki or Tempo connection's names and values.
    package func observabilityCatalog() -> ObservabilityCatalog {
        if let catalog { return catalog }
        let made = ObservabilityCatalog(session: self)
        catalog = made
        return made
    }

    package func browser(_ db: Int) -> RedisBrowser {
        if let browser = browsers[db] { return browser }
        let browser = RedisBrowser(db: db, session: self)
        browsers[db] = browser
        return browser
    }

    /// Opens it — or, while it is opening, waits for that: a statement run
    /// the moment a console picked the connection was dropped silently.
    package func open() async {
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

    /// A failure to connect, as it can be acted on. A server that wants a
    /// password nobody gave says only `authMechanismRequiresPassword`; why
    /// there was none — none saved, or the keychain wouldn't hand it over —
    /// is ours to say.
    package static func explain(_ error: Error, passwordGiven: Bool, readProblem: String?) -> String {
        let said = error.localizedDescription
        let asksForOne = String(describing: error).contains("authMechanismRequiresPassword") || said.contains("authMechanismRequiresPassword")
        guard asksForOne, !passwordGiven else { return said }
        if let readProblem { return "The server asks for a password, and the saved one couldn't be read. \(readProblem)" }
        return "The server asks for a password, and none is saved for this connection — Edit Connection… to enter it."
    }

    private func connect() async {
        state = .connecting
        let driver: any DatabaseDriver
        let password = secrets.value(.password, for: connection.id)
        do {
            let opened = try await DatabaseDrivers.open(
                connection, password: password,
                serviceAccount: secrets.value(.serviceAccount, for: connection.id), sshSecret: secrets.value(.ssh, for: connection.id))
            driver = opened.driver
            tunnel = opened.tunnel
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        do {
            try await driver.connect()
            self.driver = driver
            state = .open
            schemas = (try? await driver.schemas()) ?? []
            schema = schema ?? Self.startingSchema(connection, schemas: schemas)
        } catch {
            await driver.close()
            tunnel?.close()
            tunnel = nil
            state = .failed(
                Self.explain(error, passwordGiven: password != nil, readProblem: secrets.readProblem(.password, for: connection.id)))
        }
    }

    /// The schema a connection starts on: public, its database, else the first.
    package static func startingSchema(_ connection: DatabaseConnection, schemas: [String]) -> String? {
        if connection.kind.isRedis { return "db\(RedisDriver.database(connection.database))" }
        if let preferred = connection.kind.defaultSchema, schemas.contains(preferred) { return preferred }
        if !connection.database.isEmpty, schemas.contains(connection.database) { return connection.database }
        if connection.kind == .sqlite { return "main" }
        return schemas.first
    }

    package func close() async {
        running?.cancel()
        await driver?.close()
        driver = nil
        tunnel?.close()
        tunnel = nil
        state = .closed
        browsers = [:]
        catalog = nil
        schemas = []
        tables = [:]
        columns = [:]
    }

    package func reloadCatalog() async {
        guard let driver else { return }
        tables = [:]
        columns = [:]
        schemas = (try? await driver.schemas()) ?? schemas
    }

    package func loadTables(_ schema: String) async {
        guard let driver, tables[schema] == nil else { return }
        tables[schema] = (try? await driver.tables(in: schema)) ?? []
    }

    /// Every column of a schema, once: the tree's and completion's.
    package func loadColumns(_ schema: String) async {
        guard let driver, columns[schema] == nil, !loadingColumns.contains(schema) else { return }
        loadingColumns.insert(schema)
        defer { loadingColumns.remove(schema) }
        columns[schema] = (try? await driver.columns(in: schema)) ?? []
    }

    package func columns(of table: String, in schema: String) -> [CatalogColumn] {
        columns[schema]?.filter { $0.table.caseInsensitiveCompare(table) == .orderedSame } ?? []
    }

    // MARK: Running

    /// The statements in order — each one's result, or where it stopped.
    /// A read-only connection refuses a write before it is sent.
    package func run(_ statements: [String], limit: Int, onResult: @escaping (Int, Result<QueryResult, Error>) -> Void) async {
        if state != .open { await open() }
        guard let driver, state == .open else {
            if case .failed(let message) = state { onResult(0, .failure(DatabaseError.failed(message))) }
            return
        }
        isRunning = true
        defer { isRunning = false }
        for (index, sql) in statements.enumerated() {
            if Task.isCancelled { break }
            if connection.readOnly, !connection.kind.onlyReads(sql) {
                onResult(index, .failure(DatabaseError.readOnly(connection.kind.verb(of: sql))))
                break
            }
            do {
                let result = try await driver.execute(sql, limit: limit, range: range)
                onResult(index, .success(result))
            } catch {
                onResult(index, .failure(error))
                break
            }
        }
        // A statement may have made or dropped a table: the catalog is read again.
        if statements.contains(where: { !connection.kind.onlyReads($0) }) {
            tables = [:]
            columns = [:]
        }
    }
}

/// The client's state for the app: the saved connections (DatabaseStore),
/// the ones open, and the history of what was run.
@MainActor
package final class DatabaseModel: ObservableObject {
    package static let shared = DatabaseModel()

    package let store: DatabaseStore
    // Not published: a session is made the first time the panel draws its row.
    package private(set) var sessions: [UUID: DatabaseSession] = [:]
    /// Storage connections' sessions, as `sessions` for the databases.
    package var storageSessions: [UUID: StorageSession] = [:]
    /// Open folders of the tree: connection ids, `id/schema`, `id/schema/table`.
    @Published package var expanded: Set<String> = []
    @Published package var filter = ""
    @Published package private(set) var history: [HistoryItem] = []
    /// Queries kept by name, a connection's under it in the panel.
    @Published package private(set) var saved: [SavedQuery] = []

    package struct SavedQuery: Codable, Equatable, Identifiable {
        package var id = UUID()
        package var connection: UUID
        package var name: String
        package var text: String
        package var date = Date()
    }

    package struct HistoryItem: Codable, Equatable, Identifiable {
        package var id = UUID()
        package var connection: UUID
        package var sql: String
        package var date: Date
        package var rows: Int?
        package var error: String?
    }

    package init(store: DatabaseStore? = nil) {
        self.store = store ?? DatabaseStore.shared
        history = Self.loadHistory()
        saved = Self.loadSaved()
    }

    package func session(_ connection: DatabaseConnection) -> DatabaseSession {
        if let session = sessions[connection.id], session.connection == connection { return session }
        // A connection edited since: the old session goes.
        if let stale = sessions[connection.id] { Task { await stale.close() } }
        let session = DatabaseSession(connection, secrets: store.secrets)
        sessions[connection.id] = session
        return session
    }

    package func session(id: UUID?) -> DatabaseSession? {
        store.connection(id).map(session)
    }

    package func disconnect(_ connection: DatabaseConnection) {
        if let storage = storageSessions.removeValue(forKey: connection.id) { storage.close() }
        expanded = expanded.filter { !$0.hasPrefix(connection.id.uuidString) }
        guard let session = sessions[connection.id] else { return }
        Task { await session.close() }
        expanded = expanded.filter { !$0.hasPrefix(connection.id.uuidString) }
    }

    package func delete(_ connection: DatabaseConnection) throws {
        disconnect(connection)
        sessions[connection.id] = nil
        try store.delete(connection)
        // Its saved queries go with it: nothing else can run them.
        if saved.contains(where: { $0.connection == connection.id }) {
            saved.removeAll { $0.connection == connection.id }
            writeSaved()
        }
    }

    // MARK: History

    private static var historyFile: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("Database", isDirectory: true).appendingPathComponent("history.json")
    }

    private static func loadHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }

    package func record(_ sql: String, on connection: UUID, rows: Int?, error: String?) {
        history.insert(HistoryItem(connection: connection, sql: sql, date: Date(), rows: rows, error: error), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        let items = history
        try? FileManager.default.createDirectory(at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: Self.historyFile, options: .atomic)
    }

    // MARK: Saved queries

    private static var savedFile: URL {
        AppEnvironment.supportDirectory.appendingPathComponent("Database", isDirectory: true).appendingPathComponent("saved.json")
    }

    private static func loadSaved() -> [SavedQuery] {
        guard let data = try? Data(contentsOf: savedFile) else { return [] }
        return (try? JSONDecoder().decode([SavedQuery].self, from: data)) ?? []
    }

    private func writeSaved() {
        try? FileManager.default.createDirectory(at: Self.savedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.savedFile, options: .atomic)
    }

    /// A connection's, by name.
    package func saved(for connection: UUID) -> [SavedQuery] {
        saved.filter { $0.connection == connection }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Kept under the name; one of the same name on the connection is replaced.
    @discardableResult
    package func save(_ name: String, text: String, on connection: UUID) -> SavedQuery {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let at = saved.firstIndex(where: { $0.connection == connection && $0.name == name }) {
            saved[at].text = text
            saved[at].date = Date()
            writeSaved()
            return saved[at]
        }
        let query = SavedQuery(connection: connection, name: name, text: text)
        saved.append(query)
        writeSaved()
        return query
    }

    package func rename(_ query: SavedQuery, to name: String) {
        guard let at = saved.firstIndex(where: { $0.id == query.id }) else { return }
        saved[at].name = name.trimmingCharacters(in: .whitespaces)
        writeSaved()
    }

    package func remove(_ query: SavedQuery) {
        saved.removeAll { $0.id == query.id }
        writeSaved()
    }

    // MARK: Consoles

    /// A connection's console: a `.sql` file of its own in Overterm's folder,
    /// opened in the editor and kept between launches, as DataGrip's are.
    package func console(for connection: DatabaseConnection) -> URL {
        let folder = AppEnvironment.supportDirectory.appendingPathComponent("Database/Consoles", isDirectory: true)
        let safe = connection.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(safe) — \(connection.id.uuidString.prefix(8)).sql")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data((connection.kind.consoleText?.help ?? "").utf8).write(to: url)
        }
        attach(url, to: connection.id)
        return url
    }

    /// Which connection a `.sql` file runs on: remembered by its path.
    private static let attachmentsKey = "databaseFileConnections"

    package func attach(_ file: URL, to connection: UUID?) {
        var map = AppEnvironment.defaults.dictionary(forKey: Self.attachmentsKey) as? [String: String] ?? [:]
        map[file.standardizedFileURL.path] = connection?.uuidString
        AppEnvironment.defaults.set(map, forKey: Self.attachmentsKey)
        objectWillChange.send()
    }

    package func connection(for file: URL) -> DatabaseConnection? {
        let map = AppEnvironment.defaults.dictionary(forKey: Self.attachmentsKey) as? [String: String] ?? [:]
        return map[file.standardizedFileURL.path].flatMap(UUID.init(uuidString:)).flatMap(store.connection)
    }
}
