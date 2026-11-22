import AppKit

/// The list's two cells that aren't one line of words, drawn by AppKit
/// (docs/design/activity/analysis.md, 6.5, 6.11, 7.7): a process's name —
/// its fold, its agent's symbol, its chips — and its 15-minute strip. As
/// hosting views, the 70 on screen handed other processes at every
/// re-sorted publish were most of what a publish cost the main thread.
/// Each is shown again only when its value changed, takes the row's press
/// as every cell does (`ResourcePressCell`), and says to VoiceOver what the
/// SwiftUI cell said.

/// A row's strip as drawn: its cells and since when (`ActivityProcessRow`'s
/// own), the theme's colours. What its tooltip and VoiceOver say is made
/// from the cells only when they changed.
package struct ActivityStripValue: Equatable {
    package var strip: [Double?]?
    package var since: Date?
    package var colours: [NSColor]
    package var track: NSColor
    package var alpha: CGFloat = 1
    package var ground: NSColor? = nil
}

package final class ActivityStripCell: ResourcePressCell {
    package private(set) var shown: ActivityStripValue?
    /// What VoiceOver and the scenarios find: `activity.strip`, as the
    /// SwiftUI cell's element was — the cell's own identifier is its row's.
    private let element = NSAccessibilityElement()

    package override var isFlipped: Bool { true }

    package init() {
        super.init(frame: .zero)
        element.setAccessibilityRole(.image)
        element.setAccessibilityIdentifier("activity.strip")
        element.setAccessibilityParent(self)
        setAccessibilityChildren([element])
    }

    package override func layout() {
        super.layout()
        element.setAccessibilityFrameInParentSpace(bounds)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    package func show(_ value: ActivityStripValue) -> Bool {
        guard value != shown else { return false }
        let old = shown
        shown = value
        if old == nil || old?.strip != value.strip || old?.since != value.since {
            let help = ActivityPageView.stripHelp(value.strip, since: value.since)
            toolTip = help
            element.setAccessibilityLabel(help)
        }
        needsDisplay = true
        return true
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard let shown else { return }
        let dirty = dirtyRect.intersection(bounds)
        if let ground = shown.ground {
            ground.setFill()
            dirty.fill()
        }
        guard let strip = shown.strip, !strip.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(shown.alpha)
        // As the Canvas drew it: 6 pt in from each side, 3 from top and foot.
        let rect = CGRect(x: 6, y: 3, width: max(bounds.width - 12, 0), height: max(bounds.height - 6, 1))
        context.setFillColor(shown.track.withAlphaComponent(shown.track.alphaComponent * 0.08).cgColor)
        context.fill(rect)
        // One fill a colour, not one a cell: 60 cells, five colours.
        var byLevel = [[CGRect]](repeating: [], count: KubeHeatStrip.Level.allCases.count)
        var gaps: [CGRect] = []
        // CPU capped at 100 for the colour, as the Canvas drew it.
        for bar in KubeHeatStripView.bars(strip.map { $0.map { min($0, 100) } }, in: rect) {
            if let level = bar.level { byLevel[level.rawValue].append(bar.rect) } else { gaps.append(bar.rect) }
        }
        if !gaps.isEmpty {
            context.setFillColor(shown.track.withAlphaComponent(shown.track.alphaComponent * 0.3).cgColor)
            context.fill(gaps)
        }
        for (level, rects) in byLevel.enumerated() where !rects.isEmpty {
            context.setFillColor(shown.colours[level].cgColor)
            context.fill(rects)
        }
        context.restoreGState()
    }
}

/// A process's name cell as drawn (6.5): its indent, its fold, its agent's
/// symbol, the name in its colour, the chips, "ended".
package struct ActivityNameValue: Equatable {
    package struct Chip: Equatable {
        package var text: String
        package var color: NSColor
        /// A filled capsule (a chip of what changed); else a stroked one.
        package var fill: NSColor?
        package var stroke: NSColor?
        package var bold = false
        package var help: String? = nil
        package var identifier: String? = nil
    }

    package var id: String
    package var depth: Int
    /// Nil: no fold, its room kept; else whether it is folded.
    package var folded: Bool?
    package var chevron: NSColor
    package var symbol: String?
    package var symbolColor: NSColor
    package var name: String
    package var nameColor: NSColor
    package var chips: [Chip]
    /// The owner's reason: the cell's tooltip.
    package var help: String
    package var size: CGFloat
    package var chipSize: CGFloat
    package var alpha: CGFloat = 1
    package var ground: NSColor? = nil
}

package final class ActivityNameCell: ResourcePressCell {
    /// The fold's click: the row's id and whether it was folded.
    package var toggle: ((String, Bool) -> Void)?
    package private(set) var shown: ActivityNameValue?
    private let chevron = FirstClickButton()
    private let symbol = NSImageView()
    private var nameElement = NSAccessibilityElement()
    private var chipElements: [NSAccessibilityElement] = []
    /// Where layout put the name and each chip, y down.
    private var nameRect = CGRect.zero
    private var chipRects: [CGRect] = []

    package override var isFlipped: Bool { true }

    /// A button that takes the first click in a window behind others, as
    /// the hosted cells' did.
    private final class FirstClickButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    package init() {
        super.init(frame: .zero)
        chevron.isBordered = false
        chevron.bezelStyle = .regularSquare
        chevron.imagePosition = .imageOnly
        chevron.setButtonType(.momentaryChange)
        chevron.target = self
        chevron.action = #selector(fold)
        chevron.isHidden = true
        addSubview(chevron)
        symbol.isHidden = true
        symbol.imageScaling = .scaleProportionallyDown
        symbol.setAccessibilityElement(false)
        addSubview(symbol)
        nameElement.setAccessibilityRole(.staticText)
        nameElement.setAccessibilityParent(self)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @objc private func fold() {
        guard let shown, let folded = shown.folded else { return }
        toggle?(shown.id, folded)
    }

    /// The fold takes its own click; every other point is the row's press.
    package override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let inside = convert(point, from: superview)
        if !chevron.isHidden, chevron.frame.contains(inside) { return chevron }
        return self
    }

    @discardableResult
    package func show(_ value: ActivityNameValue) -> Bool {
        guard value != shown else { return false }
        let old = shown
        shown = value
        if old?.folded != value.folded || old?.chevron != value.chevron || old?.size != value.size {
            if let folded = value.folded {
                let image = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: ChromeMetrics.text(9), weight: .semibold))
                chevron.image = image
                chevron.contentTintColor = value.chevron
                chevron.setAccessibilityLabel(folded ? "Unfold" : "Fold")
                chevron.isHidden = false
            } else {
                chevron.isHidden = true
            }
        }
        if old?.symbol != value.symbol || old?.symbolColor != value.symbolColor || old?.chipSize != value.chipSize {
            if let name = value.symbol {
                symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: ChromeMetrics.text(10), weight: .regular))
                symbol.contentTintColor = value.symbolColor
                symbol.isHidden = false
            } else {
                symbol.isHidden = true
            }
        }
        chevron.alphaValue = value.alpha
        symbol.alphaValue = value.alpha
        needsLayout = true
        needsDisplay = true
        return true
    }

    private func attributes(_ font: NSFont, _ color: NSColor, truncate: NSLineBreakMode) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncate
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    /// As the SwiftUI cell laid it out: 6 pt in, then the indent, the fold's
    /// 14 pt, the symbol, the name — which keeps its width first — and the
    /// chips while they fit, 4 pt apart.
    package override func layout() {
        super.layout()
        guard let shown else { return }
        var x: CGFloat = 6 + CGFloat(shown.depth) * 14 + 4
        let height = bounds.height
        chevron.frame = CGRect(x: x, y: (height - 18) / 2, width: 14, height: 18)
        x += 14 + 4
        if let image = symbol.image, shown.symbol != nil {
            let size = image.size
            symbol.frame = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + 4
        }
        let right = bounds.width - 6
        let font = NSFont.systemFont(ofSize: shown.size)
        let nameWidth = ceil((shown.name as NSString).size(withAttributes: [.font: font]).width)
        let nameHeight = ceil(font.ascender - font.descender + font.leading)
        let name = min(nameWidth, max(right - x, 0))
        nameRect = CGRect(x: x, y: (height - nameHeight) / 2, width: name, height: nameHeight)
        x += name
        chipRects = []
        for chip in shown.chips {
            let chipFont = chip.bold ? NSFont.systemFont(ofSize: shown.chipSize, weight: .semibold) : NSFont.systemFont(ofSize: shown.chipSize)
            let width = ceil((chip.text as NSString).size(withAttributes: [.font: chipFont]).width) + 10
            let chipHeight = ceil(chipFont.ascender - chipFont.descender + chipFont.leading)
            let left = x + 4
            let fits = min(width, right - left)
            guard fits >= 16 else { break }
            chipRects.append(CGRect(x: left, y: (height - chipHeight) / 2, width: fits, height: chipHeight))
            x = left + fits
        }
        // Tooltips by place: a chip's own over it, the owner's reason over
        // the rest (`view(_:stringForToolTip:…)`).
        removeAllToolTips()
        var from: CGFloat = 0
        for rect in chipRects {
            if rect.minX > from { addToolTip(CGRect(x: from, y: 0, width: rect.minX - from, height: height), owner: self, userData: nil) }
            addToolTip(rect, owner: self, userData: nil)
            from = rect.maxX
        }
        if bounds.width > from { addToolTip(CGRect(x: from, y: 0, width: bounds.width - from, height: height), owner: self, userData: nil) }
        updateAccessibility()
    }

    /// What VoiceOver reads inside the cell: the fold, the name, each chip.
    private func updateAccessibility() {
        guard let shown else { return }
        nameElement.setAccessibilityLabel(shown.name)
        nameElement.setAccessibilityFrameInParentSpace(nameRect)
        while chipElements.count < chipRects.count {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(self)
            chipElements.append(element)
        }
        chipElements.removeLast(chipElements.count - chipRects.count)
        for (index, element) in chipElements.enumerated() {
            let chip = shown.chips[index]
            element.setAccessibilityLabel(chip.text)
            element.setAccessibilityIdentifier(chip.identifier)
            element.setAccessibilityHelp(chip.help)
            element.setAccessibilityFrameInParentSpace(chipRects[index])
        }
        var children: [Any] = []
        if !chevron.isHidden { children.append(chevron) }
        children.append(nameElement)
        children += chipElements
        setAccessibilityChildren(children)
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard let shown else { return }
        if let ground = shown.ground {
            ground.setFill()
            dirtyRect.intersection(bounds).fill()
        }
        NSGraphicsContext.current?.cgContext.setAlpha(shown.alpha)
        let font = NSFont.systemFont(ofSize: shown.size)
        (shown.name as NSString).draw(
            with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes(font, shown.nameColor, truncate: .byTruncatingMiddle))
        for (index, rect) in chipRects.enumerated() {
            let chip = shown.chips[index]
            let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            if let fill = chip.fill {
                fill.setFill()
                capsule.fill()
            }
            if let stroke = chip.stroke {
                stroke.setStroke()
                let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2 - 0.5, yRadius: rect.height / 2 - 0.5)
                inset.lineWidth = 1
                inset.stroke()
            }
            let chipFont = chip.bold ? NSFont.systemFont(ofSize: shown.chipSize, weight: .semibold) : NSFont.systemFont(ofSize: shown.chipSize)
            (chip.text as NSString).draw(
                with: rect.insetBy(dx: 5, dy: 0), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes(chipFont, chip.color, truncate: .byTruncatingTail))
        }
    }
}

extension ActivityNameCell: NSViewToolTipOwner {
    package nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated {
            guard let shown else { return "" }
            for (index, rect) in chipRects.enumerated() where rect.contains(point) { return shown.chips[index].help ?? "" }
            return shown.help
        }
    }
}
