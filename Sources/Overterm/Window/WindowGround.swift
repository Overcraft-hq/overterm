import AppKit

/// The window's ground while it is translucent (Settings ▸ Appearance ▸
/// Opacity): the terminal's colour at the opacity, behind everything —
/// except under the terminals.
///
/// A terminal surface draws its own background at Ghostty's
/// `background-opacity`, and it doesn't cover what is under it: libghostty
/// hands Core Animation a colour that isn't premultiplied, so the ground
/// under a surface *adds* to it. With the window's colour under the
/// terminals, the terminal came out nearly opaque (two layers) — or, with
/// the surface drawing nothing, lighter than everything around it. So the
/// ground is cut away where a surface is, clipped to its card's rounded
/// corners, and each place has exactly one layer.
///
/// The window's own background is clear meanwhile; opaque, this view is
/// hidden and the window paints `ChromeTheme.winNS` as before.
final class WindowGroundView: NSView {
    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    // Paint only: every click is for what lies over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard color.alphaComponent > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        var ground = CGPath(rect: bounds, transform: nil)
        for hole in holes() { ground = ground.subtracting(hole) }
        context.addPath(ground)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    /// Each terminal on screen, as much of it as its card shows.
    func holes() -> [CGPath] {
        guard let root = window?.contentView else { return [] }
        var found: [CGPath] = []
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if sub is TerminalView {
                    let surface = CGPath(rect: convert(sub.bounds, from: sub), transform: nil)
                    if let card = sub.enclosingCard {
                        let rect = convert(card.cardRect, from: card)
                        let radius = CardColumn.cornerRadius
                        found.append(surface.intersection(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)))
                    } else {
                        found.append(surface)
                    }
                } else {
                    walk(sub)
                }
            }
        }
        walk(root)
        return found
    }
}

extension NSView {
    /// The card a view is drawn in, if any.
    fileprivate var enclosingCard: CardColumn? {
        var view = superview
        // Bounded: a view tree is not deep, and a loop must end.
        for _ in 0..<64 {
            guard let current = view else { return nil }
            if let card = current as? CardColumn { return card }
            view = current.superview
        }
        return nil
    }
}

extension NSWindow {
    /// Something moved or showed a terminal: the ground's holes again.
    func groundChanged() {
        for case let ground as WindowGroundView in contentView?.subviews ?? [] where !ground.isHidden { ground.needsDisplay = true }
    }
}
