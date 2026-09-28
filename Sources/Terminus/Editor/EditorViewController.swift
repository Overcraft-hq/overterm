import AppKit
import Combine
import SwiftUI

/// The code editor pane beside the terminal: a header (name, unsaved dot,
/// open elsewhere, close) over a plain-text editor with line numbers.
@MainActor
final class EditorViewController: NSViewController, NSTextViewDelegate {
    let document = EditorDocument()
    /// Asked to hide the pane (after any unsaved-changes question).
    var onClose: (() -> Void)?

    private let theme: ChromeTheme
    private let background: NSColor
    private let foreground: NSColor
    /// The header's ↗: the file in the app picked for files.
    private let opener: ExternalOpener
    private var textView: NSTextView!
    private var ruler: LineNumberRuler!
    private var messageLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var language: SyntaxHighlighter.Language?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingHighlight: DispatchWorkItem?

    init(theme: ChromeTheme, background: NSColor, foreground: NSColor, opener: ExternalOpener) {
        self.theme = theme
        self.background = background
        self.foreground = foreground
        self.opener = opener
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        let header = EditorHeaderView(
            background: theme.stripNS, text: foreground,
            onReveal: { [weak self] in
                guard let self, let url = self.document.url else { return }
                self.opener.open(url)
            },
            revealMenu: { [weak self] in
                guard let self, let url = self.document.url else { return nil }
                return self.opener.menu(for: url)
            },
            onClose: { [weak self] in self?.requestClose() })
        document.$url.combineLatest(document.$isDirty)
            .receive(on: DispatchQueue.main)
            .sink { url, dirty in header.update(name: url?.lastPathComponent ?? "", path: url?.path ?? "", dirty: dirty) }
            .store(in: &cancellables)
        // The emitted value: @Published sends before the property changes.
        opener.$current
            .sink { header.setRevealTitle(OpenWith.openTitle($0)) }
            .store(in: &cancellables)

        // TextKit 1 on purpose: the line-number ruler walks the layout
        // manager's line fragments.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Only what is on screen gets laid out: a 4 MB file took 1.8 s to open
        // with the whole of it laid out first. The ruler draws the visible
        // fragments only, so it is unaffected.
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        // Unbounded width: no wrapping. (A 0-wide container lays out nothing —
        // the gutter numbered empty lines.)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        for off in [
            \NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled,
            \.isAutomaticTextReplacementEnabled, \.isAutomaticSpellingCorrectionEnabled, \.isContinuousSpellCheckingEnabled,
            \.isAutomaticLinkDetectionEnabled,
        ] {
            textView[keyPath: off] = false
        }
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = foreground
        textView.backgroundColor = background
        textView.insertionPointColor = foreground
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // No wrapping: code scrolls sideways.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No .width autoresizing: a sideways-scrolling text view sizes itself
        // to its text; tracking the clip view's width left it scrolled into
        // the middle of the document.
        textView.autoresizingMask = []
        textView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        let ruler = LineNumberRuler(textView: textView)
        ruler.textColor = foreground.withAlphaComponent(0.4)
        ruler.gutterColor = background
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let message = NSTextField(labelWithString: "")
        message.textColor = foreground.withAlphaComponent(0.6)
        message.alignment = .center
        message.isHidden = true

