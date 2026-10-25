import AppKit

/// What the editor pane does for the text view: everything that needs the
/// document, its language or a language server.
@MainActor
protocol CodeTextViewHost: AnyObject {
    /// A key, before the text view's own handling — the completion list,
    /// vim, and the editor's shortcuts. `equivalent`: asked before the menu
    /// (⌘ keys), where only shortcuts answer. True when taken.
    func codeTextView(_ view: CodeTextView, handleKey event: NSEvent, equivalent: Bool) -> Bool
    /// Typed text (not a paste, not IME composition): auto-closing pairs.
    func codeTextView(_ view: CodeTextView, willInsert text: String) -> Bool
    func codeTextViewInsertNewline(_ view: CodeTextView) -> Bool
    func codeTextView(_ view: CodeTextView, indent backwards: Bool) -> Bool
    func codeTextViewDeleteBackward(_ view: CodeTextView) -> Bool
    /// ⌘-click: go to the definition at `index`.
    func codeTextView(_ view: CodeTextView, commandClickAt index: Int) -> Bool
    /// The mouse rested on `index` (nil: it left the text).
    func codeTextView(_ view: CodeTextView, hoverAt index: Int?)
    func codeTextViewContextMenu(_ view: CodeTextView, for menu: NSMenu) -> NSMenu
    /// ⌘V, before the text view's own: true when the host pasted (an image
    /// into a note).
    func codeTextView(_ view: CodeTextView, paste pasteboard: NSPasteboard) -> Bool
    /// A click in a note's Live Preview: true when it was a box or a link
    /// and the host acted on it.
    func codeTextView(_ view: CodeTextView, liveClickAt index: Int) -> Bool
}

/// A problem a language server reported, as the text view draws it.
struct EditorDiagnostic: Equatable {
    enum Severity: Int, Comparable {
        case error = 1, warning, info, hint
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var range: NSRange
    let severity: Severity
    let message: String
    let source: String?
}

/// The editor's text: an NSTextView (IME, undo, accessibility, find for
/// free) that draws what a code editor shows besides the text — the line
/// the caret is on, indent guides, the bracket matching the caret's, a
/// squiggle under each problem, and vim's block cursor.
@MainActor
final class CodeTextView: NSTextView {
    weak var host: CodeTextViewHost?

    override func paste(_ sender: Any?) {
        if host?.codeTextView(self, paste: .general) == true { return }
        super.paste(sender)
    }
    var theme = EditorTheme(dark: true, background: .black) {
        didSet { needsDisplay = true }
    }
    var showsIndentGuides = true {
        didSet { needsDisplay = true }
    }
    /// Columns per indent level (a tab's width, or the file's spaces).
    var indentWidth = 4 {
        didSet { needsDisplay = true }
    }
    var tabWidth = 4
    /// Vim's normal and visual modes: a block over the character.
    var blockCursor = false {
        didSet {
            guard blockCursor != oldValue else { return }
            updateInsertionPointStateAndRestartTimer(true)
            needsDisplay = true
        }
    }
    /// The bracket at the caret and its partner, boxed.
    var bracketPair: [NSRange] = [] {
        didSet { if bracketPair != oldValue { needsDisplay = true } }
    }
    var diagnostics: [EditorDiagnostic] = [] {
        didSet { if diagnostics != oldValue { needsDisplay = true } }
    }
    /// Other occurrences of the word at the caret, as Zed shades them.
    var wordHighlights: [NSRange] = [] {
        didSet { if wordHighlights != oldValue { needsDisplay = true } }
    }

