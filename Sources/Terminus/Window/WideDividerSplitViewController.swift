import AppKit

/// The split view controller for the window's columns, over a
/// `GapSplitView`: the dividers measure and draw nothing, because the gap
/// between two cards belongs to the cards (`CardColumn.gap`).
///
/// Nothing of a divider is left to grab, then, so the draggable area is
/// widened by hand — over the gap, where there is nothing else to click.
final class WideDividerSplitViewController: NSSplitViewController {
    /// How far either side of the divider still resizes the columns. Half
    /// the gap: the grab band is the gap, and never reaches a card.
    private static let grabSlop: CGFloat = CardColumn.gap / 2

    /// After the panes change size — a divider dragged, a pane collapsed or
    /// opened, by the app or by hand.
    var onResize: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        // Before the view loads: NSSplitViewController makes its own split
        // view the first time it is asked for one.
        splitView = GapSplitView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize?()
    }

    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let rect = super.splitView(
            splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return splitView.isVertical ? rect.insetBy(dx: -Self.grabSlop, dy: 0) : rect.insetBy(dx: 0, dy: -Self.grabSlop)
    }
}
