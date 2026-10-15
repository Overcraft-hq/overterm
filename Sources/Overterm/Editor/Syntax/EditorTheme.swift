import AppKit

/// The editor's colours: Zed's One Dark (One Light on a light terminal
/// theme), keyed by the Helix capture names the queries use. A capture
/// takes its nearest named ancestor — "keyword.control.return" is a
/// "keyword" — and one with none ("variable.other") paints nothing.
struct EditorTheme {
    struct Style: Equatable {
        var color: NSColor
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
    }

    let isDark: Bool
    /// The text's own colour (Zed's `editor.foreground`).
    let text: NSColor
    let background: NSColor
    let activeLine: NSColor
    let lineNumber: NSColor
    let activeLineNumber: NSColor
    let indentGuide: NSColor
    let activeIndentGuide: NSColor
    let bracketMatch: NSColor
    let selection: NSColor
    let searchMatch: NSColor
    let gitAdded: NSColor
    let gitModified: NSColor
    let gitDeleted: NSColor
    let error: NSColor
    let warning: NSColor
    let info: NSColor
    let hint: NSColor
    private let styles: [String: Style]

    /// Dark or light by the terminal's background, so the editor matches
    /// the terminal beside it; the background itself stays the terminal's.
    init(background: NSColor) {
        let rgb = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        self.init(dark: luminance < 0.5, background: background)
    }

    init(dark: Bool, background: NSColor) {
        isDark = dark
        self.background = background
        let p = dark ? Self.oneDark : Self.oneLight
        text = p.text
        activeLine = p.text.withAlphaComponent(dark ? 0.045 : 0.05)
        lineNumber = p.text.withAlphaComponent(0.35)
        activeLineNumber = p.text.withAlphaComponent(0.85)
        indentGuide = p.text.withAlphaComponent(0.08)
        activeIndentGuide = p.text.withAlphaComponent(0.2)
        bracketMatch = p.text.withAlphaComponent(0.18)
        selection = p.accent.withAlphaComponent(dark ? 0.24 : 0.2)
        searchMatch = p.accent.withAlphaComponent(0.3)
        gitAdded = p.string
        gitModified = p.accent
        gitDeleted = p.error
        error = p.error
        warning = p.warning
        info = p.accent
        hint = p.text.withAlphaComponent(0.5)
        styles = Self.styles(p)
    }

    /// The style for a capture, or nil to leave the text as it is.
    func style(for capture: String) -> Style? {
        var name = Substring(capture)
        while true {
            if let style = styles[String(name)] { return style }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = name[..<dot]
        }
    }

    // MARK: Palettes

    private struct Palette {
        let text, comment, docComment, keyword, string, escape, number, constant, function, type, operator_, property, tag,
            attribute, punctuation, bracket, special, link, accent, error, warning: NSColor
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    /// Zed's assets/themes/one/one.json, One Dark.
    private static let oneDark = Palette(
        text: hex(0xACB2BE), comment: hex(0x5D636F), docComment: hex(0x878E98), keyword: hex(0xB477CF), string: hex(0xA1C181),
        escape: hex(0x878E98), number: hex(0xBF956A), constant: hex(0xDFC184), function: hex(0x73ADE9), type: hex(0x6EB4BF),
        operator_: hex(0x6EB4BF), property: hex(0xD07277), tag: hex(0x74ADE8), attribute: hex(0x74ADE8), punctuation: hex(0xACB2BE),
        bracket: hex(0xB2B9C6), special: hex(0xBF956A), link: hex(0x6EB4BF), accent: hex(0x74ADE8), error: hex(0xD07277),
        warning: hex(0xDEC184))

    /// …and One Light.
    private static let oneLight = Palette(
        text: hex(0x242529), comment: hex(0xA2A3A7), docComment: hex(0x7C7E86), keyword: hex(0xA449AB), string: hex(0x649F57),
        escape: hex(0x7C7E86), number: hex(0xAD6E25), constant: hex(0xC18401), function: hex(0x5B79E3), type: hex(0x3882B7),
        operator_: hex(0x3882B7), property: hex(0xD3604F), tag: hex(0x5C78E2), attribute: hex(0x5C78E2), punctuation: hex(0x4D4F52),
        bracket: hex(0x4D4F52), special: hex(0xAD6E25), link: hex(0x3882B7), accent: hex(0x5C78E2), error: hex(0xD36151),
        warning: hex(0xC18401))

    private static func styles(_ p: Palette) -> [String: Style] {
        func s(_ color: NSColor, bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false) -> Style {
            Style(color: color, bold: bold, italic: italic, underline: underline, strikethrough: strike)
        }
        return [
            "attribute": s(p.attribute),
            "comment": s(p.comment),
            "comment.block.documentation": s(p.docComment),
            "comment.line.documentation": s(p.docComment),
            "constant": s(p.constant),
            "constant.builtin": s(p.number),
            "constant.character": s(p.string),
            "constant.character.escape": s(p.escape),
            "constant.numeric": s(p.number),
            "constructor": s(p.function),
            "function": s(p.function),
            "keyword": s(p.keyword),
            "label": s(p.tag),
            "namespace": s(p.text),
            "operator": s(p.operator_),
            "punctuation": s(p.punctuation),
            "punctuation.bracket": s(p.bracket),
            "punctuation.delimiter": s(p.bracket),
            "punctuation.special": s(p.keyword),
            "special": s(p.special),
            "string": s(p.string),
            "string.regexp": s(p.number),
            "string.special": s(p.number),
            "string.special.path": s(p.link),
            "string.special.url": s(p.link, underline: true),
            "string.special.symbol": s(p.number),
            "tag": s(p.tag),
            "type": s(p.type),
            "type.enum.variant": s(p.function),
            "variable": s(p.text),
            "variable.builtin": s(p.number),
            "variable.other.member": s(p.property),
            "variable.parameter": s(p.text),
            "markup.heading": s(p.property, bold: true),
            "markup.heading.marker": s(p.property),
            "markup.list": s(p.property),
            "markup.list.checked": s(p.string),
            "markup.list.unchecked": s(p.property),
            "markup.bold": s(p.number, bold: true),
            "markup.italic": s(p.accent, italic: true),
            "markup.strikethrough": s(p.comment, strike: true),
            "markup.link.url": s(p.link, underline: true),
            "markup.link.text": s(p.function, italic: true),
            "markup.link.label": s(p.function),
            "markup.quote": s(p.docComment, italic: true),
            "markup.raw": s(p.string),
            "diff.plus": s(p.string),
            "diff.minus": s(p.error),
            "diff.delta": s(p.warning),
        ]
    }
}
