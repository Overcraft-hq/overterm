import AppKit

/// A row of a picker or the completion list.
struct EditorListItem {
    var title: String
    var detail: String = ""
    /// A short badge ("fn", "T", "var") before the title.
    var badge: String = ""
    var badgeColor: NSColor = .secondaryLabelColor
    /// Characters of `title` the query matched, drawn stronger.
    var matched: [Int] = []
}

/// Zed's modal pickers, at the top of the editor: Go to Line (⌃G), Go to
/// Symbol (⇧⌘O), Go to File (⌘P), references (⇧F12). A field and, for all
/// but Go to Line, a ranked list under it. Esc or a click elsewhere closes.
@MainActor
final class EditorPicker: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private var items: [EditorListItem] = []
    private let theme: EditorTheme
    private let provider: (String) -> [EditorListItem]
    private let choose: (Int, String) -> Void
    private let preview: ((Int) -> Void)?
    var onDismiss: (() -> Void)?
    private static let rowHeight: CGFloat = 26

    /// `provider` ranks rows for the query (nil list: a field only, as Go to
    /// Line); `choose` gets the row (or -1 with the field's text).
    init(
        placeholder: String, hint: String = "", theme: EditorTheme, showsList: Bool, initial: String = "",
        provider: @escaping (String) -> [EditorListItem], choose: @escaping (Int, String) -> Void, preview: ((Int) -> Void)? = nil
    ) {
        self.theme = theme
        self.provider = provider
        self.choose = choose
        self.preview = preview
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("editorPicker")
        // Lifted off the text, as Zed's: a lighter surface, a clear edge
        // and a shadow — on the editor's own colour it read as part of it.
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = theme.text.withAlphaComponent(0.2).cgColor
        layer?.backgroundColor = Self.surface(theme).cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: theme.text.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 14)])
        field.stringValue = initial
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = theme.text
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier("editorPickerField")
        self.hint.stringValue = hint
        self.hint.font = .systemFont(ofSize: 11)
        self.hint.textColor = theme.text.withAlphaComponent(0.5)
        self.hint.isHidden = hint.isEmpty

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseClicked)
        table.action = #selector(chooseClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.isHidden = !showsList
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = theme.text.withAlphaComponent(0.1)
        separator.isHidden = !showsList

        for view in [field, self.hint, separator, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            self.hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: hint.isEmpty ? 0 : 4),
            self.hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            self.hint.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            self.hint.heightAnchor.constraint(equalToConstant: hint.isEmpty ? 0 : 14),
            separator.topAnchor.constraint(equalTo: self.hint.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: showsList ? -6 : -12),
            heightConstraint,
        ])
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated static func blend(_ a: NSColor, _ b: NSColor, _ amount: CGFloat) -> NSColor {
        (a.usingColorSpace(.sRGB) ?? a).blended(withFraction: amount, of: b.usingColorSpace(.sRGB) ?? b) ?? a
    }

    /// A popup's surface: the editor's background, a step towards the text.
    nonisolated static func surface(_ theme: EditorTheme) -> NSColor { blend(theme.background, theme.text, theme.isDark ? 0.09 : 0.03) }

    // MARK: Clicking away

    private var clickMonitor: Any?

    /// A click anywhere outside closes it, as Zed's do — the field losing
    /// the keyboard alone didn't, when the click landed on text.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.superview != nil else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.dismiss() }
            }
            return event
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var query: String { field.stringValue }

    func refresh() {
        items = scroll.isHidden ? [] : provider(field.stringValue)
        table.reloadData()
        heightConstraint.constant = scroll.isHidden ? 0 : min(CGFloat(max(items.count, 1)), 12) * Self.rowHeight
        if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// Rows that arrived later (a language server's symbols).
    func reload() { refresh() }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): chooseSelected()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicked away: gone, as Zed's are.
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.other.rawValue, window?.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.superview != nil, self.window?.firstResponder !== self.field.currentEditor() else { return }
                    self.dismiss()
                }
            }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        preview?(row)
    }

    @objc private func chooseClicked() { chooseSelected() }

    func chooseSelected() {
        let row = items.isEmpty ? -1 : max(0, table.selectedRow)
        let text = field.stringValue
        dismiss()
        choose(row, text)
    }

    func dismiss() {
        guard superview != nil else { return }
        removeFromSuperview()
        onDismiss?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        EditorListRow(item: items[row], theme: theme)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EditorListRowView(theme: theme) }
}

/// A list row's selection in the theme's colour, its text as it is — the
/// system's highlight turned it white with grey text on it.
final class EditorListRowView: NSTableRowView {
    private let theme: EditorTheme

