import AppKit
import Combine
import SwiftUI

/// The code editor pane beside the terminal, Zed's way: a tab per open file,
/// tree-sitter colours, a gutter with numbers, git changes and problems,
/// completions and go-to from language servers, Zed's keys and (if asked)
/// vim. One text view; each file is an EditorBuffer it swaps in.
@MainActor
package final class EditorViewController: NSViewController, NSTextViewDelegate {
    /// Asked to hide the pane (after any unsaved-changes question).
    package var onClose: (() -> Void)?
    /// Asked to fill the window with the editor, or give the terminal back.
    package var onToggleZoom: (() -> Void)?
    /// A file was saved (the browser's reload on save).
    package var onSaved: (() -> Void)?
    /// The file the last save wrote, for `onSaved` — not always the active
    /// one: closing a tab saves the buffer being closed.
    package private(set) var lastSaved: URL?
    /// A file's tab closed (a copy made to be read goes with it).
    package var onBufferClosed: ((URL) -> Void)?
    /// Where Go to File looks: the window's checkout.
    package var workspaceRoot: (() -> URL?)?
    /// The window's API client: a `.bru` request opens as one, sent through it.
    package var apiWorkspaceStorage: AnyObject?
    /// The window: a Kubernetes manifest's confirmations and its diff.
    package weak var kubernetesHostStorage: AnyObject?
    /// The window: Ask Why on a Terraform folder's failed validate.
    package weak var terraformHostStorage: AnyObject?
    /// The file showing changed (another tab, a rename, the last one closed):
    /// the notes panel highlights it.
    package var onActiveChanged: ((URL?) -> Void)?
    /// A note's reading view, made the first time one is read.
    package var noteReaderStorage: NSView?
    /// The canvas showing, when the active buffer is a drawing.
    package var shownDrawingStorage: NSView?
    package var noteObserver: AnyCancellable?
    /// A #tag clicked in a note.
    package var onNoteTag: ((String) -> Void)?
    /// A note's shell block to run: its command, for the window to ask
    /// about and type into the selected tab.
    package var onRunNoteBlock: ((String) -> Void)?
    /// The header's menu: Reveal in Files (the window's sidebar).
    package var onRevealInFiles: ((URL) -> Void)?

    package let chrome: ChromeTheme
    package private(set) var theme: EditorTheme
    /// The header's ↗: the file in the app picked for files.
    package let opener: ExternalOpener

    package private(set) var buffers: [EditorBuffer] = []
    package private(set) var activeIndex = -1
    package var active: EditorBuffer? { buffers.indices.contains(activeIndex) ? buffers[activeIndex] : nil }
    /// Stands in while nothing is open, so `document` is never nil.
    private let emptyDocument = EditorDocument()
    /// The file showing — E2E, the window's close questions.
    package var document: EditorDocument { active?.document ?? emptyDocument }
    /// Files with unsaved edits, and cluster objects' YAML with edits not
    /// applied (never saved: closing loses them).
    package var unsavedNames: [String] {
        buffers.filter {
            ($0.document.isDirty && $0.document.unsaveable == nil) || $0.resourcePart?.isEdited == true || ($0.consolePart?.unsavedEdits() ?? 0) > 0
        }.map(\.name)
    }
    /// The Kubernetes detail's YAML tab (`KubeResourceYAMLView`): one
    /// buffer at a time — the resource's, shared with the window's editor —
    /// no tabs, no breadcrumb, its bar drawn over it by the page.
    package let embedded: Bool

    package private(set) var textView: CodeTextView!
    package private(set) var gutter: EditorGutter!
    package private(set) var scrollView: NSScrollView!
    private var header: EditorHeaderView!
    /// Over a file you have edits in that changed on disk (EDIT-G3).
    package private(set) var diskBar: EditorDiskBar!
    private var diskBarHeight: NSLayoutConstraint!
    package private(set) var breadcrumb: EditorBreadcrumbView!
    package private(set) var statusBar: EditorStatusBar!
    /// A `.sql` file's console, under its text (EditorViewController+Database).
    package private(set) var consoleHost: NSHostingView<AnyView>!
    package var consoleHeight: NSLayoutConstraint!
    package var consoleObserver: AnyCancellable?
    /// How tall the console is with results showing; dragged by its edge.
    package var consoleResultsHeight: CGFloat = 260
    package private(set) var preview: MarkdownPreviewView!
    /// A Bruno request, shown in place of its file's text.
    package private(set) var requestHost: NSHostingView<AnyView>!
    private var pendingPreview: DispatchWorkItem?
    private var messageLabel: NSTextField!
    package private(set) var lineHeight: EditorLineHeight!
    private var cancellables: Set<AnyCancellable> = []
    private var documentObservers: Set<AnyCancellable> = []
    private var flushScheduled = false
    /// While a buffer is being swapped in, its storage events aren't edits.
    package private(set) var isSwapping = false
    /// Held: a storage holds its layout managers, and this one moves from
    /// storage to storage.
    private var layout: NSLayoutManager!

    // Shared with the extensions.
    package var completion: CompletionState?
    /// Counts completion requests, for telling a stale answer apart.
    package var completionRequests = 0
    package lazy var completionPopup: CompletionPopup = {
        let popup = CompletionPopup(theme: theme)
        popup.onChoose = { [weak self] index in self?.acceptCompletion(at: index) }
        return popup
    }()
    package var picker: EditorPicker?
    package var hover: NSPopover?
    package var vim: VimEngine?
    /// ⌘D's whole-word mode, kept between presses.
    package var occurrenceWholeWord = false
    package var settingSelection = false
    package var history = NavigationHistory()
    package var isZoomed = false {
        didSet { header?.setZoomed(isZoomed) }
    }
    package var pendingSelectionWork: DispatchWorkItem?
    package var pendingGitWork: DispatchWorkItem?
    package var pendingServerChange: DispatchWorkItem?
    /// A manifest's unknown fields, marked again once typing pauses.
    package var pendingKubeMarks: DispatchWorkItem?
    /// The innermost symbol around the caret, from the language server.
    package var currentSymbols: [EditorSymbol] = []

    package init(theme chrome: ChromeTheme, background: NSColor, foreground: NSColor, opener: ExternalOpener, embedded: Bool = false) {
        self.embedded = embedded
        self.chrome = chrome
        self.theme = Self.makeTheme(background: background)
        self.opener = opener
        super.init(nibName: nil, bundle: nil)
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Views

    package override func loadView() {
        let root = NSView()
        let header = EditorHeaderView(background: chrome.stripNS, text: theme.text, accent: theme.info)
        header.onSelect = { [weak self] in self?.activate($0) }
        header.onCloseTab = { [weak self] in self?.closeBuffer(at: $0) }
        header.onZoom = { [weak self] in self?.onToggleZoom?() }
        header.onPreview = { [weak self] in self?.toggleMarkdownPreview() }
        header.onReveal = { [weak self] in
            guard let self, let url = self.active?.url else { return }
            self.opener.open(url)
        }
        header.revealMenu = { [weak self] in
            guard let self, let buffer = self.active, let url = buffer.url else { return nil }
            let menu = self.opener.menu(for: url)
            if let reveal = self.onRevealInFiles, !buffer.document.isVirtual {
                menu.insertItem(ClosureMenuItem("Reveal in Files") { reveal(url) }, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
            return menu
        }
        header.onClose = { [weak self] in self?.requestClose() }
        opener.$current
            .sink { header.setRevealTitle(OpenWith.openTitle($0)) }
            .store(in: &cancellables)

        let font = Self.font
        lineHeight = EditorLineHeight(font: font, multiple: Settings.shared.editorLineHeight)
        // TextKit 1 on purpose: the gutter walks the layout manager's line
        // fragments, and the line height is its delegate's.
        let layout = NSLayoutManager()
        // Only what is on screen gets laid out: a 4 MB file took 1.8 s to open
        // with the whole of it laid out first.
        layout.allowsNonContiguousLayout = true
        layout.delegate = lineHeight
        self.layout = layout
        emptyStorage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.host = self
        textView.theme = theme
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        for off in [
            \NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled,
            \.isAutomaticTextReplacementEnabled, \.isAutomaticSpellingCorrectionEnabled, \.isContinuousSpellCheckingEnabled,
            \.isGrammarCheckingEnabled, \.isAutomaticLinkDetectionEnabled, \.isAutomaticDataDetectionEnabled,
            \.isAutomaticTextCompletionEnabled, \.smartInsertDeleteEnabled,
        ] {
            // Grammar checking was left on: it underlined prose in red.
            textView[keyPath: off] = false
        }
        textView.font = font
        textView.textColor = theme.text
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.info
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No .width autoresizing while code scrolls sideways: a sideways-
        // scrolling text view sizes itself to its text; tracking the clip
        // view's width left it scrolled into the middle of the document.
        textView.autoresizingMask = []
        textView.delegate = self
        textView.setAccessibilityIdentifier("editorText")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        let gutter = EditorGutter(textView: textView)
        gutter.theme = theme
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .sink { [weak self] _ in self?.didScroll() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scrollView)
            .sink { [weak self] _ in self?.didScroll() }
            .store(in: &cancellables)

        let breadcrumb = EditorBreadcrumbView(background: theme.background, text: theme.text)
        breadcrumb.onClick = { [weak self] in self?.goToSymbol() }
        let statusBar = EditorStatusBar(background: chrome.stripNS, text: theme.text)
        statusBar.onProblems = { [weak self] in self?.goToProblem(forward: true) }

        let preview = MarkdownPreviewView(theme: theme)
        preview.isHidden = true
        preview.onOpenFile = { [weak self] url in self?.open(url) }

        let consoleHost = NSHostingView(rootView: AnyView(EmptyView()))
        consoleHost.sizingOptions = []
        consoleHost.clipsToBounds = true

        let requestHost = NSHostingView(rootView: AnyView(EmptyView()))
        requestHost.isHidden = true
        // The view sizes to the pane, never the pane to it.
        requestHost.sizingOptions = []

        let diskBar = EditorDiskBar(theme: theme)
        diskBar.isHidden = true
        diskBar.onReload = { [weak self] in
            guard let self, let buffer = self.active else { return }
            self.reloadFromDisk(buffer)
            self.updateDiskBar()
        }
        diskBar.onKeep = { [weak self] in
            guard let self, let buffer = self.active else { return }
            buffer.keptDiskVersion = buffer.document.diskModification
            self.updateDiskBar()
        }

        let message = NSTextField(labelWithString: "")
        message.textColor = theme.text.withAlphaComponent(0.6)
        message.alignment = .center
        message.isHidden = true

        for view in [header, breadcrumb, diskBar, scrollView, preview, requestHost, consoleHost, statusBar, message] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: embedded ? 0 : 34),
            breadcrumb.topAnchor.constraint(equalTo: header.bottomAnchor),
            breadcrumb.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            breadcrumb.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            breadcrumb.heightAnchor.constraint(equalToConstant: embedded ? 0 : 26),
            diskBar.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor),
            diskBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            diskBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: diskBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: consoleHost.topAnchor),
            consoleHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            consoleHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            consoleHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            preview.topAnchor.constraint(equalTo: scrollView.topAnchor),
            preview.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            requestHost.topAnchor.constraint(equalTo: scrollView.topAnchor),
            requestHost.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            requestHost.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            requestHost.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            message.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32),
        ])
        if embedded {
            header.isHidden = true
            breadcrumb.isHidden = true
        }
        self.textView = textView
        self.gutter = gutter
        self.scrollView = scrollView
        self.header = header
        self.diskBar = diskBar
        diskBarHeight = diskBar.heightAnchor.constraint(equalToConstant: 0)
        diskBarHeight.isActive = true
        self.breadcrumb = breadcrumb
        self.statusBar = statusBar
        self.consoleHost = consoleHost
        consoleHeight = consoleHost.heightAnchor.constraint(equalToConstant: 0)
        consoleHeight.isActive = true
        self.preview = preview
        self.requestHost = requestHost
        self.messageLabel = message
        view = root
        header.setZoomed(isZoomed)
        observeDiagnostics()
        for hook in Self.hooks.didLoad { hook(self) }
        applySettings()
        refreshChrome()
    }

    /// The storage the layout manager holds while no file is open.
    private let emptyStorage = NSTextStorage()

    // MARK: Opening and closing files

    /// Opens `url` in a tab of its own, or shows the tab it has.
    package func open(_ url: URL, then done: @escaping (Bool) -> Void = { _ in }) {
        _ = view
        // A cluster object's YAML is no file: its buffer, wherever it shows.
        if let resource = Self.hooks.resourceAt.firstAnswer({ $0(url) }) {
            adopt(resource.buffer)
            return done(true)
        }
        // Only iCloud's placeholder is here: fetched first, then opened.
        if let notes = Self.notes, notes.opensLater(url, in: self, then: done) { return }
        let key = url.standardizedFileURL.resolvingSymlinksInPath()
        if let index = buffers.firstIndex(where: { $0.url?.standardizedFileURL.resolvingSymlinksInPath() == key }) {
            activate(index)
            done(true)
            return
        }
        let buffer = EditorBuffer()
        buffer.relay.editors.add(self)
        buffer.load(url, attributes: baseAttributes)
        Self.notes?.attach(buffer, in: self)
        for hook in Self.hooks.attach { hook(self, buffer) }
        // A new tab goes after the one showing, as Zed's.
        let index = activeIndex >= 0 ? activeIndex + 1 : buffers.count
        buffers.insert(buffer, at: index)
        activate(index, recordHistory: true)
        bufferDidOpen(buffer)
        done(true)
    }

    /// Whether this editor is on screen — the window's says: its pane open,
    /// no page over it, the window not hidden or minimised. A cluster
    /// object's YAML in the active tab is followed only then (reads only
    /// while shown); the embedded one's follow is the page's.
    package var isOnScreen = true {
        didSet { if isOnScreen != oldValue { updateResourceWatch() } }
    }
    /// The resource this editor follows now: its active tab's, while on screen.
    package private(set) weak var watching: (any EditorResource)?

    private func updateResourceWatch(none: Bool = false) {
        let wanted = embedded || none || !isOnScreen ? nil : active?.resourcePart
        guard wanted !== watching else { return }
        watching?.unwatch(by: self)
        watching = wanted
        wanted?.watch(by: self)
    }

    /// The window closes: every cluster object's YAML let go — nothing
    /// followed or held for an editor that is gone (edits stay with the
    /// registry, which the quit asks about).
    package func releaseResources() {
        updateResourceWatch(none: true)
        for buffer in buffers {
            guard let resource = buffer.resourcePart else { continue }
            buffer.relay.editors.remove(self)
            if !embedded { resource.release(by: self) }
        }
        let count = buffers.count
        buffers.removeAll { $0.resourcePart != nil }
        guard buffers.count != count else { return }
        // The window is going: nothing shows any more.
        activeIndex = -1
        attach(emptyStorage)
    }

    /// A buffer made elsewhere — a cluster object's YAML, which the
    /// Kubernetes detail shows too — in a tab of its own, or the tab it has.
    /// The same buffer, not a copy: its edits are the same edits.
    package func adopt(_ buffer: EditorBuffer) {
        _ = view
        if let index = buffers.firstIndex(where: { $0 === buffer }) {
            activate(index)
            return
        }
        buffer.relay.editors.add(self)
        if !embedded { buffer.resourcePart?.hold(by: self) }
        let index = activeIndex >= 0 ? activeIndex + 1 : buffers.count
        buffers.insert(buffer, at: index)
        activate(index, recordHistory: !embedded)
    }

    /// The embedded editor's one buffer: `buffer`, the one before let go
    /// (not closed — the resource keeps it).
    package func showOnly(_ buffer: EditorBuffer?) {
        _ = view
        if let buffer, buffers.count == 1, buffers[0] === buffer {
            if activeIndex != 0 { activate(0) }
            // The window's editor may have answered for it since.
            for hook in Self.hooks.rebind { hook(self, buffer, false) }
            return
        }
        if buffer == nil, buffers.isEmpty { return }
        if let current = active {
            vim?.reset()
            textView.breakUndoCoalescing()
            current.selection = textView.selectedRanges.map(\.rangeValue)
            current.scroll = scrollView.contentView.bounds.origin
        }
        for old in buffers { old.relay.editors.remove(self) }
        buffers = []
        activeIndex = -1
        guard let buffer else {
            attach(emptyStorage)
            hideTransientUI()
            for hook in Self.hooks.show { hook(self, nil) }
            refreshChrome()
            return
        }
        buffer.relay.editors.add(self)
        buffers = [buffer]
        activate(0)
    }

    /// The text view's layout manager on `storage`. Not
    /// `replaceTextStorage`, which moves every layout manager sharing the
    /// old storage — another editor showing the same buffer would follow.
    private func attach(_ storage: NSTextStorage) {
        guard let layout, layout.textStorage !== storage else { return }
        isSwapping = true
        layout.textStorage?.removeLayoutManager(layout)
        storage.addLayoutManager(layout)
        isSwapping = false
    }

    /// The relay's: an edit of `buffer`, from whichever editor made it.
    package func storageEdited(_ buffer: EditorBuffer) {
        if buffer === active { editedElsewhere = true }
        scheduleFlush()
    }

    /// The active buffer was edited, perhaps by another editor showing it:
    /// the gutter counts its lines again at the flush.
    private var editedElsewhere = false

    /// A buffer's whole text replaced from outside (a cluster object
    /// followed): every editor showing it keeps its caret where it can.
    package static func replaceWhole(_ buffer: EditorBuffer, with text: String) {
        let editors = buffer.relay.editors.allObjects
        let attributes = editors.first(where: \.isViewLoaded)?.baseAttributes ?? [.font: font]
        let carets = editors.map { $0.isViewLoaded && $0.active === buffer ? $0.textView.selectedRange() : nil }
        buffer.setText(text, attributes: attributes)
        let length = buffer.storage.length
        buffer.selection = buffer.selection.map { NSRange(location: min($0.location, length), length: 0) }
        for (editor, caret) in zip(editors, carets) {
            guard let caret else { continue }
            editor.settingSelection = true
            editor.textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
            editor.settingSelection = false
            editor.gutter.textDidChange()
            editor.paintVisible()
            editor.refreshChrome()
        }
    }

    /// Shows the buffer at `index`, keeping where you were in the last one.
    package func activate(_ index: Int, recordHistory: Bool = false) {
        guard buffers.indices.contains(index), textView.layoutManager != nil else { return }
        if recordHistory { recordPosition() }
        hideTransientUI()
        // The text view's typing in progress belongs to the file it was in:
        // carried over, it extended an undo action in the other file.
        textView.breakUndoCoalescing()
        if let current = active {
            // Vim's open transaction (an insert, say) ends in the file it was
            // in: ended after the switch, it closed the next file's undo group
            // and left this one's open — undo there then raised.
            vim?.reset()
            current.selection = textView.selectedRanges.map(\.rangeValue)
            current.scroll = scrollView.contentView.bounds.origin
        }
        activeIndex = index
        let buffer = buffers[index]
        attach(buffer.storage)
        updateResourceWatch()
        for hook in Self.hooks.rebind { hook(self, buffer, true) }
        applyWrap()
        Self.notes?.activated(buffer, in: self)
        for hook in Self.hooks.show { hook(self, buffer) }
        let unavailable = buffer.document.unavailable
        messageLabel.stringValue = unavailable ?? ""
        messageLabel.isHidden = unavailable == nil
        scrollView.isHidden = unavailable != nil
        updatePreview()
        textView.indentWidth = buffer.usesTabs ? Settings.shared.editorTabSize : buffer.indentWidth
        textView.tabWidth = Settings.shared.editorTabSize
        gutter.textDidChange()
        textView.minSize = scrollView.contentSize
        textView.sizeToFit()
        let length = buffer.storage.length
        let selection = buffer.selection.map { NSRange(location: min($0.location, length), length: min($0.length, length - min($0.location, length))) }
        settingSelection = true
        textView.selectedRanges = selection.map { NSValue(range: $0) }
        settingSelection = false
        if let scroll = buffer.scroll {
            scrollView.contentView.scroll(to: scroll)
        } else {
            // The ruler floats over the clip view (macOS 14+), which makes
            // room with a content inset as wide as the gutter: the top-left is
            // minus that inset. Scrolled to .zero, the gutter covered the
            // first characters of every line.
            let insets = scrollView.contentView.contentInsets
            scrollView.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.diagnostics = buffer.diagnostics
        updateProblemLines()
        gutter.gitMarks = buffer.gitMarks
        observeDocument(buffer)
        vim?.reset()
        updateVimChrome()
        paintVisible()
        refreshChrome()
        selectionDidChange()
    }

    private func observeDocument(_ buffer: EditorBuffer) {
        documentObservers = []
        buffer.document.$isDirty.combineLatest(buffer.document.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshChrome() }
            .store(in: &documentObservers)
    }

    /// Closes the file at `index`, asking first if it has unsaved edits.
    package func closeBuffer(at index: Int, then done: @escaping (Bool) -> Void = { _ in }) {
        guard buffers.indices.contains(index) else { return done(true) }
        if index != activeIndex { activate(index) }
        confirmDiscard(buffers[index]) { [weak self] proceed in
            guard proceed, let self else { return done(false) }
            self.removeBuffer(at: index)
            done(true)
        }
    }

    package func removeBuffer(at index: Int) {
        let buffer = buffers[index]
        if buffer === active {
            vim?.reset()
            textView.breakUndoCoalescing()
        }
        // A cluster object's YAML is the resource's, not this tab's: let go, never closed here.
        if let resource = buffer.resourcePart {
            buffer.relay.editors.remove(self)
            buffers.remove(at: index)
            if !embedded {
                if watching === resource { updateResourceWatch(none: true) }
                resource.release(by: self)
            }
            return afterRemoving(at: index)
        }
        bufferWillClose(buffer)
        Self.notes?.closing(buffer, in: self)
        // A cluster object's copy goes with its tab.
        buffer.manifestPart?.close()
        // Read first: closing the document forgets its URL.
        let closed = buffer.url
        buffer.document.close()
        // A new request closed unsaved is gone, as Postman's tab is.
        for hook in Self.hooks.closed { hook(self, buffer) }
        buffer.relay.editors.remove(self)
        buffers.remove(at: index)
        if let closed { onBufferClosed?(closed) }
        afterRemoving(at: index)
    }

    private func afterRemoving(at index: Int) {
        if buffers.isEmpty {
            activeIndex = -1
            attach(emptyStorage)
            hideTransientUI()
            for hook in Self.hooks.show { hook(self, nil) }
            updatePreview()
            refreshChrome()
            onClose?()
            return
        }
        activeIndex = -1
        activate(min(index, buffers.count - 1))
    }

    /// A file (or a folder holding files) open here was renamed: its tabs
    /// follow it, edits and all.
    package func filesMoved(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for buffer in buffers {
            guard let url = buffer.url?.standardizedFileURL, url.path == oldPath || url.path.hasPrefix(oldPath + "/") else { continue }
            bufferWillClose(buffer)
            buffer.document.moved(to: URL(fileURLWithPath: new.standardizedFileURL.path + url.path.dropFirst(oldPath.count)))
            bufferDidOpen(buffer)
        }
        refreshChrome()
    }

    /// Files gone (moved to the Trash): their tabs close, whatever they held.
    package func filesRemoved(at removed: URL) {
        let path = removed.standardizedFileURL.path
        while let index = buffers.firstIndex(where: {
            guard let url = $0.url?.standardizedFileURL.path else { return false }
            return url == path || url.hasPrefix(path + "/")
        }) {
            removeBuffer(at: index)
        }
    }

    /// The header's ✕: every file, asking about each with edits.
    package func requestClose() {
        closeAll { [weak self] closed in
            if closed { self?.onClose?() }
        }
    }

    private func closeAll(_ done: @escaping (Bool) -> Void) {
        guard let last = buffers.indices.last else { return done(true) }
        closeBuffer(at: last) { [weak self] closed in
            guard closed, let self else { return done(false) }
            self.buffers.isEmpty ? done(true) : self.closeAll(done)
        }
    }

    /// Selects line `line` (1-based) and scrolls it to the middle.
    package func go(toLine line: Int, column: Int = 1) {
        _ = view
        let text = textView.string as NSString
        let starts = LineIndex.starts(of: text)
        guard line >= 1, line <= starts.count else { return }
        let start = starts[line - 1]
        let end = line < starts.count ? starts[line] - 1 : text.length
        let range: NSRange
        if column > 1 {
            range = NSRange(location: min(start + column - 1, end), length: 0)
        } else {
            range = NSRange(location: start, length: max(0, end - start))
        }
        reveal(range)
    }

    /// Selects `range` and centres it on screen.
    package func reveal(_ range: NSRange, flash: Bool = true) {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if let layout = textView.layoutManager, let container = textView.textContainer {
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let visible = scrollView.contentView.bounds
            let y = max(-scrollView.contentView.contentInsets.top, rect.midY - visible.height / 2)
            scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if flash, range.length > 0 { textView.showFindIndicator(for: range) }
    }

    /// The selected line (1-based), for tests.
    package var selectedLine: Int {
        // The text view exists once the view is loaded; before any file was
        // opened it isn't, and reading it trapped.
        _ = view
        return LineIndex.line(of: textView.selectedRange().location, in: LineIndex.starts(of: textView.string as NSString))
    }

    /// An agent may have rewritten a file: pick that up unless you have
    /// edits of your own — then the bar over the file asks (Reload, Keep
    /// Mine). `root`: only the files under it (the checkout a watcher saw
    /// change); nil, every open file (the window became key).
    package func reloadIfChangedOnDisk(under root: URL? = nil) {
        let prefix = root.map { $0.standardizedFileURL.path }
        for buffer in buffers {
            guard let url = buffer.url, !buffer.document.isVirtual else { continue }
            if let prefix, FileTreeMarks.relative(url.standardizedFileURL.path, to: prefix) == nil { continue }
            guard buffer.document.changedOnDisk, !buffer.document.isDirty else { continue }
            reloadFromDisk(buffer)
        }
        updateDiskBar()
    }

    /// `buffer` as the disk has it now, its edits (if any) dropped.
    package func reloadFromDisk(_ buffer: EditorBuffer) {
        guard let url = buffer.url, !buffer.document.isVirtual else { return }
        let isActive = buffer === active
        let selection = isActive ? textView.selectedRange() : buffer.selection.first ?? NSRange(location: 0, length: 0)
        buffer.document.load(url)
        buffer.keptDiskVersion = nil
        buffer.setText(buffer.document.text, attributes: baseAttributes)
        buffer.requestPart?.textChanged(buffer.storage.string)
        Self.notes?.textChanged(buffer, in: self)
        buffer.selection = [NSRange(location: min(selection.location, buffer.storage.length), length: 0)]
        bufferDidReload(buffer)
        if isActive {
            textView.setSelectedRange(buffer.selection[0])
            gutter.textDidChange()
            paintVisible()
            updatePreview()
        }
    }

    /// Whether the active file has edits here and a newer version on disk
    /// nobody chose to keep yours over.
    package var showsDiskConflict: Bool {
        guard let buffer = active, buffer.url != nil, !buffer.document.isVirtual, buffer.document.isDirty, buffer.document.changedOnDisk
        else { return false }
        return buffer.keptDiskVersion == nil || buffer.keptDiskVersion != buffer.document.diskModification
    }

    package func updateDiskBar() {
        guard isViewLoaded, !embedded else { return }
        let show = showsDiskConflict
        if show, let name = active?.name { diskBar.show(name: name) }
        guard diskBar.isHidden == show else { return }
        diskBar.isHidden = !show
        diskBarHeight.constant = show ? EditorDiskBar.height : 0
    }

    package func focus() {
        view.window?.makeFirstResponder(textView)
    }

    // MARK: Text and its colours

    /// Settings ▸ Editor's family and size.
    package static var font: NSFont {
        let size = CGFloat(Settings.shared.editorFontSize)
        let family = Settings.shared.editorFontFamily
        if !family.isEmpty, let font = NSFont(name: family, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    package var baseAttributes: [NSAttributedString.Key: Any] {
        // The editor's font as Settings set it — not `textView.font`, which
        // is the first character's: a note opening on a Live Preview
        // heading made every line a heading's size.
        let font = lineHeight?.font ?? Self.font
        let paragraph = NSMutableParagraphStyle()
        let space = ("m" as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = space * CGFloat(Settings.shared.editorTabSize)
        paragraph.tabStops = []
        return [.font: font, .foregroundColor: theme.text, .paragraphStyle: paragraph]
    }

    /// Settings changed: the editor takes whichever were its.
    /// One Dark / One Light, or the terminal theme's colours (Settings ▸
    /// Editor ▸ Colours).
    package static func makeTheme(background: NSColor = GhosttyRuntime.shared.backgroundColor) -> EditorTheme {
        guard Settings.shared.string("editor.theme") == "terminal" else { return EditorTheme(background: background, terminal: nil) }
        let runtime = GhosttyRuntime.shared
        let ansi = (0...15).compactMap { runtime.paletteColor($0) }
        return EditorTheme(background: background, terminal: .init(foreground: runtime.foregroundColor, ansi: ansi))
    }

    package func applySettings(_ keys: Set<String>? = nil) {
        guard isViewLoaded else { return }
        if keys?.contains("editor.theme") == true { applyTerminalColors() }
        let font = Self.font
        let fontChanged = textView.font != font || lineHeight.multiple != Settings.shared.editorLineHeight
        textView.font = font
        lineHeight.font = font
        lineHeight.multiple = Settings.shared.editorLineHeight
        textView.showsIndentGuides = Settings.shared.editorIndentGuides
        gutter.relativeNumbers = Settings.shared.editorRelativeLineNumbers
        if Settings.shared.editorVimMode, vim == nil {
            startVim()
        } else if !Settings.shared.editorVimMode, vim != nil {
            stopVim()
        }
        if fontChanged || keys?.contains("editor.tabSize") == true {
            let attributes = baseAttributes
            for buffer in buffers {
                buffer.storage.beginEditing()
                buffer.storage.setAttributes(attributes, range: NSRange(location: 0, length: buffer.storage.length))
                buffer.storage.endEditing()
                buffer.painted = IndexSet()
            }
            textView.typingAttributes = attributes
            textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0), actualCharacterRange: nil)
            gutter.updateThickness()
            paintVisible()
        }
        applyWrap()
        if keys?.contains("editor.languageServers") == true { languageServersSettingChanged() }
        if keys?.contains("editor.gitGutter") == true { buffers.forEach { refreshGitBase($0) } }
        gutter.needsDisplay = true
    }

    /// The size changed in Settings (the window's old entry point).
    package func applyFontSize() { applySettings(["editor.fontSize"]) }

    /// The pane is painted from the terminal's colours as well, so a theme
    /// picked in Settings ▸ Themes reaches it where it stands — the text
    /// and its syntax, the gutter, the header, the breadcrumb, the status
    /// bar — as the chrome around it does (`ChromeTheme`, which is the same
    /// object and has already been recomputed). What is made on demand (a
    /// completion list, a problems popover) is made from the new colours
    /// the next time it is asked for.
    package func applyTerminalColors() {
        guard isViewLoaded else { return }
        theme = Self.makeTheme()
        textView.theme = theme
        textView.backgroundColor = theme.background
        textView.textColor = theme.text
        textView.insertionPointColor = theme.info
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        scrollView.backgroundColor = theme.background
        gutter.theme = theme
        Self.notes?.themeChanged(dark: theme.isDark, in: self)
        header.recolor(background: chrome.stripNS, text: theme.text, accent: theme.info)
        breadcrumb.recolor(background: theme.background, text: theme.text)
        statusBar.recolor(background: chrome.stripNS, text: theme.text)
        preview.theme = theme
        if Self.notes?.invalidateReader(in: self) == true { updatePreview() }
        messageLabel.textColor = theme.text.withAlphaComponent(0.6)
        // The syntax colours are the theme's: every buffer is painted again.
        let attributes = baseAttributes
        for buffer in buffers {
            buffer.storage.beginEditing()
            buffer.storage.setAttributes(attributes, range: NSRange(location: 0, length: buffer.storage.length))
            buffer.storage.endEditing()
            buffer.painted = IndexSet()
        }
        textView.typingAttributes = attributes
        paintVisible()
        gutter.needsDisplay = true
    }

    /// Wraps long lines at the pane's edge, or lets code scroll sideways.
    package func applyWrap() {
        guard let container = textView.textContainer else { return }
        let wrap: Bool
        switch Settings.shared.editorSoftWrap {
        case "always": wrap = true
        case "none": wrap = false
        default:
            let ext = active?.url?.pathExtension.lowercased() ?? ""
            wrap = active?.language?.id == "markdown" || ["txt", "text", "rst", "adoc", "org", ""].contains(ext)
        }
        let wrapping = active?.wrapOverride ?? wrap
        guard container.widthTracksTextView != wrapping || textView.isHorizontallyResizable == wrapping else { return }
        if wrapping {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            textView.frame.size.width = scrollView.contentSize.width
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            scrollView.hasHorizontalScroller = true
        }
        textView.sizeToFit()
        gutter.needsDisplay = true
    }

    /// The parser hears of a burst of edits once, after the run loop pass
    /// that made them, and the screen's colours follow.
    package func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushScheduled = false
                for buffer in self.buffers { buffer.flushEdits() }
                if self.editedElsewhere {
                    self.editedElsewhere = false
                    self.gutter.textDidChange()
                }
                self.paintVisible()
            }
        }
    }

    package func textDidChange(_ notification: Notification) {
        guard let buffer = active else { return }
        buffer.requestPart?.textChanged(buffer.storage.string)
        Self.notes?.textChanged(buffer, in: self)
        if buffer.showsPreview, buffer.requestPart == nil, buffer.drawingPart == nil { schedulePreview() }
        buffer.document.markEdited()
        gutter.textDidChange()
        bufferDidChange(buffer)
        scheduleGitMarks(buffer)
    }

    /// The characters on screen, and a screen's worth either side: scrolling
    /// a little finds them coloured already.
    private var paintRange: NSRange {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return NSRange(location: 0, length: 0) }
        let visible = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: textView.visibleRect, in: container), actualGlyphRange: nil)
        let text = textView.string as NSString
        let margin = max(visible.length, 2000)
        let start = max(0, visible.location - margin)
        let end = min(text.length, NSMaxRange(visible) + margin)
        let lines = text.lineRange(for: NSRange(location: start, length: end - start))
        return lines
    }

    package func didScroll() {
        gutter.needsDisplay = true
        paintVisible()
    }

    /// Asks for the colours of what is on screen, unless it has them.
    package func paintVisible() {
        guard let buffer = active, let syntax = buffer.syntax, isViewLoaded else { return }
        let range = paintRange
        guard range.length > 0, !buffer.painted.contains(integersIn: range.location..<NSMaxRange(range)) else { return }
        let version = buffer.version
        syntax.highlights(in: range) { [weak self, weak buffer] parsed, spans in
            MainActor.assumeIsolated {
                // Spans for an older text land in the wrong places: a newer
                // request is already queued behind the edit that made it.
                guard let self, let buffer, parsed == buffer.version, version == buffer.version else { return }
                self.paint(spans, over: range, in: buffer)
            }
        }
    }

    private func paint(_ spans: [SyntaxDocument.Span], over range: NSRange, in buffer: EditorBuffer) {
        // Don't recolour under an IME's composition: it owns those attributes.
        if buffer === active, textView.hasMarkedText() { return }
        let storage = buffer.storage
        guard NSMaxRange(range) <= storage.length else { return }
        let base = baseAttributes
        let font = base[.font] as? NSFont ?? Self.font
        let manager = NSFontManager.shared
        let bold = manager.convert(font, toHaveTrait: .boldFontMask)
        let italic = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)
        var styles: [String: EditorTheme.Style?] = [:]
        let selection = textView.selectedRanges
        // Styled aside, then only what changed written back (`write`): the
        // range reaches a screen above the caret, and every run set again
        // there is laid out again.
        let styled = NSMutableAttributedString(string: (storage.string as NSString).substring(with: range), attributes: base)
        for span in spans {
            let clipped = NSIntersectionRange(span.range, range)
            guard clipped.length > 0 else { continue }
            let style: EditorTheme.Style?
            if let cached = styles[span.capture] {
                style = cached
            } else {
                style = theme.style(for: span.capture)
                styles[span.capture] = style
            }
            guard let style else { continue }
            let local = NSRange(location: clipped.location - range.location, length: clipped.length)
            styled.addAttribute(.foregroundColor, value: style.color, range: local)
            if style.bold || style.italic {
                styled.addAttribute(.font, value: style.bold && style.italic ? boldItalic : style.bold ? bold : italic, range: local)
            }
            if style.underline { styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: local) }
            if style.strikethrough { styled.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: local) }
        }
        if buffer.livePreview { Self.notes?.styleLive(styled, at: range.location, in: buffer, editor: self) }
        storage.beginEditing()
        Self.write(styled, at: range.location, into: storage)
        storage.endEditing()
        buffer.painted.insert(integersIn: range.location..<NSMaxRange(range))
        if buffer === active {
            // Recolouring mustn't move the caret or the selection.
            if textView.selectedRanges != selection { textView.selectedRanges = selection }
            // A note's text is typed in the note's own font: typed in the
            // code font, a character showed so until the restyle caught up.
            textView.typingAttributes = buffer.livePreview ? Self.notes?.liveTypingAttributes(in: self) ?? base : base
        }
    }

    // MARK: Markdown preview

    /// ⇧⌘V or the header's eye: the file rendered, or its text again.
    package func toggleMarkdownPreview() {
        guard let buffer = active, buffer.language?.id == "markdown" || buffer.requestPart != nil || buffer.isNote || buffer.drawingPart != nil else { return }
        buffer.showsPreview.toggle()
        updatePreview()
        if !buffer.showsPreview { focus() }
    }

    /// The preview over the text for a markdown file that asks for it;
    /// the header's eye on every markdown file.
    package func updatePreview() {
        guard isViewLoaded else { return }
        let buffer = active
        if let buffer, buffer.drawingPart != nil, buffer.document.unavailable == nil {
            requestHost.isHidden = true
            preview.isHidden = true
            Self.notes?.hideReader(in: self)
            header.setPreview(available: true, showing: buffer.showsPreview)
            Self.notes?.showDrawing(of: buffer.showsPreview ? buffer : nil, in: self)
            return
        }
        Self.notes?.showDrawing(of: nil, in: self)
        if let buffer, buffer.document.unavailable == nil, let request = Self.hooks.requestView.firstAnswer({ $0(self, buffer) }) {
            header.setPreview(available: true, showing: buffer.showsPreview == true, request: true)
            preview.isHidden = true
            Self.notes?.hideReader(in: self)
            let showing = buffer.showsPreview == true
            requestHost.isHidden = !showing
            scrollView.isHidden = showing
            if showing { requestHost.rootView = request }
            return
        }
        requestHost.isHidden = true
        if let buffer, buffer.isNote, buffer.document.unavailable == nil {
            preview.isHidden = true
            header.setPreview(available: true, showing: buffer.showsPreview)
            Self.notes?.showNote(buffer, in: self)
            return
        }
        Self.notes?.hideReader(in: self)
        let isMarkdown = buffer?.language?.id == "markdown" && buffer?.document.unavailable == nil
        let showing = isMarkdown && buffer?.showsPreview == true
        header.setPreview(available: isMarkdown, showing: showing)
        preview.isHidden = !showing
        scrollView.isHidden = showing || buffer?.document.unavailable != nil
        guard showing, let buffer else { return }
        preview.baseURL = buffer.url
        preview.show(buffer.storage.string)
    }

    /// Typing while it shows (an agent rewriting the file, say): the
    /// rendering follows a moment later.
    private func schedulePreview() {
        pendingPreview?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.updatePreview() } }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: Chrome

    package func refreshChrome() {
        guard isViewLoaded else { return }
        header.update(
            buffers.map { .init(name: $0.name, path: $0.url?.path ?? "", dirty: $0.document.isDirty) }, active: activeIndex)
        updateBreadcrumb()
        updateStatus()
        updateDiskBar()
        onActiveChanged?(active?.url)
    }

    package func updateBreadcrumb() {
        guard let url = active?.url else { return breadcrumb.update(path: [], symbol: nil) }
        var parts: [String]
        if let root = workspaceRoot?() ?? Self.gitRoot(of: url), url.path.hasPrefix(root.path + "/") {
            parts = [root.lastPathComponent] + url.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        } else {
            parts = url.pathComponents.suffix(3).map { $0 }
        }
        if parts.count > 6 { parts = [parts[0], "…"] + parts.suffix(4) }
        breadcrumb.update(path: parts, symbol: symbolAtCaret()?.name)
    }

    package func updateStatus() {
        guard isViewLoaded else { return }
        guard let buffer = active else {
            statusBar.update(line: 0, column: 0, selected: 0, cursors: 0)
            statusBar.update(indent: "", language: "", server: nil)
            statusBar.update(errors: 0, warnings: 0)
            return
        }
        let text = textView.string as NSString
        let caret = min(textView.selectedRange().location, text.length)
        let line = LineIndex.line(of: caret, in: gutter.lineStarts)
        let lineStart = gutter.lineStarts[max(0, min(line - 1, gutter.lineStarts.count - 1))]
        // The column as a person counts it: characters, a tab as its width.
        var column = 1
        var i = lineStart
        while i < caret {
            let range = text.rangeOfComposedCharacterSequence(at: i)
            column += text.character(at: i) == 0x09 ? Settings.shared.editorTabSize : 1
            i = NSMaxRange(range)
        }
        let selected = textView.selectedRanges.reduce(0) { $0 + $1.rangeValue.length }
        statusBar.update(line: line, column: column, selected: selected, cursors: textView.selectedRanges.count)
        statusBar.update(
            indent: buffer.usesTabs ? "Tabs" : "Spaces: \(buffer.indentWidth)", language: buffer.language?.name ?? "Plain Text",
            server: serverName(for: buffer))
        let errors = buffer.diagnostics.filter { $0.severity == .error }.count
        let warnings = buffer.diagnostics.filter { $0.severity == .warning }.count
        statusBar.update(errors: errors, warnings: warnings)
    }

    package func updateProblemLines() {
        guard let buffer = active else { return }
        var lines: [Int: EditorDiagnostic.Severity] = [:]
        let starts = gutter.lineStarts
        for diagnostic in buffer.diagnostics {
            let line = LineIndex.line(of: diagnostic.range.location, in: starts) - 1
            lines[line] = min(lines[line] ?? .hint, diagnostic.severity)
        }
        gutter.problemLines = lines
    }

    // MARK: Selection

    package func textViewDidChangeSelection(_ notification: Notification) {
        if !settingSelection, vim?.isSettingSelection == false { vim?.selectionDidChange() }
        occurrenceWholeWord = occurrenceWholeWord && textView.selectedRanges.count > 1
        selectionDidChange()
    }

    package func selectionDidChange() {
        guard isViewLoaded else { return }
        Self.notes?.selectionChanged(in: self)
        updateStatus()
        updateCompletionForSelection()
        gutter.needsDisplay = true
        // Brackets, matching words and the breadcrumb wait for the caret to rest.
        pendingSelectionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateBracketPair()
                self.updateWordHighlights()
                self.updateBreadcrumb()
            }
        }
        pendingSelectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func updateBracketPair() {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0, textView.selectedRanges.count == 1,
            let match = EditCommands.matchingBracket(at: selection.location, in: text)
        else { return textView.bracketPair = [] }
        textView.bracketPair = [NSRange(location: match.bracket, length: 1), NSRange(location: match.partner, length: 1)]
    }

    /// The word at the caret, everywhere on screen — Zed's shading.
    private func updateWordHighlights() {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        guard selection.length == 0, textView.selectedRanges.count == 1, text.length > 0,
            let word = Self.wordRange(at: selection.location, in: text), word.length >= 2
        else { return textView.wordHighlights = [] }
        let needle = text.substring(with: word)
        let range = paintRange
        var found: [NSRange] = []
        var search = range
        while found.count < 200 {
            let hit = text.range(of: needle, options: [.literal], range: search)
            guard hit.location != NSNotFound else { break }
            let before = hit.location > 0 ? text.character(at: hit.location - 1) : 0x20
            let after = NSMaxRange(hit) < text.length ? text.character(at: NSMaxRange(hit)) : 0x20
            if !Self.isWordUnit(before), !Self.isWordUnit(after), hit != word { found.append(hit) }
            search = NSRange(location: NSMaxRange(hit), length: NSMaxRange(range) - NSMaxRange(hit))
            if search.length <= 0 { break }
        }
        textView.wordHighlights = found.isEmpty ? [] : found + [word]
    }

    package static func isWordUnit(_ c: unichar) -> Bool {
        c == 0x5F || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c > 0x7F
    }

    /// The identifier at (or just before) `index`.
    package static func wordRange(at index: Int, in text: NSString) -> NSRange? {
        var start = min(index, text.length)
        var end = start
        while start > 0, isWordUnit(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWordUnit(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: Undo

    package func undoManager(for view: NSTextView) -> UndoManager? { active?.undo }

    // MARK: Saving

    @objc package func saveDocument(_ sender: Any?) {
        guard let buffer = active else { return }
        save(buffer, overwriting: false)
    }

    package func save(_ buffer: EditorBuffer, overwriting: Bool, formatted: Bool = false) {
        // Overterm's copy of a cluster object: never written, never formatted (its text never leaves).
        if let why = buffer.document.unsaveable {
            buffer.manifestPart?.say(why)
            return
        }
        // A new request: saving it is naming it and putting it in its collection.
        if Self.hooks.draft.contains(where: { $0(self, buffer, nil) }) { return }
        // A Terraform file: terraform fmt, only where the checkout already passes fmt -check — never the server's formatter.
        let own =
            formatted
            ? nil
            : Self.hooks.saveFormat.firstAnswer({ hook in
                hook(self, buffer) { [weak self] in self?.save(buffer, overwriting: overwriting, formatted: true) }
            })
        if own == .formatting {
            return
        } else if own == nil, !formatted, Settings.shared.editorFormatOnSave, Settings.shared.editorLanguageServers {
            formatDocument(buffer) { [weak self] in self?.save(buffer, overwriting: overwriting, formatted: true) }
            return
        }
        do {
            try buffer.document.save(buffer.storage.string, overwriting: overwriting)
            bufferDidSave(buffer)
            lastSaved = buffer.url
            onSaved?()
            refreshGitBase(buffer)
        } catch is EditorDocument.ChangedOnDisk {
            confirmOverwrite(buffer)
        } catch {
            view.window.map { NSAlert(error: error).beginSheetModal(for: $0) }
        }
    }

    /// Something else wrote the file while it had edits here. Cancel first:
    /// Return keeps both — theirs on disk, yours in the editor.
    private func confirmOverwrite(_ buffer: EditorBuffer) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(buffer.name)” changed on disk"
        alert.informativeText = "Something else saved it since you opened it — an agent, most likely. Saving replaces those changes with yours."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Anyway").keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.save(buffer, overwriting: true, formatted: true)
        }
    }

    /// Unsaved edits: Save, Don't Save, or Cancel. `proceed` is false only
    /// for Cancel (or a failed save).
    private func confirmDiscard(_ buffer: EditorBuffer, _ proceed: @escaping (Bool) -> Void) {
        // A console's rows edited and not saved: asked about first, then the file.
        if let console = buffer.consolePart, console.unsavedEdits() > 0, let window = view.window {
            Task { @MainActor [weak self] in
                guard await type(of: console).askDiscardRowEdits(console.unsavedEdits(), on: window) else { return proceed(false) }
                console.discardAllEdits()
                guard let self else { return proceed(true) }
                self.confirmDiscard(buffer, proceed)
            }
            return
        }
        if let resource = buffer.resourcePart {
            guard resource.isEdited, let window = view.window else { return proceed(true) }
            let alert = NSAlert()
            alert.messageText = "Discard your edits to \(resource.spoken)?"
            alert.informativeText =
                "A cluster object's YAML is never saved: Overterm keeps no copy of it on disk. Apply it first, or discard the edits — the YAML goes back to what \(resource.contextName) has."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Edits").hasDestructiveAction = true
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { return proceed(false) }
                resource.revert()
                proceed(true)
            }
            return
        }
        guard buffer.document.isDirty, buffer.document.unsaveable == nil, let window = view.window else { return proceed(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(buffer.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                if Self.hooks.draft.contains(where: { $0(self, buffer, proceed) }) { return }
                self.save(buffer, overwriting: false, formatted: true)
                proceed(!buffer.document.isDirty)
            case .alertThirdButtonReturn:
                proceed(true)
            default:
                proceed(false)
            }
        }
    }

    package func hideTransientUI() {
        dismissCompletion()
        hover?.close()
        hover = nil
        picker?.dismiss()
    }
}

extension EditorViewController {
    /// A caret stepping onto a folded heading's hidden lines goes past them (Notes).
    @objc package func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
        toCharacterRanges newSelectedCharRanges: [NSValue]
    ) -> [NSValue] {
        guard newSelectedCharRanges.count == 1, oldSelectedCharRanges.count == 1, let notes = Self.notes, active?.isNote == true else {
            return newSelectedCharRanges
        }
        let moved = notes.caretPastFolds(from: oldSelectedCharRanges[0].rangeValue, to: newSelectedCharRanges[0].rangeValue, in: self)
        return [NSValue(range: moved)]
    }
}
