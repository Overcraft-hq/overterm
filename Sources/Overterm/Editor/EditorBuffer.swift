import AppKit

/// One file open in the editor: its text (a storage the text view swaps
/// in), its own undo history, its syntax tree, and where you were in it.
/// The pane holds several, as Zed's tabs.
@MainActor
package final class EditorBuffer {
    package let document = EditorDocument()
    package let storage = NSTextStorage()
    package let undo = UndoManager()
    /// The storage's delegate: an edit noted once, whichever editor made
    /// it, and every editor showing the buffer told.
    package let relay = EditorStorageRelay()
    package private(set) var language: EditorLanguage?
    package private(set) var syntax: SyntaxDocument?

    /// Bumped on every edit: highlights computed for an older text are dropped.
    package var version = 0
    /// Edits the syntax tree hasn't been told about yet.
    package var pendingEdit: SyntaxEdit?
    /// What has colours for the current version.
    package var painted = IndexSet()

    package var selection: [NSRange] = [NSRange(location: 0, length: 0)]
    package var scroll: NSPoint?
    /// Spaces per indent level and whether a Tab inserts a tab.
    package var indentWidth = 4
    package var usesTabs = false
    /// ⌥Z's choice for this file, over the setting.
    package var wrapOverride: Bool?
    /// Markdown shown rendered instead of its text (⇧⌘V); a Bruno request
    /// shown as one (APIRequestView).
    package var showsPreview = false
    /// A `.bru` request's model, while the file is one.
    package var requestPart: (any EditorRequestPart)?
    /// A note of the vault: its preview is the reading view (NoteReaderView).
    package var isNote = false
    /// An Excalidraw drawing: shown as its canvas (DrawingView) over its text.
    package var drawingPart: AnyObject?
    /// A `.sql` file: the console under it (connection, results).
    package var consolePart: (any EditorConsole)?
    /// A Kubernetes manifest — a cluster object's copy (`y`), a checkout's
    /// file, a kustomization: the bar under it (Diff with Cluster, Apply).
    package var manifestPart: (any EditorManifest)?
    /// A cluster object's YAML (`KubeResourceBuffer`): one buffer for the
    /// resource, shown by the detail's YAML tab and by the editor's tab `y`
    /// opens — never a file.
    package weak var resourcePart: (any EditorResource)?
    /// A note shown as Obsidian's Live Preview (NoteLivePreview) — on by default.
    package var livePreview = false
    /// The caret's lines when Live Preview last styled them: their markup shows.
    package var liveEditing: [NSRange] = []
    /// A note's folded headings, by `NoteFolding.Section.key`: hidden in
    /// Live Preview, kept while the buffer is open.
    package var foldedHeadings: Set<String> = []
    /// The note's sections for the version they were read at.
    package var foldSections: (version: Int, sections: [NoteFolding.Section])?
    /// The note's frontmatter and code blocks, for the text's `version`.
    package var liveBlocks: (version: Int, blocks: [NoteLivePreview.Block])?

    /// A Terraform file: its module folder — validate, Format — and the bar under it.
    package var terraformPart: AnyObject?
    /// Validate asked for while it had edits: it is saved first, and its
    /// folder validated once the save has written it (format on save
    /// writes later than `save` returns).
    package var terraformValidatesOnSave = false

    /// The language server's problems, the fields a Kubernetes manifest's
    /// cluster doesn't know (3.15), and `terraform validate`'s: shown together.
    package var diagnostics: [EditorDiagnostic] {
        get { serverDiagnostics + kubeDiagnostics + terraformDiagnostics }
        set { serverDiagnostics = newValue }
    }
    package var serverDiagnostics: [EditorDiagnostic] = []
    package var kubeDiagnostics: [EditorDiagnostic] = []
    /// The last validate's, laid over the text it was saved as — never over
    /// one edited since that validate started (`TerraformFolder.describes`):
    /// dropped at the next edit, which they no longer describe.
    package var terraformDiagnostics: [EditorDiagnostic] = []
    /// The file as the last commit has it; nil outside git or when new.
    /// The disk's version Keep Mine was pressed for: its bar stays away
    /// until the file changes again.
    package var keptDiskVersion: Date?
    package var gitBase: String?
    package var gitMarks: [GitGutterMark] = []
    /// The version a language server last heard.
    package var serverVersion = 0
    package var serverOpen = false
    /// The server found for it, kept: looking one up walks the folders up
    /// for its root, and the status bar asks on every caret move.
    package var server: LanguageServer?

    package var url: URL? { document.url }
    package var name: String { document.name }

    package init() {
        relay.buffer = self
        storage.delegate = relay
    }

    /// Text that is no file's (`EditorDocument.loadVirtual`), coloured as
    /// `url`'s language.
    package func loadVirtual(_ url: URL, text: String, attributes: [NSAttributedString.Key: Any]) {
        document.loadVirtual(url, text: text)
        language = EditorLanguage.language(for: url)
        syntax = language.map { SyntaxDocument(language: $0) }
        setText(text, attributes: attributes)
    }

    package func load(_ url: URL, attributes: [NSAttributedString.Key: Any]) {
        document.load(url)
        language = EditorLanguage.language(for: url)
        syntax = language.map { SyntaxDocument(language: $0) }
        setText(document.text, attributes: attributes)
    }

    /// Replaces the whole text (a load, a reload from disk).
    package func setText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        storage.endEditing()
        undo.removeAllActions()
        version += 1
        pendingEdit = nil
        painted = IndexSet()
        syntax?.reset(Self.utf16(storage.string as NSString), version: version)
        detectIndent()
    }

    /// The storage changed `oldLength` characters at `location` into `newLength`.
    package func noteEdit(location: Int, oldLength: Int, newLength: Int) {
        version += 1
        painted = IndexSet()
        if pendingEdit == nil {
            pendingEdit = SyntaxEdit(location: location, oldLength: oldLength, newLength: newLength)
        } else {
            pendingEdit?.merge(location: location, oldLength: oldLength, newLength: newLength)
        }
    }

    /// Hands the edits so far to the parser (once per run-loop pass).
    package func flushEdits() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        syntax?.update(Self.utf16(storage.string as NSString), edit: edit, version: version)
    }

    package static func utf16(_ text: NSString) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: text.length)
        buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: text.length)) }
        return buffer
    }

    /// The file's own indentation (IndentStyle.detect: tabs, or its step
    /// of spaces); Go and Makefiles are tabs whatever they hold.
    package func detectIndent() {
        switch IndentStyle.detect(in: storage.string as NSString, languageID: languageID) {
        case .tabs:
            usesTabs = true
            indentWidth = Settings.shared.editorTabSize
        case .spaces(let count):
            usesTabs = false
            indentWidth = count
        }
    }

    package var indentStyle: IndentStyle { usesTabs ? .tabs : .spaces(indentWidth) }
    /// EditCommands' name for the language ("swift", "make", "markdown").
    package var languageID: String? { url.flatMap { EditCommands.languageID(forFileName: $0.lastPathComponent) } }

    package var indentUnit: String { usesTabs ? "\t" : String(repeating: " ", count: indentWidth) }
}

