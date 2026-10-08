import AppKit

/// The split view controller for the window's columns, over a
/// `GapSplitView`: the dividers are the 10 pt gaps between the cards, and
/// they draw nothing.
///
/// The gap is also what makes them grabbable. They used to be 1 pt, drawn,
/// and only that single point responded — which in practice meant "the
/// columns can't be resized" — so the draggable area was widened by hand.
/// A 10 pt divider needs no such help.
final class WideDividerSplitViewController: NSSplitViewController {
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
}
