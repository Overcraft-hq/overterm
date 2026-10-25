import AppKit
import Combine
import SwiftUI

/// A `.sql` file in the editor is a console: the connection it runs on and
/// what its statements gave back, under its text (SQLConsoleView). ⌘↩ runs
/// the statement at the caret — or the selection — as DataGrip's does.
extension EditorViewController {
    /// The window's: a new connection asked for from a console's menu.
    static var onNewDatabaseConnection: (() -> Void)?

    func attachConsole(_ buffer: EditorBuffer) {
        guard Settings.shared.databaseEnabled, let url = buffer.url, url.pathExtension.lowercased() == "sql",
            buffer.document.unavailable == nil
        else { return }
        let console = SQLConsole(file: url, model: DatabaseModel.shared)
        console.confirm = { [weak self] sql, why in await self?.confirmDestructive(sql, why: why) ?? false }
        buffer.sqlConsole = console
        if let session = console.session { Task { await session.open() } }
    }

    /// The console of the buffer showing, or none.
    func showConsole(_ buffer: EditorBuffer?) {
        guard isViewLoaded, let consoleHost else { return }
        consoleObserver = nil
        guard let console = buffer?.sqlConsole else {
            consoleHost.rootView = AnyView(EmptyView())
            consoleHeight.constant = 0
            return
        }
        consoleHost.rootView = AnyView(
            VStack(spacing: 0) {
                ConsoleDragEdge(height: { [weak self] in self?.consoleHeight.constant ?? 0 }) { [weak self] height in
                    self?.resizeConsole(to: height)
                }
                SQLConsoleView(
                    console: console, store: DatabaseModel.shared.store, theme: chrome,
                    runStatement: { [weak self] in _ = self?.runConsoleStatement() },
                    runAll: { [weak self] in self?.runConsoleAll() },
                    newConnection: { Self.onNewDatabaseConnection?() },
                    insert: { [weak self] sql in self?.insertIntoConsole(sql) })
            })
        // Results arriving make room for them; the toolbar alone is a strip.
        consoleObserver = console.$runs.map(\.isEmpty).removeDuplicates().sink { [weak self] empty in
            guard let self else { return }
            self.consoleHeight.constant = empty ? 33 : self.consoleResultsHeight
        }
    }

    private func resizeConsole(to height: CGFloat) {
        let limit = max(120, view.bounds.height - 160)
        consoleResultsHeight = min(max(height, 80), limit)
        consoleHeight.constant = consoleResultsHeight
    }

