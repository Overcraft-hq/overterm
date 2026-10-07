import CoreGraphics
import Foundation

/// Three fingers down the trackpad, turned into a peek progress.
///
/// Pure on purpose: it is fed a finger count and where they are, never an
/// `NSEvent`, so the tests can drive it without a trackpad. The view layer
/// reads `NSTouch.normalizedPosition` (0 at the bottom, 1 at the top) and
/// hands over the average.
struct TabPeekGesture {
    /// Settings ▸ General. Three is the default; four is the way out when
    /// macOS claims three fingers for Mission Control or App Exposé.
    enum Fingers: String, CaseIterable, Identifiable, Codable {
        case off, three, four

        var id: String { rawValue }
        /// 0 when the gesture is switched off.
        var count: Int {
            switch self {
            case .off: 0
            case .three: 3
            case .four: 4
            }
        }
        var name: String {
            switch self {
            case .off: "Off"
            case .three: "Three fingers"
            case .four: "Four fingers"
            }
        }
    }

    enum Outcome: Equatable {
        case none
        /// Follow the fingers.
        case update(Double)
        /// They left the trackpad: animate to this stage.
        case settle(TabPeek.Stage)
    }

    /// How far the fingers travel for one stage, in normalized units.
    static let travel: CGFloat = 0.28
    /// Below this the hand is only resting, not swiping.
    static let threshold: CGFloat = 0.02

    private var origin: CGFloat?
    /// The progress the gesture started from, so a second swipe carries on
    /// from an open peek instead of snapping back to the strip.
    private var base: Double = 0
    /// A fresh swipe that starts at the grid runs the other way: down takes
    /// it back out. Reversing — swiping up — would be the natural way, but
    /// macOS claims three *and* four fingers up for Mission Control, and
    /// WindowServer recognizes it before any app sees a touch. So the whole
    /// loop is one direction: down opens the strip, down again the grid,
    /// down once more closes it.
    private var reversing = false
    private(set) var progress: Double = 0
    private(set) var isTracking = false

    init(progress: Double = 0) {
        self.progress = progress
    }

    /// The fingers moved (or arrived). `count` is how many are down.
    mutating func touched(count: Int, y: CGFloat, required: Int) -> Outcome {
        guard required > 0 else { return .none }
        guard count == required else {
            // A finger lifted or a fourth joined: the swipe is over.
            return isTracking ? end() : reset()
        }
        guard let origin else {
            self.origin = y
            base = progress
            reversing = progress >= TabPeek.Stage.overview.progress
            return .none
        }
        let delta = (origin - y) / Self.travel
        guard isTracking || abs(delta) > Self.threshold / Self.travel else { return .none }
        isTracking = true
        progress = min(max(base + Double(reversing ? -delta : delta), 0), 2)
        return .update(progress)
    }

    /// The fingers left the trackpad.
    mutating func ended() -> Outcome { isTracking ? end() : reset() }

    private mutating func end() -> Outcome {
        let stage = Self.nearest(progress)
        origin = nil
        reversing = false
        base = stage.progress
        progress = stage.progress
        isTracking = false
        return .settle(stage)
    }

    @discardableResult
    private mutating func reset() -> Outcome {
        origin = nil
        return .none
    }

    /// A gesture that never started leaves the peek where the keyboard put
    /// it; this keeps the two in step.
    mutating func settled(at stage: TabPeek.Stage) {
        origin = nil
        reversing = false
        isTracking = false
        base = stage.progress
        progress = stage.progress
    }

    static func nearest(_ progress: Double) -> TabPeek.Stage {
        TabPeek.Stage(rawValue: Int(progress.rounded())) ?? (progress > 1 ? .overview : .closed)
    }
}
