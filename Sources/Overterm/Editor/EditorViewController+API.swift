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
