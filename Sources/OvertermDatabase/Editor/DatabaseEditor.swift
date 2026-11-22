import AppKit

extension EditorBuffer {
    /// A `.sql` file: the console under it (connection, results).
    package var sqlConsole: SQLConsole? {
        get { consolePart as? SQLConsole }
        set { consolePart = newValue }
    }
}

extension SQLConsole: EditorConsole {
    package func unsavedEdits() -> Int { unsavedEdits(in: nil) }

    package static func askDiscardRowEdits(_ edits: Int, on window: NSWindow) async -> Bool {
        await EditorViewController.askDiscardRowEdits(edits, on: window)
    }
}

/// The SQL console's part in the editor, set once (`OvertermFeatures`).
package enum DatabaseEditor {
    package static func install() {
        EditorViewController.hooksStorage.attach.append { editor, buffer in editor.attachConsole(buffer) }
        EditorViewController.hooksStorage.show.append { editor, buffer in editor.showConsole(buffer) }
        // ⌘↩ in a console runs, as DataGrip's does.
        EditorViewController.hooksStorage.command.append { editor, id, buffer in
            id == "editor.insertLineBelow" && buffer.sqlConsole?.connection != nil ? editor.runConsoleStatement() : nil
        }
        EditorViewController.hooksStorage.typed.append { editor, buffer, text in
            guard buffer.sqlConsole?.session?.isOpen == true else { return false }
            if text.count == 1, text == "." || text.unicodeScalars.allSatisfy({ EditorViewController.isWordUnit(unichar(min($0.value, 0xFFFF))) }),
                editor.updateSQLCompletion()
            {
                return true
            }
            editor.dismissCompletion()
            return true
        }
        EditorViewController.hooksStorage.refilter.append { editor, state in
            guard state.isSQL else { return false }
            if !editor.updateSQLCompletion() { editor.dismissCompletion() }
            return true
        }
    }
}
