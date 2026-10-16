import AppKit
import Combine
import WebKit

/// The browser column beside the terminal: the selected terminal tab's
/// browser — toolbar, its pages' tab strip, the page, and its console
/// underneath. Each terminal tab has its own BrowserWorkspace; this shows
/// whichever tab is selected.
@MainActor
final class BrowserViewController: NSViewController, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    /// "Ask an Agent About This Page".
    var onAskAgent: ((BrowserSession) -> Void)?
    var onOpenExternally: ((URL) -> Void)?
    /// The selected tab's browser, made if it has none (the empty state's
    /// buttons, the address bar, ⌘T).
    var makeWorkspace: (() -> BrowserWorkspace?)?

    let chrome: ChromeTheme
    let theme: EditorTheme
    private(set) var workspace: BrowserWorkspace?
    /// The page showing: the workspace's active one.
    private(set) var session: BrowserSession?
    private var observers: Set<AnyCancellable> = []
    private var workspaceObserver: AnyCancellable?
    private var ports: [ListeningPort] = []
    private(set) lazy var strip = BrowserTabStrip(theme: theme, chrome: chrome)

    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private(set) var address = NSTextField()
    private let progress = NSView()
    private var progressWidth: NSLayoutConstraint!
    private let page = NSView()
    private let empty = NSStackView()
    private let consoleButton = NSButton()
    private let consolePanel = NSScrollView()
    private let consoleText = NSTextView()
    private var consoleHeight: NSLayoutConstraint!
    private(set) var isConsoleOpen = false
    private(set) var zoomButton = NSButton()

    init(chrome: ChromeTheme, background: NSColor) {
        self.chrome = chrome
        theme = EditorTheme(background: background)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = BrowserRootView(color: theme.background)
        root.onKeyEquivalent = { [weak self] event in self?.handleKey(event) ?? false }
        strip.onSelect = { [weak self] in self?.workspace?.select($0) }
        strip.onClose = { [weak self] in self?.closePage($0) }
        strip.onNew = { [weak self] in self?.newPage() }
        let toolbar = BrowserBackground(color: chrome.stripNS)
        let text = theme.text

        func button(_ button: NSButton, _ symbol: String, _ tip: String, _ action: Selector, id: String) {
            EditorHeaderView.style(button, symbol, tip: tip, color: text, target: self, action: action, size: 12)
            button.identifier = NSUserInterfaceItemIdentifier(id)
        }
        button(back, "chevron.left", "Back", #selector(goBack), id: "browserBack")
        button(forward, "chevron.right", "Forward", #selector(goForward), id: "browserForward")
        button(reload, "arrow.clockwise", "Reload", #selector(reloadOrStop), id: "browserReload")
        let ask = NSButton()
        button(ask, "sparkles", "Ask an Agent About This Page", #selector(askAgent), id: "browserAskAgent")
        let inspect = NSButton()
        button(inspect, "hammer", "Web Inspector", #selector(showInspector), id: "browserInspector")
        let external = NSButton()
        button(external, "safari", "Open in Your Browser", #selector(openExternally), id: "browserExternal")
        button(zoomButton, "arrow.up.left.and.arrow.down.right", "Zoom Browser", #selector(toggleZoom), id: "browserZoom")
        let close = NSButton()
        button(close, "xmark", "Close Browser", #selector(closeBrowser), id: "closeBrowser")

        address.placeholderAttributedString = NSAttributedString(
            string: "Address — localhost:3000, a URL, or a search",
            attributes: [.foregroundColor: text.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 12)])
        address.font = .systemFont(ofSize: 12)
        address.textColor = text
        address.isBordered = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingTail
        address.cell?.isScrollable = true
        address.delegate = self
        address.identifier = NSUserInterfaceItemIdentifier("browserAddress")
        let field = BrowserBackground(color: EditorPicker.surface(theme), radius: 6)
        progress.wantsLayer = true
        progress.layer?.backgroundColor = theme.info.cgColor
        for view in [address, progress] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }

        let views: [NSView] = [back, forward, reload, field, ask, inspect, external, zoomButton, close]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(view)
        }

        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10

        consoleButton.isBordered = false
        consoleButton.target = self
        consoleButton.action = #selector(toggleConsole)
        consoleButton.identifier = NSUserInterfaceItemIdentifier("browserConsoleButton")
        let clear = NSButton()
        EditorHeaderView.style(clear, "trash", tip: "Clear the Console", color: text, target: self, action: #selector(clearConsole), size: 10)
        let strip = BrowserBackground(color: chrome.stripNS)
        for view in [consoleButton, clear] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(view)
        }
        consoleText.isEditable = false
        consoleText.drawsBackground = true
        consoleText.backgroundColor = theme.background
        consoleText.textContainerInset = NSSize(width: 8, height: 6)
        consoleText.isVerticallyResizable = true
        consoleText.autoresizingMask = [.width]
        consoleText.textContainer?.widthTracksTextView = true
        consolePanel.documentView = consoleText
        consolePanel.hasVerticalScroller = true
        consolePanel.autohidesScrollers = true
        consolePanel.drawsBackground = true
        consolePanel.backgroundColor = theme.background

        for view in [toolbar, self.strip, page, empty, consolePanel, strip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
        consoleHeight = consolePanel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),
            back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            forward.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            reload.leadingAnchor.constraint(equalTo: forward.trailingAnchor, constant: 2),
            field.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: ask.leadingAnchor, constant: -6),
            field.heightAnchor.constraint(equalToConstant: 24),
            field.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            address.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 8),
            address.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8),
            address.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            progress.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,
            ask.trailingAnchor.constraint(equalTo: inspect.leadingAnchor, constant: -2),
            inspect.trailingAnchor.constraint(equalTo: external.leadingAnchor, constant: -2),
            external.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -2),
            zoomButton.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            close.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            self.strip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            self.strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            self.strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            self.strip.heightAnchor.constraint(equalToConstant: 30),
            page.topAnchor.constraint(equalTo: self.strip.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: consolePanel.topAnchor),
            empty.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: page.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -40),
            consolePanel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            consolePanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            consolePanel.bottomAnchor.constraint(equalTo: strip.topAnchor),
            consoleHeight,
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: 24),
            consoleButton.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 10),
            consoleButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -10),
            clear.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        for view in [back, forward, reload, ask, inspect, external, zoomButton, close] {
            view.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
            view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        view = root
        show(nil, ports: [])
    }

    // MARK: The tab's browser

    /// Shows `workspace` (the selected tab's browser), or the empty state
    /// with what that tab's servers listen on.
    func show(_ workspace: BrowserWorkspace?, ports: [ListeningPort]) {
        _ = view
        self.ports = ports
        if workspace !== self.workspace {
            self.workspace = workspace
            workspaceObserver = workspace?.changed
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.showActivePage() }
        }
        showActivePage()
    }

    /// The workspace's page that shows, in the page area; the strip redrawn.
    private func showActivePage() {
        strip.update(workspace)
        let session = workspace?.active
        if let current = self.session, current !== session {
            BrowserParking.shared.park(current.webView)
        }
        self.session = session
        observers = []
        page.subviews.forEach { if $0 is WKWebView { $0.removeFromSuperview() } }
        if let session {
            let web = session.webView
            web.removeFromSuperview()
            web.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(web)
            NSLayoutConstraint.activate([
                web.topAnchor.constraint(equalTo: page.topAnchor),
                web.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: page.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            ])
            session.$url.combineLatest(session.$isLoading, session.$canGoBack, session.$canGoForward)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] url, loading, canBack, canForward in self?.updateToolbar(url: url, loading: loading, back: canBack, forward: canForward) }
                .store(in: &observers)
            session.$progress.receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.updateProgress(value) }
                .store(in: &observers)
            session.$console.receive(on: DispatchQueue.main)
                .sink { [weak self] entries in self?.updateConsole(entries) }
                .store(in: &observers)
        } else {
            updateToolbar(url: nil, loading: false, back: false, forward: false)
            updateConsole([])
        }
        let showsEmpty = session?.url == nil
        empty.isHidden = !showsEmpty
        if showsEmpty { fillEmpty(ports: ports) }
    }

    // MARK: Pages

    func newPage(_ url: URL? = nil) {
        guard let workspace = workspace ?? makeWorkspace?() else { return }
        if workspace !== self.workspace { show(workspace, ports: ports) }
        workspace.newPage(url)
        if url == nil { focusAddress() }
    }

    func closePage(_ index: Int) {
        workspace?.close(index)
        if workspace?.pages.isEmpty == true { focusAddress() }
    }

    /// The browser's own keys, while it has the keyboard — Safari's: ⌘T
    /// ⌘W ⌘L ⌘R ⌘[ ⌘] ⌃⇥ ⌃⇧⇥ ⌘1…9. Elsewhere they are the app's.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = view.window, let responder = window.firstResponder as? NSView,
            responder === view || responder.isDescendant(of: view) || (responder as? NSTextView)?.delegate === address
        else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .shift, .option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key, event.keyCode) {
        case ([.command], "t", _): newPage()
        case ([.command], "w", _):
            guard let workspace, !workspace.pages.isEmpty else { return false }
            closePage(workspace.activeIndex)
        case ([.command], "l", _): focusAddress()
        case ([.command], "r", _): session?.reload()
        case ([.command], "[", _): session?.goBack()
        case ([.command], "]", _): session?.goForward()
        case ([.control], _, 48): cyclePage(1)
        case ([.control, .shift], _, 48): cyclePage(-1)
        case ([.command], _, _) where Int(key).map({ (1...9).contains($0) }) == true:
            guard let workspace, let n = Int(key) else { return false }
            workspace.select(n == 9 ? workspace.pages.count - 1 : n - 1)
        default: return false
        }
        return true
    }

    private func cyclePage(_ step: Int) {
        guard let workspace, !workspace.pages.isEmpty else { return }
        workspace.select((workspace.activeIndex + step + workspace.pages.count) % workspace.pages.count)
    }

    private func fillEmpty(ports: [ListeningPort]) {
        empty.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let icon = NSImageView(image: NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        icon.contentTintColor = theme.text.withAlphaComponent(0.35)
        empty.addArrangedSubview(icon)
        let title = NSTextField(labelWithString: ports.isEmpty ? "Type an address above" : "This tab serves")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = theme.text.withAlphaComponent(0.7)
        empty.addArrangedSubview(title)
        for port in ports.prefix(6) {
            guard let url = port.url else { continue }
            let open = NSButton(title: "localhost:\(port.port)  ·  \(port.process)", target: self, action: #selector(openPort(_:)))
            open.bezelStyle = .rounded
            open.identifier = NSUserInterfaceItemIdentifier("browserPort-\(port.port)")
            open.toolTip = url.absoluteString
            open.tag = port.port
            empty.addArrangedSubview(open)
        }
        if ports.isEmpty {
            let hint = NSTextField(labelWithString: "Links to localhost clicked in the terminal open here, and a tab's servers are offered once it runs one.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = theme.text.withAlphaComponent(0.45)
            hint.alignment = .center
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 3
            hint.preferredMaxLayoutWidth = 280
            empty.addArrangedSubview(hint)
        }
    }

    private func updateToolbar(url: URL?, loading: Bool, back canBack: Bool, forward canForward: Bool) {
        if address.currentEditor() == nil { address.stringValue = url?.absoluteString ?? "" }
        back.isEnabled = canBack
        forward.isEnabled = canForward
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        reload.toolTip = loading ? "Stop" : "Reload"
        empty.isHidden = url != nil
    }

    private func updateProgress(_ value: Double) {
        guard let field = progress.superview else { return }
        let done = value >= 1 || session?.isLoading != true
        progressWidth.constant = done ? 0 : field.bounds.width * CGFloat(value)
    }

    private func updateConsole(_ entries: [BrowserSession.ConsoleEntry]) {
        let errors = entries.filter { $0.level == "error" }.count
        let warnings = entries.filter { $0.level == "warn" }.count
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func add(_ text: String, _ color: NSColor) { title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])) }
        add(isConsoleOpen ? "▾ Console" : "▸ Console", theme.text.withAlphaComponent(0.6))
        if errors > 0 { add("   ✕ \(errors)", theme.error) }
        if warnings > 0 { add("   ⚠ \(warnings)", theme.warning) }
        if errors == 0, warnings == 0 { add("   \(entries.count) logged", theme.text.withAlphaComponent(0.45)) }
        consoleButton.attributedTitle = title
        consoleButton.setAccessibilityLabel("Console: \(errors) errors, \(warnings) warnings")
        guard isConsoleOpen else { return }
        let text = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        for entry in entries.suffix(300) {
            let color = entry.level == "error" ? theme.error : entry.level == "warn" ? theme.warning : theme.text.withAlphaComponent(0.8)
            text.append(
                NSAttributedString(string: "\(entry.level.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \(entry.message)\n", attributes: [.font: mono, .foregroundColor: color]))
        }
        consoleText.textStorage?.setAttributedString(text)
        consoleText.scrollToEndOfDocument(nil)
    }

    func setZoomed(_ zoomed: Bool) {
        let symbol = zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        zoomButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        zoomButton.toolTip = zoomed ? "Give the Terminal Back" : "Zoom Browser"
    }

    func focusAddress() {
        _ = view
        view.window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    // MARK: Actions

    /// Opens `url` in the selected tab's browser (making it).
    func open(_ url: URL) {
        guard let workspace = workspace ?? makeWorkspace?() else { return }
        if workspace !== self.workspace { show(workspace, ports: ports) }
        if let page = workspace.active { page.load(url) } else { workspace.newPage(url) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if let url = BrowserLinks.url(fromTyped: address.stringValue) {
                open(url)
                view.window?.makeFirstResponder(session?.webView)
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            address.stringValue = session?.url?.absoluteString ?? ""
            view.window?.makeFirstResponder(session?.webView)
            return true
        }
        return false
    }

    @objc private func openPort(_ sender: NSButton) {
        guard let url = URL(string: "http://localhost:\(sender.tag)") else { return }
        open(url)
    }

    @objc private func goBack() { session?.goBack() }
    @objc private func goForward() { session?.goForward() }
    @objc private func reloadOrStop() { session?.isLoading == true ? session?.stop() : session?.reload() }
    @objc private func askAgent() { session.map { onAskAgent?($0) } }
    @objc private func toggleZoom() { onToggleZoom?() }
    @objc private func closeBrowser() { onClose?() }

    @objc private func openExternally() {
        guard let url = session?.url else { return }
        onOpenExternally?(url)
    }

    /// Safari's Web Inspector for the page: the private hook WebKit's own
    /// right-click "Inspect Element" uses; without it, that right-click is
    /// the way in.
    @objc func showInspector() {
        guard let web = session?.webView else { return }
        let selector = NSSelectorFromString("_inspector")
        if web.responds(to: selector), let inspector = web.perform(selector)?.takeUnretainedValue() as? NSObject {
            let show = NSSelectorFromString("show")
            if inspector.responds(to: show) { inspector.perform(show) }
        }
    }

    @objc func toggleConsole() {
        isConsoleOpen.toggle()
        consoleHeight.constant = isConsoleOpen ? 160 : 0
        updateConsole(session?.console ?? [])
    }

    @objc private func clearConsole() { session?.clearConsole() }
}

/// A plain filled view (the toolbar, the address field's well).
final class BrowserBackground: NSView {
    private let color: NSColor
    private let radius: CGFloat

    init(color: NSColor, radius: CGFloat = 0) {
        self.color = color
        self.radius = radius
        super.init(frame: .zero)
        if #available(macOS 14, *) { clipsToBounds = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        if radius > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else {
            dirtyRect.intersection(bounds).fill()
        }
    }
}