        for view in [header, scrollView, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),
        ])
        self.textView = textView
        self.ruler = ruler
        self.scrollView = scrollView
        self.messageLabel = message
        view = root
    }

    // MARK: Documents

    /// Opens `url`, asking first if the current file has unsaved edits.
    func open(_ url: URL, then done: @escaping (Bool) -> Void = { _ in }) {
        guard url != document.url else {
            done(true)
            return
        }
        confirmDiscard { [weak self] proceed in
            guard proceed, let self else { return done(false) }
            self.load(url)
            done(true)
        }
    }

    /// Selects line `line` (1-based) and scrolls it to the middle.
    func go(toLine line: Int) {
        _ = view
        let text = textView.string as NSString
        let starts = LineIndex.starts(of: text)
        guard line >= 1, line <= starts.count else { return }
        let start = starts[line - 1]
        let end = line < starts.count ? starts[line] - 1 : text.length
        let range = NSRange(location: start, length: max(0, end - start))
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        // Centre it rather than leave it on the bottom edge.
        if let rect = textView.layoutManager.map({ $0.boundingRect(forGlyphRange: $0.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: textView.textContainer!) }) {
            let visible = scrollView.contentView.bounds
            let y = max(0, rect.midY - visible.height / 2)
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        textView.showFindIndicator(for: range)
    }

    /// The selected line (1-based), for tests.
    var selectedLine: Int {
        // The text view exists once the view is loaded; before any file was
        // opened it isn't, and reading it trapped.
        _ = view
        return LineIndex.line(of: textView.selectedRange().location, in: LineIndex.starts(of: textView.string as NSString))
    }

    private func load(_ url: URL) {
        _ = view
        document.load(url)
        if let reason = document.unavailable {
            textView.string = ""
            messageLabel.stringValue = reason
        }
        messageLabel.isHidden = document.unavailable == nil
        scrollView.isHidden = document.unavailable != nil
        textView.string = document.text
        language = SyntaxHighlighter.language(for: url)
        highlight(loading: true)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // At least as big as the visible area, so a click below the last line
        // still lands in the text view; then show the top-left corner.
        ruler.textDidChange()
        textView.minSize = scrollView.contentSize
        textView.sizeToFit()
        // The ruler floats over the clip view (macOS 14+), which makes room
        // with a content inset as wide as the gutter: the top-left is minus
        // that inset. Scrolled to .zero, the gutter covered the first
        // characters of every line — six in a file of 70 000 lines.
        let insets = scrollView.contentView.contentInsets
        scrollView.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// An agent may have rewritten the file: pick that up unless you have
    /// edits of your own.
    func reloadIfChangedOnDisk() {
        guard let url = document.url, document.changedOnDisk, !document.isDirty else { return }
        let selection = textView.selectedRange()
        load(url)
        textView.setSelectedRange(NSRange(location: min(selection.location, (textView.string as NSString).length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        document.markEdited()
        ruler.textDidChange()
        // Coalesce a burst of typing into one pass.
        pendingHighlight?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.highlight() } }
        pendingHighlight = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Highlighting

    /// Re-colours the whole document. Attributes only — never the text —
    /// so undo is untouched.
    /// Past SyntaxHighlighter.maxLength there are no colours to update, and
    /// re-setting the base attributes over the whole text on every pause in
    /// typing made it all lay out again (165 ms a pause in a 4 MB file): it is
    /// done once, as the file loads.
    private func highlight(loading: Bool = false) {
        guard let storage = textView.textStorage else { return }
        guard loading || storage.length <= SyntaxHighlighter.maxLength else { return }
        let full = NSRange(location: 0, length: storage.length)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        storage.beginEditing()
        storage.setAttributes([.foregroundColor: foreground, .font: font], range: full)
        if let language, storage.length <= SyntaxHighlighter.maxLength {
            for (range, kind) in SyntaxHighlighter.tokens(in: storage.string, language: language) where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: SyntaxPalette.color(kind, text: foreground), range: range)
                if kind == .comment { storage.addAttribute(.font, value: italic, range: range) }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.foregroundColor: foreground, .font: font]
    }

    @objc func saveDocument(_ sender: Any?) {
        save(overwriting: false)
    }

    private func save(overwriting: Bool) {
        do {
            try document.save(textView.string, overwriting: overwriting)
        } catch is EditorDocument.ChangedOnDisk {
            confirmOverwrite()
        } catch {
            view.window.map { NSAlert(error: error).beginSheetModal(for: $0) }
        }
    }

    /// Something else wrote the file while it had edits here. Cancel first:
    /// Return keeps both — theirs on disk, yours in the editor.
    private func confirmOverwrite() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(document.name)” changed on disk"
        alert.informativeText = "Something else saved it since you opened it — an agent, most likely. Saving replaces those changes with yours."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Anyway").keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.save(overwriting: true)
        }
    }

    private func requestClose() {
        confirmDiscard { [weak self] proceed in
            guard proceed, let self else { return }
            self.document.close()
            self.textView.string = ""
            self.onClose?()
        }
    }

    /// Unsaved edits: Save, Don't Save, or Cancel. `proceed` is false only
    /// for Cancel (or a failed save).
    private func confirmDiscard(_ proceed: @escaping (Bool) -> Void) {
        guard document.isDirty, let window = view.window else { return proceed(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveDocument(nil)
                proceed(!self.document.isDirty)
            case .alertThirdButtonReturn:
                proceed(true)
            default:
                proceed(false)
            }
        }
    }
}

/// Name (centred, with an unsaved dot), open-in-app and close. AppKit: a
/// SwiftUI header in this pane, created while the pane was collapsed,
/// never drew.
private final class EditorHeaderView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let reveal = MenuButton()
    private let onReveal: () -> Void
    private let onClose: () -> Void
    private let background: NSColor

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
    }

    /// `revealMenu`: Open With, on a right-click on ↗.
    init(
        background: NSColor, text: NSColor, onReveal: @escaping () -> Void, revealMenu: @escaping () -> NSMenu?,
        onClose: @escaping () -> Void
    ) {
        self.onReveal = onReveal
        self.onClose = onClose
        self.background = background
        super.init(frame: .zero)

        title.font = .systemFont(ofSize: 12)
        title.textColor = text
        title.lineBreakMode = .byTruncatingMiddle
        title.alignment = .center
        dot.wantsLayer = true
        dot.layer?.backgroundColor = text.cgColor
        dot.layer?.cornerRadius = 3
        dot.isHidden = true
        dot.toolTip = "Unsaved — ⌘S"

        Self.style(reveal, "arrow.up.forward.app", tip: OpenWith.openTitle(nil), color: text, target: self, action: #selector(revealFile))
        reveal.identifier = NSUserInterfaceItemIdentifier("openExternally")
        reveal.menuProvider = revealMenu
        let close = Self.style(NSButton(), "xmark", tip: "Close Editor", color: text, target: self, action: #selector(close))
        for view in [title, dot, reveal, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            reveal.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            reveal.centerYAnchor.constraint(equalTo: centerYAnchor),
            reveal.widthAnchor.constraint(equalToConstant: 22),
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: reveal.leadingAnchor, constant: -8),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: title.leadingAnchor, constant: -6),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(name: String, path: String, dirty: Bool) {
        title.stringValue = name
        title.toolTip = path
        dot.isHidden = !dirty
    }

    /// "Open in Zed", or "Open With…" while no app is picked.
    func setRevealTitle(_ tip: String) {
        reveal.toolTip = tip
        reveal.setAccessibilityLabel(tip)
    }

    @discardableResult
    private static func style<Button: NSButton>(
        _ button: Button, _ symbol: String, tip: String, color: NSColor, target: AnyObject, action: Selector
    ) -> Button {
        button.image =
            NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage()
        button.imagePosition = .imageOnly
        button.title = ""
        button.target = target
        button.action = action
        button.isBordered = false
        button.contentTintColor = color.withAlphaComponent(0.7)
        button.toolTip = tip
        return button
    }

    @objc private func revealFile() { onReveal() }
    @objc private func close() { onClose() }
}

/// A button with a menu on right-click (NSView asks `menu(for:)`), built
/// when asked: Open With depends on the file and on the app in use.
private final class MenuButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }
}
