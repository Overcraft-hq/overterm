import AppKit

/// One file open in the editor: its text (a storage the text view swaps
/// in), its own undo history, its syntax tree, and where you were in it.
/// The pane holds several, as Zed's tabs.
@MainActor
final class EditorBuffer {
    let document = EditorDocument()
    let storage = NSTextStorage()
    let undo = UndoManager()
    /// The storage's delegate: an edit noted once, whichever editor made
    /// it, and every editor showing the buffer told.
    let relay = EditorStorageRelay()
    private(set) var language: EditorLanguage?
    private(set) var syntax: SyntaxDocument?

    /// Bumped on every edit: highlights computed for an older text are dropped.
    var version = 0
    /// Edits the syntax tree hasn't been told about yet.
    var pendingEdit: SyntaxEdit?
    /// What has colours for the current version.
    var painted = IndexSet()

    var selection: [NSRange] = [NSRange(location: 0, length: 0)]
    var scroll: NSPoint?
    /// Spaces per indent level and whether a Tab inserts a tab.
    var indentWidth = 4
    var usesTabs = false
    /// ⌥Z's choice for this file, over the setting.
    var wrapOverride: Bool?
    /// Markdown shown rendered instead of its text (⇧⌘V); a Bruno request
    /// shown as one (APIRequestView).
    var showsPreview = false
    /// A `.bru` request's model, while the file is one.
    var request: APIRequestModel?
    /// A note of the vault: its preview is the reading view (NoteReaderView).
    var isNote = false
    /// An Excalidraw drawing: shown as its canvas (DrawingView) over its text.
    var drawing: DrawingModel?
    /// A `.sql` file: the console under it (connection, results).
    var sqlConsole: SQLConsole?
    /// A Kubernetes manifest — a cluster object's copy (`y`), a checkout's
    /// file, a kustomization: the bar under it (Diff with Cluster, Apply).
    var kubeManifest: KubeManifestSession?
    /// A cluster object's YAML (`KubeResourceBuffer`): one buffer for the
    /// resource, shown by the detail's YAML tab and by the editor's tab `y`
    /// opens — never a file.
    weak var resource: KubeResourceBuffer?
    /// A note shown as Obsidian's Live Preview (NoteLivePreview) — on by default.
    var livePreview = false
    /// The caret's lines when Live Preview last styled them: their markup shows.
    var liveEditing: [NSRange] = []
    /// The note's frontmatter and code blocks, for the text's `version`.
    var liveBlocks: (version: Int, blocks: [NoteLivePreview.Block])?

    /// The language server's problems, and the fields a Kubernetes
    /// manifest's cluster doesn't know (3.15): shown together.
    var diagnostics: [EditorDiagnostic] {
        get { serverDiagnostics + kubeDiagnostics }
        set { serverDiagnostics = newValue }
    }
    var serverDiagnostics: [EditorDiagnostic] = []
    var kubeDiagnostics: [EditorDiagnostic] = []
    /// The file as the last commit has it; nil outside git or when new.
    var gitBase: String?
    var gitMarks: [GitGutterMark] = []
    /// The version a language server last heard.
    var serverVersion = 0
    var serverOpen = false
    /// The server found for it, kept: looking one up walks the folders up
    /// for its root, and the status bar asks on every caret move.
    var server: LanguageServer?

    var url: URL? { document.url }
    var name: String { document.name }

    init() {
        relay.buffer = self
        storage.delegate = relay
    }

    /// Text that is no file's (`EditorDocument.loadVirtual`), coloured as
    /// `url`'s language.
    func loadVirtual(_ url: URL, text: String, attributes: [NSAttributedString.Key: Any]) {
        document.loadVirtual(url, text: text)
        language = EditorLanguage.language(for: url)
        syntax = language.map { SyntaxDocument(language: $0) }
        setText(text, attributes: attributes)
    }

    func load(_ url: URL, attributes: [NSAttributedString.Key: Any]) {
        document.load(url)
        language = EditorLanguage.language(for: url)
        syntax = language.map { SyntaxDocument(language: $0) }
        setText(document.text, attributes: attributes)
    }

    /// Replaces the whole text (a load, a reload from disk).
    func setText(_ text: String, attributes: [NSAttributedString.Key: Any]) {
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
    func noteEdit(location: Int, oldLength: Int, newLength: Int) {
        version += 1
        painted = IndexSet()
        if pendingEdit == nil {
            pendingEdit = SyntaxEdit(location: location, oldLength: oldLength, newLength: newLength)
        } else {
            pendingEdit?.merge(location: location, oldLength: oldLength, newLength: newLength)
        }
    }

    /// Hands the edits so far to the parser (once per run-loop pass).
    func flushEdits() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        syntax?.update(Self.utf16(storage.string as NSString), edit: edit, version: version)
    }

    static func utf16(_ text: NSString) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: text.length)
        buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: text.length)) }
        return buffer
    }

    /// The file's own indentation (IndentStyle.detect: tabs, or its step
    /// of spaces); Go and Makefiles are tabs whatever they hold.
    func detectIndent() {
        switch IndentStyle.detect(in: storage.string as NSString, languageID: languageID) {
        case .tabs:
            usesTabs = true
            indentWidth = Settings.shared.editorTabSize
        case .spaces(let count):
            usesTabs = false
            indentWidth = count
        }
    }

    var indentStyle: IndentStyle { usesTabs ? .tabs : .spaces(indentWidth) }
    /// EditCommands' name for the language ("swift", "make", "markdown").
    var languageID: String? { url.flatMap { EditCommands.languageID(forFileName: $0.lastPathComponent) } }

    var indentUnit: String { usesTabs ? "\t" : String(repeating: " ", count: indentWidth) }
}

/// A buffer's storage delegate. The editors that show the buffer — the
/// window's, and the Kubernetes detail's YAML tab for a cluster object —
/// each hold a layout manager on the one storage; an edit made in either
/// is noted once (`noteEdit`) and every one of them repaints.
@MainActor
final class EditorStorageRelay: NSObject, NSTextStorageDelegate {
    weak var buffer: EditorBuffer?
    let editors = NSHashTable<EditorViewController>.weakObjects()
    /// An edit landed (any editor's, or a reload's).
    var onEdit: (() -> Void)?

    nonisolated func textStorage(
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
final class EditorLineHeight: NSObject, NSLayoutManagerDelegate, @unchecked Sendable {
    var font: NSFont
    var multiple: CGFloat

    init(font: NSFont, multiple: CGFloat) {
        self.font = font
        self.multiple = multiple
    }

    /// A note in Live Preview: each line as tall as its largest font (a
    /// heading's), not the code font's one height for every line.
    var variable = false

    var height: CGFloat { ((font.ascender - font.descender + font.leading) * multiple).rounded() }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        var font = self.font
        if variable, let storage = layoutManager.textStorage {
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
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
    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>, font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard variable, let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<count {
            let index = characterIndexes[i]
            guard index < storage.length, storage.attribute(.noteHidden, at: index, effectiveRange: nil) != nil else { continue }
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
