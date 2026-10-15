import AppKit

/// Markdown as it reads, for the editor's preview (⇧⌘V): Foundation's own
/// parser (`AttributedString(markdown:)`, full syntax — no web view, no
/// bundled script), drawn in the editor's colours with TextKit 1's blocks —
/// code and quotes on a surface, tables as tables.
enum MarkdownRenderer {
    static func render(_ markdown: String, theme: EditorTheme, size: CGFloat = 14) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: theme.text])
        }
        var builder = Builder(theme: theme, size: size)
        builder.build(parsed)
        return builder.out
    }

    private struct Block {
        let intent: PresentationIntent?
        var runs: [AttributedString.Runs.Run] = []
    }

    private struct Builder {
        let theme: EditorTheme
        let size: CGFloat
        let out = NSMutableAttributedString()
        private var listItemsSeen = Set<Int>()

        init(theme: EditorTheme, size: CGFloat) {
            self.theme = theme
            self.size = size
        }

        private var body: NSFont { .systemFont(ofSize: size) }
        private var mono: NSFont { .monospacedSystemFont(ofSize: size - 1.5, weight: .regular) }
        private var surface: NSColor { EditorPicker.surface(theme) }

        mutating func build(_ text: AttributedString) {
            // Runs grouped into their blocks: a paragraph, a heading, a cell.
            var blocks: [Block] = []
            for run in text.runs {
                let identity = run.presentationIntent?.components.first?.identity
                if let last = blocks.last, last.intent?.components.first?.identity == identity {
                    blocks[blocks.count - 1].runs.append(run)
                } else {
                    blocks.append(Block(intent: run.presentationIntent, runs: [run]))
                }
            }
            var i = 0
            while i < blocks.count {
                // A table is every block of it, at once.
                if let table = Self.table(of: blocks[i]) {
                    var cells: [Block] = []
                    while i < blocks.count, Self.table(of: blocks[i])?.identity == table.identity {
                        cells.append(blocks[i])
                        i += 1
                    }
                    appendTable(cells, columns: table.columns, text: text)
                    continue
                }
                append(blocks[i], text: text)
                i += 1
            }
            // No trailing empty paragraph.
            while out.string.hasSuffix("\n\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        }

        private static func table(of block: Block) -> (identity: Int, columns: Int)? {
            for component in block.intent?.components ?? [] {
                if case .table(let columns) = component.kind { return (component.identity, columns.count) }
            }
            return nil
        }

        // MARK: Blocks

        private mutating func append(_ block: Block, text: AttributedString) {
            let components = block.intent?.components ?? []
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = size * 0.75
            var font = body
            var color = theme.text
            var textBlocks: [NSTextBlock] = []
            var prefix = ""
            var depth = 0
            var isCode = false
            var isRule = false

            for component in components {
                switch component.kind {
                case .header(let level):
                    let scale: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1.0, 0.95]
                    font = .systemFont(ofSize: (size * scale[min(level, 6) - 1]).rounded(), weight: level <= 2 ? .bold : .semibold)
                    style.paragraphSpacingBefore = level <= 2 ? size * 0.9 : size * 0.5
                    style.paragraphSpacing = level <= 2 ? size * 0.6 : size * 0.4
                case .codeBlock:
                    isCode = true
                    font = mono
                    let block = Self.fullWidth()
                    block.backgroundColor = surface
                    block.setWidth(12, type: .absoluteValueType, for: .padding)
                    block.setWidth(1, type: .absoluteValueType, for: .border)
                    block.setBorderColor(theme.text.withAlphaComponent(0.1))
                    textBlocks.append(block)
                case .blockQuote:
                    color = theme.text.withAlphaComponent(0.7)
                    let block = Self.fullWidth()
                    block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                    block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                    block.setBorderColor(theme.info.withAlphaComponent(0.6), for: .minX)
                    textBlocks.append(block)
                case .listItem(let ordinal):
                    depth += 1
                    // Only the item's first paragraph carries its marker.
                    if !listItemsSeen.contains(component.identity), prefix.isEmpty {
                        listItemsSeen.insert(component.identity)
                        let ordered = components.first { $0.identity != component.identity && Self.isList($0.kind) }.map { Self.isOrdered($0.kind) }
                        prefix = ordered == true ? "\(ordinal).\t" : "•\t"
                    }
                case .thematicBreak:
                    isRule = true
                default:
                    break
                }
            }
            if depth > 0 {
                let indent = CGFloat(depth) * 22
                style.headIndent = indent
                style.firstLineHeadIndent = prefix.isEmpty ? indent : indent - 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                style.paragraphSpacing = size * 0.3
            }
            style.textBlocks = textBlocks.reversed()

            if isRule {
                let rule = Self.fullWidth()
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(theme.text.withAlphaComponent(0.2), for: .maxY)
                rule.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                style.textBlocks = [rule]
                out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 4)]))
                return
            }

            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if !prefix.isEmpty {
                var marker = base
                marker[.foregroundColor] = theme.text.withAlphaComponent(0.55)
                out.append(NSAttributedString(string: prefix, attributes: marker))
            }
            for run in block.runs {
                var piece = String(text[run.range].characters)
                if isCode, piece.hasSuffix("\n") { piece.removeLast() }
                out.append(NSAttributedString(string: piece, attributes: inline(run, base: base, font: font, isCode: isCode)))
            }
            out.append(NSAttributedString(string: "\n", attributes: base))
        }

        /// A block as wide as the page: one without a width is as narrow
        /// as it can be — a code block came out a character wide.
        private static func fullWidth() -> NSTextBlock {
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            return block
        }

        private static func isList(_ kind: PresentationIntent.Kind) -> Bool {
            switch kind {
            case .orderedList, .unorderedList: true
            default: false
            }
        }

        private static func isOrdered(_ kind: PresentationIntent.Kind) -> Bool {
            if case .orderedList = kind { return true }
            return false
        }

        /// Bold, italics, code, strikethrough and links inside a block.
        private func inline(
            _ run: AttributedString.Runs.Run, base: [NSAttributedString.Key: Any], font: NSFont, isCode: Bool
        ) -> [NSAttributedString.Key: Any] {
            var attributes = base
            guard !isCode else { return attributes }
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            if intent.contains(.code) {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                attributes[.backgroundColor] = surface
                attributes[.foregroundColor] = theme.style(for: "markup.raw")?.color ?? theme.text
            }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = theme.info
            }
            return attributes
        }

        // MARK: Tables

        private mutating func appendTable(_ cells: [Block], columns: Int, text: AttributedString) {
            let table = NSTextTable()
            table.numberOfColumns = max(columns, 1)
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            var row = -1
            var rowIdentity: Int?
            for cell in cells {
                let components = cell.intent?.components ?? []
                var column = 0
                var isHeader = false
                for component in components {
                    switch component.kind {
                    case .tableCell(let index): column = index
                    case .tableHeaderRow:
                        isHeader = true
                        if rowIdentity != component.identity {
                            rowIdentity = component.identity
                            row += 1
                        }
                    case .tableRow:
                        if rowIdentity != component.identity {
                            rowIdentity = component.identity
                            row += 1
                        }
                    default: break
                    }
                }
                let block = NSTextTableBlock(table: table, startingRow: max(row, 0), rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(theme.text.withAlphaComponent(0.18))
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                if isHeader { block.backgroundColor = surface }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let font = isHeader ? NSFont.systemFont(ofSize: size, weight: .semibold) : body
                let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.text, .paragraphStyle: style]
                for run in cell.runs {
                    out.append(NSAttributedString(string: String(text[run.range].characters), attributes: inline(run, base: base, font: font, isCode: false)))
                }
                out.append(NSAttributedString(string: "\n", attributes: base))
            }
            // Space after the table, outside it.
            let after = NSMutableParagraphStyle()
            after.paragraphSpacing = size * 0.5
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: after]))
        }
    }
}

