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
                    newConnection: { Self.onNewDatabaseConnection?() })
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