    /// One character's width: the editor's font is monospaced.
    var characterWidth: CGFloat {
        guard let font else { return 7 }
        return ("m" as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        // The caret's line, across the whole width — only for a caret, not a
        // selection, as Zed does.
        if selectedRanges.count == 1, selectedRange().length == 0 {
            let line = lineRect(at: selectedRange().location)
            theme.activeLine.setFill()
            NSRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height).fill()
        }
        if showsIndentGuides { drawIndentGuides(in: rect) }
        // Live Preview's code blocks: the lines on a surface, edge to edge.
        if let storage = textStorage, storage.length > 0 {
            let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            storage.enumerateAttribute(.noteDecoration, in: characters) { value, range, _ in
                guard case .code = value as? NoteDecoration else { return }
                let glyph = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                theme.text.withAlphaComponent(theme.isDark ? 0.06 : 0.04).setFill()
                layoutManager.enumerateLineFragments(forGlyphRange: glyph) { line, _, _, _, _ in
                    NSRect(x: rect.minX, y: line.minY + origin.y, width: rect.width, height: line.height).fill()
                }
            }
        }
        for range in wordHighlights {
            theme.bracketMatch.withAlphaComponent(0.12).setFill()
            for box in rects(for: range, layoutManager, textContainer, origin) {
                NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
            }
        }
        for range in bracketPair {
            for box in rects(for: range, layoutManager, textContainer, origin) {
                theme.bracketMatch.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -0.5, dy: 1), xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawDiagnostics(in: dirtyRect)
        drawNoteDecorations(in: dirtyRect)
    }

    /// Live Preview's boxes, dots, bars and rules (NoteDecoration), over
    /// the markup they stand for.
    private func drawNoteDecorations(in rect: NSRect) {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let accent = theme.info
        let muted = theme.lineNumber
        storage.enumerateAttribute(.noteDecoration, in: characters) { value, range, _ in
            guard let decoration = value as? NoteDecoration else { return }
            let glyph = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let box = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer).offsetBy(dx: origin.x, dy: origin.y)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            switch decoration {
            case .checkbox(let done):
                let side = min(14, line.height - 4)
                let square = NSRect(x: box.minX + 1, y: line.midY - side / 2, width: side, height: side)
                let path = NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3)
                if done {
                    accent.setFill()
                    path.fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: square.minX + side * 0.25, y: square.midY))
                    tick.line(to: NSPoint(x: square.minX + side * 0.43, y: square.maxY - side * 0.27))
                    tick.line(to: NSPoint(x: square.maxX - side * 0.22, y: square.minY + side * 0.28))
                    tick.lineWidth = 1.8
                    tick.lineCapStyle = .round
                    theme.background.setStroke()
                    tick.stroke()
                } else {
                    muted.setStroke()
                    path.lineWidth = 1.2
                    path.stroke()
                }
            case .bullet:
                let dot = NSRect(x: box.midX - 2.5, y: line.midY - 2.5, width: 5, height: 5)
                muted.setFill()
                NSBezierPath(ovalIn: dot).fill()
            case .quote:
                // Every fragment of the line, wrapped ones too — not the
                // first glyph's, a hidden `>` laid out as nothing.
                accent.withAlphaComponent(0.6).setFill()
                // From the first character drawn: a run of hidden ones at
                // the line's start is laid out against the line before.
                var first = range.location
                while first < NSMaxRange(range) - 1, storage.attribute(.noteHidden, at: first, effectiveRange: nil) != nil { first += 1 }
                let shown = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: first, length: NSMaxRange(range) - first), actualCharacterRange: nil)
                layoutManager.enumerateLineFragments(forGlyphRange: shown) { fragment, _, _, _, _ in
                    NSRect(x: origin.x + textContainer.lineFragmentPadding, y: fragment.minY + origin.y, width: 3, height: fragment.height).fill()
                }
            case .rule:
                muted.withAlphaComponent(0.6).setFill()
                NSRect(x: line.minX + textContainer.lineFragmentPadding, y: line.midY, width: line.width - 2 * textContainer.lineFragmentPadding, height: 1).fill()
            case .code:
                break
            }
        }
    }

    /// The rect of the line holding `index` (the empty last line included).
    func lineRect(at index: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let length = (string as NSString).length
        var rect: NSRect
        if index >= length, length == 0 || (string as NSString).character(at: length - 1) == 0x0A {
            rect = layoutManager.extraLineFragmentRect
            if rect.height == 0, length > 0 {
                rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.numberOfGlyphs - 1, effectiveRange: nil)
            }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(index, max(0, length - 1)))
            rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        _ = textContainer
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private func rects(
        for range: NSRange, _ layoutManager: NSLayoutManager, _ container: NSTextContainer, _ origin: NSPoint
    ) -> [NSRect] {
        let length = (string as NSString).length
        guard range.location < length else { return [] }
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        let glyphs = layoutManager.glyphRange(forCharacterRange: clipped, actualCharacterRange: nil)
        var result: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in
            result.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return result
    }

    /// A thin line at each indent level of every visible line; blank lines
    /// take their neighbours' levels so a block's guide runs unbroken.
    private func drawIndentGuides(in rect: NSRect) {
        guard let layoutManager, let textContainer, indentWidth > 0 else { return }
        let text = string as NSString
        guard text.length > 0 else { return }
        let glyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let width = characterWidth
        let x0 = textContainerOrigin.x + textContainer.lineFragmentPadding
        // Lines on screen, and their levels (nil: blank).
        var lines: [(range: NSRange, level: Int?)] = []
        var index = text.lineRange(for: NSRange(location: chars.location, length: 0)).location
        let end = min(text.length, NSMaxRange(chars) + 1)
        while index < end {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            lines.append((line, indentLevel(of: line, in: text)))
            if NSMaxRange(line) <= index { break }
            index = NSMaxRange(line)
        }
        // Blank lines: the smaller of the levels around them (looking past
        // the screen's edge a little so a guide doesn't stop at it).
        let levels = Self.fillBlankLevels(lines.map(\.level))
        let caretLine = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0))
        let caretLevel = indentLevel(of: caretLine, in: text) ?? 0
        for (i, line) in lines.enumerated() {
            let level = levels[i]
            guard level > 0 else { continue }
            let rect = lineRect(at: line.range.location)
            for guide in 0..<level {
                let x = (x0 + CGFloat(guide * indentWidth) * width).rounded() + 0.5
                let active = guide == caretLevel - 1 && NSLocationInRange(selectedRange().location, NSRange(location: 0, length: text.length + 1))
                (active ? theme.activeIndentGuide : theme.indentGuide).setFill()
                NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
            }
        }
    }

    static func fillBlankLevels(_ levels: [Int?]) -> [Int] {
        var result = [Int](repeating: 0, count: levels.count)
        var previous = 0
        for (i, level) in levels.enumerated() {
            if let level {
                result[i] = level
                previous = level
            } else {
                let next = levels[(i + 1)...].lazy.compactMap { $0 }.first ?? 0
                result[i] = min(previous, next)
            }
        }
        return result
    }

    /// Indent levels of a line's leading whitespace; nil for a blank line.
    private func indentLevel(of line: NSRange, in text: NSString) -> Int? {
        var columns = 0
        var i = line.location
        let end = NSMaxRange(line)
        while i < end {
            let c = text.character(at: i)
            if c == 0x20 {
                columns += 1
            } else if c == 0x09 {
                columns += tabWidth - columns % tabWidth
            } else if c == 0x0A || c == 0x0D {
                return nil
            } else {
                return columns / max(1, indentWidth)
            }
            i += 1
        }
        return nil
    }

    private func drawDiagnostics(in dirtyRect: NSRect) {
        guard !diagnostics.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let visible = layoutManager.characterRange(
            forGlyphRange: layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer), actualGlyphRange: nil)
        // Least severe first, so an error's squiggle is the one on top.
        for diagnostic in diagnostics.sorted(by: { $0.severity > $1.severity }) {
            var range = diagnostic.range
            if range.length == 0 { range.length = 1 }
            guard NSIntersectionRange(range, visible).length > 0 || NSLocationInRange(range.location, visible) else { continue }
            let color: NSColor
            switch diagnostic.severity {
            case .error: color = theme.error
            case .warning: color = theme.warning
            case .info: color = theme.info
            case .hint: color = theme.hint
            }
            for rect in rects(for: range, layoutManager, textContainer, origin) where rect.intersects(dirtyRect) {
                Self.squiggle(under: rect, color: color, dotted: diagnostic.severity == .hint)
            }
        }
    }

    private static func squiggle(under rect: NSRect, color: NSColor, dotted: Bool) {
        let path = NSBezierPath()
        let y = rect.maxY - 2
        let step: CGFloat = 2
        var x = rect.minX
        path.move(to: NSPoint(x: x, y: y))
        var up = true
        while x < rect.maxX {
            x += step
            path.line(to: NSPoint(x: min(x, rect.maxX), y: up ? y - 1.5 : y))
            up.toggle()
        }
        path.lineWidth = 1
        if dotted { path.setLineDash([1, 2], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
    }

    // MARK: The caret

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if blockCursor {
            guard flag else { return }
            var block = rect
            block.size.width = characterWidth
            color.withAlphaComponent(0.55).setFill()
            block.fill()
        } else {
            var bar = rect
            bar.size.width = 2
            super.drawInsertionPoint(in: bar, color: color, turnedOn: flag)
        }
    }

    /// The text view only redraws a 1 pt caret: a block (or a 2 pt bar)
    /// left pieces of itself behind as it moved.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = rect
        if rect.width <= 2 { rect.size.width = max(rect.width, characterWidth + 2) }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let before = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The caret's line moved: its highlight and the guides go with it.
        if before != selectedRange() { setNeedsDisplay(visibleRect, avoidAdditionalLayout: true) }
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Every view in the window is asked; only the focused editor answers.
        if window?.firstResponder === self, host?.codeTextView(self, handleKey: event, equivalent: true) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if host?.codeTextView(self, handleKey: event, equivalent: false) == true { return }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if !hasMarkedText(), replacementRange.location == NSNotFound, let text = string as? String,
            host?.codeTextView(self, willInsert: text) == true
        {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        if host?.codeTextViewInsertNewline(self) == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if host?.codeTextView(self, indent: false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if host?.codeTextView(self, indent: true) == true { return }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if host?.codeTextViewDeleteBackward(self) == true { return }
        super.deleteBackward(sender)
    }

    /// Replaces several ranges as one undoable change, then selects
    /// `selection` — the way every editing command lands.
    func apply(_ changes: [(range: NSRange, text: String)], selecting selection: [NSRange]?) {
        guard let storage = textStorage else { return }
        let sorted = changes.sorted { $0.range.location < $1.range.location }
        guard !sorted.isEmpty else {
            if let selection, !selection.isEmpty { selectedRanges = selection.map { NSValue(range: $0) } }
            return
        }
        guard shouldChangeText(inRanges: sorted.map { NSValue(range: $0.range) }, replacementStrings: sorted.map(\.text)) else { return }
        storage.beginEditing()
        for change in sorted.reversed() {
            storage.replaceCharacters(in: change.range, with: change.text)
        }
        storage.endEditing()
        didChangeText()
        if let selection, !selection.isEmpty {
            let length = storage.length
            selectedRanges = selection.map {
                let location = min($0.location, length)
                return NSValue(range: NSRange(location: location, length: min($0.length, length - location)))
            }
        }
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Mouse

    private var hoverTimer: Timer?
    private var showsLinkCursor = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverTimer?.invalidate()
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: point)
        // ⌘ held: the word under the mouse reads as a link, as in Zed.
        if event.modifierFlags.contains(.command), index != nil {
            NSCursor.pointingHand.set()
            showsLinkCursor = true
        } else if showsLinkCursor {
            NSCursor.iBeam.set()
            showsLinkCursor = false
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.host?.codeTextView(self, hoverAt: index)
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTimer?.invalidate()
        host?.codeTextView(self, hoverAt: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
            let index = characterIndex(at: convert(event.locationInWindow, from: nil)),
            host?.codeTextView(self, liveClickAt: index) == true
        {
            return
        }
        if event.modifierFlags.contains(.command), event.clickCount == 1,
            let index = characterIndex(at: convert(event.locationInWindow, from: nil)),
            host?.codeTextView(self, commandClickAt: index) == true
        {
            return
        }
        hoverTimer?.invalidate()
        host?.codeTextView(self, hoverAt: nil)
        super.mouseDown(with: event)
    }

    /// The character under `point`, if the point is on one (not past a
    /// line's end or below the text).
    func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.contains(inContainer) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let c = (string as NSString).character(at: index)
        return c == 0x0A ? nil : index
    }

    /// Where `index` is on screen, for popups.
    func screenRect(forCharacterAt index: Int) -> NSRect {
        guard let layoutManager, let textContainer, let window else { return .zero }
        let length = (string as NSString).length
        var rect: NSRect
        if length == 0 {
            rect = NSRect(x: 0, y: 0, width: 1, height: font?.boundingRectForFont.height ?? 16)
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: min(index, length - 1), length: 1), actualCharacterRange: nil)
            rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            if index >= length { rect.origin.x = rect.maxX }
        }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return window.convertToScreen(convert(rect, to: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // A right-click moves the caret there first, so "Go to Definition"
        // is about what was clicked.
        if let index = characterIndex(at: convert(event.locationInWindow, from: nil)), selectedRange().length == 0 {
            setSelectedRange(NSRange(location: index, length: 0))
        }
        let base = super.menu(for: event) ?? NSMenu()
        return host?.codeTextViewContextMenu(self, for: base) ?? base
    }
}
