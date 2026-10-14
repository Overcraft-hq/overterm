import AppKit

/// The editor's gutter: a line number beside the first fragment of every
/// line in view.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    var textColor: NSColor = .secondaryLabelColor
    var gutterColor: NSColor = .clear

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Since macOS 14 views don't clip by default, and the ruler's
        // content is as tall as the document: unclipped, its fill painted
        // over the editor header above it.
        if #available(macOS 14, *) { clipsToBounds = true }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Call after every text change.
    func textDidChange() {
        guard let text = textView?.string else { return }
        lineStarts = LineIndex.starts(of: text as NSString)
        let digits = max(3, String(lineStarts.count).count)
        let width = CGFloat(digits) * 8 + 20
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterColor.setFill()
        rect.intersection(bounds).fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let inset = textView.textContainerInset.height
        let offsetY = convert(NSPoint.zero, from: textView).y

        var drawn = Set<Int>()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let line = LineIndex.line(of: charIndex, in: self.lineStarts)
            // Wrapped lines: number only their first fragment.
            guard self.lineStarts[line - 1] == charIndex || charIndex == 0, drawn.insert(line).inserted else { return }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + inset + offsetY + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
        // The empty last line after a trailing newline.
        if let last = lineStarts.last, last == (textView.string as NSString).length, !drawn.contains(lineStarts.count) {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                let label = "\(lineStarts.count)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(x: ruleThickness - size.width - 8, y: extra.minY + inset + offsetY + (extra.height - size.height) / 2),
                    withAttributes: attributes)
            }
        }
    }
}
