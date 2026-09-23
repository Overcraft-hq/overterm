import AppKit

/// A split view controller whose thin (1 pt) dividers can actually be
/// grabbed: the draggable area extends a few points either side of the
/// drawn line. With the default, only that single point responded, which
/// in practice meant "the panes can't be resized".
final class WideDividerSplitViewController: NSSplitViewController {
    private static let grabSlop: CGFloat = 4

    override func splitView(
        _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return splitView.isVertical
            ? rect.insetBy(dx: -Self.grabSlop, dy: 0)
            : rect.insetBy(dx: 0, dy: -Self.grabSlop)
    }
}
