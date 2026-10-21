import AppKit
import SwiftUI

/// A text area for a body, a script, the tests, the docs or a response:
/// the editor's font and colours, tree-sitter's highlighting, nothing
/// typed substituted — quotes stay straight in JSON.
struct APICodeView: NSViewRepresentable {
    @Binding var text: String
    /// A grammar's name or alias: "json", "javascript", "markdown", "yaml".
    var language: String?
    var editable = true
    var placeholder = ""
    /// Wraps long lines (prose, a long token); code otherwise scrolls sideways.
    var wraps = false
    var accessibilityIdentifier: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = APITextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // The window's content runs under its title bar: left to adjust, the
        // scroll view took the title bar's height as an inset and hid the
        // first line under the tabs above it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        let theme = EditorTheme(background: GhosttyRuntime.shared.backgroundColor)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorViewController.font
        textView.textColor = theme.text
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.info
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.drawsBackground = true
        scroll.backgroundColor = theme.background
        scroll.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isEditable = editable
        textView.isSelectable = true
        if let accessibilityIdentifier { textView.setAccessibilityIdentifier(accessibilityIdentifier) }
        context.coordinator.textView = textView
        context.coordinator.theme = theme
        applyWrap(textView, scroll: scroll)
        context.coordinator.show(text)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = editable
        applyWrap(textView, scroll: scroll)
        // The binding changed under it (another request, a reload): shown
        // anew. Typing reaches here too, with the text it already has.
        if textView.string != text { context.coordinator.show(text) }
    }

    private func applyWrap(_ textView: NSTextView, scroll: NSScrollView) {
        guard let container = textView.textContainer, container.widthTracksTextView != wraps else { return }
        if wraps {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            scroll.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: APICodeView
        weak var textView: NSTextView?
        var theme: EditorTheme?
        private var syntax: SyntaxDocument?
        private var syntaxLanguage: String?
        private var version = 0
        private var pending: DispatchWorkItem?

        init(_ parent: APICodeView) {
            self.parent = parent
        }

        func show(_ text: String) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            // Only where it is typed in: a caret set in a read-only view
            // scrolled it, after layout, to keep the caret in sight — the
            // first column hidden.
            if parent.editable { textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0)) }
            // New text (another response, another request) starts at its
            // top-left, not where the last one was scrolled to.
            // After layout: made before the view is in its window, a scroll
            // now is undone when the text is laid out.
            if !parent.editable || selection.location == 0 {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, let clip = textView.enclosingScrollView?.contentView else { return }
                    clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: -clip.contentInsets.top))
                    textView.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            paint()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            schedulePaint()
        }

        private func schedulePaint() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.paint() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        /// Colours the text from a fresh parse: these are small (a body, a
        /// script); a response past the highlighter's limit stays plain.
        private func paint() {
            guard let textView, let storage = textView.textStorage, let theme else { return }
            let font = EditorViewController.font
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: theme.text], range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            guard let name = parent.language, storage.length > 0, storage.length <= SyntaxHighlighter.maxLength,
                let language = EditorLanguage.named(name)
            else { return }
            if syntaxLanguage != name {
                syntax = SyntaxDocument(language: language)
                syntaxLanguage = name
            }
            guard let syntax else { return }
            version += 1
            let version = self.version
            syntax.reset(EditorBuffer.utf16(storage.string as NSString), version: version)
            let range = NSRange(location: 0, length: storage.length)
            syntax.highlights(in: range) { [weak self] parsed, spans in
                MainActor.assumeIsolated {
                    guard let self, parsed == self.version, let textView = self.textView, let storage = textView.textStorage,
                        storage.length == range.length, let theme = self.theme
                    else { return }
                    storage.beginEditing()
                    for span in spans {
                        let clipped = NSIntersectionRange(span.range, range)
                        guard clipped.length > 0, let style = theme.style(for: span.capture) else { continue }
                        storage.addAttribute(.foregroundColor, value: style.color, range: clipped)
                    }
                    storage.endEditing()
                }
            }
        }
    }
}

/// The code view's text view. A live resize ending — the editor column
/// opening, a divider let go — makes NSTextView scroll its selection into
/// sight (viewDidEndLiveResize), which in a read-only view nobody had put
/// anywhere: the first column came up hidden. It stays where it was.
final class APITextView: NSTextView {
    override func viewDidEndLiveResize() {
        guard !isEditable, let clip = enclosingScrollView?.contentView else { return super.viewDidEndLiveResize() }
        let origin = clip.bounds.origin
        super.viewDidEndLiveResize()
        if clip.bounds.origin != origin {
            clip.scroll(to: origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
}
