import AppKit

/// One tab's panes, laid out from its SplitTree: each pane a TerminalView,
/// 1 pt dividers (the view's own background shows through the gaps) that
/// can be grabbed a few points either side, and the panes without the
/// keyboard dimmed so the focused one stands out.
@MainActor
final class SplitHostView: NSView {
    static let dividerThickness: CGFloat = 1
    /// How far from the 1 pt line a divider can still be grabbed.
    private static let grab: CGFloat = 4

    private(set) var tree: SplitTree<TerminalView>?
    private(set) var focused: TerminalView?
    /// Shown alone, filling the tab (toggle_split_zoom).
    private(set) var zoomed: TerminalView?
    /// A divider was dragged: the split at `path` wants `ratio`.
    var onRatioChange: (([Bool], Double) -> Void)?

    private var dividers: [SplitTree<TerminalView>.Divider] = []
    private var dims: [ObjectIdentifier: NSView] = [:]
    private var visible = true
    private let dimColor: NSColor

    init(dividerColor: NSColor, dimColor: NSColor) {
        self.dimColor = dimColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = dividerColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    /// A divider is grabbed on the first click, in a background window too
    /// (as NSSplitView's are); without this the click only activated it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(tree: SplitTree<TerminalView>, focused: TerminalView?, zoomed: TerminalView?) {
        self.tree = tree
        self.focused = focused
        self.zoomed = zoomed.flatMap { tree.contains($0) ? $0 : nil }
        let panes = tree.leaves
        for pane in panes where pane.superview !== self {
            pane.translatesAutoresizingMaskIntoConstraints = true
            addSubview(pane, positioned: .below, relativeTo: nil)
        }
        for case let pane as TerminalView in subviews where !panes.contains(where: { $0 === pane }) {
            pane.removeFromSuperview()
        }
        for (id, dim) in dims where !panes.contains(where: { ObjectIdentifier($0) == id }) {
            dim.removeFromSuperview()
            dims[id] = nil
        }
        applyVisibility()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The tab shown or hidden; hidden panes are occluded (libghostty stops
    /// rendering them).
    func setVisible(_ visible: Bool) {
        self.visible = visible
        isHidden = !visible
        applyVisibility()
    }

    private func applyVisibility() {
        for pane in tree?.leaves ?? [] {
            pane.setVisible(visible && (zoomed == nil || pane === zoomed))
        }
    }

    override func layout() {
        super.layout()
        guard let tree else { return }
        if let zoomed {
            zoomed.frame = bounds
            dividers = []
            dims.values.forEach { $0.isHidden = true }
        } else {
            let (panes, dividers) = tree.layout(in: bounds, divider: Self.dividerThickness)
            self.dividers = dividers
            let dimming = panes.count > 1
            for (pane, rect) in panes {
                pane.frame = rect
                let dim = dimView(for: pane)
                dim.frame = rect
                dim.isHidden = !dimming || pane === focused
            }
        }
        window?.invalidateCursorRects(for: self)
    }

    private func dimView(for pane: TerminalView) -> NSView {
        if let dim = dims[ObjectIdentifier(pane)] { return dim }
        let dim = PassThroughView()
        dim.wantsLayer = true
        dim.layer?.backgroundColor = dimColor.cgColor
        addSubview(dim, positioned: .above, relativeTo: nil)
        dims[ObjectIdentifier(pane)] = dim
        return dim
    }

    // MARK: Dragging dividers

    private func grabRect(_ divider: SplitTree<TerminalView>.Divider) -> CGRect {
        divider.axis == .horizontal ? divider.rect.insetBy(dx: -Self.grab, dy: 0) : divider.rect.insetBy(dx: 0, dy: -Self.grab)
    }

    private func divider(at point: NSPoint) -> SplitTree<TerminalView>.Divider? {
        // Innermost last in layout order; prefer it where zones overlap.
        dividers.last { grabRect($0).contains(point) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !isHidden, divider(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(grabRect(divider), cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    /// Tracks the drag itself, as NSSplitView does: the pointer soon
    /// leaves the grab zone, and the drag must stay with the divider.
    override func mouseDown(with event: NSEvent) {
        let down = convert(event.locationInWindow, from: nil)
        guard let dragging = divider(at: down), let window else { return }
        // Where on the grab zone it was taken: the divider keeps that
        // distance from the pointer instead of jumping onto it.
        let grabbed = dragging.axis == .horizontal ? down.x - dragging.rect.minX : down.y - dragging.rect.minY
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let point = convert(next.locationInWindow, from: nil)
            let box = dragging.container
            let ratio =
                dragging.axis == .horizontal
                ? (point.x - grabbed - box.minX) / max(box.width - Self.dividerThickness, 1)
                : (point.y - grabbed - box.minY) / max(box.height - Self.dividerThickness, 1)
            onRatioChange?(dragging.path, Double(ratio))
        }
    }
}

/// Draws, never takes a click: the dim over unfocused panes.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
