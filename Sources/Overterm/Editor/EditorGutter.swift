import AppKit

/// A change against the last commit, for the gutter: lines added or
/// modified (0-based, in the text now), or removed after `lines.lowerBound`.
struct GitGutterMark: Equatable {
    enum Kind: Equatable { case added, modified, deleted }
    let kind: Kind
    let lines: Range<Int>
}

/// The editor's left margin: line numbers (the caret's brighter, or counted
/// from it for vim), a bar where the file differs from the last commit, and
/// a dot on lines with problems. A click on a number selects its line.
@MainActor
final class EditorGutter: NSRulerView {
    private weak var codeView: CodeTextView?
    private(set) var lineStarts: [Int] = [0]
    var theme = EditorTheme(dark: true, background: .black) {
        didSet { needsDisplay = true }
    }
    var relativeNumbers = false {
        didSet { if relativeNumbers != oldValue { needsDisplay = true } }
    }
    var gitMarks: [GitGutterMark] = [] {
        didSet { if gitMarks != oldValue { needsDisplay = true } }
    }
    /// Worst severity per 0-based line.
    var problemLines: [Int: EditorDiagnostic.Severity] = [:] {
        didSet { if problemLines != oldValue { needsDisplay = true } }
    }

    init(textView: CodeTextView) {
        codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
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
        guard let codeView else { return }
        lineStarts = LineIndex.starts(of: codeView.string as NSString)
        updateThickness()
        needsDisplay = true
    }

    func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let width = (CGFloat(digits) * digitWidth + 30).rounded()
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    private var numberFont: NSFont {
        let size = max(9, (codeView?.font?.pointSize ?? 13) - 1)
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private var digitWidth: CGFloat { ("8" as NSString).size(withAttributes: [.font: numberFont]).width }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        theme.background.setFill()
        rect.intersection(bounds).fill()
        guard let codeView, let layoutManager = codeView.layoutManager, let container = codeView.textContainer else { return }
        let text = codeView.string as NSString
        let offsetY = convert(NSPoint.zero, from: codeView).y
        // The characters on screen, laid out if they weren't (non-contiguous
        // layout only lays out what was asked for: enumerating fragments
        // alone skipped lines never laid out, and numbered almost none).
        let glyphs = layoutManager.glyphRange(forBoundingRect: codeView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = LineIndex.line(of: min(codeView.selectedRange().location, text.length), in: lineStarts)
        let font = numberFont
        var line = LineIndex.line(of: visible.location, in: lineStarts)
        let marks = gitMarks
        while line <= lineStarts.count {
            let start = lineStarts[line - 1]
            if start > NSMaxRange(visible) { break }
            let fragment = codeView.lineRect(at: start)
            let y = fragment.minY + offsetY
            if y > bounds.maxY { break }
            let isCaret = line == caretLine
            let number = relativeNumbers && !isCaret ? abs(line - caretLine) : line
            let label = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isCaret ? theme.activeLineNumber : theme.lineNumber,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y + (fragment.height - size.height) / 2), withAttributes: attributes)
            if let severity = problemLines[line - 1] {
                let color = severity == .error ? theme.error : severity == .warning ? theme.warning : theme.info
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 7, y: y + fragment.height / 2 - 2.5, width: 5, height: 5)).fill()
            }
            for mark in marks where mark.kind != .deleted && mark.lines.contains(line - 1) {
                (mark.kind == .added ? theme.gitAdded : theme.gitModified).setFill()
                NSRect(x: ruleThickness - 4, y: y, width: 2.5, height: fragment.height).fill()
            }
            for mark in marks where mark.kind == .deleted && mark.lines.lowerBound == line {
                theme.gitDeleted.setFill()
                let tip = NSBezierPath()
                tip.move(to: NSPoint(x: ruleThickness - 5, y: y - 3.5))
                tip.line(to: NSPoint(x: ruleThickness - 1, y: y))
                tip.line(to: NSPoint(x: ruleThickness - 5, y: y + 3.5))
                tip.close()
                tip.fill()
            }
            line += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let codeView else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inText = codeView.convert(NSPoint(x: 0, y: point.y), from: self)
        guard let layoutManager = codeView.layoutManager, let container = codeView.textContainer else { return }
        let glyph = layoutManager.glyphIndex(
            for: NSPoint(x: 0, y: inText.y - codeView.textContainerOrigin.y), in: container, fractionOfDistanceThroughGlyph: nil)
        let text = codeView.string as NSString
        let index = text.length == 0 ? 0 : layoutManager.characterIndexForGlyph(at: glyph)
        let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        codeView.window?.makeFirstResponder(codeView)
        codeView.setSelectedRange(lineRange)
    }
}
