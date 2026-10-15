import AppKit

/// The file tree's New File…, New Folder…, Rename… and Move to Trash…:
/// each asks in a sheet, then does it, and the tree and the editor follow.
extension TerminalWindowController {
    /// Asks for a name and creates an empty file (then opens it) or a folder.
    func createItem(in folder: URL, folder isFolder: Bool) {
        askForName(
            title: isFolder ? "New Folder" : "New File", detail: "In \(folder.lastPathComponent)", initial: "",
            action: "Create"
        ) { [weak self] name in
            guard let self else { return nil }
            let url = folder.appendingPathComponent(name)
            if let problem = Self.nameProblem(name, at: url) { return problem }
            do {
                if isFolder {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    // A name with folders in it ("pkg/a.go") makes them too.
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return "Couldn't create it." }
                }
            } catch {
                return error.localizedDescription
            }
            self.tree.reload()
            if !isFolder { self.openInEditor(url) }
            return nil
        }
    }

    func renameItem(_ url: URL) {
        let name = url.lastPathComponent
        askForName(title: "Rename", detail: name, initial: name, action: "Rename") { [weak self] newName in
            guard let self, newName != name else { return nil }
            let target = url.deletingLastPathComponent().appendingPathComponent(newName)
            // A change of case only is the same file to a case-insensitive disk.
            if newName.lowercased() != name.lowercased(), let problem = Self.nameProblem(newName, at: target) { return problem }
            do {
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                return error.localizedDescription
            }
            self.editor?.filesMoved(from: url, to: target)
            self.tree.reload()
            return nil
        }
    }

    /// Asks, then moves it to the Trash (so it can come back). Its tabs in
    /// the editor close — said in the question when one has unsaved edits.
    func trashItem(_ url: URL) {
        guard let window else { return }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let path = url.standardizedFileURL.path
        let unsaved =
            editor?.buffers.filter {
                guard let open = $0.url?.standardizedFileURL.path, $0.document.isDirty else { return false }
                return open == path || open.hasPrefix(path + "/")
            }.map(\.name) ?? []
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        var detail = isFolder ? "The folder and everything in it." : "You can put it back from the Trash."
        if !unsaved.isEmpty { detail += " Unsaved changes to \(unsaved.joined(separator: ", ")) will be lost." }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }
            self.editor?.filesRemoved(at: url)
            self.tree.reload()
        }
    }

    /// Why `name` can't be used, or nil.
    nonisolated static func nameProblem(_ name: String, at url: URL) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A name, please." }
        if trimmed.hasPrefix("/") || trimmed.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) {
            return "The name can't leave this folder."
        }
        if FileManager.default.fileExists(atPath: url.path) { return "“\(trimmed)” is already there." }
        return nil
    }

    /// A sheet with a name field. `submit` answers nil when done, or why not
    /// — the sheet stays up with that said, the field as typed.
    private func askForName(title: String, detail: String, initial: String, action: String, submit: @escaping (String) -> String?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.identifier = NSUserInterfaceItemIdentifier("fileNameField")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // The name without its extension selected, as Finder does.
        if let dot = initial.lastIndex(of: "."), dot != initial.startIndex {
            field.currentEditor()?.selectedRange = NSRange(initial.startIndex..<dot, in: initial)
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let problem = submit(name) {
                // Again, with what was wrong.
                self.askForName(title: title, detail: problem, initial: name, action: action, submit: submit)
            }
        }
    }
}