/// The browser's root: its own keys, before the menu (BrowserViewController.handleKey).
final class BrowserRootView: NSView {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The browser's pages, as Safari's tabs: title (or address), a spinner
/// while loading, ✕ on hover; + makes one.
@MainActor
final class BrowserTabStrip: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    private let stack = NSStackView()
    private let plus = NSButton()
    private let theme: EditorTheme
    private let chrome: ChromeTheme
    private(set) var titles: [String] = []

    init(theme: EditorTheme, chrome: ChromeTheme) {
        self.theme = theme
        self.chrome = chrome
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("browserTabStrip")
        if #available(macOS 14, *) { clipsToBounds = true }
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.distribution = .fillEqually
        EditorHeaderView.style(plus, "plus", tip: "New Tab — ⌘T", color: theme.text, target: self, action: #selector(newTab), size: 11)
        plus.identifier = NSUserInterfaceItemIdentifier("browserNewTab")
        for view in [stack, plus] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            plus.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 4),
            plus.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -34),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        chrome.stripNS.setFill()
        dirtyRect.intersection(bounds).fill()
        theme.text.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(_ workspace: BrowserWorkspace?) {
        let pages = workspace?.pages ?? []
        let active = workspace?.activeIndex ?? -1
        titles = pages.map { Self.title(of: $0) }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, page) in pages.enumerated() {
            let tab = BrowserTabView(
                title: titles[index], tip: page.url?.absoluteString ?? "", loading: page.isLoading, isActive: index == active,
                theme: theme, select: { [weak self] in self?.onSelect?(index) }, close: { [weak self] in self?.onClose?(index) })
            tab.identifier = NSUserInterfaceItemIdentifier("browserTab-\(index)")
            stack.addArrangedSubview(tab)
            tab.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
            tab.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        }
    }

    static func title(of page: BrowserSession) -> String {
        if !page.title.isEmpty { return page.title }
        if let url = page.url { return url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.lastPathComponent }
        return "New Tab"
    }

    @objc private func newTab() { onNew?() }
}

/// One page's tab in the strip.
@MainActor
private final class BrowserTabView: NSView {
    private let select: () -> Void
    private let close: () -> Void
    private let isActive: Bool
    private let theme: EditorTheme
    private let closeButton = NSButton()
    private var hovering = false {
        didSet { closeButton.isHidden = !(hovering || isActive) }
    }

    init(
        title: String, tip: String, loading: Bool, isActive: Bool, theme: EditorTheme, select: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.select = select
        self.close = close
        self.isActive = isActive
        self.theme = theme
        super.init(frame: .zero)
        toolTip = tip
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11.5, weight: isActive ? .medium : .regular)
        label.textColor = theme.text.withAlphaComponent(isActive ? 0.95 : 0.6)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) }
        EditorHeaderView.style(closeButton, "xmark", tip: "Close Tab — ⌘W", color: theme.text, target: self, action: #selector(closeTab), size: 8)
        closeButton.isHidden = !isActive
        for view in [spinner, label, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: loading ? 12 : 0),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: loading ? 5 : 0),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0, dy: 1)
        (isActive ? EditorPicker.surface(theme) : hovering ? theme.text.withAlphaComponent(0.04) : .clear).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { select() }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { close() } }
    @objc private func closeTab() { close() }
}
