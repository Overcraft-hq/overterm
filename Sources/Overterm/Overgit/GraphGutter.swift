import SwiftUI

/// The lanes beside one commit row, drawn from its `GraphRow`.
///
/// A `Canvas` per row rather than one for the list: the rows are lazy, so
/// only what is on screen is drawn, and a row redraws when its own line
/// changes rather than the whole history redrawing when one commit lands.
/// The rows must be a fixed height or the lines do not meet.
struct GraphGutter: View {
    let row: GraphRow
    /// The whole list's width in lanes, so subjects line up.
    let lanes: Int
    let height: CGFloat

    /// A ring of lane colours. Fixed hues at one saturation and brightness
    /// so they read on a light ground and a dark one alike — the chrome's
    /// own tokens are derived from the terminal theme and there are only
    /// three of them, which is not enough to tell six branches apart.
    static let laneColors: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 0.95),
        Color(red: 0.47, green: 0.78, blue: 0.52),
        Color(red: 0.90, green: 0.60, blue: 0.32),
        Color(red: 0.78, green: 0.52, blue: 0.88),
        Color(red: 0.36, green: 0.76, blue: 0.78),
        Color(red: 0.92, green: 0.47, blue: 0.55),
    ]

    static func color(_ lane: Int) -> Color { laneColors[lane % laneColors.count] }

    /// What one lane is given, in points. Six of them is 66 pt — the widest
    /// the gutter ever gets (`GraphLayout`'s own cap).
    static let laneWidth: CGFloat = 11

    static func width(lanes: Int) -> CGFloat { CGFloat(max(1, lanes)) * laneWidth }

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            func x(_ lane: Int) -> CGFloat { Self.laneWidth * (CGFloat(lane) + 0.5) }

            for edge in row.through {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: 0))
                path.addLine(to: CGPoint(x: x(edge.to), y: size.height))
                context.stroke(path, with: .color(Self.color(edge.from)), lineWidth: 1.6)
            }
            for lane in row.incoming {
                context.stroke(bend(from: x(lane), y0: 0, to: x(row.lane), y1: middle), with: .color(Self.color(lane)), lineWidth: 1.6)
            }
            for lane in row.outgoing {
                context.stroke(
                    bend(from: x(row.lane), y0: middle, to: x(lane), y1: size.height), with: .color(Self.color(lane)), lineWidth: 1.6)
            }
            let dot = CGRect(x: x(row.lane) - 3.5, y: middle - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: dot), with: .color(Self.color(row.lane)))
        }
        .frame(width: Self.width(lanes: lanes), height: height)
    }

    /// A straight line down its own lane, or a quarter turn into another —
    /// the corner is rounded by putting the control point at the turn.
    private func bend(from x0: CGFloat, y0: CGFloat, to x1: CGFloat, y1: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x0, y: y0))
        if x0 == x1 {
            path.addLine(to: CGPoint(x: x1, y: y1))
        } else {
            path.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: x0, y: y1))
        }
        return path
    }
}
