import CoreGraphics
import Foundation
import QuartzCore

/// Where tab peek puts every tab, and how a key moves between them. Pure
/// geometry — no AppKit, no views: the controller turns a placement into a
/// layer transform and the chrome draws its card at the same rectangle, so
/// the picture and the terminal under it can never drift apart.
///
/// Everything here is in a **top-left origin** space the size of the
/// terminal container, as `SplitTree.layout` is; the controller flips it
/// into the container's own coordinates.
enum TabPeek {
    /// How far the gesture has gone: 0 closed, 1 the strip under the tab
    /// bar, 2 the full grid. In between the two are interpolated.
    enum Stage: Int, Comparable {
        case closed = 0, peek = 1, overview = 2

        static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }

        var progress: Double { Double(rawValue) }
    }

    /// One tab in the peek.
    struct Card: Equatable {
        let id: UUID
        /// The whole card: its header and the terminal under it.
        let frame: CGRect
        /// Where the tab's full-size host has to land. Equal to `frame`
        /// while the selected tab is still the real terminal (stage 1):
        /// that one is pushed down, not turned into a card, so it has no
        /// title bar — which is how the chrome knows not to draw one.
        let content: CGRect
        let isSelected: Bool

        var hasHeader: Bool { frame.height > content.height }
    }

    enum Direction { case left, right, up, down }

    // MARK: Metrics

    /// The card's title bar, above its terminal.
    static let headerHeight: CGFloat = 22
    static let gap: CGFloat = 14
    static let margin: CGFloat = 16
    /// The group title ("terminus") above the grid.
    static let groupHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 8
    /// How much of the window the strip takes, and so how far the selected
    /// terminal is pushed down.
    static let pushFraction: CGFloat = 0.42
    /// Panes rendered at full rate; past this they are drawn by hand at a
    /// slower cadence so twenty tabs don't all run at 60 fps.
    static let liveLimit = 12

    // MARK: Placements

    /// Every tab's card for a gesture `progress` of 0…2.
    ///
    /// Up to 1 the selected tab keeps its full size and slides down while
    /// the others come in as a row above it; past 1 every card — the
    /// selected one included — travels to its grid cell. At exactly 1 both
    /// halves give the same answer, so the stages meet without a jump.
    static func placements(
        tabs: [UUID], selected: UUID?, progress: Double, in bounds: CGRect, stripScroll: CGFloat = 0
    ) -> [Card] {
        guard !tabs.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let p = min(max(progress, 0), 2)
        guard p > 0 else { return [] }
        if p <= 1 { return peekCards(tabs: tabs, selected: selected, p: p, in: bounds, stripScroll: stripScroll) }

        let from = peekCards(tabs: tabs, selected: selected, p: 1, in: bounds, stripScroll: stripScroll)
        let to = gridCards(tabs: tabs, selected: selected, in: bounds)
        let t = CGFloat(p - 1)
        return to.map { target in
            guard let start = from.first(where: { $0.id == target.id }) else { return target }
            return Card(
                id: target.id,
                frame: lerp(start.frame, target.frame, t),
                content: lerp(start.content, target.content, t),
                isSelected: target.isSelected)
        }
    }

    /// The strip: the selected tab full size, pushed down by `p`; the rest
    /// in one row that slides in from above the top edge.
    private static func peekCards(
        tabs: [UUID], selected: UUID?, p: Double, in bounds: CGRect, stripScroll: CGFloat
    ) -> [Card] {
        let push = (bounds.height * pushFraction).rounded()
        let cardHeight = max(push - margin * 2, headerHeight + 1)
        let contentHeight = cardHeight - headerHeight
        let cardWidth = (contentHeight * (bounds.width / bounds.height)).rounded()
        // Above the top edge at 0, in place at 1.
        let drop = (margin + cardHeight) * CGFloat(p) - cardHeight
        var x = bounds.minX + margin - stripScroll

        var cards: [Card] = []
        for id in tabs {
            if id == selected {
                let content = bounds.offsetBy(dx: 0, dy: (CGFloat(p) * push).rounded())
                cards.append(Card(id: id, frame: content, content: content, isSelected: true))
                continue
            }
            let frame = CGRect(x: x, y: bounds.minY + drop, width: cardWidth, height: cardHeight)
            cards.append(Card(id: id, frame: frame, content: contentRect(in: frame), isSelected: false))
            x += cardWidth + gap
        }
        return cards
    }

    /// The grid: cells keeping the terminal's shape, rows centred, the
    /// whole block centred under the group title.
    private static func gridCards(tabs: [UUID], selected: UUID?, in bounds: CGRect) -> [Card] {
        let area = CGRect(
            x: bounds.minX + margin, y: bounds.minY + margin + groupHeight,
            width: bounds.width - margin * 2, height: bounds.height - margin * 2 - groupHeight)
        guard area.width > 0, area.height > 0 else { return [] }

        let (columns, scale) = grid(count: tabs.count, in: area.size, shape: bounds.size)
        let cardWidth = (bounds.width * scale).rounded()
        let cardHeight = (bounds.height * scale).rounded() + headerHeight
        let rows = Int((Double(tabs.count) / Double(columns)).rounded(.up))
        let blockHeight = CGFloat(rows) * cardHeight + CGFloat(rows - 1) * gap
        let top = area.minY + max((area.height - blockHeight) / 2, 0)

        var cards: [Card] = []
        for (index, id) in tabs.enumerated() {
            let row = index / columns
            let column = index % columns
            // The last row may be short: centre it rather than leave a gap.
            let inRow = min(columns, tabs.count - row * columns)
            let rowWidth = CGFloat(inRow) * cardWidth + CGFloat(inRow - 1) * gap
            let left = area.minX + (area.width - rowWidth) / 2
            let frame = CGRect(
                x: left + CGFloat(column) * (cardWidth + gap),
                y: top + CGFloat(row) * (cardHeight + gap),
                width: cardWidth, height: cardHeight)
            cards.append(Card(id: id, frame: frame, content: contentRect(in: frame), isSelected: id == selected))
        }
        return cards
    }

    /// How many columns fit `count` cards of `shape`'s proportions in
    /// `area` largest, and the scale that gets them there.
    static func grid(count: Int, in area: CGSize, shape: CGSize) -> (columns: Int, scale: CGFloat) {
        guard count > 0, area.width > 0, area.height > 0, shape.width > 0, shape.height > 0 else { return (1, 0) }
        var best = (columns: 1, scale: CGFloat(0))
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows) - headerHeight
            guard cellWidth > 0, cellHeight > 0 else { continue }
            let scale = min(cellWidth / shape.width, cellHeight / shape.height)
            if scale > best.scale { best = (columns, scale) }
        }
        return best.scale > 0 ? best : (count, 0)
    }

    /// The terminal's part of a card: everything under its title bar.
    static func contentRect(in card: CGRect) -> CGRect {
        CGRect(x: card.minX, y: card.minY + headerHeight, width: card.width, height: max(card.height - headerHeight, 0))
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    // MARK: The transform a host needs

    /// Maps a host filling `bounds` onto `target`, and never touches the
    /// view's frame — which is the whole point: a resized terminal would
    /// reflow its pty.
    ///
    /// Measured on the real thing (`TERMINUS_DUMP_PEEK`), because two
    /// details decide the arithmetic and neither is obvious:
    ///
    /// - AppKit anchors a layer-backed view's layer at (0, 0) with position
    ///   (0, 0), so the scale is about the layer's own origin — not its
    ///   centre, which would put each preview's content a third of a card
    ///   down and to the right.
    /// - The host's layer has its geometry flipped (the view is), its
    ///   superlayer's is not. So x is the top-left one the placements are
    ///   in, while y has to be mirrored — otherwise every card holds its
    ///   terminal upside down the page, mirrored about the middle.
    static func transform(from bounds: CGRect, to target: CGRect) -> CATransform3D {
        guard bounds.width > 0, bounds.height > 0 else { return CATransform3DIdentity }
        return CATransform3DConcat(
            CATransform3DMakeScale(target.width / bounds.width, target.height / bounds.height, 1),
            CATransform3DMakeTranslation(target.minX - bounds.minX, bounds.maxY - target.maxY, 0))
    }

    /// Where `transform` actually puts a point of the host, back in the
    /// top-left space the placements use. The views can't be asked in a
    /// unit test, so this is the arithmetic the tests check.
    static func place(_ point: CGPoint, from bounds: CGRect, by t: CATransform3D) -> CGPoint {
        CGPoint(
            x: point.x * t.m11 + t.m41,
            y: bounds.height - ((bounds.maxY - point.y) * t.m22 + t.m42))
    }

    // MARK: Moving the highlight

    /// The card an arrow key lands on: the nearest one whose centre lies
    /// in that direction, measured with the across-axis distance weighted
    /// so a card in the next row never beats one in this one.
    static func move(_ direction: Direction, from id: UUID, in cards: [Card]) -> UUID {
        guard let current = cards.first(where: { $0.id == id }) else { return cards.first?.id ?? id }
        let origin = CGPoint(x: current.frame.midX, y: current.frame.midY)
        var best: (id: UUID, cost: CGFloat)?
        for card in cards where card.id != id {
            let dx = card.frame.midX - origin.x
            let dy = card.frame.midY - origin.y
            let (along, across): (CGFloat, CGFloat)
            switch direction {
            case .left: (along, across) = (-dx, abs(dy))
            case .right: (along, across) = (dx, abs(dy))
            case .up: (along, across) = (-dy, abs(dx))
            case .down: (along, across) = (dy, abs(dx))
            }
            guard along > 0.5 else { continue }
            let cost = along + across * 3
            if best == nil || cost < best!.cost { best = (card.id, cost) }
        }
        return best?.id ?? id
    }

    /// Tab / ⇧Tab: the next card in reading order, wrapping.
    static func step(_ offset: Int, from id: UUID, in cards: [Card]) -> UUID {
        guard !cards.isEmpty else { return id }
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return cards[0].id }
        let n = cards.count
        return cards[((i + offset) % n + n) % n].id
    }
}