/// The preview pane over the editor's text: read-only, selectable, links
/// that work — a web link in the browser, a relative one in the editor.
@MainActor
final class MarkdownPreviewView: NSScrollView, NSTextViewDelegate {
    private let textView: NSTextView
    /// Settable: the terminal's theme can change while a preview is open
    /// (`EditorViewController.applyTerminalColors`), and the rendering
    /// carries its colours.
    var theme: EditorTheme {
        didSet {
            backgroundColor = theme.background
            textView.backgroundColor = theme.background
            show(lastMarkdown)
        }
    }
    private var lastMarkdown = ""
    /// A link to a file beside this one (`CLAUDE.md`, `docs/x.md#part`).
    var onOpenFile: ((URL) -> Void)?
    var baseURL: URL?

    init(theme: EditorTheme) {
        self.theme = theme
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("markdownPreview")
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = theme.background
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.foregroundColor: theme.info, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        textView.delegate = self
        textView.setAccessibilityIdentifier("markdownPreviewText")
        documentView = textView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = theme.background
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var renderedText: NSAttributedString { textView.attributedString() }

    /// Renders `markdown`, keeping where you had scrolled to.
    func show(_ markdown: String) {
        lastMarkdown = markdown
        let origin = contentView.bounds.origin
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(markdown, theme: theme))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return false }
        if let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return true
        }
        // A link to a heading in this file: nothing to open.
        let path = url.scheme == "file" ? url.path : url.relativePath
        guard !path.isEmpty, let base = baseURL else { return true }
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.deletingLastPathComponent().appendingPathComponent(path)
        onOpenFile?(target.standardizedFileURL)
        return true
    }
}
