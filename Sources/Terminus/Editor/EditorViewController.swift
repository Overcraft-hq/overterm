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
    private var textView: NSTextView!
    private var ruler: LineNumberRuler!
    private var messageLabel: NSTextField!
    private var scrollView: NSScrollView!

    init(theme: ChromeTheme, background: NSColor, foreground: NSColor) {
        self.theme = theme
        self.background = background
        self.foreground = foreground
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        let header = NSHostingView(
            rootView: EditorHeader(
                document: document, theme: theme,
                onReveal: { [weak self] in self?.document.url.map { NSWorkspace.shared.open($0) } },
                onClose: { [weak self] in self?.requestClose() }))

        // TextKit 1 on purpose: the line-number ruler walks the layout
        // manager's line fragments.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
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
        textView.autoresizingMask = [.width]
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
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        ruler.textDidChange()
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
    }

    @objc func saveDocument(_ sender: Any?) {
        do {
            try document.save(textView.string)
        } catch {
            view.window.map { NSAlert(error: error).beginSheetModal(for: $0) }
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

private struct EditorHeader: View {
    @ObservedObject var document: EditorDocument
    let theme: ChromeTheme
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if document.isDirty {
                Circle().fill(theme.text).frame(width: 6, height: 6).help("Unsaved — ⌘S")
            }
            Text(document.name)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(document.url?.path ?? "")
            Spacer(minLength: 0)
            Button(action: onReveal) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Open in Default App")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.dimText)
            .help("Close Editor")
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(theme.strip)
    }
}
