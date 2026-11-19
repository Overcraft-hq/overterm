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
/// select nothing; and the table hits a cell only when the cell says it
/// may (`validateProposedFirstResponder`) —, the first click in a window
/// behind others too, and a right-click as the table's menu for the row
/// clicked.
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

    /// The press is the cell's to take. A view-based table hands a press
    /// to a view in its row only when that view says so; NSView's answer
    /// is the table's, which is no for all but controls. So the table hit
    /// itself, and its `mouseDown` selects nothing: no AppKit cell could
    /// be pressed. A hosting view says yes, which is why hosted rows could.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }

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

/// One line of text in a list's cell, drawn by the cell itself: shown
/// again only when its value changed (`show`), and then only drawn — no
/// text field, no constraint, no layout pass (a label's every change was
/// a layout of its cell).
final class ResourceTextCell: ResourcePressCell {
    /// A column's text cells for one kind of row; never a hosted cell's.
    static func identifier(column: String, kind: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("resource.text.\(column).\(kind)")
    }

    private(set) var shown: ResourceTextCellValue?
    private var words = NSAttributedString()
    private var lineHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `value` drawn: whether anything changed.
    @discardableResult
    func show(_ value: ResourceTextCellValue) -> Bool {
        guard value != shown else { return false }
        let old = shown
        shown = value
        let font = Self.font(size: value.size, number: value.number)
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        let style = Self.style(number: value.number)
        words = NSAttributedString(
            string: value.text, attributes: [.font: font, .foregroundColor: value.color.withAlphaComponent(value.color.alphaComponent * value.alpha), .paragraphStyle: style])
        if old?.text != value.text { setAccessibilityValue(value.text) }
        if old?.help != value.help { toolTip = value.help?.isEmpty == false ? value.help : nil }
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let shown else { return }
        if let ground = shown.ground {
            ground.setFill()
            dirtyRect.intersection(bounds).fill()
        }
        let rect = CGRect(x: 6, y: (bounds.height - lineHeight) / 2, width: max(bounds.width - 12, 0), height: lineHeight)
        words.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static var fonts: [CGFloat: (text: NSFont, number: NSFont)] = [:]

    private static func font(size: CGFloat, number: Bool) -> NSFont {
        if let known = fonts[size] { return number ? known.number : known.text }
        let made = (text: NSFont.systemFont(ofSize: size), number: NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
        fonts[size] = made
        return number ? made.number : made.text
    }

    /// Text against the leading edge cut in its middle; a number against
    /// the trailing edge cut at its end.
    private static let styles: (text: NSParagraphStyle, number: NSParagraphStyle) = {
        let text = NSMutableParagraphStyle()
        text.lineBreakMode = .byTruncatingMiddle
        let number = NSMutableParagraphStyle()
        number.lineBreakMode = .byTruncatingTail
        number.alignment = .right
        return (text, number)
    }()

    private static func style(number: Bool) -> NSParagraphStyle { number ? styles.number : styles.text }
}
