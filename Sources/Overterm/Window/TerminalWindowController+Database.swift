import AppKit
import SwiftUI

/// The database client: the sidebar's panel over the saved connections, a
/// connection's console in the editor, and the sheet that makes one.
extension TerminalWindowController {
    var databaseActions: DatabaseActions {
        DatabaseActions(
            edit: { [weak self] connection, kind in self?.editDatabaseConnection(connection, kind: kind) },
            delete: { [weak self] in self?.deleteDatabaseConnection($0) },
            console: { [weak self] in self?.openDatabaseConsole($0) },
            run: { [weak self] connection, sql in self?.runInDatabaseConsole(connection, sql) }
        )
    }

    func wireDatabase() {
        EditorViewController.onNewDatabaseConnection = { [weak self] in self?.editDatabaseConnection(nil, kind: nil) }
    }

    /// View ▸ Database (⌥⌘B): the sidebar, on the database panel.
    @objc func showDatabase(_ sender: Any?) {
        guard Settings.shared.databaseEnabled else { return }
        if sidebarItem?.isCollapsed == true { toggleFileTree(nil) }
        sidebarPanel.panel = .database
    }

    func databaseSettingsChanged() {
        if !Settings.shared.databaseEnabled, sidebarPanel.panel == .database { sidebarPanel.panel = .files }
        // The rail lists its icons from the setting: drawn again.
        sidebarPanel.objectWillChange.send()
    }

    /// New Connection… (with a kind picked) and Edit Connection…, in a sheet.
    func editDatabaseConnection(_ connection: DatabaseConnection?, kind: DatabaseKind?) {
        let model = DatabaseModel.shared
        let start = connection ?? DatabaseConnection(name: kind?.title ?? "PostgreSQL", kind: kind ?? .postgres)
        presentSheet { close in
            DatabaseConnectionForm(connection: start, isNew: connection == nil, store: model.store) { saved in
                close()
                guard let saved else { return }
                // Edited: the open session was the old connection's.
                if connection != nil { model.disconnect(saved) }
                model.expanded.insert(saved.id.uuidString)
                Task { await model.session(saved).open() }
            }
        }
    }

    func deleteDatabaseConnection(_ connection: DatabaseConnection) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(connection.name)”?"
        alert.informativeText = "Its saved password or key goes from the keychain too. Its console file stays."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                do {
                    try DatabaseModel.shared.delete(connection)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    /// The connection's console, in the editor.
    func openDatabaseConsole(_ connection: DatabaseConnection, then done: ((EditorViewController) -> Void)? = nil) {
        let url = DatabaseModel.shared.console(for: connection)
        openInEditor(url)
        guard let editor else { return }
        editor.open(url) { opened in
            guard opened else { return }
            // Its console runs on this connection, whatever it ran on before.
            if editor.active?.sqlConsole?.connection?.id != connection.id { editor.active?.sqlConsole?.use(connection) }
            done?(editor)
        }
    }

    /// A query from the panel (Select Top 100): written at the end of the
    /// console and run there, so it stays with what else was run.
    func runInDatabaseConsole(_ connection: DatabaseConnection, _ sql: String) {
        openDatabaseConsole(connection) { editor in
            guard let buffer = editor.active, let console = buffer.sqlConsole else { return }
            let text = buffer.storage.string
            let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
            editor.replaceText(of: buffer, with: text + separator + sql + "\n")
            // The caret at the query's start — ⌘↩ runs it again — and the
            // console saved, as DataGrip keeps its consoles.
            let start = (text as NSString).length + (separator as NSString).length
            editor.textView.setSelectedRange(NSRange(location: start, length: 0))
            editor.textView.scrollRangeToVisible(NSRange(location: start, length: 0))
            editor.save(buffer, overwriting: false)
            console.run([sql])
        }
    }
}
