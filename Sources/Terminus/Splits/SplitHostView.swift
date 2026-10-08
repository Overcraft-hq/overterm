import AppKit

/// One tab's panes, laid out from its SplitTree: each pane a TerminalView,
/// 1 pt dividers (the view's own background shows through the gaps) that
/// can be grabbed a few points either side, and the panes without the
/// keyboard dimmed so the focused one stands out.
@MainActor
final class SplitHostView: NSView {
    static let dividerThickness: CGFloat = 1
    /// The bar across the top of every pane (`PaneHeaderView`).
    static let headerHeight: CGFloat = 38
    /// How far from the 1 pt line a divider can still be grabbed.
    private static let grab: CGFloat = 4

    private(set) var tree: SplitTree<TerminalView>?
    private(set) var focused: TerminalView?
    /// Shown alone, filling the tab (toggle_split_zoom).
    private(set) var zoomed: TerminalView?
    /// A divider was dragged: the split at `path` wants `ratio`.
    var onRatioChange: (([Bool], Double) -> Void)?

    /// Tab peek scales the whole host into a card with a layer transform:
    /// pixels move, no frame changes, so no surface is resized and nothing
    /// reflows. AppKit resets a layer-backed view's transform whenever it
    /// syncs the layer to the view's geometry — it had silently undone the
    /// scale on every host but the first — so the host owns it and puts it
    /// back after each layout.
    var peekTransform = CATransform3DIdentity {
        didSet { layer?.transform = peekTransform }
    }

    private func restorePeekTransform() {
        guard let layer, !CATransform3DEqualToTransform(layer.transform, peekTransform) else { return }
        // Not mid-flight: the settling animation owns the transform until it
        // lands, and this would snap it to the end.
        guard layer.animation(forKey: "transform") == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = peekTransform
        CATransaction.commit()
    }

    /// Makes a pane's header. The host frames it and nothing more: what
    /// goes in it needs the tab, its group and the window's actions, none
    /// of which a view over TerminalViews should know about.
    var makeHeader: ((TerminalView) -> NSView)?

    private var dividers: [SplitTree<TerminalView>.Divider] = []
    private var headers: [ObjectIdentifier: NSView] = [:]
    private var dims: [ObjectIdentifier: NSView] = [:]
    private var visible = true
    /// Scaled into a tab peek card, which draws a header of its own: ours
    /// would be a second one, at a size nobody can read.
    private var previewing = false
    /// Over the panes without the keyboard; Settings can change it.
    var dimColor: NSColor {
        didSet { dims.values.forEach { $0.layer?.backgroundColor = dimColor.cgColor } }
    }

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
        for (id, header) in headers where !panes.contains(where: { ObjectIdentifier($0) == id }) {
            header.removeFromSuperview()
            headers[id] = nil
        }
        applyVisibility()
        needsLayout = true
        layoutSubtreeIfNeeded()
        restorePeekTransform()
    }

    /// The tab shown or hidden; hidden panes are occluded (libghostty stops
    /// rendering them).
    func setVisible(_ visible: Bool) {
        self.visible = visible
        previewing = false
        isHidden = !visible
        if visible { needsLayout = true }
        applyVisibility()
    }

    /// Shown for tab peek without waking the renderer: the peek draws these
    /// panes itself, at its own cadence.
    func setPreviewing(_ previewing: Bool) {
        visible = previewing
        self.previewing = previewing
        isHidden = !previewing
        headers.values.forEach { $0.isHidden = previewing }
        for pane in tree?.leaves ?? [] {
            pane.setPreviewing(previewing && (zoomed == nil || pane === zoomed))
        }
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
            place(zoomed, in: bounds)
            dividers = []
            dims.values.forEach { $0.isHidden = true }
            for (id, header) in headers { header.isHidden = previewing || id != ObjectIdentifier(zoomed) }
        } else {
            let (panes, dividers) = tree.layout(in: bounds, divider: Self.dividerThickness)
            self.dividers = dividers
            let dimming = panes.count > 1
            for (pane, rect) in panes {
                place(pane, in: rect)
                let dim = dimView(for: pane)
                dim.frame = rect
                dim.isHidden = !dimming || pane === focused
            }
        }
        window?.invalidateCursorRects(for: self)
        restorePeekTransform()
    }

    /// After layout, before display — AppKit writes the layer's geometry
    /// from the view's between the two, which is where the scale was lost.
    override func viewWillDraw() {
        super.viewWillDraw()
        restorePeekTransform()
    }

    /// The pane's header across the top of its rect, the terminal under it.
    /// The terminal is the one that shrinks — the header is chrome, and a
    /// pane's share of the tab should not depend on whether it has one.
    private func place(_ pane: TerminalView, in rect: CGRect) {
        guard let header = headerView(for: pane) else {
            pane.frame = rect
            return
        }
        header.isHidden = previewing
        header.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Self.headerHeight)
        pane.frame = CGRect(
            x: rect.minX, y: rect.minY + Self.headerHeight,
            width: rect.width, height: max(rect.height - Self.headerHeight, 0))
    }

    private func headerView(for pane: TerminalView) -> NSView? {
        if let header = headers[ObjectIdentifier(pane)] { return header }
        guard let header = makeHeader?(pane) else { return nil }
        header.translatesAutoresizingMaskIntoConstraints = true
        addSubview(header, positioned: .above, relativeTo: pane)
        headers[ObjectIdentifier(pane)] = header
        return header
    }

    /// How many panes are dimmed — for the E2E scenario, which cannot tell
    /// a dim from a header by class alone.
    var dimmedPanes: Int { dims.values.count { !$0.isHidden } }

    /// A pane's header, if it has been made.
    func header(of pane: TerminalView) -> NSView? { headers[ObjectIdentifier(pane)] }

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
