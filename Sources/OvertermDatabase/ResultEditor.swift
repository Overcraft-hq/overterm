import Foundation

/// A console result's rows, edited in the grid: whether they can be (one
/// table, its key among the columns), what has been changed and not saved,
/// the statements a Save runs, and the Save itself — confirmed with those
/// statements, applied in one transaction, then the rows read again.
/// Nothing runs before Save. docs/architecture.md, Database: Editing rows.
@MainActor
package final class ResultEditor: ObservableObject {
    package enum State: Equatable {
        case checking
        case editable(EditableResult)
        /// Why not, as the status bar says it.
        case refused(String)
    }

    package let runID: UUID
    package let sql: String
    private weak var console: SQLConsole?
    private let session: DatabaseSession
    @Published package private(set) var state = State.checking
    @Published package private(set) var edits = PendingEdits()
    @Published package private(set) var saving = false
    @Published package var error: String?

    package init(runID: UUID, sql: String, console: SQLConsole, session: DatabaseSession) {
        self.runID = runID
        self.sql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        self.console = console
        self.session = session
    }

    package var editable: EditableResult? {
        if case .editable(let result) = state { return result }
        return nil
    }

    /// The rows as they were read (the run's), in the result's order.
    package var rows: [[String?]] { console?.runs.first { $0.id == runID }?.result?.rows ?? [] }
    private var resultColumns: [String] { console?.runs.first { $0.id == runID }?.result?.columns ?? [] }
    private var result: QueryResult? { console?.runs.first { $0.id == runID }?.result }

    /// One table, its key, its columns matched to the result's — or, a kind
    /// whose rows are documents or items, as its driver finds them.
    package func resolve() async {
        guard let driver = session.editing else { return state = .refused("") }
        if let result {
            do {
                switch try await driver.editableResult(for: sql, result: result) {
                case .success(let editable)?: return state = .editable(editable)
                case .failure(let refusal)?: return state = .refused(refusal.message)
                case nil: break
                }
            } catch {
                return state = .refused(error.localizedDescription)
            }
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

    package func set(row: Int, column: Int, to value: CellValue) {
        guard let result = editable, result.isUpdatable(column), rows.indices.contains(row) else { return }
        edits.set(row: row, column: column, to: value, original: rows[row][safe: column] ?? nil)
    }

    package func set(new index: Int, column: Int, to value: CellValue?) {
        guard let result = editable, result.isEditable(column) else { return }
        edits.set(new: index, column: column, to: value)
    }

    package func addRow() {
        guard editable != nil else { return }
        edits.add()
    }

    package func duplicate(_ rowIndexes: [Int]) {
        guard let result = editable else { return }
        for row in rowIndexes where rows.indices.contains(row) { edits.add(PendingEdits.duplicate(rows[row], result: result)) }
    }

    package func delete(_ rowIndexes: [Int], new newIndexes: [Int] = []) {
        guard editable != nil else { return }
        edits.delete(rows: rowIndexes.filter { rows.indices.contains($0) })
        for index in newIndexes.sorted(by: >) { edits.remove(new: index) }
    }

    package func revert(_ rowIndexes: [Int], new newIndexes: [Int] = []) {
        for row in rowIndexes { edits.revert(row: row) }
        for index in newIndexes.sorted(by: >) { edits.remove(new: index) }
    }

    package func discard() {
        edits.discard()
        error = nil
    }

    /// What a Save would run, in order, in the engine's own words.
    package func statements() async throws -> [EditStatement] {
        guard let result = editable, let driver = session.editing else { return [] }
        return try await driver.editStatements(edits, rows: rows, result: result)
    }

    /// The statements as the preview shows them, or why they can't be made.
    package func preview() async -> String {
        do {
            let statements = try await statements()
            return statements.isEmpty ? "Nothing to save." : EditStatement.listing(statements)
        } catch let refusal as EditRefusal {
            return refusal.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Asked with every statement shown; applied together; the rows read again.
    package func save() async {
        guard let driver = session.editing, let console, !edits.isEmpty, !saving else { return }
        let statements: [EditStatement]
        do {
            statements = try await self.statements()
        } catch {
            self.error = (error as? EditRefusal)?.message ?? error.localizedDescription
            return
        }
        // A kind of its own (a label, a collection) names its table as it is:
        // its database, then its name.
        var table = ""
        if let key = editable?.key {
            if case .identity = key.kind {
                table = [key.table.schema, key.table.name].compactMap { $0 }.joined(separator: ".")
            } else {
                table = await driver.editDialect().qualified(key.table)
            }
        }
        // Each statement's own note (a node's relationships go too) once,
        // then how they run together.
        var notes: [String] = []
        for note in statements.compactMap(\.note) where !notes.contains(note) { notes.append(note) }
        let note = await driver.editSaveNote()
        let confirmation = WriteConfirmation(
            title: "Save \(edits.count) change\(edits.count == 1 ? "" : "s") to \(table)?", scope: session.connection.name,
            detail: EditStatement.listing(statements) + notes.map { "\n\n" + $0 }.joined() + "\n\n" + note,
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
