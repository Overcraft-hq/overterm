import AppKit

/// A Bruno request file in the editor: shown as a request (APIRequestView)
/// over its text, every edit made there written into the text — so it is
/// saved, undone and reloaded like any file.
extension EditorViewController {
    /// A `.bru` request gets its model; collection.bru, folder.bru and
    /// environments are shown as text, being settings rather than requests.
    func attachRequest(_ buffer: EditorBuffer) {
        guard let url = buffer.url, url.pathExtension == "bru", buffer.document.unavailable == nil else { return }
        let model = APIRequestModel(url: url, text: buffer.storage.string, workspace: apiWorkspace)
        guard model.file.isRequest else { return }
        model.onEdit = { [weak self, weak buffer] text in
            guard let self, let buffer else { return }
            self.replaceText(of: buffer, with: text)
        }
        buffer.request = model
        buffer.showsPreview = true
    }

    /// Replaces what changed between the buffer's text and `text` — only
    /// that range, through the text view when the buffer is the one showing,
    /// so undo, the dirty mark and the git gutter see an ordinary edit.
    func replaceText(of buffer: EditorBuffer, with text: String) {
        let old = buffer.storage.string as NSString
        let new = text as NSString
        guard old as String != text else { return }
        var prefix = 0
        let shorter = min(old.length, new.length)
        while prefix < shorter, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        if buffer === active, textView.shouldChangeText(in: range, replacementString: replacement) {
            buffer.storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: baseAttributes))
            textView.didChangeText()
        } else {
            buffer.storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: baseAttributes))
            buffer.document.markEdited()
            refreshChrome()
        }
    }

    // MARK: Drafts

    /// A request started with New Request and not saved yet.
    func isDraft(_ buffer: EditorBuffer) -> Bool {
        buffer.url.map { apiWorkspace?.isDraft($0) == true } ?? false
    }

    /// Saves a new request: asks its name, then puts it in the folder it was
    /// started from — its tab following it there. `done(false)` when
    /// cancelled.
    func saveDraft(_ buffer: EditorBuffer, then done: ((Bool) -> Void)? = nil) {
        guard let window = view.window, let draft = buffer.url, let workspace = apiWorkspace else {
            done?(false)
            return
        }
        let folder = workspace.place(of: draft).deletingLastPathComponent()
        let collection = workspace.collection(containing: draft)
        let alert = NSAlert()
        alert.messageText = "Save Request"
        alert.informativeText =
            "In “\(collection?.name ?? folder.lastPathComponent)”"
            + (collection.map { folder.standardizedFileURL != $0.root.standardizedFileURL } == true ? ", in “\(folder.lastPathComponent)”" : "")
            + (collection?.isPersonal == true ? " — yours, on this Mac." : " — in the checkout.")
        let field = NSTextField(string: buffer.request?.file.name ?? "New Request")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                done?(false)
                return
            }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            do {
                // What is in the editor, then moved in under its name.
                try buffer.document.save(buffer.storage.string, overwriting: true)
                let target = try workspace.saveDraft(draft, named: name.isEmpty ? "New Request" : name)
                self.filesMoved(from: draft, to: target)
                self.reloadIfChangedOnDisk()
                self.requestsMoved()
                self.onSaved?()
                done?(true)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                done?(false)
            }
        }
    }

    /// Files were renamed under open requests: each request's model is made
    /// again for its file's new path.
    func requestsMoved() {
        var changed = false
        for buffer in buffers where buffer.request != nil && buffer.request?.url.standardizedFileURL != buffer.url?.standardizedFileURL {
            buffer.request = nil
            attachRequest(buffer)
            changed = true
        }
        if changed { updatePreview() }
    }

    /// The window's API client arrived (or changed): open requests use it.
    func apiWorkspaceChanged() {
        for buffer in buffers where buffer.request != nil {
            buffer.request = nil
            attachRequest(buffer)
        }
        updatePreview()
    }
}
