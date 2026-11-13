import AppKit
import Combine
import Foundation

/// A `.sql` file in the editor, as a console: the connection it runs on, and
/// what its statements gave back — one tab a statement, as DataGrip shows.
/// The text stays the file's; this is what sits under it.
@MainActor
final class SQLConsole: ObservableObject {
    struct Run: Identifiable {
        let id = UUID()
        var sql: String
        var result: QueryResult?
        var error: String?
        var running = false
    }

    let file: URL
    private let model: DatabaseModel
    @Published private(set) var connection: DatabaseConnection?
    @Published private(set) var runs: [Run] = []
    @Published var selected: UUID?
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var sessionChanges: AnyCancellable?
    /// Asked before a statement that destroys: true to send it.
    var confirm: (_ sql: String, _ why: String) async -> Bool = { _, _ in true }

    init(file: URL, model: DatabaseModel) {
        self.file = file
        self.model = model
        connection = model.connection(for: file)
        observeSession()
    }

    var session: DatabaseSession? { connection.map(model.session) }

    func use(_ connection: DatabaseConnection?) {
        self.connection = connection
        model.attach(file, to: connection?.id)
        observeSession()
        if let session { Task { await session.open() } }
    }

    /// The session's catalog and state redraw the toolbar.
    private func observeSession() {
        sessionChanges = session?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The statements in order, each a tab. A destroying one is asked about
    /// first (Settings ▸ Database); a read-only connection refuses a write.
    func run(_ statements: [String]) {
        guard let session, !statements.isEmpty, !isRunning else { return }
        task = Task { @MainActor in
            for sql in statements {
                if Settings.shared.databaseConfirmDestructive, let why = session.connection.kind.danger(of: sql), !(await confirm(sql, why)) {
                    return
                }
            }
            isRunning = true
            defer { isRunning = false }
            let first = runs.count
            runs += statements.map { Run(sql: $0, running: true) }
            selected = runs[first].id
            // Old tabs go: the last ten runs are kept.
            await session.run(statements, limit: Settings.shared.databaseRowLimit) { [weak self] index, outcome in
                guard let self else { return }
                let at = first + index
                guard self.runs.indices.contains(at) else { return }
                self.runs[at].running = false
                switch outcome {
                case .success(let result):
                    self.runs[at].result = result
                    self.model.record(statements[index], on: session.connection.id, rows: result.hasRows ? result.rows.count : result.affected, error: nil)
                    if result.hasRows { self.selected = self.runs[at].id }
                case .failure(let error):
                    self.runs[at].error = error.localizedDescription
                    self.selected = self.runs[at].id
                    self.model.record(statements[index], on: session.connection.id, rows: nil, error: error.localizedDescription)
                }
            }
            // Statements not reached (one before failed): their tabs go.
            runs.removeAll { $0.running }
            if runs.count > 10 { runs.removeFirst(runs.count - 10) }
            if !runs.contains(where: { $0.id == selected }) { selected = runs.last?.id }
        }
    }

    /// Stops waiting for the statement; the database may finish it anyway.
    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        for index in runs.indices where runs[index].running {
            runs[index].running = false
            runs[index].error = "Stopped."
        }
    }

    func close(_ run: Run) {
        if live == run.id { stopFollowing() }
        runs.removeAll { $0.id == run.id }
        if selected == run.id { selected = runs.last?.id }
    }

    var current: Run? { runs.first { $0.id == selected } ?? runs.last }

    // MARK: Live (Loki)

    /// The run whose lines are followed: new ones polled every two seconds
    /// and put on top, as `logcli --tail` shows them.
    @Published private(set) var live: UUID?
    private var liveTask: Task<Void, Never>?
    /// Lines a live run keeps; the oldest go.
    static let liveKeep = 5000

    func follow(_ run: Run) {
        stopFollowing()
        guard let driver = session?.observability, case .logs(let lines)? = run.result?.payload else { return }
        live = run.id
        let id = run.id
        let query = run.sql
        var after = lines.map(\.nanos).max() ?? Int64(Date().timeIntervalSince1970 * 1e9)
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                do {
                    let new = try await driver.tail(query, after: after, limit: 1000)
                    guard let self, self.live == id, let at = self.runs.firstIndex(where: { $0.id == id }) else { return }
                    guard !new.isEmpty else { continue }
                    after = new.map(\.nanos).max() ?? after
                    var all = ObservabilityParse.ordered(new)
                    if case .logs(let old)? = self.runs[at].result?.payload { all += old }
                    if all.count > Self.liveKeep { all.removeLast(all.count - Self.liveKeep) }
                    var result = ObservabilityRows.result(.logs(all), limit: Self.liveKeep)
                    result.duration = self.runs[at].result?.duration ?? 0
                    self.runs[at].result = result
                } catch {
                    guard let self, let at = self.runs.firstIndex(where: { $0.id == id }) else { return }
                    self.runs[at].error = error.localizedDescription
                    self.stopFollowing()
                    return
                }
            }
        }
    }

    func stopFollowing() {
        liveTask?.cancel()
        liveTask = nil
        live = nil
    }
}
