import AppKit

/// The split view the cards sit in: no divider at all, drawn or measured.
///
/// The gap between two cards is the window showing through, and each card
/// holds its own half of it (`CardColumn.gap`). A wide divider was the
/// obvious way to make that gap — one number, and a grab area for free —
/// but a divider is measured even for a collapsed item: with the editor,
/// the changes pane and the inbox all shut, the window lost 30 pt down its
/// right side, and a pane closed *between* two open ones doubled the gap
/// there. A card's own margin is only spent when the card is on screen.
///
/// A zero-width divider is still draggable: the controller widens it to a
/// grab band (`WideDividerSplitViewController`), which is what that class
/// did before the cards and does again.
final class GapSplitView: NSSplitView {
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

    override var dividerThickness: CGFloat { 0 }
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
    /// The window showing through between two cards. Each card keeps half
    /// of it on each side, so the gap is the same whoever its neighbour is
    /// — and a card that isn't on screen costs nothing (`GapSplitView`).
    static let gap: CGFloat = 10
    /// Half the gap, which is what one card keeps on each side.
    static let margin: CGFloat = gap / 2

    /// Which of the theme's grounds a card is painted in. Held rather than
    /// the colour itself, so a card can be repainted when the terminal
    /// theme changes (`repaint`).
    enum Fill {
        /// A panel: the sidebar, the changes pane, the inbox.
        case panel
        /// The terminal's own background: the terminal column, the editor.
        case terminal

        @MainActor func color(_ theme: ChromeTheme) -> NSColor {
            switch self {
            case .panel: theme.cardNS
            case .terminal: theme.termNS
            }
        }
    }

    private let content: NSView
    private let ground = CALayer()
    private let fill: Fill
    private let theme: ChromeTheme

    init(content: NSView, fill: Fill, theme: ChromeTheme) {
        self.content = content
        self.fill = fill
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        ground.cornerRadius = Self.cornerRadius
        layer?.addSublayer(ground)
        repaint()

        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.margin),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.margin),
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

    /// What the card is painted in now — the E2E run reads it to check a
    /// theme change reached the layers.
    var groundColor: NSColor? { ground.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } }

    /// Takes the colours the theme holds now — the terminal's theme can be
    /// changed while the window is open (Settings ▸ Themes).
    func repaint() {
        ground.backgroundColor = fill.color(theme).cgColor
        // The hairline alone separates a card from a dark window; on a
        // light one it needs the lift too.
        ground.shadowOpacity = theme.isDark ? 0 : 0.10
        ground.shadowColor = NSColor.black.cgColor
        ground.shadowRadius = 6
        ground.shadowOffset = CGSize(width: 0, height: -2)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds.insetBy(dx: Self.margin, dy: 0)
        guard let layer = content.layer else { return }
        layer.cornerRadius = Self.cornerRadius
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = theme.borderNS.cgColor
    }
}

/// Hosts a column's view controller inside a `CardColumn`, so the split
/// view's item measures the card and the controller keeps its own view.
final class CardColumnController: NSViewController {
    private let child: NSViewController
    private let fill: CardColumn.Fill
    private let theme: ChromeTheme

    init(_ child: NSViewController, fill: CardColumn.Fill, theme: ChromeTheme) {
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