    /// A query from the history, on a line of its own at the caret's
    /// statement's end, the caret on it — ⌘↩ runs it.
    func insertIntoConsole(_ sql: String) {
        guard let buffer = active else { return }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let end = SQLText.statement(at: caret, in: text as String).map(NSMaxRange) ?? text.length
        let line = text.lineRange(for: NSRange(location: min(end, text.length), length: 0))
        let at = min(NSMaxRange(line), text.length)
        let lead = at > 0 && text.character(at: at - 1) != 0x0A ? "\n\n" : "\n"
        let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let piece = lead + statement + (statement.hasSuffix(";") ? "" : ";") + "\n"
        replaceText(of: buffer, with: text.replacingCharacters(in: NSRange(location: at, length: 0), with: piece))
        textView.setSelectedRange(NSRange(location: at + (lead as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        focus()
    }

    /// The selection, else the statement at the caret.
    @discardableResult
    func runConsoleStatement() -> Bool {
        guard let buffer = active, let console = buffer.sqlConsole else { return false }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        if selection.length > 0 {
            let picked = text.substring(with: selection)
            console.run(SQLText.statements(in: picked).map { (picked as NSString).substring(with: $0) })
        } else if let range = SQLText.statement(at: selection.location, in: text as String) {
            console.run([text.substring(with: range)])
            // The statement run, marked a moment, as DataGrip does.
            textView.showFindIndicator(for: range)
        }
        return true
    }

    func runConsoleAll() {
        guard let console = active?.sqlConsole else { return }
        let text = textView.string as NSString
        console.run(SQLText.statements(in: text as String).map(text.substring))
    }

    /// DROP, TRUNCATE, an UPDATE or DELETE with no WHERE: asked first.
    func confirmDestructive(_ sql: String, why: String) async -> Bool {
        guard let window = view.window else { return false }
        let alert = NSAlert()
        alert.messageText = "Run this statement?"
        alert.informativeText = "\(why)\n\n\(sql.prefix(400))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

/// The console's top edge: dragged, it resizes the results.
private struct ConsoleDragEdge: View {
    let height: () -> CGFloat
    let resize: (CGFloat) -> Void
    @State private var start: CGFloat?

    var body: some View {
        Color.clear
            .frame(height: 5)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if start == nil { start = height() }
                        resize((start ?? 0) - value.translation.height)
                    }
                    .onEnded { _ in start = nil })
    }
}

// MARK: Completion

extension EditorViewController {
    /// Tables, columns and keywords from the console's connection, for what
    /// the caret is writing; a schema not read yet is read, and the list
    /// comes back with it. False when there is nothing to offer.
    @discardableResult
    func updateSQLCompletion() -> Bool {
        guard let buffer = active, let console = buffer.sqlConsole, let session = console.session, session.isOpen,
            textView.selectedRanges.count == 1, textView.selectedRange().length == 0, let window = view.window
        else { return false }
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        let range = SQLText.statement(at: caret, in: text as String) ?? NSRange(location: 0, length: text.length)
        let start = min(range.location, caret)
        let before = text.substring(with: NSRange(location: start, length: caret - start))
        let statement = text.substring(with: NSRange(location: start, length: max(NSMaxRange(range), caret) - start))
        let context = SQLText.completionContext(before: before)
        let catalog = SQLCompletion.Catalog(
            schemas: session.schemas, defaultSchema: session.schema, tables: session.tables, columns: session.columns)
        let missing = SQLCompletion.missing(context, statement: statement, catalog: catalog)
        if !missing.isEmpty {
            Task { [weak self, weak buffer] in
                for schema in missing {
                    await session.loadTables(schema)
                    await session.loadColumns(schema)
                }
                guard let self, let buffer, buffer === self.active, self.textView.selectedRange().location == caret else { return }
                self.updateSQLCompletion()
            }
        }
        let prefix: String
        switch context {
        case .table(_, let typed), .qualifiedColumn(_, let typed), .any(let typed): prefix = typed
        }
        let found = SQLCompletion.candidates(context, statement: statement, catalog: catalog).prefix(200)
        guard !found.isEmpty else {
            completionPopup.hide()
            completion = nil
            return missing.isEmpty ? false : true
        }
        let candidates = found.map { candidate in
            let (badge, color): (String, NSColor) =
                switch candidate.kind {
                case .table: ("T", theme.style(for: "type")?.color ?? theme.info)
                case .view: ("V", theme.style(for: "type")?.color ?? theme.info)
                case .column: ("col", theme.style(for: "property")?.color ?? theme.info)
                case .schema: ("S", theme.style(for: "namespace")?.color ?? theme.hint)
                case .keyword: ("kw", theme.style(for: "keyword")?.color ?? theme.hint)
                }
            return CompletionState.Candidate(
                label: candidate.label, filterText: candidate.label, insertText: candidate.insert, isSnippet: false, badge: badge,
                badgeColor: color, detail: candidate.detail, edit: nil, additionalEdits: [], sortText: candidate.label, fromServer: false)
        }
        completionRequests += 1
        let anchor = caret - (prefix as NSString).length
        var state = CompletionState(anchor: anchor, requestedAt: caret, buffer: buffer, candidates: candidates, generation: completionRequests)
        state.isSQL = true
        state.shown = Array(candidates.indices)
        completion = state
        let items = candidates.map { EditorListItem(title: $0.label, detail: $0.detail, badge: $0.badge, badgeColor: $0.badgeColor, matched: []) }
        completionPopup.show(items, details: candidates.map(\.detail), at: textView.screenRect(forCharacterAt: anchor), in: window)
        return true
    }
}
