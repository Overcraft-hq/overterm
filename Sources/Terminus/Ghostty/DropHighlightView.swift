import AppKit

/// Over a terminal pane while something is dragged onto it: an accent
/// border and a small label saying what a drop inserts. Placed by the pane
/// over its own frame, in its superview; it never takes a click, a drag or
/// the keyboard, and draws only within the pane.
@MainActor
final class DropHighlightView: NSView {
    private let badge = NSView()
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        if #available(macOS 14, *) { clipsToBounds = true }
        layer?.masksToBounds = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(badge)
        badge.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let fitted = label.frame.size
        let width = max(min(fitted.width + 20, bounds.width - 16), 0)
        let height = fitted.height + 8
        badge.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        label.frame = NSRect(x: 10, y: 4, width: max(width - 20, 0), height: fitted.height)
    }

    override var acceptsFirstResponder: Bool { false }
    /// Hit-testing picks a drag's destination: the pane below must get it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
