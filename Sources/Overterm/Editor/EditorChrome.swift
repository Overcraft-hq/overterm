import AppKit

/// The editor's header: a tab per open file (name, unsaved dot, ✕), then
/// zoom, open-in-app and close. AppKit: a SwiftUI header in this pane,
/// created while the pane was collapsed, never drew.
@MainActor
final class EditorHeaderView: NSView {
    struct Item: Equatable {
        let name: String
        let path: String
        let dirty: Bool
    }

    var onSelect: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onZoom: (() -> Void)?
    var onPreview: (() -> Void)?
    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?
    var revealMenu: (() -> NSMenu?)? {
        didSet { reveal.menuProvider = revealMenu }
    }

    private let background: NSColor
    private let text: NSColor
    private let accent: NSColor
    private let tabs = NSStackView()
    private let scroll = NSScrollView()
    private let zoom = NSButton()
    private let preview = NSButton()
    private let reveal = MenuButton()
    private var items: [Item] = []
    private var active = -1

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.intersection(bounds).fill()
        text.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }

    init(background: NSColor, text: NSColor, accent: NSColor) {
        self.background = background
        self.text = text
        self.accent = accent
        super.init(frame: .zero)
        // Views don't clip by default since macOS 14: a fill of the dirty
        // rect reached past this one and painted over the whole editor.
        if #available(macOS 14, *) { clipsToBounds = true }
        tabs.orientation = .horizontal
        tabs.spacing = 0
        tabs.alignment = .centerY
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(tabs)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none

        Self.style(preview, "eye", tip: "Preview Markdown — ⇧⌘V", color: text, target: self, action: #selector(togglePreview))
        preview.identifier = NSUserInterfaceItemIdentifier("markdownPreviewButton")
        preview.isHidden = true
        Self.style(zoom, "arrow.up.left.and.arrow.down.right", tip: "Zoom Editor — ⇧⎋", color: text, target: self, action: #selector(zoomEditor))
        zoom.identifier = NSUserInterfaceItemIdentifier("zoomEditor")
        Self.style(reveal, "arrow.up.forward.app", tip: OpenWith.openTitle(nil), color: text, target: self, action: #selector(revealFile))
        reveal.identifier = NSUserInterfaceItemIdentifier("openExternally")
        let close = Self.style(NSButton(), "xmark", tip: "Close Editor", color: text, target: self, action: #selector(closeEditor))
        close.identifier = NSUserInterfaceItemIdentifier("closeEditor")
        for view in [scroll, preview, zoom, reveal, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            scroll.trailingAnchor.constraint(equalTo: preview.leadingAnchor, constant: -6),
            preview.trailingAnchor.constraint(equalTo: zoom.leadingAnchor, constant: -2),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 22),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            tabs.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: document.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 22),
            reveal.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            reveal.centerYAnchor.constraint(equalTo: centerYAnchor),
            reveal.widthAnchor.constraint(equalToConstant: 22),
            zoom.trailingAnchor.constraint(equalTo: reveal.leadingAnchor, constant: -2),
            zoom.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoom.widthAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ items: [Item], active: Int) {
        guard items != self.items || active != self.active else { return }
        // Two files of one name show their folder, as Zed does.
        let names = Dictionary(grouping: items, by: \.name)
        self.items = items
        self.active = active
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let folder = (names[item.name]?.count ?? 0) > 1 ? (item.path as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) : nil
            let tab = EditorTabView(
                item: item, folder: folder, isActive: i == active, text: text, accent: accent, background: background,
                select: { [weak self] in self?.onSelect?(i) }, close: { [weak self] in self?.onCloseTab?(i) })
            tabs.addArrangedSubview(tab)
            tab.heightAnchor.constraint(equalTo: tabs.heightAnchor).isActive = true
        }
        // The active tab into view once laid out — not by forcing a layout
        // here, which may be called from inside one.
        if active >= 0, active < tabs.arrangedSubviews.count {
            let tab = tabs.arrangedSubviews[active]
            DispatchQueue.main.async { tab.scrollToVisible(tab.bounds) }
        }
    }

    func setZoomed(_ zoomed: Bool) {
        let symbol = zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        zoom.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        zoom.toolTip = zoomed ? "Give the Terminal Back — ⇧⎋" : "Zoom Editor — ⇧⎋"
        zoom.setAccessibilityLabel(zoom.toolTip)
    }

    /// "Open in Zed", or "Open With…" while no app is picked.
    func setRevealTitle(_ tip: String) {
        reveal.toolTip = tip
        reveal.setAccessibilityLabel(tip)
    }

    @discardableResult
    static func style<Button: NSButton>(
        _ button: Button, _ symbol: String, tip: String, color: NSColor, target: AnyObject, action: Selector, size: CGFloat = 11
    ) -> Button {
        button.image =
            NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) ?? NSImage()
        button.imagePosition = .imageOnly
        button.title = ""
        button.target = target
        button.action = action
        button.isBordered = false
        button.contentTintColor = color.withAlphaComponent(0.7)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }

    /// Markdown files only: the eye shows it rendered, the brackets go back.
    func setPreview(available: Bool, showing: Bool) {
        preview.isHidden = !available
        let symbol = showing ? "chevron.left.forwardslash.chevron.right" : "eye"
        preview.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        preview.toolTip = showing ? "Back to the Markdown — ⇧⌘V" : "Preview Markdown — ⇧⌘V"
        preview.setAccessibilityLabel(preview.toolTip)
    }

    @objc private func togglePreview() { onPreview?() }
    @objc private func zoomEditor() { onZoom?() }
    @objc private func revealFile() { onReveal?() }
    @objc private func closeEditor() { onClose?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One file's tab: its name (and folder, when two share a name), a dot while
/// unsaved that turns into ✕ under the mouse. Middle-click closes it.
@MainActor
private final class EditorTabView: NSView {
    private let select: () -> Void
    private let close: () -> Void
    private let isActive: Bool
    private let accent: NSColor
    private let text: NSColor
    private let closeButton = NSButton()
    private let dot = NSView()
    private let dirty: Bool
    private var hovering = false {
        didSet { updateMarks() }
    }

    init(
        item: EditorHeaderView.Item, folder: String?, isActive: Bool, text: NSColor, accent: NSColor, background: NSColor,
        select: @escaping () -> Void, close: @escaping () -> Void
    ) {
        self.select = select
        self.close = close
        self.isActive = isActive
        self.accent = accent
        self.text = text
        dirty = item.dirty
        super.init(frame: .zero)
        // Views don't clip by default since macOS 14: a fill of the dirty
        // rect reached past this one and painted over the whole editor.
        if #available(macOS 14, *) { clipsToBounds = true }
        toolTip = item.path
        let title = NSTextField(labelWithString: item.name)
        title.font = .systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        title.textColor = text.withAlphaComponent(isActive ? 1 : 0.6)
        title.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [title])
        stack.spacing = 5
        if let folder {
            let detail = NSTextField(labelWithString: folder)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = text.withAlphaComponent(0.4)
            stack.addArrangedSubview(detail)
        }
        EditorHeaderView.style(closeButton, "xmark", tip: "Close \(item.name)", color: text, target: self, action: #selector(closeTab), size: 9)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = text.withAlphaComponent(0.7).cgColor
        dot.layer?.cornerRadius = 3.5
        dot.toolTip = "Unsaved — ⌘S"
        for view in [stack, closeButton, dot] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            dot.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(item.name)
        updateMarks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateMarks() {
        dot.isHidden = !dirty || hovering
        closeButton.isHidden = !(hovering || (isActive && !dirty))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            text.withAlphaComponent(0.06).setFill()
            bounds.fill()
            accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1.5).fill()
        }
        text.withAlphaComponent(0.08).setFill()
        NSRect(x: bounds.maxX - 1, y: 6, width: 1, height: bounds.height - 12).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { select() }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { close() } }
    @objc private func closeTab() { close() }
}

/// A button with a menu on right-click (NSView asks `menu(for:)`), built
/// when asked: Open With depends on the file and on the app in use.
final class MenuButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }
}

