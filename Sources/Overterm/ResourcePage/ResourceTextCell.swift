import AppKit

/// A one-line cell's words as a `ResourceTextCell` draws them: a list's
/// numbers and plain text, which need no SwiftUI view of their own (7.7 of
/// docs/design/activity/analysis.md — a hosting view each cost a SwiftUI
/// update and layout at every publish, most of a tick's main thread).
struct ResourceTextCellValue: Equatable {
    var text: String
    var color: NSColor
    /// The font's size, `ChromeMetrics.text`'s.
    var size: CGFloat
    /// A number: monospaced, against the trailing edge, cut at its end; else
    /// text against the leading edge, cut in its middle.
    var number = false
    /// Its tooltip; nil for none.
    var help: String? = nil
    /// The words' opacity (an ended row's 0.45); the ground stays whole.
    var alpha: CGFloat = 1
    /// A fill behind the words (a new row's tint); nil for none.
    var ground: NSColor? = nil
}

/// A cell of the page's own AppKit view (`ResourceTable.drawnCell`): its
/// kind, the reuse identifier's last part; how to make one; and how to
/// show the row in it, saying whether anything changed.
struct ResourceDrawnCell {
    let kind: String
    let make: () -> ResourcePressCell
    let show: (ResourcePressCell) -> Bool
}

/// A cell that takes a row's press as `ResourceRowHostingView` does: on
/// release, through the table's `pressRow` — `ResourceTableView.mouseDown`
/// never calls super, so a cell that let the press fall through would
/// select nothing —, the first click in a window behind others too, and a
/// right-click as the table's menu for the row clicked.
class ResourcePressCell: NSTableCellView {
    private var down: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var table: ResourceTableView? {
        var view = superview
        while let current = view, !(current is ResourceTableView) { view = current.superview }
        return view as? ResourceTableView
    }

    /// Every press inside is the cell's: none reaches the words.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        down = event
        table?.interaction?(.pressBegan)
    }

    override func mouseUp(with event: NSEvent) {
        if let down {
            self.down = nil
            table?.pressRow(down)
            table?.interaction?(.pressEnded)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let table { table.rightMouseDown(with: event) } else { super.rightMouseDown(with: event) }
    }
}

/// One line of text in a list's cell, drawn by AppKit: shown again only
/// when its value changed (`show`).
final class ResourceTextCell: ResourcePressCell {
    /// A column's text cells for one kind of row; never a hosted cell's.
    static func identifier(column: String, kind: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("resource.text.\(column).\(kind)")
    }

    private let label = NSTextField(labelWithString: "")
    private(set) var shown: ResourceTextCellValue?

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Not the cell's `textField`: the table would restyle it on
        // selection, which the hosted cells beside it never are.
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `value` drawn, each part set only where it changed: whether anything
    /// did.
    @discardableResult
    func show(_ value: ResourceTextCellValue) -> Bool {
        guard value != shown else { return false }
        let old = shown
        shown = value
        if old?.text != value.text { label.stringValue = value.text }
        if old?.color != value.color { label.textColor = value.color }
        if old?.size != value.size || old?.number != value.number {
            label.font = value.number ? .monospacedSystemFont(ofSize: value.size, weight: .regular) : .systemFont(ofSize: value.size)
            label.alignment = value.number ? .right : .left
            label.lineBreakMode = value.number ? .byTruncatingTail : .byTruncatingMiddle
        }
        if old?.help != value.help { toolTip = value.help?.isEmpty == false ? value.help : nil }
        if old?.alpha != value.alpha { label.alphaValue = value.alpha }
        if old?.ground != value.ground { needsDisplay = true }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ground = shown?.ground else { return }
        ground.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}
