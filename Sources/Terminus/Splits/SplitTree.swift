import CoreGraphics

/// A tab's panes: a binary tree of splits with panes at the leaves. Pure
/// value logic (insert, remove, neighbours, resize) — the view lays it out,
/// the tab holds it. Generic so the tests need no terminals.
indirect enum SplitTree<Leaf: AnyObject> {
    /// Side by side (a vertical divider) or stacked (a horizontal one).
    enum Axis: String, Codable {
        case horizontal, vertical
    }

    /// Where a new pane goes, relative to the one split.
    enum Direction {
        case right, down, left, up

        var axis: Axis { self == .right || self == .left ? .horizontal : .vertical }
        /// The new pane comes second (right of / below) the old one.
        var newSecond: Bool { self == .right || self == .down }
    }

    /// Moving the keyboard between panes.
    enum Focus {
        case previous, next, left, right, up, down
    }

    case leaf(Leaf)
    /// `ratio`: the first child's share of the space, 0…1.
    case split(axis: Axis, ratio: Double, first: SplitTree, second: SplitTree)

    /// Panes in reading order: left to right, top to bottom.
    var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .split(_, _, let first, let second): first.leaves + second.leaves
        }
    }

    func contains(_ leaf: Leaf) -> Bool { leaves.contains { $0 === leaf } }

    /// Splits `target` in two, `new` on the `direction` side, half each.
    func inserting(_ new: Leaf, at target: Leaf, _ direction: Direction) -> SplitTree {
        switch self {
        case .leaf(let leaf):
            guard leaf === target else { return self }
            let (first, second): (SplitTree, SplitTree) = direction.newSecond ? (.leaf(leaf), .leaf(new)) : (.leaf(new), .leaf(leaf))
            return .split(axis: direction.axis, ratio: 0.5, first: first, second: second)
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis, ratio: ratio, first: first.inserting(new, at: target, direction),
                second: second.inserting(new, at: target, direction))
        }
    }

    /// Without `leaf`; its sibling takes its parent's place. Nil when it
    /// was the last pane.
    func removing(_ leaf: Leaf) -> SplitTree? {
        switch self {
        case .leaf(let only):
            return only === leaf ? nil : self
        case .split(let axis, let ratio, let first, let second):
            guard let newFirst = first.removing(leaf) else { return second }
            guard let newSecond = second.removing(leaf) else { return first }
            return .split(axis: axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// Every split sized so each pane along it gets an equal share.
    func equalized() -> SplitTree {
        switch self {
        case .leaf: return self
        case .split(let axis, _, let first, let second):
            let a = Double(first.count(along: axis))
            let b = Double(second.count(along: axis))
            return .split(axis: axis, ratio: a / (a + b), first: first.equalized(), second: second.equalized())
        }
    }

    /// Panes side by side along `axis` (a nested split across it counts once).
    private func count(along axis: Axis) -> Int {
        switch self {
        case .leaf: 1
        case .split(let own, _, let first, let second):
            own == axis
                ? first.count(along: axis) + second.count(along: axis)
                : max(first.count(along: axis), second.count(along: axis))
        }
    }

    /// A split's divider line, the split's whole area and where it is in
    /// the tree — what dragging it needs.
    struct Divider {
        let path: [Bool]
        let rect: CGRect
        let container: CGRect
        let axis: Axis
    }

    /// Each pane's rectangle in `rect`, and each split's divider.
    func layout(in rect: CGRect, divider: CGFloat = 1) -> (panes: [(Leaf, CGRect)], dividers: [Divider]) {
        var panes: [(Leaf, CGRect)] = []
        var dividers: [Divider] = []
        func walk(_ node: SplitTree, _ rect: CGRect, _ path: [Bool]) {
            switch node {
            case .leaf(let leaf):
                panes.append((leaf, rect))
            case .split(let axis, let ratio, let first, let second):
                let (a, line, b) = Self.divide(rect, axis: axis, ratio: ratio, divider: divider)
                dividers.append(Divider(path: path, rect: line, container: rect, axis: axis))
                walk(first, a, path + [false])
                walk(second, b, path + [true])
            }
        }
        walk(self, rect, [])
        return (panes, dividers)
    }

    /// `rect` cut along `axis`: first part, divider, second part. Top-left
    /// origin (the first pane of a vertical split is the top one).
    static func divide(_ rect: CGRect, axis: Axis, ratio: Double, divider: CGFloat) -> (CGRect, CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let firstWidth = ((rect.width - divider) * ratio).rounded()
            return (
                CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                CGRect(x: rect.minX + firstWidth, y: rect.minY, width: divider, height: rect.height),
                CGRect(x: rect.minX + firstWidth + divider, y: rect.minY, width: rect.width - firstWidth - divider, height: rect.height)
            )
        case .vertical:
            let firstHeight = ((rect.height - divider) * ratio).rounded()
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: divider),
                CGRect(x: rect.minX, y: rect.minY + firstHeight + divider, width: rect.width, height: rect.height - firstHeight - divider)
            )
        }
    }

    /// The split at `path` (false = first child) with a new ratio, kept to
    /// 0.05…0.95 so no pane disappears.
    func settingRatio(_ newRatio: Double, at path: [Bool]) -> SplitTree {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        guard let step = path.first else {
            return .split(axis: axis, ratio: min(max(newRatio, 0.05), 0.95), first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        return step
            ? .split(axis: axis, ratio: ratio, first: first, second: second.settingRatio(newRatio, at: rest))
            : .split(axis: axis, ratio: ratio, first: first.settingRatio(newRatio, at: rest), second: second)
    }

    /// The pane to move to from `leaf`. Previous/next wrap around in reading
    /// order; directions pick the nearest pane on that side that overlaps it,
    /// preferring the most overlap.
    func neighbor(of leaf: Leaf, _ focus: Focus) -> Leaf? {
        let all = leaves
        guard all.count > 1, let index = all.firstIndex(where: { $0 === leaf }) else { return nil }
        switch focus {
        case .previous: return all[(index - 1 + all.count) % all.count]
        case .next: return all[(index + 1) % all.count]
        default: break
        }
        let frames = layout(in: CGRect(x: 0, y: 0, width: 1000, height: 1000)).panes
        guard let from = frames.first(where: { $0.0 === leaf })?.1 else { return nil }
        let candidates = frames.filter { $0.0 !== leaf }.compactMap { other, rect -> (Leaf, CGFloat, CGFloat)? in
            let gap: CGFloat
            let overlap: CGFloat
            switch focus {
            case .left:
                gap = from.minX - rect.maxX
                overlap = min(from.maxY, rect.maxY) - max(from.minY, rect.minY)
            case .right:
                gap = rect.minX - from.maxX
                overlap = min(from.maxY, rect.maxY) - max(from.minY, rect.minY)
            case .up:
                gap = from.minY - rect.maxY
                overlap = min(from.maxX, rect.maxX) - max(from.minX, rect.minX)
            default:
                gap = rect.minY - from.maxY
                overlap = min(from.maxX, rect.maxX) - max(from.minX, rect.minX)
            }
            return gap >= -0.5 && overlap > 0 ? (other, gap, overlap) : nil
        }
        return candidates.min { ($0.1, -$0.2) < ($1.1, -$1.2) }?.0
    }

    /// Ghostty's resize_split: the nearest split around `leaf` along the
    /// direction's axis moves its divider that way, by `amount` of its size.
    func resizing(_ leaf: Leaf, toward direction: Direction, by amount: Double) -> SplitTree {
        func walk(_ node: SplitTree) -> (SplitTree, Bool) {
            guard case .split(let axis, let ratio, let first, let second) = node, node.contains(leaf) else { return (node, false) }
            let (newFirst, inFirst) = walk(first)
            if inFirst { return (.split(axis: axis, ratio: ratio, first: newFirst, second: second), true) }
            let (newSecond, inSecond) = walk(second)
            if inSecond { return (.split(axis: axis, ratio: ratio, first: first, second: newSecond), true) }
            guard axis == direction.axis else { return (node, false) }
            let moved = direction.newSecond ? ratio + amount : ratio - amount
            return (.split(axis: axis, ratio: min(max(moved, 0.05), 0.95), first: first, second: second), true)
        }
        return walk(self).0
    }
}
