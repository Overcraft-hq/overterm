#if E2E
import AppKit

/// Writing in a note: Return carries a list on and an empty item ends it, a
/// URL pasted over a selection makes a link, `/` puts a table, a heading
/// folds in Live Preview and opens again, and a shell block runs through
/// the window's question. The note's text is put back after.
extension E2ERunner {
    func notesWritingChecks(_ editor: EditorViewController) async {
        guard let buffer = editor.active, buffer.isNote else { return check("a note to write in", false) }
        let original = editor.textView.string
        func set(_ text: String, caret: Int? = nil) {
            editor.replaceText(of: buffer, with: text)
            editor.textView.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        }

        set("- milk")
        _ = editor.codeTextViewInsertNewline(editor.textView)
        check("Return carries a list on", editor.textView.string == "- milk\n- ", editor.textView.string.debugDescription)
        _ = editor.codeTextViewInsertNewline(editor.textView)
        check("and an empty item ends it", editor.textView.string == "- milk\n", editor.textView.string.debugDescription)

        set("see the docs")
        editor.textView.setSelectedRange((editor.textView.string as NSString).range(of: "docs"))
        let board = NSPasteboard(name: NSPasteboard.Name("overterm-e2e-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("https://example.com/guide", forType: .string)
        _ = editor.pasteIntoNote(from: board)
        board.releaseGlobally()
        check("a URL over a selection is a link", editor.textView.string == "see the [docs](https://example.com/guide)", editor.textView.string)

        set("")
        editor.textView.insertText("/tab", replacementRange: editor.textView.selectedRange())
        _ = editor.updateNoteCompletion()
        let offered = editor.completion.map { state in state.shown.map { state.candidates[$0].label } } ?? []
        check("/ offers what can go on the line", offered.first == "Table", "\(offered)")
        editor.acceptCompletion(at: 0)
        check("and puts it there, the slash gone", editor.textView.string.hasPrefix("|  |  |\n| --- |"), editor.textView.string.debugDescription)
        editor.dismissCompletion()

        if !buffer.livePreview { editor.toggleLivePreview() }
        set("# Plan\nhidden line\n# Next\nshown", caret: 2)
        editor.toggleHeadingFold()
        let hidden = (editor.textView.string as NSString).range(of: "hidden line").location
        let shown = (editor.textView.string as NSString).range(of: "shown").location
        check(
            "a heading folds: its lines hidden",
            await eventually(2) { editor.textView.textStorage?.attribute(.noteFolded, at: hidden, effectiveRange: nil) != nil }
                && editor.textView.textStorage?.attribute(.noteFolded, at: shown, effectiveRange: nil) == nil)
        editor.unfoldAllHeadings()
        check("and opens again", editor.textView.textStorage?.attribute(.noteFolded, at: hidden, effectiveRange: nil) == nil)

        var asked: String?
        let hook = editor.onRunNoteBlock
        editor.onRunNoteBlock = { asked = $0 }
        set("```bash\necho from the note\n```", caret: 10)
        editor.runNoteBlockAtCaret()
        check("a shell block goes to the window to be asked about", asked == "echo from the note", asked ?? "-")
        editor.onRunNoteBlock = hook

        set(original)
    }
}
#endif
