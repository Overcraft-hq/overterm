import AppKit

/// An NSMenuItem that runs a closure — keeps menu building declarative.
package final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    package init(_ title: String, enabled: Bool = true, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: "")
        self.target = self
        self.state = state
    }

    package required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() { handler() }
}

extension TabColor {
    /// A filled dot of the colour, for menu items.
    package var swatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}