    init(theme: EditorTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

/// One row: badge, title with its matched letters, detail on the right.
@MainActor
final class EditorListRow: NSView {
    init(item: EditorListItem, theme: EditorTheme, font: NSFont = .systemFont(ofSize: 12.5)) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "")
        let attributed = NSMutableAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: theme.text.withAlphaComponent(0.85)])
        let ns = item.title as NSString
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        for index in item.matched where index < ns.length {
            attributed.addAttributes([.foregroundColor: theme.info, .font: bold], range: NSRange(location: index, length: 1))
        }
        title.attributedStringValue = attributed
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = theme.text.withAlphaComponent(0.45)
        detail.lineBreakMode = .byTruncatingHead
        detail.alignment = .right
        let badge = NSTextField(labelWithString: item.badge)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.textColor = item.badgeColor
        badge.alignment = .center
        for view in [badge, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.widthAnchor.constraint(equalToConstant: item.badge.isEmpty ? 0 : 26),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: item.badge.isEmpty ? 2 : 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// The completion list under the caret: a borderless child window, so it
/// can hang past the pane's edge. The text view keeps the keyboard; the
/// pane routes ↑ ↓ ⏎ ⇥ ⎋ here while it shows.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var items: [EditorListItem] = []
    private var details: [String] = []
    private let theme: EditorTheme
    var onChoose: ((Int) -> Void)?
    private static let rowHeight: CGFloat = 22
    private static let width: CGFloat = 440

    init(theme: EditorTheme) {
        self.theme = theme
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.borderWidth = 1
        content.layer?.borderColor = theme.text.withAlphaComponent(0.14).cgColor
        content.layer?.backgroundColor = EditorPicker.surface(theme).cgColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        footer.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        footer.textColor = theme.text.withAlphaComponent(0.5)
        footer.lineBreakMode = .byTruncatingTail
        for view in [scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 3),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -3),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])
        panel.contentView = content
    }

    var isVisible: Bool { panel.isVisible }
    var selectedIndex: Int { max(0, table.selectedRow) }
    var count: Int { items.count }

    /// Shows `items` with their top-left at the caret's bottom-left (above
    /// it when there is no room below).
    func show(_ items: [EditorListItem], details: [String], at caret: NSRect, in parent: NSWindow) {
        guard !items.isEmpty else { return hide() }
        self.items = items
        self.details = details
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        updateFooter()
        let rows = CGFloat(min(items.count, 10))
        let height = rows * Self.rowHeight + 8 + 18
        var origin = NSPoint(x: caret.minX - 30, y: caret.minY - height - 2)
        if let screen = parent.screen?.visibleFrame {
            if origin.y < screen.minY { origin.y = caret.maxY + 2 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.width)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        var row = table.selectedRow + delta
        if row < 0 { row = items.count - 1 }
        if row >= items.count { row = 0 }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateFooter()
    }

    private func updateFooter() {
        let row = max(0, table.selectedRow)
        footer.stringValue = row < details.count ? details[row] : ""
    }

    @objc private func clicked() { onChoose?(selectedIndex) }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        EditorListRow(item: items[row], theme: theme, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EditorListRowView(theme: theme) }
}

/// What a language server says about the symbol under the mouse (and any
/// problem there), in a popover over it.
@MainActor
enum EditorHover {
    static func popover(text: String, problems: [EditorDiagnostic], theme: EditorTheme, font: NSFont) -> NSPopover {
        let body = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.text]
        let code: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(11, font.pointSize - 1), weight: .regular), .foregroundColor: theme.text,
        ]
        for problem in problems {
            let color = problem.severity == .error ? theme.error : problem.severity == .warning ? theme.warning : theme.info
            body.append(NSAttributedString(string: problem.message, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color]))
            if let source = problem.source {
                body.append(NSAttributedString(string: "  \(source)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.hint]))
            }
            body.append(NSAttributedString(string: "\n"))
        }
        if !problems.isEmpty, !text.isEmpty { body.append(NSAttributedString(string: "\n")) }
        // Markdown, lightly: fenced code in the editor's font, the rest as text.
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            let content = inFence ? line : line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            body.append(NSAttributedString(string: content + "\n", attributes: inFence ? code : plain))
        }
        while body.string.hasSuffix("\n\n") { body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1)) }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textStorage?.setAttributedString(body)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let size = NSSize(width: min(540, max(160, used.width + 24)), height: min(360, used.height + 18))
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.documentView = textView
        scroll.hasVerticalScroller = used.height + 18 > 360
        scroll.drawsBackground = false
        textView.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: max(size.height, used.height + 18)))
        textView.autoresizingMask = [.width]
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        return popover
    }
}
