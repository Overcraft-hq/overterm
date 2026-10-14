import SwiftUI

/// The strip down the right edge of a pane: the whole scrollback as one
/// column, the viewport as a thumb, and a mark for every command.
///
/// A terminal's scrollback is the one place in the window with no overview
/// at all — you scroll until you recognise something. The map answers "is
/// there a failure above me, and how far" without scrolling, and clicking
/// a mark goes there.
///
/// It draws over the terminal rather than beside it. libghostty owns the
/// grid, so insetting it would mean 16 pt off every pane's width forever
/// for something you look at while scrolling; macOS's own scrollbars
/// overlay for the same reason.
struct ScrollMapView: View {
    @ObservedObject var blocks: PaneBlocks
    let theme: ChromeTheme
    /// Scroll the pane by this many rows (positive is down).
    let scroll: (Int) -> Void

    static let width: CGFloat = 16

    private var ledger: CommandLedger { blocks.ledger }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .top) {
                Rectangle().fill(theme.win.opacity(0.5))
                if let viewport = ledger.viewport {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.text.opacity(0.14))
                        .frame(height: max(24, span(viewport, height)))
                        .offset(y: start(viewport, height))
                        .padding(.horizontal, 3)
                }
                ForEach(marks) { mark in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(mark.color)
                        .frame(height: mark.failed ? 4 : 2)
                        .offset(y: mark.y * height)
                        .padding(.horizontal, mark.failed ? 2 : 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                // Put what was clicked at the top of the viewport.
                let row = UInt64((point.y / max(height, 1)) * Double(ledger.total))
                scroll(ledger.lines(toReach: row))
            }
        }
        .frame(width: Self.width)
        .opacity(blocks.showMap ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: blocks.showMap)
        // It lies over the terminal's right edge, so while it is invisible
        // it must be as if it were not there — otherwise selecting text at
        // the edge of a pane would hit the map instead.
        .allowsHitTesting(blocks.showMap)
        .onHover { blocks.hoverMap($0) }
        .help("The scrollback — a mark for each command, red where one failed")
    }

    private struct Mark: Identifiable {
        let id: Int
        let y: Double
        let failed: Bool
        let color: Color
    }

    private var marks: [Mark] {
        ledger.blocks.compactMap { block in
            guard let position = ledger.position(of: block) else { return nil }
            return Mark(
                id: block.id, y: position.lowerBound, failed: block.failed,
                color: block.failed ? TabStatusStyle.failed : (block.isRunning ? TabStatusStyle.working : theme.text3))
        }
    }

    private func start(_ range: ClosedRange<Double>, _ height: CGFloat) -> CGFloat {
        CGFloat(range.lowerBound) * height
    }

    private func span(_ range: ClosedRange<Double>, _ height: CGFloat) -> CGFloat {
        CGFloat(range.upperBound - range.lowerBound) * height
    }
}