/// A buffer's storage delegate. The editors that show the buffer — the
/// window's, and the Kubernetes detail's YAML tab for a cluster object —
/// each hold a layout manager on the one storage; an edit made in either
/// is noted once (`noteEdit`) and every one of them repaints.
@MainActor
package final class EditorStorageRelay: NSObject, NSTextStorageDelegate {
    package weak var buffer: EditorBuffer?
    package let editors = NSHashTable<EditorViewController>.weakObjects()
    /// An edit landed (any editor's, or a reload's).
    package var onEdit: (() -> Void)?

    package nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Storages are only edited on the main thread: the text view's.
        MainActor.assumeIsolated {
            let showing = editors.allObjects
            guard let buffer, !showing.contains(where: \.isSwapping) else { return }
            buffer.noteEdit(location: editedRange.location, oldLength: editedRange.length - delta, newLength: editedRange.length)
            for editor in showing { editor.storageEdited(buffer) }
            onEdit?()
        }
    }
}

/// Every line as tall as the setting asks, the text centred in it — Zed's
/// "comfortable" spacing. A layout manager delegate, not a paragraph style:
/// a style's extra height all goes above the text.
package final class EditorLineHeight: NSObject, NSLayoutManagerDelegate, @unchecked Sendable {
    package var font: NSFont
    package var multiple: CGFloat

    package init(font: NSFont, multiple: CGFloat) {
        self.font = font
        self.multiple = multiple
    }

    /// A note in Live Preview: each line as tall as its largest font (a
    /// heading's), not the code font's one height for every line.
    package var variable = false

    package var height: CGFloat { ((font.ascender - font.descender + font.leading) * multiple).rounded() }

    package func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        var font = self.font
        if variable, let storage = layoutManager.textStorage {
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // A line under a folded heading: nothing to show, no height.
            if characters.length > 0, NSMaxRange(characters) <= storage.length {
                var folded = NSRange()
                if storage.attribute(.noteFolded, at: characters.location, longestEffectiveRange: &folded, in: characters) != nil,
                    NSMaxRange(folded) >= NSMaxRange(characters)
                {
                    lineFragmentRect.pointee.size.height = 0
                    lineFragmentUsedRect.pointee.size.height = 0
                    baselineOffset.pointee = 0
                    return true
                }
            }
            var largest: NSFont?
            storage.enumerateAttribute(.font, in: NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))) { value, range, _ in
                guard let candidate = value as? NSFont, storage.attribute(.noteHidden, at: range.location, effectiveRange: nil) == nil else { return }
                if candidate.pointSize > (largest?.pointSize ?? 0) { largest = candidate }
            }
            if let largest { font = largest }
        }
        let height = ((font.ascender - font.descender + font.leading) * multiple).rounded()
        let natural = font.ascender - font.descender
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = ((height - natural) / 2 + font.ascender).rounded()
        return true
    }

    /// Live Preview's hidden markup (`.noteHidden`): laid out as nothing.
    package func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard variable, let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<count {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            let hidden = storage.attribute(.noteHidden, at: index, effectiveRange: nil) != nil
            // A folded line's break stays one, so each folded line is a fragment of its own (and takes no height).
            let folded = !hidden && storage.attribute(.noteFolded, at: index, effectiveRange: nil) != nil && (storage.string as NSString).character(at: index) != 0x0A
            guard hidden || folded else { continue }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: count)) }
            changed?[i] = .null
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        }
        return count
    }
}
