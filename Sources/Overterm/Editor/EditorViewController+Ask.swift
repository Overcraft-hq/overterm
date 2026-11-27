import AppKit

/// What ⌘L hands an agent from the editor: the file's path in the
/// checkout, the lines, the text and a problem marked on it (EDIT-N1).
package struct EditorAsk {
    package let text: String
    package let subject: String
    /// The checkout the file is in, else its folder: where a new agent tab opens.
    package let folder: URL?
}

extension EditorViewController {
    /// Nil without a selection — ⌘L then means what it did before.
    package func askAboutSelection() -> EditorAsk? {
        guard isViewLoaded, let buffer = active, let url = buffer.url, buffer.document.unavailable == nil else { return nil }
        let range = textView.selectedRange()
        let string = textView.string as NSString
        guard range.length > 0, NSMaxRange(range) <= string.length else { return nil }
        let selected = string.substring(with: range)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let starts = LineIndex.starts(of: string)
        let first = LineIndex.line(of: range.location, in: starts)
        let last = LineIndex.line(of: NSMaxRange(range) - 1, in: starts)
        let virtual = buffer.document.isVirtual
        let root = virtual ? nil : workspaceRoot?() ?? Self.gitRoot(of: url)
        let path: String
        if virtual {
            path = buffer.name
        } else if let root, let relative = FileTreeMarks.relative(url.standardizedFileURL.path, to: root.standardizedFileURL.path) {
            path = relative
        } else {
            path = url.path
        }
        // The worst problem the selection touches.
        let problem = buffer.diagnostics
            .filter { NSIntersectionRange($0.range, range).length > 0 || NSLocationInRange($0.range.location, range) }
            .min { $0.severity < $1.severity }
            .map { EditorAskSelection.Problem(severity: Self.severityName($0.severity), message: $0.message, source: $0.source) }
        let text = EditorAskSelection.text(
            path: path, first: first, last: last, selection: selected, language: buffer.language?.id, problem: problem,
            scrub: EditorAskSelection.scrubs(fileName: buffer.name, isVirtual: virtual))
        return EditorAsk(
            text: text, subject: EditorAskSelection.subject(path: path, first: first, last: last),
            folder: root ?? (virtual ? nil : url.deletingLastPathComponent()))
    }

    private static func severityName(_ severity: EditorDiagnostic.Severity) -> String {
        switch severity {
        case .error: "error"
        case .warning: "warning"
        case .info: "info"
        case .hint: "hint"
        }
    }

    /// Whether the editor's text has the window's keyboard.
    package var hasKeyboard: Bool {
        guard isViewLoaded, let textView else { return false }
        return textView.window?.firstResponder === textView
    }
}
