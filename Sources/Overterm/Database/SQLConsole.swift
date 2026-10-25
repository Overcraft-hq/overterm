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
                if Settings.shared.databaseConfirmDestructive, let why = SQLText.danger(of: sql), !(await confirm(sql, why)) { return }
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
        runs.removeAll { $0.id == run.id }
        if selected == run.id { selected = runs.last?.id }
    }

    var current: Run? { runs.first { $0.id == selected } ?? runs.last }
}
