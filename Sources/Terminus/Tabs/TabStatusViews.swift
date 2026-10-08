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
    /// Warning orange: an agent blocked *on you*. Distinct from `signal`
    /// because "it wants something" and "it is busy" are different news.
    static let waiting = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let waitingNS = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    /// Work in progress: the system blue, which never means "act".
    static let working = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let done = Color(red: 0.36, green: 0.78, blue: 0.44)
    static let failed = Color(red: 0.94, green: 0.36, blue: 0.34)
    /// GitHub's "merged" purple, so a merged worktree reads like its PR.
    static let merged = Color(red: 0.64, green: 0.47, blue: 0.96)

    /// One activity as one colour, for the places that show a tab as a dot
    /// or a segment rather than a glyph — a collapsed island's foot, the
    /// "needs you" list. `idle` is the theme's, since nothing is not a
    /// status colour.
    static func color(for activity: TabActivity, idle: Color) -> Color {
        switch activity.mark {
        case .waiting: waiting
        case .failed: failed
        case .done: done
        case .none: activity.isWorking ? working : idle
        }
    }
}

/// The agent's glyph while it works: slowly breathing.
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

/// Waiting for you: a dot sending out a soft ring.
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

/// A ring with a quarter of it drawn, turning: the badge a working tab
/// wears in the corner of its icon, where a breathing glyph would be lost.
struct WorkingSpinner: View {
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LoopingStatus(kind: .spinning(size: size), animated: !reduceMotion)
            .frame(width: size, height: size)
            .help("Working")
    }
}

/// What a tab wants from you, in the corner of its icon tile.
///
/// One badge, and the most urgent wins: being blocked outranks having
/// failed, which outranks having finished, which outranks still working.
/// `ring` is the ground the badge sits on, drawn around it so it reads as
/// a sticker rather than as part of the glyph underneath.
struct StatusBadge: View {
    let activity: TabActivity
    let ring: Color
    var size: CGFloat = 12

    var body: some View {
        switch activity.mark {
        case .waiting: filled("exclamationmark.circle.fill", TabStatusStyle.waiting)
        case .failed: filled("xmark.circle.fill", TabStatusStyle.failed)
        case .done: filled("checkmark.circle.fill", TabStatusStyle.done)
        case .none:
            if activity.isWorking {
                WorkingSpinner(size: size).background(Circle().fill(ring).padding(-1))
            }
        }
    }

    private func filled(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .background(Circle().fill(ring).padding(1))
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
        case spinning(size: CGFloat)
        case sweeping

        /// What this motion means, and so what colour it is: blocked on you
        /// is warning orange, work in progress is the system blue.
        var color: NSColor {
            switch self {
            case .ringing: NSColor(TabStatusStyle.waiting)
            case .breathing, .spinning, .sweeping: NSColor(TabStatusStyle.working)
            }
        }
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
    private let arc = CAShapeLayer()

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
        let tint = kind.color.cgColor
        switch kind {
        case .breathing(let symbol, let size):
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(.init(paletteColors: [kind.color]))
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Working")?.withSymbolConfiguration(config)
            content.contents = image
            content.contentsGravity = .resizeAspect
            layer?.addSublayer(content)
            invalidateIntrinsicContentSize()
        case .ringing:
            ring.fillColor = nil
            ring.strokeColor = tint
            ring.lineWidth = 1.5
            content.contents = nil
            content.backgroundColor = tint
            if animated { layer?.addSublayer(ring) }
            layer?.addSublayer(content)
        case .spinning:
            // The whole ring faint, a quarter of it solid and turning.
            ring.fillColor = nil
            ring.strokeColor = kind.color.withAlphaComponent(0.3).cgColor
            ring.lineWidth = 2
            arc.fillColor = nil
            arc.strokeColor = tint
            arc.lineWidth = 2
            arc.lineCap = .round
            arc.strokeEnd = animated ? 0.25 : 0.75
            layer?.addSublayer(ring)
            layer?.addSublayer(arc)
        case .sweeping:
            track.backgroundColor = kind.color.withAlphaComponent(animated ? 0.18 : 0.7).cgColor
            slider.backgroundColor = tint
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
        case .spinning(let size):
            let inset = CGRect(x: b.midX - size / 2, y: b.midY - size / 2, width: size, height: size).insetBy(dx: 1, dy: 1)
            for shape in [ring, arc] {
                shape.bounds = CGRect(origin: .zero, size: inset.size)
                shape.position = CGPoint(x: b.midX, y: b.midY)
                shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
            }
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
        for layer in [content, ring, slider, arc] { layer.removeAllAnimations() }
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
        case .spinning:
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = 2 * Double.pi
            turn.duration = 0.9
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            arc.add(turn, forKey: "loop")
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
