import AppKit
import Combine

/// A ring around the output of the command that failed, drawn over the
/// grid.
///
/// libghostty draws the grid and will not draw anything of ours inside it,
/// so a failed command cannot be given a background the way the design
/// has it. What it can be given is a frame on top — and the frame has to
/// be inert: this lies over live terminal text, and anything that takes a
/// click here takes it away from selecting output.
///
/// Rows become points through the cell's height, which libghostty reports,
/// and the viewport's top row, which it pushes on every scroll. Both move
/// on the same beat, so the frame stays with its output.
final class BlockFrameView: NSView {
    private let blocks: PaneBlocks
    private let cellHeight: () -> CGFloat
    private var watch: AnyCancellable?

    init(blocks: PaneBlocks, cellHeight: @escaping () -> CGFloat) {
        self.blocks = blocks
        self.cellHeight = cellHeight
        super.init(frame: .zero)
        wantsLayer = true
        watch = blocks.objectWillChange.sink { [weak self] in
            // objectWillChange fires before the value lands.
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    /// Never takes the mouse: the terminal underneath owns every point.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let ledger = blocks.ledger
        let cell = cellHeight()
        guard cell > 0, ledger.rows > 0 else { return }
        for block in ledger.blocks where block.failed && block.isLocated {
            // Only the part of it that is on screen.
            let top = max(block.startRow, ledger.offset)
            let bottom = min(block.endRow, ledger.offset + ledger.rows - 1)
            guard bottom >= top else { continue }
            let y = CGFloat(top - ledger.offset) * cell
            let height = CGFloat(bottom - top + 1) * cell
            let rect = NSRect(x: 1, y: y, width: bounds.width - 2, height: height).insetBy(dx: 0, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor(TabStatusStyle.failed).withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor(TabStatusStyle.failed).withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
