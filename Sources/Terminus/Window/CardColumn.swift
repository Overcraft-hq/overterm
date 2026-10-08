import AppKit

/// The gap between the cards.
///
/// The columns are drawn as cards floating on the window, so what reads as
/// the space between two of them is simply the window showing through —
/// which is exactly what a split view divider is, once it is wide enough
/// and draws nothing. Making the divider the gap (rather than insetting
/// every card) keeps one source of truth for the spacing and gives the
/// dividers a 10 pt grab area for free; before this they were 1 pt, drawn
/// and barely grabbable.
final class GapSplitView: NSSplitView {
    static let gap: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Columns side by side. NSSplitView's own default is horizontal;
        // NSSplitViewController's is not, and substituting the split view
        // loses that.
        isVertical = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerThickness: CGFloat { Self.gap }
    override var dividerColor: NSColor { .clear }
    override func drawDivider(in rect: NSRect) {}
}

/// One column of the window — the sidebar, the terminal, the editor, the
/// changes pane — drawn as a card: rounded, hairlined, clipping whatever
/// it contains, and on a light ground casting a shadow.
///
/// A wrapper rather than rounding each column's own view: the sidebar and
/// the changes pane are `NSHostingView`s whose layers SwiftUI owns, and the
/// shadow has to live on a layer that does *not* clip. `layout()` re-applies
/// everything each pass, so nothing a subview does to its own layer can
/// undo it.
final class CardColumn: NSView {
    static let cornerRadius: CGFloat = 10

    private let content: NSView
    private let ground = CALayer()
    private let edge: NSColor

    init(content: NSView, fill: NSColor, theme: ChromeTheme) {
        self.content = content
        edge = theme.borderNS
        super.init(frame: .zero)
        wantsLayer = true
        ground.backgroundColor = fill.cgColor
        ground.cornerRadius = Self.cornerRadius
        if !theme.isDark {
            // The hairline alone separates a card from a dark window; on a
            // light one it needs the lift too.
            ground.shadowColor = NSColor.black.cgColor
            ground.shadowOpacity = 0.10
            ground.shadowRadius = 6
            ground.shadowOffset = CGSize(width: 0, height: -2)
        }
        layer?.addSublayer(ground)

        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A card reaches into the title bar's unused lower band, and a view
    /// with no background there drags the window instead of being clicked.
    override var mouseDownCanMoveWindow: Bool { false }

    // A wrapper has to be invisible to what it wraps. The columns it holds
    // are `NSHostingView`s, which are flipped and lay out from the top, and
    // whoever addresses a column (the layout dump, the E2E scenarios) now
    // reaches the card first — so the card reads top-down too, and hands on
    // the context menu it has none of.

    override var isFlipped: Bool { true }

    /// A card starts under the tab strip, which is shorter than the title
    /// bar — so its top reaches into it, and AppKit would hand its SwiftUI
    /// content a 14 pt safe-area inset it must not have. The strip zeroes
    /// its own for the same reason (`TabStripHostingView`).
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func menu(for event: NSEvent) -> NSMenu? {
        super.menu(for: event) ?? content.menu(for: event)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        guard let layer = content.layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = edge.cgColor
    }
}

/// Hosts a column's view controller inside a `CardColumn`, so the split
/// view's item measures the card and the controller keeps its own view.
final class CardColumnController: NSViewController {
    private let child: NSViewController
    private let fill: NSColor
    private let theme: ChromeTheme

    init(_ child: NSViewController, fill: NSColor, theme: ChromeTheme) {
        self.child = child
        self.fill = fill
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
        addChild(child)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = CardColumn(content: child.view, fill: fill, theme: theme)
    }
}
