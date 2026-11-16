import Foundation

/// A console result's rows, edited in the grid: whether they can be (one
/// table, its key among the columns), what has been changed and not saved,
/// the statements a Save runs, and the Save itself — confirmed with those
/// statements, applied in one transaction, then the rows read again.
/// Nothing runs before Save. docs/architecture.md, Database: Editing rows.
@MainActor
final class ResultEditor: ObservableObject {
    enum State: Equatable {
        case checking
        case editable(EditableResult)
        /// Why not, as the status bar says it.
        case refused(String)
    }

    let runID: UUID
    let sql: String
    private weak var console: SQLConsole?
    private let session: DatabaseSession
    @Published private(set) var state = State.checking
    @Published private(set) var edits = PendingEdits()
    @Published private(set) var saving = false
    @Published var error: String?

    init(runID: UUID, sql: String, console: SQLConsole, session: DatabaseSession) {
        self.runID = runID
        self.sql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        self.console = console
        self.session = session
    }

    var editable: EditableResult? {
        if case .editable(let result) = state { return result }
        return nil
    }

    /// The rows as they were read (the run's), in the result's order.
    var rows: [[String?]] { console?.runs.first { $0.id == runID }?.result?.rows ?? [] }
    private var resultColumns: [String] { console?.runs.first { $0.id == runID }?.result?.columns ?? [] }

    /// One table, its key, its columns matched to the result's.
    func resolve() async {
        guard let driver = session.editing else { return state = .refused("") }
        dialect = await driver.editDialect()
        // A kind of its own (a graph's nodes) says it, else the SQL way.
        if let own = await driver.editableResult(statement: sql, columns: resultColumns) {
            switch own {
            case .success(let result): state = .editable(result)
            case .failure(let refusal): state = .refused(refusal.message)
            }
            return
        }
        let query: EditableQuery
        switch EditableQuery.parse(sql) {
        case .success(let parsed): query = parsed
        case .failure(let refusal): return state = .refused(refusal.message)
        }
        do {
            guard let key = try await driver.key(of: query.table) else {
                return state = .refused(EditRefusal.noKey(query.table.name).message)
            }
            let schema = key.table.schema ?? session.schema ?? ""
            await session.loadColumns(schema)
            let columns = session.columns(of: key.table.name, in: schema).map(\.name)
            switch EditableResult.match(resultColumns: resultColumns, tableColumns: columns, key: key) {
            case .success(let result): state = .editable(result)
            case .failure(let refusal): state = .refused(refusal.message)
            }
        } catch {
            state = .refused(error.localizedDescription)
        }
    }

    // MARK: Changes

    func set(row: Int, column: Int, to value: CellValue) {
        guard let result = editable, result.isEditable(column), rows.indices.contains(row) else { return }
        edits.set(row: row, column: column, to: value, original: rows[row][safe: column] ?? nil)
    }

    func set(new index: Int, column: Int, to value: CellValue?) {
        guard let result = editable, result.isEditable(column) else { return }
        edits.set(new: index, column: column, to: value)
    }

    func addRow() {
        guard editable != nil else { return }
        edits.add()
    }

    func duplicate(_ rowIndexes: [Int]) {
        guard let result = editable else { return }
        for row in rowIndexes where rows.indices.contains(row) { edits.add(PendingEdits.duplicate(rows[row], result: result)) }
    }

    func delete(_ rowIndexes: [Int], new newIndexes: [Int] = []) {
        guard editable != nil else { return }
        edits.delete(rows: rowIndexes.filter { rows.indices.contains($0) })
        for index in newIndexes.sorted(by: >) { edits.remove(new: index) }
    }

    func revert(_ rowIndexes: [Int], new newIndexes: [Int] = []) {
        for row in rowIndexes { edits.revert(row: row) }
        for index in newIndexes.sorted(by: >) { edits.remove(new: index) }
    }

    func discard() {
        edits.discard()
        error = nil
    }

    /// What a Save would run, in order.
    func statements() async throws -> [EditStatement] {
        guard let result = editable else { return [] }
        if let driver = session.editing, let own = try await driver.editStatements(edits, rows: rows, result: result) { return own }
        return try EditStatements.make(edits, rows: rows, result: result, dialect: dialect)
    }

    private var dialect = SQLDialect.postgres

    /// The statements as the preview shows them, or why they can't be made.
    func preview() async -> String {
        if let driver = session.editing { dialect = await driver.editDialect() }
        do {
            let statements = try await statements()
            return statements.isEmpty ? "Nothing to save." : statements.map { $0.sql + ";" }.joined(separator: "\n")
        } catch let refusal as EditRefusal {
            return refusal.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Asked with every statement shown; applied together; the rows read again.
    func save() async {
        guard let driver = session.editing, let console, !edits.isEmpty, !saving else { return }
        dialect = await driver.editDialect()
        let statements: [EditStatement]
        do {
            statements = try await self.statements()
        } catch {
            self.error = (error as? EditRefusal)?.message ?? error.localizedDescription
            return
        }
        // A kind of its own names its table (a label) as it is.
        let table =
            editable.map { result in
                if case .identity = result.key.kind { return result.key.table.name }
                return dialect.qualified(result.key.table)
            } ?? ""
        var notes: [String] = []
        for note in statements.compactMap(\.note) where !notes.contains(note) { notes.append(note) }
        let confirmation = WriteConfirmation(
            title: "Save \(edits.count) change\(edits.count == 1 ? "" : "s") to \(table)?", scope: session.connection.name,
            detail: statements.map { $0.sql + ";" }.joined(separator: "\n") + notes.map { "\n\n" + $0 }.joined()
                + "\n\nIn one transaction: if any statement fails, none is kept.",
            button: "Save")
        guard await console.confirmWrite(confirmation) else { return }
        saving = true
        defer { saving = false }
        do {
            try await driver.apply(statements)
            for statement in statements { DatabaseModel.shared.record(statement.sql, on: session.connection.id, rows: statement.expectedRows, error: nil) }
            edits.discard()
            error = nil
            await console.reread(runID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