/// Under the header: where the file is (folders › file) and the symbol the
/// caret is in, as Zed's breadcrumbs. A click on it opens ⇧⌘O.
@MainActor
final class EditorBreadcrumbView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let background: NSColor
    private let text: NSColor
    var onClick: (() -> Void)?

    init(background: NSColor, text: NSColor) {
        self.background = background
        self.text = text
        super.init(frame: .zero)
        // Views don't clip by default since macOS 14: a fill of the dirty
        // rect reached past this one and painted over the whole editor.
        if #available(macOS 14, *) { clipsToBounds = true }
        label.font = .systemFont(ofSize: 11.5)
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    func update(path: [String], symbol: String?) {
        let out = NSMutableAttributedString()
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: text.withAlphaComponent(0.5), .font: NSFont.systemFont(ofSize: 11.5)]
        let strong: [NSAttributedString.Key: Any] = [.foregroundColor: text.withAlphaComponent(0.85), .font: NSFont.systemFont(ofSize: 11.5)]
        for (i, part) in path.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "  ›  ", attributes: dim)) }
            out.append(NSAttributedString(string: part, attributes: i == path.count - 1 ? strong : dim))
        }
        if let symbol {
            out.append(NSAttributedString(string: "  ›  ", attributes: dim))
            out.append(NSAttributedString(string: symbol, attributes: strong))
        }
        label.attributedStringValue = out
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The bottom line: problems, vim's mode or command line, then the caret's
/// line and column, indentation, language and its server.
@MainActor
final class EditorStatusBar: NSView {
    private let problems = NSButton()
    private let mode = NSTextField(labelWithString: "")
    private let position = NSTextField(labelWithString: "")
    private let indent = NSTextField(labelWithString: "")
    private let language = NSTextField(labelWithString: "")
    private let server = NSTextField(labelWithString: "")
    private let background: NSColor
    private let text: NSColor
    var onProblems: (() -> Void)?

