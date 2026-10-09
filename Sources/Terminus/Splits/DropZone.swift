import CoreGraphics

/// Where a tab dragged over a pane would land.
///
/// Five targets in one rectangle, so the whole gesture is one drag with
/// no modifier to remember: the edges say which way to split, and the
/// middle — the big, easy target — just puts it in the tab.
///
/// Not "swap with this pane", which the designs draw: swapping two tabs'
/// panes is a no-op unless *both* are already split, and when the one
/// being dragged is a whole tab it would empty it. Pure, so the
/// thresholds can be read rather than felt out.
enum DropZone: String, CaseIterable, Equatable {
    case up, down, left, right, into

    /// What the overlay calls it.
    var name: String {
        switch self {
        case .up: "Split Up"
        case .down: "Split Down"
        case .left: "Split Left"
        case .right: "Split Right"
        case .into: "Add to this tab"
        }
    }

    var direction: SplitTree<TerminalView>.Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .into: .right
        }
    }

    /// How much of each edge is a split target. A quarter: enough to hit
    /// without aiming, small enough that the middle is clearly the middle.
    static let edge: CGFloat = 0.25

    /// The zone a point falls in, in a pane's own coordinates (y down).
    /// Nil when the point is outside it.
    static func at(_ point: CGPoint, in rect: CGRect) -> DropZone? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        // Top and bottom win the corners: a pane is wider than it is tall,
        // so its horizontal bands are the ones you hit by accident.
        if y < edge { return .up }
        if y > 1 - edge { return .down }
        if x < edge { return .left }
        if x > 1 - edge { return .right }
        return .into
    }

    /// The part of the pane a zone covers, for drawing it.
    func frame(in rect: CGRect) -> CGRect {
        let w = rect.width * Self.edge
        let h = rect.height * Self.edge
        switch self {
        case .up: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
        case .down: return CGRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
        case .left: return CGRect(x: rect.minX, y: rect.minY + h, width: w, height: rect.height - 2 * h)
        case .right: return CGRect(x: rect.maxX - w, y: rect.minY + h, width: w, height: rect.height - 2 * h)
        case .into:
            return CGRect(
                x: rect.minX + w, y: rect.minY + h, width: rect.width - 2 * w, height: rect.height - 2 * h)
        }
    }
}
