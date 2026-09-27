import AppKit
import QuartzCore
import SwiftUI

/// How a tab shows what its agent is doing. Motion is the signal's volume:
/// working breathes, waiting sends a ring out, done and failed sit still —
/// so five busy tabs stay calm and the one that wants you stands out.
/// With Reduce Motion on, everything is still and colour carries it.
enum TabStatusStyle {
    /// Signal yellow: the brand's "look here".
    static let signal = Color(red: 1.0, green: 0.882, blue: 0.29)
    static let done = Color(red: 0.36, green: 0.78, blue: 0.44)
    static let failed = Color(red: 0.94, green: 0.36, blue: 0.34)
    /// GitHub's "merged" purple, so a merged worktree reads like its PR.
    static let merged = Color(red: 0.64, green: 0.47, blue: 0.96)
}

/// The agent's glyph while it works: signal yellow, slowly breathing.
struct WorkingGlyph: View {
    let symbol: String
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingStatus(kind: .breathing(symbol: symbol, size: size), animated: !reduceMotion)
            .fixedSize()
            .help("Working")
    }
}

/// Waiting for you: a yellow dot sending out a soft ring.
struct WaitingDot: View {
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingStatus(kind: .ringing(size: size), animated: !reduceMotion)
            .frame(width: size * 2.4, height: size * 2.4)
    }
}

/// Done or failed while you were away: still, small, coloured.
struct ResultMark: View {
    let failed: Bool
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(failed ? TabStatusStyle.failed : TabStatusStyle.done)
    }
}

/// A thin bar sliding along the bottom of a working tab, like a page
/// loading in Chrome — visible even on a 38 pt pinned tab.
struct WorkingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingStatus(kind: .sweeping, animated: !reduceMotion).frame(height: 2)
    }
}

/// The three motions, run by Core Animation rather than SwiftUI. A SwiftUI
/// `repeatForever` animation re-renders its view on the main thread every
/// frame: five working tabs took the app from 2.6% to 11.8% CPU, all day
/// while agents work. A CAAnimation, once added, is the window server's.
private struct LoopingStatus: NSViewRepresentable {
    enum Kind: Equatable {
        case breathing(symbol: String, size: CGFloat)
        case ringing(size: CGFloat)
        case sweeping
    }

    let kind: Kind
    let animated: Bool

    func makeNSView(context: Context) -> LoopingStatusView { LoopingStatusView() }

    func updateNSView(_ view: LoopingStatusView, context: Context) {
        view.configure(kind, animated: animated)
    }
}

private final class LoopingStatusView: NSView {
    private var kind: LoopingStatus.Kind?
    private var animated = false
    private var image: NSImage?
    private let content = CALayer()
    private let ring = CAShapeLayer()
    private let track = CALayer()
    private let slider = CALayer()
    private static let signal = NSColor(TabStatusStyle.signal).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        if case .breathing = kind, let image { return image.size }
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Called on every SwiftUI update of the tab strip; only a real change
    /// rebuilds, or the motion would restart on every title change.
    func configure(_ kind: LoopingStatus.Kind, animated: Bool) {
        guard kind != self.kind || animated != self.animated else { return }
        self.kind = kind
        self.animated = animated
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        switch kind {
        case .breathing(let symbol, let size):
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(TabStatusStyle.signal)]))
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Working")?.withSymbolConfiguration(config)
            content.contents = image
            content.contentsGravity = .resizeAspect
            layer?.addSublayer(content)
            invalidateIntrinsicContentSize()
        case .ringing:
            ring.fillColor = nil
            ring.strokeColor = Self.signal
            ring.lineWidth = 1.5
            content.contents = nil
            content.backgroundColor = Self.signal
            if animated { layer?.addSublayer(ring) }
            layer?.addSublayer(content)
        case .sweeping:
            track.backgroundColor = NSColor(TabStatusStyle.signal).withAlphaComponent(animated ? 0.18 : 0.7).cgColor
            slider.backgroundColor = Self.signal
            layer?.masksToBounds = true
            layer?.addSublayer(track)
            if animated { layer?.addSublayer(slider) }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let kind else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        switch kind {
        case .breathing:
            content.frame = b
            content.contentsScale = window?.backingScaleFactor ?? 2
        case .ringing(let size):
            let dot = CGRect(x: b.midX - size / 2, y: b.midY - size / 2, width: size, height: size)
            content.frame = dot
            content.cornerRadius = size / 2
            ring.bounds = CGRect(origin: .zero, size: dot.size)
            ring.position = CGPoint(x: b.midX, y: b.midY)
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        case .sweeping:
            layer?.cornerRadius = b.height / 2
            track.frame = b
            slider.frame = CGRect(x: 0, y: 0, width: b.width * 0.4, height: b.height)
            slider.cornerRadius = b.height / 2
        }
        CATransaction.commit()
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    /// (Re)adds the loop — after a size change the sweep's distance is new.
    private func restart() {
        for layer in [content, ring, slider] { layer.removeAllAnimations() }
        guard animated, window != nil, let kind else { return }
        switch kind {
        case .breathing:
            content.add(Self.loop("opacity", from: 1.0, to: 0.35, duration: 0.75, autoreverses: true, .easeInEaseOut), forKey: "loop")
        case .ringing:
            let group = CAAnimationGroup()
            group.animations = [
                Self.loop("transform.scale", from: 1.0, to: 2.4, duration: 1.4, autoreverses: false, .easeOut),
                Self.loop("opacity", from: 0.9, to: 0.0, duration: 1.4, autoreverses: false, .easeOut),
            ]
            group.duration = 1.4
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "loop")
        case .sweeping:
            let width = bounds.width
            guard width > 0 else { return }
            // Its centre from 0.4 widths before the start to past the end.
            slider.add(
                Self.loop("position.x", from: width * -0.2, to: width * 1.2, duration: 1.1, autoreverses: false, .linear),
                forKey: "loop")
        }
    }

    private static func loop(
        _ keyPath: String, from: Double, to: Double, duration: CFTimeInterval, autoreverses: Bool,
        _ timing: CAMediaTimingFunctionName
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        animation.isRemovedOnCompletion = false
        return animation
    }
}
