import AppKit
import Combine
import Foundation

/// A `.sql` file in the editor, as a console: the connection it runs on, and
/// what its statements gave back — one tab a statement, as DataGrip shows.
/// The text stays the file's; this is what sits under it.
@MainActor
package final class SQLConsole: ObservableObject {
    package struct Run: Identifiable {
        package let id = UUID()
        package var sql: String
        package var result: QueryResult?
        package var error: String?
        package var running = false
    }

    package let file: URL
    private let model: DatabaseModel
    @Published package private(set) var connection: DatabaseConnection?
    @Published package private(set) var runs: [Run] = []
    @Published package var selected: UUID?
    @Published package private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var sessionChanges: AnyCancellable?
    /// Asked before a statement that destroys: true to send it.
    package var confirm: (_ sql: String, _ why: String) async -> Bool = { _, _ in true }
    /// Asked before a Save of edited rows, its statements shown: true to run them.
    package var confirmWrite: (WriteConfirmation) async -> Bool = { _ in false }
    /// Asked before rows edited and not saved are lost (a result's tab or
    /// the console closed): true to discard them.
    package var confirmDiscard: (_ edits: Int) async -> Bool = { _ in true }
    /// Each run's rows as edited (`ResultEditor`), made when its grid first shows.
    private var editors: [UUID: ResultEditor] = [:]

    /// Row edits not saved, in a run or in all of them — never kept on
    /// disk, so closing loses them (CLAUDE.md: closing always asks).
    package func unsavedEdits(in run: Run? = nil) -> Int {
        editors.filter { id, editor in (run == nil || id == run?.id) && !editor.saving }.values.reduce(0) { $0 + $1.edits.count }
    }

    package init(file: URL, model: DatabaseModel) {
        self.file = file
        self.model = model
        connection = model.connection(for: file)
        observeSession()
    }

    package var session: DatabaseSession? { connection.map(model.session) }

    package func use(_ connection: DatabaseConnection?) {
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
    package func run(_ statements: [String]) {
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
            // The oldest go past ten — never one with row edits not saved.
            while runs.count > 10, let old = runs.firstIndex(where: { unsavedEdits(in: $0) == 0 }) {
                editors[runs[old].id] = nil
                runs.remove(at: old)
            }
            if !runs.contains(where: { $0.id == selected }) { selected = runs.last?.id }
        }
    }

    /// Stops waiting for the statement; the database may finish it anyway.
    package func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        for index in runs.indices where runs[index].running {
            runs[index].running = false
            runs[index].error = "Stopped."
        }
    }

    /// Every run's row edits dropped (its file closing, asked first).
    package func discardAllEdits() {
        for editor in editors.values { editor.discard() }
    }

    /// A result's tab closed — asked first when its rows have edits not saved.
    package func requestClose(_ run: Run) {
        let edits = unsavedEdits(in: run)
        guard edits > 0 else { return close(run) }
        Task { @MainActor in
            if await confirmDiscard(edits) { close(run) }
        }
    }

    package func close(_ run: Run) {
        if live == run.id { stopFollowing() }
        editors[run.id] = nil
        runs.removeAll { $0.id == run.id }
        if selected == run.id { selected = runs.last?.id }
    }

    package var current: Run? { runs.first { $0.id == selected } ?? runs.last }

    // MARK: Editing rows

    /// A run's editor — when its connection edits rows and the run has rows;
    /// whether these rows can be is its own to say (`ResultEditor.state`).
    package func editor(for run: Run) -> ResultEditor? {
        guard let session, session.editing != nil, let result = run.result, result.hasRows, result.payload == nil, !run.running else { return nil }
        if let editor = editors[run.id] { return editor }
        let editor = ResultEditor(runID: run.id, sql: run.sql, console: self, session: session)
        editors[run.id] = editor
        // Runs gone take their editors with them.
        editors = editors.filter { id, _ in runs.contains { $0.id == id } }
        Task { await editor.resolve() }
        return editor
    }

    /// A run's statement again, its rows replacing the old ones — after a
    /// Save. Not recorded in the history: the statement was, when first run.
    package func reread(_ id: UUID) async {
        guard let session, let at = runs.firstIndex(where: { $0.id == id }) else { return }
        let sql = runs[at].sql
        await session.run([sql], limit: Settings.shared.databaseRowLimit) { [weak self] _, outcome in
            guard let self, let at = self.runs.firstIndex(where: { $0.id == id }) else { return }
            switch outcome {
            case .success(let result): self.runs[at].result = result
            case .failure(let error): self.runs[at].error = error.localizedDescription
            }
        }
    }

    // MARK: Live (Loki)

    /// The run whose lines are followed: new ones polled every two seconds
    /// and put on top, as `logcli --tail` shows them.
    @Published package private(set) var live: UUID?
    private var liveTask: Task<Void, Never>?
    /// Lines a live run keeps; the oldest go.
    package static let liveKeep = 5000

    package func follow(_ run: Run) {
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

    package func stopFollowing() {
        liveTask?.cancel()
        liveTask = nil
        live = nil
    }
}