    init(background: NSColor, text: NSColor) {
        self.background = background
        self.text = text
        super.init(frame: .zero)
        // Views don't clip by default since macOS 14: a fill of the dirty
        // rect reached past this one and painted over the whole editor.
        if #available(macOS 14, *) { clipsToBounds = true }
        problems.isBordered = false
        problems.target = self
        problems.action = #selector(showProblems)
        problems.toolTip = "Next Problem — F8"
        problems.identifier = NSUserInterfaceItemIdentifier("editorProblems")
        for label in [mode, position, indent, language, server] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = text.withAlphaComponent(0.6)
            label.lineBreakMode = .byTruncatingTail
        }
        mode.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        position.identifier = NSUserInterfaceItemIdentifier("editorPosition")
        mode.identifier = NSUserInterfaceItemIdentifier("editorMode")
        let left = NSStackView(views: [problems, mode])
        left.spacing = 14
        let right = NSStackView(views: [position, indent, language, server])
        right.spacing = 16
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        mode.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
        ])
        update(errors: 0, warnings: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.intersection(bounds).fill()
        text.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    private var counts: (errors: Int, warnings: Int)?

    func update(errors: Int, warnings: Int) {
        // Every caret move updates the bar: only a change reaches the button.
        if let counts, counts == (errors, warnings) { return }
        counts = (errors, warnings)
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func add(_ symbol: String, _ count: Int, _ color: NSColor) {
            let attachment = NSTextAttachment()
            attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium).applying(.init(paletteColors: [color])))
            out.append(NSAttributedString(attachment: attachment))
            out.append(NSAttributedString(string: " \(count)  ", attributes: [.font: font, .foregroundColor: text.withAlphaComponent(0.6)]))
        }
        add("xmark.circle", errors, errors > 0 ? NSColor.systemRed : text.withAlphaComponent(0.5))
        add("exclamationmark.triangle", warnings, warnings > 0 ? NSColor.systemYellow : text.withAlphaComponent(0.5))
        problems.attributedTitle = out
        problems.setAccessibilityLabel("\(errors) errors, \(warnings) warnings")
    }

    func update(mode text: String) {
        if mode.stringValue != text { mode.stringValue = text }
        if mode.isHidden != text.isEmpty { mode.isHidden = text.isEmpty }
    }

    func update(line: Int, column: Int, selected: Int, cursors: Int) {
        var value = "\(line):\(column)"
        if cursors > 1 {
            value += " (\(cursors) selections)"
        } else if selected > 0 {
            value += " (\(selected) selected)"
        }
        if position.stringValue != value { position.stringValue = value }
    }

    func update(indent: String, language: String, server: String?) {
        if self.indent.stringValue != indent { self.indent.stringValue = indent }
        if self.language.stringValue != language { self.language.stringValue = language }
        if self.server.stringValue != server ?? "" {
            self.server.stringValue = server ?? ""
            self.server.isHidden = server == nil
            self.server.toolTip = server.map { "Language server: \($0)" }
        }
    }

    @objc private func showProblems() { onProblems?() }
}
