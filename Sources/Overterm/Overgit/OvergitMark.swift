import SwiftUI

/// Overgit's own mark, for the sidebar's icon bar.
///
/// Drawn rather than loaded: the app has no asset catalog and no SVG
/// pipeline — `Resources/` is the app icon and the themes — and one glyph
/// is not reason enough to add either. It is monochrome on purpose: the
/// icon bar tints it `text` when the panel is open and `text2` when it is
/// not, beside Apple's own symbols.
///
/// An arch over a branch: Overterm's "over", and git's.
struct OvergitMark: View {
    /// The design is drawn on a 24×24 square and scaled from there.
    private nonisolated static let side: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / Self.side
            ZStack {
                Strokes()
                    .stroke(style: StrokeStyle(lineWidth: 2.1 * scale, lineCap: .round, lineJoin: .round))
                Dots()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The arch, and the branch leaving the trunk.
    private struct Strokes: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / OvergitMark.side
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
            var path = Path()
            path.move(to: point(3.5, 8.5))
            path.addQuadCurve(to: point(20.5, 8.5), control: point(12, -0.5))
            path.move(to: point(7.5, 19))
            path.addQuadCurve(to: point(16.5, 13.5), control: point(7.5, 13.5))
            return path
        }
    }

    /// The two commits the branch runs between.
    private struct Dots: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / OvergitMark.side
            func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: rect.minX + (x - r) * s, y: rect.minY + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
            }
            var path = Path()
            path.addPath(dot(7.5, 19, 2.5))
            path.addPath(dot(16.5, 13.5, 2.5))
            return path
        }
    }
}
